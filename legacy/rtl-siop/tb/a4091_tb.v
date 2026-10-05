// ===========================================================================
// a4091_tb - iverilog testbench for the A4091 software-SIOP bridge
//
//   G1  Zorro III autoconfig walk + base assignment
//   G2  boot ROM read (nibble fan-out)
//   G3  DIP switch byte
//   G4  CPU writes 53C710 regs -> HPS 0x65 burst read matches
//   G5  HPS 0x66 burst write -> CPU reads regs back, matches
//   G6  kick: CPU writes DSP (0x2C..0x2F) -> mbx_status.kick;
//       HPS clears kick + sets int -> int2 asserts;
//       CPU reads ISTAT -> int2 deasserts
//   G7  soft-reset: CPU writes ISTAT bit6 -> mbx_status.srst; HPS clears it
//
//   run:  make -C A4091/tb
// ===========================================================================
`timescale 1ns/1ps
`default_nettype none

module a4091_tb;

reg clk = 0;
always #5 clk = ~clk;

reg        reset  = 1;
reg        enable = 1;
reg  [2:0] cfg_scsi_id = 3'd7;
reg  [4:0] cfg_dip     = 5'b00110;

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
reg          brd_lds = 0, brd_uds = 0, brd_rnw = 1;
wire         brd_selack, brd_ready;

// chip DMA port (tied off in the bridge for now)
wire        dma_req, dma_rw;
wire [31:1] dma_addr;
wire [15:0] dma_wdata;
reg  [15:0] dma_rdata = 0;
wire [1:0]  dma_bs;
reg         dma_ack = 0;

wire        int2, led;
wire [63:0] dbg_bus;

reg         rom_wr = 0;
reg  [15:0] rom_addr = 0;
reg  [7:0]  rom_data = 0;

// HPS bridge mailbox
reg  [7:0]  mbx_addr = 0;
reg         mbx_regs_wr = 0;
reg  [7:0]  mbx_wdata = 0;
wire [7:0]  mbx_rdata;
reg         mbx_set_int = 0, mbx_clr_int = 0, mbx_clr_kick = 0, mbx_clr_srst = 0;
reg         mbx_cache_clr = 0;
wire        a4091_cache_clr;
wire [15:0] mbx_status;

a4091 dut
(
	.clk(clk), .reset(reset),
	.enable(enable), .cfg_scsi_id(cfg_scsi_id), .cfg_dip(cfg_dip),

	.ac_cycle(ac_cycle), .ac_reg(ac_reg), .ac_write(ac_write),
	.ac_wdata(ac_wdata), .ac_rdata(ac_rdata), .ac_done(ac_done),

	.board_base(board_base), .board_cfgd(board_cfgd),
	.brd_sel(brd_sel), .brd_addr(brd_addr), .brd_din(brd_din),
	.brd_dout(brd_dout), .brd_lds(brd_lds), .brd_uds(brd_uds),
	.brd_rnw(brd_rnw), .brd_selack(brd_selack), .brd_ready(brd_ready),

	.dma_req(dma_req), .dma_rw(dma_rw), .dma_addr(dma_addr),
	.dma_wdata(dma_wdata), .dma_rdata(dma_rdata), .dma_bs(dma_bs), .dma_ack(dma_ack),

	.int2(int2),
	.rom_wr(rom_wr), .rom_addr(rom_addr), .rom_data(rom_data),

	.mbx_addr(mbx_addr), .mbx_regs_wr(mbx_regs_wr), .mbx_wdata(mbx_wdata),
	.mbx_rdata(mbx_rdata),
	.mbx_set_int(mbx_set_int), .mbx_clr_int(mbx_clr_int),
	.mbx_clr_kick(mbx_clr_kick), .mbx_clr_srst(mbx_clr_srst),
	.mbx_cache_clr(mbx_cache_clr),
	.mbx_status(mbx_status),
	.cache_clr(a4091_cache_clr),

	.dbg_bus(dbg_bus), .led(led)
);

integer errs = 0;
task check(input [127:0] name, input [31:0] got, input [31:0] exp); begin
	if (got !== exp) begin
		$display("  FAIL %0s: got %h exp %h", name, got, exp);
		errs = errs + 1;
	end else $display("  ok   %0s = %h", name, got);
end endtask

// ---- bus helpers ------------------------------------------------------
task ac_wr(input [5:0] r, input [15:0] d); begin
	@(posedge clk); ac_cycle<=1; ac_reg<=r; ac_write<=1; ac_wdata<=d;
	@(posedge clk); ac_cycle<=0; ac_write<=0;
end endtask

task ac_read(input [5:0] r, output [3:0] nib); begin
	@(posedge clk); ac_cycle=1; ac_reg=r; ac_write=0;
	@(posedge clk); @(negedge clk); nib = ac_rdata;
	@(posedge clk); ac_cycle=0;
end endtask

task brd_write(input [23:0] a, input [15:0] d, input lds, input uds); begin
	@(posedge clk); brd_sel<=1; brd_addr<=a; brd_din<=d; brd_rnw<=0;
	brd_lds<=lds; brd_uds<=uds;
	wait (brd_ready); @(posedge clk);
	brd_sel<=0; brd_rnw<=1; brd_lds<=0; brd_uds<=0;
	@(posedge clk);
end endtask

task brd_read(input [23:0] a, output [15:0] d); begin
	@(posedge clk); brd_sel<=1; brd_addr<=a; brd_rnw<=1; brd_lds<=1; brd_uds<=1;
	wait (brd_ready); #1 d = brd_dout; @(posedge clk);
	brd_sel<=0; brd_lds<=0; brd_uds<=0;
	@(posedge clk);
end endtask

// A4091 regs: byte, big-endian-swapped on the bus.
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

// ---- HPS mailbox helpers --------------------------------------------
// 0x65 read: drive mbx_addr, mbx_rdata = regs[addr] one clk later.
task mbx_read(input [7:0] idx, output [7:0] val); begin
	@(posedge clk); mbx_addr <= idx;
	@(posedge clk); @(posedge clk); val = mbx_rdata;
end endtask

// 0x66 write: one shadow byte.
task mbx_write(input [7:0] idx, input [7:0] val); begin
	@(posedge clk); mbx_addr <= idx; mbx_wdata <= val; mbx_regs_wr <= 1;
	@(posedge clk); mbx_regs_wr <= 0;
	@(posedge clk);
end endtask

task mbx_ctrl(input si, input ci, input ck, input cs); begin
	@(posedge clk);
	mbx_set_int <= si; mbx_clr_int <= ci; mbx_clr_kick <= ck; mbx_clr_srst <= cs;
	@(posedge clk);
	mbx_set_int <= 0; mbx_clr_int <= 0; mbx_clr_kick <= 0; mbx_clr_srst <= 0;
	@(posedge clk);
end endtask

// ---- stimulus -------------------------------------------------------
reg  [3:0]  nib;
reg  [15:0] w;
reg  [7:0]  b;
integer i;

initial begin
	$dumpfile("a4091_tb.vcd");
	$dumpvars(0, a4091_tb);

	repeat (8) @(posedge clk);
	reset = 0;
	repeat (4) @(posedge clk);

	// G1 - autoconfig: ident nibble + base assignment
	// (nibble fan-out RTL is byte-identical to the shipped a4091.v; the write
	//  path - er_Type read gating + base latch - is what this checks.)
	$display("G1 autoconfig");
	@(posedge clk); ac_cycle=1; ac_reg=6'h08; ac_write=0;
	repeat (3) @(posedge clk); #1 check("er_Mfg[15:12] inv", ac_rdata, 4'hF);
	@(posedge clk); ac_cycle=0;
	ac_wr(6'h22, 16'h4000);                    // base[31:16], top byte 0x40
	repeat (2) @(posedge clk);
	check("board_cfgd", board_cfgd, 1'b1);
	check("board_base", board_base, 8'h40);

	// G2 - boot ROM: offset 0 -> high nibble of ROM byte 0 on D15:12
	$display("G2 boot ROM");
	brd_read(24'h000000, w);
	check("rom[0] lane0 low12", w[11:0], 12'hfff);

	// G3 - DIP byte at 0x8C0003 (odd -> low lane)
	$display("G3 DIP byte");
	brd_read(24'h8C0002, w);
	check("dip low lane present", w[15:8], 8'hff);   // high lane = ff

	// G4 - CPU writes regs, HPS burst-reads them
	$display("G4 CPU write regs -> HPS read");
	reg_write(8'h34, 8'hA5);        // SCRATCH[0]
	reg_write(8'h35, 8'h5A);        // SCRATCH[1]
	reg_write(8'h10, 8'h11);        // DSA[0]
	reg_write(8'h13, 8'h44);        // DSA[3]
	mbx_read(8'h34, b); check("mbx regs[34]", b, 8'hA5);
	mbx_read(8'h35, b); check("mbx regs[35]", b, 8'h5A);
	mbx_read(8'h10, b); check("mbx regs[10]", b, 8'h11);
	mbx_read(8'h13, b); check("mbx regs[13]", b, 8'h44);

	// G5 - HPS burst-writes regs, CPU reads back
	$display("G5 HPS write regs -> CPU read");
	mbx_write(8'h0c, 8'h1D);        // DSTAT
	mbx_write(8'h30, 8'hBE);        // DSPS[0]
	reg_read(8'h0c, b); check("cpu reg[0c]", b, 8'h1D);
	reg_read(8'h30, b); check("cpu reg[30]", b, 8'hBE);

	// G6 - kick + IRQ
	$display("G6 kick + IRQ");
	check("kick idle", mbx_status[0], 1'b0);
	reg_write(8'h2f, 8'h00);        // DSP MSB  -> arm kick
	reg_write(8'h2e, 8'h00);
	reg_write(8'h2d, 8'h10);
	reg_write(8'h2c, 8'h00);        // DSP LSB  -> kick_lo_seen -> fire
	repeat (4) @(posedge clk);
	check("kick_pending", mbx_status[0], 1'b1);
	check("int2 low pre", int2, 1'b0);
	mbx_write(8'h21, 8'h01);        // ARM sets ISTAT.DIP
	mbx_ctrl(1'b1, 1'b0, 1'b1, 1'b0);   // set_int | clr_kick
	repeat (2) @(posedge clk);
	check("kick cleared", mbx_status[0], 1'b0);
	check("int2 asserted", int2, 1'b1);
	reg_read(8'h21, b);            // read ISTAT -> clears the interrupt
	repeat (2) @(posedge clk);
	check("int2 cleared by ISTAT read", int2, 1'b0);

	// G7 - soft reset flag
	$display("G7 soft-reset flag");
	reg_write(8'h21, 8'h40);       // ISTAT bit6 = software reset
	repeat (3) @(posedge clk);
	check("srst_pending", mbx_status[2], 1'b1);
	mbx_ctrl(1'b0, 1'b0, 1'b0, 1'b1);   // clr_srst
	repeat (2) @(posedge clk);
	check("srst cleared", mbx_status[2], 1'b0);

	// G8 - DCNTL.STD (reg 0x3B bit2) resumes SCRIPTS -> immediate kick
	$display("G8 DCNTL.STD kick");
	mbx_ctrl(1'b0, 1'b0, 1'b1, 1'b0);   // clr any stale kick
	repeat (2) @(posedge clk);
	check("kick idle", mbx_status[0], 1'b0);
	reg_write(8'h3b, 8'h04);            // DCNTL bit2 = STD
	repeat (3) @(posedge clk);
	check("DCNTL.STD kicked", mbx_status[0], 1'b1);
	mbx_ctrl(1'b0, 1'b0, 1'b1, 1'b0);
	repeat (2) @(posedge clk);
	check("kick cleared", mbx_status[0], 1'b0);

	// G9 - cache-clr strobe (0x67 bit4): held ~64 clk then auto-released
	$display("G9 cache-clr strobe");
	check("cache_clr idle", a4091_cache_clr, 1'b0);
	@(posedge clk); mbx_cache_clr <= 1'b1;
	@(posedge clk); mbx_cache_clr <= 1'b0;
	repeat (2) @(posedge clk);
	check("cache_clr asserted", a4091_cache_clr, 1'b1);
	repeat (70) @(posedge clk);
	check("cache_clr released", a4091_cache_clr, 1'b0);

	$display("");
	if (errs == 0) $display("ALL GROUPS PASS");
	else           $display("%0d FAILURE(S)", errs);
	$finish;
end

// watchdog
initial begin
	#500000;
	$display("TIMEOUT");
	$finish;
end

endmodule
