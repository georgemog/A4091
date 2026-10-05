# Legacy — superseded designs, kept for reference

Nothing here is used by the current build.

## `rtl-siop/` — the 53C710 in RTL ("Option A")

The first implementation put the entire NCR 53C710 in FPGA fabric:
`a4091_siop.v` holds the register file, the SCRIPTS engine (all four
instruction groups) and the SCSI phase engine. `a4091_target.v` is a virtual
SCSI-2 disk, and `a4091_sd.v` streams its sectors to the HPS. The
`tb/` iverilog bench (`make`) passes, and the design got as far as
enumerating, reading geometry and mounting a drive on real hardware.

It was abandoned for the software SIOP (`../rtl/a4091_bridge.v` +
`../main_mister/`). The FPGA-side DMA into Minimig's RAM controllers kept
producing a family of 16-bit-DMA data-corruption bugs, and every fix cost a
~25-minute Quartus rebuild. `../docs/JOURNAL.md` has the full history.
`STATUS.md` is the RTL status as last written.

## `integration-eb7a26e/` — original core patch set

Patches against `Minimig-AGA_MiSTer` `eb7a26e` (Release 20260603) and early
`Main_MiSTer` trees, for the RTL SIOP. They include the dedicated DMA ports
on `ddram_ctrl` / `sdram_ctrl` and the CPU-port hijack mux. Upstream's later
`memory_router` refactor makes them inapplicable as-is. The current
integration is `../core/combined/`.
