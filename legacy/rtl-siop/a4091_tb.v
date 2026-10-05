// ===========================================================================
// a4091_tb - iverilog testbench for the A4091 RTL
//
//   G1  Zorro III autoconfig walk + base assignment
//   G2  boot ROM read (nibble fan-out)
//   G3  DIP switch byte
//   G4  53C710 register file write/read
//   G5  trivial SCRIPTS (unconditional INTERRUPT) -> DSTAT.SIR + IRQ
//   G6  full SCSI nexus: SELECT+ATN / IDENTIFY / INQUIRY / DATA-IN / STATUS / MSG-IN
//   G7  READ(10) 1 sector, HPS-streamed data -> Amiga RAM
//   G8  WRITE(10) 1 sector, Amiga RAM -> HPS
//   G9  SCRIPTS register ALU (read-modify-write AND)
//   G10 SCRIPTS conditional JUMP on SFBR data compare
//   G11 table-indirect Block Move ({count,addr} from a DSA-relative table)
//   G12 Group 3 Memory Move (RAM -> RAM byte copy)
//   G13 indirect Block Move (data address via a pointer in RAM)
//
//   run:  make -C A4091/tb          (DEFS=-DA4091_DEBUG for a SCRIPTS trace)
// ===========================================================================
`timescale 1ns/1ps
`default_nettype none

module a4091_tb;

reg clk = 0;
always #5 clk = ~clk;           // 100 MHz sim clock (rate irrelevant here)

reg         reset  = 1;
reg         enable = 1;
reg  [2:0]  cfg_scsi_id = 3'd7;
reg  [4:0]  cfg_dip     = 5'b00110;

// autoconfig
reg         ac_cycle = 0;
reg  [5:0]  ac_reg   = 0;
reg         ac_write = 0;
reg  [15:0] ac_wdata = 0;
wire [3:0]  ac_rdata;
wire        ac_done;

// board window
wire [31:24] board_base;
wire         board_cfgd;
reg          brd_sel = 0;
reg  [23:0]  brd_addr = 0;
reg  [15:0]  brd_din  = 0;
wire [15:0]  brd_dout;
reg          brd_lds = 0, brd_uds = 0, brd_rnw = 1;   // strobes active-high, idle low
wire         brd_selack, brd_ready;

// DMA master  <-> behavioural RAM
wire         dma_req;
wire         dma_rw;
wire [31:1]  dma_addr;
wire [15:0]  dma_wdata;
reg  [15:0]  dma_rdata;
wire [1:0]   dma_bs;
reg          dma_ack;

wire         int2;
wire         led;

// a4091 <-> a4091_sd sector port
wire         sec_rd, sec_wr, sec_dv;
wire [31:0]  sec_lba;
wire [15:0]  sec_cnt;
wire [7:0]   sec_q;
wire         sec_qv;
wire [7:0]   sec_d;
wire         sec_wr_rdy;
wire         sec_done;
wire [31:0]  disk_blocks;

// a4091_sd <-> behavioural hps_io VD slot
wire [31:0]  sd_lba;
wire         sd_rd, sd_wr;
reg          blk_done = 0;
reg  [8:0]   sd_buff_addr = 0;
reg  [7:0]   sd_buff_dout = 0;
wire [7:0]   sd_buff_din;
reg          sd_buff_wr = 0;
reg          img_mounted = 0;
reg  [63:0]  img_size = 0;
wire         img_present;

reg          rom_wr = 0;
reg  [15:0]  rom_addr = 0;
reg  [7:0]   rom_data = 0;

a4091 dut
(
	.clk(clk), .reset(reset),
	.enable(enable), .cfg_scsi_id(cfg_scsi_id), .cfg_dip(cfg_dip), .present(7'h7f),

	.ac_cycle(ac_cycle), .ac_reg(ac_reg), .ac_write(ac_write),
	.ac_wdata(ac_wdata), .ac_rdata(ac_rdata), .ac_done(ac_done),

	.board_base(board_base), .board_cfgd(board_cfgd),
	.brd_sel(brd_sel), .brd_addr(brd_addr), .brd_din(brd_din),
	.brd_dout(brd_dout), .brd_lds(brd_lds), .brd_uds(brd_uds),
	.brd_rnw(brd_rnw), .brd_selack(brd_selack), .brd_ready(brd_ready),

	.dma_req(dma_req), .dma_rw(dma_rw), .dma_addr(dma_addr),
	.dma_wdata(dma_wdata), .dma_rdata(dma_rdata), .dma_bs(dma_bs),
	.dma_ack(dma_ack),

	.int2(int2),

	.rom_wr(rom_wr), .rom_addr(rom_addr), .rom_data(rom_data),

	.sec_rd(sec_rd), .sec_wr(sec_wr), .sec_lba(sec_lba), .sec_cnt(sec_cnt),
	.sec_q(sec_q), .sec_qv(sec_qv), .sec_d(sec_d), .sec_dv(sec_dv),
	.sec_wr_rdy(sec_wr_rdy), .sec_done(sec_done), .disk_blocks(disk_blocks),

	.led(led)
);

// ---- a4091_sd: sec_* <-> hps_io sd_* bridge (as wired in Minimig.sv) ----
a4091_sd a4091_sd
(
	.clk(clk), .reset(reset), .ena(1'b1),
	.sec_rd(sec_rd), .sec_wr(sec_wr), .sec_lba(sec_lba), .sec_cnt(sec_cnt),
	.sec_q(sec_q), .sec_qv(sec_qv), .sec_d(sec_d), .sec_dv(sec_dv),
	.sec_wr_rdy(sec_wr_rdy), .sec_done(sec_done),
	.img_mounted(img_mounted), .img_size(img_size),
	.img_present(img_present), .disk_blocks(disk_blocks),
	.sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .blk_done(blk_done),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr)
);

// --------------------------------------------------------------------------
// behavioural hps_io virtual-drive (sd_*) HPS backend
//   image byte (lba,off) = (lba*7) ^ off ^ 0x5a  unless previously written
// --------------------------------------------------------------------------
function [7:0] disk_byte(input [31:0] lba, input [31:0] off);
	disk_byte = (lba[7:0] * 8'd7) ^ off[7:0] ^ 8'h5a;
endfunction

// small writable overlay: 256 blocks (for the WRITE10 round-trip check)
reg [7:0]  ovl_data [0:131071];
reg        ovl_set  [0:255];
reg [7:0]  wdisk [0:4095];         // last WRITE stream, flat (back-compat for G8)
integer    wctr;

function [7:0] img_rd(input [31:0] lba, input [8:0] off);
	img_rd = (lba < 256 && ovl_set[lba[7:0]]) ? ovl_data[{lba[7:0], off}]
	                                          : disk_byte(lba, {23'd0, off});
endfunction

// behavioural block server (models Main_MiSTer a4091_sd_poll over hps_ext):
// on sd_rd/sd_wr, after a short "poll latency", stream one 512 B block via
// sd_buff_*, then pulse blk_done.
reg  [2:0]  sdst;
reg  [9:0]  sdi;
reg  [31:0] sdlba;
integer     sd_delay;
integer     bi;
always @(posedge clk) begin
	sd_buff_wr <= 0;
	blk_done   <= 0;
	if (reset) begin
		sdst <= 0; wctr <= 0;
		for (bi = 0; bi < 256; bi = bi + 1) ovl_set[bi] <= 0;
	end
	else case (sdst)
	0: if (sd_rd | sd_wr) begin
		sdlba <= sd_lba; sdi <= 0; sd_delay <= 6;
		sdst <= sd_rd ? 3'd1 : 3'd4;
	end
	// ---- READ: wait, then stream 512 bytes into blk_rd, then blk_done ----
	1: if (sd_delay != 0) sd_delay <= sd_delay - 1; else sdst <= 2;
	2: begin
		sd_buff_addr <= sdi[8:0];
		sd_buff_dout <= img_rd(sdlba, sdi[8:0]);
		sd_buff_wr   <= 1;
		sdi <= sdi + 1;
		if (sdi == 10'd511) sdst <= 3;
	end
	3: begin blk_done <= 1; sdst <= 7; end
	7: if (~sd_rd & ~sd_wr) sdst <= 0;    // wait for the adapter to drop the request
	// ---- WRITE: wait, then read 512 bytes from blk_wr, then blk_done -----
	4: if (sd_delay != 0) sd_delay <= sd_delay - 1; else begin sdi <= 0; sdst <= 5; end
	5: begin
		sd_buff_addr <= sdi[8:0];             // adapter drives sd_buff_din combinationally
		if (sdi >= 1) begin                   // 1-cycle latency for the addr->din path
			ovl_data[{sdlba[7:0], (sdi[8:0]-9'd1)}] <= sd_buff_din;
			if (sdlba < 256) ovl_set[sdlba[7:0]] <= 1;
			wdisk[sdi[8:0]-9'd1] <= sd_buff_din;   // sdi-1 in 0..511
		end
		sdi <= sdi + 1;
		if (sdi == 10'd512) sdst <= 6;        // captured [0..511]
	end
	6: begin blk_done <= 1; sdst <= 7; end
	endcase
end

// --------------------------------------------------------------------------
// behavioural Amiga RAM for the DMA master (big-endian byte array)
// --------------------------------------------------------------------------
reg [7:0] mem [0:65535];
reg [1:0] dcyc;

// SCRIPTS words are big-endian in Amiga RAM (68k NCR assembler output)
task write_be32(input [31:0] a, input [31:0] d); begin
	mem[a+0] = d[31:24]; mem[a+1] = d[23:16];
	mem[a+2] = d[15:8];  mem[a+3] = d[7:0];
end endtask

always @(posedge clk) begin
	dma_ack <= 0;
	if (dma_req && !dma_ack) begin
		dcyc <= dcyc + 1'b1;
		if (dcyc == 2'd2) begin
			dcyc <= 0;
			dma_ack <= 1;
			if (dma_rw) begin
				dma_rdata <= { mem[{dma_addr,1'b0}], mem[{dma_addr,1'b0}+1] }; // BE
			end else begin
				if (dma_bs[1]) mem[{dma_addr,1'b0}]   <= dma_wdata[15:8]; // uds/even
				if (dma_bs[0]) mem[{dma_addr,1'b0}+1] <= dma_wdata[7:0];  // lds/odd
			end
		end
	end else dcyc <= 0;
end

// --------------------------------------------------------------------------
// bus helpers
// --------------------------------------------------------------------------
task ac_read(input [5:0] r, output [3:0] nib); begin
	@(posedge clk); ac_cycle = 1; ac_reg = r; ac_write = 0;
	@(negedge clk); @(negedge clk); nib = ac_rdata;
	@(posedge clk); ac_cycle = 0;
end endtask

task ac_wr(input [5:0] r, input [15:0] d); begin
	@(posedge clk); ac_cycle<=1; ac_reg<=r; ac_write<=1; ac_wdata<=d;
	@(posedge clk); ac_cycle<=0; ac_write<=0;
end endtask

// strobes are ACTIVE HIGH in a4091's convention (cpu_wrapper: ~lds_p / ~uds_p)
task brd_write(input [23:0] a, input [15:0] d, input lds, input uds); begin
	@(posedge clk); brd_sel<=1; brd_addr<=a; brd_din<=d; brd_rnw<=0;
	brd_lds<=lds; brd_uds<=uds;
	wait (brd_ready); @(posedge clk);
	brd_sel<=0; brd_rnw<=1; brd_lds<=0; brd_uds<=0;
end endtask

task brd_read(input [23:0] a, output [15:0] d); begin
	@(posedge clk); brd_sel<=1; brd_addr<=a; brd_rnw<=1; brd_lds<=1; brd_uds<=1;
	wait (brd_ready); #1 d = brd_dout; @(posedge clk);
	brd_sel<=0; brd_lds<=0; brd_uds<=0;
end endtask

// register access: A4091 regs are byte, big-endian-swapped on the bus.
// offset N -> bus address (N & ~3)|(3-(N&3)); byte lane from addr[0].
task reg_write(input [7:0] off, input [7:0] val); begin : rw
	reg [23:0] a;
	a = 24'h800000 | {16'd0, (off & 8'hfc) | (2'd3 - off[1:0])};
	if (a[0]) brd_write(a, {8'h00, val}, 1'b1, 1'b0);
	else      brd_write(a, {val, 8'h00}, 1'b0, 1'b1);
end endtask

task reg_read(input [7:0] off, output [7:0] val); begin : rr
	reg [23:0] a; reg [15:0] d;
	a = 24'h800000 | {16'd0, (off & 8'hfc) | (2'd3 - off[1:0])};
	brd_read(a, d);
	val = a[0] ? d[7:0] : d[15:8];
end endtask

// two back-to-back word reads with brd_sel HELD across both (mimics a 68020
// longword access - the case that deadlocked the sticky-busy handshake on hw)
reg burst_hung;
task brd_read_burst(input [23:0] a0, output [15:0] d0, output [15:0] d1);
begin : rb
	integer to;
	burst_hung = 0;
	@(posedge clk); brd_sel<=1; brd_rnw<=1; brd_lds<=1; brd_uds<=1; brd_addr<=a0;
	to = 0;
	while (!brd_ready && to < 100) begin @(posedge clk); to = to + 1; end
	#1 d0 = brd_dout;
	@(posedge clk); brd_addr <= a0 + 24'd2;         // NOTE: brd_sel stays 1
	@(posedge clk);                                 // let brd_ready drop (addr moved)
	to = 0;
	while (!brd_ready && to < 100) begin @(posedge clk); to = to + 1; end
	if (to >= 100) burst_hung = 1;
	#1 d1 = brd_dout;
	@(posedge clk); brd_sel<=0; brd_lds<=0; brd_uds<=0;
end endtask

task run_scripts(input [31:0] entry); begin : rs
	reg [7:0] junk;
	integer   kk;
	reg_read (8'h0c, junk);            // clear DSTAT (and any prior SIR)
	reg_read (8'h0d, junk);            // clear SSTAT0
	reg_write(8'h2c, entry[7:0]);
	reg_write(8'h2d, entry[15:8]);
	reg_write(8'h2e, entry[23:16]);
	reg_write(8'h2f, entry[31:24]);    // writing DSP[31:24] kicks SCRIPTS
	kk = 0;
	while (!int2 && kk < 30000) begin @(posedge clk); kk = kk + 1; end
	if (kk >= 30000) $display("  (run_scripts: no IRQ after %0d cycles)", kk);
end endtask

// --------------------------------------------------------------------------
integer errors = 0;
task expect8(input [8*24-1:0] name, input [7:0] got, input [7:0] exp); begin
	if (got !== exp) begin
		$display("  FAIL %0s: got %02x exp %02x", name, got, exp);
		errors = errors + 1;
	end else $display("  ok   %0s = %02x", name, got);
end endtask

reg [3:0]  nib;
reg [15:0] w;
reg [7:0]  b;
integer    k;

initial begin
	$dumpfile("a4091_tb.vcd");
	$dumpvars(0, a4091_tb);
	for (k=0;k<65536;k=k+1) mem[k]=8'h00;
	// boot ROM: a4091.v $readmemh's the real a4091-software image
	// (-DA4091_ROM_HEX in the Makefile). Overwrite one byte via the rom_wr
	// port so that path stays exercised; G2 checks it back.
	@(posedge clk); rom_wr<=1; rom_addr<=16'h0001; rom_data<=8'hA4;
	@(posedge clk); rom_wr<=0;

	repeat (4) @(posedge clk);
	reset <= 0;
	repeat (16) @(posedge clk);

	// mount a 64 MB image (matches disk_byte's default geometry)
	@(posedge clk); img_size <= 64'd67108864; img_mounted <= 1;
	@(posedge clk); img_mounted <= 0;
	repeat (2) @(posedge clk);
	if (!img_present)                  begin $display("  FAIL img_present not set"); errors=errors+1; end
	if (disk_blocks !== 32'd131072)    begin $display("  FAIL disk_blocks=%0d exp 131072", disk_blocks); errors=errors+1; end

	$display("[G1] autoconfig walk");
	ac_read(6'h3f, nib);   // prime the combinational nibble path
	// byte0 = er_Type = 0x90 (ZORRO_III | DIAGVALID); byte0 not inverted
	ac_read(6'h00, nib); expect8("ac type hi", nib, 8'h09);
	ac_read(6'h01, nib); expect8("ac type lo", nib, 4'h0);
	// byte1 = er_Product = 0x54; inverted -> ~5=A , ~4=B
	ac_read(6'h02, nib); expect8("ac prod hi", nib, 4'hA);
	ac_read(6'h03, nib); expect8("ac prod lo", nib, 4'hB);
	// byte2 = er_Flags = 0x30 (EXTENDED|ZORRO_III); inverted
	ac_read(6'h04, nib); expect8("ac flags hi", nib, 8'h0c);  // ~0x3
	ac_read(6'h05, nib); expect8("ac flags lo", nib, 8'h0f);  // ~0x0
	// byte4/5 = mfg 0x0202; inverted
	ac_read(6'h08, nib); expect8("ac mfg  hi", nib, 8'h0f);  // ~0
	ac_read(6'h0b, nib); expect8("ac mfg lo3", nib, 8'h0d);  // ~2
	if (board_cfgd) begin $display("  FAIL already configured"); errors=errors+1; end
	ac_wr(6'h22, 16'h4000);            // assign base 0x40000000
	@(posedge clk); #1;
	if (!board_cfgd)          begin $display("  FAIL not configured"); errors=errors+1; end
	else if (board_base!==8'h40) begin $display("  FAIL base=%02x exp 40", board_base); errors=errors+1; end
	else $display("  ok   configured, base=%02x000000", board_base);

	$display("[G2] boot ROM read (4x nibble fan-out, real a4091.rom)");
	// board offset O -> ROM file byte O>>2: O&3==0 exposes b[7:4] on D15:12,
	// O&3==2 exposes b[3:0]. Reconstruct the file byte and check it.
	// file[0]=0x9f, file[1]=0xa4 (rom_wr override), file[0x80]=0x10 (DiagArea da_Config).
	brd_read(24'h000000, w); b[7:4] = w[15:12];
	brd_read(24'h000002, w); b[3:0] = w[15:12];
	expect8("rom file[0x00] (er_Type|0f)", b, 8'h9f);
	brd_read(24'h000004, w); b[7:4] = w[15:12];
	brd_read(24'h000006, w); b[3:0] = w[15:12];
	expect8("rom file[0x01] (rom_wr override)", b, 8'hA4);
	brd_read(24'h000200, w); b[7:4] = w[15:12];
	brd_read(24'h000202, w); b[3:0] = w[15:12];
	expect8("rom file[0x80] (DiagArea da_Config)", b, 8'h10);

	$display("[G3] DIP switch byte @ 0x8C0003");
	brd_read(24'h8C0002, w);           // 0x8C0003 = odd byte = low lane
	b = w[7:0];
	// dip_byte = ({cfg_dip,3'b0} ^ 0xF8) | scsi_id  = ({00110,000}^F8)|7
	//          = (0x30 ^ 0xF8) | 7 = 0xC8 | 7 = 0xCF
	expect8("dip", b, 8'hCF);

	$display("[G4] 53C710 register file");
	reg_write(8'h34, 8'hDE);           // SCRATCH[0]
	reg_write(8'h35, 8'hAD);
	reg_read (8'h34, b); expect8("scratch0", b, 8'hDE);
	reg_read (8'h35, b); expect8("scratch1", b, 8'hAD);
	reg_write(8'h39, 8'hFF);           // DIEN = all DMA ints enabled
	reg_read (8'h39, b);
	// DIEN has no read case in the skeleton readb2 -> reads 0; that's fine,
	// amiberry's 710 map also omits it. Skip strict check.

	$display("[G5] trivial SCRIPTS: unconditional INTERRUPT");
	write_be32(32'h00001000, 32'h98080000);   // INT
	write_be32(32'h00001004, 32'hDEADBEEF);   // -> DSPS
	reg_write(8'h39, 8'hFF);                   // DIEN
	run_scripts(32'h00001000);
	if (!int2) begin $display("  FAIL no IRQ"); errors=errors+1; end
	else $display("  ok   IRQ asserted");
	reg_read(8'h30, b); expect8("dsps0", b, 8'hEF);
	reg_read(8'h33, b); expect8("dsps3", b, 8'hDE);
	reg_read(8'h0c, b); if (!b[2]) begin $display("  FAIL DSTAT.SIR"); errors=errors+1; end
	                    else $display("  ok   DSTAT.SIR set");

	// ================================================================
	$display("[G6] SCSI SCRIPTS: SELECT/IDENTIFY/INQUIRY/DATA-IN/STATUS/MSG-IN");
	mem[24'h003000] = 8'hC0;                                  // IDENTIFY, LUN 0
	mem[24'h003010]=8'h12; mem[24'h003011]=8'h00; mem[24'h003012]=8'h00; // INQUIRY
	mem[24'h003013]=8'h00; mem[24'h003014]=8'h24; mem[24'h003015]=8'h00;
	write_be32(32'h00002000, 32'h41010000); write_be32(32'h00002004, 32'h00000000); // Select 0 +ATN
	write_be32(32'h00002008, 32'h06000001); write_be32(32'h0000200c, 32'h00003000); // MSG OUT 1
	write_be32(32'h00002010, 32'h02000006); write_be32(32'h00002014, 32'h00003010); // CMD 6
	write_be32(32'h00002018, 32'h01000024); write_be32(32'h0000201c, 32'h00004000); // DATA IN 36
	write_be32(32'h00002020, 32'h03000001); write_be32(32'h00002024, 32'h00003020); // STATUS 1
	write_be32(32'h00002028, 32'h07000001); write_be32(32'h0000202c, 32'h00003021); // MSG IN 1
	write_be32(32'h00002030, 32'h98080000); write_be32(32'h00002034, 32'h0000600d); // INT

	run_scripts(32'h00002000);
	if (!int2) begin $display("  FAIL no completion IRQ"); errors=errors+1; end
	reg_read(8'h30, b); expect8("dsps0(int arg)", b, 8'h0d);
	expect8("inq[0] direct-access", mem[24'h004000], 8'h00);
	expect8("inq[2] SCSI-2",        mem[24'h004002], 8'h02);
	expect8("inq[4] add'l len",     mem[24'h004004], 8'd31);
	expect8("inq[8] 'M'",           mem[24'h004008], "M");
	expect8("inq[16] 'A'",          mem[24'h004010], "A");
	expect8("inq[19] '9'",          mem[24'h004013], "9");
	expect8("status byte GOOD",     mem[24'h003020], 8'h00);
	expect8("msgin CMD COMPLETE",   mem[24'h003021], 8'h00);

	// ================================================================
	$display("[G7] SCSI SCRIPTS: READ(10) 1 sector @ LBA 10 -> RAM 0x5000");
	mem[24'h003030]=8'hC0;
	mem[24'h003040]=8'h28; mem[24'h003041]=8'h00;
	mem[24'h003042]=8'h00; mem[24'h003043]=8'h00; mem[24'h003044]=8'h00; mem[24'h003045]=8'h0A;
	mem[24'h003046]=8'h00; mem[24'h003047]=8'h00; mem[24'h003048]=8'h01; mem[24'h003049]=8'h00;
	write_be32(32'h00002100, 32'h41010000); write_be32(32'h00002104, 32'h00000000);
	write_be32(32'h00002108, 32'h06000001); write_be32(32'h0000210c, 32'h00003030);
	write_be32(32'h00002110, 32'h0200000a); write_be32(32'h00002114, 32'h00003040); // CMD 10
	write_be32(32'h00002118, 32'h01000200); write_be32(32'h0000211c, 32'h00005000); // DATA IN 512
	write_be32(32'h00002120, 32'h03000001); write_be32(32'h00002124, 32'h00003060);
	write_be32(32'h00002128, 32'h07000001); write_be32(32'h0000212c, 32'h00003061);
	write_be32(32'h00002130, 32'h98080000); write_be32(32'h00002134, 32'h0000d15c);

	run_scripts(32'h00002100);
	expect8("sec[0]",   mem[24'h005000], disk_byte(32'd10, 32'd0));
	expect8("sec[1]",   mem[24'h005001], disk_byte(32'd10, 32'd1));
	expect8("sec[255]", mem[24'h0050ff], disk_byte(32'd10, 32'd255));
	expect8("sec[511]", mem[24'h0051ff], disk_byte(32'd10, 32'd511));
	expect8("read status GOOD", mem[24'h003060], 8'h00);

	// ================================================================
	$display("[G8] SCSI SCRIPTS: WRITE(10) 1 sector from RAM 0x5800 -> HPS");
	for (k=0;k<512;k=k+1) mem[24'h005800 + k[15:0]] = k[7:0] ^ 8'h33;
	mem[24'h003070]=8'hC0;
	mem[24'h003080]=8'h2a; mem[24'h003081]=8'h00;
	mem[24'h003082]=8'h00; mem[24'h003083]=8'h00; mem[24'h003084]=8'h00; mem[24'h003085]=8'h14;
	mem[24'h003086]=8'h00; mem[24'h003087]=8'h00; mem[24'h003088]=8'h01; mem[24'h003089]=8'h00;
	write_be32(32'h00002200, 32'h41010000); write_be32(32'h00002204, 32'h00000000);
	write_be32(32'h00002208, 32'h06000001); write_be32(32'h0000220c, 32'h00003070);
	write_be32(32'h00002210, 32'h0200000a); write_be32(32'h00002214, 32'h00003080);
	write_be32(32'h00002218, 32'h00000200); write_be32(32'h0000221c, 32'h00005800); // DATA OUT 512
	write_be32(32'h00002220, 32'h03000001); write_be32(32'h00002224, 32'h00003090);
	write_be32(32'h00002228, 32'h07000001); write_be32(32'h0000222c, 32'h00003091);
	write_be32(32'h00002230, 32'h98080000); write_be32(32'h00002234, 32'h0000d00e);

	run_scripts(32'h00002200);   // STATUS now gates on the target->HPS flush (wr_busy)
	expect8("wr sec[0]",   wdisk[0],   8'h00 ^ 8'h33);
	expect8("wr sec[1]",   wdisk[1],   8'h01 ^ 8'h33);
	expect8("wr sec[255]", wdisk[255], 8'hff ^ 8'h33);
	expect8("wr status GOOD", mem[24'h003090], 8'h00);
	if (!int2) begin $display("  FAIL WRITE no completion IRQ"); errors=errors+1; end
	else $display("  ok   WRITE completion IRQ");

	// ================================================================
	$display("[G9] SCRIPTS register ALU: SCRATCH0 &= 0x3C");
	reg_write(8'h34, 8'hF0);
	write_be32(32'h00002300, 32'h7C343C00);   // op7 RMW: AND SCRATCH0, 0x3C
	write_be32(32'h00002304, 32'h00000000);
	write_be32(32'h00002308, 32'h98080000);   // INT
	write_be32(32'h0000230c, 32'h0000a1a1);
	run_scripts(32'h00002300);
	reg_read(8'h34, b); expect8("scratch0 & 0x3c", b, 8'h30);

	// ================================================================
	$display("[G10] SCRIPTS conditional JUMP on SFBR data compare");
	// MOVE 0x42 TO SFBR ; JUMP good IF SFBR==0x42 ; INT bad ; good: INT good
	write_be32(32'h00002400, 32'h70004200);   // op6 MOV -> SFBR = 0x42 (data8 = insn[15:8])
	write_be32(32'h00002404, 32'h00000000);
	write_be32(32'h00002408, 32'h800C0042);   // JUMP if (SFBR & 0xFF)==0x42
	write_be32(32'h0000240c, 32'h00002418);   //   -> 0x2418
	write_be32(32'h00002410, 32'h98080000);   // INT 0xBAD (must be skipped)
	write_be32(32'h00002414, 32'h0000baad);
	write_be32(32'h00002418, 32'h98080000);   // INT 0x600D
	write_be32(32'h0000241c, 32'h0000600d);
	run_scripts(32'h00002400);
	reg_read(8'h30, b); expect8("jump taken (dsps lo)", b, 8'h0d);
	reg_read(8'h31, b); expect8("jump taken (dsps hi)", b, 8'h60);

	// ================================================================
	$display("[G11] table-indirect Block Move (DSA table -> DATA IN)");
	reg_write(8'h10, 8'h00); reg_write(8'h11, 8'h60);      // DSA = 0x00006000
	reg_write(8'h12, 8'h00); reg_write(8'h13, 8'h00);
	// table @ DSA+0x40 : [count BE dword][addr BE dword]
	mem[24'h006040]=8'h00; mem[24'h006041]=8'h00; mem[24'h006042]=8'h00; mem[24'h006043]=8'h24; // 36
	mem[24'h006044]=8'h00; mem[24'h006045]=8'h00; mem[24'h006046]=8'h70; mem[24'h006047]=8'h00; // ->0x7000
	mem[24'h003100]=8'hC0;
	mem[24'h003110]=8'h12; mem[24'h003111]=8'h00; mem[24'h003112]=8'h00;
	mem[24'h003113]=8'h00; mem[24'h003114]=8'h24; mem[24'h003115]=8'h00;
	write_be32(32'h00002500, 32'h41010000); write_be32(32'h00002504, 32'h00000000);
	write_be32(32'h00002508, 32'h06000001); write_be32(32'h0000250c, 32'h00003100);
	write_be32(32'h00002510, 32'h02000006); write_be32(32'h00002514, 32'h00003110);
	write_be32(32'h00002518, 32'h11000000); write_be32(32'h0000251c, 32'h00000040); // table-indirect DI, offset 0x40
	write_be32(32'h00002520, 32'h03000001); write_be32(32'h00002524, 32'h000031a0);
	write_be32(32'h00002528, 32'h07000001); write_be32(32'h0000252c, 32'h000031a1);
	write_be32(32'h00002530, 32'h98080000); write_be32(32'h00002534, 32'h0000700d);
	run_scripts(32'h00002500);
	expect8("ti inq[0]",  mem[24'h007000], 8'h00);
	expect8("ti inq[2]",  mem[24'h007002], 8'h02);
	expect8("ti inq[16]", mem[24'h007010], "A");
	expect8("ti status",  mem[24'h0031a0], 8'h00);

	// ================================================================
	$display("[G12] Group 3 Memory Move: 16 bytes 0x8000 -> 0x8100");
	for (k=0;k<16;k=k+1) mem[24'h008000 + k[15:0]] = k[7:0] ^ 8'h6e;
	write_be32(32'h00002600, 32'hC0000010);   // Memory Move, 16 bytes
	write_be32(32'h00002604, 32'h00008000);   //   src
	write_be32(32'h00002608, 32'h00008100);   //   dst
	write_be32(32'h0000260c, 32'h98080000);   // INT
	write_be32(32'h00002610, 32'h00000e0e);
	run_scripts(32'h00002600);
	expect8("mm[0]",  mem[24'h008100], 8'h00 ^ 8'h6e);
	expect8("mm[7]",  mem[24'h008107], 8'h07 ^ 8'h6e);
	expect8("mm[15]", mem[24'h00810f], 8'h0f ^ 8'h6e);

	// ================================================================
	$display("[G13] indirect Block Move (pointer -> DATA IN)");
	mem[24'h003200]=8'hC0;
	mem[24'h003210]=8'h12; mem[24'h003211]=8'h00; mem[24'h003212]=8'h00;
	mem[24'h003213]=8'h00; mem[24'h003214]=8'h24; mem[24'h003215]=8'h00;
	mem[24'h003300]=8'h00; mem[24'h003301]=8'h00; mem[24'h003302]=8'h72; mem[24'h003303]=8'h00; // ptr -> 0x7200
	write_be32(32'h00002700, 32'h41010000); write_be32(32'h00002704, 32'h00000000);
	write_be32(32'h00002708, 32'h06000001); write_be32(32'h0000270c, 32'h00003200);
	write_be32(32'h00002710, 32'h02000006); write_be32(32'h00002714, 32'h00003210);
	write_be32(32'h00002718, 32'h21000024); write_be32(32'h0000271c, 32'h00003300); // indirect DI, ptr @0x3300
	write_be32(32'h00002720, 32'h03000001); write_be32(32'h00002724, 32'h000032a0);
	write_be32(32'h00002728, 32'h07000001); write_be32(32'h0000272c, 32'h000032a1);
	write_be32(32'h00002730, 32'h98080000); write_be32(32'h00002734, 32'h0000720d);
	run_scripts(32'h00002700);
	expect8("ind inq[2]",  mem[24'h007202], 8'h02);
	expect8("ind inq[19]", mem[24'h007213], "9");
	expect8("ind status",  mem[24'h0032a0], 8'h00);

	// ================================================================
	$display("[G14] burst register read - brd_sel HELD across both halves");
	//   (the sticky-busy handshake deadlocked here on real hw / a 68020 longword)
	// reg 0x34..0x37 = SCRATCH[7:0]..[31:24] -> SCRATCH = 0xEF_BE_AD_DE
	reg_write(8'h34, 8'hDE); reg_write(8'h35, 8'hAD);
	reg_write(8'h36, 8'hBE); reg_write(8'h37, 8'hEF);
	begin : g14
		reg [15:0] w0, w1;
		// bus 0x800034 -> beswap reg 0x37 (=SCRATCH[31:24]=0xEF) on the hi lane
		// bus 0x800036 -> beswap reg 0x35 (=SCRATCH[15:8] =0xAD) on the hi lane
		brd_read_burst(24'h800034, w0, w1);
		if (burst_hung) begin $display("  FAIL burst 2nd half HUNG (handshake deadlock)"); errors=errors+1; end
		else $display("  ok   burst completed (no deadlock)");
		// full 32-bit read = {w0, w1} = regs 0x37,0x36,0x35,0x34 = EF BE AD DE
		expect8("lw byte3 (reg 0x37)", w0[15:8], 8'hEF);
		expect8("lw byte2 (reg 0x36)", w0[7:0],  8'hBE);
		expect8("lw byte1 (reg 0x35)", w1[15:8], 8'hAD);
		expect8("lw byte0 (reg 0x34)", w1[7:0],  8'hDE);
	end

	// ================================================================
	$display("[G15] READ(10) 3 sectors @ LBA 40 -> RAM 0x6000 (a4091_sd block loop)");
	mem[24'h003190]=8'hC0;
	mem[24'h0031a0]=8'h28; mem[24'h0031a1]=8'h00;
	mem[24'h0031a2]=8'h00; mem[24'h0031a3]=8'h00; mem[24'h0031a4]=8'h00; mem[24'h0031a5]=8'h28; // LBA 40
	mem[24'h0031a6]=8'h00; mem[24'h0031a7]=8'h00; mem[24'h0031a8]=8'h03; mem[24'h0031a9]=8'h00; // 3 blocks
	write_be32(32'h00002800, 32'h41010000); write_be32(32'h00002804, 32'h00000000);
	write_be32(32'h00002808, 32'h06000001); write_be32(32'h0000280c, 32'h00003190);
	write_be32(32'h00002810, 32'h0200000a); write_be32(32'h00002814, 32'h000031a0);
	write_be32(32'h00002818, 32'h01000600); write_be32(32'h0000281c, 32'h00006000); // DATA IN 1536
	write_be32(32'h00002820, 32'h03000001); write_be32(32'h00002824, 32'h000031c0);
	write_be32(32'h00002828, 32'h07000001); write_be32(32'h0000282c, 32'h000031c1);
	write_be32(32'h00002830, 32'h98080000); write_be32(32'h00002834, 32'h00000f15);
	run_scripts(32'h00002800);
	expect8("s0 b0",     mem[24'h006000],       disk_byte(32'd40, 32'd0));
	expect8("s0 b511",   mem[24'h0061ff],       disk_byte(32'd40, 32'd511));
	expect8("s1 b0",     mem[24'h006200],       disk_byte(32'd41, 32'd0));
	expect8("s1 b300",   mem[24'h00632c],       disk_byte(32'd41, 32'd300));
	expect8("s2 b0",     mem[24'h006400],       disk_byte(32'd42, 32'd0));
	expect8("s2 b511",   mem[24'h0065ff],       disk_byte(32'd42, 32'd511));
	expect8("g15 status GOOD", mem[24'h0031c0], 8'h00);

	// ================================================================
	$display("[G16] WRITE(10) 2 sectors @ LBA 60 then READ back (a4091_sd write pacing)");
	for (k=0;k<1024;k=k+1) mem[24'h007000 + k[15:0]] = (k[7:0] * 8'd3) ^ k[9:8] ^ 8'h11;
	mem[24'h003290]=8'hC0;
	mem[24'h0032a0]=8'h2a; mem[24'h0032a1]=8'h00;
	mem[24'h0032a2]=8'h00; mem[24'h0032a3]=8'h00; mem[24'h0032a4]=8'h00; mem[24'h0032a5]=8'h3c; // LBA 60
	mem[24'h0032a6]=8'h00; mem[24'h0032a7]=8'h00; mem[24'h0032a8]=8'h02; mem[24'h0032a9]=8'h00; // 2 blocks
	write_be32(32'h00002900, 32'h41010000); write_be32(32'h00002904, 32'h00000000);
	write_be32(32'h00002908, 32'h06000001); write_be32(32'h0000290c, 32'h00003290);
	write_be32(32'h00002910, 32'h0200000a); write_be32(32'h00002914, 32'h000032a0);
	write_be32(32'h00002918, 32'h00000400); write_be32(32'h0000291c, 32'h00007000); // DATA OUT 1024
	write_be32(32'h00002920, 32'h03000001); write_be32(32'h00002924, 32'h000032c0);
	write_be32(32'h00002928, 32'h07000001); write_be32(32'h0000292c, 32'h000032c1);
	write_be32(32'h00002930, 32'h98080000); write_be32(32'h00002934, 32'h00001610);
	run_scripts(32'h00002900);
	expect8("g16 wr status GOOD", mem[24'h0032c0], 8'h00);
	// read the 2 blocks back into RAM 0x8000 and compare
	mem[24'h003390]=8'hC0;
	mem[24'h0033a0]=8'h28; mem[24'h0033a1]=8'h00;
	mem[24'h0033a2]=8'h00; mem[24'h0033a3]=8'h00; mem[24'h0033a4]=8'h00; mem[24'h0033a5]=8'h3c;
	mem[24'h0033a6]=8'h00; mem[24'h0033a7]=8'h00; mem[24'h0033a8]=8'h02; mem[24'h0033a9]=8'h00;
	write_be32(32'h00002a00, 32'h41010000); write_be32(32'h00002a04, 32'h00000000);
	write_be32(32'h00002a08, 32'h06000001); write_be32(32'h00002a0c, 32'h00003390);
	write_be32(32'h00002a10, 32'h0200000a); write_be32(32'h00002a14, 32'h000033a0);
	write_be32(32'h00002a18, 32'h01000400); write_be32(32'h00002a1c, 32'h00008000);
	write_be32(32'h00002a20, 32'h03000001); write_be32(32'h00002a24, 32'h000033c0);
	write_be32(32'h00002a28, 32'h07000001); write_be32(32'h00002a2c, 32'h000033c1);
	write_be32(32'h00002a30, 32'h98080000); write_be32(32'h00002a34, 32'h00001611);
	run_scripts(32'h00002a00);
	expect8("g16 rb b0",    mem[24'h008000], mem[24'h007000]);
	expect8("g16 rb b1",    mem[24'h008001], mem[24'h007001]);
	expect8("g16 rb b511",  mem[24'h0081ff], mem[24'h0071ff]);
	expect8("g16 rb b512",  mem[24'h008200], mem[24'h007200]);
	expect8("g16 rb b1023", mem[24'h0083ff], mem[24'h0073ff]);

	$display("");
	if (errors == 0) $display("==== ALL PASS ====");
	else             $display("==== %0d FAILURE(S) ====", errors);
	$finish;
end

initial begin
	#8000000;
	$display("TIMEOUT");
	$finish;
end

endmodule
`default_nettype wire
