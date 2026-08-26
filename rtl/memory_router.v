// SPDX-License-Identifier: GPL-3.0-or-later

module memory_router
(
	input  [31:0] cpu_addr,

	input         cchip,
	input         ckick,
	input         wr,

	input         bootrom,
	input         cdtv_mode,

	input         z2ram_ena,
	input   [4:0] z3ram_base0,
	input         z3ram_ena0,
	input   [3:0] z3ram_base1,
	input         z3ram_ena1,

	input         rtg_fb_ena,

	output        sel_chipram,
	output        sel_kickram,
	output        sel_kicklower,
	output        sel_z2ram,
	output        sel_z3ram0,
	output        sel_z3ram1,
	output        sel_zram,
	output        sel_dd,
	output        sel_rtg,

	output [28:1] ramaddr
);

assign sel_z3ram0   = (cpu_addr[31:27] == z3ram_base0) && z3ram_ena0;
assign sel_z3ram1   = (cpu_addr[31:28] == z3ram_base1) && z3ram_ena1;
// Z2 fast RAM: fixed $200000-$9FFFFF Zorro II slot. RTG's framebuffer
// AutoConfig's itself into this same slot for real -- ConfigDev, cd_BoardAddr
// and CDB_CONFIGME all genuine, matched here in the RTL decode too (see
// ramaddr[22:19] below for the base-offset correction this requires, since
// this board's Zorro base ($200000) isn't zero unlike a fixed-address board
// would be) -- so Z2 fast RAM stays excluded here whenever rtg_fb_ena is
// latched.
assign sel_z2ram = !cpu_addr[31:24] && (cpu_addr[23] ^ |cpu_addr[22:21]) && z2ram_ena && ~rtg_fb_ena; // addr[23:21] = 1..4
assign sel_rtg   = rtg_fb_ena && !cpu_addr[31:24] && (cpu_addr[23] ^ |cpu_addr[22:21]);                // $200000-$9FFFFF
assign sel_zram     = sel_z3ram0 | sel_z3ram1 | sel_z2ram;
assign sel_dd       = (cpu_addr[31:16] == 16'h00DD) && (cpu_addr[15:13] == 3'b010);

// don't sel_kickram when writing
assign sel_kickram   = !cpu_addr[31:24] && (&cpu_addr[23:19] || (!cdtv_mode && cpu_addr[23:19] == 5'b11100) || (cpu_addr[23:19] == 5'b10101) || (cpu_addr[23:19] == 5'b10110)) && ckick && wr;
assign sel_kicklower = !cpu_addr[31:24] && (cpu_addr[23:18] == 6'b111110);
assign sel_chipram   = !cpu_addr[31:21] && cchip;

//       Main  DDx  RTG  8M  128M  256M
//       ----  ---  ---  --  ----  ----
//        SDR  DDR  RTG  Z2  Z3_0  Z3_1
// 28      0    0    0   1    0     1
// 27      0    0    0   1    1     X
// 26      0    1    1   0    X     X
// 25-23   0   111  110  0    X     X
// supported configs: SDR + (Z2, Z3_1, Z3_0+Z3_1)
//
// This is the mapping to the sram

assign ramaddr[28]    = sel_z2ram | sel_z3ram1;
assign ramaddr[27]    = sel_z3ram0 | (sel_z3ram1 & cpu_addr[27]);
assign ramaddr[26:23] = (sel_z3ram0 | sel_z3ram1) ? cpu_addr[26:23] : (sel_rtg ? 4'b1110 : {4{sel_dd}});
// sel_rtg's window select (cpu_addr[23:21] = 1..4, see sel_z2ram above)
// passes cpu_addr[22:19] straight through as if the board's own zero-offset
// coincided with cpu_addr==0 -- but this board's Zorro base is $200000, not
// $0. The raw bits are off by exactly one 2MB window (4 blocks of this
// 4-bit field's 512KB granularity), which silently rotates the whole 8MB
// physical window: Zorro-offset-0 (the framebuffer's own pixel (0,0), where
// the driver/P96 actually write) would otherwise land at physical DDR3
// offset $200000 instead of offset 0, while the ARM-side video scanout
// reads from a fixed physical offset 0 -- so every pixel/cursor write would
// miss the bytes actually being displayed (this was the corruption/blank-
// screen/no-cursor bug traced during development; see
// rtg/IMPLEMENTATION_PLAN.md). Subtracting 4'd4 (mod 16) undoes the rotation.
assign ramaddr[22:19] = sel_rtg ? (cpu_addr[22:19] - 4'd4) : ({4{sel_dd}} | cpu_addr[22:19]);
assign ramaddr[18]    =    sel_dd   | (sel_kicklower & bootrom) | cpu_addr[18];
assign ramaddr[17:16] = {2{sel_dd}} | cpu_addr[17:16];
assign ramaddr[15:1]  = cpu_addr[15:1];

endmodule
