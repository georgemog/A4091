# A4091 on MiSTer — status & known issues

As of 2026-09-06, the **software SIOP** (branch `claude/a4091-software-siop`)
works end-to-end on real hardware and **supersedes the RTL SIOP** and the
`displit` stopgap.

Architecture: a thin FPGA bridge (`a4091_bridge.v` — 256-byte shadow
53C710 register RAM + kick flag + IRQ, no DMA datapath) + `Main_MiSTer`
running the ported 53C710/SCRIPTS VM (`a4091_lsi.cpp`) and a C1 SCSI-2
target (`a4091_scsi.cpp`). The DATA phase is an ARM `memcpy` into HPS DDR
(Z3 fast RAM is physically DDR: `phys = 0x30000000 + (A − 0x40000000)`,
16-bit halfword byte-swap). The whole RTL 16-bit-DMA corruption family
(the old P1..P7) is bypassed. Full history in `JOURNAL.md` (newest on
top).

Deployed: RBF `minimig_20260906_A4091_evict8k_x128`, `Main_MiSTer` binary
`MiSTer.evict8k_x128` on `mister`.

## Verified on hardware

- Autoconfig, boot ROM, `devtest -p / -g / -t` (probe / geometry /
  INQUIRY / TUR / RC10 / RC16 / CMD_READ / ETD_READ / TD_READ64 / SEEK)
- Mount at cold boot **and** warm `C:Reboot`, 0 errors, data persists
- `Format DRIVE … FFS QUICK` and a full non-quick format of the 200 MB
  disk
- HDToolBox: Change Drive Type, Save Changes, **Low-level Format** — full
  run, no hang
- 3.3 MB LhA write + `lha t` CRC round-trip; a 4× 3.3 MB copy/CRC on a
  fragmenting disk
- Multi-drive: two SCSI IDs, isolated
- Regression suite `A4091/tools/swsiop_tests/` **10/10** + host
  `ddrmap_test` 14/14
- Boot stays on IDE DH0; the SCSI drive is `DH0.1` (the RDB names its
  partition "DH0"; AmigaOS renames to `.1`)

## Done this branch

Release build (runtime-gated logging), C1 SEEK + READ CAPACITY(16),
`ddr_ptr()` bounds check (an out-of-window Amiga address used to reboot
the whole box), RTL SIOP retired (Quartus 0 errors, clk_sys +0.390),
Main_MiSTer integration README + patch, regression suite.

**Throughput** (`devtest -b`): read **1.13 → 7.9 MB/s (~7×)**, write
**1.64 → 4.0 MB/s (~2.5×)**, Amiga CPU 92 % → ~39 %. Two changes, both
in `driver-patches/`:
- `mm_ramctrl_cache_evict()`: 2× 32 KB → 1× 8 KB, and only the buffer's
  RAM region (`cpu_cache_new` is 4 KB 2-way). It flushes the RAM-
  controller read cache, which cannot snoop the ARM's mmap DDR writes.
- `MM_MAX_XFER` 16 KB → 128 KB — fewer, larger SCSI commands amortise
  the evict and the per-command `siop_checkintr` round trip. The
  "64 KB / 256 KB wedges the VM" reports were test-environment
  collateral, not real.

## Follow-ups (not blockers)

1. **Write throughput lags read** (4.1 vs 8.5). Remaining gap is
   `FileWriteAdv` to the USB stick and the per-command SPI-mailbox round
   trips, not the cache path. The DMA seam (`pci710_dma_rw`) no longer
   calls `ddr_ptr()` per byte; the driver evict is gone (item 2).
2. ~~**FPGA snoop-invalidate**~~ — done, kept. `a4091_bridge` pulses
   `cpu_cache_new`'s clear via a registered `cpu_cacr_a4091` after a
   DATA-IN (hps_ext `0x67` bit4); `mm_ramctrl_cache_evict` retired behind
   `#ifdef MM_DRIVER_CACHE_EVICT`. clk_114 slack **+0.057** (thin — the
   combinational first cut was −0.127; registering on clk_sys fixed it).
   Gain is small (~+4 % read) because the 8 KB evict had already stopped
   being the bottleneck. Prior attempts that broke the core used the
   *snoop* port (needs data) or `cache_inhibit`; this uses the CPU's own
   cache-clear path.
3. ~~**`MM_MAX_XFER` > 128 KB fragmentation risk**~~ — not a real risk on
   this platform. The `datain`/`dataout` SCRIPTS hold 9 S/G segments and
   a non-disconnecting target (our C1) can't drive the `siop_checkintr`
   chain-shift, so >9 physical segments *would* corrupt — but Minimig has
   no MMU and Z3 fast / chip RAM are each physically contiguous, so
   `CachePreDMA`+`DMA_Continue` always coalesce a transfer buffer to 1–2
   `ds.chain` entries regardless of size. 128 KB stays the shipped value
   for throughput reasons (bigger = diminishing returns), not S/G safety.
4. **`ncr7xx` self-test — won't fix.** It is a *silicon* validation tool
   and the software SIOP is the wrong shape for it: t1 needs CTEST5
   ADCK/BBCK counter emulation, t2/t3 a DMA/SCSI FIFO RAM+parity model,
   t5/t6 register-poke DMA without SCRIPTS, t8 a real SCSI bus loopback
   (there is no bus). Only t1 was cleanly doable (bridge-side CTEST5
   emulation, prototyped in `273591ea`, reverted in `c19799e5`); the
   rest fight the architecture. Not a functional blocker — disk I/O,
   format, mount, HDToolBox and the regression suite all pass without
   it.
5b. ~~**HDToolBox low-level format hang**~~ — its bulk zero-write is
   WRITE(6) with a block count but no data buffer; the C1 target demanded
   a DATA-OUT phase a4091.device never drove, the SCRIPTS VM spun the
   9-entry S/G to the watchdog and the next command tripped
   `assert(s->current == NULL)`. `lsi_do_dma` now completes a transfer
   the initiator stalls on (>= 12 zero-byte MOVEs) as a zero-filled short
   write. See `tools/scsi_wr6.c`.
5. ~~**HDToolBox "No Disk Inserted"** / **low-level format crash**~~ —
   FIXED. The C1 MODE SENSE(6) ignored the page code (no geometry page →
   HDToolBox couldn't ID the drive) and MODE SELECT(6/10) + FORMAT UNIT
   with a defect list fell through as no-data commands while a4091.device
   drove DATA-OUT (VM deadlock). Now real mode pages 0x03/0x04, and
   0x15/0x55/0x04-FmtData consume+discard the parameter list. HDToolBox
   shows "MiSTer 200MBSCSI"; `scsi_fmt` 6/6 clean.
6. ~~**The a4091 ROM is `$readmemh`-baked into the RBF**~~ — FIXED &
   verified. `(* ram_init_file *)` + `a4091_rom.mif` → `rom_mem` is an
   inferred `altsyncram` with INIT_FILE. A driver-only ROM change is now
   `quartus_cdb --update_mif` + `quartus_asm` = **~1.5 min** (was
   ~27 min). Full compile 0 errors, timing unchanged.
7. **Upstream** — the `Main_MiSTer` C++ lives on the build box, not this
   repo. `A4091/integration/main_mister/` mirrors the new files;
   `A4091/integration/main_mister_swsiop.patch` is the modified-file
   diff. Needs a fork-or-patch decision, then a PR.

## Build

- FPGA: Quartus `quartus-host`, `/tmp/mm-a4091` (Minimig-AGA branch `MiSTer` +
  `A4091/integration/` patches + `A4091/rtl/a4091/*.v`).
  `rm -rf db incremental_db && quartus_sh --flow compile Minimig`.
- ROM-only change (no RTL/logic change): copy the new
  `rtl/a4091/a4091_rom.mif` and `quartus_cdb Minimig -c Minimig
  --update_mif && quartus_asm Minimig -c Minimig` (~1.5 min).
- ARM: `build-host` `/opt/development/minimig/Main_MiSTer`,
  `PATH=/opt/armV7-linux-gcc/bin make -j4`. `-DA4091_SWSIOP_TRACE` or
  `touch /media/usb0/a4091_debug` for tracing.
- a4091.device / ROM: `build-host` `/tmp/a4091-software` @ `a199fa8` + the
  `driver-patches/`, `PATH=/opt/amiga/bin:/opt/vbcc/bin VBCC=/opt/vbcc
  make DEVICE=A4091 a4091.rom`, then `rom/make_hex.sh a4091.rom`
  (emits `a4091_rom.hex` for the tb + `a4091_rom.mif` for Quartus).
- Deploy: build box → local `A4091/build/` → `root@mister`.

## Test / debug tooling (this repo)

- `A4091/tools/swsiop_tests/` — `ddrmap_test.c` (host unit test) +
  `swsiop_regress.py` (MiSTer serial suite) + `aserial_lib.py`.
- `A4091/tools/aserial.py` — run one AmigaDOS command over the Minimig
  serial console (`ttyS1`), print its output.
- `A4091/tools/scsi_rd.c` — one `CMD_READ` of N blocks, 3 passes, prints
  the first 4 bytes of each block (byte-exact ground truth vs the .hdf).
- `A4091/tools/scsi_fmt.c` / `scsi_fmt2.c` — HD_SCSICMD harnesses
  (FORMAT UNIT / MODE SELECT / WRITE / READ verify).
- `A4091/tools/uinput_kbd.c` / `uinput_mouse.c` — ARM headless-input
  helpers for driving the core.
- `echo screenshot > /dev/MiSTer_cmd` → PNG in
  `/media/fat/screenshots/Minimig/`.
- `SHARE:` on the Amiga = `/media/usb0/games/Amiga/shared/`.
- Pristine test image: `/media/usb0/Test200MB.hdf.pristine` on the box
  (restore + reformat when the test volume gets corrupted).
