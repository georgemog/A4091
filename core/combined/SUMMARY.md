# Combined core — what was implemented and tested

One Minimig-AGA_MiSTer core carrying three expansion boards: **A4091** (Zorro III
NCR 53C710 SCSI, software SIOP), **Z3 RTG** graphics, and **A2065** Ethernet.
Session of 2026-09-06/07. Detail in [`RESULTS.md`](RESULTS.md), timeline in
[`../../docs/JOURNAL.md`](../../docs/JOURNAL.md).

**Where things live:**

| | |
|---|---|
| Runtime files (driver, diagnostics, the Zorro III `MiSTer.card`, icons) | [`../../README.md#runtime-files`](../../README.md#runtime-files) — install map, provenance, checksums |
| RTL diff + build recipe | [`README.md`](README.md), [`a4091-on-rtgz3.patch`](a4091-on-rtgz3.patch) |
| Hardware smoke test | [`verify_combined.sh`](verify_combined.sh) |
| ARM sources | [`../../main_mister/`](../../main_mister/) |
| Boot ROM | [`../../rom/`](../../rom/) → baked in as `rtl/a4091/a4091_rom.mif` |
| Build products (not in git) | RBF `minimig_20260906_A4091_RTG_A2065_v2.rbf` in `/media/fat/_Computer/` (built in `/tmp/mm-combined` on `quartus-host`); ARM binary `/media/fat/MiSTer` (built on `build-host`) |

## Implemented

| Area | What |
|---|---|
| **Core** | A4091 bridge forward-ported from Minimig `eb7a26e` (Rel 20260603) onto `b265a3b` (Rel 20260823) + the Z3 RTG branch. A2065 came free — it is upstream on both the FPGA side (`809b955`) and the ARM side (`ebd9628`, `b7dd336`, `98f2cd1`), so no `Main_MiSTer` merge was needed. |
| | Dropped the whole DMA half of the old patch set — `ddram_ctrl`/`sdram_ctrl` dma ports, the CPU-port hijack mux, `a4091_dma_tail`, `ramcinhibit`, the SDC DMA multicycles. Dead weight since the software SIOP ties `dma_req` to 0, and precisely the part upstream's `memory_router` refactor would have broken. |
| | **AutoConfig chain order**: RTG assigned *after* the Z3 RAM board so fast RAM keeps `$40000000`. |
| **ARM** | `rdb_fixup_last()` in `a4091_scsi.cpp` — presents `RDBFF_LAST` per the live chain on the READ path (set for the highest configured ID, cleared for the rest, RDB checksum recomputed). The `.hdf` bytes are never modified. |
| **Tools** | `rdb_lastflag.py` (inspect/edit the RDB flag), `rtg_paint_z3.c` (Zorro III framebuffer paint diagnostic), `coloricon.py` / `icontool.py` / `mister_icon.py` (Amiga `.info` decode/encode). |
| **Packaging** | [`../../README.md#runtime-files`](../../README.md#runtime-files) — driver, diagnostics, the Zorro III `MiSTer.card`, icons, with an install map, provenance and checksums. |

Build: seed 1, **0 errors**, clk_114 setup slack **+0.053**, 58 % ALMs →
`minimig_20260906_A4091_RTG_A2065_v2.rbf`.

## Tested on hardware

| Test | Result |
|---|---|
| AutoConfig chain | Five boards enumerate: Toccata, A2065 `514/112` @`$EA0000`, Z3 FastRAM 256 MB @`$40000000`, RTG Z3 `139C/30` @`$50000000`, A4091 `514/84` |
| A4091 regression (`swsiop_regress.py`) | **9/9**, run three times — two drives, six drives, and after the RDB fix |
| Multi-drive | Six SCSI targets probe, mount and carry distinct volumes |
| SCSI autoboot | AmigaOS 3.2 boots from ID 1 with IDE disabled (`SYS: → DHO:`) |
| A2065 | `Lance-Test diags` **5/5**; `addrs` finds the board at `EA0000`; eth0 in promisc |
| RTG | Board claims its window; registers + framebuffer verified byte-exact (`ENABLE=1`, 640×480×8bpp, BASE `$27000000`) |
| Icons | Drive icons and the MiSTer case icon confirmed rendering on the Workbench |

## Throughput

Two different ceilings, worth keeping apart.

**Real A4091 hardware.** NCR 53C710 on an 8-bit Fast SCSI-2 bus — **10 MB/s**
bus-rate ceiling; real cards in an A4000 typically land around 6–9 MB/s with a
period drive, DMA'ing into Zorro III fast RAM.

**This emulation**, `devtest -b -B 128k,4`, measured on the A4091-only build
that carries the same ARM code as the current core:

| | Throughput | Amiga CPU |
|---|---:|---:|
| Read | **8.5 MB/s** (8.2 typical) | ~41 % |
| Write | **4.2 MB/s** | ~18 % |

Up from 1.13 / 1.64 MB/s at first light — ~7× read, ~2.5× write. Two changes did
it: shrinking the driver's cache-evict sweep from 2 × 32 KB to a single 8 KB
region, and raising `MM_MAX_XFER` from 16 KB to 128 KB so fewer, larger SCSI
commands amortise the per-command cost.

**What limits it is not the SCSI side.** The software SIOP's DATA phase is an ARM
`memcpy` into HPS DDR, a path the journal puts at ~20–40 MB/s. The real cost is
per-command overhead: the SPI mailbox round trip per kick, `FileReadAdv` /
`FileWriteAdv` against the USB stick, and the mmap copy. That is why larger
transfers helped so much, and why write lags read — the file write is the slow
half. Past 128 KB per command the SCRIPTS scatter/gather list runs out of its 9
segments, so that knob is spent.

Caveats: those numbers predate the combined core, which now shares the DDR path
with RTG and A2065, and they were taken against a 200 MB test image — ID 1 is now
a 3.2 GB boot volume. Worth re-measuring rather than assuming; `devtest -b` is
non-destructive.

## Open

1. **RTG display switch not visually confirmed.** The FPGA side proves out, but
   the MiSTer `screenshot` capture returns the Amiga video path, so whether the
   monitor actually flips to the framebuffer needs eyes on it, or a P96
   screenmode change. The one real gap.
2. **The ARM assumes Z3 fast RAM is at `$40000000`** (`ddr_ptr()`). It should
   learn `z3ram_base0` — e.g. carried in the `a4091_dbg_bus` word read over
   `hps_ext 'h68` — so AutoConfig order stops mattering.
3. `swsiop_regress.py` defaults to `--scsivol DH0.1:`, stale under SCSI boot;
   pass `--scsivol SH1:`.
