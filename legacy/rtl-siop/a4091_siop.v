// ===========================================================================
// a4091_siop - NCR 53C710 SCSI I/O Processor model
//
// Port of amiberry/WinUAE src/qemuvga/lsi53c710.cpp (function names in
// comments). Register map from lsi_reg_readb2 / lsi_reg_writeb2.
//
// Simplifications vs the reference (all safe for a4091.device against a
// synchronous virtual target):
//   * SCSI targets complete synchronously - no lsi_request queue, no real
//     disconnect/reselect, no tagged queueing. CON stays asserted for the
//     whole nexus; the driver's phase-branch SCRIPTS follow the connected
//     path. lsi_do_dma / lsi_queue_command / lsi_reselect collapse away.
//   * SCRIPTS words are big-endian in Amiga RAM (68k NCR assembler output);
//     read_dword's byteswap == "assemble MSB-first from memory".
//
// STATUS: Phase 3 - passes A4091/tb (13 groups).
//   register file .......... done
//   interrupt logic ....... done  (lsi_update_irq)
//   byte DMA engine ....... done
//   SCRIPTS group 0 ....... block move (direct / indirect / table-indirect)
//                           + phase engine (MO/CMD/DI/DO/ST/MI)
//   SCRIPTS group 1 ....... Select / WaitDisc / Set / Clear + register ALU
//   SCRIPTS group 2 ....... Jump/Call/Return/Interrupt, carry/phase/data cond
//   SCRIPTS group 3 ....... Memory Move (lsi_memcpy byte copy)
//   DATA OUT .............. STATUS gated on target->HPS flush (tgt_wr_busy)
//   TODO .................. Wait Reselect (sync model has nothing pending),
//                           40/64-bit DMA, self-test loopback detail
// ===========================================================================
`default_nettype none

module a4091_siop
(
	input             clk,
	input             reset,
	input       [6:0] present,      // 1 bit per target id with media (Select STO if absent)

	// CPU-side register access - two 53C710 registers per 16-bit bus word
	// (the beswapped pair). Byte access strobes one lane, word/long both.
	input       [7:0] reg_hi_addr,   // -> D15:8
	input       [7:0] reg_lo_addr,   // -> D7:0
	input             reg_rd_hi, reg_rd_lo,
	input             reg_wr_hi, reg_wr_lo,
	input       [7:0] reg_wd_hi, reg_wd_lo,
	output reg  [7:0] reg_rq_hi,
	output reg  [7:0] reg_rq_lo,
	output            reg_ready,

	// bus-master DMA (16-bit word + byte selects, arbitrated in cpu_wrapper)
	output reg        dma_req,
	output reg        dma_rw,      // 1 = read
	output reg [31:1] dma_addr,
	output reg [15:0] dma_wdata,
	input      [15:0] dma_rdata,
	output reg  [1:0] dma_bs,      // {uds(hi/even byte), lds(lo/odd byte)}
	input             dma_ack,

	output            irq,

	// ---- SCSI target model (a4091_target) ------------------------------
	output reg        tgt_cmd_stb,
	output reg [7:0]  tgt_cdb0,tgt_cdb1,tgt_cdb2,tgt_cdb3,tgt_cdb4,
	output reg [7:0]  tgt_cdb5,tgt_cdb6,tgt_cdb7,tgt_cdb8,tgt_cdb9,
	input             tgt_rsp_ready,
	input      [1:0]  tgt_rsp_dir,
	input      [23:0] tgt_rsp_len,
	input      [7:0]  tgt_rsp_status,
	input             tgt_wr_busy,
	output reg [11:0] tgt_buf_addr,
	output reg [7:0]  tgt_buf_wdata,
	output reg        tgt_buf_we,
	input      [7:0]  tgt_buf_rdata,
	output reg        tgt_data_out_done,

	output            led
);

// ---------------------------------------------------------------------------
// Register file  (LSIState710)
// ---------------------------------------------------------------------------
reg [7:0]  scntl0, scntl1, sdid, sien0, scid, sxfer, sodl, socl;
reg [7:0]  sidl, sbcl, sstat0, sstat1, sstat2;
reg [7:0]  dstat;
reg [31:0] dsa, temp, dsp, dsps, scratch;
reg [7:0]  ctest0, ctest2, ctest3, ctest4, ctest5, ctest6, ctest7, ctest8;
reg [7:0]  istat, dcmd, dmode, dien, dwt, dcntl, lcrc;
reg [23:0] dbc;
reg [31:0] dnad;
reg        carry;
reg [7:0]  sfbr;
reg [7:0]  status;              // last SCSI status byte
reg [2:0]  current_lun;
reg [7:0]  select_id;           // bitmask id from Select

// diagnostic SCSI FIFO
reg [8:0]  scsi_fifo [0:7];
reg [3:0]  scsi_fifo_cnt;

// message buffer (queued MSG IN bytes)
reg [7:0]  msg [0:7];
reg [3:0]  msg_len;
reg [1:0]  msg_action;          // 0 CMD, 1 disconnect, 2 DO, 3 DI

localparam PH_DO=0, PH_DI=1, PH_CMD=2, PH_ST=3, PH_MO=6, PH_MI=7;

integer i;

// ---------------------------------------------------------------------------
// lsi_soft_reset
// ---------------------------------------------------------------------------
task do_soft_reset; begin
	carry<=0; dsa<=0; dnad<=0; dbc<=0; temp<=0; scratch<=0;
	istat <= istat & 8'h40;
	dcmd  <= 8'h40;
	dstat <= 8'h00;
	dien<=0; sien0<=0;
	ctest2 <= 8'h01;
	ctest3<=0; ctest4<=0; ctest5<=0;
	dsp<=0; dsps<=0; dmode<=0; dcntl<=0;
	scntl0 <= 8'hc0; scntl1<=0;
	sstat0<=0; sstat1<=0; sstat2<=0; sodl<=0;
	scsi_fifo_cnt<=0;
	scid <= 8'h80; sxfer<=0; socl<=0; sdid<=0; sidl<=0;
	msg_len<=0; msg_action<=0; sfbr<=0;
end endtask

task set_phase(input [2:0] ph); begin
	sstat2  <= (sstat2 & 8'hf8) | ph;
	ctest0  <= (ctest0 & 8'hfe) | (ph == PH_DI);
	sbcl    <= sbcl & ~8'h80;   // REQ
end endtask

task add_msg(input [7:0] b); begin
	if (msg_len < 8) begin msg[msg_len] <= b; msg_len <= msg_len + 1'b1; end
end endtask

integer sfi;
task rd_side_effect(input stb, input [7:0] a); begin
	if (stb) case (a)
		8'h0c: dstat  <= 0;              // reading DSTAT clears it
		8'h0d: sstat0 <= 0;              // reading SSTAT0 clears it
		8'h16: istat[5] <= 0;            // CTEST2 read clears SIGP
		8'h17: if (scsi_fifo_cnt != 0) begin   // CTEST3 read pops the SCSI FIFO
			ctest2[4] <= scsi_fifo[0][8];
			for (sfi = 0; sfi < 7; sfi = sfi + 1) scsi_fifo[sfi] <= scsi_fifo[sfi+1];
			scsi_fifo_cnt <= scsi_fifo_cnt - 1'b1;
		end
		default: ;
	endcase
end endtask

// ---------------------------------------------------------------------------
// Interrupt  (lsi_update_irq)
// ---------------------------------------------------------------------------
assign irq = ((dstat & dien) != 0) || ((sstat0 & sien0) != 0);

// ---------------------------------------------------------------------------
// register read VALUE  (CPU + SCRIPTS ALU). Pure - the read side effects
// (status-clear, FIFO pop) are applied separately, per strobed lane.
// ---------------------------------------------------------------------------
function [7:0] rreg(input [7:0] a);
	case (a)
		8'h00: rreg = scntl0;   8'h01: rreg = scntl1;
		8'h02: rreg = sdid;     8'h03: rreg = sien0;
		8'h04: rreg = scid;     8'h05: rreg = sxfer;
		8'h08: rreg = sfbr;     8'h09: rreg = sidl;
		8'h0c: rreg = dstat | 8'h80;
		8'h0d: rreg = sstat0;   8'h0e: rreg = sstat1;
		8'h0f: rreg = {scsi_fifo_cnt, sstat2[3:0]};
		8'h10: rreg = dsa[7:0];   8'h11: rreg = dsa[15:8];
		8'h12: rreg = dsa[23:16]; 8'h13: rreg = dsa[31:24];
		8'h15: rreg = 8'hf0;                       // CTEST1: DMA FIFO empty
		8'h16: rreg = ctest2 | 8'h01;              // CTEST2: DACK
		8'h17: rreg = (scsi_fifo_cnt != 0) ? scsi_fifo[0][7:0] : ctest3;
		8'h18: rreg = ctest4;   8'h19: rreg = ctest5;
		8'h1c: rreg = temp[7:0];   8'h1d: rreg = temp[15:8];
		8'h1e: rreg = temp[23:16]; 8'h1f: rreg = temp[31:24];
		8'h21: rreg = istat;
		8'h22: rreg = (ctest8 | 8'h20) & 8'hfb;    // CTEST8: rev V1, CLF clear
		8'h23: rreg = lcrc;
		8'h24: rreg = dbc[7:0]; 8'h25: rreg = dbc[15:8]; 8'h26: rreg = dbc[23:16];
		8'h27: rreg = dcmd;
		8'h28: rreg = dnad[7:0];   8'h29: rreg = dnad[15:8];
		8'h2a: rreg = dnad[23:16]; 8'h2b: rreg = dnad[31:24];
		8'h2c: rreg = dsp[7:0];   8'h2d: rreg = dsp[15:8];
		8'h2e: rreg = dsp[23:16]; 8'h2f: rreg = dsp[31:24];
		8'h30: rreg = dsps[7:0];   8'h31: rreg = dsps[15:8];
		8'h32: rreg = dsps[23:16]; 8'h33: rreg = dsps[31:24];
		8'h34: rreg = scratch[7:0];   8'h35: rreg = scratch[15:8];
		8'h36: rreg = scratch[23:16]; 8'h37: rreg = scratch[31:24];
		8'h38: rreg = dmode;   8'h39: rreg = dien;
		8'h3a: rreg = dwt;     8'h3b: rreg = dcntl;
		default: rreg = 8'h00;
	endcase
endfunction

// ---------------------------------------------------------------------------
// register write  (shared by the CPU port and the SCRIPTS ALU)
// ---------------------------------------------------------------------------
task wreg(input [7:0] a, input [7:0] d); begin
	case (a)
		8'h00: scntl0 <= d;
		8'h01: begin
			scntl1 <= d;
			if (d[3]) begin if (!sstat0[1]) sstat0[1] <= 1; end
			else sstat0[1] <= 0;
		end
		8'h03: sien0 <= d;
		8'h04: scid  <= d;
		8'h05: sxfer <= d;
		8'h06: begin
			sodl <= d;
			if (ctest4[3] && scsi_fifo_cnt < 8) begin
				scsi_fifo[scsi_fifo_cnt] <= { (scntl1[2] ? (^d) : ~(^d)), d };
				scsi_fifo_cnt <= scsi_fifo_cnt + 1'b1;
			end
		end
		8'h07: socl <= d;
		8'h08: sfbr <= d;
		8'h0b: sstat2[2:0] <= d[2:0];
		8'h10: dsa[7:0]   <= d;   8'h11: dsa[15:8]  <= d;
		8'h12: dsa[23:16] <= d;   8'h13: dsa[31:24] <= d;
		8'h14: ctest0 <= (d & 8'hfe) | (ctest0 & 8'h01);
		8'h17: ctest3 <= d;
		8'h18: ctest4 <= d;
		8'h19: begin
			if (d[7]) dnad <= dnad + 32'd4;   // ADCK
			if (d[6]) dbc  <= dbc  - 24'd4;   // BBCK
			ctest5 <= d & 8'h3f;
		end
		8'h1a: ctest6 <= d;   8'h1b: ctest7 <= d;
		8'h1c: temp[7:0]   <= d;   8'h1d: temp[15:8]  <= d;
		8'h1e: temp[23:16] <= d;   8'h1f: temp[31:24] <= d;
		8'h21: begin
			istat <= (istat & 8'h0f) | (d & 8'hf0);
			if (d[7]) dstat[4] <= 1;
			if (d[6]) do_soft_reset;
		end
		8'h22: begin ctest8 <= d; if (d[2]) scsi_fifo_cnt <= 0; end
		8'h23: lcrc <= 0;
		8'h24: dbc[7:0]   <= d;   8'h25: dbc[15:8]  <= d;   8'h26: dbc[23:16] <= d;
		8'h27: dcmd <= d;
		8'h28: dnad[7:0]   <= d;   8'h29: dnad[15:8]  <= d;
		8'h2a: dnad[23:16] <= d;   8'h2b: dnad[31:24] <= d;
		8'h2c: dsp[7:0]   <= d;   8'h2d: dsp[15:8]  <= d;
		8'h2e: dsp[23:16] <= d;
		8'h2f: dsp[31:24] <= d;   // NOTE: kick handled by caller
		8'h30: dsps[7:0]   <= d;   8'h31: dsps[15:8]  <= d;
		8'h32: dsps[23:16] <= d;   8'h33: dsps[31:24] <= d;
		8'h34: scratch[7:0]   <= d;   8'h35: scratch[15:8]  <= d;
		8'h36: scratch[23:16] <= d;   8'h37: scratch[31:24] <= d;
		8'h38: dmode <= d;
		8'h39: dien  <= d;
		8'h3a: dwt   <= d;
		8'h3b: dcntl <= d & ~8'h44;
		default: ;
	endcase
end endtask

// ---------------------------------------------------------------------------
// byte DMA engine  (pci710_dma_rw, one byte per transaction)
// ---------------------------------------------------------------------------
localparam D_IDLE=0, D_WAIT=1;
reg        dstate;
reg        d8_go, d8_rw;
reg [31:0] d8_addr;
reg [7:0]  d8_wd;
reg [7:0]  d8_rq;
reg        d8_busy, d8_done;

always @(posedge clk) begin
	if (reset) begin
		dstate <= D_IDLE; dma_req <= 0; d8_busy <= 0; d8_done <= 0;
	end else begin
		d8_done <= 0;
		case (dstate)
		D_IDLE: if (d8_go) begin
			dma_req   <= 1;
			dma_rw    <= d8_rw;
			dma_addr  <= d8_addr[31:1];
			dma_bs    <= d8_addr[0] ? 2'b01 : 2'b10;      // odd->lds, even->uds
			dma_wdata <= d8_addr[0] ? {8'h00,d8_wd} : {d8_wd,8'h00};
			d8_busy   <= 1;
			dstate    <= D_WAIT;
		end
		D_WAIT: if (dma_ack) begin
			dma_req <= 0;
			d8_rq   <= d8_addr[0] ? dma_rdata[7:0] : dma_rdata[15:8];
			d8_busy <= 0;
			d8_done <= 1;
			dstate  <= D_IDLE;
		end
		endcase
	end
end

// ---------------------------------------------------------------------------
// SCRIPTS sequencer + phase engine
// ---------------------------------------------------------------------------
localparam
	S_IDLE=6'd0,  S_FA=6'd1,   S_FB=6'd2,   S_DEC=6'd3,  S_DISP=6'd4,
	S_BM=6'd5,
	S_CMDA=6'd6,  S_CMDB=6'd7,  S_CMDX=6'd8,  S_CMDW=6'd9,
	S_DIA=6'd10,  S_DIB=6'd11,  S_DIC=6'd12,
	S_DOA=6'd13,  S_DOB=6'd14,  S_DOC=6'd15,
	S_STA=6'd16,  S_STB=6'd17,
	S_MIA=6'd18,  S_MIB=6'd19,  S_MIC=6'd20,
	S_MOA=6'd21,  S_MOB=6'd22,  S_MOC=6'd23,
	S_IO=6'd24,   S_MM=6'd25,
	S_RUN=6'd26,  S_XFER=6'd27, S_STOP=6'd28,
	S_BMADDR=6'd29, S_BMPTR=6'd30, S_BMPTRW=6'd31,
	S_MMA=6'd32,  S_MMA2=6'd33, S_MMB=6'd34, S_MMC=6'd35,
	S_MMCW=6'd36, S_MMD=6'd37,
	S_DOW1=6'd38, S_DOW2=6'd39,
	S_DIS=6'd40;                   // DATA-IN: settle cycle for the registered tgt_buf_rdata

reg [5:0]  st;
reg [31:0] insn, arg;
reg [2:0]  fb;
reg [7:0]  fbuf [0:7];
reg [15:0] insn_cnt;

reg [23:0] data_rem;
reg [11:0] data_off;
reg [4:0]  cdb_i;
reg [7:0]  cdb [0:15];
reg [4:0]  mi_i;
reg [4:0]  mo_i;

// block-move addressing (direct / indirect / table-indirect)
reg [31:0] mv_addr;
reg [23:0] mv_dbc;
reg [3:0]  ind_i, ind_n;
reg [31:0] ind_base;
reg [7:0]  ptr [0:7];

// memory move (group 3)
reg [31:0] mm_src, mm_dst;
reg [23:0] mm_cnt;
reg [7:0]  mm_byte;

reg        reg_ready_r;
assign reg_ready = reg_ready_r;
assign led       = (st != S_IDLE);

// The a4091.v strobes are LEVELS held for the whole (multi-cycle) bus access.
// reg_ready acts on the level, but each lane's latch + SIDE EFFECT (register
// write, read-clear / FIFO-pop, SCRIPTS kick) must fire exactly ONCE per
// address phase - not every cycle the strobe is held (self-clearing bits
// double-count: CTEST5 ADCK/BBCK give DNAD += 8 / DBC -= 8) and not just
// once for a whole 32-bit access (each half hits a different register pair).
// Trigger = strobe rising edge OR this lane's decoded address changed.
reg  reg_rd_hi_d, reg_rd_lo_d, reg_wr_hi_d, reg_wr_lo_d;
reg  [7:0] reg_hi_addr_d, reg_lo_addr_d;
wire hi_new  = (reg_hi_addr != reg_hi_addr_d);
wire lo_new  = (reg_lo_addr != reg_lo_addr_d);
wire rd_hi_e = reg_rd_hi & (~reg_rd_hi_d | hi_new);
wire rd_lo_e = reg_rd_lo & (~reg_rd_lo_d | lo_new);
wire wr_hi_e = reg_wr_hi & (~reg_wr_hi_d | hi_new);
wire wr_lo_e = reg_wr_lo & (~reg_wr_lo_d | lo_new);

task dma8(input rw, input [31:0] a, input [7:0] wd); begin
	d8_go <= 1; d8_rw <= rw; d8_addr <= a; d8_wd <= wd;
end endtask

wire d8_idle = ~d8_busy & ~d8_go & ~d8_done;


always @(posedge clk) begin
	if (reset) begin
		do_soft_reset;
		st <= S_IDLE; insn_cnt <= 0; d8_go <= 0; reg_ready_r <= 0;
		reg_rd_hi_d <= 0; reg_rd_lo_d <= 0; reg_wr_hi_d <= 0; reg_wr_lo_d <= 0;
		tgt_cmd_stb <= 0; tgt_buf_we <= 0; tgt_data_out_done <= 0;
	end
	else begin
		d8_go             <= 0;
		reg_ready_r       <= 0;
		tgt_cmd_stb       <= 0;
		tgt_buf_we        <= 0;
		tgt_data_out_done <= 0;

		// ==== CPU register port (dual-lane: hi -> D15:8, lo -> D7:0) =====
		reg_rd_hi_d <= reg_rd_hi;  reg_rd_lo_d <= reg_rd_lo;
		reg_wr_hi_d <= reg_wr_hi;  reg_wr_lo_d <= reg_wr_lo;
		reg_hi_addr_d <= reg_hi_addr;  reg_lo_addr_d <= reg_lo_addr;

		reg_ready_r <= reg_rd_hi | reg_rd_lo | reg_wr_hi | reg_wr_lo;

		// -- reads: latch value + apply side effects once, on the strobe edge --
		if (rd_hi_e) reg_rq_hi <= rreg(reg_hi_addr);
		if (rd_lo_e) reg_rq_lo <= rreg(reg_lo_addr);
		rd_side_effect(rd_hi_e, reg_hi_addr);
		rd_side_effect(rd_lo_e, reg_lo_addr);

		// -- writes: once per access (edge) --
		if (wr_hi_e) wreg(reg_hi_addr, reg_wd_hi);
		if (wr_lo_e) wreg(reg_lo_addr, reg_wd_lo);

		// DSP[31:24] (reg 0x2f) write with DMODE.MAN=0 -> start SCRIPTS
		if (((wr_hi_e && reg_hi_addr == 8'h2f) || (wr_lo_e && reg_lo_addr == 8'h2f))
		    && !dmode[0] && st == S_IDLE) begin
			st <= S_FA; fb <= 0; insn_cnt <= 0;
`ifdef A4091_DEBUG
			$display("  [siop] kick");
`endif
		end
		// DCNTL.STD single-step (DMODE.MAN=1)
		else if (((wr_hi_e && reg_hi_addr == 8'h3b && reg_wd_hi[2]) ||
		          (wr_lo_e && reg_lo_addr == 8'h3b && reg_wd_lo[2]))
		         && dmode[0] && st == S_IDLE) begin
			st <= S_FA; fb <= 0;
		end

		// ==== sequencer ==============================================
		case (st)

		// ---- fetch 8 big-endian bytes @ dsp ----------------------
		S_FA: if (d8_idle) begin dma8(1, dsp + {29'd0, fb}, 8'h0); st <= S_FB; end
		S_FB: if (d8_done) begin
			fbuf[fb] <= d8_rq;
			if (fb == 3'd7) st <= S_DEC;
			else begin fb <= fb + 1'b1; st <= S_FA; end
		end
		S_DEC: begin
			insn     <= {fbuf[0], fbuf[1], fbuf[2], fbuf[3]};
			arg      <= {fbuf[4], fbuf[5], fbuf[6], fbuf[7]};
			dcmd     <= fbuf[0];
			dsps     <= {fbuf[4], fbuf[5], fbuf[6], fbuf[7]};
			dsp      <= dsp + 32'd8;
			insn_cnt <= insn_cnt + 1'b1;
`ifdef A4091_DEBUG
			$display("  [siop] @%08x insn=%02x%02x%02x%02x arg=%02x%02x%02x%02x ph=%0d",
			         dsp, fbuf[0],fbuf[1],fbuf[2],fbuf[3],
			         fbuf[4],fbuf[5],fbuf[6],fbuf[7], sstat2[2:0]);
`endif
			if (insn_cnt > 16'd12000) begin sstat0[2] <= 1; st <= S_STOP; end
			else st <= S_DISP;
		end
		S_DISP: case (insn[31:30])
			2'b00: st <= S_BMADDR;
			2'b01: st <= S_IO;
			2'b10: st <= S_XFER;
			2'b11: st <= S_MM;
		endcase

		// ---- Group 0: Block Move addressing ---------------------
		//   direct         : addr = arg
		//   indirect  (b29) : addr = *(arg)                    [BE dword]
		//   table ind (b28) : {count,addr} = *(dsa + s24(arg)) [2 BE dwords]
		S_BMADDR: begin
			if (insn[29] || insn[28]) begin
				ind_i    <= 0;
				ind_n    <= insn[28] ? 4'd7 : 4'd3;
				ind_base <= insn[28] ? (dsa + {{8{arg[23]}}, arg[23:0]}) : arg;
				st <= S_BMPTR;
			end else begin
				mv_addr <= arg;
				mv_dbc  <= insn[23:0];
				st <= S_BM;
			end
		end
		S_BMPTR: if (d8_idle) begin
			if (ind_i > ind_n) begin
				if (insn[28]) begin
					mv_dbc  <= {ptr[1], ptr[2], ptr[3]};
					mv_addr <= {ptr[4], ptr[5], ptr[6], ptr[7]};
				end else begin
					mv_addr <= {ptr[0], ptr[1], ptr[2], ptr[3]};
					mv_dbc  <= insn[23:0];
				end
				st <= S_BM;
			end else begin
				dma8(1, ind_base + {28'd0, ind_i}, 8'h0);
				st <= S_BMPTRW;
			end
		end
		S_BMPTRW: if (d8_done) begin
			ptr[ind_i] <= d8_rq;
			ind_i <= ind_i + 1'b1;
			st <= S_BMPTR;
		end

		// ---- Group 0: Block Move phase-check + dispatch ---------
		S_BM: begin
			if (sstat2[2:0] != insn[26:24]) begin
				sstat0[7] <= 1;               // SSTAT0.MA
				sbcl[7]   <= 1;               // REQ
				st <= S_STOP;
`ifdef A4091_DEBUG
				$display("  [siop] PHASE MISMATCH have=%0d want=%0d", sstat2[2:0], insn[26:24]);
`endif
			end else begin
				dnad <= mv_addr;
				dbc  <= mv_dbc;
				case (insn[26:24])
					PH_CMD: begin cdb_i <= 0; st <= S_CMDA; end
					PH_DI:  st <= S_DIA;
					PH_DO:  st <= S_DOA;
					PH_ST:  st <= S_STA;
					PH_MI:  begin mi_i <= 0; st <= S_MIA; end
					PH_MO:  begin mo_i <= 0; st <= S_MOA; end
					default: st <= S_STOP;
				endcase
			end
		end

		// ---- CMD phase ---------------------------------------
		S_CMDA: if (d8_idle) begin
			if (cdb_i >= 5'd16 || {19'd0,cdb_i} >= dbc) st <= S_CMDX;
			else begin dma8(1, dnad + {27'd0, cdb_i}, 8'h0); st <= S_CMDB; end
		end
		S_CMDB: if (d8_done) begin
			cdb[cdb_i] <= d8_rq;
			if (cdb_i == 0) sfbr <= d8_rq;
			cdb_i <= cdb_i + 1'b1;
			st <= S_CMDA;
		end
		S_CMDX: begin
			tgt_cdb0<=cdb[0]; tgt_cdb1<=cdb[1]; tgt_cdb2<=cdb[2]; tgt_cdb3<=cdb[3];
			tgt_cdb4<=cdb[4]; tgt_cdb5<=cdb[5]; tgt_cdb6<=cdb[6]; tgt_cdb7<=cdb[7];
			tgt_cdb8<=cdb[8]; tgt_cdb9<=cdb[9];
			tgt_cmd_stb <= 1;
			st <= S_CMDW;
		end
		S_CMDW: if (tgt_rsp_ready) begin
			status <= tgt_rsp_status;
			data_off <= 0;
			case (tgt_rsp_dir)
				2'd1: begin data_rem <= tgt_rsp_len; set_phase(PH_DI); end
				2'd2: begin data_rem <= tgt_rsp_len; set_phase(PH_DO); end
				default: set_phase(PH_ST);
			endcase
`ifdef A4091_DEBUG
			$display("  [siop] rsp dir=%0d len=%0d status=%02x", tgt_rsp_dir, tgt_rsp_len, tgt_rsp_status);
`endif
			st <= S_RUN;
		end

		// ---- DATA IN (target buffer -> Amiga RAM) -----------
		S_DIA: begin
			if (data_rem == 0) begin set_phase(PH_ST); st <= S_RUN; end
			else if (dbc == 0)  st <= S_RUN;
			else begin tgt_buf_addr <= data_off; st <= S_DIS; end
		end
		S_DIS: st <= S_DIB;                 // tgt_buf_rdata is registered -> 1 settle cycle
		S_DIB: if (d8_idle) begin dma8(0, dnad, tgt_buf_rdata); st <= S_DIC; end
		S_DIC: if (d8_done) begin
			dnad     <= dnad + 1'b1;
			dbc      <= dbc  - 1'b1;
			data_rem <= data_rem - 1'b1;
			data_off <= data_off + 1'b1;
			st <= S_DIA;
		end

		// ---- DATA OUT (Amiga RAM -> target buffer) ----------
		S_DOA: begin
			if (data_rem == 0) begin tgt_data_out_done <= 1; st <= S_DOW1; end
			else if (dbc == 0)  st <= S_RUN;
			else st <= S_DOB;
		end
		S_DOW1: st <= S_DOW2;                       // target latches data_out_done -> wr_busy
		S_DOW2: if (!tgt_wr_busy) begin set_phase(PH_ST); st <= S_RUN; end
		S_DOB: if (d8_idle) begin dma8(1, dnad, 8'h0); st <= S_DOC; end
		S_DOC: if (d8_done) begin
			tgt_buf_addr  <= data_off;
			tgt_buf_wdata <= d8_rq;
			tgt_buf_we    <= 1;
			dnad     <= dnad + 1'b1;
			dbc      <= dbc  - 1'b1;
			data_rem <= data_rem - 1'b1;
			data_off <= data_off + 1'b1;
			st <= S_DOA;
		end

		// ---- STATUS phase ----------------------------------
		S_STA: if (d8_idle) begin dma8(0, dnad, status); st <= S_STB; end
		S_STB: if (d8_done) begin
			sfbr <= status;
			dbc  <= dbc - 1'b1;
			set_phase(PH_MI);
			msg[0] <= 8'h00;          // COMMAND COMPLETE
			msg_len <= 4'd1;
			msg_action <= 2'd1;
			st <= S_RUN;
		end

		// ---- MSG IN phase --------------------------------
		S_MIA: begin
			if (mi_i == 0) sfbr <= msg[0];
			if ({27'd0,mi_i} >= {28'd0,msg_len} || {27'd0,mi_i} >= dbc) begin
				case (msg_action)
					2'd1: begin scntl1 <= scntl1 & ~8'h10; sstat2[2:0] <= 3'd0; end
					2'd0: set_phase(PH_CMD);
					2'd2: set_phase(PH_DO);
					2'd3: set_phase(PH_DI);
				endcase
				st <= S_RUN;
			end else st <= S_MIB;
		end
		S_MIB: if (d8_idle) begin dma8(0, dnad, msg[mi_i]); st <= S_MIC; end
		S_MIC: if (d8_done) begin
			sidl <= msg[mi_i];
			dnad <= dnad + 1'b1;
			dbc  <= dbc - 1'b1;
			mi_i <= mi_i + 1'b1;
			st <= S_MIA;
		end

		// ---- MSG OUT phase ------------------------------
		S_MOA: begin
			if ({27'd0,mo_i} >= dbc) begin set_phase(PH_CMD); st <= S_RUN; end
			else st <= S_MOB;
		end
		S_MOB: if (d8_idle) begin dma8(1, dnad + {27'd0,mo_i}, 8'h0); st <= S_MOC; end
		S_MOC: if (d8_done) begin
			sfbr <= d8_rq;
			if (d8_rq[7]) current_lun <= d8_rq[2:0];
			dnad <= dnad + 1'b1;
			mo_i <= mo_i + 1'b1;
			st <= S_MOA;
		end

		// ---- Group 1: I/O + register ALU --------------
		S_IO: begin
			if (insn[29:27] < 3'd5) begin
				case (insn[29:27])
				3'd0: begin                             // Select
					sdid <= insn[23:16];
					select_id <= insn[23:16];
					if (scntl1[4]) begin
						dsp <= arg;                    // already connected -> alt addr
						st  <= S_RUN;
					end else if ((insn[22:16] & present) == 7'd0) begin
						sstat0[5] <= 1'b1;             // STO - selection timeout
						scntl1 <= scntl1 & ~8'h10;
						st  <= S_STOP;
					end else begin
						scntl1 <= scntl1 | 8'h10;      // CON
						sstat1[2] <= 1'b1;             // WOA
						if (insn[24]) begin socl <= socl | 8'h08; set_phase(PH_MO); end
						else set_phase(PH_CMD);
						st  <= S_RUN;
					end
				end
				3'd1: begin scntl1 <= scntl1 & ~8'h10; st <= S_RUN; end  // Wait Disconnect
				3'd2: st <= S_RUN;                                       // Wait Reselect (TODO)
				3'd3: begin                                             // Set
					if (insn[3])  begin socl <= socl | 8'h08; set_phase(PH_MO); end
					if (insn[10]) carry <= 1'b1;
					st <= S_RUN;
				end
				3'd4: begin                                             // Clear
					if (insn[3])  socl <= socl & ~8'h08;
					if (insn[10]) carry <= 1'b0;
					st <= S_RUN;
				end
				endcase
			end
			else begin : alu
				reg [7:0] rn, d8, o0, o1;
				reg [2:0] xop;
				reg       nc;
				rn  = {insn[7], insn[22:16]};
				d8  = insn[15:8];
				xop = insn[26:24];
				o0  = 8'h00; o1 = 8'h00; nc = carry;
				case (insn[29:27])
					3'd5: begin o0 = sfbr; o1 = d8; end
					3'd6: begin if (|xop) o0 = rreg(rn); o1 = d8; end
					3'd7: begin if (|xop) o0 = rreg(rn); o1 = insn[23] ? sfbr : d8; end
				endcase
				case (xop)
					3'd0: o0 = o1;
					3'd1: begin nc = o0[7]; o0 = {o0[6:0], carry}; end
					3'd2: o0 = o0 | o1;
					3'd3: o0 = o0 ^ o1;
					3'd4: o0 = o0 & o1;
					3'd5: begin nc = o0[0]; o0 = {carry, o0[7:1]}; end
					3'd6: {nc, o0} = o0 + o1;
					3'd7: {nc, o0} = o0 + o1 + {7'd0, carry};
				endcase
				carry <= nc;
				case (insn[29:27])
					3'd5, 3'd7: wreg(rn, o0);
					3'd6:       sfbr <= o0;
				endcase
				st <= S_RUN;
			end
		end

		// ---- Group 2: Transfer Control -------------
		S_XFER: begin : xfer
			reg cnd, jmp;
			reg [7:0] m;
			reg [31:0] tgt;
			if ((insn & 32'h002e0000) == 32'h0) begin
				st <= S_FA; fb <= 0;                    // NOP
			end else begin
				jmp = insn[19];
				cnd = jmp;
				if (cnd == jmp && insn[21]) cnd = (carry != 1'b0);
				if (cnd == jmp && insn[17]) cnd = (sstat2[2:0] == insn[26:24]);
				if (cnd == jmp && insn[18]) begin
					m   = ~insn[15:8];
					cnd = ((sfbr & m) == (insn[7:0] & m));
				end
				tgt = insn[23] ? (dsp + {{8{arg[23]}}, arg[23:0]}) : arg;
				if (cnd == jmp) begin
					case (insn[29:27])
						3'd0: begin dsp <= tgt; st <= S_FA; fb <= 0; end
						3'd1: begin temp <= dsp; dsp <= tgt; st <= S_FA; fb <= 0; end
						3'd2: begin dsp <= temp; st <= S_FA; fb <= 0; end
						3'd3: begin if (!insn[20]) dstat[2] <= 1'b1; st <= S_STOP; end
						default: begin dstat[0] <= 1'b1; st <= S_STOP; end
					endcase
				end else begin st <= S_FA; fb <= 0; end
			end
		end

		// ---- Group 3: Memory Move (DCMD 0xC0) -----
		//   3 dwords: insn, src(arg), dst(@dsp). Copy insn[23:0] bytes.
		S_MM: begin
			if (insn[31:24] != 8'hc0) begin dstat[0] <= 1'b1; st <= S_STOP; end
			else begin
				mm_src <= arg;
				mm_cnt <= insn[23:0];
				ind_i  <= 0;
				st <= S_MMA;
			end
		end
		S_MMA: if (d8_idle) begin
			if (ind_i > 4'd3) begin
				mm_dst <= {ptr[0], ptr[1], ptr[2], ptr[3]};
				dsp    <= dsp + 32'd4;
				st <= S_MMB;
			end else begin
				dma8(1, dsp + {28'd0, ind_i}, 8'h0);
				st <= S_MMA2;
			end
		end
		S_MMA2: if (d8_done) begin ptr[ind_i] <= d8_rq; ind_i <= ind_i + 1'b1; st <= S_MMA; end
		S_MMB: if (d8_idle) begin
			if (mm_cnt == 0) st <= S_RUN;
			else begin dma8(1, mm_src, 8'h0); st <= S_MMC; end
		end
		S_MMC: if (d8_done) begin mm_byte <= d8_rq; st <= S_MMCW; end
		S_MMCW: if (d8_idle) begin dma8(0, mm_dst, mm_byte); st <= S_MMD; end
		S_MMD: if (d8_done) begin
			mm_src <= mm_src + 1'b1;
			mm_dst <= mm_dst + 1'b1;
			mm_cnt <= mm_cnt - 1'b1;
			st <= S_MMB;
		end

		// ---- post-op: continue or single-step ----
		S_RUN: begin
			if (dcntl[4] || dmode[0]) begin dstat[3] <= 1'b1; st <= S_STOP; end
			else begin st <= S_FA; fb <= 0; end
		end

		S_STOP: begin
			st <= S_IDLE;
			istat[0] <= (dstat  != 8'h0);
			istat[1] <= (sstat0 != 8'h0);
`ifdef A4091_DEBUG
			$display("  [siop] STOP dstat=%02x sstat0=%02x dsps=%08x", dstat, sstat0, dsps);
`endif
		end
		endcase
	end
end

endmodule
`default_nettype wire
