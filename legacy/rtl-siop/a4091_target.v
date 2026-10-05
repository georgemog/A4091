// ===========================================================================
// a4091_target - virtual SCSI-2 direct-access device model
//
// One instance per bus (LUN 0 only, matches WinUAE). The SIOP phase engine
// hands it a CDB; it returns {direction, length, status} and owns the data
// buffer the SIOP DMAs to/from. Sector data comes from the HPS over `sec_*`
// (modelled on the block-serve path in rtl/ide.v).
//
// Command set = what a4091.device needs to boot an RDB hardfile:
//   TUR, REQUEST SENSE, INQUIRY, MODE SENSE(6), READ CAPACITY(10),
//   READ(6/10), WRITE(6/10), START STOP UNIT.
//
// STATUS: Phase 3.
// ===========================================================================
`default_nettype none

module a4091_target #(parameter BUFAW = 12)   // 4 KB data buffer
(
	input                 clk,
	input                 reset,

	// ---- command interface from the SIOP phase engine -------------------
	input                 cmd_stb,     // pulse: CDB valid
	input        [7:0]     cdb0,cdb1,cdb2,cdb3,cdb4,cdb5,
	input        [7:0]     cdb6,cdb7,cdb8,cdb9,
	output reg            rsp_ready,   // pulse: {dir,len,status} valid
	output reg  [1:0]     rsp_dir,     // 0 none / 1 in (dev->host) / 2 out
	output reg  [23:0]    rsp_len,
	output reg  [7:0]     rsp_status,  // SCSI status byte

	// ---- data buffer, shared with the SIOP DMA path --------------------
	input       [BUFAW-1:0] buf_addr,
	input       [7:0]       buf_wdata,
	input                   buf_we,       // SIOP writes (DATA OUT)
	output      [7:0]       buf_rdata,    // SIOP reads  (DATA IN)
	input                   data_out_done,// pulse: SIOP finished the DATA OUT move

	// ---- HPS sector port (TB / minimig_scsi.cpp) --------------------
	output reg            sec_rd,      // pulse: read  sec_cnt sectors @ sec_lba -> stream in on sec_q
	output reg            sec_wr,      // pulse: write sec_cnt sectors @ sec_lba <- stream out on sec_d
	output reg  [31:0]    sec_lba,
	output reg  [15:0]    sec_cnt,
	input       [7:0]     sec_q,
	input                 sec_qv,
	output      [7:0]     sec_d,       // = dbuf_q (the current write-stream byte)
	output reg           sec_dv,       // 1 = sec_d valid; consumed when sec_dv & sec_wr_rdy
	input                 sec_wr_rdy,  // sink ready/ack for a write byte
	input                 sec_done,
	input       [31:0]    disk_blocks, // capacity from the mounted image (0 => default)

	output               wr_busy,     // 1 = DATA OUT flush to HPS in progress
	output reg           busy
);

localparam
	OP_TUR       = 8'h00,
	OP_REZERO    = 8'h01,
	OP_REQSENSE  = 8'h03,
	OP_READ6     = 8'h08,
	OP_WRITE6    = 8'h0a,
	OP_INQUIRY   = 8'h12,
	OP_MODESENSE = 8'h1a,
	OP_STARTSTOP = 8'h1b,
	OP_READCAP   = 8'h25,
	OP_READ10    = 8'h28,
	OP_WRITE10   = 8'h2a;

localparam STAT_GOOD = 8'h00, STAT_CHECK = 8'h02;

localparam [31:0] DISK_BLOCKS_DEF = 32'd131072;   // 64 MB / 512, used if no image
localparam [31:0] BLOCK_SIZE  = 32'd512;
wire [31:0] DISK_BLOCKS = (disk_blocks == 32'd0) ? DISK_BLOCKS_DEF : disk_blocks;

// data buffer ----------------------------------------------------------
// EXACTLY one write port + one registered read port so it maps to M10K.
// Two async / multi-block reads earlier duplicated the whole 4 KB array
// into ~33k flip-flops / ~18k ALMs (builds #12/#13). The read address is
// muxed - the DATA-OUT flush pointer while flushing, else the SIOP
// DATA-IN address; those phases never overlap. Read latency is 1 cycle:
// the SIOP DATA-IN loop has an explicit settle state (S_DIS), the
// DATA-OUT flush a present/advance micro-sequence.
localparam W_IDLE=1'b0, W_STREAM=1'b1;
reg             wst;
reg [BUFAW-1:0] wr_ptr;

reg [7:0] dbuf [0:(1<<BUFAW)-1];
reg [7:0] dbuf_q;

reg [BUFAW-1:0] fill;
reg             fill_we;
reg [7:0]       fill_d;

wire [BUFAW-1:0] dbuf_ra = (wst == W_STREAM) ? wr_ptr : buf_addr;
always @(posedge clk) begin
	if (buf_we)       dbuf[buf_addr] <= buf_wdata;   // SIOP DATA OUT writes
	else if (fill_we) dbuf[fill]     <= fill_d;      // response / sector fill
	dbuf_q <= dbuf[dbuf_ra];
end
assign buf_rdata = dbuf_q;
assign sec_d     = dbuf_q;

reg [7:0] sense_key, sense_asc, sense_ascq;

reg [7:0] c0,c1,c2,c3,c4,c5,c6,c7,c8,c9;
wire [31:0] lba10 = {c2,c3,c4,c5};
wire [15:0] cnt10 = {c7,c8};
wire [20:0] lba6  = {c1[4:0],c2,c3};
wire [15:0] cnt6  = (c4 == 0) ? 16'd256 : {8'd0,c4};

localparam
	T_IDLE=0, T_DECODE=1, T_FILL=2, T_RDSEC=3, T_DONE=4;
reg [2:0]  st;
reg [23:0] resp_len;
reg [7:0]  resp [0:63];
reg [5:0]  ri;
reg        started;

integer j;

// background DATA-OUT -> HPS flush: W_IDLE/W_STREAM, wst, wr_ptr declared
// with the dbuf block above.

always @(posedge clk) begin
	if (reset) begin
		st <= T_IDLE; rsp_ready <= 0; busy <= 0;
		sec_rd <= 0; fill_we <= 0;
		sense_key <= 0; sense_asc <= 0; sense_ascq <= 0;
	end
	else begin
		rsp_ready <= 0; sec_rd <= 0; fill_we <= 0;

		case (st)
		T_IDLE: if (cmd_stb) begin
			c0<=cdb0; c1<=cdb1; c2<=cdb2; c3<=cdb3; c4<=cdb4;
			c5<=cdb5; c6<=cdb6; c7<=cdb7; c8<=cdb8; c9<=cdb9;
			busy <= 1; st <= T_DECODE;
		end

		T_DECODE: begin
			for (j=0;j<64;j=j+1) resp[j] <= 8'h00;
			resp_len   <= 0;
			rsp_status <= STAT_GOOD;
			rsp_dir    <= 2'd0;
			ri <= 0; fill <= 0;
			case (c0)
			OP_TUR, OP_STARTSTOP, OP_REZERO: st <= T_DONE;

			OP_REQSENSE: begin
				resp[0]  <= 8'h70;
				resp[2]  <= sense_key;
				resp[7]  <= 8'h0a;
				resp[12] <= sense_asc;
				resp[13] <= sense_ascq;
				resp_len <= (c4 != 0 && c4 < 8'd18) ? {16'd0,c4} : 24'd18;
				rsp_dir  <= 2'd1;
				sense_key <= 0; sense_asc <= 0; sense_ascq <= 0;
				st <= T_FILL;
			end

			OP_INQUIRY: begin
				resp[0]  <= 8'h00;
				resp[2]  <= 8'h02;   // SCSI-2
				resp[3]  <= 8'h02;
				resp[4]  <= 8'd31;
				resp[8]<="M"; resp[9]<="i"; resp[10]<="S"; resp[11]<="T";
				resp[12]<="e"; resp[13]<="r"; resp[14]<=" "; resp[15]<=" ";
				resp[16]<="A"; resp[17]<="4"; resp[18]<="0"; resp[19]<="9";
				resp[20]<="1"; resp[21]<=" "; resp[22]<="H"; resp[23]<="D";
				resp[24]<=" "; resp[25]<=" "; resp[26]<=" "; resp[27]<=" ";
				resp[28]<=" "; resp[29]<=" "; resp[30]<=" "; resp[31]<=" ";
				resp[32]<="0"; resp[33]<="0"; resp[34]<="0"; resp[35]<="1";
				resp_len <= ({8'd0,c4} < 24'd36 && c4 != 0) ? {16'd0,c4} : 24'd36;
				rsp_dir  <= 2'd1;
				st <= T_FILL;
			end

			OP_READCAP: begin
				resp[0]<=(DISK_BLOCKS-1)>>24; resp[1]<=(DISK_BLOCKS-1)>>16;
				resp[2]<=(DISK_BLOCKS-1)>>8;  resp[3]<=(DISK_BLOCKS-1);
				resp[4]<=BLOCK_SIZE[31:24]; resp[5]<=BLOCK_SIZE[23:16];
				resp[6]<=BLOCK_SIZE[15:8];  resp[7]<=BLOCK_SIZE[7:0];
				resp_len <= 24'd8; rsp_dir <= 2'd1; st <= T_FILL;
			end

			OP_MODESENSE: begin
				resp[0]<=8'd11; resp[3]<=8'd8;
				resp[5]<=(DISK_BLOCKS)>>16; resp[6]<=(DISK_BLOCKS)>>8; resp[7]<=(DISK_BLOCKS);
				resp[9]<=BLOCK_SIZE[15:8]; resp[10]<=BLOCK_SIZE[7:0];
				resp_len <= ({8'd0,c4} < 24'd12 && c4 != 0) ? {16'd0,c4} : 24'd12;
				rsp_dir  <= 2'd1; st <= T_FILL;
			end

			OP_READ10, OP_READ6: begin
				sec_lba <= (c0==OP_READ10) ? lba10 : {11'd0,lba6};
				sec_cnt <= (c0==OP_READ10) ? cnt10 : cnt6;
				rsp_dir <= 2'd1;
				started <= 0;
				st <= T_RDSEC;
			end

			OP_WRITE10, OP_WRITE6: begin
				sec_lba <= (c0==OP_WRITE10) ? lba10 : {11'd0,lba6};
				sec_cnt <= (c0==OP_WRITE10) ? cnt10 : cnt6;
				rsp_dir <= 2'd2;
				rsp_len <= ((c0==OP_WRITE10) ? cnt10 : cnt6) * BLOCK_SIZE;
				st <= T_DONE;
			end

			default: begin
				rsp_status <= STAT_CHECK;
				sense_key  <= 8'h05;   // ILLEGAL REQUEST
				sense_asc  <= 8'h20;
				st <= T_DONE;
			end
			endcase
		end

		T_FILL: begin
			fill_we <= 1;
			fill    <= {{(BUFAW-6){1'b0}}, ri};
			fill_d  <= resp[ri];
			ri      <= ri + 1'b1;
			if ({18'd0,ri} + 24'd1 >= resp_len) begin
				rsp_len <= resp_len;
				st <= T_DONE;
			end
		end

		T_RDSEC: begin
			if (!started) begin sec_rd <= 1; started <= 1; fill <= 0; end
			if (sec_qv) begin fill_we <= 1; fill_d <= sec_q; end
			if (fill_we) fill <= fill + 1'b1;      // advance past the byte just stored
			if (sec_done) begin
				rsp_len <= sec_cnt * BLOCK_SIZE;
				st <= T_DONE;
			end
		end

		T_DONE: begin
			rsp_ready <= 1;
			busy      <= 0;
			st        <= T_IDLE;
		end
		endcase
	end
end

// -- DATA OUT flush: when the SIOP signals the DATA OUT move is done, stream
//    dbuf to the HPS via a valid/ready handshake (a4091_sd paces it, one
//    512 B block at a time). wr_busy holds the SIOP in its STATUS wait.
//    sec_d is a REGISTERED read of dbuf (keeps the 4 KB buffer a true BRAM,
//    no wide async mux on clk_sys); the handshake tolerates the 1-cycle
//    latency with a present/advance micro-sequence.
assign wr_busy = (wst != W_IDLE);
localparam WS_PRESENT = 1'b0, WS_ADVANCE = 1'b1;
reg wss;
always @(posedge clk) begin
	if (reset) begin
		wst <= W_IDLE; sec_wr <= 0; sec_dv <= 0; wss <= WS_PRESENT;
	end else begin
		sec_wr <= 0;
		case (wst)
		W_IDLE: begin
			sec_dv <= 0;
			if (data_out_done) begin
				sec_wr <= 1; wr_ptr <= 0;
				wss <= WS_ADVANCE;                // let dbuf_q settle for wr_ptr=0
				wst <= W_STREAM;
			end
		end
		W_STREAM: begin
			if (sec_done) begin wst <= W_IDLE; sec_dv <= 0; end
			else case (wss)
			WS_PRESENT: begin
				sec_dv <= 1'b1;                    // sec_d = dbuf_q = dbuf[wr_ptr]
				if (sec_dv && sec_wr_rdy) begin    // consumed -> advance
					sec_dv <= 1'b0;
					wr_ptr <= wr_ptr + 1'b1;       // dbuf_ra follows; dbuf_q updates next cyc
					wss    <= WS_ADVANCE;
				end
			end
			WS_ADVANCE: wss <= WS_PRESENT;         // 1 cycle for dbuf_q to catch wr_ptr
			endcase
		end
		endcase
	end
end

endmodule
`default_nettype wire
