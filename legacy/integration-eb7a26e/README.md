# A4091 → Minimig-AGA_MiSTer core integration (Phase 1)

Patches against `Minimig-AGA_MiSTer` branch `MiSTer` @ `eb7a26e`
("Release 20260603"), Quartus server `quartus-host`.

**Quartus Analysis & Synthesis: 0 errors** (98 warnings, all benign — stock
Minimig + "register assigned but never read" on 53C710 regs the driver
writes but nothing reads yet). Full `--flow compile` (fitter + timing) run
separately — see `build-notes.md`.

`files.qip`: add three `VERILOG_FILE` lines for `rtl/a4091/a4091{,_siop,_target}.v`
right after the `rtl/cpu_wrapper.v` line.

## Scope

**Phase 1** = the board is real on the bus: Zorro III autoconfig, autoboot
ROM window, 53C710 register window, bus-master DMA, INT2. The HPS sector
server (`minimig_scsi.cpp`) is **not** done yet, so `a4091_present` is tied
to 0 — every SCSI SELECT times out, AmigaOS autoconfigs the board, loads
`a4091.device`, and reports zero units. That already exercises the whole
FPGA path on hardware.

## Files

| Patch | Target | Change |
|---|---|---|
| `cpu_wrapper.v.patch` | `rtl/cpu_wrapper.v` | instance `a4091`; extend the autoconfig chain (A4091 = last link); `sel_a4091` Z3 aperture + peripheral handshake muxed into `cpu_din` / `clkena_in` / `chipreq`; bus-master DMA that hijacks the CPU→RAM port (`cpu_addr`/`cpu_dout`/strobes/`cpustate` override, CPU stalled) so the existing `sel_*`/`ramaddr` decode maps chip-vs-Zorro for free |
| `minimig.v.patch` | `rtl/minimig.v` | `a4091_int2` input, OR-ed into `paula.int2` |
| `Minimig.sv.patch` | `Minimig.sv` | wire `a4091_*` between `cpu_wrapper` and `minimig`; `a4091_ena = status[57]`; sector port tied off; `a4091_present = 0` |

`full/cpu_wrapper.v` is the complete patched file (the biggest change) for
reference / eyeball diff. `minimig.v` / `Minimig.sv` changes are small — the
patch is enough.

## Apply

```bash
cd ~/Development/Minimig-AGA_MiSTer      # on the Quartus server (quartus-host)
git apply /path/to/A4091/integration/cpu_wrapper.v.patch
git apply /path/to/A4091/integration/minimig.v.patch
git apply /path/to/A4091/integration/Minimig.sv.patch

# add the A4091 RTL to the project
mkdir -p rtl/a4091
cp /path/to/A4091/rtl/a4091.v          rtl/a4091/
cp /path/to/A4091/rtl/a4091_bridge.v   rtl/a4091/
cp /path/to/A4091/rtl/a4091_rom.mif    rtl/a4091/
#  -> a4091.v + a4091_bridge.v are already in Minimig.qsf (VERILOG_FILE lines)
```

## Boot ROM

`a4091.v` initialises its 64 KB ROM BRAM from `rtl/a4091/a4091_rom.mif` via a
`(* ram_init_file *)` synthesis attribute on `rom_mem`. Nothing to set in the
QSF — Quartus reads the `.mif` at synthesis.

Generate the `.mif` (plus the byte-per-line `.hex` the iverilog tb uses) from
the [A4091/a4091-software](https://github.com/A4091/a4091-software) AutoConfig
ROM with `../rom/make_hex.sh a4091.rom`, then copy `a4091_rom.mif` to
`rtl/a4091/`.

Because the init is a tracked `.mif` (not a baked `$readmemh`), a
driver-only ROM change is a Quartus **"Update MIF/HEX files"** incremental
step (~2 min) instead of a full recompile (~27 min): update the `.mif`,
`quartus_cdb Minimig --update_mif`, then re-run the assembler flow.

> The `AC_*` localparams in `a4091.v` are the standard A4091 ident layout,
> **not yet reconciled** with the a4091-software ROM's `$00..$1F` / `$40..$5F`
> bytes. Dump those and confirm before trusting autoboot.

## Build

```bash
cd ~/Development/Minimig-AGA_MiSTer && mkdir -p logs
/opt/altera/17.0/quartus/bin/quartus_sh --flow compile Minimig 2>&1 | tee logs/$(date +%Y%m%d)a4091.txt
```

## Enable at runtime

`a4091_ena = status[57]` (OSD `O[57]`). Minimig uses a **hand-wired menu**
(`menu.cpp`), not CONF_STR, so add an "A4091 SCSI : Off/On" toggle by hand —
same mechanism as the PiStorm `O[58]` toggle (see the
`minimig-extcfg-menu-mechanism` memory note). Until that menu entry exists,
force it on for a bench test by setting the bit in a saved config, or
temporarily hard-wire `wire a4091_ena = 1'b1;` in `Minimig.sv`.

## Verify on hardware

1. Boot with A4091 enabled, no ROM → `ShowConfig` lists a Commodore board,
   product 84, ~16 MB at a Z3 base. `a4091d` / `ncr7xx` register tests pass.
2. Add `a4091_rom.hex`, rebuild → the board autoboots; `a4091.device` opens,
   finds no units (expected — no sector server).
3. `ncr7xx` full self-test (loopback / FIFO / CTEST5 / DMA-increment).

## Risk areas (need on-hardware / Quartus validation — cannot sim here)

| Risk | Detail / fallback |
|---|---|
| **DMA via CPU-port hijack** | `cpu_wrapper` overrides `cpu_addr`/`cpu_dout`/strobes/`cpustate` and stalls the CPU while `a4091_dma_active`. Relies on the existing `sel_chipram`/`sel_zram`/`ramaddr` decode. `sel_chipram` was widened with `| a4091_dma_active` so DMA reaches chip RAM regardless of turbochip. If `sdram_ctrl`/`ddram_ctrl` mis-handle a non-CPU-shaped request, fall back to a dedicated 4th port on those controllers. |
| **DMA vs chipset timing** | CPU fully stalled during each DMA burst. Burst length (SCRIPTS fetch = 8 B, data = sector-sized) is the knob. Measure Dhrystone / chipset DMA before/after. |
| **`iverilog` can't check `cpu_wrapper.v`** | the stock file already fails `iverilog -g2012` (forward net refs); only Quartus compiles it. The A4091 modules themselves pass a 13-group `iverilog` bench (`A4091/tb`). |
| **68030 D-cache vs DMA'd buffers** | `a4091.device` issues `CacheClearE`; FPGA DMA writes SDRAM directly. Confirm the TG68030 cache model doesn't stale-read A4091 buffers. |
| **autoconfig chain order** | A4091 armed only after Z2/Z3 RAM + Toccata configure (`ac_a4091_turn`). If a board is added later in the chain, revisit. |
| **`status[57]`** | assumes hps_io exposes 64-bit status and Minimig routes `O[32..63]` as ext_cfg. Confirm against `minimig_config.cpp`. |

## Next (Phase 2)

- `minimig_scsi.cpp` in `Main_MiSTer/support/minimig/` — an `hps_ext.v`
  command channel (like the IDE `'h61/'h62/'h63` path) that serves sectors
  from `.hdf` images into the `a4091_target` `sec_*` stream; drive
  `a4091_present` from mount status.
- OSD: A4091 submenu (enable, 7× image, host ID, the 5 DIP options).
- Reconcile `AC_*` ident bytes with the a4091-software ROM.
