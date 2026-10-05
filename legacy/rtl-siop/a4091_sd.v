// ===========================================================================
// a4091_sd - bridge the a4091_target `sec_*` sector port to a block server
//            reached over Minimig's `hps_ext` UIO extension (commands
//            'h64/'h65/'h66; Main_MiSTer a4091_sd_poll()).
//
// The generic hps_io SD-sector loop (UIO_SECTOR_RD/WR) is NOT polled for the
// Minimig core, so a plain hps_io virtual-drive slot never gets serviced.
// hps_ext IS polled (is_minimig() branch of user_io_poll), so the A4091
// sector mailbox rides on it.
//
//   a4091 side (all clk_sys):
//     sec_rd  pulse  -> read  sec_cnt sectors @ sec_lba -> sec_q/sec_qv stream
//     sec_wr  pulse  -> write sec_cnt sectors @ sec_lba <- sec_d/sec_dv,
//                       paced by sec_wr_rdy (drops while a block is flushing)
//     sec_done pulse -> whole transfer complete
//   server side (hps_ext): sees sd_rd|sd_wr + sd_lba held; fills / drains the
//     512 B buffer via sd_buff_*; then pulses blk_done for that one block.
//
// ONE 512 B block in flight:
//   blk_rd : BRAM     - server write (sd_buff_wr) -> registered read to sec_q
//   blk_wr : LUT RAM  - sec_d capture             -> async read to sd_buff_din
// ===========================================================================
`default_nettype none

module a4091_sd
(
	input             clk,           // clk_sys
	input             reset,
	input             ena,           // 0 -> fully inert: FSM held, all outputs idle

	// ---- a4091_target sector port -------------------------------------
	input             sec_rd,
	input             sec_wr,
	input      [31:0]  sec_lba,
	input      [15:0]  sec_cnt,
	output reg [7:0]   sec_q,
	output reg        sec_qv,
	input      [7:0]   sec_d,
	input             sec_dv,
	output reg        sec_wr_rdy,
	output reg        sec_done,

	// ---- image geometry (-> a4091_target READ CAPACITY / MODE SENSE) --
	input             img_mounted,
	input      [63:0]  img_size,
	output reg        img_present,
	output reg [31:0]  disk_blocks,

	// ---- block server (hps_ext) ------------------------------------
	output reg [31:0]  sd_lba,
	output reg        sd_rd,          // level: read this block, held until blk_done
	output reg        sd_wr,          // level: write this block, held until blk_done
	input             blk_done,       // pulse: the 512 B buffer transfer finished
	input      [8:0]   sd_buff_addr,
	input      [7:0]   sd_buff_dout,   // server -> FPGA
	output     [7:0]   sd_buff_din,    // FPGA -> server
	input             sd_buff_wr
);

// ---- mounted-image bookkeeping ------------------------------------------
always @(posedge clk) begin
	if (reset | ~ena) begin
		img_present <= 1'b0;
		disk_blocks <= 32'd0;
	end
	else if (img_mounted) begin
		img_present <= (img_size != 64'd0);
		disk_blocks <= img_size[40:9];        // bytes / 512
	end
end

// ---- block buffers (512 B) -----------------------------------------
reg [7:0] blk_rd [0:511];
reg [7:0] blk_wr [0:511];
reg [8:0] sp;

always @(posedge clk) if (ena & sd_buff_wr) blk_rd[sd_buff_addr] <= sd_buff_dout;
assign sd_buff_din = ena ? blk_wr[sd_buff_addr] : 8'd0;

// ---- transfer FSM ----------------------------------------------------
localparam S_IDLE    = 4'd0,
           S_RD_REQ  = 4'd1,
           S_RD_WAIT = 4'd2,
           S_RD_STR  = 4'd3,
           S_WR_FILL = 4'd4,
           S_WR_REQ  = 4'd5,
           S_WR_WAIT = 4'd6,
           S_DONE    = 4'd7;

reg [3:0]  st;
reg [31:0] lba;
reg [15:0] cnt, idx;

always @(posedge clk) begin
	sec_qv   <= 1'b0;
	sec_done <= 1'b0;

	if (reset | ~ena) begin
		st <= S_IDLE; sd_rd <= 0; sd_wr <= 0; sec_wr_rdy <= 0; sd_lba <= 0;
	end
	else case (st)

	S_IDLE: begin
		sd_rd <= 0; sd_wr <= 0; sec_wr_rdy <= 0;
		idx <= 0; sp <= 0;
		lba <= sec_lba;
		cnt <= (sec_cnt == 0) ? 16'd1 : sec_cnt;
		if      (sec_rd) st <= S_RD_REQ;
		else if (sec_wr) begin sec_wr_rdy <= 1'b1; st <= S_WR_FILL; end
	end

	// ---- READ: one block per iteration -------------------------
	S_RD_REQ: begin
		sd_lba <= lba + {16'd0, idx};
		sd_rd  <= 1'b1;
		st     <= S_RD_WAIT;
	end
	S_RD_WAIT: if (blk_done) begin      // block now sitting in blk_rd
		sd_rd <= 1'b0;
		sp    <= 0;
		st    <= S_RD_STR;
	end
	S_RD_STR: begin
		sec_q  <= blk_rd[sp];
		sec_qv <= 1'b1;
		sp     <= sp + 1'b1;
		if (sp == 9'd511) begin
			if (idx + 1'b1 == cnt) st <= S_DONE;
			else begin idx <= idx + 1'b1; st <= S_RD_REQ; end
		end
	end

	// ---- WRITE: capture one block (valid/ready), flush, repeat -
	S_WR_FILL: if (sec_dv) begin        // sec_wr_rdy is 1 here -> handshake
		blk_wr[sp] <= sec_d;
		if (sp == 9'd511) begin
			sec_wr_rdy <= 1'b0;         // stop the source, go flush
			st <= S_WR_REQ;
		end
		else sp <= sp + 1'b1;
	end
	S_WR_REQ: begin
		sd_lba <= lba + {16'd0, idx};
		sd_wr  <= 1'b1;
		st     <= S_WR_WAIT;
	end
	S_WR_WAIT: if (blk_done) begin      // block taken from blk_wr
		sd_wr <= 1'b0;
		if (idx + 1'b1 == cnt) st <= S_DONE;
		else begin
			idx <= idx + 1'b1;
			sp  <= 0;
			sec_wr_rdy <= 1'b1;
			st <= S_WR_FILL;
		end
	end

	S_DONE: begin
		sec_done   <= 1'b1;
		sec_wr_rdy <= 1'b0;
		st         <= S_IDLE;
	end

	default: st <= S_IDLE;
	endcase
end

endmodule
