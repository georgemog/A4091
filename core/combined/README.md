# Combined core — A4091 + Z3 RTG + A2065

One Minimig-AGA_MiSTer core carrying all three expansion boards:

| Board | Type | Ident | Where it comes from |
|---|---|---|---|
| **A2065 Ethernet** (LANCE Am7990) | Zorro II | Commodore, mfr 0x0202 / prod 0x70 | **upstream**, merged in Minimig `809b955` (Release 20260823) |
| **Z3 RTG graphics** | Zorro III, 16 MB | mfr 0x139C / prod 0x30 ("Rok Krajnc Minimig Z3 GraphicsCard") | branch `rtg-z3-graphics-card` (`02eff9c`), see `rtg/` |
| **A4091 SCSI** (NCR 53C710, software SIOP) | Zorro III, 16 MB | Commodore, mfr 514 / prod 84 | this directory — forward-ported from the `eb7a26e` integration in `../` |

Base: `Minimig-AGA_MiSTer` `b265a3b` ("Release 20260823") + the three RTG
commits = branch `rtg-z3-graphics-card`. The old A4091 integration in `../../legacy/integration-eb7a26e/`
targets `eb7a26e` ("Release 20260603") and does **not** apply to that tree.

## What changed vs the `eb7a26e` integration

The software-SIOP bridge has no FPGA bus master (`a4091_bridge.v` ties
`dma_req` to 0 — the ARM writes DATA phases straight into HPS DDR), so the
whole DMA half of the old patch set is gone:

* **dropped** — `ddram_ctrl.v` / `sdram_ctrl.v` dedicated `dma*` ports, the
  `cpu_addr`/`cpustate` DMA hijack mux, `a4091_dma_tail`, the `ramsel` /
  `chipreq` DMA gating, `ramcinhibit`, and the `Minimig.sdc` DMA multicycles.
  That matters here: upstream `20260823` moved the address decode out of
  `cpu_wrapper.v` into `rtl/memory_router.v` (plus a second instance inside
  `rtl/chipdma_arb.v`), which the old DMA hijack was built around.
* **dropped** — the `CONF_STR` `S0,HDFIMGHDF` slot / `VDNUM(1)` /
  `img_mounted` wires. Vestigial: `minimig_a4091.cpp` opens the `.hdf`s
  itself (`FileOpenEx`) from the hand-wired OSD "A4091 SCSI" section.
* **kept** — autoconfig chain link, board window + DTACK handshake, boot ROM,
  the `hps_ext` mailbox (`'h64`–`'h68`), INT2, and the registered
  `cpu_cacr_a4091` cache-clear OR (FPGA snoop-invalidate; a combinational OR
  fails clk_114 — see `../../docs/JOURNAL.md` 20260906-16xx).

Autoconfig order in the combined core is CDTV → Z2 RAM → Toccata → **A2065**
→ Z3 RAM → **RTG Z3** → **A4091** (last link). The RTG/Z3-RAM order is
deliberate — see below:

```verilog
wire ac_a4091_turn = a4091_on & ~a4091_cfgd
                   & ~|ac_memcard & ~ac_toccata & ~ac_a2065 & ~ac_rtg & ~ac_cdtv;
```

## Zorro III address-space notes

**AutoConfig chain order is load-bearing.** AmigaOS hands out Zorro III space
in chain order, and the A4091's ARM-side DMA seam hardcodes the Z3 fast RAM
base: `minimig_a4091.cpp :: ddr_ptr()` maps `phys = 0x30000000 + (A -
0x40000000)`. Upstream places the RTG board *before* the Z3 RAM board, which
pushed the RAM to `$50000000` — every buffer address the driver handed the
SIOP then fell outside the ARM's window, the bounds check rejected it, the
SCSI probe found nothing and `a4091.device` expunged itself (board still
enumerated; `devtest` reported "no device found"). So `cpu_wrapper.v` here
moves the `ac_rtg` branch **after** `ac_memcard[2]`, in both the nibble mux
and the base-latch ladder. RTG itself is indifferent to its base (dynamic
128 MB base compare).

Follow-up worth doing: have the ARM learn the real Z3 RAM base (e.g. carry
`z3ram_base0` in the `a4091_dbg_bus` word read by `hps_ext` `'h68`) instead of
assuming `$40000000`, so board order stops mattering.

Two boards also decode more space than they declare:

* **RTG** declares 16 MB but its decode is a 128 MB-granularity base compare
  (`cpu_addr[31:27] == rtg_z3_base`), split by `cpu_addr[26:23]`: `0` = the
  8 MB framebuffer (`memory_router.v`), `1` = the regs+CLUT block
  (`fastchip_sel`). A later board landing in the same 128 MB block at
  `[26:23] == 1` would collide with the regs window. AmigaOS packs Z3
  allocations at board-size alignment, so the next 16 MB board lands at
  `[26:23] == 2` — fine, but not free: don't shrink the RTG board below 16 MB
  without revisiting this.
* **A4091** decodes a full 16 MB (`cpu_addr[31:24] == a4091_board_base`) while
  its `AC_TYPE` size code still reads as 8 MB (the known ident quirk, see
  `../../docs/JOURNAL.md`). Harmless *because it is the last link in the chain* —
  nothing is allocated after it. Adding a board behind the A4091 means fixing
  the ident bytes first.

## Files

| File | Change |
|---|---|
| `rtl/cpu_wrapper.v` | A4091 ports, `ac_a4091_turn` chain link, `sel_a4091` board window, `cpu_din` / `clkena_p_base` / `chipreq` mux, `a4091` instance (DMA ports left unconnected) |
| `rtl/minimig.v` | `a4091_int2` input, OR-ed into `paula.int2` alongside `a2065_int2_sync` / `akiko_irq` / `cdtv_irq_w` |
| `Minimig.sv` | mailbox wires (picked up by `hps_ext`'s `.*`), `a4091_ena = status[57]`, `cpu_cacr_a4091` into both RAM controllers, cpu_wrapper + minimig wiring |
| `hps_ext.v` | A4091 mailbox commands `'h64` poll / `'h65` reg read / `'h66` reg write / `'h67` control / `'h68` debug (upstream uses `'h61`–`'h63` only) |
| `files.qip` | `rtl/a4091/a4091.v`, `rtl/a4091/a4091_bridge.v` |

`a4091-on-rtgz3.patch` is the whole thing as one diff against
`rtg-z3-graphics-card`. `rtl/a4091/{a4091.v,a4091_bridge.v,a4091_rom.mif}`
are copied in unchanged from `../../rtl/`.

## Build

```bash
# on the Quartus server (quartus-host)
git -C ~/Development/Minimig-AGA_MiSTer_rtg worktree add -b a4091-rtg-a2065 /tmp/mm-combined rtg-z3
cd /tmp/mm-combined
git apply /path/to/Minimig-AGA-A4091/core/combined/a4091-on-rtgz3.patch
mkdir -p rtl/a4091 && cp /path/to/Minimig-AGA-A4091/rtl/{a4091.v,a4091_bridge.v,a4091_rom.mif} rtl/a4091/
printf '`define BUILD_DATE "%s"' $(date +%y%m%d) > build_id.v   # PRE_FLOW normally does this
/opt/altera/17.0/quartus/bin/quartus_sh --flow compile Minimig 2>&1 | tee logs/combined_build.log
```

## Runtime config

| Knob | Where |
|---|---|
| A4091 enable | OSD `O[57]` — `tools/mmcfg.py --a4091 minimig.cfg`, then reload the core |
| A4091 units | OSD "A4091 SCSI" section (`Main_MiSTer` `menu.cpp`), IDs 1–6 |
| A2065 | always autoconfig'd; interface chosen in the Minimig OSD (Main_MiSTer `minimig_a2065.cpp`) |
| RTG | always autoconfig'd; Amiga side needs `MiSTer.card` built from `extra/rtg_driver/MiSTer.card.asm` (`FindConfigDev(0x139C, 0x30)`) |

`Main_MiSTer` needs no merge work: A2065 support is upstream (`ebd9628`,
`b7dd336`, `98f2cd1`) in the same `915ca33` master the A4091 patch
(`../../../main_mister/main_mister_swsiop.patch` + `../../main_mister/`) is built on.
