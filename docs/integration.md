# A4091 ↔ Minimig-AGA_MiSTer integration map

> **Phase-1 patches implemented** — see [`integration/`](integration/):
> `cpu_wrapper.v.patch`, `minimig.v.patch`, `Minimig.sv.patch` (apply cleanly
> on branch `MiSTer` @ `6fc0d5e`), full patched files under `integration/full/`,
> ROM helper in `rom/`. This document is the design rationale behind them.

Recon done against `Minimig-AGA_MiSTer` branch `MiSTer` @ `6fc0d5e` on build
server `build-host:/opt/development/minimig/Minimig-AGA_MiSTer` (the
network-bridge tree — has `sel_net` / `macsh` / HPS shared-memory windows).

This is the tree to target: Option A needs no HPS bridge, but Phase-3'
(Option B) reuses the `$DDxxxx` bridge already here.

---

## What already exists that we reuse

| Need | Existing mechanism | File |
|---|---|---|
| **AutoConfig nibble chain** | hand-coded responder for Z2 RAM / Toccata / Z3 RAM, sequenced by `ac_memcard` / `ac_toccata` flags, `$E80000` config space, nibble on `cpu_din[15:12]`, base latched on write to reg `0x44`/`0x48` | `rtl/cpu_wrapper.v:368-478` |
| **32-bit CPU address** | `cpu_addr_p` from `TG68KdotC_Kernel`; `cpu_addr` is full 32-bit in `cpucfg[1:0]!=0` mode | `rtl/cpu_wrapper.v:144-194` |
| **Peripheral bus handshake** | `fastchip_sel` / `fastchip_selack` / `fastchip_ready` / `fastchip_dout` muxed into `cpu_din` and `clkena_in` | `cpu_wrapper.v:51-58,146,220`; `Minimig.sv:583` |
| **CPU→RAM port** (chip+Z2+Z3, both SDR & DDR3) | `ramsel`/`ramaddr[28:1]`/`ramdin`/`ramdout`/`ramready`/`ramlds`/`ramuds`/`ramshared` | `cpu_wrapper.v:60-67,77,132-138` |
| **INT2 into Paula** | `paula.int2` = `int2 | (ide_fast ? ide_ext_irq : gayle_irq)`; `int2` itself is CIAA irq | `rtl/minimig.v:492`, `:621` |
| **HPS block-device serving** | `ide.v` `request[2:0]` (100=new cmd, 101=data xfer, 110=reset) + `mgmt_*` taskfile/dpram port; Main_MiSTer `support/minimig/` polls `ide_req`, does file IO on the `.hdf`, streams sectors through `mgmt_write & &mgmt_address` into a 4 KB dpram | `rtl/ide.v:49-55,176-310`; `Minimig.sv:258-261` (`hps_ext`) |
| **OSD ext-cfg bits** | `ext_cfg` bit N = OSD `O[32+N]`, auto-persists via `minimig_cfg_save/load`; menu entries are **hand-wired** in `menu.cpp` (no CONF_STR auto-menu) | see `[[minimig-extcfg-menu-mechanism]]` memory note |

## What does NOT exist and must be added

1. **Z3 non-RAM autoconfig** — the chain only knows RAM + Toccata. Add an
   `ac_a4091` state with the A4091 ident table + boot-ROM-vector bit + base
   latch.
2. **A third bus master.** Nothing DMAs to Z2/Z3 fast RAM except the CPU.
   Chip RAM DMA is Agnus-only on the legacy bus. The A4091 SIOP must get a
   memory path.
3. **A Z3 aperture decode** on the CPU side for `[a4091_base, +16 MB)`.
4. **A second HPS block channel** (SCSI, N targets) alongside the IDE one.

---

## Wiring plan (Option A)

New module `a4091.v`, instanced in `Minimig.sv` beside `fastchip`, clocked on
`clk_sys` (28.6875 MHz).

### 3.1 `rtl/cpu_wrapper.v`

**AutoConfig** — in the `always @(*)` at `:374`, add an `else if (ac_a4091)`
arm producing the A4091 ident nibbles (table in `a4091.v` header / from the
ROM image). In the `always @(posedge clk)` at `:435`:
- reset: `ac_a4091 <= 1` **after** `ac_toccata` clears and after Z3 RAM
  configures (A4091 should be last so RAM keeps its expected base), or gate
  on an `a4091_enable` strobe from OSD.
- on write to Z3 base register (`chip_addr[6:1]==6'h22`, reg `0x44`):
  `a4091_base <= cpu_dout[15:12]` (top nibble → 256 MB granule; A4091 wants
  16 MB so also capture `cpu_dout[11:8]` for `addr[27:24]`), `a4091_cfgd<=1`,
  `ac_a4091<=0`.
- also handle the "shut up" register `0x4C`.

**Aperture + handshake** — add:
```verilog
wire sel_a4091 = a4091_cfgd && (cpu_addr[31:24] == a4091_base_hi) ...;   // 16 MB window
```
Feed a new port group to the instanced `a4091`:
`a4091_sel`, `a4091_addr` (`cpu_addr[23:0]`), `a4091_din`(`cpu_dout`),
`a4091_dout`, `a4091_lds/uds`(`lds_in/uds_in`), `a4091_rnw`(`wr`),
`a4091_selack`, `a4091_ready`.
Then:
- `cpu_din` mux (`:146`): add `a4091_selack ? a4091_dout : …`.
- `clkena_in` (`:220`): `… | a4091_ready`.
- `ramsel` (`:77`): leave as-is (A4091 window is not RAM).

**DMA arbitration** — add a DMA-master port the `a4091` drives:
`dma_req`, `dma_rw`, `dma_addr[31:1]`, `dma_din[15:0]`, `dma_dout[15:0]`,
`dma_bs[1:0]`, `dma_ack`.
v1 (CPU-blocking): when `dma_req`, hold the CPU (`clkena_in &= ~dma_active`)
and drive `ramsel/ramaddr/ramdin/ramlds/ramuds` from the DMA port instead of
the CPU decode; return `ramdout`/`ramready` as `dma_dout`/`dma_ack`. Reuses
the full `ramaddr[28:1]` map (chip → SDR, Zorro → DDR3) for free.
v2 (later): a proper extra port on `sdram_ctrl.v` + `ddram_ctrl.v` so DMA
overlaps CPU.

### 3.2 `rtl/minimig.v`

- `:492` → `.int2(int2 | (ide_fast ? ide_ext_irq : gayle_irq) | a4091_int2)`.
- thread `a4091_int2` up from `Minimig.sv`.

### 3.3 `Minimig.sv`

- instance `a4091` (ports: `clk_sys`, `reset`, the `a4091_*` bus from
  `cpu_wrapper`, the `dma_*` master, `a4091_int2`, the HPS `scsi_*` channel,
  the boot-ROM load port).
- boot ROM: reuse the ioctl/download path other cores use for a ROM blob
  (`ioctl_download` with an index), write into a BRAM in `a4091.v`.
- HPS SCSI channel: extend `hps_ext.v` with a `scsi_req[2:0]` + `scsi_mgmt_*`
  pair mirroring `ide_req`.

### 3.4 Main_MiSTer (`support/minimig/`)

- `menu.cpp`: hand-wire an "A4091 SCSI" submenu (enable, 7× image slot,
  host ID, the 5 DIP options) — gate on `user_io_confstr_has("O[..]")` like
  the PiStorm toggle.
- config struct: add `scsi[7]` image paths + options to `mm_configTYPE`
  (auto-persists via `minimig_cfg_save/load`).
- a `minimig_scsi.cpp` block-server: poll `scsi_req`, parse the SCSI CDB
  from the mgmt taskfile, read/write the image file, stream sectors through
  the mgmt dpram. Model it on the existing IDE server.
- ship the open [a4091-software](https://github.com/A4091/a4091-software)
  AutoConfig ROM as the default; allow user override.

---

## Signal budget / clocks

- `a4091.v` on `clk_sys` (28.6875 MHz) — same as the CPU, simplest handshake.
- DMA v1 blocks the CPU; burst length is the tuning knob (see risks in
  `mister-plan.md`). Keep bursts ≤ 512 B initially.
- INT2 must be a **level** held until the driver reads `ISTAT` — Paula
  re-latches `intreq[3]` every `clk7_en` from `int2`, so a held level works.

## Open questions for Phase 0 close-out

- Exact Z3 size code + ident bytes the a4091-software ROM emits (dump it).
- Does `ramready` behave for a non-CPU driver mid-burst, or does the SDR/DDR
  arbiter assume one outstanding CPU request? (check `sdram_ctrl.v`,
  `ddram_ctrl.v`, `minimig_sram_bridge.v`).
- `ioctl_download` index free for the A4091 ROM.
- Whether to gate the whole board on `cpucfg[1]` (TG68 / 32-bit) — yes.
