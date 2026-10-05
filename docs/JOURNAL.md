# A4091 MiSTer — journal

Running log of builds, hardware tests, and findings. Newest entry on top.
See `mister-plan.md` for the plan, `rtl/STATUS.md` for RTL state,
`integration/build-notes.md` for Quartus detail.

Environment: build/Quartus server `quartus-host`. **Current build dir
`/tmp/mm-combined`** — git worktree, branch `a4091-rtg-a2065` off `rtg-z3`
(= `Minimig-AGA_MiSTer` `b265a3b` "Release 20260823" + the Z3 RTG commits,
which also brings the upstream A2065) + `integration/combined/` +
`rtl/a4091/*.v`. The older A4091-only tree `/tmp/mm-a4091` sits on `eb7a26e`
("Release 20260603") and its patches do not apply to the newer base.
Deploy: `quartus-host` → local `A4091/build/` →
`root@mister:/media/fat/_Computer/`. Enable via
`A4091/tools/mmcfg.py --a4091 minimig.cfg` (`O[57]`), then core reload
(`echo load_core … > /dev/MiSTer_cmd`).

Tools on the Amiga: `<shared>:a4091/` — `ncr7xx`, `a4091d`, `a4091.device`,
`devtest` (from a4091-software v42.39), `a4091dbg` (SIOP snapshot + ring),
`peek` (memory dump). All tool output is prefixed `[YYYYMMDD-hhmmss]`.
Copies of these, plus the Zorro III `MiSTer.card` the RTG board needs, are
vendored in `resources/` — see `resources/README.md` for what installs where.

---

## 20260907-13xx — AmigaOS AUTOBOOTS from the A4091. Constraint retired.

IDE disabled, SCSI ID1 pointed at the 3.2 GB `AmigaOS3.2.hdf`, five 200 MB
drives behind it: the machine boots AmigaOS 3.2 straight off the board's
autoboot ROM.

```
SYS  ->  DHO:                       ; DF0-3 empty, no IDE hardfile
DH0      3199M  Read/Write  DHO     ; SCSI ID 1
SH1..SH5  199M each                 ; Test2..Test6
devtest -p: 1 A4091 HD 512 3355 MB, 2..6 = 209 MB
scsi: ID1 present (6553600 blocks)
scsi: ID1 RDB block 0: RDBFF_LAST cleared (last ID is 6)
```

The whole ROM path — autoconfig → DiagArea copy → romtag → mounter → boot —
works on the combined core. This supersedes the bring-up rail "boot from IDE,
SCSI is a non-bootable data drive at ID1, never boot from SCSI"; that existed
to keep a debuggable machine while the DMA/SIOP path was unreliable.

Caveat for the suite: `swsiop_regress.py` defaults to `--scsivol DH0.1:`,
which does not exist in a SCSI-booted setup — pass `--scsivol SH1:`.

## 20260907-12xx — Drive icons: ColorIcon transplant (no icon editor).

The artwork Workbench draws is not the planar image in the `.info` — it is the
OS3.5-style **ColorIcon** (`FORM…ICON` with `FACE`/`IMAG`, RLE, 46×46)
appended to the file. `ENVARC:Sys/def_harddisk.info` is the same drive unit
already drawn *without* the beachball, so rather than repaint pixels the whole
`FORM ICON` block (both render states) was transplanted into each volume's
`Disk.info`, preserving its DrawerData (window snapshot) and tooltypes.
2372 → 1620 bytes. Applied to `DH0.1:` and `SH1:`–`SH5:`; `DH0:` later
restored to the original beachball icon on request. Decoder/encoder:
`resources/tools/coloricon.py` (+ `icontool.py` for the planar half).

Gotcha found on the way: a reboot came up on a *different* Workbench (2023
title bar, `HDSetup3.2` volume, no serial `newcli`). Cause was the HDSetup
ADF still in DF0 from partitioning — floppy outranks the HD at boot.
`/dev/MiSTer_cmd` has no eject (only `fb_cmd`, `video_mode`, `load_core`,
`screenshot`, `volume`), but `load_core` re-applies the saved config, which
has no ADF, and that drops it.

## 20260907-09xx — Fully loaded bus: six drives mount; cloned images collide.

All six IDs populated, but only two icons on Workbench. Not a mount failure:
`info` showed all six devices mounted and the RDB fixup tracking the growing
chain (`... cleared (last ID is 4)` then `(last ID is 6)`). The images for
IDs 2-6 were clones of one formatted `.hdf`, so every filesystem carried the
same volume **name and creation date** — the pair AmigaOS uses to identify a
volume. DOS bound all five as one: same label on every device, one icon, and
`Relabel` appeared to rename them all (it did write each image — mtimes prove
one write per file — but the shared volume node masked it until a reboot).
`Relabel SH2: Test3` … + `C:Reboot` → six distinct volumes. Regression 9/9
with the bus full (`probe PASS 6 MiSTer A4091 HD`).

Rule: relabel a cloned image before use, or partition/format each separately.

## 20260907-09xx — RDBFF_LAST now presented per the live chain (ARM side).

`a4091_scsi.cpp` READ path (`case 0x08/0x28`) gained `rdb_fixup_last()`: any
served read reaching into blocks 0-15 gets an `RDSK` block's `rdb_Flags`
rewritten **in the returned buffer** — `RDBFF_LAST` set for the highest
configured SCSI ID, cleared for the rest — with the RDB checksum recomputed.
The `.hdf` bytes are never touched, so images stay portable and HDToolBox is
unaffected; because it keys off which targets are `present`, adding a drive at
a higher ID moves the flag automatically. The write path is deliberately left
alone: if AmigaOS writes the block back, the corrected flag lands on disk,
which is what the image should have said anyway.

Verified with both images deliberately set *back* to the broken `0x17`:
`scsi: ID1 RDB block 0: RDBFF_LAST cleared (last ID is 2)`, both drives mount,
regression 9/9.

Deploy note: `/media/fat/MiSTer` cannot be overwritten while running ("Text
file busy"), but `/etc/inittab` starts it with **sysinit, not respawn** — so
`killall MiSTer`, copy, `reboot`. A reboot also wipes `/tmp`, taking
`/tmp/swsiop_tests` with it.

## 20260907-08xx — Only the first SCSI drive mounted: RDBFF_LAST, not the core.

HDToolBox listed both drives; only ID1 mounted. `devtest -p` saw both units
and `devtest -g a4091.device 2` returned correct geometry, so bridge, ARM SIOP
and driver were all fine. The boot ROM's mounter stops walking targets at the
first drive whose RDB claims to be last (`3rdparty/mounter/mounter.c`):

```c
md->wasLastDev = (flags & RDBFF_LAST) != 0;      /* rdb_Flags bit 0 */
if (md->wasLastDev && !ms->ignoreLast) break;    /* no further targets */
```

Both `.hdf`s were partitioned independently, each as "the only drive", so both
carried `rdb_Flags = 0x17` (LAST|LASTLUN|LASTTID|DISKID). Reproduced on the
previous A4091-only RBF too — pre-existing, not a combined-core regression.
New tool `tools/rdb_lastflag.py` shows/sets/clears the flag with a correct RDB
checksum; clearing it on ID1 (`0x17 → 0x16`) made `SH1` appear. Superseded the
same day by the ARM-side fixup above.

The alternative was a ROM fork (`ms.ignoreLast = 1`): measured at ~15 min total
— `make DEVICE=A4091 a4091.rom` on `build-host` takes **6.5 s** (toolchain all
present; only the CD-ROM filesystem ROM fails, an `ar` LTO-plugin issue,
irrelevant), then MIF regen + a Quartus MIF/HEX Update rather than a full
recompile. Not done: it would force the mounter to probe all 8 targets always,
and the flag stays semantically truthful with the ARM fixup.

## 20260906-19xx — Combined core v2: A4091 + Z3 RTG + A2065, all verified.

Fixed the chain order (below) and rebuilt: **0 errors, clk_114 setup +0.053**,
58 % ALMs, RBF `minimig_20260906_A4091_RTG_A2065_v2.rbf`. On hardware:

```
 Commodore (West Chester) A 2065 Ethernet:  Prod=514/112  (@$EA0000 64KB)
 Rok Krajnc Minimig Z3 FastRAM:  Prod=5020/16   (@$40000000, 256MB)
 Rok Krajnc Minimig Z3 GraphicsCard: Prod=5020/48 (@$50000000, 16MB)
 Commodore (West Chester) A 4091 SCSI:  Prod=514/84 (@$51000000, 16MB)
```

A4091 regression **9/9**, `DH0.1` auto-mounts, geometry correct. A2065
`Lance-Test diags` **5/5** (buffer/config/interrupt/collision/loopback), eth0
in promisc. RTG claims its window and its registers + framebuffer read back
byte-exact (`ENABLE=1`, 640×480×8bpp, BASE `$27000000`) via a new Zorro III
port of the paint diagnostic — the deployed `rtg_paint`/`rtg_dump` still hunt
the retired two-board Zorro II products `0x03`/`0x04`. On-screen switch not
eyeballed (the MiSTer `screenshot` capture returns the Amiga video path).

Also: `SHARE:RunLanceTest` writes to `serial:`, which is not mounted — it hangs
the Amiga shell behind an "insert volume serial" requester. Run
`SHARE:Lance-Test diags` directly.

## 20260906-18xx — Combined core v1: all boards enumerate, a4091.device expunges.

First hardware run of the forward-port. All five boards autoconfigured, the
board window / boot ROM / 53C710 register window all read back correctly — but
no SCSI volume mounted and `devtest` reported "no device found".

Cause: **AmigaOS hands out Zorro III space in autoconfig chain order.**
Upstream places the RTG board ahead of the Z3 RAM board, so fast RAM moved
from `$40000000` to `$50000000` — and the ARM's DMA seam hardcodes that base
(`minimig_a4091.cpp :: ddr_ptr()`, `phys = 0x30000000 + (A - 0x40000000)`).
Every driver buffer address fell outside the ARM window, the bounds check
rejected it, the probe found no units, and `a4091.device` expunged itself.
Fix: move the `ac_rtg` branch after `ac_memcard[2]` in both the nibble mux and
the base-latch ladder, so the RAM keeps `$40000000`. RTG is indifferent to its
own base (dynamic 128 MB compare). Longer term the ARM should learn the real
`z3ram_base0` (e.g. via the `a4091_dbg_bus` word on `hps_ext` `'h68`).

Timing on this build (seed 4) also missed: clk_114 setup **-0.548**, worst path
Agnus beamcounter → Gary → `chipdma_arb` → `sdram_ctrl.sd_addr[9]` — stock
chipset logic, nothing A4091. Seed 1 fits at +0.053.

## 20260906-17xx-b — Forward-port: A4091 onto Release 20260823 + Z3 RTG.

Retargeted the software-SIOP integration from `eb7a26e` (Release 20260603) to
`b265a3b` (Release 20260823) + branch `rtg-z3-graphics-card`, giving one core
with all three boards — **A2065 comes free**: it is upstream in Minimig
`809b955`, and its ARM half is upstream in `Main_MiSTer` master (`ebd9628`,
`b7dd336`, `98f2cd1`), the same `915ca33` the A4091 patch builds on. No
Main_MiSTer merge was needed.

The port is small because the software SIOP has **no FPGA bus master**
(`a4091_bridge.v` ties `dma_req` to 0). Dropped entirely: the dedicated `dma*`
ports on `ddram_ctrl`/`sdram_ctrl`, the `cpu_addr`/`cpustate` hijack mux,
`a4091_dma_tail`, `ramcinhibit`, the SDC DMA multicycles — which is exactly the
half that upstream's `memory_router.v` refactor (address decode moved out of
`cpu_wrapper.v`, second instance in `chipdma_arb.v`) would have broken. Also
dropped the vestigial `CONF_STR` `S0,HDFIMGHDF` / `VDNUM(1)` / `img_mounted`
wiring — `minimig_a4091.cpp` opens the `.hdf`s itself. Kept: autoconfig link
(A4091 last), board window + DTACK, boot ROM, the `hps_ext` `'h64`-`'h68`
mailbox, INT2, the registered `cpu_cacr_a4091` cache-clear OR. `hps_ext.v` was
rewritten upstream (akiko/cdtv now share `'h61`-`'h63`); `'h64`-`'h68` remained
free. Patches + full write-up in `integration/combined/`.


## 20260906-17xx — HDToolBox low-level format: WRITE(6)-with-no-data hang fixed.

HDToolBox's "low-level format" for the MiSTer drive type = write zeros. It
issues **WRITE(6) with a block count but a zero-length data buffer**
(`scsi_Length = 0`) - expecting the drive to zero the blocks itself. The
C1 target computed `data_len = blocks*512` from the CDB and demanded a
DATA-OUT phase a4091.device never delivered: the SCRIPTS VM spun on an
empty 9-entry S/G (`MOVE FROM ds_DataN` all len 0, `switch` loops back to
`dataout` while phase stays DATA_OUT), hit the 10000-instruction
watchdog, force-disconnected without freeing the request, and the next
SELECT tripped `assert(s->current == NULL)` -> MiSTer abort -> Amiga hang.

Fix: `lsi_do_dma` now counts consecutive zero-byte MOVEs; after a full
pass of the S/G with no progress (>= 12) it treats it as a short
transfer - `scsi710_req_get_buf` (which zero-fills a write buffer) then
`scsi710_req_continue` takes the terminal path (`emulate` the zeroed
write, `command_complete`, free). `scsi_tools/scsi_wr6` reproduces it
headless: no-data WRITE(6) now `err=0 status=0`, blocks read back zero,
MiSTer alive. Regression 10/10. **Verified end-to-end**: the full
HDToolBox Change-Drive-Type -> Save -> Low-level Format run completes, no
hang.

Also: `MM_MAX_XFER > 128 KB` note (follow-up #3) is only partly right -
a *raw HD_SCSICMD* write with no S/G still hits this; FS I/O never does.

## 20260906-16xx — FPGA snoop-invalidate: works, marginal, kept.

Follow-up #2. Wired `a4091_bridge` to pulse `cpu_cache_new`'s clear (via
`cpu_cacr[3]`) after a DATA-IN: new hps_ext `0x67` bit4 -> bridge holds
`cache_clr` ~64 clk_sys -> `Minimig.sv` ORs it into a **registered**
`cpu_cacr_a4091` feeding both RAM controllers. The ARM strobes it from
the kick loop when `pci710_dma_rw` wrote Amiga RAM. Driver
`mm_ramctrl_cache_evict` retired behind `#ifdef MM_DRIVER_CACHE_EVICT`.

- Build 1 (combinational `cpu_cacr_a4091`): 0 errors but **clk_114 slack
  -0.127** - `a4091_cache_clr` routed across the die into the cache
  control path. Not deployed.
- Build 2 (registered on clk_sys): **slack +0.057**, boots clean,
  regression 10/10, no evict, `write_integrity`/`marker_roundtrip`
  CRC-clean - the FPGA flush alone keeps reads coherent.

`devtest -b -d -y -B 128k,4`: read **8.2 -> 8.5 MB/s**, write ~4.1
(flat). Small - the 8 KB single-region evict was already down to ~1.5 ms
and 128 KB commands are rare, so the evict had stopped being the
bottleneck (it's now the SPI-mailbox round trips + `FileReadAdv` + the
mmap copy). Kept per user call despite the thin timing margin.

tb: new G9 (cache_clr strobe hold/release). RBF
`minimig_20260906_A4091_snoop2_noevict` (`e1ef1667`... then ROM re-gen
`978f7ac9` pending a MIF update - dead-code layout only), ARM `d5a6b06c`.

## 20260906-16xx-b — Menu: A4091 SCSI inlined on the Drives page.

Was a sub-page (`MENU_MINIMIG_SCSI1/2`). Now inline under the IDE drives,
scrolling: menusub 14 = enable (gated `cpu & 2`, so hidden on 68000 -
Zorro III needs an 020+), 15/16..25/26 = ID1..ID6 type/path, 27 = BACK.
`menumask` was already `uint64_t`. Blank line between the IDE slots and
the A4091 section. Sub-page states deleted.

## 20260906-16xx — Follow-up #3 (MM_MAX_XFER >128 KB S/G risk): closed, not real.

Read the `datain`/`dataout` SCRIPTS (`siop2_script.ss`) + `siop_dma_setup`
/ `siop_checkintr` (`siop.c`). The SCRIPTS hold 9 `MOVE FROM ds_DataN`;
past 9 physical segments they'd re-run `ds_Data1..9` (switch → JUMP
datain) and re-DMA the first 9 — the NetBSD driver only survives that via
the target disconnecting mid-DATA and `siop_checkintr` shifting
`ds.chain[i..]` down. Our C1 target never disconnects, so >9 segments
*would* corrupt.

But it can't happen here: fx68k has no MMU and Minimig Z3 fast / chip RAM
are each one physically-contiguous region, so `kvtop` is identity and
`CachePreDMA`+`DMA_Continue` coalesce any transfer buffer to 1–2
`ds.chain` entries no matter how large. 128 KB stays the value for
throughput (diminishing returns past it), not S/G safety.

## 20260906-15xx — DMA seam: hoist ddr_ptr out of the per-byte loop.

Follow-up #1 (write profiling). `pci710_dma_rw` was calling `ddr_ptr()`
once **per byte** — 128 K calls per transfer, each redoing the range /
window-compare bookkeeping, then a byte-at-a-time store to uncached mmap
DDR.

`ddr_map_range()` now maps the whole `[addr, addr+len)` span once and
returns the window base + un-XORed offset; the copy walks it with
`base[(off+k) ^ 1]` addressing, 16-bit accesses on the aligned interior
(the Z3 halfword byte-swap = swap each pair). Window-straddling or
out-of-Z3 ranges fall back to the old per-byte path.

`devtest -b -d -y -B 128k,4` on `mister`:

|        | before (f66444d8) | after (688d87ec) |
|--------|-------------------|------------------|
| read   | 7.1 MB/s / 35 %   | **8.2 MB/s / 41 %** |
| write  | 3.9 MB/s / 19 %   | **4.2 MB/s / 18 %** |

Smaller than hoped: the byte loop was real overhead but not dominant.
Write is gated by `FileWriteAdv` to the USB stick; read by the
`mm_ramctrl_cache_evict` sweep + the SPI-mailbox round trips. `devtest
-i 65536 -d` integrity: WRITE(6)/READ(6) 64 KB pairs, all st=00, no
CHECK, box stable.

## 20260906-14xx — C1 target: MODE SELECT + FORMAT-UNIT DATA-OUT, real MODE SENSE pages.

Follow-up #5 (HDToolBox cosmetic) + the "low-level format crashes the
drive" report — same root cause.

Added a runtime-gated CDB trace to the C1 target (`slog` in
`scsi710_req_enqueue` + `set_check`; only writes when
`/media/usb0/a4091_debug` exists — no rebuild, no 100 MB log). It showed:

- **`No Disk Inserted` in HDToolBox** = MODE SENSE(6) ignored the page
  code and returned only a header+block-descriptor, no pages. HDToolBox
  asks for page 0x03 (Format Device) and 0x3F (all); with no geometry
  page it can't identify the drive. Now returns real page 0x03 + page
  0x04 (Rigid Disk Drive Geometry) with H/S/C derived from the capacity,
  honours DBD and the page code, 0x3F = both. HDToolBox now shows
  "MiSTer 200MBSCSI".
- **Low-level format hang** = MODE SELECT(6/10, 0x15/0x55) fell through to
  the `default` CHECK with `direction = 0`, and FORMAT UNIT with FmtData=1
  (0x04, defect-list DATA-OUT) was hard-coded `direction = 0`. Either way
  the target expected no data phase while a4091.device's SCRIPTS drove
  DATA-OUT → the VM set PHASE_DI, both sides deadlocked. Now 0x15/0x55 and
  FmtData FORMAT UNIT are DATA-OUT commands: consume and discard the
  parameter list, return GOOD.
- **READ DEFECT DATA(10, 0x37)** returned CHECK/invalid-opcode; now an
  empty 4-byte defect list.

`tools/scsi_fmt.c` extended (MODE SELECT, MODE SENSE page 4, READ DEFECT
DATA) — 6/6 clean on hardware, `grep -c CHECK a4091_sd.log` = 0. Page-4
read-back: cyls 406, heads 16, 7200 rpm, 409600 blocks, 512 B.

Deployed `MiSTer` 688d87ec (this + the DMA-seam change) on
`mister`. **Regression 10/10** — `write_integrity` size_ok +
crc_ok, `mount`/`marker_roundtrip`/`quick_format` all PASS.

## 20260906-13xx — Boot ROM: .mif (ram_init_file) instead of baked $readmemh.

Follow-up #6. `$readmemh` in an `initial` block is baked at synthesis;
`SMART_RECOMPILE` "Update MIF/HEX files" is a no-op for it, so every
driver-only ROM change cost a full ~27 min recompile.

Fix: `(* ram_init_file = "rtl/a4091/a4091_rom.mif" *)` on `rom_mem`.
Quartus reads the .mif at synth; the ~2 min incremental MIF/HEX update can
regenerate it. tb keeps loading the byte-per-line .hex via `$readmemh`,
now `ifdef A4091_ROM_HEX`-guarded (tb Makefile passes the define, Quartus
does not). `rom/make_hex.sh` emits both files from the same `a4091.rom`.

tb: ALL GROUPS PASS. Committed `c1becde2`.

**Verified on `quartus-host`** (2026-09-06 13xx, box freed up): full recompile
0 errors — `Info (286033): Parameter INIT_FILE set to
rtl/a4091/a4091_rom.mif`, `rom_mem` now an inferred `altsyncram` with an
INIT_FILE (was a baked `$readmemh`). Timing slacks all still positive.
Then a `.mif`-only byte edit (`FFFF: 48 -> 99`) through
`quartus_cdb --update_mif` + `quartus_asm`: **"MIF/HEX Update was
successful", 1 m 33 s total**, RBF md5 flips and flips back on restore —
deterministic. ~27 min -> ~1.5 min for a driver-only ROM change. The
restored RBF is byte-identical to the deployed
`minimig_20260906_A4091_evict8k_x128` (`d1de2476`) — same 128 KB ROM
image, so no redeploy needed; the win is future iteration speed.

## 20260906-12xx — Throughput: MM_MAX_XFER 64 KB -> read 5.5 MB/s (4.8x from baseline).

The "64 KB single command wedges the VM" was a **misdiagnosis** (test-env
collateral, like the "256 KB hang"). Traced a clean 64 KB `scsi_rd` and
`devtest -b -B 64k..512k`: single 64 KB READ(6)/WRITE(10) commands run
fine, box stable, regression `write_integrity` CRC-clean.

`MM_MAX_XFER` 16 KB -> 64 KB: 4x fewer commands -> 4x fewer evict
sweeps. Read **2.15 -> 5.46 MB/s** (55 % Amiga CPU, was 92). Write
~1.7 MB/s (no DATA-IN evict). `-B 128k/256k/512k` all ~5.6 - `sd_readwrite`
caps at 64 KB/command.

**128 KB `MM_MAX_XFER` -> read 7.4 MB/s, 36 % Amiga CPU.** The
fragmentation risk (a non-contiguous 128 KB buffer > 9 S/G segments)
did not bite: regression 10/10 + a 4x 3.3 MB LhA copy/CRC on a filling
disk, all clean. So the datain multi-pass either isn't hit (FFS buffers
stay < ~9 segments) or the phase-mismatch reload converges.

**Final (128 KB, evict8k):  read 7.9 MB/s / 39 % CPU,  write 4.0 MB/s /
18 % CPU.**  From baseline: read **~7x** (1.13 -> 7.9), write **~2.5x**
(1.64 -> 4.0). Write improved too - bigger transfers = fewer
`siop_checkintr` round trips, even though the write path has no
cache-evict. The Amiga is no longer the bottleneck.

RBF `minimig_20260906_A4091_evict8k_x128` (full recompile, 0 err,
clk_sys +0.390), ARM unchanged (pB23).

## 20260906-11xx — Throughput: evict-sweep shrink -> read 1.13 -> 2.15 MB/s (1.9x).

`mm_ramctrl_cache_evict()`: 2x 32 KB stride-8 (both `cpu_cache_new`
instances) -> **1x 8 KB** of just the buffer's region (chip: < 0x200000
or slow 0xC00000-0xD7FFFF via sdram_ctrl; else fast via ddram_ctrl).
`cpu_cache_new` is only 4 KB 2-way; a DMA buffer is contiguous in one RAM
type.

Also `MM_MAX_XFER` 4 KB -> 16 KB (the committed patch was 4 KB; the
deployed 09/04 ROM used 16 KB - now pinned). 64 KB was tried and
**wedges the VM** (single SCSI command whose data phase needs > 9 S/G
segments -> the datain SCRIPTS run out of MOVEs -> phase-mismatch reload
desync). 16 KB stays 1-pass.

Build pipeline learned:
  * `/opt/vbcc` + `make DEVICE=A4091 a4091.rom`, then `rom/make_hex.sh`.
  * The a4091 ROM is `$readmemh`-initialised inferred RAM. Quartus
    `SMART_RECOMPILE`'s "MIF/HEX Update" does **NOT** touch it - it
    produced a byte-identical RBF. Need `rm -rf db incremental_db` +
    full `--flow compile` (~27 min) for a ROM change.
  * The repo's `rom/a4091.rom` + `rtl/a4091_rom.hex` were stale (Aug 29,
    pre-patch); the 09/04 driver was built on the box and never
    committed. Fixed now.

RBF `minimig_20260906_A4091_evict8k` (a4a19f7a), 0 errors, clk_sys
+0.390. Regression **10/10** (write_integrity CRC-verifies a 3.3 MB
round-trip - the single-region evict is coherent). Read 2.15 MB/s /
84 % CPU, write 1.73 MB/s (write has no DATA-IN evict).

Remaining: the other ~half of the per-command gap is `siop_checkintr` +
the 16 KB mmap memcpy + S/G build. Next levers: fix the >9-segment
multi-pass DATA phase so `MM_MAX_XFER` can rise; or the FPGA
snoop-invalidate (deletes the sweep entirely).

## 20260906-10xx — Throughput root-caused: the driver's cache-evict sweep, not the SPI mailbox.

`devtest -b`: **1.14 MB/s, 92% Amiga CPU**. Three ARM-side experiments,
all ~0:
  * shadow-register SPI burst 256 B -> 64 B (the 53C710 file is 0x00-0x3F;
    the VM + poll loop never touch higher): +6%.
  * spin-poll the 0x64 mailbox at SPI speed instead of once per
    Main_MiSTer main loop: 0%.
  * CTEST1 (struct 0x16) = 0xf0 so `siop_checkintr`'s `while ((ctest1 &
    0xf0) != 0xf0)` FIFO-empty wait exits at once instead of its
    10000-iteration timeout: 0%.

Instrumented the poll: the Amiga runs 2 SCSI phases, then goes quiet for
**~11.6 ms**, then 2 more. That gap is
`mm_ramctrl_cache_evict()` (`driver-patches/mm_siop.patch`): after every
DATA-IN it reads **32 KB in fast RAM + 32 KB in chip RAM** to flush the
Minimig RAM-controller read cache (`cpu_cache_new`, which can't snoop the
ARM's mmap writes to DDR). 64 KB of uncached reads on a ~10 MHz 68020 ~=
11.6 ms per 16 KB command -> 1.14 MB/s.

**"Move to shared memory" does not help** - the ARM side is not the
bottleneck.

`cpu_cache_new` is only **4 KB, 2-way, 8-byte lines**. `MM_EVICT_SIZE`
32 KB is 4-8x oversized. Real fixes (all need a Quartus RBF rebuild - the
a4091 ROM is baked in via `$readmemh`):
  1. shrink the sweep to ~8 KB + skip the chip sweep when the buffer is
     in fast RAM: ~7x -> ~7-8 MB/s. Driver patch + ROM + RBF.
  2. bridge pulses `cpu_cache_new`'s snoop/invalidate port for the
     ARM-written range (mailbox carries addr/len); delete the driver
     sweep: ~150x on the coherency cost. RTL + ARM + RBF. (Prior snoop
     wiring attempts -> "green screen at boot"; `ramcinhibit=a4091_ena`
     -> "magenta crash".)

Kept (all correct, low-risk, no throughput change): 64 B SPI burst,
CTEST1=0xf0, spin-poll, ddr_ptr bounds. Regression 10/10, bench 1128 KB/s.

## 20260906-09xx — ">128 KB DATA phase" investigated: the driver caps at 16 KB. Real fix = a ddr_ptr bounds check.

The "128 KB ok / 256 KB wedges" limitation from earlier was a
**misdiagnosis**. Traced (`-DA4091_SWSIOP_TRACE`) a 256 KB `scsi_rd`
CMD_READ: the a4091.device splits it into 16 x `READ(6)`
`08.00.00.XX.20.00` = 32 blocks = **16 KB** each (`MM_MAX_XFER`,
`mm_sd.patch`). `siopvar.h` `AMIGA_MAX_TRANSFER` = 1 MB is the S/G
*segment* ceiling, not the per-command size. **No single SCSI command
this driver issues exceeds 16 KB** - the >128 KB path can't occur.
Verified: `scsi_rd a4091.device 1 512` (256 KB) and `... 2048` (1 MB)
both -> `err=0 io_Actual=<full>`, 3 consistent passes, no hang, box
stable.

The earlier "256 KB hang" was test-environment collateral (killed runs,
2-drive config residue, corrupted `DH0.1` FS).

**Real bug found + fixed:** `ddr_ptr()` had no bounds check. An Amiga
address < 0x40000000 (chip RAM, or a stray 0) -> `A - 0x40000000`
underflows -> `phys` wraps to a multi-GB `/dev/mem` offset -> the mmap'd
access is a wild SoC bus transaction -> **kernel fault, whole box
reboots** (not just MiSTer - seen twice during `devtest -i`). Fix: reject
`addr < 0x40000000` or `>= 256 MB` (the Z3-fast window) -> drop the byte
(0xFF read / dropped write), as the chip-DMA mailbox is tied off anyway.

Also: `RW_MAX_BYTES` 128 KB -> 1 MB (match `AMIGA_MAX_TRANSFER`; the
128 KB cap was from the misdiagnosis, nothing hits it). `opcode_names`
table `#ifdef` widened to `A4091_SWSIOP_TRACE` so a trace build links.

Regression 10/10 on the fixed build. Throughput unchanged (~1.1 MB/s
read / ~1.6 MB/s write - latency-bound).

## 20260906-08xx — Punch list, part 2 (items 1/2/3/6/7)

### Item 1 done — release build

`DEBUG_LSI` removed; per-SCRIPTS tracing is `-DA4091_SWSIOP_TRACE` only.
Logging runtime-gated on `/media/usb0/a4091_debug` (release build silent).
`BADF` never `assert()`s. Boots + survives core load, no log written.
Binary saved as `MiSTer.swsiop_pB14_release` on the box.

### Item 3 done — C1 SEEK + READ CAPACITY(16)

SEEK(6/10) `0x0b/0x2b` -> no-op GOOD; READ CAPACITY(16) via SERVICE
ACTION IN(16) `0x9e` SA 0x10 -> 32-byte descriptor. `devtest -g -t`:
`TD_SEEK Success`, `READ_CAPACITY_16 512 409600`.

### Item 2 done — throughput

`devtest -b` (release build): **~1105 KB/s read, ~1635 KB/s write**,
FLAT from 16 KB to 128 KB transfers. Latency-bound (one kick-poll round
trip per SCSI command), not size- or DMA-bound. ~11x the original RTL
SIOP (101 KB/s), ~1.5x its 16-bit-DMA best (719 KB/s). The next lever is
Q4: a real HPS IRQ instead of polling 0x64.

C1 buffer: was a fixed 64 KB array that silently truncated (and hung)
larger transfers. Now one shared buffer `realloc`-grown to the exact
transfer size. **New limitation found:** past ~128 KB in a single
READ/WRITE the a4091.device SCRIPTS `datain`/`dataout` (9 S/G segments)
re-run and desync - 128 KB ok, 256 KB wedges the Amiga. Mitigated:
`RW_MAX_BYTES` 128 KB, over-cap commands get CHECK CONDITION / INVALID
FIELD IN CDB *before* any DATA phase (no hang). Real FS I/O is <=64 KB.
Proper fix = multi-pass DATA phase in `a4091_lsi.cpp` (follow-up).

### Item 6 done — multi-drive

Set `minimig_config.scsi[1]` (SCSI ID2) = `system.hdf` via the `.minimig`
config (`scsi_cfg`@7269, `scsi[i]` = 1026 B each from 7270). `devtest -p`
-> **two** drives at ID1 + ID2; both geometry / RC10 / RC16 correct;
AmigaOS mounts both (`DH0.1`, `DH0.2`); per-ID marker files prove the
images are isolated (ID1 file absent on ID2 and vice-versa). Reverted to
ID1-only after.

### Item 7 partial -> done — upstream story

`A4091/integration/main_mister/README.md`: base commit, the 7
canonical new files, `main_mister_swsiop.patch` (now `git diff HEAD` of
user_io.cpp / menu.cpp / minimig_config.{cpp,h}), build + verify steps.

### Regression

`A4091/tools/swsiop_tests/swsiop_regress.py` 10/10 on the release +
buffer + cap + SEEK/RC16 build. Reordered: SIOP-layer checks (no DOS
volume) first so a corrupted test volume can't mask them.

Test-fixture note: several 256 KB-transfer hangs corrupted `DH0.1`'s FS
(unvalidated -> no mount). Recovered each time from
`/media/usb0/Test200MB.hdf.pristine` + reformat.

Final clean run (pB14 shipping build, ID1-only): **10/10 PASS**, bench
1067 KB/s. (An intermediate run scored 9/10 - `write_integrity` - only
because the `.minimig` config edit for the multi-drive test was still
live in the running core; a reboot to reload it -> 10/10. Editing
`config/Minimig.cfg` needs a core reload to take effect.)

## 20260906-07xx — Post-ship cleanup (working the punch list)

### Item 5 done — RTL SIOP retired

`a4091_siop.v` / `a4091_target.v` / `a4091_sd.v` + the old `rtl/a4091_tb.v`
deleted (dead since the bridge). Dropped from `files.qip` / `Minimig.qsf`
and from the Quartus box's `/tmp/mm-a4091`. `tb/a4091_tb.v` (bridge
bench, 8 groups) still ALL PASS.

### Item 4 done — regression suite (`A4091/tools/swsiop_tests/`)

* `ddrmap_test.c` - host unit test, no hardware. Replicates `ddr_ptr()`
  + `cpu_to_le32` and asserts against the `devmem` HW capture (scripts[]
  at Amiga 0x40000090 -> phys 0x30000090, halfword-swapped). 14/14 pass.
  Guards the stale-file-cache-anchor bug.
* `swsiop_regress.py` - MiSTer-side, drives the Amiga serial console:
  mount / probe / geometry / RC10 / RC16 / read packets / SEEK / marker
  round-trip / 3.3 MB LhA CRC / quick format.
* `aserial_lib.py` - importable serial helper.

**Test-fixture note:** the original `Test200MB.hdf` had its partition at
LowCyl 0, so the earlier full non-quick format overwrote the RDB (block
0). Rebuilt from `system_A4091.hdf` (partition LowCyl 2 - RDB-safe);
AmigaOS mounts it as device `DH0.1:` (RDB names it "DH0", auto-renamed to
dodge the IDE "DHO"). Pristine copy saved as
`/media/usb0/Test200MB.hdf.pristine` on the box.

## 20260906-0530 — Phase B/C1/D: SOFTWARE SIOP WORKS END-TO-END ON HARDWARE.

The v8 (DCNTL.STD) trace still looped `WAIT DISCONNECT; INT ok` forever
with a garbage `[DSA]` dump. Two root causes, both found this session:

### 1. "Q1 solved" was wrong - the DDR map anchored on a stale file cache

The 32-byte SCRIPTS-signature scan found `scripts[]` at DDR phys
`0x050386dc` and `ddr_ptr()` used it as a linear anchor. That address is
a **Linux page-cache copy of the `a4091.device` file** (its
`.data.ncr_scripts` section = `scripts[]` verbatim). Reads near script
offset 0 decoded; the DSA structure at +0x1b0f0 walked off the cached
file into unrelated RAM, so every command "completed" with junk and the
driver retried.

Real map, derived from the RTL and confirmed with `devmem`:
  * `cpu_wrapper.v`: a Z3 access (base 0x40000000) -> ddram word addr
    `{1'b1, cpu_addr[27:1]}`.
  * `ddram_ctrl.v`: `{3'b001, addr[28:3]}` 8-byte DDR words
    => HPS phys **`0x30000000 + (A - 0x40000000)`**.
  * The 16-bit Amiga word lands byte-swapped in the LE 64-bit DDR word
    => every byte access **XORs offset bit 0**.
  * `scripts[0..3]` (`47000000 00000150 878b0000 00000030`) read back at
    phys 0x30000090, halfword-swapped. `sc_scriptspa` = 0x40000090 (the
    driver's `.data` loaded at +0x90), so `DSP=0x40000090` IS
    `Ent_scripts` - the driver was issuing real SELECTs all along.

Fix: `minimig_a4091.cpp` `ddr_ptr()` -> `phys = (0x30000000 + (A -
0x40000000)) ^ 1`; deleted the `g_cand[]` scan.

### 2. `req->bus` was NULL -> SIGSEGV on the first DATA phase

`lsi710_transfer_data` / `lsi710_command_complete` recover the HBA via
`LSI53C895A(req->bus->qbus.parent)`. The C1 `scsi710_req_new()` left
`req->bus` NULL and nothing set `s->bus.qbus.parent`, so INQUIRY's
transfer callback dereferenced NULL and killed MiSTer the instant the
Amiga probed SCSI. Fix: `s->bus.qbus.parent = dev` in
`lsi710_scsi_reset` + `a4091_lsi_run`; `s->current->req->bus = &s->bus`
in `lsi_do_command`.

Deploy note: stale racing deploy scripts from a prior session had wedged
the DE10 FPGA (every MiSTer binary, incl. stock, segfaulted). `reboot`
clears it. A MiSTer crash *with the Minimig core loaded* re-wedges the
FPGA, so the recovery is: reboot -> launch -> one clean `load_core`.

### Results (a4091.device unit 1, Test200MB.hdf, RBF = swsiop_stdkick)

  * `info` -> `SH0  199M  Read/Write  0 Errs` - drive **MOUNTED**
  * `devtest -p` -> `1  MiSTer  A4091 HD  0001  Disk  512  209 MB`
  * `devtest -g -t` -> C=3200 H=16 S=8; INQUIRY / TUR / RC10 / CMD_READ /
    ETD_READ / TD_READ64 / NSCMD_*_READ64 all **Success**
    (RC16 + TD_SEEK return SENSE 5/20/00 - C1 gap, driver copes)
  * `Format DRIVE SH0: NAME SCSITest FFS QUICK` -> success, remounts
    clean, 0 errors
  * Wrote `SH0:marker.txt`, read back byte-exact over serial, AND the
    string appears in the raw `Test200MB.hdf` on the MiSTer SD - full
    DATA-OUT path (VM -> pci710_dma_write -> DDR -> FileWriteAdv -> disk)
    verified.

The RTL-SIOP 16-bit-DMA whack-a-mole (P1..P7) is bypassed entirely: the
bridge has no DMA datapath.

### Full (non-quick) format - the workload that corrupted RAM on the RTL SIOP

`Format DRIVE SH0: NAME SCSITest FFS` (no QUICK) - AmigaOS writes +
verifies every block of the 200 MB disk. 15684 WRITE(6) commands, LBA
climbing monotonic 0 -> 0x62038 (~402k blocks) then the RDB/root/bitmap
writes, ~15 min (the per-instruction `DEBUG_LSI` trace + fflush-to-USB is
the limiter, not the SIOP). **MiSTer never crashed.** Drive remounts
`SCSITest` 0 errors R/W. Re-copied the 3.3 MB LhA afterwards -> `lha t`
"10 files tested, all files OK". The RTL SIOP corrupted Amiga RAM doing
exactly this (P1, cyl ~1325).

Open (polish, not blockers): C1 lacks SEEK(6/10) + READ CAPACITY(16);
the DCNTL.STD idle re-kick grows the trace when idle (harmless, wastes
SPI); DEBUG_LSI / a4log still compiled in.

## 20260906-011500 — software-SIOP PR1: bridge RTL + integration + Main_MiSTer stub + tb. Elaborates clean, tb ALL PASS, Phase A Quartus build fitting.

Branch `claude/a4091-software-siop`. Phase A per `software-siop-exec-plan.md`.

- **`a4091_bridge.v` (new, ~210 lines):** 256 B shadow register RAM
  (dual-port CPU + HPS mailbox), kick detect (DSP-MSB write -> fire on
  trailing 0x2C or 6 idle reg-bus cycles, ported verbatim from
  a4091_siop), the "fire once per address phase" reg-bus edge detect
  (also verbatim - the self-clearing-bit double-count fix), int2 +
  ISTAT-read-clears-int, soft_reset_pending. hps_ext mailbox stubs.
  chip-DMA slot tied off (dma_req=0) until PR2.
- **`a4091.v`:** gutted -456 lines. Autoconfig + ROM + board decode +
  board mux kept verbatim; SIOP register net -> the bridge shadow RAM;
  a4091_siop/target instances and the sec_* / big dbg_q SIOP-snapshot
  window gone (dbg window slimmed to signature + shadow regs + flags).
- **`hps_ext.v`:** a4091 mailbox 'h64-'h69 redesigned - 'h64 poll,
  'h65/'h66 shadow-reg burst rd/wr, 'h67 control byte, 'h68 heartbeat.
  512 B sector buffer walk + 'h69 geometry push removed.
- **`cpu_wrapper.v` / `Minimig.sv`:** a4091_sd instance + per-ID
  geometry store deleted; sec_*/present/disk_blocks/sec_id gone (ARM
  owns geometry); mbx_* wired hps_ext <-> cpu_wrapper <-> a4091.
- **`minimig_a4091.cpp` (Main_MiSTer):** Phase A stub. Polls 0x64; on
  kick, burst-reads the shadow regs (logs DSA/DSP), then read-modify-
  writes ISTAT.DIP + DSTAT.IID and pulses set_int|clr_kick so
  a4091.device fails the SELECT fast (no SCRIPTS VM yet -> 0 units).
  Builds clean vs Main_MiSTer build-host.
- **`a4091_tb.v`:** rewritten, 7 groups, **ALL GROUPS PASS** - autoconfig,
  ROM, DIP, CPU<->HPS shadow-reg both directions, kick+IRQ+ISTAT-clear,
  soft-reset flag.

Elaboration clean (no Error (), past Analysis into the Fitter). Phase A
build `20260906_swsiop_pA_build.txt` on `quartus-host`. files.qip on the box:
a4091_siop/target/sd -> a4091_bridge.

**Build result: 0 errors, 76 warnings.** clk_sys setup -0.170 - but the
worst path is `yc_out|cburst_phase -> yc_out|phase` (the stock S-Video
chroma-burst phase generator, a known-marginal MiSTer video path,
irrelevant unless S-Video output is selected). **Every a4091 / sdram_ctrl
timing problem from the P1-fix branch is GONE** - the bridge deleted the
48-state SIOP FSM and the byte-DMA critical paths, and the a4091 DMA
slot no longer adds a 4th priority tier to sdram_ctrl's command decode
(dma_req tied 0 until PR2). Exactly the "timing should improve"
prediction in the plan.

Deployed as `minimig_20260906_A4091_swsiop_pA.rbf` + the Phase A stub
`MiSTer` binary (old one backed up to `/media/fat/MiSTer.bak_known_good`),
FPGA reconfigured.

**First hardware run - the bridge works.** `/media/usb0/a4091_sd.log`:
```
ID1 = "Test200MB.hdf"  200 MB
kick #1  DSA=00504001 DSP=00004000 DCMD=00 DMODE=00 DIEN=00
```
`a4091.device` loaded (autoconfig + ROM path unchanged), wrote DSP/DSA
into the shadow register RAM at Zorro speed, and the ARM burst-read them
back over the 0x65 mailbox - **DSP=0x00004000 came back a clean round
value, so the CPU -> shadow-RAM -> HPS path is proven byte-exact on real
hardware.** (DSA=0x00504001 has bit0 set - either the driver's own
struct pointer, or a burst-read skew; a raw regs[0..0f] dump was added
to check.) `d16`/tb G4-G7 already proved the same in sim.

**Problem: `DSTAT=IID` alone made the driver soft-reset-loop** every
~8 s, never giving up -> AmigaOS boot blocked, no AUX: console.

**Fix chain (stub v2..v6):**
- v3: model the 53C710 soft reset on the shadow RAM (driver writes ISTAT
  bit6, then polls DSTAT for DFE and expects control/status regs cleared)
  -> **the Amiga now boots to a console, DH0 mounted.**
- v4: `skew_probe` measured the 0x65 burst read offset = 0 (the two
  pipeline throwaways were wrong). Fixed -> `DIEN` reads back as `0x35`,
  the driver's real interrupt mask; `DSP=0x40000090`, `DSA=0x4001bXXX`
  (a real pointer the driver updates between kicks). **Shadow-register
  path proven byte-exact both directions on real silicon.**
- v6: on kick, just clear it and raise no interrupt (DSTAT=0x31+set_int
  had the driver retry-storm the SELECT 28x).

## 20260906-020000 — software-SIOP PHASE A COMPLETE. Bridge proven on hardware; device install needs Phase B (SCRIPTS VM).

Phase A scorecard (`software-siop-exec-plan.md`):

| item | status |
|---|---|
| RTL builds, 0 errors | DONE - and every a4091 / sdram_ctrl timing problem from the P1-fix branch is GONE (worst path is now stock `yc_out` S-Video) |
| `a4091_tb.v` | DONE - 7 groups ALL PASS |
| autoconfig enumerates, `a4091.device` loads | DONE - `apply_config` runs, driver executes (28 kicks logged) |
| 256 B shadow register RAM, CPU R/W at Zorro speed | DONE - byte-exact both directions on HW, `DIEN` reads `0x35` |
| kick detect | DONE - fires reliably |
| soft-reset model | DONE - driver clears chip init, Amiga boots |
| int2 / IRQ | DONE - tb G6; HW path exercised (ISTAT-read clears) |
| burst mailbox 0x65/0x66 round-trip | DONE - skew calibrated to 0 |
| Amiga boots, console, DH0 mounted | DONE |
| `devtest -p` installs the device | **NOT in Phase A** - a4091.device needs a successful init SCRIPTS run to register the device node. That is Phase B (port `lsi53c710.cpp`). The exec-plan ladder step 1 as written ("devtest -p enumerates") reaches slightly into Phase B; the register-path / mailbox / kick / IRQ goal it was meant to prove is fully met. |

**Interesting HW detail:** `DSP=0x40000090` - the driver runs its init
SCRIPTS from ~board-base offset 0x90 (the ROM window). Phase B's DMA
hook must handle reads from the board's own address space as well as
Z3 fast RAM. Noted for the exec plan.

Deployed cores this session: `minimig_20260906_A4091_swsiop_pA.rbf`
(bridge, clk_sys -0.170 on `yc_out` only) + Phase A stub MiSTer binary.
**Stopgap restored:** `displit` RBF + known-good MiSTer binary back on
the box for normal use.

## 20260906-033000 — Phase B/C1/D: full software SIOP compiles + links + runs on hardware. Stuck on the Amiga-Z3 -> HPS-DDR memory map (Q1).

- **`a4091_scsi.cpp` (C1)** - `scsi710_req_*` / `scsi710_device_find` seam
  backed by a C port of `a4091_target.v` T_DECODE (TUR/START-STOP/FORMAT/
  SYNC-CACHE no-op, REQUEST SENSE, INQUIRY, READ CAPACITY(10), MODE
  SENSE(6), READ/WRITE 6&10 via `FileReadAdv/WriteAdv`). `analyze()` +
  `emulate()` match the WinUAE `scsi_data` enqueue/continue contract.
- **`a4091_lsi.cpp`** - `+ a4091_lsi_load/store` (256-byte shadow RAM <->
  LSIState710 direct field copy) `+ a4091_lsi_run` (`lsi_execute_script`).
  `DEBUG_LSI` on for per-instruction tracing (also removes `BADF`'s
  `assert(false)` so error paths aren't fatal).
- **`minimig_a4091.cpp`** - kick poll: `regs_read` -> `a4091_lsi_load` ->
  `a4091_lsi_run` -> `a4091_lsi_store` -> `regs_write` -> drive `int2`.
  `pci710_dma_rw` = the one memory seam; `pci710_set_irq` -> `g_lsi_irq`.

**Builds clean, links, runs on hardware.** Iterations:
- soft-reset was storing the fresh (all-zero) model over the shadow RAM,
  clobbering the driver's DSP -> `DSP=0`. Fixed: model soft reset on the
  shadow bytes directly, don't `a4091_lsi_store`.
- `DSP=0` also seen because the driver zeroes DSP during chip init (a
  spurious kick) - now skipped.
- `DDR_BASE=0x40000000` was past the 1 GB SoC DDR -> `mmap` access
  SIGBUS'd MiSTer. Tried `0x20000000` (MiSTer's reserved FPGA window):
  the bytes at `DSP & mask` were `0x07` - wrong.

**Q1 - the Amiga-Z3 -> physical DDR mapping.** Scanned all of HPS DDR
(1 GB) for the driver's `scripts[]` signature. The 53C710 SCRIPTS use
DSP-*relative* jumps (no relocation), so file-cache copies of
`a4091.device` are byte-identical to the live one - 8+ hits, content
can't discriminate. Current approach: `phys(A) = cand[N] +
(A - 0x40000000)` linear map, cycle `A4091_CAND` 0..7 while watching the
LSI SCRIPTS trace for the first candidate that decodes a valid
SELECT -> INQUIRY -> DATA IN and lands data back where the driver
expects. If none work linearly, fall back to routing `pci710_dma_rw`
through the RTL bridge's `sdram_ctrl`/`ddram_ctrl` DMA port (reuses the
proven RTL address decode, at SPI-mailbox speed instead of memcpy).

## 20260906-023000 — Phase B scaffold: lsi53c710 SCRIPTS VM port COMPILES on the ARM toolchain.

`WinUAE/qemuvga/lsi53c710.cpp` (2505 lines) -> `a4091_lsi.cpp`. WinUAE had
already `#if 0`'d all the QEMU PCI / MemoryRegion / VMState infra, so the
only live code past the SCRIPTS interpreter is `lsi710_scsi_init/reset`.
Port surface was tiny:
- `a4091_lsi_glue.h` - replaces `qemuuaeglue.h`: `DeviceState{void*lsistate}`,
  opaque `PCIDevice`, `PCI_DEVICE(s)` cookie macro, `dma_addr_t`/
  `DMADirection`, `pci710_dma_read/write` -> `pci710_dma_rw` (impl pending),
  `pci710_set_irq` (pending), `cpu_to_le32`, `sextract32`/`extract32`,
  `write_log` -> `a4091_lsi_log`, `g_free`.
- `a4091_queue.h` = WinUAE `queue.h` verbatim (BSD QTAILQ).
- `a4091_scsi_defs.h` = WinUAE `scsi/scsi.h`; `QEMUFile`/`BusState` shimmed.
- `a4091_lsi.cpp` - includes rewired only, zero logic changes.

**Compiles clean:** `arm-none-linux-gnueabihf-g++ -std=c++11`, 21 KB `.o`.
Committed. `cpu_to_le32` is currently a byteswap - the SCRIPTS-fetch
endianness (this + `pci710_dma_rw`'s 68k<->ARM swizzle) gets calibrated
with the host unit test.

**Remaining for Phase B/C1/D:**
- `a4091_lsi_hw.cpp` - `pci710_dma_rw` (Z3-fast `memcpy` vs `/dev/mem` DDR
  mmap; chip/Z2 -> 0x68/0x69 mailbox), `pci710_set_irq` (0x67),
  `a4091_lsi_log`.
- `a4091_scsi.cpp` (C1) - `scsi710_req_*` + `scsi710_device_find` backed by
  a port of `a4091_target.v`'s command decode + `FileReadAdv/WriteAdv`.
- `minimig_a4091.cpp` kick poll: load shadow regs -> `lsi_execute_script`
  -> store regs -> `set_int`.
- host unit test (canned READ(10) SCRIPTS + fake target -> DMA buffer
  byte-exact); the endianness calibration lands here.
- HW bring-up: `devtest -c TUR` -> INQUIRY -> READ CAPACITY -> `devtest -i`.

## 20260906-002500 — Direction set: software SIOP on the ARM, new branch, RTL SIOP replaced. `displit` deployed as the stopgap core.

The ship-build timing chase for the P1 fix hit a wall: clean source
(`D16_DIN_ENABLE=0`) builds at -0.09..-0.21 clk_sys on the
`sdram_ctrl:ram1` SDRAM command decode (`{dma_req,dma_ack,write_req,
sdram_state} -> sd_addr/sd_cas`) - the a4091 DMA slot is a 4th priority
tier on the state-0 arbitration mux and the decode cone is congested at
the TG68 020 fmax. An SDC multicycle on `dma_ack -> sd_*` backfired
(-0.503: once relieved of that path the fitter spread the rest, and
`write_req`/`sdram_state` are real single-cycle paths). SDC reverted.

Rather than seed-hunt or do risky surgery on `sdram_ctrl` for a +29%-on-
writes-only gain, switching strategy. The RTL byte-serial DMA path has
now cost, in order: build #64 lost bytes, #64->71 grey-screen wedge,
#73 dropped first byte, and today `S_DI16` memory corruption - the exact
whack-a-mole pattern `software-siop-plan.md` 1.1 lists as its trigger.

**Decisions (user, 20260906):**
- Implement software SIOP (`software-siop-plan.md`): 53C710 + SCRIPTS VM
  + SCSI-2 emulation move to the HPS ARM; FPGA becomes a thin Zorro-III
  <-> ARM bridge (autoconfig ROM + 256 B shadow register RAM + kick
  flag + IRQ + chip-DMA mailbox). DATA phase = ARM `memcpy` into DDR
  (Z3 fast RAM is physically HPS DDR). Ceiling ~20-40 MB/s.
- **Plan first** - concrete phased execution plan before code.
- **New branch, replace** - not a coexist-behind-O[]-bit transition.
- **`displit` is the stopgap** - deployed now
  (`minimig_20260905_A4091_displit.rbf`, 16-bit DATA OUT + byte DATA IN,
  clk_sys -0.119, hardware-validated 200 MB `devtest -i` + full format).
  Booted clean, DH0/SH0 0 errs, `devtest -i -l 8` passed.

P1 (`S_DI16`) root cause stays OPEN - the software SIOP removes the
whole class, so it will not be chased further on the RTL path.

## 20260905-214500 — P1 FIX validated: DATA IN forced to byte path (`D16_DIN_ENABLE=0`), DATA OUT keeps 16-bit. `displit` passed 200 MB `devtest -i` + a full format.

`displit` (`S_DI16` byte path, `S_DO16` 16-bit) ran
`devtest -i 512k -d -y -l 400 -m Fast` = **400/400 passes, ~200 MB of
write-pattern / read-back / verify, "completed successfully"**, system
healthy after (DH0 + SH0 0 errs). That is ~7x the ~27 MB that kills the
full-16-bit build, on top of the earlier clean 3008-cylinder format.
So byte-path DATA IN is a real fix, not a slower path to the same
failure.

RTL change made permanent as a single compile-time flag in
`a4091_siop.v`:
```
localparam D16_DIN_ENABLE = 1'b0;          // P1: S_DI16 disabled
wire d16_din = d16_possible & D16_DIN_ENABLE;
```
`S_DIA` gates on `d16_din` (so always byte path); `S_DOA` still gates on
`d16_possible` (16-bit DATA OUT stays on). The `S_DI16A-E` states and
`di16_b0` are left in source but unreferenced - Quartus elides them,
and flipping the flag back re-enables the path for a future SDF-sim
root-cause attempt.

**Throughput cost:** 16-bit was +29% end-to-end (JOURNAL 20260904-123400).
Reads lose that, writes keep it. Net: somewhere around +10-15%
vs the pre-16-bit b91 baseline, still well up from 101 KB/s.

**Root cause, as far as it was taken:** `S_DI16` (16-bit DATA IN, word
DMA WRITE into Amiga RAM) corrupts memory under sustained load.
Isolated hard - A/B builds, pure integrity repro, both RAM controllers.
Static logic of `S_DI16A-E -> dma16 -> ddram_ctrl state 5` verified
correct at every alignment (address, 68k byte order, `dmaWriteBE`,
DDRAM_DIN lane, the CPU/DMA-consistent 16-bit DDR byte swap). Cadence
is *wider* than the byte path, not tighter. `d8_go` / `tgt_buf_we` are
clean 1-cycle pulses. It is a dynamic/silicon timing effect the
zero-delay testbench cannot reproduce - pinning the exact gate needs
SDF-annotated sim or a logic-analyzer probe on the board, which is the
open item if the read-side 16-bit speedup is wanted back.

**Ship build - timing:** clean source (`D16_DIN_ENABLE=0`) built at
SEED 4 (-0.207) and SEED 5 (-0.092) - both fail one path,
`sdram_ctrl:ram1|dma_ack -> sd_addr[8]` on clk_sys. This is placement
noise inside `sdram_ctrl`'s a4091 chip-DMA command decode, not the
S_DI16 change; `dma_ack` there only toggles at SDRAM FSM states 2 and
10, always >= 6 sysclk before the state-0 slot arbitration that reads
it, so the decode genuinely has a full SDRAM half-period. Added a
`set_multicycle_path -setup 2 / -hold 1` on `{emu|ram1|dma_ack*} ->
{emu|ram1|sd_*}` to `Minimig.sdc` (tracked as
`integration/Minimig.sdc.patch`). `dma_req` left at 1 cycle - it can
rise close to the state-0 boundary and a wrong `sd_addr` there would
be silent bounce-buffer corruption, not benign. STA on the SEED 5
placement with the new SDC: **0 violated, clk_sys +0.071**. Clean
compile with the constraint running (`20260905_p1fix_sdc_build.txt`).

**Next:** verify the SDC-build timing, deploy, re-verify format +
`devtest -i` + `scsi_rd` ladder, update ISSUES.md P2-7.

## 20260905-211500 — P1 further: full-16-bit build crashes a *pure* `devtest -i` integrity test (~27 MB of S_DI16 reads), so NOT contention-dependent. Threshold ~ tens of MB.

Redeployed `dbginstr` (full 16-bit, both `S_DI16` + `S_DO16`). Ran
`devtest -i 512k -d -y -l 300 a4091.device 1` - each pass writes a
512K random pattern (S_DO16), reads it back (S_DI16), CPU compares.
Minimal CPU fast-RAM contention vs a full Format.

**Crashed at pass ~53** (~27 MB of S_DI16 read-back traffic). Same
silent abort + red `ESC[31m` prompt. So the trigger is not Format's
CPU-vs-DMA fast-RAM contention pattern - a light pure read/verify
workload hits it too, at a volume/time threshold of a few tens of MB.
For comparison `b16dma` (JOURNAL 20260904-123400) passed `scsi_rd 1 32`
(16 KB) and 75 KB file round-trips - well under the threshold, which
is why it looked clean at the time.

Static review of the `S_DI16A-E` -> `dma16` -> `ddram_ctrl` state 5
path is exhausted: address, 68k byte order, `dmaWriteBE` mask, DDRAM_DIN
lane, and the 16-bit DDR byte-swap convention (consistent CPU vs DMA)
were all verified correct at every alignment, four times over. The
cadence argument for "word path stresses the bus harder" doesn't hold
either - the word path issues HALF the transactions of the byte path
with WIDER per-transaction spacing (~5 vs ~3 SIOP cycles). So it is
neither a wiring bug nor simple bus-rate.

**Next:** pure read/verify repro means a `devtest -i` loop is now a
~4 min repro (vs 15-30 min format). Isolate SIOP-`S_DI16`-logic vs
`ddram_ctrl`-word-write by running the same `-i` test with the buffer
forced to Chip RAM (`-m Chip` -> `sdram_ctrl` path) vs Fast (`-m Fast`
-> `ddram_ctrl`). Chip crash too -> bug in the SIOP S_DI16 sequence.
Chip clean / Fast crash -> bug in `ddram_ctrl` state 5 word write.

**Box state - NEEDS ATTENTION:** the pass-53 crash left DH0
(`/media/usb0/games/AmigaOS3.2/hdf/AmigaOS3.2.hdf`, 3.35 GB IDE boot
drive) unbootable. The Amiga powers up and `a4091.device` inits (HPS
`a4091_sd.log` kick/sel counters keep climbing), but the AUX: serial
console never comes up after 20+ min across a full `killall MiSTer` +
relaunch + `load_core` cycle. uartmode.Minimig still = 2 (Console),
Minimig.cfg intact - so this is DH0 filesystem damage from the
crash's stray writes, not a config problem.
Candidate restore: `/media/usb0/games/AmigaPiStorm/hdf/AmigaOS3.2.hdf`
(identical 3355443200 bytes, dated Aug 20, pre-session) - but it is a
PiStorm setup and may not carry the a4091 test tooling / assigns.
`AmigaA2065/hdf/AmigaOS3.2.3.hdf` also same size, Apr 26. User call on
which (or restore from their own backup / repair via install media).
Test200MB.hdf (SH0) may also have a mangled RDB - reformat or restore.

Investigation on the RTL side does NOT need the box for the next step:
the `-i` Chip-vs-Fast discriminator can wait. What we have is solid -
`S_DI16` is the culprit, `S_DO16` is clean, and `displit` (S_DI16 on
byte path) passed a full format.

**Chip-RAM discriminator, first attempt (inconclusive):** box recovered
on its own (DH0 disk-validate finished, ~20 min). Ran `devtest -i 128k
-d -y -l 500 -m Chip` on the full-16-bit build to route `S_DI16` writes
through `sdram_ctrl` instead of `ddram_ctrl`. The Amiga HUNG around
pass ~17 (~2 MB) - `capture.py` stopped receiving bytes, no red prompt
or Guru text captured, console dead afterwards. So `S_DI16` writes to
CHIP RAM also bring the system down, and *sooner* than the ~27 MB Fast
threshold (though chip RAM is far smaller, so corruption hits critical
OS structs faster - not necessarily "13x worse"). Tentative read: the
fault is in the SIOP `S_DI16` sequence and is NOT specific to
`ddram_ctrl` - it shows through both RAM controllers. Needs a clean
rerun with proper output capture to be sure it was corruption and not
chip-pool fragmentation.

**More useful next test:** does `displit` (S_DI16 forced to byte path)
survive the SAME `devtest -i` pure-integrity loop that killed the
full-16-bit build at pass 53? That decides word-specific vs
all-a4091-DMA-writes, and whether byte-path DATA IN is a genuine fix
or just a slower path to the same failure.

## 20260905-201500 — P1 ISOLATED: the crash is `S_DI16` (DATA IN 16-bit word DMA, the SCSI-read / RAM-write direction). DATA OUT 16-bit is fine.

Two A/B builds, opposite halves of `d16_possible` disabled:

| build | `S_DO16` (write pass) | `S_DI16` (verify pass) | clk_sys slack | full format |
|-------|------|------|------|------|
| `dosplit` `947c2fc5` | **byte** | 16-bit | +0.192 (good) | **CRASH cyl 1325** |
| `displit` `7776dcad` | 16-bit | **byte** | -0.119 (marginal) | **COMPLETES, 0 errs** |

The build that SURVIVED had the WORSE timing, so this is not a timing
artefact - it is a clean isolation. `S_DI16` is the guilty state
machine. `S_DO16` (DATA OUT, RAM-read / SCSI-write) ran 3008 "Formatting"
passes in the `displit` run with zero errors - it is fine.

**The "always crashes on a Formatting line, never a Verifying line"
observation was a red herring.** `S_DI16` runs during the *Verify*
(read-back) pass; it corrupts Amiga RAM there, and the corruption only
becomes *visible* one step later when the CPU touches the damaged
memory while setting up the next "Formatting cylinder N" line. The
visible symptom and the actual fault are one cylinder-group apart.

**Mechanism (narrowed, not yet proven):** `S_DI16` issues `dma16(0,
dnad, ...)` = a 16-bit *word write* into fast RAM via `ddram_ctrl.v`
state 5 (the DMA-write-accept path). The byte path `S_DIB`/`S_DIC`
issues `dma8(0, ...)` = single-byte writes through the same state 5.
So the difference is **word (BE=11) vs byte (BE=01/10) DMA writes**,
or the tighter `S_DI16A-E` issue cadence vs `S_DIS/S_DIB/S_DIC`. The
`ddram_ctrl` DMA-accept timeout counter reading 0 after an earlier
crash still holds - this is not that timeout. The D_HOLD `d8_w16 ?
8 : 4` margin bump (`holdfix`, JOURNAL 20260904) doubled the settle
for ALL word transfers and did not help - but that was with both
directions on 16-bit, and the read side (`S_DO16`) is now shown
harmless, so the margin bump was partly aimed at the wrong path.

**Shippable fix available now:** keep `S_DI16` permanently on the byte
path, keep `S_DO16` on 16-bit. Loses the 16-bit speedup on SCSI reads
only; SCSI writes (the common case for real use) keep it. Needs a
reseed rebuild for positive clk_sys slack. OR: root-cause the word-DMA-
write corruption in `ddram_ctrl` state 5 / the `S_DI16` sequence.

## 20260905-193000 — P1: RTL re-review found a directional asymmetry never isolated before. Diagnostic build (DATA OUT forced byte-path, DATA IN kept 16-bit) running on `quartus-host`.

After the driver-side investigation (below) came up empty, went back to
the RTL with fresh eyes rather than more driver instrumentation.

**New observation, easy to miss:** every crash/abort recorded so far
happens during Format's WRITE pass ("Formatting cylinder N"), never
during Verify (the read-back pass) - true across the release-build
Guru crash AND all three debug-driver abort runs. In SCSI terms: write
= DATA OUT phase = `S_DO16A-C` (word DMA **read** from Amiga RAM, split
into 2 dbuf bytes). Verify = DATA IN = `S_DI16A-E` (word DMA **write**
into RAM). Every fix attempt to date - `d8_hcnt` D_HOLD margin
(`a4091_siop.v`), `dma_wait_cnt` timeout widening (`ddram_ctrl.v`) -
treated both directions identically via the shared `d16_possible`/
`d8_w16` flags. The direction was never isolated as its own variable.

**Structural re-review of `ddram_ctrl.v`'s arbiter** (the DDR3
controller shared by CPU fast-RAM access and a4091 DMA, `ram2` in
`Minimig.sv`): the `state` FSM is single-owner per cycle - DMA-write
(state 5), DMA-read (state 1, shared with CPU cache-line fill via the
`dma_read_in_flight` flag), CPU-write (state 0 same-cycle grant), and
cache-req all gate through one `case(state)` with no path for two
requesters to load the shared `DDRAM_ADDR/DIN/BE` regs in the same
window. No crossover found. `d16_possible = ~dnad[0] & (|data_rem
[23:1]) & (|dbc[23:1])` (a4091_siop.v:508) also correctly excludes
odd DMA address and <2 bytes remaining, so no odd-tail overrun/
underflow at the S_DO16/S_DI16 boundary. `dma_bs` -> `uds_in`/`lds_in`
mux in `cpu_wrapper.v` checks out for word mode too. Nothing wrong
found by inspection in any of these - consistent with the earlier
sim/hardware findings, just now covering the arbiter and boundary
logic specifically rather than only the timeout path.

One pre-existing oddity noted in passing, not pursued as the cause:
`ddram_ctrl.v`'s CPU-write path (state 0, lines ~277-283) fires
`DDRAM_WE` and sets `write_ack` in the SAME cycle whenever `~DDRAM_BUSY`
is already true on entry - the exact pattern the a4091 DMA-write path
used to use before build #64's fix (comment at line 252: "firing WE
and ACKing the same cycle raced and the byte was silently lost"). If
real, it would affect ordinary CPU fast-RAM stores on ANY MiSTer core
using this controller style, not just the a4091 - long-standing
shared code, out of scope for the a4091 device bug, but worth a note
for later.

**DIAGNOSTIC (`947c2fc5`):** `a4091_siop.v` S_DOA forced to the byte
path unconditionally (`1'b0 && d16_possible`), `S_DIA`'s `d16_possible`
left untouched. If a full non-quick format now survives, `S_DO16A-C`
(word DMA read-from-RAM for the write pass) is confirmed as the
specific guilty state machine, sharply narrowing where the real fix
needs to go - and rules out the DATA IN side entirely rather than
leaving it an open question. If it still crashes, the direction
theory is wrong and the bug lives somewhere direction-agnostic
(ddram arbiter under real DDR contention remains the leading
candidate there, per the existing dma_wait_cnt comment).

BUILD: `quartus-host`, clean in 26.5 min (0 errors). `clk_sys` setup +0.192 ns,
all slack positive - matches b91 baseline. Deployed as
`minimig_20260905_A4091_dosplit.rbf`, forced FPGA reconfigure.
Repro command is now `Format DRIVE SH0: NAME Test FFS` (NAME arg
required on this AmigaOS build - the earlier journal's `Format DRIVE
SH0: FFS` no longer parses; RETURN-confirm handled via `capture.py`).

**RESULT (`947c2fc5`, DATA OUT byte / DATA IN 16-bit): STILL CRASHES.**
Cylinder 1325/3008 (44%), silent abort mid-"Formatting cylinder 1325"
line (no matching "Verifying 1325"), red `ESC[31m` prompt - the exact
same signature as all three debug-driver runs. Forcing DATA OUT to the
byte path did NOT fix it. So `S_DO16` is not solely at fault.

Caveat: `S_DI16` (DATA IN word DMA) was still active for all ~1300
cylinders of Verify passes before the abort. The crash always *shows*
on a "Formatting" (write) line, but that may just be where a stray
write from the preceding Verify pass first becomes visible. Three
data points now:
  - global `d16_possible = 0`      -> full format completes (20260904)
  - DATA OUT byte / DATA IN 16-bit -> crash at cyl 1325
  - DATA IN byte / DATA OUT 16-bit -> next test (`7776dcad`, building)
If the inverse also crashes, no single direction is at fault and the
trigger is aggregate 16-bit DMA bus pressure (ddram_ctrl arbitration
or the shared dma8/dma16 D_WAIT/D_HOLD engine under load), not a
per-direction logic bug - which would also explain why widening
either margin in isolation never helped.

## 20260905-130000 — P1 driver-side investigation: three targeted instrumentation attempts, all inconclusive. Stopped for tonight, known-good driver restored.

With the RTL cleared (300-cmd sim stress test clean; hardware ddram
timeout counter reads 0 after a live crash - see the entry below),
moved investigation to `a4091.device` itself (a4091-software, built on
`build-host` at `/tmp/a4091clean`, NOT this repo). Three debug driver builds,
each `FULL_VERSION=...` to route around a `git describe` failure in
that checkout (tags exist but the current commit isn't a descendant of
any reachable one - environment quirk, unrelated):

1. **`-DDEBUG_SD`** (`a4091.device.dbgsd`): covers bounce-buffer alloc
   and the RC10 (READ CAPACITY) response path. Neither fires during a
   bulk format - wrong code path for this bug. Format aborted cleanly
   (no crash) at cylinder 950/3008 (31%).
2. **`-DDEBUG_SIOP`** (`a4091.device.dbgsiop`): covers Phase Mismatch /
   Select Timeout / Unexpected Disconnect - anomalous SCSI phase
   events, matching the `phase-mismatch=2` counter seen in `a4091dbg`
   output earlier. Never fired either. Format aborted at cylinder
   2050/3008 (68%), then again (rerun) at 425/3008 (14%).
3. **Unconditional `XSERR` print** added directly to `scsipi_done()` in
   `scsipi_base.c` (any `xs->error != XS_NOERROR`, printing error code/
   status/resid/retries/opcode) - the most generic catch-all possible,
   built with `-DDEBUG_SIOP` as the carrier flag. **Never fired either**
   - `xs->error` was zero the whole run. Format aborted at cylinder
   150/3008 (5%), the earliest yet.

**None of the three catches anything, and each successive debug binary
crashes SOONER, not later** (950 -> 2050/425 -> 150 cylinders across the
four runs). That pattern - getting *worse* with different binary
layouts, not converging - fits a genuine stray-write/corruption bug
whose target address depends on what's currently allocated there: a
bigger/differently-laid-out binary just changes what's sitting at the
corrupted address, so the same underlying fault becomes visible sooner
or later depending on build. It also means the abort itself isn't a
normal SCSI-layer error at all (scsipi_done's own error path never
sees it) - something crashes/aborts at a level entirely outside what
these three instrumentation points can see.

Also notable: every debug-build abort is silent - no error text on the
AUX: console (confirmed via raw hex dump, not just string-stripped
output), no visual requester on screen (confirmed via screenshot), just
the AmigaDOS shell prompt reappearing in red (`ESC[31m`, its own
"last command failed" indicator) partway through a "Formatting cylinder
N" line with no matching "Verifying" line - i.e. it fails during the
WRITE pass, not the read-back verify.

**Not a corruption/crash of the whole system on any debug build** - only
the release (non-debug) build produces the actual illegal-instruction/
LINEF crash-and-reboot from the original report. The debug builds's
extra code/timing seems to intercept the SAME underlying fault earlier
and more gently (a clean process-level abort instead of a wild jump),
which is itself useful confirmation this is timing/memory-layout
sensitive, but didn't get further code-level answers than that.

**Recovery note for next time:** each debug driver swap needs a forced
FPGA reconfigure (`load_core` to a different rbf then back - a same-
path `load_core` is a no-op) to get a fresh Amiga boot, and after an
abort the AUX: shell can take anywhere from ~1 to ~8 minutes to come
back (extra boot-time serial chatter from ANY `-DDEBUG_*` flag - it's
a compiler-wide flag, not per-file, so it also activates the
already-unconditional `#define USE_SERIAL_OUTPUT` in `attach.c`,
`cmdhandler.c`, `device.c`, `port.c`, `scsipiconf.c`, `scsiconf.c`,
`scsimsg.c`, `romfile.c`, `battmem.c`, `bootmenu.c` - be patient rather
than assuming it's wedged). `killall MiSTer` + relaunch does NOT reset
the Amiga - only affects the ARM housekeeping process; the FPGA-side
Amiga is independent and needs an actual reconfigure.

**Stopped here for tonight** (extensive session - multiple FPGA builds,
several driver builds, ~10 live full-format repro rounds). Known-good
`a4091.device` (46152 bytes) restored to `DEVS:` and verified booting
normally (39s, clean). My `XSERR` patch to `scsipi_base.c` is local
scratch state on `build-host:/tmp/a4091clean` only, not committed anywhere -
harmless to leave, easy to redo (single hunk, see above) if picked up
again.

**State to leave the RTL in:** all committed RTL changes stay as-is -
16-bit DMA (P2-7), multi-ID SCSI, scaffold strip, the D_HOLD margin
bump, the two ddram_ctrl `dma_wait_cnt` widenings, and the
`a4091_dma_timeout_cnt` debug counter. None of them are implicated by
tonight's findings (the RTL is cleared); reverting any of them would
not fix a driver-side bug once found. `minimig_20260905_A4091_dbginstr.rbf`
is deployed and current on the box.

**Next-session starting point:** the bug is confirmed driver-side
(a4091.device / a4091-software), memory-layout-sensitive, likely a
stray write rather than a hang (timeout theory produced no supporting
evidence - `xs->error` never nonzero). Worth trying next: (a) a memory-
canary scheme (guard bytes around known allocations, checked
periodically) rather than more printf placements; (b) a much smaller,
deterministic single-operation repro instead of a 15-30 min full-format
run, to make iteration cheaper; (c) checking `chan_continue_iotd`'s
buffer-pointer math (`io_Data + io_Actual`) and the bounce-buffer
size-capping path in `sd.c` (~line 640, `MAX_BOUNCE_SIZE`) more
carefully - not read in full detail this session.

## 20260905-103000 — P1 regression: ddram timeout widening does NOT converge. Added verification instrumentation.

Continuing from the ddram_ctrl fix below. Hardware results, `Format
DRIVE SH0: FFS` (no QUICK) each time, same 200 MB drive:

  dma_wait_cnt=10 bits (1024 cyc, f3530902)  -> crashed at LBA ~277K/409600
  dma_wait_cnt=14 bits (16384 cyc, 688dd805) -> crashed at LBA ~235K/409600

Widening the timeout 16x further did **not** push the failure point out
further - if anything slightly earlier. Full sequence of failure points
across every run this investigation: 15K, 80K, 108K, 277K, 235K blocks.
No monotonic trend. Given DDR contention timing is inherently stochastic
(depends on real-time alignment with CPU/video traffic), this run-to-run
scatter means **the ddram_ctrl timeout theory is no longer confirmed** -
it may be a real contributing factor, a red herring, or one of several
mechanisms. Guessing a bigger number a third time was not going to
settle it.

Verified the RAM path first, since it changes where to even look: `avail`
on the box shows chip=~2MB, fast=~256MB: Format's small work buffer
comes from the huge Fast pool via plain `AllocMem(MEMF_PUBLIC)`, and
`is_zorro_ii_address()` in a4091-software's `sd.c` (the driver's bounce-
to-chip-RAM trigger, `0x00200000-0x00a00000`, a Zorro-II-legacy check
unrelated to chip RAM per se) doesn't fire because this core's Zorro III
Fast RAM is mapped well above that range. So the DMA target is
genuinely Fast RAM via `ddram_ctrl.v` (`sel_zram` routing in
cpu_wrapper.v) - `sdram_ctrl.v` (chip RAM, fixed round-robin, no
timeout/race by design) is not involved.

**Added verification instrumentation (commit 712a5e9a)** rather than
guess a fourth number: `a4091_dma_timeout_cnt` in `ddram_ctrl.v` counts
every time the a4091 DMA-accept (write state 5 / read-in-flight state 1)
fires via the `dma_wait_cnt` timeout while `DDRAM_BUSY` was STILL
asserted - i.e. a genuine "force-ACKed without confirmation" event,
distinct from the normal `~DDRAM_BUSY` accept. Routed through
Minimig.sv -> cpu_wrapper.v -> a4091.v -> the 0x8D0000 debug window
(freed slot 0x3d). Deliberately wired to `ddram_ctrl`'s `reset_n`
(= `~reset_d`, the CORE-level reset: PLL lock / button / RESET pin) -
**not** the Amiga CPU reset that zeroes a4091_siop's own kick/sel/dien
counters on every crash - so this counter survives the crash-and-reboot
cycle and can be read via a4091dbg (rebuilt to print `w[0x3d]`,
redeployed to `SHARE:a4091/a4091dbg`) after recovery. If it reads 0
after a crash, the timeout theory is falsified outright.

Build `20260905_095936_dbginstr.txt` succeeded, clk_sys +0.234, deployed
as `minimig_20260905_A4091_dbginstr.rbf`. Baseline check: `a4091dbg`
signature ok, counter reads 0 fresh after boot as expected.

**RESULT: theory falsified.** Repro crashed again at LBA ~201K/409600
(49%, `SH0` left "Unreadable disk" as always). `a4091dbg` read
immediately after recovery: `DEBUG ddram a4091 DMA-accept TIMEOUT
count = 0` - the ddram_ctrl timeout never fired once, the entire run.
All three widenings (128->1024->16384 cycles) were chasing a mechanism
that was never actually happening. `ddram_ctrl.v`'s DMA-accept path is
cleared as the cause.

Combined with the earlier 300-command RTL stress test (also clean),
the RTL is now cleared on two independent fronts: no SIOP-side logic
bug (sim), no DMA-accept race (hardware counter). Every hardware crash
this whole investigation has shown the identical signature - SIOP
completes its last command cleanly (`INT=ff00 ok`, `DSTAT=00`, idle),
then total silence, then the Amiga has reset. That pattern, with the
FPGA/RTL side now cleared twice over, points at **a4091.device itself**
(the 68k driver, `a4091-software`, `sd.c`/`siop.c`/`cmdhandler.c`) -
code not touched this session, quite possibly a pre-existing bug never
exercised at this scale before (a full non-quick 200 MB format is a far
more sustained/high-volume workload than any earlier test in this
project). Next step: read the driver's IOTD chaining/continuation logic
(`chan_continue_iotd`, `sd_complete`) and completion-interrupt path
(`siop_checkintr`/`siopintr`) for something that only breaks after
hundreds of thousands of back-to-back commands - not more RTL changes.

RTL state to leave as-is for now: 16-bit DMA (P2-7) + multi-ID SCSI +
scaffold strip + the (harmless, if unproven) D_HOLD/dma_wait_cnt
margin bumps + this debug counter. None of the RTL changes are
implicated; reverting them wouldn't fix the driver-side bug once found.

## 20260904-222000 — P1 regression: real root cause found in ddram_ctrl.v (not the SIOP). Fix building.

Continuing from below. The D_HOLD margin fix (a4091_siop.v, commit
5554e962: doubled the post-ACK settle wait for word writes) was tested
on hardware with the SAME `Format DRIVE SH0: FFS` repro and **did NOT
fix it** - crashed again, same signature (silent, `SH0` left
"Unreadable disk"), at LBA ~108746/409600.

Wrote a 300-command sustained WRITE10/READ10 stress test (G27,
a4091_tb.v) - varying RAM buffer alignment and length 1-8 sectors,
back-to-back, byte-exact verify each time. **All 300 passed clean** in
simulation. That rules out a logic/state-leak bug in the SIOP's 16-bit
DMA sequencing - the bug is hardware-only, invisible to the ideal
zero-delay DMA model the testbench uses.

**Real cause, found reading `ddram_ctrl.v`:** the a4091 DMA write
(state 5) and read-in-flight (state 1) accept states force-ACK on a
bounded wait (`dma_wait_cnt`, was `[6:0]` = 128 cycles) even if the
write never actually reached DDR - an existing, deliberate trade-off
(comment: "a rare lost byte is recoverable; a wedged 020 is not",
written for an earlier RC10/status-byte flakiness bug). On timeout this
path looks successful to the SIOP by design, so nothing on the FPGA
side ever shows an error - matching every observation from both
crashes. 16-bit DMA doesn't make individual transactions slower, but
issues them in a denser back-to-back burst than the old byte-DMA
pacing, so it rolls the dice against real DDR contention (CPU, video
sharing the controller) more often per unit of real time - more chances
of blowing the 128-cycle window and silently corrupting memory.

**Fix (commit f3530902):** widened `dma_wait_cnt` 7->10 bits (1024
cycles, ~8x headroom). Scoped to a4091 DMA only - the CPU's own
cache_req fill and the other write_req client in ddram_ctrl.v don't
reference this counter. `sdram_ctrl.v` (chip RAM path) doesn't need the
equivalent change - its DMA slot is a fixed round-robin state, not
variable-latency DDR arbitration, so it has no analogous race.

Build running (`20260904_221936_ddrfix.txt`). Not yet hardware-verified.

## 20260904-180000 — P1 REGRESSION found + root-caused: 16-bit DMA corrupts memory under sustained load. A/B confirmed.

User report: 200 MB SCSI drive (ID1), `Format DRIVE SHx: FFS` (no QUICK,
full non-quick AmigaDOS format) crashes and reboots partway through, on
the scsi6id build only (not the earlier ship build). Guru logs:
  15:24:15  Task "Unknown"       80000004 DEADEND  illegal instruction
  15:32:48  Task "a4091.device"  8000000B DEADEND  unexpected LINEF

Investigation (`/media/usb0/a4091_sd.log`, HPS-side, survives the crash):
both crashes show the SIOP completing its last command cleanly
(`INT=ff00`) then total silence forever - no more SELECTs, and the
a4091 module's `kick`/`sel`/`dien` debug counters reset to 0 (only
happens on the Amiga CPU reset). So: no FPGA/SIOP-side error at any
point, and the crash is a genuine 68k-side event (illegal instruction /
LINEF = executing corrupted memory), not a wedged or erroring SIOP.
Reproduced live twice more (once with HRTMON armed - did not trap,
consistent with a hard reset rather than a recoverable exception).

**A/B test (commit afa99a26, `d16_possible` forced to 0, everything else
unchanged - multi-ID SCSI, scaffold strip):** ran the same
`Format DRIVE SH0: FFS` to completion - all 409,600 blocks, zero errors,
`info` afterward: `SH0 199M 0 Errs Read/Write Test`. Confirms the 16-bit
DATA-phase DMA (P2-7, commit 3929f1a0) is the trigger, not the multi-ID
work or the strip.

**Leading mechanism:** the dma8/dma16 engine's `D_HOLD` post-ACK settle
margin (`d8_hcnt >= 4`, `a4091_siop.v`) was tuned against single-byte
writes - see the comment on that state, added earlier this project to
fix an address-mux-reverts-mid-fill corruption bug. A full 16-bit word
write may need more settle time than one byte, and 16-bit halves the
transaction count for the same data volume, so back-to-back DMA beats
land denser under sustained load. If the margin is thin for word writes,
`dma_req` could drop before the write has actually landed in DDR - a
race entirely inside the RAM controller, invisible to the SIOP's own
bookkeeping (which is why the log never shows an error). Matches every
observation: no FPGA-side fault, only manifests at full-disk scale
(never in the 25-75 KB round-trip tests earlier), corrupts something
in Amiga RAM that later crashes unrelated code.

**Not yet done:** widen `D_HOLD` for `d8_w16` writes specifically and
re-run the same A/B format test to confirm the fix (vs. just leaving
16-bit DMA off). Current box state: A/B (16-bit off) RBF deployed and
verified; `d16_possible` forced-off change is committed as a diagnostic,
not yet reverted to the real logic.

## 20260904-134500 — OSD "A4091 SCSI" section + 6-ID host/RTL support (in progress).

Plan `compiled-stargazing-hennessy.md` approved: 6 SCSI IDs (1..6), each
Disabled/Fixed-HDD with an .hdf picker in the Minimig OSD Drives page.
Removable/CD deferred (needs a SCSI CD-ROM target model).

Done so far:
  - RTL (14f42334): a4091_siop `sel_id[2:0]` output; a4091_sd drops its
    single-slot geometry latch, gains sec_id/sd_id; Minimig.sv holds the
    `a4091_scsi_blocks[1:6]` / `scsi_present[6:1]` store (reset-immune),
    fed by new hps_ext cmd 0x69; `present` / `disk_blocks` derive from it
    routed by sel_id. tb: 26/26 pass (models the store for one slot).
  - Main_MiSTer (4928128a): `scsi_cfg` + `mm_hardfileTYPE scsi[6]`
    appended to mm_configTYPE (old configs still load - loader zero-fills
    a short tail); menu.cpp "A4091 SCSI >" on Drives + MENU_MINIMIG_SCSI1/2
    sub-page; minimig_a4091.cpp now opens 6 .hdf, routes each mailbox
    request by the SCSI ID in the 0x64 poll word; a4091_apply_config()
    pushes per-ID geometry (0x69). Builds clean (ARMv7).

Build order: 16-bit DMA + scaffold-strip RBF first (own build, log
`20260904_132752_b16dma_strip.txt`, running - box loaded, slow), verify
on HW, then the multi-ID RBF.

## 20260904-123400 — b16dma verified on hardware. 559 -> 719 KB/s (+29%), reads/writes byte-exact, timing met.

RBF `minimig_20260904_A4091_b16dma.rbf` (md5 e647799b), Quartus log
`20260904_115916_b16dma.txt`, ~29 min.

Timing (Minimig.sta.summary, all corners):
  setup  emu|pll counter[0] (clk_sys)  +0.420   (b92 was +0.312)
         emu|pll counter[1] (clk_114)  +1.022
         pll_hdmi counter[0] (stock)   +0.417   <- headline WNS
  hold   worst +0.224 (pll_hdmi).   All positive. MET.
The 16-bit path added no timing pressure - fewer DMA transactions, and
`d16_possible` is a shallow gate.

Hardware (RBF reloaded, Amiga booted, MDH0 R/W 0 Errs):
  scsi_rd a4091.device 1 8   -> err=0, RDSK/PART/FSHD/LSEG, 3 passes
  scsi_rd a4091.device 1 32  -> err=0, io_Actual 16384, 3 passes
  devtest -b 512k,4 -m Fast  -> 719-721 KB/s (43% CPU), 4 runs
                                (b92 ship = 559)
  copy A4091.guide (24986 B) -> MDH0 -> back to HPS: cmp IDENTICAL
  copy 74958 B file          -> MDH0 -> back: cmp IDENTICAL

Gain is +29%, not 2x: SCRIPTS instruction fetch is still byte-serial and
the target dbuf is still fill-then-drain one HPS sector at a time - the
DATA-phase DMA was not the sole bottleneck. Next levers if more is
needed: burst the SCRIPTS fetch, or overlap dbuf fill with drain, or
software-SIOP-on-ARM.

STATE ON BOX: RBF minimig_20260904_A4091_b16dma.rbf, Main_MiSTer =
ship build (unchanged), a4091.device 42.39-11-gmm9buf14 (unchanged).

## 20260904-120000 — 16-bit DMA on the DATA phase (P2-7 ceiling). Committed 3929f1a0, FPGA build kicked.

The SIOP byte DMA engine (`dma8`) can now move a full 16-bit word per bus
cycle. `dma16()` task sets `d8_w16` -> `dma_bs=2'b11` +
`dma_wdata=d8_wd16`; read path latches `d8_rq16`. Both RAM controllers
already honour `dma_bs=11` (ddram `dmaWriteBE`, sdram `dmaXdqm`) so no
controller change.

  - new states S_DI16A..E (DATA IN: 2 dbuf reads -> 1 word DMA to RAM)
    and S_DO16A..C (DATA OUT: 1 word DMA from RAM -> 2 dbuf writes).
  - `wire d16_possible = ~dnad[0] & (|data_rem[23:1]) & (|dbc[23:1])`
    -- even Amiga addr AND >=2 to go on both counters. Odd head byte and
    odd tail byte fall back to the single-byte path, so misaligned DMA
    buffers still work.
  - RC10 (0x25) pinned to the byte path (8 bytes, carries readback dbg).

tb: G25 (odd-addr 0x7001, 512 READ) + G26 (odd-addr 0x5A01, 512 WRITE),
both byte-exact incl. the align byte. All 26 groups pass; sim cycle
count down ~25% (3.51 ms -> 2.63 ms sim-time for the same script set).
Two tb opcode bugs found + fixed while writing G25/G26: DATA-OUT phase
code is 000 not 010, and a dbc<data_rem odd-length move exposed a
missing `set_phase(PH_ST)` on the `dbc==0` exit (latent, not on the
new path -- noted, not fixed, no real caller does short reads).

FPGA: pushed to `quartus-host:/tmp/mm-a4091/rtl/a4091/a4091_siop.v` (baseline was
== HEAD~1, clean), `quartus_sh --flow compile Minimig` running,
log `logs/20260904_115916_b16dma.txt`. Not hardware-verified yet.

## 20260904-114500 — Ship binary re-verified over serial. P1/P2 pass CLOSED. Full status.

Final check on RBF b92 + /tmp/MiSTer_A4091_ship (module split,
A4091_DEBUG=1) driven entirely over the serial console (aserial.py):
  info               -> MDH0 15M, 0 Errs, Read/Write TestSCSI
  devtest -b 512k,4  -> 559 KB/sec (43% CPU)
  scsi_rd 32 blocks  -> err=0, byte-exact, 3 passes
No regressions from the P2-8 extraction.

=== P1 ===
  P1-1  >4 KB xfers        DONE   b91: dbuf BUFAW 12->14 (16 KB), seq
                                  protocol. Ring tried first, reverted.
  P1-2  img_present drop   DONE   b90: a4091_sd latch survives the Amiga
                                  CPU reset. Verified with a 1-strobe
                                  Main_MiSTer build.
  P1-3  stale stat/msg     DONE   CacheClearU() in siop_checkintr.
  P1-4  recovery storms    NOT REPRODUCIBLE (scsi_err: clean CHECK
                                  CONDITION, kick==sel). Latent;
                                  1.2 s watchdog backstop.
  P1-5  disconnect/resel   PARTIAL b92: WAIT RESELECT parks (S_WRESEL),
                                  no more fall-through-to-garbage.
                                  Full disc/resel not done - no caller.
  P1-6  LUN!=0             SKIPPED (timing cost, no real initiator).
  +     watchdog 24->25 bits.

=== P2 ===
  P2-7  throughput         101 -> 557 KB/s (5.5x): 16 KB cap + fast
                                  block SPI + stop the per-poll 0x68.
                                  Ceiling now = SIOP byte-serial dma8.
  P2-8  Main patch         DONE   support/minimig/minimig_a4091.{cpp,h};
                                  debug behind A4091_DEBUG, both builds
                                  verified.
  P2-9  RTL scaffold       KEEP until an upstream PR (0x68 dbg_bus feeds
                                  a4091dbg + the dma8 work needs it).
  P2-10 timing margin      standing. b92 clk_sys +0.312. Compare slack
                                  per-clock, not the headline number.
  P2-11 HDToolBox "Addr 0" CLOSED - HDToolBox-side (devtest -p says
                                  address 1, OpenDevice(unit 0) fails).

=== deferred, with rationale ===
  - 16-bit / burst dma8 in the SIOP  (P2-7 ceiling; timing-risky SIOP
    RTL, wants gate-level sim - two RTL changes broke reads this pass)
  - full target disconnect / reselect  (P1-5; big RTL, no caller yet)

STATE ON BOX: RBF minimig_20260904_A4091_b92.rbf, Main_MiSTer =
/tmp/MiSTer_A4091_ship, a4091.device 42.39-11-gmm9buf14.
TEST PATH: `A4091/tools/aserial.py "<amigados cmd>"` over ttyS1.

## 20260904-113000 — P2-8 DONE: a4091 host code -> support/minimig/minimig_a4091.{cpp,h}. Serial test path added.

Extracted the ~234 inline lines from user_io.cpp into a self-contained
module (mirrors minimig_a2065). user_io.cpp now = `#include` +
`a4091_sd_poll()`. Debug behind `A4091_DEBUG`:
  =1: benchmark 563 KB/s, scsi_rd byte-exact, warm reboot remounts +
      MDH0:s8 file persists.
  =0: builds clean, mounts, reads correct, NO a4091_sd.log written.
Cleanups folded in: dead vars (mount_confirmed / a4091_bus_idle /
remounts), stale comments, get_image() / fpga_get_io_version() instead
of reaching into user_io.cpp statics.

Also - after the uinput-keyboard + shared-file test dance kept losing
focus / truncating output / queuing commands: **serial console works**.
`newcli AUX:115200/8n1` runs from S:User-Startup -> ttyS1 on the HPS.
The Amiga serial.device drops chars at 115200 with no flow control, so
`A4091/tools/aserial.py` paces TX at ~25 ms/char + tcdrain. Clean
command/response. This is the test path from here on.

STATE ON BOX: RBF b92, Main_MiSTer /tmp/MiSTer_A4091_ship (module
split, A4091_DEBUG=1, fast SPI, gated snapshot), a4091.device
42.39-11-gmm9buf14.

## 20260904-104500 — P1 + P2 pass complete. Final regression clean. Scorecard below.

Final warm-reboot sweep on b92 + fast/gated Main_MiSTer: MDH0 mounts
(0 strobes), TestSCSI 0 errs, 80 KB file cmp-identical, fresh file
write+read OK, 0 bus resets.

P1:
  P1-1  >4 KB transfers       DONE  BUFAW 12->14 (16 KB dbuf), sequential
                                    protocol kept. Read path verified
                                    8/16/32/40 blocks byte-exact.
  P1-2  img_present drop       DONE  a4091_sd latch no longer cleared by
                                    the Amiga CPU reset. Verified in
                                    isolation (one-shot strobe build).
  P1-3  stale stat[0]/msg[0]   DONE  CacheClearU() in siop_checkintr.
  P1-4  recovery storms        NOT REPRODUCIBLE on b91 (scsi_err: clean
                                    CHECK CONDITION, kick==sel). Latent;
                                    1.2 s watchdog is the backstop.
  P1-5  no disconnect/reselect PARTIAL  WAIT RESELECT now parks in
                                    S_WRESEL instead of running garbage
                                    (tb G24). Full disconnect/reselect
                                    not done - no caller.
  P1-6  LUN!=0 half-checked    SKIPPED deliberately (timing cost, no
                                    real initiator hits it).
  +     SCRIPTS watchdog       24 -> 25 bits.

P2:
  P2-7  throughput             101 -> 557 KB/s (5.5x): 16 KB cap +
                                    fast block SPI + stop per-poll 0x68.
                                    Ceiling = SIOP byte-serial dma8;
                                    16-bit dma8 deferred (RTL/timing).
  P2-8  Main patch             mostly done - single patch, debug cost
                                    removed. Build-flag split deferred.
  P2-9  RTL scaffold           keep until an upstream PR (still needed
                                    for the dma8 work).
  P2-10 timing margin          standing constraint. b92 clk_sys +0.312.
  P2-11 HDToolBox "Address 0"  CLOSED - HDToolBox-side, driver is right
                                    (devtest -p reports address 1).

Remaining real work, both deferred with rationale: 16-bit/burst dma8
(P2-7 ceiling, needs gate-level sim), and full target disconnect/
reselect (P1-5, no caller yet).

STATE ON BOX: RBF minimig_20260904_A4091_b92.rbf, Main_MiSTer =
/tmp/MiSTer_A4091_current (fast SPI + gated debug + one-shot strobe),
a4091.device 42.39-11-gmm9buf14.

## 20260904-102500 — P2-7: 266 -> 557 KB/s by NOT running the debug snapshot every poll. 5.5x total from baseline.

`a4091_dbg_snapshot()` was doing 4 SPI words (cmd 0x68 + 3 reads) on
EVERY `a4091_sd_poll()` call - constant hot-path overhead. Gated to a
~16 k-poll heartbeat + the per-block call only when `verbose`.
  read 512 KB xfers: **557 KB/sec (43% CPU)**  (was 266 / 20%)
Verified: scsi_rd 32-blk byte-exact, 80 KB file cmp-identical,
TestSCSI FS 0 errs after a `devtest -b -d` write pass.

P2-7 full progression: 101 (baseline) -> 222 (b91 16 KB cap) ->
266 (b92 fast block SPI) -> 557 (drop per-poll 0x68). SIOP dma8
(byte-serial, arbitrated) is the remaining ceiling; 16-bit dma8 is the
lever and stays deferred (RTL/timing risk, two RTL changes broke reads
this session).

Also doubles as P2-8: the debug SPI was leaking into the serve loop.
Runtime cost of the logging is now gone; `main_mister_a4091.patch` is
the single source.

STATE ON BOX: RBF b92, Main_MiSTer = fast SPI + gated debug (saved as
/tmp/MiSTer_A4091_current), a4091.device 42.39-11-gmm9buf14.

## 20260904-101500 — b92 SHIPPED (S_WRESEL). P2-7: fast block SPI 223 -> 266 KB/s; the serve-loop spin was useless (reverted).

b92 RBF (S_WRESEL, slack clk_sys +0.312) on the box. scsi_rd 8/16/32
ladder ALL MATCH, 80 KB file cmp-identical, MDH0 mounts. P1-5 hardware-
clean (no regression from the new state).

P2-7:
 1. serve-loop spin (serve N blocks per a4091_sd_poll instead of 1):
    223 -> 223 KB/s. ZERO effect. The block rate is not gated by
    user_io_poll round trips. Reverted.
 2. fast block SPI for the 512 B sector payload (spi_block_read/write =
    fpga_spi_fast, vs a 512x spi_w loop): 223 -> 266 KB/s (~20%),
    verified byte-exact. KEPT.

Measured a 32-block read via the HPS DBG poll counter: ~28 poll-calls
per block during the fill, so a4091_sd IS being fed one block per
main-loop pass - but making that faster (the spin) did nothing, meaning
the fill is not the bottleneck. The ceiling is the SIOP draining dbuf:
dma8 = one byte per arbitrated RAM transaction, ~16384 of them per
16 KB command, plus SCRIPTS instruction fetch byte-by-byte the same
way. 16-bit / burst dma8 is the real lever and it is a timing-risky
SIOP RTL change - deferred with a note (ISSUES #7 / #10).

STATE ON BOX: RBF b92, Main_MiSTer with fast SPI (one-shot img strobe,
no serve spin), a4091.device 42.39-11-gmm9buf14.

Tools: `A4091/tools/scsi_err.c`.

## 20260904-094000 — P2-7 attempt: Main_MiSTer serve loop spins for the next block instead of one-per-poll. Binary built, waiting on b92 RBF.

`a4091_sd_poll()`'s block-serve `for` loop broke on `lba == last_lba`
after every block, so effectively ONE block per user_io_poll() round
trip (~1.5 ms of main-loop overhead per 512 B). a4091_sd only needs
~18 us to stream a block and request the next.

Change (Main_MiSTer only, no RTL): after serving a block, spin the 0x64
poll up to ~400 times waiting for a4091_sd's lba to advance, then serve
the next block in the SAME call. Guard raised 64 -> 512. Still bounded
by the spin count, the guard, and the (st & 3) / range checks. dbuf is
16 KB now (b91) so the old "drain loop overran the 4 KB buffer" hazard
is gone, and the flow control is still lba-change-gated, not
unconditional.

Binary built on build-host. Deploy + measure alongside b92; MUST re-run the
scsi_rd 8/16/32 ladder - the serve loop is the risky bit.

## 20260904-093000 — P1-4 not reproducible on b91. P1-5: WAIT RESELECT now parks (S_WRESEL). b92 building.

P1-4 (recovery storms): built `scsi_err` (out-of-range READ, bad opcode
0x1f, then recovery reads, each DoIO timed). On b91:
  OUT-OF-RANGE read  -> err=0, zeros, 20 ms  (Main_MiSTer zero-fills;
                        not even an error)
  bad opcode 0x1f    -> err=52, SENSE 05/20/00 (ILLEGAL REQ / inv op),
                        20 ms then 0 ms on the 2nd pass
  every recovery read -> err=0, correct data, 20 ms
  a4091dbg: insns=37151 selects=255 kicks=255 (kick==sel, NO imbalance),
            phase-mismatch=4, SIOP idle, stop rsn=00
NO STORM. A clean CHECK CONDITION recovers fine. The historical storms
were the SIOP/target wedging mid-nexus from bugs since fixed (geometry,
dbuf desync). P1-4 downgraded to latent - the widened watchdog (1.2 s)
+ driver reset is the backstop if a future change re-wedges.

P1-5 (no disconnect/reselect): full target-initiated disconnect/reselect
is a big RTL addition with no current caller and is NOT done. But the
existing `WAIT RESELECT` instruction (grp1 op 2) was `st <= S_RUN` - a
no-op that fell through into `MOVE LCRC to SFBR` + whatever, run as
garbage. Reachable whenever the driver points DSP at Ent_wait_reselect
(it does when sc->nexus_list is non-empty). New `S_WRESEL` state: halt
until SIGP (ISTAT bit 5), then jump to the insn's REL alt address (the
driver's select-retry). Watchdog held while parked. A DSP kick also
breaks it. tb G24 covers it (park 20k cyc no IRQ, SIGP -> INT err4).
22 groups pass. Pure RTL - a4091.rom unchanged, no ROM regen.

Tools: `A4091/tools/scsi_err.c`.

## 20260904-090000 — b91 SHIPPED. P1-1 done the boring way: dbuf BUFAW 12->14 (16 KB), sequential protocol kept. 101 -> 222 KB/s.

After the ring reverted twice, the low-risk path: widen the buffer, do
not touch the protocol.
  a4091_target  #(parameter BUFAW = 14)     dbuf 4 KB -> 16 KB (~13 M10K)
  a4091_siop    tgt_buf_addr / data_off     [11:0] -> [13:0]
  a4091.v       tgt_buf_addr wire + .BUFAW(14)
  sd.c          MM_MAX_XFER 4096 -> 16384
No new signal crosses a module boundary - the thing that sank both ring
attempts. `fill` and `data_off` still run 0..rsp_len-1 with no wrap
because a transfer is capped at exactly dbuf size.

BUILD: slack +0.196, and it is on clk_sys (all clocks positive, HDMI
+0.348 this seed). RBF grew 3.64M -> 3.73M (the extra 12 KB of M10K).

HARDWARE VERIFICATION (b91):
  scsi_rd 8 / 16 / 32 / 40 blocks - byte-exact vs the .hdf. Python
    compare of the full 32-block read: "32-block pass1: ALL MATCH".
    40 blocks = 20480 B = a 2-segment transfer (16384 + 4096 via
    chan_continue_iotd), also clean.
  80 KB file (devtest binary) copied to MDH0 and back -> cmp IDENTICAL.
    Still identical after a warm C:Reboot. b90file also survived.
  info -> MDH0 15M, 0 errs, Read/Write TestSCSI
  devtest -b -B 512k,4 -m Fast -> 222 KB/sec, 19% CPU  (was ~101)
  warm C:Reboot: MDH0 remounts, grep -c re-mount = 0 (P1-2 still holds
    with zero strobes on the shipped one-shot Main_MiSTer binary).

devtest -i / -ii / -iii print nothing and return 10 with this binary
regardless of -y - not investigated; scsi_rd + the 80 KB cmp are the
ground truth and both pass.

STATE ON THE BOX: RBF minimig_20260904_A4091_b91.rbf, one-shot-strobe
Main_MiSTer, a4091.device 42.39-11-gmm9buf14.

P1 SCORECARD:
  P1-1 >4 KB transfers      DONE (16 KB cap, read path verified;
                            write path also 16 KB, same mechanism)
  P1-2 img_present          DONE, verified in isolation
  P1-3 stale stat[0]/msg[0] DONE (CacheClearU in siop_checkintr)
  P1-4 recovery storms      not started
  P1-5 no disconnect        not started
  P1-6 LUN!=0               deliberately skipped (timing, low value)
  + SCRIPTS watchdog 24 -> 25 bits

## 20260904-020000 — b90 SHIPPED. Ladder matches b86. P1-2 VERIFIED in isolation, HPS re-strobe removed.

b90 = reverted RTL + the three keepers. clk_sys slack +0.192. (Headline
worst-case was -0.301 but on `pll_hdmi`, the stock MiSTer video pixel
clock - unrelated to the a4091 and a known-marginal path in this core.
Lesson: compare slack PER CLOCK, not the headline number. b88's -0.124
WAS on clk_sys, so dropping the bypass there was correct; b87 +0.184 and
b89 +0.193 both had healthy clk_sys and still corrupted reads, so the
ring's failure was never a timing artefact.)

VERIFICATION on hardware:
  scsi_rd ladder 1 / 3 / 8 blocks, 3 passes each -> byte-exact, matches
    b86 exactly. Ring regression gone.
  info -> MDH0 15M, 0 errs, Read/Write TestSCSI
  write + read back a file -> content correct

P1-2 VERIFIED IN ISOLATION (not just assumed): rebuilt Main_MiSTer to
strobe img_present ONCE ONLY, removing the periodic idle-gated
re-strobe that would otherwise mask any regression. Cold boot, then warm
`C:Reboot`:
  grep -c re-mount  -> 1        (one strobe, ever)
  info              -> MDH0 mounted, TestSCSI
  type MDH0:b90file -> b90-regression-ok   (survived the reboot)
So the a4091_sd latch fix stands on its own. The re-strobe is now
REMOVED from a4091_sd_poll() rather than left as dead belt-and-braces -
which also shrinks P2-8.

STATE ON THE BOX: RBF minimig_20260904_A4091_b90.rbf, Main_MiSTer with
the one-shot strobe, a4091.device 42.39-11-gmm8p1.

P1 SCORECARD:
  P1-1 >4 KB transfers      NOT DONE - ring attempted and reverted, see
                            above. Next: BUFAW 12 -> 13/14, sequential.
  P1-2 img_present          DONE, verified in isolation
  P1-3 stale stat[0]/msg[0] DONE (CacheClearU in siop_checkintr)
  P1-4 recovery storms      not started
  P1-5 no disconnect        not started
  P1-6 LUN!=0               deliberately skipped (timing, low value)
  + SCRIPTS watchdog 24 -> 25 bits

## 20260904-012500 — RING REVERTED. A/B vs b86 proves it broke reads. Keeping img_present + CacheClearU + watchdog. b90 = clean baseline.

b89 (slack +0.193, registered sec_hold + 2 KB headroom, bypass dropped)
still returned bad data - but with a NEW signature: pass 1 of a read
partly ZERO, passes 2-3 correct.
  3 blk pass1: blk1 = 00 41 52 54, blk2 = 00 00 00 44
  8 blk pass1: blocks 3-7 all zero;  passes 2,3 clean
(b87's signature had been stale bytes at each block boundary.)

A/B TEST vs b86 - the decisive one I should have run earlier:
  b86 3 blk  -> RDSK / PART / FSHD correct, all 3 passes
  b86 8 blk  -> all 8 blocks correct, all 3 passes
So multi-block reads were NEVER broken before the ring. My earlier
speculation that they might always have been corrupt (and that
`devtest -b` simply never verified content) was WRONG - worth recording,
because it nearly sent me looking in the wrong place.

DECISION: revert the ring. Two hardware iterations and three FPGA builds
in, it has broken read correctness both times, and neither failure
reproduces in sim - all 22 groups pass, including 8 KB / 32 KB, and they
still pass with RING_HI forced to 512 and with 2000-cycle HW-like
inter-block latency. Zero-delay simulation cannot model a signal
crossing four module boundaries into another FSM, and it gives
deterministic old-data semantics for a dbuf read-during-write that the
inferred M10K need not honour. A working system beats a faster broken
one; the ring is an optimisation and does not get to cost correctness.

KEPT (independently verified, or zero risk):
  P1-2 sticky img_present in a4091_sd - `reset` there is the AMIGA CPU
       RESET, so every warm reboot dropped HPS-side mount state. This
       is the real fix for what the Main_MiSTer re-strobe papered over.
  P1-3 CacheClearU() at the top of siop_checkintr - STATUS / MSG IN are
       read before siop_scsidone's flush.
  SCRIPTS watchdog 24 -> 25 bits (pure counter width).
REVERTED: the ring itself (a4091_target wp/occ/ring_mode/sec_hold/
rd_rdy + producer, a4091_siop tgt_rd_rdy/tgt_buf_re, a4091_sd sec_hold
gate, the cross-module sec_hold wiring) and the direction-aware driver
cap - back to the blanket 4 KB MM_MAX_XFER.

NEXT ATTEMPT AT P1-1, when it is worth the time: widen dbuf
(BUFAW 12 -> 13/14) and KEEP the sequential fill-then-drain protocol.
One parameter, raises the cap 4-8x, costs M10K, adds no cross-module
control path and nothing for the sim/silicon gap to hide in. The
concurrent producer/consumer ring is the "right" design on paper but it
needs a way to validate inter-module timing that this bench does not
have - treat any new signal leaving a4091_target as register-by-default,
and consider gate-level or SDF-annotated sim before trying again.

b90 (building) = the reverted RTL + the three keepers. Expect it to
match b86 on the scsi_rd ladder.

## 20260904-001500 — P1 work: DATA IN ring (b87) + sticky img_present + CacheClearU in checkintr. b87 had a ring regression; b88 fixes it.

P1-1 DATA IN RING. READ was strictly sequential - a4091_sd streamed
cnt*512 into dbuf, and only sec_done released the SIOP to run DATA IN.
Anything over the 4 KB dbuf wrapped `fill` and overwrote unread data,
hence the blanket 4 KB MM_MAX_XFER cap. Producer and consumer now run
concurrently around dbuf as a ring:
  a4091_target: wp / occ / ring_mode; sec_hold (near full -> a4091_sd
    pauses), rd_rdy (non-empty -> SIOP may take a byte). Canned
    responses keep rd_rdy high. T_RDSEC kicks the stream and hands the
    SIOP its length at once instead of waiting for sec_done.
  a4091_siop: S_DIA stalls on tgt_rd_rdy; S_DIC pulses tgt_buf_re.
  a4091_sd: S_RD_STR gated on sec_hold.
Driver cap is now direction-aware: reads 16 KB, writes still 4 KB
(DATA OUT still fills dbuf whole then flushes - the write side needs
the same treatment before it can be raised).

P1-2 STICKY img_present. a4091_sd's mounted-image latch was cleared by
`reset` = `~cpu_rst | ~cpu_nrst_out`, i.e. the AMIGA CPU RESET, so every
warm reboot dropped it. HPS-side mount state must survive a CPU reset;
only an explicit unmount (img_mounted with size 0) clears it now. This
is the real fix for what the Main_MiSTer re-strobe was papering over.

P1-3 CacheClearU() at the top of siop_checkintr - STATUS / MSG IN are
read there, before siop_scsidone's flush, so on a command with no
DATA IN phase they could be a stale cache line. Bare CACR poke, no
alloc, ISR-safe.

Also: SCRIPTS watchdog 24 -> 25 bits (0.6 -> 1.2 s). It is a pure
elapsed-time-in-non-idle counter and one READ can now span 32 blocks;
the HPS serves ~200 blocks/s so 16 KB is ~0.16 s, 32 KB ~0.32 s - too
close to 0.6 s.

b87 (slack +0.184) BOOTED FINE - MDH0/TestSCSI mounts - but multi-block
reads came back with ONE CORRUPT BYTE AT EACH BLOCK BOUNDARY once the
transfer was big enough for sec_hold to fire:
  scsi_rd 1 blk  -> clean
  scsi_rd 3 blk  -> clean (RDSK/PART/FSHD all correct, 3 passes)
  scsi_rd 8 blk  -> blk1 b0 = 4c (want 50), blk2 b0/b2 = 4c/45
  scsi_rd 12 blk -> blocks 8..11 returned the stale content of 0..3
HPS log confirms all 12 blocks WERE fetched (lba 0..11 x3), and the
SIOP moved the full byte count, so data was arriving and being dropped
at the ring, not at the sector server.

The testbench never caught it: ALL PASS with the new G21 (16 blk, 8 KB)
and G22 (64 blk, 32 KB), and still ALL PASS with RING_HI forced down to
512 and with a 2000-cycle HW-like inter-block latency in the block
server. So not a logic bug - a silicon-only effect:
 1. `sec_hold` was COMBINATIONAL out of a4091_target and crossed
    a4091 -> cpu_wrapper -> Minimig.sv into a4091_sd's FSM. Zero delay
    in sim; a long unregistered inter-module path in the fabric.
 2. producer and consumer now touch dbuf in the same cycle, so the
    inferred M10K's read-during-write behaviour matters. Verilog gives
    old-data; Quartus may give new/undefined on a same-address hit.

FIX (b88, building): register `sec_hold`; widen headroom 512 B -> 2 KB
so a4091_sd reacting a couple of bytes late cannot overrun; add an
explicit write-forward bypass on dbuf instead of trusting inference.
`rd_rdy` stays combinational - it must drop the same cycle occ hits 0
or the SIOP would claim a byte the producer has not written.

Tools added: `A4091/tools/scsi_rd.c` - one CMD_READ of N blocks from
LBA 0, prints the first 4 bytes of each block, 3 passes. Deterministic
ground truth vs the .hdf read from Linux; this is what pinned the
boundary-byte signature.

## 20260903-164500 — STATUS: both P0 blockers closed. ISSUES.md rewritten. Open work is now P1 robustness / P2 cleanup.

Core goal met: A4091 virtual SCSI disk is a usable data drive on real
MiSTer hw. Mounts (cold + warm `C:Reboot`), formats (Shell + HDToolBox
low-level), reads/writes with verified integrity, survives reboot with
data intact, boot stays on IDE DH0.

Open problems (see ISSUES.md, freshly rewritten):
 P1-1  >4 KB transfers overrun a4091_target dbuf -> driver 4 KB cap
       band-aid (slow, chained 8-blk cmds). Proper fix = flow-controlled
       dbuf ring in FPGA.
 P1-2  img_present re-strobe is a workaround; a4091_sd clears it on
       module reset (rst_edges climbs). Latch it in RTL / find the
       reset source.
 P1-3  acb->stat[0]/msg[0] can be one cache line stale on a no-DATA-IN
       command (STATUS/MSG read before siop_scsidone's CacheClearU).
       Mitigated, not closed. Safe now to add CacheClearU() at top of
       siop_checkintr (no alloc).
 P1-4  error-recovery / bus-reset SCRIPT can storm (kick >> sel) when a
       command genuinely fails. Masked - little fails now.
 P1-5  a4091_siop has no disconnect/reselect (CON held whole nexus).
 P1-6  LUN!=0 only rejected on INQUIRY, not TUR/READCAP/etc.
 P2-7  ~101 KB/s (byte DMA + 1 blk/poll + 4 KB cap).
 P2-8  Main_MiSTer patch (+238 lines) not split into functional vs debug.
 P2-9  RTL diagnostic scaffold (RC10 readback, dbg_bus, dbg_leak) still in.
 P2-10 timing margin thin (b86 +0.324, earlier builds negative).
 P2-11 cosmetic: HDToolBox shows drive at "Address 0".

## 20260903-163000 — HDToolBox LOW-LEVEL FORMAT works (no error 48). Same two fixes. Raw SCSI FORMAT UNIT / MODE SELECT / multi-blk WRITE all pass.

Drove HDToolBox headless (uinput mouse+kbd) with `SCSI_DEVICE_NAME=
a4091.device`. "Low-level Format Drive" -> confirm -> **completes with no
error**, drive Status flips "Not Changed" -> "Empty", "Save Changes to
Drive" ungreys. No bus reset, no error 48. "Modify Bad Block List" also
opens cleanly ("Bad Blocks mapped out by drive: 0").

So the "error 48" (= TDERR_WriteProt / more likely a mis-read
completion status) was NOT a FORMAT-UNIT-specific RTL gap - it was the
same cache-coherency + img_present-drop pair. `a4091_target` #78's
`OP_FORMAT: st<=T_DONE` (rsp_dir=0, SIOP phase-mismatches DATA-OUT ->
early completion) is sufficient once the status/sense buffers read back
coherently.

`A4091/tools/scsi_fmt2.c` (HD_SCSICMD harness) confirms every op
HDToolBox LLF uses, against a4091.device unit 1, all err=0:
  MODE SENSE(6) pg3            actual=64
  MODE SELECT(6) 12B           actual=12
  FORMAT UNIT FmtData=1 hdr    actual=4
  FORMAT UNIT FmtData=1 512B   actual=512   <- large defect-list DATA-OUT
  WRITE(10) 8 blk @lba272      actual=4096
  READ(10) 8 blk @lba272       actual=4096, verify 0/4096 mismatch
(the WRITE(10) test pattern DID clobber the FFS root block at 272 ->
"MDH0:\0\1\2\3" until re-Format; that is the test being destructive, not
a driver bug. Re-`Format MDH0:` -> clean `TestSCSI` again.)

Also: after HDToolBox's own "reboot to apply" (warm), WB + MDH0 come
back fine (on-disk RDB never Saved, so intact).

Tools committed: `A4091/tools/{scsi_fmt.c,scsi_fmt2.c,uinput_kbd.c,
uinput_mouse.c}`. Amiga mouse accel makes uinput_mouse fiddly - move in
<=3px steps and screenshot between; `echo screenshot >/dev/MiSTer_cmd`.

## 20260903-144000 — ***WORKING*** MDH0 mounts, formats, reads+writes, data verified. Two fixes: CacheClearU + HPS img_present re-strobe.

END TO END SUCCESS on real MiSTer hw (mister):
  info ->  MDH0  15M  9 used  0 errs  Read/Write TestSCSI
  format drive MDH0: name TestSCSI FFS QUICK  -> "Initializing disk..." OK
  echo hello-scsi-a4091 >MDH0:testfile ; copy back -> content matches
  48 SCSI ops during format+file IO, 0 bus resets, 0 OUT-OF-RANGE, 0 errors
Boots from IDE DH0 (constraint honoured); MDH0 = target 1 LUN 0 data drive.

Also verified after AmigaOS `C:Reboot` (WARM reboot, not load_core, per
user): WB comes back with the "TestSCSI" icon, `info` shows
`MDH0 ... Read/Write TestSCSI`, and `type MDH0:testfile` still prints
`hello-scsi-a4091` - the pre-reboot write persisted and re-reads clean.

Two fixes were needed on top of the #78-#85 RTL:

1. siop.c `mm_ramctrl_cache_evict()`: **`CacheClearU()`** as the first
   line. The 32 KB scratch-sweep was a NO-OP (its AllocMem fails / wrong
   bank at ROM-init). TG68 "020" forwards the 68020 CACR clear bit to
   `cpu_cache_new` (`cpu_cache_ctrl[3]` edge -> full wipe, both chip and
   fast instances). One unconditional flush fixes every a4091-DMA-stale
   line - INQUIRY response, FSHD dostype, RDB blocks.

2. Main_MiSTer `user_io.cpp` `a4091_sd_poll()`: **keep re-strobing
   img_present on the slow (0x3fff-poll) schedule forever**, gated on
   `a4091_bus_idle` (no pending sector request last pass), instead of
   stopping permanently after the first sector (`mount_confirmed`). The
   FPGA `a4091_sd` clears `img_present` on its module reset
   (`rst_edges` climbs); once strobing stopped the board went imageless
   -> SELECT timeout -> `devtest -p` "no device", `OpenDevice(unit 1)`
   Fail 46 ERROR_INQUIRY_FAILED -> ROM mounter's rescan found nothing.
   With the periodic re-strobe (verified: "re-mount 64 @ poll 1032192",
   "re-mount 128 @ poll 2080768") img_present stays asserted and MDH0
   mounts + stays alive.

Deployed: RBF minimig_20260903_A4091_b86.rbf, /media/fat/MiSTer (new
build, old saved MiSTer.bak.1788442431), share a4091.device b86.

Debug tooling built this session:
 - `scratchpad/uinput_kbd.c` (ARM static, /tmp/uinput_kbd on box):
   virtual keyboard. `create` (fifo server) + `type/key/enter/quit`.
   RightAmiga+E -> "newshell" gives a Shell; commands via
   `execute SHARE:<script>` with output to `SHARE:` (=
   /media/usb0/games/Amiga/shared/, NOT .../AmigaOS3.2/shared/).
 - MiSTer `echo screenshot > /dev/MiSTer_cmd` -> PNG in
   /media/fat/screenshots/Minimig/.

REMAINING: HDToolBox "Low-level format" (raw SCSI FORMAT UNIT 0x04 with
FmtData DATA-OUT) still needs the a4091_target OP_FORMAT DATA-OUT-consume
fix. Not blocking - Shell `Format` works. Also: consolidate Main patch,
strip RTL scaffold, 101 KB/s throughput (ISSUES.md).

## 20260903-142500 — #86 deployed. Partition is UNFORMATTED (blk272 all-zero). No DH1 icon = expected. Next: make Format work.

#86 (RBF b86 + a4091.device, CacheClearU in evict) on box. HPS trace:
RD 0,1,2,272,272 - same shape. Can't tell from the trace alone whether
the CacheClearU fix took, because BOTH the "dostype matches" and the
"dostype mismatches -> fall back to ROM FFS" paths end with the
partition mounted via the ROM FFS handler (DOS\3 is in Kickstart), and
BOTH then read partition root block 272.

Checked the .hdf directly: **block 272 (partition root) is 512 bytes of
zero** -> the partition was never formatted. So:
 - WB shows RAM/DH0/MiSTer only, NO DH1 icon -> that is CORRECT for an
   unformatted/NDOS volume (no disk.info, no icon). It does not prove
   the mount failed.
 - The actual blocker for "usable DH1" is FORMAT, not the mounter.

Format paths:
 1. Shell `Format DRIVE DH1: NAME x QUICK FFS` -> AmigaOS TD_FORMAT,
    which cmdhandler.c treats as a WRITE (writes io_Data over the
    blocks) -> small scattered WRITE(10)s -> should already work with
    the 4 KB cap. UNTESTED (need Amiga input).
 2. HDToolBox "Low-level format" -> raw SCSI FORMAT UNIT (0x04) via
    HD_SCSICMD. a4091_target #78 does `OP_FORMAT: st<=T_DONE` with
    rsp_dir=0 (no data). If the initiator set FmtData (CDB[1] bit 4) it
    then drives a DATA-OUT phase (4-byte defect-list header [+ list]);
    target is already in STATUS -> SIOP phase-mismatch -> HDToolBox
    "I/O error 48". FIX NEEDED: OP_FORMAT must consume the DATA-OUT
    phase (accept 4 + (hdr[2:3]) bytes, discard, then STATUS GOOD)
    without routing anything to the HPS sector path.

Box access notes: MiSTer `echo screenshot > /dev/MiSTer_cmd` writes
`/media/fat/screenshots/Minimig/*.png` (works, that's how the WB shot
was grabbed). `fbgrab /dev/fb0` = HPS Linux console only, not the core.
ttyS1 has no Amiga CLI bound (uartmode=2 routes it but nothing listens).
`SHARE:watcher1` (shell-script command bridge via
games/AmigaOS3.2/shared/cmd1/{pending,output}) is NOT running - would
need Amiga keyboard input to start it.

## 20260903-134500 — ROOT CAUSE: mm_ramctrl_cache_evict is a NO-OP. FSHD reads stale (1 flipped bit). Fix = CacheClearU(). #86.

#85 leak trace decoded (observed_lba = 0x600000 | tag<<16 | val&0xFFFF):
  0x1 de_TableSize      = 0x10   (16)          OK
  0x2 de_DosType hi     = 0x444F               OK
  0x3 de_DosType lo     = 0x5303               OK  -> dostype = 0x444F5303
  0xA filesysblock      = 2                    OK
  0x4 fhb_DosType hi    = **0x44CF**  (want 0x444F)  <-- BIT 0x0080 SET
  0x5 fhb_DosType lo    = 0x5303               OK
  0x6 dostype hi        = 0x444F               OK
  0x7 dostype lo        = 0x5303               OK
  0x8 block             = 2
  0x9 fse               = 0   (FSHDProcess returned NULL)

So `fshb->fhb_DosType` reads back as 0x44CF5303 - ONE stale bit in byte
0x21 of the FSHD block (disk has 0x4F, CPU sees 0xCF = 0x4F|0x80). The
DMA data is correct in RAM; the CPU's cpu_cache_new copy is stale for
that line. `0x44CF5303 != 0x444F5303` -> ParseFSHD dostype check fails
-> fsrelocate never runs -> no filesystem -> DH1: never mounts. (The
later tag-0x9 run shows the value self-heals after ~4 more reads - that
is natural cache-capacity eviction from the intervening leak DoIOs, NOT
the evict function.)

=> `mm_ramctrl_cache_evict()` (the 32 KB scratch sweep) IS DOING
NOTHING. Its `AllocMem(MEMF_CHIP, 32768)` fails at ROM-init (or lands in
the wrong bank) so the sweep loop is skipped; the "converges after N
reads" pattern is exactly one cache-way (2 KB) of read pressure.

FIX (#86): `cpu_cache_new.v` clears on an edge of `cpu_cache_ctrl[3]`
(`cpu_cache_clear`, wipes BOTH chip+fast instances). TG68 "020" forwards
the 68020 CACR clear bit there. `CacheClearU()` issues exactly that -
one unconditional flush, no alloc, both banks. Added as the first line
of `mm_ramctrl_cache_evict()`; scratch sweep kept as backup. Built
a4091.rom + a4091.device (`FULL_VERSION=42.39-11-gmm6ccu`), hdr 0x5d0,
RTL compiling (logs/20260903_b86.txt).

Note: the 272,272 reads are the ROM FFS handler reading the partition
root block (LowCyl 4 * BPT 68 = 272) - normal once the partition mounts.

## 20260903-131500 — #84: NO leaks fired -> fsrelocate never runs. dostype match FAILS. #85 leaks dostype + PART env.

#84 (RBF b84) HPS trace: RD 0,1,2,272,272 and **not one** of the
0xA/0xB/0xC/0xD/0xE leaks appeared. Those leaks sit inside
`if (fshb->fhb_DosType == dostype) { ... if (fse) { ... } }` in
ParseFSHD. #83's leaks (which DID fire) were all placed BEFORE that
`if`. Conclusion: **the dostype comparison is false** (or FSHDProcess
returns NULL) -> `fsrelocate()` is never called -> the RDB filesystem
is never relocated -> partition has no SegList -> DH1: never mounts.

So the 272,272 reads are NOT the LSEG chain. They are almost certainly
the FFS/OFS handler (started by AddBootNode) reading the partition's
first block (LowCyl 4 * Surf 1 * BPT 68 = 272) and failing because
there is no working filesystem for DOS\3.

#83 leaked `fshb->fhb_DosType & 0xFFFF = 0x5303` (i.e. DOS\3). So the
FSHD block's dostype is right. The mismatch must be on the OTHER side:
`dostype` = `pp->de.de_DosType`, filled by
`copymem(&pp->de, &part->pb_Environment, (pb_Environment[0]+1)*4)` in
ParsePART. If `de_TableSize` (pb_Environment[0]) came back wrong/short,
`de_DosType` (DosEnvec index 16, byte 64) is never copied and stays 0
(pp is MEMF_CLEAR) -> 0 != 0x444F5303 -> no match.

#85 (building, `FULL_VERSION=42.39-11-gmm5leak`) leaks, all before the
`if`: 0x1=de_TableSize 0x2/0x3=de_DosType hi/lo 0xA=filesysblock
0x4/0x5=fhb_DosType hi/lo 0x6/0x7=dostype hi/lo 0x8=block
0x9=(fse!=NULL) 0xC=md->lsegblock. Nails whether the PART env copy is
short and whether dostype is 0.

## 20260903-124000 — #83 leak trace: FSHD read is CLEAN (SegListBlocks=3). blk-272 bug is AFTER line 779. #84 narrows it.

#83 (RBF b83, leak ROM) HPS trace decoded. Note: `io_Offset` is 32-bit
and `lba*512` wraps, so observed_lba = `0x600000 | (tag<<16) | (val&0xFFFF)`.
  req#1  0x600200  tag0 geom.dg_SectorSize   = 0x200  (512)   OK
  req#2  0x610000  tag1 dg_DeviceType&0xFF   = 0             OK (DIRECT)
  req#3  0x628000  tag2 TotalSectors&0xFFFF  = 0x8000 (32768) OK
  req#4-6  RD 0,1,2  = real RDSK / PART / FSHD reads
  req#7  0x630002  tag3 ParseFSHD block      = 2             OK
  req#8  0x640003  tag4 fhb_SegListBlocks    = 3             OK  <-- CLEAN
  req#9  0x655303  tag5 fhb_DosType&0xFFFF   = 0x5303        OK
  req#10 0x660200  tag6 md->blocksize        = 512           OK
  req#11 0x67FFFF  tag7 fhb_Next&0xFFFF      = 0xFFFF        OK
  req#12,13  RD 272  = the bad LSEG read

So the FSHD block-2 read is NOT stale - `fhb_SegListBlocks` reads as 3
correctly. My earlier "stale cache line" theory is WRONG. The block
number turns into 272 somewhere BETWEEN mounter.c:779
(`md->lsegblock = fshb->fhb_SegListBlocks`) and the LSEG `readblock` at
mounter.c:346. Candidates in that window:
  - line 780 `md->lsegbuf = buf + md->blocksize` (can't alias lsegblock,
    12 bytes apart in struct)
  - FSHDProcess() at line 776 - AllocMem + strcpy; if the earlier
    ParsePART `copymem(&pp->de, &part->pb_Environment,
    (pb_Environment[0]+1)*4)` overran (corrupt de_TableSize) the heap
    could be trashed -> AllocMem returns a bad ptr -> scribble
  - driver: `cmd_do_iorequest` CMD_READ does `blkno = io_Offset >>
    periph_blkshift` then `io_Actual = 0` (line 337-338) - io_Actual IS
    reset, so the "stale io_Actual" continuation theory is also dead.
  272 = 0x110 = RDBBlocksHi(271)+1 = also LowCyl(4)*Surf(1)*BPT(68).

Driver read path confirmed clean: `sd_readwrite` builds a READ_6/10 CDB
straight from `blkno`; `chan_current_blkno` is only used by the
continuation path (`chan_continue_iotd`), which only triggers when
`io_Actual < io_Length` after a capped/split transfer - not for these
single 512-byte reads.

#84 (building, `FULL_VERSION=42.39-11-gmm4leak`): minimal leak set -
0xA=md->blocksize & 0xB=fhb_SegListBlocks just before line 779,
0xC=md->lsegblock just after, 0xD=md->lsegblock at fsrelocate() entry,
0xE=md->lsegblock right before the LSEG readblock. Pinpoints exactly
where 3 becomes 272.

## 20260903-123000 — blk-272 analysis: single stale RAM-ctrl cache line at FSHD+0x40. #83 debug ROM compiling on quartus-host (STA phase).

Confirmed from HPS log (`req #1..5`): mounter reads lba 0,1,2 then
jumps to 272 twice. `nblk=32768` in the log is just disk-size
(`f->size>>9`), NOT request length — red herring, no overrun there.

Offsets nailed down (ndk `devices/hardblocks.h`):
  fhb_Next 0x10, fhb_DosType 0x20, fhb_PatchFlags 0x28,
  fhb_SegListBlocks 0x48, fhb_GlobalVec 0x4C.
On-disk block 2: SegListBlocks=3, Next=0xffffffff, DosType=444F5303.

Since reads 0/1/2 map lba->offset correctly, `md->blocksize`==512 is
fine. So `md->lsegblock` (= `fshb->fhb_SegListBlocks`) must equal 272 at
mounter.c:779. 272 = 0x110 = RDBBlocksHi(271)+1. A 16-byte stale cache
line covering 0x40-0x4F would corrupt SegListBlocks (0x48) while
leaving DosType (0x20) and Next (0x10) intact -> mounter still matches
dostype, still processes, but relocates from block 272 -> reads zeros
-> no filesystem -> DH1: not mounted. Matches observed exactly.

`mm_ramctrl_cache_evict` weak point: `md = AllocMem(MEMF_CLEAR|
MEMF_PUBLIC)` (no MEMF_CHIP) -> exec may place `md->buf` in FAST RAM;
#82's chip-arena sweep then evicts the wrong bank. The evict must sweep
the SAME RAM bank as `md->buf` (ddram vs sdram have separate
`cpu_cache_new` caches, neither snoops the a4091 DMA port).

#83 = SCSI-leak debug ROM. `dbg_leak(md,tag,value)` in
`3rdparty/mounter/mounter.c` (`#ifdef A4091_DBG_LEAK`) issues a 512-byte
`CMD_READ` at `lba = 0x00E00000 | (tag<<16) | (value & 0xFFFF)`; HPS
`a4091_sd_poll()` logs each as `RD lba=<hex> OUT-OF-RANGE`. Taps:
  MountDrive after blocksize set: 0=SectorSize 1=DeviceType 2=TotalSectors
  ParseFSHD after each FSHD readblock: 3=block 4=fhb_SegListBlocks
    5=fhb_DosType 6=md->blocksize 7=fhb_Next
Build OK (hdr 0x5d0, `FULL_VERSION=42.39-11-gmm3leak
DEBUG="-DA4091_DBG_LEAK"`), rom hex regenerated, RTL compiling
(`logs/20260903_b83.txt`). Next: deploy RBF b83 to box, `reboot`, read
`/media/usb0/a4091_sd.log` for the 0x00E0xxxx trace.

## 20260903-120500 — #82 still reads blk 272. #83 = SCSI-leak debug ROM to observe mounter internals. Reverted mount_always (hung box).

#82 on box (RBF b82): ROM mounter still does RD 0,1,2,272,272 — the
AllocMem-gate fix did not move the block number. Need to see the
mounter's own values (`md->blocksize`, `fhb_SegListBlocks`, `block`)
but kickstart-time serial is dead on this core (#81).

#83 approach — leak via deliberate out-of-range CMD_READs. New
`dbg_leak(md,tag,value)` in `3rdparty/mounter/mounter.c` (guarded
`#ifdef A4091_DBG_LEAK`) issues a 512-byte `CMD_READ` at
`lba = 0x00E00000 | (tag<<16) | (value & 0xFFFF)`. MiSTer HPS
`a4091_sd_poll()` already logs these as `RD lba=<hex> OUT-OF-RANGE`
in `/media/usb0/a4091_sd.log`. Taps:
  - MountDrive after `md->blocksize = geom.dg_SectorSize`:
    tag0=SectorSize, tag1=DeviceType, tag2=TotalSectors
  - ParseFSHD after each FSHD `readblock` success:
    tag3=block, tag4=fhb_SegListBlocks, tag5=fhb_DosType,
    tag6=md->blocksize, tag7=fhb_Next
Build: `make DEVICE=A4091 a4091.rom FULL_VERSION=42.39-11-gmm3leak
DEBUG="-DA4091_DBG_LEAK"` from /tmp/a4091clean. Header 0x5d0 OK.
RTL rebuild kicked on quartus-host (logs/20260903_b83.txt).

Also: reverted the `mount_always` device.c change (ran `mount_drives()`
from a LoadSeg'd driver → hung the Amiga, recovered via load_core).
sd.c / siop.c keep the 4 KB cap + `mm_ramctrl_cache_evict`.

## 20260903-111500 — #81 no mounter debug (KPrintF not on ttyS1 at init). Root cause of blk-272 = evict dead at init. #82.

#81 (DEBUG_MOUNTER rom): the mounter's `dbg()` -> `printf` -> RawPutChar
-> Paula UART, but NOTHING on ttyS1 during boot (raw kickstart-time
serial isn't routed there on this Minimig; only post-boot RawPutChar
shows). Can't watch the mounter directly. HPS side still shows
RD 0,1,2,272,272.

ROOT CAUSE (found by reading the evict): `mm_ramctrl_cache_evict()`
gated BOTH AllocMem's on `if (mm_evict_fast == NULL)` and re-assigned
`mm_evict_chip` every call. At `init()` time the ROM mounter runs
BEFORE expansion adds the Z3 FAST RAM board (the #60b "kickmodule runs
early" finding) -> `AllocMem(MEMF_FAST)` fails -> `mm_evict_fast` stays
NULL -> the gate never closes, chip arena leaked each call, and with no
usable scratch the sweep is a no-op -> the mounter's block-2 (FSHD)
read is served from a stale RAM-controller cache line ->
`fhb_SegListBlocks` comes back wrong (as ~272 = RDBBlocksHi+1) -> reads
zeros -> no filesystem -> partition not mounted.

FIX (#82, building bzpbvmvib): separate NULL checks, no re-assign; the
CHIP arena always allocates (chip RAM is always in the pool), and at
init() the mounter also reads into CHIP RAM, so the chip sweep evicts
those lines. FAST arena alloc retried on later calls.

On-disk RDB re-verified correct: FSHD.fhb_SegListBlocks=3, FFS LSEG
chain blocks 3-65, 2nd FS (FSHD+LSEG) at 66-71.

## 20260903-104000 — #80: ROM driver RUNS + scans RDB, but stops before mount. #81 = DEBUG_MOUNTER.

#80 (clean-built rom, header 0x5d0) - **the ROM a4091.device init()/
mount_drives() runs at boot now.** a4091_sd.log:
```
req #1 RD lba=0    <- RDSK
req #2 RD lba=1    <- PART
req #3 RD lba=2    <- FSHD
req #4 RD lba=272  <- ??? (RDBBlocksHi 0x10f + 1)
req #5 RD lba=272
```
Then stops. `info` still shows no DH1:.

On-disk RDB is correct: RDSK.PartitionList=1, .FileSysHeaderList=2,
.RDBBlocksHi=271; PART name "MDH0" LowCyl 4 HighCyl 480 flags BOOTABLE;
FSHD DosType 'DOS\3' ver 47.4 fhb_SegListBlocks=**3** (byte 0x48); the
FFS LSEG chain is at blocks 3-15.

So the mounter reads RDSK/PART/FSHD fine (blocks 0-2) but then reads
block 272 instead of block 3 to load the filesystem LSEG chain -> gets
zeros -> no FS -> partition not mounted. 272 = RDBBlocksHi+1, looks like
a fallback path, OR the FSHD (block 2) read was stale and
fhb_SegListBlocks came back wrong.

#81 (building bte6b1451): rebuilt the rom with DEBUG_MOUNTER +
DEBUG_SD - the mounter's dbg() prints will show exactly what RDSK/FSHD
fields it read and why it goes to 272.

Also: early img_present strobe (`re-mount 1 @ poll 64`) confirmed working
on b80; the ROM scan now sees the disk.

## 20260903-101500 — #79 ROM was MALFORMED (empty version -> bad header). #80 = clean-built rom.

#79 full-driver ROM did NOT load: `OpenDevice("a4091.device",1)` fails
even with the DEVS: disk file removed -> kickstart never ran the ROM
driver's init()/mount_drives(). ROOT CAUSE: I built a4091.rom in
/tmp/a4091full which is NOT a git repo -> `git describe` failed ->
version.i was empty -> the ROM header came out 16 bytes short
(0x5c0 vs 0x5d0) -> malformed romtag -> kickstart skipped it.

Also found: `mount_drives()` (the RDB scanner + AddBootNode) only runs
when `romboot` (device init'd from ROM with seg_list==0), NOT for the
disk driver. So the RDB mount REQUIRES a working ROM driver.

Also found + fixed: `a4091_img_present` was asserted late - Main_MiSTer
only strobed SDINFO/SDSTAT on the `(polls & 0x3fff)==0` boundary
(~16 k polls). The ROM driver's RDB scan runs ~1-2 s after FPGA config
and saw an empty bus. Patched Main to strobe the instant the image is
available (`strobed_once`), verified `re-mount 1 @ poll 64` now.

#80 (building b73gdeq8b): rebuilt a4091.rom from the CLEAN git clone
(/tmp/a4091clean, submodules init'd, `FULL_VERSION=42.39-11-gmmfix`),
non-debug, with the mm_ramctrl_cache_evict + 4 KB cap patches. Header
0x5d0, romtool signature OK. Regenerated a4091_rom.hex, full RTL rebuild
(= b78 RTL: FORMAT UNIT, LUN 0x7F, live ISTAT, state-5 timeout, ...).

Patches saved: driver-patches/mm_driver.patch,
integration/main_mister_a4091.patch (early-mount + flow-control + 0x66).

## 20260903-093000 — Drive not seen after `reboot`: nodriver ROM since #69 -> nothing auto-mounts. #79 = full ROM.

User: after AmigaOS `reboot` (warm, != `load_core`), the SCSI partition
does not mount - `info` shows only DH0/RAM/SHARE.

DIAGNOSIS:
 - "Save Changes to Drive" DID work - the .hdf has a valid RDB:
   blk0 RDSK, blk1 PART, blk2 FSHD, blk3-15 LSEG (the FFS binary),
   + a mirror set at blk16-20. Write path is fine.
 - With the disk driver renamed away, `OpenDevice("a4091.device",1)`
   FAILS (-1) -> **there is NO ROM a4091.device**. b70-b78 all carried
   the NODRIVER rom hex - I swapped it in at #69 to debug geometry and
   only ever pushed .v files after, never restored the full hex.
 - So nothing mounts the RDB at boot: no ROM driver diag-time scan, no
   S:Startup mount, no DEVS:DOSDrivers entry.

FIX (#79, building b73at8fq6): rebuilt `a4091.rom` from /tmp/a4091full
(driver = same source, has mm_ramctrl_cache_evict + 4 KB xfer cap),
regenerated a4091_rom.hex (full driver), FPGA rebuild with all b78 RTL
fixes. The ROM driver does the standard A4091 boot-time RDB scan +
AddBootNode -> DH1: should mount after `reboot`, like real hardware.
Build via `PATH=/opt/amiga/bin:/opt/vbcc/bin make a4091.rom
DEVICE_VERSION=42 DEVICE_REVISION=39` (clone lacks git -> pass version).

Also: built a uinput virtual mouse (`scratchpad/uinput_mouse.c`, ARM
static) - MiSTer picks it up (event7 appears, Amiga pointer moves) but
blind pixel-targeting of HDToolBox buttons is slow. For the low-level
format trace, better to have the user click while serial captures.

LOW-LEVEL FORMAT (still error 48 on b78): not yet traced. #78's
`OP_FORMAT -> STATUS GOOD` wasn't enough - HDToolBox's low-level format
is likely FORMAT UNIT with FmtData=1 (defect-list DATA-OUT) or a
block-zeroing WRITE loop; the SIOP phase-mismatches or a chunk fails.
Trace after #79.

## 20260903-090700 — #78 deployed: HDToolBox clean, FORMAT UNIT works

b78 (`3dba5a99`, +0.324 slack) + a4091.device-cap:
  devtest -g          -> 512 32768   OK
  devtest -c FORMAT   -> TD_FORMAT Success
  HDToolBox a4091.device -> **one clean entry**:
     `SCSI 1 0  Not Changed  MiSTer A4091 HD`
     No phantom LUNs. No error dialog. Main screen, all buttons live.

State: the full HDToolBox path is now reachable - Change Drive Type /
Low-level Format / Partition Drive / Save Changes / Verify. Handed to the
user to partition + format.

Build/deploy chain for the record:
  RTL   -> user@quartus-host:/tmp/mm-a4091  (Quartus 17.0,
           `quartus_sh --flow compile Minimig`, ~50 min)
  RBF   -> root@mister:/media/fat/_Computer/, symlink Minimig.rbf,
           `echo load_core ... > /dev/MiSTer_cmd`
  driver-> root@build-host:/tmp/a4091full  (m68k-amigaos-gcc,
           `make DEVICE=A4091 a4091.device DEBUG="-DDEBUG_SD"`)
           -> mister:/media/usb0/games/Amiga/shared/a4091/a4091.device
           -> `copy share:a4091/a4091.device DEVS:` on the Amiga
  Main_MiSTer -> root@build-host:/opt/development/minimig/Main_MiSTer
           (patches: dbg snapshot, sector flow-control, 0x66 no-throwaway,
            WR-data log) -> mister:/media/fat/MiSTer, restart
  serial -> mister:/tmp/aserial.py drives /dev/ttyS1 @ 115200

## 20260902-234500 — Low-level format -> error 48: a4091_target has no FORMAT UNIT

b77 drive list is now clean: `SCSI 1 0 Not Changed MiSTer A4091 HD`
(phantom LUNs gone). Partition path reachable.

User clicked "Low-level Format Drive" -> `Driver returned I/O error
code 48`. dbg trace: SIOP `st=2/31` (fetch / table-indirect block-move)
cycling with NO select (`kick=255 sel=169`), then
`dstat=0x21 rsn=03` = the 50000-instruction SCRIPTS-runaway abort
(BF|IID). The driver's FORMAT UNIT SCRIPT loops waiting on a phase the
target never produces.

CAUSE: `a4091_target` opcode table has no `OP_FORMAT` (0x04); it falls to
`default:` -> CHECK CONDITION with `rsp_dir=0` (no data). The driver's
FORMAT SCRIPT expects a DATA-OUT (defect-list parameter block) or a
specific completion path and spins.

Also reconsidered: the trace shows the SCRIPT never SELECTs during the
runaway (`sel` frozen at 169). FORMAT UNIT on a real drive DISCONNECTs
(format takes minutes) and the driver's SCRIPT waits for RESELECT.
a4091_siop has no reselect (CON held the whole nexus), so the driver's
reselect-wait spins -> 50k-insn abort. The fix makes the target complete
FORMAT UNIT inline (CDB -> STATUS GOOD, no disconnect) so the SCRIPT
follows the phases straight through and never waits for a reselect.

FIX (#78, `3dba5a99`, building b010bwdva): `a4091_target` adds
`OP_FORMAT = 8'h04` -> `st <= T_DONE` (STATUS GOOD, no data phase). A
virtual .hdf needs no low-level format. tb 20/20.

WORKAROUND meanwhile: low-level format is not needed for a virtual disk -
click Continue on the error, then go straight to "Partition Drive" ->
"Save Changes to Drive" -> Exit -> reboot -> `Format`.

## 20260902-233500 — #77 deployed: HDToolBox clean start, no error 48, no phantom LUNs

b77 (`d96b0b89`, minimal LUN fix, +0.280 slack) + a4091.device-cap:
  devtest -g              -> 512 32768   OK
  devtest -ii 16384 -d -y -> PASS
  HDToolBox a4091.device  -> normal "Drives added/removed - Save Changes"
     prompt (phantom LUNs gone). No panic, no error 48. SIOP settles
     idle at kick=215 sel=119 (kick > sel = the driver retrying INQUIRY
     on the now-0x7F phantom LUNs a couple times + fetch-only SCRIPT
     kicks; stable, not a storm).

Handed to the user to click Continue -> partition -> Save Changes ->
Format. All write chunks now <= 4 KB.

Session net (a4091 on MiSTer, this run):
  FIXED: DATA-OUT byte drop (HPS 0x66 throwaway), multi-cmd wedge
  (Main flow control), ddram state-5 deadlock (bounded timeout),
  HDToolBox "Unhandled Interrupt" panic (live ISTAT SIP/DIP),
  "I/O error 48" (4 KB transfer cap), phantom LUNs (INQUIRY 0x7F).
  WORKS: geometry, read, write, HDToolBox launch+scan+partition path.
  OPEN: 101 KB/s throughput; kick/sel imbalance on LUN probe;
  fold Main_MiSTer changes into the patch; a4091_target proper >4KB
  buffer (currently worked around by the driver cap).

## 20260902-230000 — #76 LUN fix timing-failed (-0.344); #77 = minimal one-bit version

#76 wrapped the whole a4091_target T_DECODE `case(c0)` in
`if (clun != 3'd0)` -> main sys clock slack -0.344 (unshippable).

#77 (`d96b0b89`): register `clun_nz` in T_IDLE, use it ONLY in the
INQUIRY `resp[0]` mux (`clun_nz ? 8'h7F : 8'h00`). HDToolBox sends
INQUIRY first, sees "no device", never probes the LUN further - the
CHECK-CONDITION-everything-else branch was unnecessary. tb 20/20.
Building (boo7vc77j).

Meanwhile the b75 RBF + a4091.device-cap (4 KB transfer cap) is on the
box and is the config to test HDToolBox partition/format on - it still
shows the phantom LUNs but writes work.

## 20260902-210000 — HDToolBox "I/O error 48" = 40-block RDB write overran the 4KB target buffer. Driver 4KB cap.

User "Save Changes to Drive" -> "Driver returned I/O error code 48".
a4091_sd.log: HDToolBox wrote lba 26..65 (40 blocks, data "LSEG..." =
the FFS filesystem LoadSeg blocks) as one big WRITE. That overran
a4091_target's 4 KB dbuf (data_off/fill/wr_ptr wrap at 4096) -> phase
mismatch -> driver bus-reset -> error 48. Then kick=NNN sel=0 retry
storm (SCRIPTS re-kicked ~100x, never selects) - the driver's
reset-recovery path is also fragile, but the primary bug is the
oversized transfer.

FIX (`A4091/driver-patches/mm_sd.patch`): `MM_MAX_XFER 4096` cap in
`sd_readwrite` - every SCSI transfer capped to 4 KB (8 blocks), the
existing `sd_complete` / `chan_continue_iotd` continuation re-issues the
rest. Also init `chan_current_blkno` for the non-Zorro-II split path.

  b75 RBF + a4091.device v42.39-cap:
    devtest -g               -> 512 32768   OK
    devtest -ii 16384 -d -y  -> PASS  (32 blocks, chunked 4x)
    devtest -ii 65536 -d -y  -> runs, no wedge (128 blocks, 32x)
    devtest -b -B 32768,4    -> runs, kick==sel (1:1, no storm)

Driver deployed to the box. User can retry HDToolBox: partition + Save
should now work (each write chunk <= 4 KB fits the buffer).

Driver patches captured in A4091/driver-patches/ (against a4091-software
a199fa8).

## 20260902-203000 — #76: a4091_target rejects LUN != 0 (phantom-drive fix)

User feedback: real HDToolBox against a real A4091 shows ONE drive per
SCSI address (LUN 0). Our b75 listed SCSI 1 LUN 0..4 because a4091_target
answered INQUIRY on every LUN.

#76 (`9d7030bf`): plumb the IDENTIFY-message LUN from a4091_siop
(`current_lun`, reset per nexus in S_SELC, new `tgt_lun` output) to
a4091_target (new `lun` input). LUN != 0:
  - INQUIRY  -> resp[0] = 0x7F  (peripheral qualifier 011b, type 1Fh)
  - REQ SENSE -> ILLEGAL REQUEST / 0x25 LOGICAL UNIT NOT SUPPORTED
  - anything else -> CHECK CONDITION
tb 20/20 (LUN 0 path unchanged). Build running (b34st0swf).

Note on the user's reference screenshot: it shows their existing boot
drive ("SCSI 0 0 Not Changed AmigaOS3.2.hdf") = a drive that already has
a valid RDB. Our blank SCSI drive correctly shows "Unknown" - it needs
partitioning, which is the next step (user, with a mouse, or a
Linux-side RDB inject).

## 20260902-195000 — *** #75: HDToolBox RUNS *** - main screen, drive detected, stable

b75 (`532961ca`, live ISTAT SIP/DIP) + `a4091.device` v42.39-hdtb
(2-arena cache-evict, DEBUG_SD) + no-throwaway Main_MiSTer:

  devtest -g              -> TD_GETGEOMETRY 512 32768   OK
  devtest -ii 512/1024/2048 -d -y  -> PASS PASS PASS
  devtest -b -B 2048,4 -m Fast     -> 101 KB/sec, no wedge
  HDToolBox a4091.device -> **"Hard Drive Preparation, Partitioning and
     Formatting" main screen**. Lists SCSI addr 1 LUN 0..4 "Unknown".
     kick/sel counters saturate at 255 (hundreds of probe commands) then
     go idle - stable, no panic, no wedge.

The "Unhandled Interrupt" panic (latched ISTAT.SIP after a select-timeout)
is fixed. HDToolBox can now be driven to partition + format (small-block
IO, which works).

REMAINING:
 - HDToolBox lists 5 phantom LUNs (1/0..1/4) - a4091_target does not
   reject LUN != 0. Cosmetic for now; real fix = INQUIRY with a non-zero
   LUN returns "not present" (peripheral qualifier 011b).
 - transfers > ~6 blocks (> a4091_target's 4 KB dbuf) still wedge. Cap
   the driver's SCSI transfer to 4096 B (siop.c / sd.c), or BUFAW=13 +
   data_off/tgt_buf_addr width audit, or flow-controlled dbuf streaming.
 - throughput 101 KB/s (byte DMA + 1-block/poll HPS serve). OK for setup.
 - fold the Main_MiSTer changes (dbg snapshot, flow control, 0x66 fix,
   WR logging) into integration/main_mister_a4091.patch properly.

Box: b75 RBF, hdtb driver, no-throwaway Main. Ready for the user to
partition/format in HDToolBox with a mouse.

## 20260902-192000 — HDToolBox wedge = "Panic: Unhandled Interrupt" after SELECT timeout on ID 0. #75.

Full-debug driver (DEBUG_SIOP) trace of `HDToolBox a4091.device`:
```
a4091: siop id 7 reset V2
a4091: select target 0 cmd 12            <- INQUIRY probe to ID 0 (no disk)
a4091: intr istat 2 dstat 80 sstat0 20   dsps 150   <- SELECT TIMEOUT (correct)
SIOP_DEBUG: Select Timeout. Target did not respond.
a4091: intr istat 2 dstat 80 sstat0 0    <- SECOND intr, sstat0 already cleared
a4091: spurious interrupt? ... nexus 0 status 0
-> screen: "a4091 Panic - Unhandled Interrupt"  dsps 150 acb 0
```

ROOT CAUSE: `ISTAT.SIP` (bit 1) was LATCHED in S_STOP (`istat[1] <=
(sstat0 != 0)`) and never updated after. Driver ISR: reads SSTAT0
(RTL clears it), loops, reads ISTAT -> SIP still 1, SSTAT0 now 0 ->
can't classify -> panic. On the real 53C710 SIP/DIP are LIVE flags that
follow sstat0/dstat.

#75 (`a6f4e95a`): `rreg(0x21) = {istat[7:2], |sstat0, |dstat[6:0]}` -
computed live; dropped the S_STOP latch. Also reverted the useless S_DOP
DATA-OUT prime (`532961ca`, was -0.033 slack for nothing - the byte drop
was the HPS 0x66 throwaway). Build running (byagnz0sx).

Note: `devtest -g` (selects ID 1, present) never hit this - only the
SELECT of an ABSENT id (STO path) leaves SIP stuck. HDToolBox probes
IDs 0-6 so it hits it immediately.

## 20260902-185000 — HDToolBox launches + finds the drive; wedges during the RDB scan

`run HDToolBox a4091.device` -> "Checking a4091.device address 1 unit 0..."
The driver + geometry + probe all work: HDToolBox found the SCSI disk at
ID 1 LUN 0. Then it wedges (020 grey, SIOP idle, `kick=49 sel=32` -
17 kicks past the last SELECT = the driver's retry storm, `dien=00` =
the driver has disabled SIOP interrupts, i.e. it is in scsi_reset /
error recovery). ~29 sectors served before the storm.

Same wedge class as the multi-command hangs earlier: after ~15-17 failed
SCSI commands the driver's error-recovery path (SCSI/SIOP reset) wedges
the 020. HDToolBox's probe issues enough commands a4091_target rejects
(CHECK CONDITION -> XS_BUSY -> retry) to reach that threshold.

Two ways forward:
  1. a4091_target: handle more commands (MODE SENSE pages 1-5/30/3F,
     READ DEFECT DATA, etc.) and return "empty/ok" instead of CHECK for
     the ones HDToolBox probes -> fewer retries -> never hit the wedge.
  2. Find why the driver's scsi_reset path hangs the 020 (a CPU read of
     an a4091 register that never gets brd_ready / siop_ready?).

#1 is more tractable and is the WinUAE scsi.cpp territory the
software-SIOP plan would give for free.

SESSION NET: geometry OK, read OK, WRITE OK (<=2KB, the HPS 0x66
throwaway was the byte-drop). HDToolBox sees the drive. Blocker =
error-recovery wedge under a probe-heavy command mix.

## 20260902-183000 — *** WRITE PATH WORKS *** (<=2KB). Bug was the HPS 0x66 read, not the SIOP.

The DATA-OUT first-byte drop was NOT in the RTL at all. hps_ext cmd 0x66
(FPGA->HPS sector data) returns blk_wr[K] on SPI word **K+1**, not K+2 -
the SPI samples io_dout AFTER the word's `io_dout <= ...` fires. The old
a4091_sd_poll did `spi_w(0x66); spi_w(0) /*throwaway*/; loop` - one read
too many, so a4buf[0] = blk_wr[1] and every DATA-OUT landed on disk
shifted by one byte. Removed the throwaway.

  b74 + no-throwaway Main:
    devtest -ii 512   -d -y  -> PASS
    devtest -ii 1024  -d -y  -> PASS
    devtest -ii 2048  -d -y  -> PASS   (4 blocks)
    devtest -ii 4096  -d -y  -> wedge  (8 blocks - a4091_target 4 KB dbuf)
  HPS write log: disk now gets [00 01 02 03 04 05 06 07] - correct.

So the RTL SIOP path is now: geometry OK, single+multi READ OK, WRITE OK
for transfers that fit the 4 KB target buffer with margin (<=~6 blocks).
HDToolBox partition/format is all 1-2 block IO -> should work now.

Still open: transfers > ~6 blocks wedge (a4091_target dbuf overrun). Fix =
cap the driver's SCSI transfer to 4096 B, or BUFAW=13 + width audit, or
flow-controlled dbuf streaming.

The b74 S_DOP prime was chasing this same drop and did nothing - the bug
was HPS-side. Revert it in cleanup (costs -0.033 slack for nothing).

Main patch saved: integration/main_mister_a4091.patch.
Box: b74 RBF + no-throwaway Main_MiSTer.

## 20260902-174500 — #73 d8 prime-read wedged (edge-sync + timing); #74 = sequencer prime S_DOP

#73 (d8-engine prime-read, D_REPRIME): timing -0.147 AND wedged on the
write test. Pulsing dma_req low for the re-prime does not re-trigger the
3-stage edge-synced DMA port -> the re-prime read never acked -> d8
timeout -> bus fault -> wedge. Reverted (`2da27851`).

#74 (`bc6d5bde`): prime in the SIOP sequencer instead. New states S_DOP /
S_DOP2: on entering DATA-OUT, fire ONE complete dma8 read of dnad and
discard it (dnad/data_off unchanged), then S_DOA runs the real loop.
Clean full d8 transactions, no edge-sync games. If ad69bb4c's "second
read is clean" holds, this fixes the dropped first byte. Build running
(bi90io3vi).

## 20260902-171500 — WRITE drops the first byte (DATA-OUT). #73 re-adds d8 prime-read.

Chain finally traced with a HPS write-data log + address-pattern integrity
test (`devtest -ii 512 -d -y`):
  devtest wrote  [00 01 02 03 04 05 06 07 ...]
  disk received  [01 02 03 04 05 06 07 08 ...]   (a4091_sd.log FileWriteAdv)
  devtest read back exactly what is on disk -> READ path is faithful.

=> DATA-OUT drops pattern[0], everything shifts down one byte. Not a
garbled value - a clean drop. tb G8 (WRITE10 1 sector) passes in sim, so
the SIOP DATA-OUT *logic* is right; the fault is the d8 engine's FIRST
read from Amiga RAM after the command phase (a long d8-idle gap, CPU had
drained the RAM port) - exactly what ad69bb4c's prime-read fixed before
later commits dropped it for the D_HOLD approach.

#73 (`68f6bde6`): restore the prime-read (D_REPRIME) merged with D_HOLD -
read starting after >=6 idle cycles takes one throwaway ack, then the
real read. Writes never primed. Build running (by3r7yd5l).

Also this round:
 - #71 state-5 + 128-cyc timeout: geometry SOLID, single/repeat READ ok.
 - Main_MiSTer flow control: only serve the next sector when a4091_sd's
   0x64 lba advances (drain loop was runaway-serving, overran the 4 KB
   dbuf, wedged after ~14 cmds). `integration/main_mister_dbg_snapshot.patch`
   + the flow-control edit both live on build-host.
 - a4091_target dbuf is 4 KB (8 blocks); >8-block transfers still wrap it.
   devtest BUFSIZE=8192 (16 blocks) - HDToolBox does small IO so lower
   priority, but a real fix (flow-controlled dbuf or BUFAW=13) is pending.

## 20260902-162000 — #71: GEOMETRY WORKS, single READ ok; -c WRITE + benchmark still wedge. #72 = INT arg on dbg_bus

#71 (state-5 + 128-cyc timeout) deployed:
 - `TD_GETGEOMETRY 512 32768 4096 4 2` SOLID. `[DBG] RC10 buf=00007fff 00000200`
   (maxLBA 32767, blklen 512) - the RC10 DMA write LANDS now. The bounded
   state-5 park keeps #64's fix without the deadlock.
 - `devtest -c READ` -> `CMD_READ Success` (single 8 KB / 16-block read OK).
 - `devtest -c WRITE` -> WEDGE (grey). `devtest -b -B 8192,4` -> WEDGE after
   ~40 sector reqs. HPS dbg frozen at `st=0 idle dstat=04 (SIR)`,
   `kick=24 sel=14` - driver kept kicking SCRIPTS ~10x past the last real
   SELECT, then the 020 died.

So #71 improved the READ path (single read now clean, got further) but a
WEDGE remains after ~14 completed SCSI commands - independent of transfer
size. Something accumulates per-command (driver acb/xs pool leak? SIOP
nexus/CON state? the never-DISCONNECT).

#72 (`8712a9c7`): dbg_bus[63:48] now carries `dbg_lastint` (the arg of the
last SCRIPT INT) instead of pmms/select_id. Main_MiSTer dbg snapshot
updated to log `INT=%04x`. This shows WHICH SCRIPT INT the driver is stuck
on: ff00 = normal completion, ff0x = error N. Build #72 running (brqbilmms).
BUFSIZE in devtest = 8192 (16 blocks) - also note a4091_target's dbuf is
only 4096 B, so any transfer > 8 blocks wraps it (data corruption, maybe
count desync) - candidate too.

## 20260902-160000 — #70 (bare revert) lost RC10 data; #71 = state-5 WITH a 128-cyc timeout

#70 (same-cycle DMA-write ACK) BOOTED but:
 - `TD_GETGEOMETRY 0 1` again; `[DBG] RC10 done err=0 buf=00000000 00000000`
   -> the RC10 8-byte DMA write did NOT land. So #64's state-5 park IS
   required for the write to land (MiSTer f2h DDR wants WE held until it
   accepts).
 - multi-block read / `-c WRITE` STILL wedge (grey screen, ~14 cmds in).
   HPS dbg still shows `st=0 idle dstat=04 (SIR)` frozen - SIOP fine, 020
   dead. So the bare revert did not cure the wedge either.

Conclusion: BOTH are real - the write needs the park, and the unbounded
park wedges. #71: state 5 re-added but with a **128-cycle timeout**; same
bounded wait added to the DMA-read path (state 1 / DOUT_READY). On
timeout the FSM force-ACKs and returns to state 0, so `cache_req` is
always eventually served. Normal ~BUSY/DOUT_READY latency 1-3 cyc.

Still open if #71 doesn't fix the wedge: the wedge may not be the ddram
FSM at all - could be an a4091 SIOP register read that never gets
`siop_ready` (brd_ready needs `sel_reg & siop_ready`), or the sdram_ctrl
DMA slot (#61) stalling on SCRIPTS fetch from chip RAM. Next: add DSPS /
last-INT to the HPS dbg_bus so we see which SCRIPT INT the driver can't
handle.

commit `0742d4b4`. Build #71 running (benp2h72v).

---

## 20260902-150000 — DATA-phase wedge ROOT CAUSE = ddram state-5 deadlock (#64 regression). #70 reverts it.

Set up HPS-side capture: Main_MiSTer `a4091_sd_poll` now reads the SIOP
64-bit debug bus (hps_ext cmd 0x68) every poll and logs `siop_st / phase /
dstat / reason / dma_req / idle` to a4091_sd.log on any change + heartbeat.
Survives an Amiga wedge (HPS<->FPGA only). Patch:
`integration/main_mister_dbg_snapshot.patch` (to save).

Capture during a `devtest -c WRITE` hang (both evict + no-evict drivers):
```
st=11(S_DIB) -> 12(S_DIC) dreq=1 -> 40(S_DIS) -> ... -> 27(S_XFER) ph=3 pmm++
-> st=0 idle=1 dstat=04   <-- SIR (normal SCRIPT INT), FROZEN here forever
```
**The SIOP is fine** - it completed the DATA phase, phase-matched to
STATUS, hit a SCRIPT INT, stopped normally (rsn=00, no watchdog). Screen
goes flat GREY = the TG68 **020** core (a4091 needs `cpucfg[1]`, so this
is the TG68 020 path, NOT fx68k) is frozen on a bus cycle that never gets
`clkena_in` - a hard wedge.

ROOT CAUSE: `ddram_ctrl` state 5, added in #64 to fix "status byte lost".
State 5 parks the ddram FSM waiting for `~DDRAM_BUSY` before ACKing an
a4091 DMA write. **While parked it cannot service `cache_req`** - so the
first CPU fast-RAM read after a long DATA-IN burst hangs forever. Holding
`DDRAM_WE` across many BUSY cycles can also storm the Avalon write FIFO
until BUSY sticks. Single block (512 writes) usually survives; multi-block
(4096+) reliably wedges. #59 predates state 5 -> 768 blocks worked.

#70 (`31722623`): revert to same-cycle ACK, exactly like the CPU write
path (which has never deadlocked). ADDR/DIN/BE hold in
dmaWriteAddr/Dat/BE; the SIOP can't raise the next dmaCS edge until it
sees the ACK + 3-stage sync clears (~6 cyc), by when DDRAM has sampled WE.
If a byte is genuinely lost on a real BUSY stall that is recoverable;
a wedged core is not. nodriver ROM kept. Build #70 running (bascqnx06).

---

## 20260902-090000 — HDToolBox blocked: single READ ok, multi READ + any WRITE wedge (RTL DATA-phase)

Probed the IO paths with `devtest -c` (single-command):
 - `devtest -c READ`  → **`CMD_READ Success`** - single-block read WORKS
 - `devtest -c WRITE` → **hangs the Amiga** (core reload to recover)
 - multi-block read → serves 24-40 blocks then hangs (non-deterministic N)

a4091_sd.log ground truth (Linux side, bypasses all Amiga caches):
 - reads: `FileReadAdv -> 512` for every req, LBAs increment correctly
 - **old writes DID land**: lba 10 = `00 01 02 03 04 05 06 07`,
   lba 20 = `57 52 4f 54 45 2d 42 59` ("WROTE-BY...") from earlier tests
 - hdf block 0 = junk (`00 00 00 40 1c 7a 82 40`), NOT an RDB

Conclusion: the DMA DATA phase (SIOP <-> a4091_target <-> a4091_sd <->
hps_ext) works for a single block but breaks under sustained transfer
(read) or at all for write. Same handshake bug both directions.
**HDToolBox partition/format needs working writes → blocked on this RTL
bug.** It is pre-existing (b62 shows it) and needs FPGA-side debug:
capture dbg_bus / a4091_siop `st` + a4091_sd `dbg_state` during a live
hang (hard: the wedge kills the whole Amiga - need a 2nd serial reader,
or make a4091dbg run as a background task before triggering).

WHAT WORKS NOW (real progress this session):
 - geometry: `TD_GETGEOMETRY 512 32768` solid (2-arena cache-evict driver)
 - single-block SCSI read
 - the FPGA-side coherency question is answered (driver-side evict, not RTL)

Box: b69 RBF, O57 on, drain-loop Main_MiSTer, Workbench, recovered.

---

## 20260902-082000 — block-read wedge is PRE-EXISTING (b62 too), not a regression; Main poll rewrite didn't fix

Chased the block-read `ERROR_BUS_RESET`:
 - no-evict driver: serves ~24-40 sequential blocks (lba 0,1,2… correct in
   a4091_sd.log) then wedges the Amiga hard (core reload to recover).
 - **b62 RBF wedges the same way** with its native ROM driver and the exact
   #59 command (`-b -B 32768,4 -m Fast`). So this is NOT caused by the
   #61/#64/#69 RTL changes. Either #59's "768 blocks" was a narrower case,
   or the box's Main_MiSTer / hdf changed since.
 - post-wedge the SIOP re-requests the SAME lba forever (log shows
   `lba=255` = post-BUS_RESET garbage CDB decode); the HPS drain loop then
   spins. lba=255 is a SYMPTOM of the reset, not the cause.

Rewrote `a4091_sd_poll()` in Main_MiSTer: serve the mailbox EVERY poll in a
drain loop (was 1/64), and gate the re-mount strobe on `!mount_confirmed`
(set once the core pulls its first sector) so it can never fire
mid-transfer. Built on build-host (2.3s), deployed, MiSTer restarted, b69 linked.
**Did not fix the wedge** → confirms the bug is RTL-side, in the
a4091_sd ↔ SIOP DATA-IN / blk_done handshake, and it is old.

*** GEOMETRY REMAINS SOLID *** on b69 + 2-arena-evict driver:
`TD_GETGEOMETRY 512 32768 4096 4 2` every run, across core reloads.

Box now: b69 RBF, O57 on, new drain-loop Main_MiSTer (pid from setsid, NOT
inittab-respawned - `killall MiSTer` kills it dead), Workbench.
Driver on box: `share:a4091/a4091.device` = the [DBG] 2-arena-evict build
(v42.39-b69dbg/e3). `build-host:/tmp/a4091full` has siop.c evict + sd.c [DBG].

NEXT: try HDToolBox anyway — partition/format is small sequential IO and
may dodge the bulk-transfer wedge. Separately: RTL debug the
a4091_sd/SIOP DATA-IN handshake (needs dbg_bus capture during a live
hang; the wedge kills the whole Amiga so needs a second serial reader).

---

## 20260902-040000 — #69 nodriver + driver-side 2-arena cache evict → GEOMETRY SOLID; block read regressed

#69 (`99d32da6`, nodriver ROM) boots, O57 on. Disk driver
`copy share:a4091/a4091.device DEVS:`.

**Driver-side coherency fix that works:** `a4091.device` siop.c
`siop_scsidone()` — after `CachePostDMA`, if `xs->xs_control & XS_CTL_DATA_IN`,
call `mm_ramctrl_cache_evict()`: sweep a 32 KB scratch arena in BOTH chip
AND fast RAM (8-byte stride, one touch/line) to evict the stale DMA-buffer
line from cpu_cache_new. cpu_cache_new has SEPARATE instances for chip
(sdram_ctrl) and fast (ddram_ctrl) RAM - a fast-only sweep only half-fixed
it (`b69e`/`b69e2`). Two-arena sweep (`b69e3`):

  `devtest -g a4091.device 1`  → `TD_GETGEOMETRY  512  32768  4096 4 2`
  **CORRECT, 4/4 runs.** (Was 0/1 flaky for weeks.)

  - devtest's OWN direct RC10 line still flaky (1/4) - devtest is not
    patched, its buffers stay stale. Cosmetic; HDToolBox uses the driver.

**NEW REGRESSION:** `devtest -b -B 4096,4 -m Fast` → `Read Fail 48
ERROR_BUS_RESET at 0x1000`. a4091_sd.log shows the sector-server getting
`req RD lba=255 nblk=32768` (nblk = the whole disk size - garbled CDB
fields), looping + re-mounting. Block READ via this driver+RTL combo is
broken. #59's good read path was b59 RTL + the ROM/other driver.
Needs: isolate whether it's the evict (huge in-interrupt sweep tripping
the SIOP watchdog), the nodriver disk-driver read path, or a stale
CDB/SCRIPTS read.

State: driver = `/tmp/a4091full` on build-host (siop.c has mm_ramctrl_cache_evict,
sd.c has [DBG]); built `DEBUG="-DDEBUG_SD"`. Box: b69 RBF, O57 on,
Main_MiSTer is the Sep-1 20:57 patched sector-server build.

---

## 20260902-033000 — #68 boots clean w/ O57, geometry still broken (ROM drv) → #69 nodriver building

#68 (`987fdc3c`) deployed, O57 ON → **boots to Workbench**, SCSI attaches.
`devtest -g a4091.device 1`:
```
TD_GETGEOMETRY       0            1
READ_CAPACITY_10     0            1
Read-to capacity   512            1
```
Full ROM driver + the #61 sdram DMA slot does NOT fix geometry. RC10
bytes still arrive wrong at the CPU (SIOP readback was always exact →
coherency, ROM-driver-in-chip-RAM path). Confirms: need the nodriver
config from #60b.

#69 kicked: `a4091_rom.hex` regenerated from `a4091_nodriver.rom`, full
clean rebuild. Disk driver `a4091.device` v42.39-b69 (still has [DBG]
RC10/inquiry traces) built on build-host, deployed to
`mister:/media/usb0/games/Amiga/shared/a4091/a4091.device`.
Test plan on #69: boot IDE → `copy share:a4091/a4091.device DEVS:` →
`devtest -g` x5 → `devtest -i` write → HDToolBox.

---

## 20260902-030000 — #67 magenta-crash; both FPGA coherency fixes dead → back to nodriver ROM (#68/#69)

#67 (ramcinhibit = a4091_ena) → **magenta/garbage crash** with O57 on;
boots fine with O57 off (isolation confirmed: ramcinhibit is the break).
cpu_cache_new's `cache_inhibit` only blocks new cache-line *allocation*
(FILL1→FILLW), it is NOT a safe sustained read-bypass — under constant
inhibit every fetch desyncs the 4-word line-fill handshake.

So BOTH FPGA-side coherency attempts are out:
  - snoop into cpu_cache_new (#65/#66): green screen, functional not timing
  - ramcinhibit sustained (#67): magenta crash

**Re-read journal history (lost in compaction):** #60b already had
geometry WORKING 5/5 (`TD_GETGEOMETRY 512 32768`) with
**a4091_nodriver.rom + disk-loaded a4091.device**. Root cause back then:
the autoboot ROM driver runs as a kickmodule EARLY, before Z3 fast RAM
joins the pool → its acb/ds/buffers land in CHIP RAM → chip-RAM DMA
misroutes. The disk driver loads post-boot → acb in fast RAM → clean.

The snoop/inhibit detour (#64-67) was chasing a re-diagnosis that may
have been a second-order effect. The known-good config is nodriver ROM.

PLAN:
  - #68 (building, HEAD bfef9030): b64-equiv ddram (dedicated DMA port +
    state-5 write-race fix) + the #61 sdram DMA slot + ramcinhibit=0,
    FULL ROM driver. Boot-test + one geometry data point (does the
    sdram slot alone fix the ROM driver?).
  - #69: swap a4091_rom.hex → a4091_nodriver.rom, rebuild. Return to the
    #60b known-good path: boot from IDE, `copy a4091.device DEVS:`,
    mount, HDToolBox. Test geometry + WRITE + partition/format.

commits `bfef9030` (ramcinhibit→0), earlier `02e95441`/`40285ba9`.

---

## 20260902-021000 — #66 STILL green; reverted snoop, ramcinhibit=a4091_ena (#67)

Deployed #66 (b65 + reset-init of dmaWriteAddr/Dat/BE). **Still bright
green at boot** (+60s, two screenshots). Reset-X theory was wrong.
Rolled box back to b62 → boots to Workbench fine (box/config OK), so the
snoop wiring itself is the break, init or no init.

Conclusion: connecting `cpu_cache_new.snoop_*` in ddram_ctrl pulls the
whole port-B write path onto the I/D-cache M10Ks (tag compares, 4×
data-RAM write ports) that Quartus elides when the snoop inputs are
constant. Something in that path wedges the core at boot even with no DMA
traffic. Timing was met (+0.058) so likely a RAM-port / read-during-write
inference hazard, not pure fmax.

**#67 = abandon the snoop approach.**
- ddram_ctrl reverted to the #64 state (keep the DMA-write-race state-5
  fix, drop `dma_write_snoop` + the 4 `.snoop_*` connections).
- `cpu_wrapper.v`: `assign ramcinhibit = a4091_ena;` (was `1'b0`).
  `ramcinhibit` feeds `cache_inhibit` on BOTH ram1 (sdram_ctrl, chip+Z2)
  and ram2 (ddram_ctrl, Z3). With O57 on, all fast RAM is uncached:
  CPU writes to a buffer go straight through, the a4091 DMA lands in
  DDR/SDRAM directly, CPU reads see fresh data. Coherent + boot-safe.
  Cost: CPU speed, only while the SCSI board is switched on.

commit `02e95441`. Build #67 running (job bn4qstkut).

---

## 20260902-150000 — *** ROOT CAUSE: ddram DMA WRITE race *** (#64)

## 20260902-170000 — #64 didn't fix it; THE REAL BUG = ddram cache not snooped (#65)

## 20260902-190000 — #65 green-screened; snoop feed was X at boot (#66)

#65 (cache snoop) does NOT boot - bright green screen. b64 (write-race
fix only) boots fine (screenshot-confirmed Workbench), b62/b59 boot.
Isolated: the snoop wiring is the break.

`cpu_cache_new` samples `snoop_adr` combinationally (sdr_itagN_match)
AND latches it every cycle in SDR_SM_IDLE. #65 wired it to
`dmaWriteAddr` which had NO reset -> X at power-on -> poisons the cache
FSM -> CPU can't fetch -> green screen.

#66: init dmaWriteAddr/Dat/BE (and dmaReadAddr) to 0 in the ddram_ctrl
reset. Then snoop_adr=0 at boot, harmless; snoop only acts on real DMA
writes. Box restored to b62 meanwhile. PENDING #66.

(Test-harness pain: repeated killall/setsid left the MiSTer wedged; a
full `reboot` fixed it but wiped /tmp - had to redeploy g2.py/g3.py.
Screenshot via `echo screenshot > /dev/MiSTer_cmd` is the reliable way
to check boot state.)

#64 (dma write hold-WE) deployed: geometry 0/12 (flaky -> consistently
0/1). SIOP readback still byte-exact. So the write DOES reach DDR - the
CPU just doesn't see it.

ROOT CAUSE: `ddram_ctrl` instantiates `cpu_cache_new` (read cache for
CPU Zorro-fast) but leaves `.snoop_*` UNCONNECTED. `sd_getgeometry`
CPU-writes 0 to the caller's DriveGeometry, then issues INQUIRY / READ
CAPACITY(10); the data-in DMA writes straight to DDR via the dedicated
port, bypassing the cache. CPU then reads geom -> cache HIT on stale 0
-> TotalSectors=1 SectorSize=0. `devtest -c`/`-b` buffers are never
CPU-written first so they missed the cache and worked. The #62 SIOP
readback reads DDR directly so it always saw fresh bytes.

FIX (#65): wire ddram_ctrl `cpu_cache .snoop_act/adr/dat_w/bs` to the
dma write (dmaWriteAddr/Dat/BE), pulsed by `dma_write_snoop` from state
5 the cycle the DDR accepts. Keep #64's state-5 discipline (clean snoop
point). Follow-up: sdram_ctrl DMA slot needs the same. PENDING #65.

Got the driver's own trace working (sd.c gates USE_SERIAL_OUTPUT on
-DDEBUG_SD; rebuilt with DEBUG="-DDEBUG_SD", + `avail flush` to expunge
the stale resident device). Two back-to-back `devtest -g`, SAME buffer
addr 0x40123cd4, SAME driver:
  run 1: [DBG] RC10 done err=0 status=ff buf=00000000 00000000 -> 0/1
  run 2: [DBG] RC10 done err=0 status=ff buf=00007fff 00000200 -> 512/32768
xs->error is 0 (not an error!). The swap runs; it's the BUFFER that is
zero. RACE, per-run not per-boot. And status byte = 0xff EVERY run
(never lands - but 0xff isn't CHECK/BUSY so err stays 0).

BUG in the grafted ddram_ctrl dedicated dma WRITE port: state 0 fired
DDRAM_WE and set dma_write_ack the same cycle -> the SIOP got ACKed
immediately. If DDRAM_BUSY covered WE's single cycle, the write sat
un-taken (ADDR/DIN/BE still valid) but the SIOP advanced to its next
beat, re-entered ddram state 0 and OVERWROTE ADDR/DIN with the next
byte before the DDR took the stalled one -> byte lost. The lone STATUS
write (right after a data burst, DDR busy) lost every time; RC10's
8-byte data-in lost intermittently. Reads and `devtest -c` (sync) and
`devtest -b` (bulk) masked it.

FIX (#64): dma write goes state 0 -> new state 5, holds DDRAM_WE (top
clears it only on ~DDRAM_BUSY = when the DDR accepts), ACKs the SIOP
only from state 5 on ~DDRAM_BUSY. state 5 blocks any other access from
touching ADDR/DIN/BE. Mirrors the read in-flight discipline. CPU write
path untouched. ROM hex back to with-driver. PENDING build #64.

This is the same class as the multi-month SCRIPTS-FETCH corruption
(#29-48) - build #48 fixed the READ side, the WRITE side of the same
graft was never scrutinised because reads were the visible symptom.

## 20260902-130000 — *** DMA WRITE PATH IS PERFECT *** ; Bug A is 100% driver

#62 on HW: `RC10 data-in dest addr = 4000e640` then
`RC10 dest READBACK = 00 00 7f ff  00 00 02 00` - the SIOP wrote 8 bytes
to Z3 fast and READ THEM BACK BYTE-EXACT. The a4091 ddram DMA write path
is 100% correct. Bug A is entirely driver-side: the correct 8 bytes ARE
at &geom->dg_SectorSize, but the driver's geom_done_get_capacity takes
the `xs->error != 0` branch (-> RC16 -> mode sense fallback).

INT=ff00, resid=0, status GOOD (a4091_target returns GOOD). scsipi
resets xs->error only on ERESTART. So something sets xs->error for the
async+tagged RC10 despite a clean completion. Suspect: the per-command
async callout timer (scsipi_make_xs_locked timeout=1000ms) firing
(siop_timeout -> XS_TIMEOUT) because the async RC10, submitted from
inside the INQUIRY callback, is not started / not marked done fast
enough; or a tag-lifecycle bug.

NEXT: b63 = b62 RTL + a4091_nodriver.rom, load the DEBUG a4091.device
(v42.39 built from the full clone, printf in geom_done_inquiry /
geom_done_get_capacity). Will show xs->error and the raw bytes the
driver sees. The sdram DMA slot (#61) and the readback (#62) stay in as
correct/diagnostic; a clean release build strips the readback later.

## 20260902-113000 — chip-RAM theory WRONG; RC10 dest is Z3 fast (#62 readback)

#61 on HW: geometry still `0 1`. `RC10 data-in dest addr = 4000e5e8`
(and 0x4000320c, 0x4000da60 other boots). Amiga memory map (devtest -m):
**Zorro III RAM at 0x40000000 size 0x10000000 (256MB)**. So the RC10
dest IS Zorro-III fast, NOT chip RAM. It's ~12-58KB into Z3 fast, in
devtest's own used data region. The chip-RAM-DMA theory does not
explain this - the ddram dma port already reaches 0x4000xxxx (the whole
OS runs there via the CPU's ddram path).

The sdram DMA slot (#61) is still a correct/useful addition (real hw
reaches chip RAM) but it is NOT the geometry bug.

Verified the ddram dma WRITE path is byte-for-byte identical to the CPU
write path in ddram_ctrl (writeDat/writeBE/DDRAM_ADDR/DDRAM_BE all same
formula; my dmaWriteBE = ~{dmaU,dmaL} matches ~{cpuU,cpuL}). So the
write SHOULD land.

=> either the DMA write to 0x4000e5e8 silently does NOT land in DDR, or
the driver reads a different address. #62: after RC10's data-in the
SIOP issues 8 DMA READS from the same dnad (S_RBA/S_RBB) into
dbg_rc10_rb[0..7] @ board 0x8D0080. If readback == 00 00 7f ff ... the
write landed (bug is driver-side); if readback != the written bytes,
the ddram dma write path is broken for this case. PENDING #62.

routing split kept from #61: sel_zram -> ddram port, else -> sdram port.
0x4000e5e8 matches sel_z3ram1 (z3ram_base1=4, 256MB) -> ddram port.

## 20260902-100000 — #61 built: sdram DMA slot, timing MET (+0.015)

Clean build, 0 errors, worst-case setup +0.015 ns (razor-thin - the
DMA slot is on the clk_114 / 114 MHz SDRAM critical path; passes but no
margin, would want to pipeline/relax for a real release). Deployed b61,
restored the autoboot-ROM driver (deleted DEVS:a4091.device). Testing:
geometry x8 with the ROM driver + a read benchmark WITHOUT -m Fast
(chip/normal buffers now reachable). PENDING result.

## 20260902-090000 — OPTION A: DMA slot added to sdram_ctrl (#61)

Implemented. a4091 DMA now routes by target:
 - `sel_zram` (Zorro-III fast) -> ddram_ctrl dma port (as before)
 - everything else (chip / motherboard RAM) -> NEW dma slot in
   sdram_ctrl ram1

sdram_ctrl.v (+~65 lines): slot_type DMA=4, 3-FF CS sync + rising-edge
detect, one 16-bit byte-masked transfer per CS pulse. Inserted in the
RAS arbitration below CPU writes, above the read cache (so heavy CPU
code fetch can't starve the SIOP; SIOP just waits on dmaACK). Read word
latched at state 9 (same as CHIP), acked at state 10; writes reuse the
CAS datapath (cas_dqm / cas_sd_we / datawr) and ack at state 10 too.

cpu_wrapper.v: `a4091_dma_zorro`/`a4091_dma_chip` split from the muxed
`sel_zram`; dma_rdata = chip ? sdmaRD : dmaRD, dma_ack = dmaACK |
sdmaACK. sdma addr = ramaddr[24:1] (identity for chip). Reuses
a4091_dmaWE/U/L/WR for both ports (only CS differs).

Minimig.sv: new a4091_sdma* wires, wired cpu_wrapper<->sdram_ctrl ram1.

sdram_ctrl.v syntax-checks clean (only the expected missing
cpu_cache_new extern). ROM hex restored to WITH-driver so #61 tests the
real failing case: the autoboot-ROM driver's chip-RAM acb is now
reachable. Clean build (db wiped). PENDING #61.

Known limitation: DMA writes to chip RAM don't snoop the TG68K (020)
cache (snoop_adr is chipAddr only). The ACTIVE core is fx68k (68000,
no cache) so this is moot for now; note if the 020 core is used.

## 20260902-073000 — CONSOLIDATED STATUS

STANDING DEPLOY: RBF = minimig_20260902_A4091_b59.rbf (ROM driver,
clean, timing +0.133). MiSTer = clean mailbox-fixed binary
(md5 70c75c0...). Config O56+O57, IDE boot, uartmode 2.

WORKS ON HW:
 - autoconfig, autoboot ROM, a4091.device 42.39 loads, INT2
 - SELECT to ID 1, IDENTIFY, tagged 3-byte MSG_OUT, CDB send
 - TUR (Success Ready), INQUIRY (V='MiSTer' P='A4091 HD'), device OPEN
 - READ(6)/(10): sector server serves blocks end to end
   (a4091_target -> a4091_sd -> hps_ext 0x64 -> Main_MiSTer -> .hdf).
   `devtest -b -m Fast` completes, no watchdog, 700+ blocks served.

FLAKY (boot-deterministic, NOT run-to-run):
 - TD_GETGEOMETRY: correct on some boots, `0 1` on others. The SIOP
   ALWAYS delivers READ CAPACITY(10) byte-exact (dbc0=8 resid=0
   INT=ff00 verified every time). The driver's acb/ds SCRIPTS structs,
   when the driver is the autoboot-ROM kickmodule, land in CHIP RAM
   (allocated before Z3 fast is in the pool). The a4091 dedicated DMA
   port is on `ddram_ctrl ram2` (Zorro fast / DDR) ONLY - chip RAM is
   in `sdram_ctrl ram1` (SDRAM). So DMA to those structs misroutes.

NOT WORKING:
 - WRITE end to end (blocked: devtest -i needs geometry; the WRITE(6)
   CDB + sec_wr path itself does fire).

THE REAL FIX (needed for reliable geometry + write + HDToolBox):
 a4091 DMA must reach chip RAM like real hardware. Options:
   A. add a DMA slot to sdram_ctrl ram1 (mirror the ddram_ctrl dma
      port); route a4091 DMA by address: Zorro -> ram2, chip/Z2 ->
      ram1. ~cleanest, moderate RTL work on the fAMpIGA controller
      (it is slot-structured: CHIP / CPU_READCACHE / CPU_WRITECACHE).
   B. ship a4091_nodriver.rom in the RBF + startup `copy a4091.device
      DEVS:` + mount. Driver then loads post-boot into fast RAM.
      Confirmed 5/5 geometry once on a clean boot; needs the startup
      integration + a non-hacky MiSTer restart path to be solid.
   C. hybrid: dedicated DDR port for Zorro, CPU-masquerade for chip
      addrs only. Fiddly, the masquerade path had the old corruption
      bug (on reads during phase gaps).

Recommend A. Sub-steps saved in memory [[a4091-mister-project]].

## 20260902-063000 — Bug A ROOT CAUSE: ROM-resident driver's DMA buffers in CHIP RAM

#60b (nodriver ROM) + disk-loaded a4091.device: `devtest -g` => 5/5
`TD_GETGEOMETRY 512 32768` CORRECT. Same driver source as the flaky
ROM one (v42.39).

ROOT CAUSE: chip RAM lives in `sdram_ctrl ram1` (SDRAM daughterboard);
Zorro fast lives in `ddram_ctrl ram2` (DDR). The a4091 dedicated DMA
port is ONLY on ram2. cpu_wrapper `sel_chipram = !addr[31:21] && cchip`
and `cchip` is 0 during a4091 DMA, so a chip-RAM DMA address decodes to
nothing -> misroutes. The autoboot ROM driver runs as a kickmodule
EARLY (before Z3 fast is added to the pool) so its acb/ds SCRIPTS
structures land in CHIP RAM -> every DMA to them is flaky. The disk
driver loads post-boot, fast RAM up, acb in fast -> reliable.

Also explains why reads need `-m Fast` (data buffer must be fast).

FIX OPTIONS:
 (a) ship a4091_nodriver.rom + startup `copy a4091.device DEVS:` +
     mount. Works NOW, 5/5. User boots from IDE so no SCSI autoboot
     needed. LOW effort.
 (b) RTL: add a dma port to sdram_ctrl too, route chip-addr a4091 DMA
     there. Correct/general (real hw reaches chip RAM). HIGH effort
     (TobiFlex fAMpIGA controller).
 (c) hybrid: dedicated DDR port for Zorro-fast, CPU-masquerade for chip
     addrs only (rare).

WRITE path with disk driver: WRITE(6) CDB reaches target, sec_wr fires
6x, no watchdog - but `devtest -i` reports "write failed at 0". Close;
one more debug pass on the DATA-OUT / sector-serve-write chain.

## 20260902-050000 — #59 deployed (good READ baseline); #60b = nodriver ROM

BUILD #59: clean (freerun 24b, present-force reverted), timing +0.133,
deployed as `minimig_20260902_A4091_b59.rbf` - the known-good baseline
with the READ path working. Main_MiSTer = the mailbox-fix binary.

To debug Bug A (flaky async geometry) need the driver's own trace, but
the board autoboot ROM provides the resident a4091.device (disk file
ignored). BUILD #60b regenerates `a4091_rom.hex` from
`rom/a4091_nodriver.rom` and force-cleans the Quartus db (smart-recompile
had skipped re-elaboration on a bare hex swap). With no resident driver
we `copy share:a4091/a4091.device DEVS:` and devtest loads the DISK
driver - a full m68k clone of a4091-software @ v42.39-11-ga199fa8 built
on build-host (submodules cloned), with printf's added in
geom_done_inquiry / geom_done_get_capacity (USE_SERIAL_OUTPUT is on in
sd.c, so [DBG] lines hit the Paula console). Will show xs->error and the
raw 8 bytes at &geom->dg_SectorSize right after RC10.

Driver-code read so far: siop_scsidone sets xs->error=XS_BUSY only if
status is CHECK/BUSY (a4091_target returns GOOD). scsipi_done ->
scsipi_complete -> xs_done_callback for a NOERROR async xs, in interrupt
context. Tagged commands: scsipi_put_tag(xs) on completion. Suspect is
the tag lifecycle or the async-in-interrupt-context timing (real target
takes ms; a4091_target ~us). PENDING #60b.

READ path confirmed working on #59: devtest -b 32768,4 -m Fast serves
768 blocks, no watchdog. WRITE still blocked (devtest -i needs geometry).

## 20260902-030000 — *** READ PATH WORKS *** ; WRITE blocked on flaky geometry

*** THE READ-PATH BUG: Main_MiSTer's a4091_sd_poll read the hps_ext 0x64
mailbox status from the WRONG SPI word. `spi_w(0x0064); st = spi_w(0)` -
but hps_ext presents the status on the SAME word that carries the
command (HW-verified: the spi_w sending 0x0064 returns 0x0001 with
rd_pending set; the following words are 0). So Main NEVER saw
rd_pending, never served a block, every READ SIOP-side hung -> WDOG.
FIX: `uint16_t st = spi_w(0x0064);` (matches UIO_DMA_SDIO / ide_check).
main_mister_user_io.patch regenerated, debug removed. ***

HW after fix: `devtest -b -B 32768,4 -m Fast` reads 768 blocks cleanly,
sector-server reads climb, a4091_sd FSM returns to IDLE each time, NO
watchdog. READ(6)/(10) via the a4091 -> a4091_target -> a4091_sd ->
hps_ext -> Main_MiSTer -> .hdf chain is fully working.

Cleanup this session: reverted the diagnostic a4091_present force
(| a4091_ena) in Minimig.sv - present is now O56 & img_present only;
a4091.v dbg_freerun 32b -> 24b (32b carry chain broke timing at -0.31).

STILL BROKEN - Bug A: geometry. `devtest -g` / `devtest -i` flaky
boot-to-boot (TD_GETGEOMETRY 512/32768 ~half the time, 0/1 the rest;
`devtest -i` -> "Failed to get device size" -> can't test WRITE). The
SIOP ALWAYS delivers READ CAPACITY(10) byte-exact (dbc0=8 resid=0
INT=ff00). The driver's geom_done_inquiry issues RC10 as
XS_CTL_ASYNC|XS_CTL_SIMPLE_TAG; devtest's own non-async non-tagged RC10
sometimes reads 512/32768 correct in the SAME run the driver's fails.
=> driver's async+tagged completion flags xs->error (RC16 + mode-sense
fallback). Suspect: a4091_target never DISCONNECTs, so the driver's
async/queued-command bookkeeping races (real target takes ms, this one
us). Building a debug a4091.device (full repo + submodules clone, sd.c
printf added) was blocked - the board autoboot ROM provides the
resident driver, disk a4091.device is ignored. Next: either swap to
a4091_nodriver.rom in the RBF to iterate on the disk driver, or add
artificial completion latency to a4091_target.

WRITE path: untested (needs geometry). Sector-serve WRITE code is in
Main_MiSTer + tb G8/G16 pass in sim.

## 20260902-010000 — reset NOT pulsing; geometry flaky; two distinct bugs

#58 reset watch on HW: `rst_edges` 6 at boot, +2 over ~37s of testing,
`freerun` advances normally. So the a4091 module reset is NOT
oscillating - the dbg_sd2 self-inconsistency in #57 is unexplained but
reset isn't the cause.

3 fresh-boot `devtest -g` trials, all: SIOP delivers RC10 byte-exact
(00 00 7f ff 00 00 02 00, dbc0=8 resid=0 INT=ff00). Yet:
 - trial1: TD_GETGEOMETRY 0/1        (driver geom fails)
 - trial2: TD_GETGEOMETRY 512/1      (partial)
 - trial3: TD_GETGEOMETRY 0/1  BUT devtest's OWN raw READ_CAPACITY_10
           probe = 512/32768 CORRECT

=> the DRIVER's RC10 (geom_done_inquiry, into `&geom->dg_SectorSize`,
XS_CTL_ASYNC|XS_CTL_SIMPLE_TAG) completes with xs->error != 0 (falls to
RC16 + mode sense), while devtest's raw non-async non-tagged RC10 into
its own buffer lands fine. The 8 DMA'd bytes either don't land at
`&geom->dg_SectorSize` or the async/tagged completion is flagged as an
error. Device OPENs, TUR/INQUIRY solid, CHS often computed right anyway.

Bug A: driver's async+tagged RC10 -> geom struct: flaky/errors.
Bug B: READ(6)/(10) sector server: a4091_sd asserts sd_rd (0x3c debug),
holds it, but Main_MiSTer's hps_ext 0x64 poll reads 0 every time (0x68
SIOP-bus poll DOES read live data). #59-equiv: Main_MiSTer mbox debug
now reads 0x64 5x per poll to catch any SPI-offset issue. PENDING.

The user's original complaint ("CDB never reaches target, phase
mismatch aborts") is FIXED (#51 MSG_OUT). CDBs reach the target,
commands execute. Remaining = the two DMA/mailbox issues above.

## 20260901-230000 — dbg_sd2 self-inconsistent -> reset-pulse or oscillation (#58)

#57: `dbg_sd2` read via board window 0x3c shows st=RD_WAIT sd_rd=1;
the SAME `dbg_sd2` mirrored into dbg_bus[15:8] and read via hps_ext 0x68
shows sd_rd=0, st!=RD_WAIT. Same net, same a4091.v combinational scope.
=> either (a) `dbg_sd2` is undriven (X) and Quartus resolves the two
fanouts to different constants, or (b) a4091_sd genuinely oscillates
between states so the two sample points (CPU snapshot vs SPI poll) catch
different states.

Most likely (b) via the SHARED module reset: a4091_target and a4091_sd
both reset on `~cpu_rst | ~cpu_nrst_out`. If the a4091.device error
recovery (READ times out -> siopreset) bounces that, a4091_sd keeps
getting kicked S_IDLE (sd_rd=0), re-catches the re-issued sec_rd, ...
Main's 0x64 poll mostly lands on the S_IDLE/sd_rd=0 phase.

Note: SDRAM_* pins "stuck at GND/VCC" is PRE-EXISTING (b49 too) - this
MiSTer core has no SDRAM daughterboard; chip RAM lives in DDR. So the
earlier "chip-RAM DMA unreachable" concern is moot (a4091 DDR port can
reach it if ramaddr decodes chip addresses - separate check).

#58: a4091.v gets a reset-immune counter block (no `if(reset)`):
`rst_edges` counts module-reset rising edges, `freerun` counts clks.
Board window 0x3d/0x3e/0x3f. Read twice: if rst_edges climbs -> reset
is pulsing -> that's the READ-path bug. PENDING build.

## 20260901-210000 — READ: a4091_sd asserts sd_rd but hps_ext 0x64 reads 0 (#57)

Added mailbox debug to Main_MiSTer (`dbg_mbox.py`: reads hps_ext 0x68
SIOP-bus + logs 0x64 status). Results on HW during a hung `devtest -b`:
 - 0x68 SIOP debug bus reads LIVE, changing data (kicks 6->23, state
   transitions) => the hps_ext SPI path WORKS.
 - 0x64 A4091 sector mailbox: `st=0000` on every poll, hundreds of them,
   for the whole 10s+ that a4091_sd's own CPU-window debug shows
   `st=RD_WAIT sd_rd=1`.

So a4091_sd asserts sd_rd (per its dbg_state at window 0x3c), holds it,
but hps_ext's `{a4091_sd_wr, a4091_sd_rd}` reads 0. Wiring in Minimig.sv
is a single clean net (a4091_sd.sd_rd -> a4091_sd_rd -> hps_ext), no
collision, no build warning. tb G15/G16 (same loop) pass.

Leading theory: `a4091_disk_ena` (O56 / status[56]) glitches a4091_sd
out of RD_WAIT between Main's polls (`if (reset | ~ena) st<=S_IDLE;
sd_rd<=0`), and the CPU snapshot happens to catch it back in RD_WAIT.
#57: expose `ena` + an ena-bounce counter in dbg_state, and mirror
{sd_wr,sd_rd,sd_st} into dbg_bus[15:8] so the known-good 0x68 path
also shows a4091_sd's sd_rd. PENDING build.

STILL: geometry (TD_GETGEOMETRY) works - TotalSectors=32768, CHS
computed right; the SSize column in devtest -g flickers 512<->0 boot to
boot (RC10 delivers byte-exact every time - suspect an async race in
geom_done_get_capacity or the RC10 DMA write landing, low priority
since CHS is right).

## 20260901-190000 — GEOMETRY WORKS. READ path: SELECT STO on non-Z3 buf; sec-server stalls (#56)

*** BUILD #55: `devtest -g` => TD_GETGEOMETRY  SSize=512  TotalSectors=32768
    Cyl=4096 Head=4 Sect=2 - CORRECT for the 16MB image. Stable across
    re-runs. TUR ok. Device opens. ***
(#54 had shown 1/0 once - now believed to be a race from the concurrent
`killall MiSTer` restart during that test, not an RTL issue. #55 is a
clean load_core and is solid. The chip-RAM-DMA theory in the previous
entry did not pan out: RC10 dest = 0x4000b6c8 / 0x40070d08 etc - all
Zorro-III fast, reachable, delivered byte-exact.)

Perpetual re-mount fix confirmed on HW: img_present=1 disk_blocks=32768
after load_core, re-mount cadence ~every poll&0x3fff.

READ path (devtest -b):
 - Plain `devtest -b`: SELECT STO-timeouts, retried 5x, READ never
   issued. devtest's default benchmark buffer is Chip/Z2 -> the driver
   bounces it to a MEMF_CHIP bounce buffer -> the a4091 dedicated DMA
   port (DDR/Z3 only) can't reach it -> and apparently the SELECT itself
   STOs (DSA table read?). Needs `-m Fast`.
 - `devtest -b -m Fast`: SELECT ok, READ(6) opcode 0x08 reaches the
   target, `sector-server: reads=1` (a4091_target asserted sec_rd), but
   then SIOP WDOG. Main_MiSTer logs NO `req #` -> the FPGA hps_ext 0x64
   mailbox never showed rd_pending -> a4091_sd never asserted sd_rd
   despite the sec_rd pulse. T_RDSEC hangs -> WDOG.
 - tb G15/G16 (the same a4091_sd read/write loop) PASS in sim.

#56: expose a4091_sd FSM state + sec_rd-caught / blk_done counters at
0x8D003c (via a4091_sd -> cpu_wrapper -> a4091 dbg window; new dbg_sd2
port threaded through). Will show whether a4091_sd sees the pulse and
where it wedges. PENDING build.

Two open items: (1) a4091_sd not servicing the read; (2) non-Z3 DMA
buffers (chip/Z2) unreachable -> driver bounces to chip which is also
unreachable -> the real fix is either RTL (a4091 DMA reaches all RAM
like real hw) or a MiSTer-port driver change (bounce everything to Z3).

## 20260901-170000 — RC10 datapath perfect; likely chip-RAM DMA gap (#55 confirms)

#54 HW, mount restored (perpetual re-mount fix works, img_present=1
disk_blocks=32768):
  last READ CAPACITY(10) data-in: 00 00 7f ff 00 00 02 00
  -> blocks=32767 blksize=512   (= the mounted 16MB image, exact)
  RC10 SCRIPTS dbc0=8  resid=0  target rsp_len=8  INT=ff00

The SIOP does RC10 100% correctly: 8 bytes, right data, no residual,
clean INT ok. But devtest -g STILL 1/0 and the driver still goes to
RC16 -> the 8 bytes are landing at the WRONG physical address.

HYPOTHESIS: the a4091 DEDICATED DMA PORT (build #48) only talks to
ddram_ctrl (ram2 = DDR = Zorro-III fast). Chip RAM and Zorro-II fast
live in sdram_ctrl (ram1). cpu_wrapper line 169:
  `sel_chipram = !cpu_addr[31:21] && cchip;`  and `cchip` is forced 0
during a4091 DMA (cpustate=2'b1x). So an a4091 DMA to a chip-RAM
address decodes to NOTHING -> ramaddr high bits 0 -> write lands at
DDR ~offset 0. INQUIRY / MODE SENSE / sd_read_capacity use
AllocMem(MEMF_PUBLIC) => Z3 fast => reachable => work. But
geom_done_inquiry puts READ CAPACITY(10) straight into the caller's
`&geom->dg_SectorSize` with NO bounce (is_zorro_ii only catches
0x200000-0x9FFFFF, not chip < 0x200000), and if devtest's geom is in
chip RAM the write is lost.

#55 latches RC10's dnad (dbg_rc10_addr @ 0x8D003a) to confirm it's
< 0x200000. If so the fix is RTL: give the a4091 DMA path access to
sdram_ctrl too (mirror the ddram dma port), so a4091 can reach ALL of
RAM like real hardware. PENDING build #55.

## 20260901-153000 — SIOP DATA-IN is byte-exact; RC10 still errors; mount cap bug found

#53 HW: `last READ CAPACITY(10) data-in: 00 01 ff ff 00 00 02 00`
-> blocks=131071 blksize=512. The SIOP delivered the RC10 payload
BYTE-EXACT. (131071 = the default 131072-1: the a4091_sd mount had
dropped, disk_blocks=0 -> a4091_target used DISK_BLOCKS_DEF.) The
DATA-IN datapath is PROVEN CORRECT.

Yet devtest -g still => TotalSectors=1 SSize=0, and the ring shows RC10
followed by RC16 (0x9e) + MODE SENSE - so the driver's RC10 xfer
completes with xs->error != 0 (0x0001FFFF != 0xffffffff, so RC16 only
fires on an *error* fall-through in geom_done_get_capacity /
sd_read_capacity). Something in RC10's *completion* (residual /
phase-mismatch / status / the async+tagged disconnect the target model
never does) is being rejected. #54 latches, for opcode 0x25: SCRIPTS
ds_Data1 dbc at data-in start (dbc0), dbc left when it ended (resid),
target rsp_len, and the RC10 INT arg.

MOUNT CAP BUG: a4091_sd.log shows `try mount a4091test.hdf -> ret=1
size=16777216` then 250 re-mounts (the rate-limit cap). `load_core`
resets the FPGA but not the MiSTer process, so after a reload with the
cap already hit, the fresh a4091_sd never gets SDINFO -> img_present=0,
disk_blocks=0. FIX: perpetual slow re-mount (every ~30-60s, no cap) -
self-heals on every core reload. patch_ratelimit.py updated, Main_MiSTer
rebuilt (bin/MiSTer staged to mister:/media/fat/MiSTer.new). PENDING #54.

## 20260901-140000 — #52 on HW: stuck-CON not the cause; #53 latches RC10 bytes

#52 deployed. HW: `last S_SELC path = 3 SELECT-ok` (normal path, NOT
path 1 = "CON already set"), SCNTL1=0x20 (bit5, not bit4/CON). So CON is
clean at select time on HW - the stuck-CON SELECT bug is real but not
what the geometry chain hits. Geometry still wrong (mode-sense fallback,
phase-mismatch=8).

HW DATA-IN instrumentation (#52): `total bytes=288 last-run len=12
first byte=0b @4006b598` - the 12-byte run = MODE SENSE (resp[0]=0x0b),
correct first byte, sane Z3 address. So DATA-IN DMA *does* run and
*is* delivering right bytes for the 12-byte case.

Still can't see READ CAPACITY(10)'s specific 8-byte transfer (only the
last run is captured, and -g ends in mode-sense). #53: latch all 8
data-in bytes whenever dbg_last_cdb==0x25 -> dbg_rc10[0..7] @ 0x8D0032,
a4091dbg decodes blocks/blksize. Next HW capture tells us definitively:
SIOP delivered good bytes (=> driver-side bug) or garbage (=> DMA-port
RTL bug for the 8-byte transfer). PENDING build #53.

## 20260901-124500 — #51 deployed: MSG_OUT fix WORKS on HW; SELECT stuck-CON fix (#52)

BUILD #51 (MSG_OUT double-advance fix) on HW:
 - target command ring now populated: [0] cdb=12 dir=1 len=36 (INQUIRY),
   [1] cdb=25 dir=1 len=8 (READ CAP 10), [2] cdb=9e dir=0 (READ CAP 16,
   target has no 0x9e handler), [3] cdb=1a dir=1 len=12 (MODE SENSE).
   => CDBs REACH THE TARGET. SIOP completes clean (INT ok, stop rsn none).
 - MSG_OUT fix confirmed. Tagged path unblocked.
 - Geometry STILL wrong: devtest -g => TotalSectors=1 SSize=0. The driver
   sees READ CAP(10) block count = 0xffffffff (issues READ CAP 16), then
   mode-sense fallback. So the 8-byte DATA-IN is arriving as 0xff/garbage
   even though the target returns dir=1 len=8.
 - #51 timing: -0.168ns setup, one path, 28MHz domain. Placement noise
   (the edit is a net logic reduction). Deployed for the functional test.

CACHE THEORY RULED OUT: core reports `System: 68020 (INST: Cache)` -
instruction cache only, NO data cache. INQUIRY-vs-READCAP difference is
not CPU cache coherency.

SIM REPRO (tb G20): tagged 3-byte MSG OUT + READ CAPACITY(10) + 8-byte
DATA IN. When run right after G19 (which ends with SCNTL1.CON still set,
no WAIT DISCONNECT) the SCRIPTS wedged: SELECT -> S_SELC saw CON set ->
took the "already reconnected, use alt address" branch -> `dsp <= arg`
(insn 0x41, second word 0) -> fetch @0 -> PHASE MISMATCH -> STOP, no
DATA-IN. cap[] left untouched.

FIX #52 (a4091_siop S_SELC): this model never does target reselection,
so drop the alt-address branch. A SELECT always (re)starts the nexus;
if CON is still set from a prior unterminated command, drive it anyway.
STO only when NOT already connected. tb G20 now passes, all 20 groups.

Whether HW hits this exact stuck-CON path is unconfirmed (HW SELECT is
the 0x47 relative form, arg=0x150 - a stuck CON there would do
`dsp += 0x150`, jumping past DATA-IN into the switch/status area, which
matches the observed "command -> straight to STATUS"). #52 also adds
DATA-IN instrumentation (din_total/lastlen/first/addr @ 0x8D002d) to
settle it on the next HW capture. PENDING build #52.

## 20260901-101500 — ROOT CAUSE: MSG_OUT multi-byte address double-advance (#51)

READ/WRITE + geometry chain all wedge the SCRIPTS at `MOVE FROM ds_Cmd`
(`1a00000c` @ 0x1739e = COMMAND phase, 12 bytes) -> watchdog. `devtest -c
INQUIRY` / `-c TUR` work. Only difference: geometry + read/write commands
are issued `XS_CTL_SIMPLE_TAG` (tagged), the devtest -c ones are not.

Tagged => MSG_OUT is 3 bytes (IDENTIFY + SIMPLE_QUEUE_TAG 0x20 + tag id),
untagged => 1 byte (IDENTIFY only).

BUG in a4091_siop.v S_MOB/S_MOC: `S_MOB` fetched from `dnad + mo_i`
while `S_MOC` also did `dnad <= dnad + 1`. Byte N read from offset 2N.
For 1 byte: harmless. For 3 bytes: reads offsets 0,2,4 - bytes 1&2 of
the queue-tag message are garbage. Target sees a broken message, drops
to an unexpected phase, SCRIPTS phase-mismatches / wedges at the CDB
move. Explains: INQUIRY ok, all tagged cmds dead, phase-mismatch count
climbing every probe, `sector-server: reads=0` (CDB never delivered).

FIX: S_MOB walks `dnad` like S_MIB (msg-in) does; `mo_i` is only the
count vs dbc. LUN captured only from byte 0 (was also mis-capturing
from a high tag id). Committed. Build #51 = this + #50 target cmd ring.
Killed #50 mid-fit (its ring is in #51 anyway). PENDING build.

## 20260901-093000 — geometry chain = INQUIRY then READ CAPACITY(10); build #50 trace

Read the driver: `sd_getgeometry` sends INQUIRY -> `geom_done_inquiry`
sends **READ CAPACITY(10)** into `&geom->dg_SectorSize` (8 bytes) ->
`geom_done_get_capacity` swaps the two 32-bit halves and +1's the count.
The HW result `TotalSectors=1 SSize=0` decodes to a **fully-zero 8-byte
READ CAPACITY data-in**. `devtest -c INQUIRY` works (V='MiSTer'
P='A4091 HD'), so the 36-byte data-in path is fine; the 8-byte one into
the geom struct returns zeros. All geometry commands are `XS_CTL_SIMPLE_TAG`
(tagged) - `devtest -c` commands are not.

#50: 4-deep target command ring in a4091.v - `{cdb0, rsp_dir, rsp_len}`
captured at `tgt_rsp_ready`, board window 0x8D0025. Will show whether
`a4091_target` set rsp_dir=1/len=8 for the 0x25 (READ CAP) or returned
no-data. Main_MiSTer poll-flood fix confirmed working (poll count
253k not 732M). tb 19/19. `logs/20260901_b50.txt`. PENDING.

## 20260901-092500 — READ path: found the sector-server flood; Main_MiSTer rate-limit

Tracing the READ(6) hang: the SIOP reaches `command_phase` ->
`MOVE FROM ds_Cmd, WHEN CMD` (`1a00000c` @ 0x1739e) and **watchdogs**
there, every kick. `sector-server reads=1` once - so a READ CDB *did*
reach `a4091_target` T_RDSEC and it asserted `sec_rd` - but T_RDSEC then
waits forever for `sec_qv`/`sec_done` from `a4091_sd` <- `hps_ext` <-
Main_MiSTer, which never serves -> the SIOP's S_CMDW hangs -> WDOG.
(INQUIRY/TUR don't hit this: `a4091_target` answers them from its own
`resp[]` buffer, no sector round-trip.)

**Root cause of the dead sector server + the flaky geometry:**
`a4091_sd.log` poll counter is at **732 million** - `user_io_poll()` runs
tens of thousands of times/sec for minimig, and my `a4091_sd_poll`:
- re-strobed `UIO_SET_SDSTAT` every `polls % 90` == ~700 img_mounted
  pulses/sec, constantly re-latching `a4091_sd` state
- ran a full `spi_w(0x64)` mailbox poll every single call, saturating SPI

Fix (Main_MiSTer `a4091_sd_poll`): `if (polls & 0x3f) return;` throttles
the body to ~1/64 of calls; re-mount capped at 250 total, `polls & 0x3ff`
spacing. Rebuilt + redeployed. Testing. PENDING.

## 20260831-223000 — build #49 HW: INQUIRY+TUR WORK, READ/geometry do not

Fetch stays clean (`stop rsn = none` every run). Command results:

| via | result |
|---|---|
| `devtest -c TUR`     | **Success  Ready** |
| `devtest -c INQUIRY` | **Success  V='MiSTer' P='A4091 HD'** - INQUIRY data-in transfers correctly! |
| `devtest -g` (driver open + geometry) | opens OK, but `TD_GETGEOMETRY` TotalSectors is **flaky: 32768 one run, 1 the next** |
| `devtest -c READ(0)` | "CMD_READ No data" |
| `devtest -c SCSI(0x25..)` raw READ CAP | "Success" (data not checked) |

Trace: `sector-server reads=0 writes=0` - `a4091_target` **never asserts
`sec_rd`**; `target saw CDB opcode` stuck at `1a` (last MODE SENSE) -
**the READ(10) CDB never reaches `a4091_target`'s `cmd_stb`**. So the READ
command's SCRIPT path aborts (one of the growing `phase-mismatch` count,
now 19) before the CDB is sent. INQUIRY/TUR complete because their phase
sequence is simpler.

### Where things stand (session end point)

**FIXED (the multi-month blocker):** SIOP SCRIPTS-fetch DMA corruption -
build #48's dedicated `ddram_ctrl` DMA port. Fetch is byte-perfect, no
wedge, `INT ok`.

**WORKS:** autoconfig, autoboot ROM, register file, INT2, SELECT ID 1,
IDENTIFY, CDB send for short CDBs, TUR, INQUIRY, .hdf mount
(`disk_blocks=32768`), device OPEN.

**REMAINING (each its own focused task, not more DMA-race work):**
1. READ(10)/WRITE(10) CDB path: aborts on a phase mismatch before the CDB
   reaches the target -> sector server never runs -> HDToolBox can't
   read/write the RDB. Likely the SIOP phase engine's handling of the
   longer CMD phase or the DATA_IN entry for a sector transfer.
2. Geometry (READ CAPACITY / MODE SENSE data-in) is flaky - sometimes the
   8-byte transfer lands, sometimes only partial. `phase-mismatch` grows
   with every probe; the `MOVE FROM ds_DataN, WHEN DATA_IN` /
   `CALL switch, WHEN NOT DATA_IN` loop and the driver's phase-mismatch
   recovery (DBC math) need scrutiny - #49 set DBC/DNAD/SBCL on mismatch
   but it did not fully fix it.
3. `dbg_tgtdir` trace field reads 0 even for INQUIRY (which clearly does a
   data-in) - the a4091.v capture of `tgt_rsp_dir` at `tgt_rsp_ready` is
   probably sampling the wrong cycle; low priority.

### deploy state
build #49 RBF, SEED 3, +0.159. Main_MiSTer origin/master 915ca33 + a4091
patch (perpetual mount + sector server). O56+O57 on, IDE boot, uartmode 2.

## 20260831-222000 — build #49: phase-mismatch DBC/DNAD + sector/target trace

Two changes to chase the READ-CAPACITY-partial + dead-sector-server:
1. `a4091_siop` S_BM phase mismatch now sets `DBC = mv_dbc` (full move
   count - nothing transferred on a start mismatch), `DNAD = mv_addr`,
   `SBCL[2:0] = sstat2[2:0]` (new phase). The 53C710 driver's
   phase-mismatch handler reads DBC to compute bytes-transferred; a stale
   DBC there would corrupt the recovered buffer pointer.
2. Debug: 0x8D0023 = sector-server rd/wr pulse counts,
   0x8D0024 = the CDB opcode + rsp_dir the *target* actually saw. Tells
   me if the READ CDB reaches `a4091_target` and if it asserts `sec_rd`.

tb 19/19. SEED 3. `logs/20260831_b49.txt`. PENDING.

## 20260831-221000 — STATUS after build #48: fetch FIXED, device opens, geometry mostly right

### Working
- **SIOP SCRIPTS fetch: clean.** Ring 100% matches `siop_script.lis`,
  `stop rsn = none`, `INT ok`, `insns=599 selects=20` with no wedge.
  Fixed by the dedicated `ddram_ctrl` DMA port (a4091 DMA no longer
  masquerades as a cached CPU access). This was the blocker.
- Zorro III autoconfig, autoboot ROM, 53C710 register file, INT2.
- SCSI SELECT to ID 1, IDENTIFY, CDB send, full SCRIPTS run to `INT ok`.
- HPS .hdf mount -> `img_present`, `disk_blocks=32768`.
- `devtest -g a4091.device 1` **opens the unit** and `TD_GETGEOMETRY`
  returns **TotalSectors=32768** (correct 16 MB), Cyl 4096 / Head 4 /
  Sect 2. (Driver derives this from MODE SENSE(6), which reads back
  correct.)

### Not working yet
- READ CAPACITY(10/16) reads back block-count = 1 (block size 512 is
  right). The 8-byte data-in transfer loses its first 4 bytes. MODE
  SENSE (12 B) is fine, so it is transfer-length / `ds_DataN`-buffer
  specific, not the memory path. `phase-mismatch=10` across the probe -
  the `MOVE FROM ds_DataN, WHEN DATA_IN` / `CALL switch WHEN NOT DATA_IN`
  loop and the driver's phase-mismatch recovery need a close look.
- `devtest -c read(0)` -> "CMD_READ No data", and **0 sector-server
  requests** (`a4091_sd.log`). The a4091_target OP_READ6/10 -> T_RDSEC ->
  `sec_rd` -> a4091_sd -> hps_ext -> Main_MiSTer chain isn't moving data.
  HDToolBox needs this (read RDB / write partitions).

### Config / deploy state
build #48 RBF (`minimig_20260831_A4091_b48.rbf`), SEED 3, +0.298.
Main_MiSTer = origin/master 915ca33 + a4091 patch (perpetual mount
re-strobe + sector server enabled). O56+O57 on. Boot from IDE. uartmode 2.

### Repo
`integration/full/ddram_ctrl.v` is NEW (grafted). Build tree includes it
via `rtl/ram.qip`. `cpu_wrapper.v` + `Minimig.sv` route the dma port.
d8 `D_HOLD` + 3-cycle guard retained (belt-and-suspenders; can be
simplified now the dma port is the real fix).

## 20260831-220000 — build #48: DMA-PORT GRAFT WORKS - fetch race GONE, device OPENS

Timing met (+0.298). The dedicated `ddram_ctrl` dma port fixed it:
- ring is **all-clean** across the whole probe - no `40000000` garbage
  anywhere, `this-run stop reason = 00`, `last INT = ff00 ok`.
- `devtest -g a4091.device 1` **OPENS the device** (no more
  `Fail 46 ERROR_INQUIRY_FAILED`) and returns from `TD_GETGEOMETRY`.
- `insns=479 selects=16` - many commands run without a wedge.

The multi-month SIOP SCRIPTS-fetch corruption is **fixed**. Root cause:
a4091 bus-master DMA masquerading as a CPU `cpuCS` access through
`cpu_cache_new` - fundamentally racy on the address-mux / stale-ready /
cold-refill edges. Fix: give it its own edge-synced DDR port.

Remaining: `TD_GETGEOMETRY` reports garbage (`SSize=0 TotalSectors=1
Cyl=0 Head=2 Sect=1`) and `phase-mismatch=8` - the DATA-IN transfers
(READ CAPACITY / MODE SENSE response bytes, SIOP writing to the driver's
RAM buffer via the dma-port WRITE path) come back wrong. Next: verify the
grafted dma_write BE/slot mapping, and the data-in phase handling.
0 sector-server reads yet (geometry doesn't need them).

## 20260831-210000 — build #47 HW: fetch STILL races; build #48 = ddram DMA-port graft

#47 (cpustate=10): the `@400173a6` fetch after the CDB send is STILL
sometimes `40000000` (RAM: `80880000`), d8-timeout, INQUIRY fails
(`Fail 46 ERROR_INQUIRY_FAILED` from devtest). Some runs clean, some not
- a race none of the d8/cpu_wrapper mitigations (#39-#47) fully close.

**Decision: stop patching the masquerade. Give a4091 DMA its own port.**
Grafted the newer Minimig-AGA `ddram_ctrl`'s dedicated `dma*` port onto
the build tree's controller (`integration/full/ddram_ctrl.v`):
- `dmaCS` 3-FF synced -> `dmaCS_rise`
- own `dmaReadAddr` / `dmaReadBA` slot register (not the shared CPU `ba`)
- direct DDR read in the state machine, `dmaRD <= DDRAM_DOUT[{dmaReadBA,
  4'b0}+:16]`, no `cache_req` / FILL states / cpu_cache_new
- write path with its own addr/data/BE

`cpu_wrapper`: `ramsel` is CPU-only again; a4091 DMA drives
`a4091_dmaCS/WE/Addr(=ramaddr)/WR/U/L`, reads `a4091_dmaRD/ACK`. The
cpu_addr/cpustate mux still switches on a4091 DMA so `ramaddr` (Z3->DDR)
is computed. Chip-RAM a4091 DMA dropped (DDR-only; probe never uses it).
d8 D_HOLD/3-cycle-guard kept as backup. `Minimig.sv` wires it through.
tb 19/19. SEED 3. `logs/20260831_b48.txt`. PENDING.

## 20260831-203000 — build #46 HW: fetch mostly clean, INQUIRY still fails; build #47

#46 (D_HOLD, single sample, SEED 3, +0.100): big improvement. The `end:`
status/msg/int-ok sequence now reads back **byte-for-byte clean** vs the
`.lis`, `this-run stop reason = 00` (no wedge), `last INT = ff00 ok`.
But `a4091d 1` STILL "Open failed": `selects=8 insns=282 phase-mismatch=3`
= the driver runs ~8 INQUIRY attempts and gives up. Ring shows the main
`switch` jumping straight to STATUS after CMD (skipping DATA_IN), so
`a4091_target` returned `rsp_dir=0` for a command whose `dbg_last_cdb`
byte reads correct - some read (CDB length in *(DSA+0xc), or an
intermittent fetch) is still occasionally corrupt. The TB INQUIRY (G5)
passes, so the SIOP/target path is right with clean DMA.

#47: revert DMA reads to `cpustate=10` (data read). On a bare 68020 the
data cache is off, so cpu_cache_new takes the direct-single-DDR-read
(FILLW) branch - no cached line for the CPU's gap-time code to evict, no
cold-refill race. Keeps D_HOLD + 3-cycle guard. If this doesn't close it,
next is grafting the newer ddram_ctrl's dedicated edge-synced `dma*` port
(separate `dmaReadBA` reg, no shared CPU `ba`/FILL states).
`logs/20260831_b47.txt`. PENDING.

## 20260831-200000 — build #45 timing fail, build #46 (D_HOLD, single sample, SEED 3)

#45 (D_HOLD, resample every cycle) missed clk_114 -0.176. #46: sample
`d8_rq` once on D_HOLD exit (same timing-arc count as the old D_WAIT
capture), SEED 3. tb 19/19. PENDING.

## 20260831-195500 — build #44 partial, build #45 (D_HOLD)

#44 (3-cycle ack guard): got to `insns=191`, one command reached `INT ok`,
but the `@400173a6` fetch (right after the CDB send / target-processing
gap) still came back `40000000` where RAM holds `80880000` - byte0
`0x80->0x40`, i.e. the 16-bit word read as `word >> 1`. The garbled value
VARIES between runs (`4088` / `265f` / `4000`) -> it is a race, and it is
not in the first 3 D_WAIT cycles.

Working theory: the SIOP drops `dma_req` the instant it acks, so the
cpu_wrapper mux reverts cpu_addr to the frozen CPU's address while
ddram_ctrl's fill FSM is still delivering the line -> the last word comes
out bit-skewed. #45: new D_HOLD state - after the ack, hold `dma_req`
(=> cpu_addr / ramsel stable) 4 more cycles, resample `dma_rdata` each
cycle, keep the settled value. tb 19/19. SEED 2. PENDING.

## 20260831-194500 — fresh boot: INQUIRY d8-timeouts; build #44 (3-cycle ack guard)

Clean fresh-boot single `a4091d 1` -> "Open failed" every time. `dbg`
(stop reason now cleared per kick): `last CDB = 12` (INQUIRY),
`this-run stop reason = 02 d8-TIMEOUT`, `phase-mismatch=0`, ring [11]
`@400173a6 265f0000` where RAM holds `80880000` - **the fetch right after
the CDB send is still corrupt** (byte0/1 wrong), SIOP runs garbage,
d8-timeout. The build-#42 run got further only because the driver retried
~14x and some retries happened to fetch clean.

The prime-read (#42) helps probabilistically but doesn't close it. Root
cause pinned: when `a4091_dma_req` rises, the cpu_wrapper address mux is
still leaving the frozen CPU's address; `zram_sel` briefly points at SDRAM
and a stale `ram_ready1` acks the SIOP with SDRAM data on the very first
D_WAIT cycle.

#44: d8 engine ignores `dma_ack` until it has held `dma_req` for >=3
cycles - the DMA address has propagated by then and `ram_ready` reflects
the real Z3 access. Reverted D_REPRIME/d8_prime. SEED 2. tb 19/19.
`logs/20260831_b44.txt`. PENDING.

## 20260831-193000 — driver open path traced; sector server enabled

Cloned `A4091/a4091-software` and traced `drv_open`:
`open_unit -> CMD_ATTACH -> attach() -> scsi_probe_device()`.
`scsi_probe_device` for PORT_AMIGA does **INQUIRY only** - no TUR, no
READ CAPACITY, no RDB read. `MEDIA_LOADED` / `T_DIRECT` are set the moment
INQUIRY returns with LU present. So the open succeeds on a good INQUIRY.

Observed on HW: the **first** `a4091d 1` after a boot opens fine (dumps a
full Periph: target 1, LUN 0, T_DIRECT, MEDIA_LOADED, 512 B). **Later**
`a4091d 1` runs print "Open ... failed". a4091d does CloseDevice on exit
-> `close_unit` -> when refcount hits 0, `CMD_DETACH -> detach()` which
issues a SCSI reset; that likely leaves the SIOP/target such that the
next probe's INQUIRY fails (`scmds=14` = retries).

`periph_version=0` in the dump (should be 2 for the SCSI-2 target) - the
INQUIRY data-in transfer drops byte 2, but the driver tolerates it.

For the user's goal (HDToolBox) a single held-open unit is enough. Next:
confirm one clean open + `devtest -g` geometry, then point HDToolBox at
`a4091.device` unit 1. The re-open-after-close path can be hardened later
(the detach reset).

Sector server (Main_MiSTer `a4091_sd_poll`) now enabled - serves 512 B
blocks from the mounted .hdf via hps_ext 0x64/0x65/0x66/0x67. Not yet
exercised (driver open doesn't read sectors).

## 20260831-190000 — ROOT CAUSE of the open-fail: sector server was OFF + build #43

The `Main_MiSTer` a4091 patch is a **MOUNT-ONLY** build - `a4091_sd_poll()`
has `return; // ISOLATION` right before the hps_ext sector-mailbox code.
So the .hdf mounts (img_present) but the core's actual sector reads
(0x64 poll / 0x65 data / 0x67 done) are never serviced -> the driver's
READ of RDB block 0 hangs -> unit open never completes. `a4091test.hdf`
IS a valid RDB hardfile (`RDSK` @ blk 0, `PART` @ blk 1).

Re-enabled the sector server in `a4091_sd_poll()` (the full impl was
sitting disabled in a git stash `a4091-a2065-wip-preserve`): serve one
512 B block per poll - `spi_w(0x64)` poll -> if rd/wr pending, FileSeek +
FileReadAdv/FileWriteAdv on the mounted .hdf, `spi_w(0x65/0x66)` for the
data, `spi_w(0x67)` block-done. Kept the perpetual mount re-strobe.

Build #43 (RTL): clear `dbg_stop_reason` per kick; expose last INT arg
(0x8D0021) + {stop reason, last CDB} (0x8D0022). Setup -0.070 on the
**stock HDMI pixel clock** (not a4091) - deployed as-is for the bench
test; SEED-2 rebuild (#43b) pending for a clean RBF.

Deployed: #43 RBF + sector-serving MiSTer. Testing. PENDING.

## 20260831-183000 — build #42 mount fixed (perpetual re-strobe), build #43 (INT/CDB trace)

Perpetual re-strobe (Main_MiSTer patch: `if (f->size && polls % 90 == 0)`,
no cap) -> `img_mounted pulses=255`, `img_present=1`, `disk_blocks=32768`
(= a4091test.hdf, 16 MB). The earlier `polls <= 6000` cap expired before
AmigaOS finished booting / `cpu_nrst_out` settled, so every re-strobe
landed while `a4091_sd` was still in reset.

But `a4091d 1` STILL fails the same way. Cross-checked the ring against
`siop_script.lis`: **the fetches are all correct now**. The wedge point
(`98080000 / 0000ff00`) is `INT ok` at script `end:` - the SIOP ran the
full command-completion sequence (MOVE ds_Status -> int err10 WHEN NOT
MSG_IN -> MOVE ds_Msg -> CLEAR ACK -> WAIT DISCONNECT -> INT ok). The
command COMPLETED. `stop rsn = WDOG` is **stale/sticky** from an earlier
kick (dbg_stop_reason only cleared on chip reset).

So: 14 SCSI commands run clean, device reports MEDIA_LOADED / 512 B /
ID 1 LUN 0, script hits INT ok - yet the driver's OpenDevice never
returns. Something in the driver<->SIOP completion handshake, or a
command result the driver rejects.

#43: clear `dbg_stop_reason` per kick; expose last INT arg (0x8D0021) and
{stop reason, last CDB opcode} (0x8D0022). tb 19/19.
`logs/20260831_b43.txt`. PENDING.

## 20260831-182000 — build #42: PRIME READ WORKS - fetch clean, device sees MEDIA_LOADED

Timing met (+0.346). The throwaway prime read fixed the post-gap fetch
corruption: **no more `40880000` / `4280` garbage**. The SIOP now runs the
whole script - `insns=282` (was 191/14), `selects=8`, ring entries are all
real instructions (the switch table, block moves, `98080000` INT).

`a4091d 1` now dumps a full device/unit/Periph diagnostic:
- `periph_target=1  periph_lun=0`         <- SCSI ID 1 LUN 0
- `periph_type=0  T_DIRECT`
- `periph_flags=2  MEDIA_LOADED`          <- !!
- `periph_blkshift=9 (512 bytes)`
- `sc_tinfo[1] scmds=14`                  <- 14 SCSI commands to target 1
- `free_list ... MODE_SENSE_6(06)`
- `sc_intcode=ff00`  == INT arg `0000ff00`

Still: `Open a4091.device failed`, `stop rsn = WDOG` at the `98080000` INT
insn, `phase-mismatch=3`. The device probe (TUR/INQUIRY/MODE SENSE) is
running for real against `a4091_target`; something in the phase handshake
or the INT handling wedges. `disk_blocks=0` (mount still not plumbed) so
`a4091_target` is answering from its default geometry.

Next: decode the INT 0xff00 in siop_script, and the 3 phase mismatches -
the SIOP phase engine vs `a4091_target` response lengths.

## 20260831-180000 — builds #39-#41 dead-end, build #42 (prime read)

The cpu_wrapper-side attempts to fix the post-gap first-beat corruption
all failed:
- #39 arm-delay: setup -1.229 (combinational NOR into clk_114 ram_cs).
- #40 registered `a4091_dma_go` + `dma_ack` gate: -1.674, TNS -11.8 -
  the reg was outside the `a4091_inst|*` SDC multicycle pattern.
- #41 = #40 + `a4091_dma_*` SDC multicycle: timing met (+0.384) but the
  HW fetch got WORSE - `4280` garbage on nearly every fetch, `selects=1`,
  `insns=11`. The registered `go` + gated `dma_ack` broke the basic
  d8<->RAM capture alignment.

Reverted cpu_wrapper to the plain build-#34 per-fetch tail (`ramcinhibit`
tied 0). New approach, SIOP-side (a4091_siop.v d8 engine, under the
`a4091_inst|*` multicycle): after >=6 idle cycles the first read of the
next transaction is a **throwaway prime** - issue it, drop `dma_req`,
D_REPRIME re-asserts for a tight back-to-back real read whose value is
kept. The post-gap read comes back bit-shifted; the immediate second read
is clean. Reads only. tb 19/19. `logs/20260831_b42.txt`. PENDING.

## 20260831-171500 — build #40 timing FAIL, build #41 (SDC multicycle)

#40 (registered `a4091_dma_go` + `dma_ack` gate): still setup **-1.674**,
TNS -11.8 - a whole cone failing. Cause: the SIOP's `a4091_dma_req` is
under `emu|cpu_wrapper|a4091_inst|*`, which `Minimig.sdc` multicycles to
`emu|ram*` (2/1). The new `a4091_dma_go` is a cpu_wrapper-level reg
(`emu|cpu_wrapper|a4091_dma_go`) - NOT matched by that pattern - so its
path to `ram_cs` was checked at the full clk_114 rate and failed. Same
DMA-holds-address-stable contract as the CPU, so the same multicycle
applies. Added to `Minimig.sdc` / `integration/Minimig.sdc.patch`:
`set_multicycle_path -from {emu|cpu_wrapper|a4091_dma_*} -to {emu|ram*}
-setup 2 / -hold 1`. #41 = #40 RTL + this SDC line.
`logs/20260831_b41.txt`. PENDING.

## 20260831-165500 — build #40 (registered dma_go + dma_ack gate)

#39 arm delay missed timing -1.229 (combinational NOR into clk_114
`ram_cs`). #40 fixes:
1. `a4091_dma_go` -> plain register off a 1-bit `a4091_dma_armed` flag.
   `ramsel` / cpu_addr-cpustate mux / `sel_chipram` key on it. +1 clk/beat.
2. `.dma_ack` now `(a4091_dma_go & ramready)` not `(a4091_dma_req &
   ramready)` - a stale `ram_ready1` pulse from the CPU's just-drained
   SDRAM access during the arm window can no longer ack the SIOP with the
   wrong data source (the 1-bit-shift corrupt first word).
tb 19/19. `logs/20260831_b40.txt`. PENDING.

Build #39 (arm delay) missed timing hard: **setup -1.229** on clk_114 -
the combinational `~|a4091_dma_arm` NOR feeding `ramsel` -> `ram_cs` blew
the razor-thin domain. #40: `a4091_dma_go` is now a plain register off a
1-bit `a4091_dma_armed` flag; `ramsel` / the cpu_addr-cpustate mux /
`sel_chipram` key on the registered signal. Costs the DMA one extra clk
per beat (d8 waits). tb 19/19. `logs/20260831_b40.txt`. PENDING.
## 20260831-161500 — build #38 HW: no change, build #39 (arm delay)

### #38 (tail + cache_inhibit) - still corrupt

Same as #36: `insns=191 selects=6`, `stop rsn = d8-TIMEOUT`. Ring [14]
`@400173a6 40880000` where RAM holds `80880000` - byte0 `0x80->0x40`
again. `*(DSA+1)` also read `88` (should be 00/02). cache_inhibit did NOT
help: the corrupt fetch is the first one after the CDB block move, i.e.
after a CPU-active phase-wait gap. The corruption is in the DMA read
*handshake* after an idle period, not the cache line fill.

### #39 - arm delay

`a4091_dma_arm`: on a DMA session start (or resume after a gap longer than
the 8-clk tail), `a4091_dma_active` freezes the CPU right away but the
beat is held off the RAM port (`a4091_dma_go = 0`) for ~12 clk so the
CPU's in-flight `cpu_cache_new`/DDR fill drains before the SIOP's first
beat engages. Only the first beat waits. `ramsel` / the cpu_addr-cpustate
mux / `sel_chipram` now key on `a4091_dma_go`. tb 19/19.
`logs/20260831_b39.txt`. PENDING.

## 20260831-155500 — STATUS ROLLUP (builds #29-#38)

### Fixed / confirmed working
- **SIOP SCRIPTS fetch corruption** (the blocker since build #29). Root
  cause: `cpu_wrapper` presents each a4091 DMA byte beat to the Minimig RAM
  port as a CPU cycle; `a4091_dma_req` pulses once per byte, so between the
  SIOP's back-to-back reads the mux reverted to the frozen CPU's pending
  access and a stray `cpu_cache_new` line fill collided with the next beat,
  scrambling the later 16-bit words of a straddled fetch (the script array
  sits at 0x400171ce = offset 6 mod 8, so every 8-byte insn straddles two
  DDR 64-bit words). Fix in #34: `a4091_dma_tail` holds "CPU off the RAM
  bus" ~8 clk past each beat -> a whole multi-byte fetch is one session.
  Verified: tight fetches (SELECT x8, the switch table) read back
  byte-for-byte correct vs `peek`.
- **cpustate for DMA reads** (#30): tag them as instruction fetch (00) not
  data read (10) - the data-read miss path in `cpu_cache_new` misbehaves
  on a bare 68020 (no D-cache).
- **SCSI SELECT** (#36, with the diagnostic force-present): `selects` goes
  0 -> 6, `insns` 14 -> 191. The SIOP walks SELECT -> MSG-OUT handler ->
  CMD block move (12-byte CDB) -> ... real script execution.
- **O[56]** does reach `status[56]` - but only after a real `load_core`
  via `/dev/MiSTer_cmd`. `killall MiSTer` + restart reloads the *old* FPGA
  image. This wasted build #36's first HW test.

### Still open
1. **Fetch corruption across inter-instruction gaps** (#36): a fetch that
   follows a CPU-active gap (SIOP waiting on the a4091_target response)
   still gets a corrupt byte 0 (`0x40` vs RAM's `0x80`) and d8-times-out.
   The per-fetch tail doesn't span those gaps. #37 (freeze CPU whole run)
   hangs the box on watchdog. #38 (tail + `cache_inhibit`) is the current
   attempt - PENDING.
2. **HPS disk mount never reaches the core**: `a4091_sd` sees
   `img_mounted pulses = 0`, so `img_present`/`disk_blocks` stay 0 and
   real READ/WRITE can't work. Main_MiSTer re-strobes `UIO_SET_SDSTAT`
   (0x1c) 20+ times post-boot with no effect. Worked around by the
   **diagnostic force-present** (`a4091_present` asserts ID 1 whenever the
   board is enabled) - must be reverted once the mount path is fixed.
3. `phase-mismatch = 2` during the #36 run - SIOP phase engine vs script
   expectations; revisit after (1).

### HW state
Deployed: build #36 (`minimig_20260831_A4091_b36.rbf`). Config O56+O57 on
(ext_cfg2 0x0300). Main_MiSTer = origin/master 915ca33 + a4091 mount patch
(re-strobe loop). uartmode.Minimig = 2. AmigaOS boots from IDE.

## 20260831-154500 — build #37 HANG, build #38 (tail + cache_inhibit)

### #37: whole-run CPU freeze deadlocks the box

Holding `a4091_dma_active` while `st != S_IDLE` froze the CPU for the
entire SIOP run. When the SIOP watchdogs / d8-times-out and does NOT
cleanly return to S_IDLE, the CPU never unfreezes -> whole Amiga hangs
(serial console dead, `echo` no reply). Reverted; HW rolled back to #36.

### #38: per-fetch tail (build #34) + cache_inhibit (build #31)

Not per-run freeze - too dangerous. Instead: keep the ~8-clk per-beat
tail, and re-add `ramcinhibit = a4091_dma_active` -> `sdram_ctrl` +
`ddram_ctrl` `.cache_inhibit`. Each SIOP fetch byte -> direct single DDR
slot read (cpu_cache_new FILL1 return), no 8-byte line fill to collide
with an in-flight CPU fill or to serve stale after a CPU-active gap
between SCRIPTS instructions. #31 tried cache_inhibit alone (no tail) and
still saw corruption, but that was confounded by the inter-beat bleed the
tail now fixes. Diagnostic force-present kept. tb 19/19.
`logs/20260831_b38.txt`. PENDING.

## 20260831-151500 — build #36 HW: SELECT WORKS, build #37 (whole-run hold)

### #36 (clean load_core - killall+restart does NOT reflash the FPGA!)

O[56] finally read as 1 (`disk_ena=1`). With the diagnostic force-present
(`| a4091_ena`), `present bitmask = 02` and **SELECT succeeds**:
`selects=6`, `insns=191` (was 14), the SIOP walks SELECT -> switch ->
msgout handler -> switch -> CMD block move (12-byte CDB) -> ... Real
script execution.

But: `stop rsn = 02 d8-TIMEOUT`, and ring entry [14] `@400173a6
40000000` where RAM actually holds `80880000` - **byte 0 corrupted
(0x80->0x40), the fetch bug again**, on an instruction fetched right after
the CDB block move (long CPU-active gap while a4091_target processes the
command). The per-fetch tail does not cover gaps between SCRIPTS
instructions.

`img_mounted pulses=0` still - the HPS mount never reaches the core's
`a4091_sd` (separate issue, worked around by the force-present for now).

### #37

`a4091_dma_active` now also holds while the SIOP is non-idle
(`a4091_dbg_bus[5:0] != 0`) - CPU is off the RAM bus for the entire
kick-to-idle window, so it can't thrash the script's cache lines during a
phase wait. SIOP never waits on the CPU -> no deadlock. Diagnostic
force-present kept. `logs/20260831_b37.txt`. PENDING.

### NOTE for redeploy: after copying a new RBF, `load_core` via
`/dev/MiSTer_cmd` IS required - `killall MiSTer` + restart alone reloads
the old FPGA image. (Cost me build #36's first test.)

## 20260831-144500 — build #35 HW result + build #36 (mount plumbing)

### #35 SELECT trace on HW: present=0, every SELECT STO-times-out

```
SELECT trace:
  present bitmask = 00
  disk_blocks     = 0
  *(DSA+1) id byte= 02      <- SIOP reads target ID correctly
  last S_SELC path= 2 STO-timeout
  phase set after select = 0
```

`disk_blocks` is passed straight through from `a4091_sd`, so `a4091_sd`
never latched `img_mounted`. Tried re-strobing `UIO_SET_SDSTAT` (0x1c =
the img_mounted notify) from `a4091_sd_poll()` every ~2 s for 2 min after
MiSTer start (patched Main_MiSTer, rebuilt, redeployed) - **no change**,
present stayed 0.

Root cause: `a4091_sd.v` gated `img_present`/`disk_blocks` latching on
`~ena` (O[56]) - `if (reset | ~ena) img_present<=0`. Whether O[56] is
actually reaching `status[56]` is still unconfirmed.

### build #36 changes

1. `a4091_sd.v`: latch `img_present`/`disk_blocks` on `img_mounted`
   regardless of `ena`. `present` in Minimig.sv is still `(a4091_disk_ena
   & a4091_img_present)`-gated, so O[56]=off is still a safe fallback.
2. New `dbg_mnt_cnt` (img_mounted pulse counter) + `img_present` +
   `disk_ena(O56)` at board window 0x8D0020, printed by a4091dbg.
3. **DIAGNOSTIC**: `a4091_present` also asserts ID 1 whenever the board is
   enabled (O[57], confirmed working) - isolates the SELECT/INQUIRY path
   from the mount plumbing. To be reverted.

Main_MiSTer patch kept (re-mount every ~2 s, poll<=6000). tb 19/19.
`logs/20260831_b36.txt`. PENDING.

## 20260831-140000 — SELECT stall analysis + build #35 (SELECT trace)

`ncr7xx -r` on HW (build #34): SCNTL1=0x20 (bit5, not CON), SSTAT0=0x00,
DSA=0. `a4091dbg`: `selects=0`, `stop rsn = WDOG`. So SELECT is NOT
taking the success branch (dbg_sel_cnt stays 0) and NOT latching STO
(driver reads/clears SSTAT0 in its ISR). WDOG = the SIOP spins in the
`switch:` phase-dispatch because the phase after SELECT never matches a
case.

Two candidates:
  1. `present[1]` is really 0 -> S_SELC STO branch every time (SSTAT0
     cleared before we look), driver retries ~8x, gives up. `present` =
     `(status[56] & a4091_img_present) ? 7'b10 : 0`. The HDF *is* mounted
     (a4091_sd.log: ret=1 size=16777216) and O[56]/O[57] set in
     Minimig.cfg (0x03000000), but `a4091_sd` only latches `img_present`
     on the `img_mounted` pulse - which may land during the core's reset
     window after a `load_core` and be lost.
  2. The `scntl1[4]` CON-alt branch is taken (skips set_phase) - unlikely,
     SCNTL1=0x20.

Build #35 adds a SELECT decision trace to the board debug window
(0x8D001b..1f): present bitmask, `*(DSA+1)` id byte, SCNTL1, last S_SELC
path, phase-after-select, disk_blocks. `a4091dbg` prints them. tb: 19/19
pass. `logs/20260831_b35.txt`. PENDING.

## 20260831-134000 — build #34: DMA FETCH FIXED (hold-stretch works)

Timing met (setup +0.258). HW ring after `a4091d 1`:

```
[ 0..7] @400171ce  47000000  arg=00000150   SELECT - all correct
[ 9]    @400171d6  878b0000  arg=00000030   grp2  <- was 588f0000
[10]    @400171de  868a0000  arg=000001a0   grp2  <- was 00000000
[11]    @400171e6  828a0000  arg=000001a8   grp2   (matches peek)
[12]    @400171ee  808a0000  arg=000001b8   grp2
[13]    @400173ae  1800003c  arg=0000003c
```

Every fetched word now matches RAM. **The a4091 DMA data-integrity bug is
fixed** by `a4091_dma_tail` (hold the CPU off the RAM bus for the whole
multi-byte SIOP fetch instead of per-beat). One transient `7cfc0000` at a
kick boundary (entry 8) but arg still correct - cosmetic.

Root cause confirmed: per-beat `a4091_dma_req` let the cpu_wrapper mux
flap back to the frozen CPU between the SIOP's back-to-back byte reads;
a stray RAM-controller fill then collided with the next beat and
scrambled the later 16-bit slots. Not a cache bug, not a DDR bug - a
bus-arbitration/mux bug in the integration.

### still failing: SELECT does not complete

`a4091d 1` still -> "Open a4091.device failed", `stop rsn = WDOG`,
`selects=0`, 9 kicks, `insns=14`. The SIOP now walks the real script
(SELECT -> the `switch:` grp2 phase-dispatch JUMPs -> 0x173ae) but the
SCSI SELECT to ID 1 never completes and it watchdogs. Next: check whether
target ID 1 is actually presented (`a4091_present` / `a4091_sd` disk
enable O[56]), and trace the script path from 0x173ae.

## 20260831-130000 — builds #32/#33 timing, build #34

- #32 (stretch + cache_inhibit, SEED 3): setup -0.002 (2 ps) on clk_114.
- #33 (same, SEED 5): -0.046 - SEED reroll made it worse.
- Decision: **drop cache_inhibit** (build #31 already proved it changes
  nothing on HW) to shed the clk_114 fanout it added; keep only the
  `a4091_dma_tail` hold-stretch. Repo `integration/Minimig.qsf` SEED
  synced (was stale at 1). Build #34 = stretch-only, SEED 3.
  `logs/20260831_b34.txt`. PENDING.

## 20260831-123000 — build #31 HW (cache_inhibit) FAILED, build #32 (DMA hold stretch)

### build #31 — cache_inhibit — no change

Timing met (setup +0.331). HW ring identical pattern: `400171ce` insn OK,
arg flaky; `400171d6` = `58820000` (real `878b0000`); `400171de` garbage.
So the corruption is **below** `cpu_cache_new` - bypassing the line fill
did not help.

### key observation

Across #29/#30/#31: `400171ce` is fetched 9+ times (one per kick) and
converges to mostly-correct; `400171d6` / `400171de` are fetched rarely
and are **always** wrong. The wrong bytes are the later 16-bit slots
(slot 2/3) of a fetch that straddles two DDR 64-bit words. `peek` (CPU
read, one addr at a time) reads every one of those bytes correctly.
=> the differentiator is **back-to-back access**: the SIOP `d8` engine
fires 8 byte reads ~2-4 clk apart; a lone CPU read is fine.

### build #32 — stretch the DMA hold

`a4091_dma_req` is one pulse per byte beat. In the gap between beats the
`cpu_wrapper` mux reverts `cpu_addr`/`cpustate` to the frozen CPU's
pending RAM access, so a stray controller fill can start and collide with
the next beat. New `a4091_dma_tail` (4-bit) holds the "CPU off the RAM
bus" state ~8 clk past each beat -> the whole multi-byte fetch is one
uninterrupted DMA session. `ramsel` + the cpu_addr/cpustate mux now key
on `a4091_dma_req` (real beat only); `clkena`/`chipreq`/`sel_a4091` keep
the stretched hold. cache_inhibit + cpustate=00 retained. SEED 3.
Build `logs/20260831_b32.txt`. PENDING result + HW retest.

## 20260831-121500 — build #30 HW result + build #31 (cache_inhibit)

### build #30 (DMA read = instruction fetch) — PARTIAL, still fails

Timing met (setup +0.084), RBF `minimig_20260831_A4091_b30.rbf` deployed.
`a4091d 1` -> still "Open a4091.device failed", `stop rsn = WDOG`,
9-13 kicks, `selects=0`.

Instruction ring (deterministic across runs, `peek 400171ce` confirms RAM
is 100% correct - `47 00 00 00 00 00 01 50 87 8b 00 00 00 00 00 30 86 8a
00 00 00 00 01 a0 ...`):

| DSP | fetched insn / arg | real | verdict |
|---|---|---|---|
| `400171ce` | `47000000` / `00000150` | `47000000 00000150` | insn always OK; arg OK on "warm" fetches, `00000000` on the first-after-kick, `7cfc7cfc` periodically |
| `400171d6` | `588f0000` / `00000000` | `878b0000 00000030` | always wrong |
| `400171de` | `00000000` / `00004000` | `868a0000 000001a0` | always wrong |

cpustate=00 helped (the `47000000/00000150` fetch now reads back right
most of the time, vs never in #29) but did not fix it.

### diagnosis refined

SCRIPTS array base is `0x400171ce` = **offset 6 mod 8**, so every 8-byte
instruction fetch straddles two DDR 64-bit words. The SIOP `d8` engine
reads the fetch one byte at a time; each byte misses `cpu_cache_new` and
pulls a full 8-byte line fill. Mapping the wrong bytes to DDR 16-bit
slots: **slot 0/1 of a line come back correct, slot 2/3 come back 0 /
stale** - i.e. the 3rd/4th beat of `cpu_cache_new`'s FILL2/3/4 sequence
delivers bad data. Byte-level RTL trace of `ddram_ctrl` + `cpu_cache_new`
*looks* correct on paper (traced 5x), so the fault is in the multi-beat
fill interaction (or real DDR3 `DDRAM_DOUT_READY` behaviour the source
read doesn't show), not something obvious.

### build #31 — cache_inhibit for a4091 DMA

Don't fight the fill: skip it. New `cpu_wrapper` output `ramcinhibit =
a4091_dma_active`, wired to the **existing** `cache_inhibit` port on both
`sdram_ctrl ram1` and `ddram_ctrl ram2` (was unconnected). With
`cache_inhibit` set, `cpu_cache_new` returns the single direct FILL1 read
of the requested 16-bit slot and skips FILL2/3/4 + line population. No
endian effect (that is `ramshared` only). Reads never create resident
lines, and the CPU's script stores are write-through, so it stays
coherent.

Files: `integration/full/cpu_wrapper.v`, `integration/full/Minimig.sv`.
Kept cpustate=00 and SEED 3. Build started ~20260831-121x on `quartus-host`,
log `logs/20260831_b31.txt`. PENDING result + HW retest.

## 20260831-111000 — build #30: DMA reads tagged as instruction fetch

Fix for the corrupt SCRIPTS fetch. `cpu_wrapper.v` presents each a4091
bus-master DMA beat to the Minimig RAM port as a CPU cycle; it was
tagging reads `cpustate==2` (data read). Both `ddram_ctrl` and
`sdram_ctrl` route `cpustate==2` through `cpu_cache_new`'s **data** path.
On a bare 68020 the data cache is disabled (`cc_den=0`), and that
miss/fill branch returned only the first fetched longword intact - the
ring dump showed insn OK, every following word 0 / `7cfc7cfc`.

Change (1 line): `cpustate = a4091_dma_rw ? 2'b00 : 2'b11;` - reads now
look like instruction fetches, which always take the full multi-beat
`cpu_cache_new` line fill (the path every opcode fetch from fast RAM
already exercises). Writes unchanged.

Kept SEED 3 (build #29 timing baseline). Build started 20260831-110457
on Quartus quartus-host, `/tmp/mm-a4091`, log `logs/20260831_b30.txt`.

PENDING: build result + HW retest (probe `a4091d 1` + ring dump; expect
the ring to show the real `switch:` / `msgout` insns and `arg=00000150`).

## 20260831-114500 — ROOT CAUSE: a4091 DMA reads go through the CPU cache

Traced the corrupt-fetch path through the integration RTL.

`cpu_wrapper.v` handles an a4091 DMA beat by **masquerading as the CPU**:
`a4091_dma_active` drives `ramsel`, and lines 200-206 force
`cpu_addr = {a4091_dma_addr,1'b0}`, `cpustate = dma_rw ? 2'b10 : 2'b11`
(2 = CPU data read, 3 = CPU write). That request lands on
`ddram_ctrl` (Z3 fast RAM @ 0x40000000 -> DDR) via `cpuCS = zram_sel & ram_cs`.

Inside `ddram_ctrl` every `cpuCS` access with `cpustate==2` is a
**cached CPU data read** - it goes through `cpu_cache_new`
(`.cpu_dr(cpustate==2)`, `ramready = cache_hit || write_ena`). So the
SIOP's SCRIPTS/table fetches are served from the 68020 line cache, and
the `d8` engine (which re-asserts `dma_req` every ~4 clk, far faster than
a CPU access cadence) races the cache fill FSM:
 - byte in an already-cached line  -> correct
 - first byte of an un-cached line -> MISS, fill in flight, but a stale
   `cache_hit`/`ramready` from the previous access lets `d8` ack early
   -> reads 0 / stale / `7cfc7cfc`.
That is exactly the ring signature: bytes 0-1 (line 0x1c0, cached) OK,
bytes 2-7 (line 0x1d0, cold) = 0; longer probe runs -> whole-fetch garbage.

`ddram_ctrl` **already has a dedicated, cache-coherent DMA port**
(`dmaAddr/dmaCS/dmaWE/dmaL/dmaU/dmaWR/dmaRD/dmaACK`): edge-synced
(`dmaCS_sync`, `dmaCS_rise`), reads bypass the cache (direct DDR burst),
writes bypass the cache **and snoop-update it** so the CPU stays
coherent. In the current `Minimig.sv` that port is left **unconnected**.

Decision: wire the a4091 `d8` DMA engine to `ddram_ctrl`'s `dma*` port
instead of the `cpuCS`/`cpustate` masquerade. NOT via `ramshared` - that
signal also byte-swaps write data / read data (file-share endian) and
would corrupt SCRIPTS. Chip-RAM DMA (`sdram_ctrl`, no dma port) is a
separate later concern; the driver's SCSI buffers + SCRIPTS are all in
Z3 fast RAM so the DDR port covers the probe path.

Rejects the "68020 D-cache snoop" HW-gap theory from build #29: the
driver's `CacheClearE` is fine, the leak is the FPGA `cpu_cache_new`
being (mis)used for DMA.

## 20260831 - refined: 4th consecutive DMA word reads as 0

Re-reading the ring: the "clean" SELECT fetches (entries 0-7) are NOT
random garbage - they are consistently `insn=47000000 arg=00000000`.
Byte-level: the 8-byte fetch reads four 16-bit words (@ ..ce, ..d0, ..d2,
..d4). Words 1-3 come back correct (`47 00`, `00 00`, `00 00`); **word 4
(@ 0x400171d4, should be `01 50`) comes back `00 00`** - every time.
The single-byte DSA-table read in S_SELA works fine (select_id tracks the
real ID). So: **the 4th back-to-back `d8` DMA read returns 0**; longer
runs (the a4091d probe) degrade further to whole-fetch garbage.

`ncr7xx -t -f`: Device access PASS, Register test PASS, **DMA FIFO test
FAIL** ("DSTAT DFE not 1", CTEST1 f0 != e0) - but that's a separate known
stub (`rreg 0x15` hardcodes CTEST1=0xf0, the chip DMA FIFO isn't modelled).

**Working theory now leans HW over cache:** a sustained/back-to-back
`a4091_dma_req` read burst through `cpu_wrapper` -> Minimig RAM loses data
after ~3 beats. Look at: the `d8` engine's `dma_rdata` capture timing vs
`dma_ack`; `a4091_dma_active` toggling `clkena_in` between every byte
(CPU unfreezes for 1 cycle mid-burst - SDRAM refresh / arbitration
collision?); whether the Minimig fastram/SDRAM controller can service
consecutive single-beat DMA reads without a gap.

## 20260831 - instruction ring on HW: the fetch is corrupt (build #29)

**build #29 (SEED 1 -> 3): timing MET (+0.072).** Confirms #27/#28's
-70ps was fitter noise on the HDMI clock, not the ring.

**Serial gotcha:** a stale `amiga_term.py` from a prior session was holding
`/dev/ttyS1` all along - that's why "serial dead" kept recurring. Kill it
(`pkill -9 -f amiga_term`) + re-run `/sbin/uartmode 2` before driving the
AUX shell.

**a4091dbg + ring, boot probe (O56+O57 on):**
```
counters: insns=7 selects=0 kicks=7   stop rsn=none
ring: [0..7] all  @400171ce  47000000  arg=00000000   (7-8x, identical)
```
8 clean SELECT-STO cycles. BUT: `peek 400171ce` (CPU read) =
`47 00 00 00  00 00 01 50` (matches `siop_script.out`: `0x47000000,
0x00000150`). **The SIOP's DMA fetch returns `47000000` for the insn but
`00000000` for the arg (should be `0x150`).**

**After `run a4091d 1` (detached probe):**
```
ring: [0..7]  @400171ce  47000000  arg=00000000       (clean SELECT-STO)
      [ 8]    @400171ce  7cfc7cfc  arg=7cfc7cfc        <- whole 8-byte fetch garbage
      [ 9]    @400171d6  58000000  arg=00004000        (real: 87 8b .. / JUMP switch)
      [10]    @400171de  e08a0000  arg=0000015f  grp3  (real: 86 8a .. / JUMP msgout)
```
DSP advances correctly (ce -> d6 -> de, +8 each). The FETCHED BYTES are
wrong: entry 10 real `86 8a 00 00` vs got `e0 8a 00 00` (byte0 only);
entry 8 all 4 corrupt (`7cfc` fill).

**DECISION / diagnosis:** this is a **DMA data-integrity bug in the a4091
bus-master read path**, NOT SCRIPTS decode and NOT the script contents.
Progressive: arg wrong from transaction 1, everything wrong after ~8.
Prime suspect: **68020 D-cache coherency** - the a4091 kickstart module
(incl. `scripts[]`) is relocated to RAM by CPU writes with D-cache on;
the a4091 DMA master does not snoop cache, so it reads stale/uninit DRAM
(`0x7cfc7cfc` = uninitialised pattern). Matches a4091-software git-bug
`587684b` ("cache coherency on 68020+, needs CacheClearE/U"). insn bytes
sometimes right = partially flushed lines.

**Next:** (a) retest with the Minimig 68020 D-cache OFF (OSD) - if the
fetch goes clean, it's cache; (b) check whether `a4091.device` calls
`CacheClearU()` after relocation / `dma_cachectl()` around the script;
(c) if it's a hard HW gap, the a4091 DMA path in `cpu_wrapper` needs to
either bypass cache or the fx68k/TG68K core must invalidate on DMA write.

## 20260831 - instruction ring build/timing

- build #27 (ring, comb 3x16:1 read mux): -0.073 setup, on `pll_hdmi`
  (video pixel clock), not the a4091. ~1500 FF for the ring shifted the
  fitter.
- build #28 (ring read registered -> MLAB/M10K): -0.069, same HDMI path.
  So the ring FF were not the cause - fitter placement noise on the video
  path (b25 +0.127, b26 +0.343 both passed clean).
- build #29: SEED 1 -> 3 retry. If it also lands on HDMI, ship #28 as-is:
  a -69ps pixel-clock path is a margin warning, not a data-path failure,
  and this is a debug build driven over serial + screenshots.
- tb: 19/19 pass with the ring (G19 reads it back through the board
  window; SELECT @0x1700 + INT @0x1708 captured correctly).

## 20260831 — instruction ring + script/SIOP cross-check

**Decision:** stop guessing at the post-SELECT wedge; add a 16-deep
instruction ring to the SIOP so hardware shows the exact fetch sequence.

**Compiled `siop_script.ss`** (repo `A4091/a4091-software`, `ncr53cxxx`
built locally) and walked every opcode against `a4091_siop.v`:
- decode is COMPLETE for the probe path (SELECT tbl-indirect, JUMP REL +
  phase-compare, MOVE FROM ds_X tbl-indirect block move, CLEAR/SET,
  CALL REL, INT). Only `WAIT RESELECT` (`54000000`) is still TODO and
  that's the reselect path, not the initial probe.
- RAM contents verified byte-for-byte vs `siop_script.out` at SELECT
  (`47000000 00000150`), `switch:` JUMP (`878b0000 00000030`), JUMP
  msgout (`868a0000 000001a0`). **The script in RAM is correct.**
- driver (`siop.c`): DMODE=0xe0 (no MAN), DCNTL no SSM -> **full-speed
  SCRIPTS**, plain `move.l sc_scriptspa -> DSP` kick, `DCNTL.STD` resume.
  Script args are script-relative; the chip computes `DSP+disp`.

**So the HW `dbg_i0 = 7cfc7cfc @ 0x400171ce` is NOT a decode bug** - it's
a corrupt *fetch* from a verified-correct script base (and `..ce` is
2-aligned, `scripts[]` is `aligned(4)`). Prime suspects: a4091-DMA
address decode into Z3 fast-RAM, bus arbitration, or 68020 D-cache
coherency (a4091-software git-bug 587684b).

**RTL (build #27, pending):**
- `a4091_siop.v`: `ir_dsp/ir_insn/ir_arg [0:15]` + `ir_wp`, one entry per
  `S_DEC` (fetch addr + raw 8 bytes). Read-only.
- `a4091.v`: debug window widened to 0x8D0000-0x8D03FF; ring at
  0x8D0100 (16 x 16 bytes: dsp/insn/arg), `ir_wp` at `w[0x1a]`.
- `a4091dbg.c`: dumps the ring oldest-first with the `<- newest` marker;
  `[YYYYMMDD-hhmmss]` header + footer. `peek.c` same timestamp.
- tb **G19** reads the ring back through the board window and checks the
  last two entries (SELECT @ 0x1700, INT @ 0x1708). **All 19 groups pass.**

---

## 2026-08-30 — ROOT CAUSE of "no IDE boot": stale MiSTer binary, NOT the A4091

**The whole "b23 / baseline / any core won't boot IDE" saga was a stale
Main_MiSTer binary.** Nothing to do with the A4091 RTL, SIOP, or HDF.

- The a4091 `Main_MiSTer` tree on `build-host` sat at `98643c0` (Aug 16).
- Upstream commit **`ebd9628` "minimig: include A2065 config into
  minimig_config"** (Aug 21) appended `uint8_t a2065_mode;` to
  `mm_configTYPE` → `sizeof(minimig_config)` **7268 → 7270** (2-byte
  align), AND relaxed `minimig_cfg_load()` from a strict
  `size == sizeof || 5152 || 5216` to `size <= sizeof(minimig_config)`.
- The user's live `config/Minimig.cfg` is **7270 bytes** (written by a
  post-`ebd9628` MiSTer). The stale a4091 MiSTer (struct 7268, strict
  check) **silently rejected it** → default config → no hardfile filename
  → Kickstart "insert boot disk" forever. `is_minimig()` fine, RTL fine,
  HDF fine (first 500 MB byte-identical to the untouched Aug-20 copy).

**Fix:** rebuilt `Main_MiSTer` on current `origin/master` (`915ca33`) with
only the `a4091_sd_poll` hook re-injected (mount-only variant). `sizeof`
now 7270, config loads, **AmigaOS 3.2 boots from IDE (DH0), Workbench up.**
New binary md5 `6622c766c8776187ad2a4aed5ab20d15`, deployed
`/media/fat/MiSTer`. Old one saved as `/media/fat/MiSTer.prev_a4091old`.
A2065 local mods stashed on `build-host` (`git stash` "a4091-a2065-wip-preserve",
also `/tmp/a2065_save/`).

**Serial console:** DH0's `MiSTer:user-startup` runs `newcli AUX:115200/8n1`
— the AUX shell **is** there (`4.DHO:>`). Drive it with
`scratchpad/aserial.py` (slow 6 ms/char input — the AUX console drops
chars otherwise). `uartmode.Minimig` = 2 (Console), leave it.

**build #25 — SIOP kick-timing fix (the split `move.l DSP` race).**
The 53C710 starts SCRIPTS on the DSP-MSB write (chip reg 0x2f). On the
real A4091 `move.l script,DSP` is one atomic 32-bit Zorro III write; our
16-bit register port splits the beswapped move.l into two bus cycles —
regs 0x2f/0x2e first, then 0x2d/0x2c. Kicking on 0x2f started the fetch
before dsp[15:0] landed → garbled script address, junk insns, watchdog.
Fix: arm on 0x2f, actually start once the trailing 0x2c write lands
(`kick_lo_seen`) or the reg bus goes idle. tb G17. Timing: b24 (naïve
version) missed by 37 ps; b25 (decision off the `st` path) +0.127.
**Result: `stop rsn` goes from WDOG → `none`.** The SIOP now fetches the
driver's real init script cleanly.

**build #26 — table-indirect SELECT.** With b25, `a4091dbg` +
`share:a4091/peek` (new m68k mem-dump tool) showed the first insn is
`0x47000000` @ `0x400171ce` = **`SELECT ATN FROM ds_Device, REL(reselect)`**
— the NetBSD-siop first instruction (`a4091-software/siop_script.ss`,
fetched from GitHub). Bits: [30] I/O, [26] rel-addr, [25] **table
indirect**, [24] ATN. Our SIOP only did a *direct* SELECT
(`insn[23:16]` as the ID) → the table-indirect form has that field 0 →
always STO → `selects=0`, driver retries forever, unit never opens.
Fix: new `S_SELA/S_SELB/S_SELC` — when `insn[25]`, DMA-read the ID
bitmask byte from `*(DSA + s24(insn[23:0]))[23:16]` (`ds_Device` @ off 0
= `(1<<target)<<16`), then run the select decision on that. `insn[26]`
now also makes the alt-address relative (`dsp + s24(arg)`). tb G18.

**build #26 HW result — `a4091.device` now LOADS.** `version a4091.device`
=> `a4091.device 42.39` (was "object not found" through #25). Table-indirect
SELECT works: `a4091dbg` `select_id` now tracks the byte fetched from
`*(DSA)` (0x02 when probing ID 1, 0x40 for ID 6...). Timing +0.343.
- **Unit open still fails.** `a4091d 1` -> "Open a4091.device failed".
  The probe SELECTs ID 1 (select_id=02), the script proceeds past SELECT,
  then a later kick fetches garbage (`dbg_i0 = 7cfc7cfc @ 400171ce`,
  `stop insn @0`) -> WDOG. So there's a THIRD SIOP gap in the post-SELECT
  flow: `switch:` dispatch (JUMP/CALL REL on phase), `MOVE FROM ds_XXX`
  (table-indirect block move, bit 28), or the a4091_target not answering
  MSG_OUT/CMD the way the real script drives it. `peek` of the script
  region + the DSA table is the next step (careful: `list <name>:` from
  the serial shell pops a modal Volume requester that blocks the shell).

**A4091 state now (b26 core + rebuilt mount-only MiSTer, O[56]+O[57] on):**
- Board autoconfigs: `A4091 board @ 0x50000000  size 16 MB`, in the
  expansion list, debug window `sig=a491`.
- `a4091.device` loads from ROM, programs the chip (`DIEN=35`).
- **Still wedges on the init SCRIPT** (same as build #22):
  `kicks=N, insns=N, selects=0, WDOG, last DMA=400171dc`.
- b23 capture: first insn after a kick fetched from **`DSP=0x400171d6`**
  (NOT longword-aligned — `…d6`); bytes decode as garbage that varies
  between runs (`00007cfc`/`e0580000`), arg points at unmapped
  `0x588f4280` → `d8` DMA to nothing → timeout → 14–18 retries → give up,
  unit never opens → `version a4091.device` = "object not found".
- **Prime suspect: DSP register assembly or the SCRIPT-fetch alignment.**
  `0x400171d6` should almost certainly be `…d8` or `…d4`. Either `wreg`
  for regs `0x2c-0x2f` mis-lands a lane on the driver's 32-bit DSP write
  (cf. the ncr7xx single-shot bug), or the driver's script really is at
  a 2-aligned addr and our per-byte big-endian fetch is fine but the
  driver's DSP write arrived off-by-2. Next: DMA-read `0x400171c0..e0`
  from the Amiga (`ncr7xx -D`) to see the real bytes, and trace the
  CPU→SIOP writes to `0x2c-0x2f` at kick time.

---

## 2026-08-29 — MacLC_MiSTer SCSI review + SIOP instrumentation (build #19)

Reviewed `danifunker/MacLC_MiSTer` + `Main_MiSTer` — a Mac LC core (68020 +
NCR 5380) that booted System 6 but hung System 7 at "Welcome" with the
**same bug class** we have. Writeup: `maclc-scsi-reference.md`. Their
root causes, mapped:

- **alloc-length over-serve deadlock** — a response must serve
  `min(alloc, actual)` and END the data phase there; holding REQ for
  leftover bytes hangs the initiator. (Our SIOP phase engine: a `MOVE`
  needs `DBC == target_len` or the phase never ends cleanly.)
- **completion / phase-mismatch IRQ latch** — the vendor driver's async
  I/O sleeps on an interrupt at DATA→STATUS; if the controller doesn't
  raise it, `ioResult` never clears → hang. **Our SIOP has no
  phase-mismatch interrupt.** Prime suspect.
- every command must complete (unknown CDB → CHECK, never stall);
  level IRQ never edge (our `paula intreq[3] <= tmp[3] | int2` is already
  level-correct); truthful poll-able status bits.
- transport: MacLC uses `hps_ext` + a `support/` handler for CD/Toolbox
  because `is_minimig()` also skips the generic SD loop — i.e. our
  option 1 is the right shape.

MacLC took ~15 documented sessions on disk I/O. Methodology worth copying:
sim-gated instrumentation, dual oracle sources, forensic disk-diff.

**build #19 — instrument the SIOP (commit `3b267968`):**
- **`d8` byte-DMA watchdog** — `D_WAIT` times out (~9 ms) instead of
  holding `dma_req` forever. This is the CPU-stall path the FSM watchdog
  can't reach (`a4091_dma_active` stuck high freezes the 68k -> the real
  reason build #18's watchdog didn't rescue boot).
- **watchdog now delivers** — `d8` timeout → `DSTAT.BF` (bit 5, in the
  driver's `DIEN 0x35`); plain expiry → `ABRT|IID`. Stop-reason recorded.
- **debug window** — board `0x8D0000`, 16-bit reads: `st`, `DSP`, `DBC`,
  `DCMD`, `DSTAT`, `SSTAT0/1/2`, `DIEN`, `ISTAT`, last DMA addr,
  `dma_req`, stop-reason, + saturating counters (insns / selects /
  phase-mismatches). `dbg_pmm` flags a DATA phase ending with
  `DBC != target count` (detector only this build).
- **`tools/a4091dbg.c`** — `FindConfigDev(514,84)` → dump the window.
  Built with `m68k-amigaos-gcc -lamiga`, deployed to `<shared>:a4091/`.

16 tb groups pass.

**builds #19-#21 — instrumentation, still hung:**
- #19: SIOP-FSM watchdog rearmed on `S_DEC`/`d8_done` → a wedged SCRIPTS
  polling loop held it off forever. Fixed #20: pure non-idle cycle count.
- #20: still hung. `a4091_sd_poll` file-logs to `/media/usb0/a4091_sd.log`
  now — proves the HPS poll loop is alive (2 M polls) and **`st` never
  leaves `0000`**: `a4091_sd` never gets a sector request, so the probe
  wedges *before* any disk I/O.
- **`sd_image[0]` is not mounted** — `parse_config`'s `SC` handler is
  skipped for Minimig. A hardcoded `user_io_file_mount("A4091/a4091test.hdf")`
  from `a4091_sd_poll` works (`ret=1 size=16 MB`), so `FileOpenEx` is fine.
  Even with the mount forced, `st` stays `0000` and boot hangs.
- The Amiga is frozen (`clkena_in` low) so `a4091dbg` can't run. But
  `present=0` builds (#15, no disk) also hung → the hang is **`O[56]=1`
  itself = a live `a4091_sd`**, not `present`/the probe.
- #21: expose a 64-bit SIOP snapshot (`st` / `dma_req` / `dstat` /
  `sstat2` / stop-reason / kicks / sels / phase-mismatch / `select_id`)
  on `a4091.v` `dbg_bus` → `cpu_wrapper` → `Minimig.sv` → `hps_ext` cmd
  `0x68`; `a4091_sd_poll` reads it every 4000 idle polls to the log.
  Also fixed `hps_ext` `dout_en` (was set for `0x65`).

**build #21 — SIOP snapshot: the chip is NEVER touched.**
`/media/usb0/a4091_sd.log` from poll #1 onward, unchanged for 2 M polls:

```
SIOP st=0 dma_req=0 dstat=00 sstat2=00 rsn=0 kicks=0 sels=0 pmm=0 selid=00
```

`kicks=0` (saturating - the driver never wrote DSP), `sels=0`, `dstat=0`,
every register 0. **With `O[56]=1` the a4091.device never even programs
the 53C710** - it's not a probe hang, `Init()` itself wedges before
touching the chip. `present` feeds *only* SELECT (and `sels=0`), so it is
**not** `present` - it is a **live `a4091_sd`** (the only other thing
`O[56]` changes). (`dbg_bus` also read `idle=0` wrongly - the concat was
72 bits into `[63:0]`, shifting everything; fixed to exactly 64 in #22.)

**build #22 — bisect.** `a4091_present` forced to `0`, `a4091_sd.ena`
still from `O[56]`. If `O[56]=1` still hangs → `a4091_sd` / `hps_ext`
wiring. If it boots → `present` after all and #21's snapshot was
mis-decoded.

**CORRECTION — the "hangs" were the serial UART in PPP mode, NOT the RTL.**
`uartmode.Minimig` had drifted to **1 = PPP** (0 = none, 1 = PPP,
**2 = Console**). With PPP, `/dev/ttyS1` carries no console → the harness
reads 0 bytes → looks like a hang. Set `uartmode.Minimig` to `2` and
LEAVE IT. **Builds #17–#22 all boot fine.** All the HPS-side data stays
valid (`a4091_sd.log` polls, the `0x68` SIOP snapshot).

**build #22, `O[56]=0`, serial restored — `a4091dbg`:**
```
st=0 IDLE  DIEN=35  DMODE=e0        (driver loaded + programmed the chip)
kicks=14  insns=14  selects=0       (14 SCRIPTS starts, ~1 insn each)
stop rsn=01 WDOG   last DMA=400171dc (Z3 FastRAM - the driver's SCRIPTS)
```
The driver runs its init SCRIPT, DMAs it from Z3 RAM, and **wedges on
~the first instruction** (`selects=0` - never even reaches a SELECT). The
0.6 s watchdog catches each of the 14 attempts, the driver gives up, boot
completes. So the watchdog *works* - the remaining task is the SIOP
mishandling the driver's actual init SCRIPT.

**~~build #22 broke the core~~** - retracted; it was PPP.

Suspects in the #17 delta (hps_ext.v + Minimig.sv):
- `hps_ext.v` new ports + the `a4b_wr` pipeline running unconditionally at
  the top of the always block + `dout_en` for `'h64`/`'h66`/`'h68` +
  `io_dout` writes for the new commands - any of which could corrupt the
  IDE / UART / screen-geometry command flow the core needs to boot.
- `Minimig.sv` `hps_io` instance: added `.VDNUM(1)` + `.img_mounted` +
  `.img_size` (stock connects none); `a4091_sd` ↔ `hps_ext` wiring.
- (`a4091.v` #19 debug window `0x8D0000` + `dbg_bus`, `a4091_siop.v`
  watchdog/instrumentation - less likely, the SIOP is idle at boot, but
  not ruled out.)

**Last known-good: build #16** (`hps_io` VDNUM sd_* path, `O[56]=0`,
verified booting - autoconfig + boot ROM + `a4091.device` + `ncr7xx`
tests pass). Restored on the MiSTer with the stock `MiSTer` binary.

**Next:** rebuild option 1 from #16 one change at a time, re-checking
`O[56]=0` boot after EACH:  (a) hps_ext.v alone,  (b) + Minimig.sv hps_io
change,  (c) + a4091_sd blk_done,  (d) + the debug window. Bisect to the
breaking change.

---

## 2026-08-29 — sector server, option 1: hps_ext + Main_MiSTer (builds #17–#18)

Chosen transport (`hps_io` `S`-slot is a dead end — Main_MiSTer skips the
generic SD loop for Minimig): route `a4091_sd`'s block requests over
`hps_ext`, which *is* polled in `user_io_poll()`'s `is_minimig()` branch.

**RTL (build #17, timing met +0.094):**
- `hps_ext.v` — A4091 sector mailbox: `'h64` poll (pending bits + LBA),
  `'h65` data HPS→FPGA, `'h66` data FPGA→HPS, `'h67` block-done. 512 B
  buffer walk copies `sys/hps_io.sv`'s `b_wr` 3-stage pipeline.
- `a4091_sd.v` — `sd_ack` level → `blk_done` pulse; `S_RD_ACK`/`S_RD_END`
  collapse to `S_RD_WAIT`, ditto write side.
- `Minimig.sv` — `hps_io` back to stock (keeps only `img_mounted` /
  `img_size` for the S0 mount notify); `a4091_sd` ↔ `hps_ext` wiring.
- tb block-server model reworked to `blk_done` + request-deassert wait.
  16 groups pass.

**Main_MiSTer** (`integration/main_mister_user_io.patch`, built on `build-host`
from `98643c0`): static `a4091_sd_poll()` in `user_io.cpp` — poll `'h64`,
file I/O on `sd_image[0]` (CONF_STR `S0`), stream the block, `'h67` done;
called after `minimig_share_poll()` / `a2065_poll()`. Deployed by swapping
`/media/fat/MiSTer` (backup `MiSTer.bak_pre_a4091`; `mv` then `cp`, the
running binary is "text file busy").

**Result — still hangs.** `O[56]=1` + `.hdf` on S0 → AmigaOS boot hangs
hard (0 serial bytes, 130 s). Added a `printf` to `a4091_sd_poll` and
captured MiSTer stdout (relaunch with `> /tmp/mister_out.log`): **no
`a4091_sd:` line ever prints** — `a4091_sd` never asserts `sd_rd`/`sd_wr`.
So the hang is *before* any sector I/O: the real `a4091.device` init
SCRIPTS drive phase / message sequences the simplified synchronous SIOP
does not resolve, and Minimig has no bus timeout → CPU stalls forever.
(Consistent with builds #15/#16, which hung on `O[56]=1` regardless of the
transport.)

**build #18 — SIOP global watchdog (timing met +0.187).** 24-bit
free-running counter, rearmed by forward progress; on expiry → `DSTAT`
ABRT|IID + `S_STOP` → IRQ. **Did NOT rescue the boot** - `O[56]=1` + disk
still hangs hard, still no `a4091_sd:` log line.

**Assessment:** the watchdog only covers the SIOP main FSM (`st`). The
deadlock is deeper - almost certainly the byte-DMA engine (`d8`) or the
CPU-side arbitration: the real `a4091.device` fetches SCRIPTS / does a
Block Move whose DMA address never returns `ramready`
(`dma_ack = a4091_dma_active & ramready`), so `d8` holds `dma_req` forever,
`a4091_dma_active` stays high, and cpu_wrapper stalls `clkena_in` -> the
68k is frozen regardless of what `st` does. Candidates: the driver
relocates itself + SCRIPTS into Z3 FastRAM (`0x40000000`) and our
DMA-master path mis-decodes that range; or `dsp` lands in board / Zorro
space; or an unhandled SCRIPTS opcode leaves `dsp` garbage.

`ncr7xx -r`/`-t1`/`-t`(Device access) all still pass and `a4091.device`
still loads with `O[56]=0` - the SIOP is fine for the driver's *init* and
for hand-written test SCRIPTS (tb G6 runs a full SELECT/INQUIRY/DATA-IN/
STATUS/MSG-IN nexus). It's specifically the driver's *unit-0 probe* that
wedges once `present` lets a SELECT succeed.

**Next (needs instrumentation, not more blind builds):**
1. Watchdog on `d8` / `a4091_dma_active` too - force `dma_req` low +
   `a4091_dma_active` low on expiry so the CPU always un-stalls.
2. Expose SIOP state (`st`, `dsp`, `dbc`, phase, `dma_addr`, `dma_req`) in
   spare 53C710 scratch registers or a board debug window, readable over
   serial once boot survives.
3. Trace the first DMA address the probe issues vs the cpu_wrapper
   `sel_*` / `ramaddr` decode for the DMA-master override.
4. Or: run the probe against the amiberry `lsi53c710.cpp` with logging to
   see the exact SCRIPTS sequence the driver emits, then match the SIOP.

---

## 2026-08-29 — HPS sector server (builds #9–#11)

Wire `a4091_target`'s `sec_*` streaming port to an `hps_io` virtual-drive
(`sd_*`) slot so a mounted `.hdf` is served by the HPS as SCSI ID 0 LUN 0.

**New RTL — `rtl/a4091_sd.v`:** `sec_* ↔ sd_*` bridge. One 512 B block in
flight (`blk_rd` BRAM for HPS→target, `blk_wr` LUT RAM for target→HPS since
`hps_io` reads `sd_buff_din` combinationally); multi-sector transfers loop
block-by-block. WRITE uses a `sec_dv` / `sec_wr_rdy` valid-ready handshake so
the per-block flush pause never drops a byte.

**`a4091_target.v`:** `disk_blocks` input → READ CAPACITY / MODE SENSE from
the mounted image size. Write stream reworked twice (see build #10).

**`integration/full/` (Minimig.sv, cpu_wrapper.v):** `hps_io #(.VDNUM(1))`
`sd_*` slot 0, `CONF_STR` `"S0,HDFIMGHDF,A4091 SCSI Unit 0"`, `a4091_sd`
instance, `a4091_present = a4091_img_present` (disk at ID 0), `sec_wr_rdy` /
`disk_blocks` threaded through. `files.qip` / `Minimig.qsf` + `a4091_sd.v`.

**tb:** `a4091_sd` + behavioural `hps_io` VD backend (writable overlay).
G7/G8 now run through the bridge; **G15** (3-sector read, block loop) and
**G16** (2-sector write round-trip, pacing) added. 16 groups pass.

**`tools/a4091_disk_test.py`:** writes `/media/fat/config/Minimig.s0` (the
S-slot mount-persistence file — 1024 B NUL-padded path), reloads the core,
waits for boot, then over serial checks `a4091.device` unit 0 opens with a
sane geometry and the RDB partition (`DH1:`) auto-mounted. A 16 MB RDB test
image was built with `amitools rdbtool` (one DOS3 partition, `automount=1`).

- **build #9 — DOES NOT FIT.** First `a4091_sd` used a 4 KB async-read data
  buffer (to hold a whole multi-sector WRITE at once): 103784 / 83820
  combinational nodes. The wide async mux exploded into logic.
- **build #10 — fits, timing −0.199 ns.** 4 KB buffer dropped to a single
  512 B block + the valid/ready write handshake. Compiles clean, but
  `emu|sdram_ctrl:ram1|sdram_state → sd_addr[7]` (**stock Minimig SDRAM
  controller**, `clk_sys`) fails setup by 0.199 ns — a pre-existing
  razor-thin baseline path pushed over by the added fabric/routing
  pressure, **not** A4091 logic (the A4091 `clk_sys` paths clear). Still a
  regression to fix.
- **build #11 — DOES NOT FIT (4411 / 4191 LABs).** `a4091_target` `sec_d`
  made a registered BRAM read + present/advance `W_STREAM` micro-sequence.
  But the fitter log revealed the real hog: **`a4091_inst|rom_mem` was
  "uninferred due to asynchronous read logic"** - the 64 KB boot ROM was
  distributed *logic*, not M10K, the whole time (builds #8/#10 only just
  fit). The combinational `rb = rom_mem[brd_addr[17:2]]` blocked inference.
- **build #12 — fits, timing −0.750.** `rom_mem` → registered read port
  (M10K), frees the LABs. But `a4091_target` is still **18265 ALMs /
  33k FF**: `assign buf_rdata = dbuf[buf_addr]` (async) + the separate
  W_STREAM `dbuf[wr_ptr]` reads = two read ports on the 4 KB array →
  uninferrable, duplicated into flip-flops. Design at 99 % ALMs; the
  fitter, out of slack, degrades a stock video path (`yc_out`) to −0.750.
- **build #13 — fits, timing −1.438.** `buf_rdata` registered
  (`buf_rdata_r`) + SIOP `S_DIS` settle state. Still two `always` blocks
  read `dbuf` → still ~18k ALMs / 33k FF, still 99 %, and now the fitter
  degrades a **different** stock video path (`ascal` polyphase, TNS −99).
  Placement roulette on a packed device.
- **build #14 — in progress.** `dbuf` collapsed to **one `always`, one
  write port, one registered read port** (`dbuf_q`), read address muxed
  `wr_ptr`/`buf_addr` (DATA-IN vs DATA-OUT never overlap); `buf_rdata` and
  `sec_d` both tap `dbuf_q`. Should finally infer as a plain M10K and drop
  a4091_target from ~18k ALMs to a few hundred.
- **Minimig.sv: `O[56]` now gates `a4091_present`.** OFF (default) →
  `present = 0`, `a4091.device` loads and reports no units (the safe
  fallback). ON → a mounted `.hdf` shows as SCSI ID 0.

### build #12 on hardware (before the O[56] gate)

- **No disk:** `version a4091.device` → `a4091.device 42.39`, `ncr7xx -r`
  shows the chip programmed (`SCNTL0=cc SIEN=af DIEN=35 DMODE=e0`).
  Board + driver fully working - the −0.750 timing violation (on `yc_out`,
  not the CPU/A4091 `clk_sys` logic) does **not** break it.
- **Disk mounted (S0):** `a4091_present` = 1 at boot (hps_io mounts S0
  before the driver probes) → `a4091.device` init does real SCSI I/O to
  ID 0 through `a4091_sd` → **hangs / faults**, driver init aborts, the
  device is torn down → `version` says "object not found", HDToolBox sees
  nothing. → **functional bug in the `a4091_sd` ↔ real `hps_io` sd_*
  handshake** (passes the iverilog bench; the tb's behavioural hps_io VD
  model doesn't match real `sd_ack` / poll timing). To debug next.

- **build #14 — timing MET, +0.274 ns setup / +0.246 hold.** The `dbuf`
  single-port rewrite dropped `a4091_target` from **18265 → 245 ALMs**
  (the async double-read had cloned the 4 KB buffer into ~33k FF); whole
  design 99 % → **56 %** logic. Best A4091 build yet.
  - **hardware, `O[56]=0`, no disk:** `showconfig` PASS, `ncr7xx -r` /
    `-t1` / `-t` (Device access) all PASS, `a4091.device` loads and
    programs the chip. Solid baseline.
  - **hardware, disk mounted:** AmigaOS boot **hangs** (no serial prompt
    at all - the driver blocks the startup sequence).

**Root cause found — `a4091_sd` reset polarity.** `Minimig.sv` wired it
`.reset(cpu_rst)`, but `cpu_rst` is **active-LOW** (`0` = reset), so the
bridge sat permanently in reset: `st` frozen at `S_IDLE`,
`sec_qv` / `sec_done` / `sec_wr_rdy` stuck at 0. The instant the real
`a4091.device` does any disk I/O, `a4091_target` waits forever for a
`sec_*` response that never arrives → SIOP DATA phase stalls → driver init
blocks → boot hangs. (The iverilog tb drives `reset` active-high, so it
never showed.)

- **build #15 — timing met (+0.154), but REGRESSES the baseline.**
  `a4091_sd .reset(~cpu_rst | ~cpu_nrst_out)`. Now that `a4091_sd`
  actually *runs*, AmigaOS boot **hangs with `O[56]=0` and no disk** -
  worse than #14, where the (wrongly-)frozen `a4091_sd` was the safe
  state. So a *live* `a4091_sd`, even idle, wedges the core: the most
  likely path is its `sd_*` / `img_*` signals into the real `hps_io` (VD
  slot 0) desyncing the HPS↔FPGA command loop, which also carries the
  serial bridge → no prompt at all.
  - Test-methodology caveat: several "no prompt" results were confounded
    by the harness sampling mid-boot; `a4091_serial_test.py` needs a
    longer, retrying alive-check. Build **#14 with `O[56]=0` is
    re-confirmed working** (showconfig + ncr7xx all pass).

**Assessment:** a generic `hps_io` S-slot is the wrong vehicle for the
sector server on *this* core - Minimig-AGA does all its own disk mounting
through a custom Main_MiSTer path (`hps_ext` / `EXT_BUS`), and bolting a
CONF_STR `S0` + `VDNUM` onto its `hps_io` disturbs that. Options for the
next attempt: (a) hook `a4091_target` into Minimig's existing hardfile
mount path, (b) a dedicated HPS daemon with its own shared-memory window
(like `minimig_netd`), (c) keep the S-slot but add a hard `a4091_sd`
enable so its `sd_*` outputs are forced idle unless a transfer is truly
in flight, plus a SIOP DATA-phase watchdog so a stuck transfer errors
instead of hanging boot.

- **build #16 — `a4091_sd` gets an explicit `ena` (O[56]) input:** when
  off, FSM held at `S_IDLE`, `sd_rd`/`sd_wr`/`sd_lba` forced 0,
  `sd_buff_din` forced 0, `img_present`/`disk_blocks` held 0. Timing met
  (+0.089 setup). **`O[56]=0` boots clean, all 4 harness tests pass** -
  the solid shippable baseline. **`O[56]=1` + disk still hangs.**

### ROOT CAUSE of the disk hang — Main_MiSTer skips generic SD for Minimig

`Main_MiSTer/user_io.cpp` `user_io_poll()`: the `is_minimig()` branch runs
its *own* storage polling (`HandleFDD`, `ide_check()` / `ide_io()` for the
`hps_ext` IDE hardfiles, `minimig_share_poll()`). The **generic hps_io
SD-sector poll** (the `UIO_SECTOR_RD` / `UIO_SECTOR_WR` command loop that
drives `sd_ack`) is guarded `… && !is_minimig()` - **never runs for this
core**. So `a4091_sd` asserts `sd_rd`, waits for `sd_ack`, and it never
comes → stuck in `S_RD_ACK` → SIOP DATA phase stalls → `a4091.device`
init blocks → boot hangs.

**The `hps_io` `S0` / `VDNUM` virtual-drive path is a dead end on the
Minimig core.** Sector-server options for the next phase:

1. **Main_MiSTer change** - add an `a4091_check()` / `a4091_io()` beside
   `ide_check()` in the `is_minimig()` poll, serving `.hdf` sectors over a
   new `EXT_BUS` sub-protocol (or a spare `spi_w` command). "Proper", but
   touches the Main_MiSTer C build + deploy.
2. **Piggyback the IDE `hps_ext` path** - present the A4091 target as
   another IDE-style unit on `EXT_BUS`. Reuses the working block server,
   but the protocol wasn't meant for a second consumer.
3. **Dedicated HPS daemon** (like `minimig_netd`) - mmap `/dev/mem`, a
   shared-RAM window in the FPGA, `a4091_sd` talks to that instead of
   `hps_io`. Fully independent of Main_MiSTer; needs a free HPS-lightweight
   bridge window (the `0x27FFxxxx` pattern in `CLAUDE.md`).

**Shippable milestone: build #16, `O[56]=0`** (`minimig_20260829_A4091_b16.rbf`):
A4091 autoconfigs, boot ROM + `a4091.device` load, `ncr7xx -r`/`-t1`/`-t`
(Device access) pass, timing met (+0.089). `O[56]` cleanly gates the
(not-yet-working) sector server off.

**Next:** pick a sector-server transport (1/2/3 above). Keep #16 as the
baseline RBF.

---

## 2026-08-29 — build #8: boot ROM bundled, a4091.device loads on hardware

**Test:** `a4091_serial_test.py` (all 4) on build #8 (commit `f804917a`).

- `showconfig` — PASS.
- `ncr7xx -r` — PASS, and the register dump now shows the chip
  **configured by the driver**: `SCNTL0=cc`, `SIEN=af`, `DIEN=35`,
  `DMODE=e0` (were all `00` pre-ROM). AmigaOS autoconfigured the board,
  read the DiagArea at board+0x200, relocated and started
  `a4091.device` v42.39, which reset + programmed the 53C710.
- `ncr7xx -t1` — PASS.
- `ncr7xx -t` (new `ncr7xx-rom` harness test) — **Device access: PASS**
  (ROM window reads back the a4091.rom image byte-for-byte),
  Register test PASS. Stops at *DMA FIFO test* (`CTEST1` reads `f0`
  always-empty; we have no DMA-FIFO fill/level model) - out of scope.

Amiga booted to the shell normally, no hang - `a4091_present = 0` so the
driver probes IDs 0-6, each times out, and it registers no units.

Quartus: **setup slack -0.030 ns** on `pll_hdmi ... divclk` (the HDMI
pixel clock) - a pre-existing marginal Minimig-AGA path, not in the A4091
logic (`clk_sys` +0.120, `clk_114` +0.700, both met). Deployed anyway;
HDMI output on hardware is fine.

**Next:** HPS sector server - wire `a4091_target`'s `sec_*` port to an
`hps_io` virtual-drive (`sd_*`) slot so a mounted `.hdf` becomes a SCSI
target, set `a4091_present` from `img_mounted`.

---

## 2026-08-28 — build #7: register access WORKS (`ncr7xx -t1` PASS)

**Test:** `a4091_serial_test.py` + `ncr7xx -t` on build #7 (commit `ed0fe181`,
Quartus setup +0.197 / hold +0.254).

- `showconfig` — PASS: `mfg=514 product=84 size=16MB`.
- `ncr7xx -r` — PASS: `53C710 V2`, every register clean, all 32-bit regs
  `00000000`. No hang (build #6 regression gone).
- `ncr7xx -t1` (register test) — **PASS**. The CTEST5 ADCK/BBCK
  double-count is fixed; byte / word / longword register R/W all correct.
- `ncr7xx -t` (full) — fails at the **Device access** subtest: it reads the
  AutoConfig/boot ROM window and expects the a4091-software ROM image;
  our RTL has no ROM bundled yet (`rom_mem` empty, DIAGVALID=0) so every
  ROM byte reads `00` → `Stuck low: 0xff`. Expected. The DMA/FIFO subtests
  after it are not reached.

**Harness fix:** `showconfig` and `-t1` first came back as
`shconfig` / `shara4091/...` — the Paula UART RX has no flow control and
drops characters on a fast TX burst. `a4091_serial_test.py` now sends the
command line one byte at a time with an 8 ms gap (`send_slow()`).

**Next:** boot ROM bundling (`A4091_ROM_HEX`, widen `rom_mem` to 64 KB,
set DIAGVALID) + HPS sector server (`minimig_scsi.cpp`) → autoboot from a
`.hdf`, and the rest of `ncr7xx -t` (DMA FIFO / SCSI FIFO / DMA via
SCRATCH-TEMP-RAM).

---

## 2026-08-28 — build #6 hang + single-shot side-effects (build #7 pending)

**Test:** `a4091_serial_test.py` on build #5 then build #6.

Build #5: `showconfig` PASS (`mfg=514 product=84 size=16MB`), `ncr7xx -r`
PASS (`53C710 V2`, all 32-bit regs `00000000`, no filler), `ncr7xx -t1`
FAIL — `DNAD address increment failed: 0x8 != 0x4`,
`DBC decrement failed: 0x8 != 0xc`.

**Issue:** the CPU register write strobe (`sel_reg & brd_lds`) is a *level*
held the whole bus access (~2-3 `clk_sys` cycles). `wreg` CTEST5 (`0x19`)
fires the self-clearing ADCK / BBCK edge strobes (`dnad += 4` / `dbc -= 4`)
once **per held cycle** → +8 / -8. Same hazard for CLF / ABRT and the
SCRIPTS kick (guarded by `st == S_IDLE`, so harmless there).

**Build #6 (regression):** first attempt gated all four strobes with a
1-cycle `xact` pulse locked to `brd_sel`'s rising edge, and rebuilt
`brd_ready` as a hold latch. `showconfig` still PASS but `ncr7xx -r`
**hung on the very first register read** (`[50800044] R 00` then dead).
`uds_p` / `lds_p` / `wr_p` lag `brd_sel` (= `cpu_req`) by a cycle or two in
the CPU-wrapper pipeline, so the strobe never coincided with the single
`xact` cycle → no latch → `brd_ready` never asserted → CPU stalled forever
(Minimig has no bus timeout). Backed out.

**Fix (build #7):** keep build #5's handshake (level strobes, level
`brd_ready`) **exactly**. Change only `a4091_siop.v`: `reg_ready` still
tracks the level, but each lane's value-latch and every side effect
(register write, read-clear / FIFO-pop, SCRIPTS kick) fires **once per
address phase** — trigger = strobe rising edge **OR** that lane's decoded
register address changed (so a 32-bit access still services both halves).
`a4091.v` + `tb/a4091_tb.v` reverted to build #5. 14 tb groups pass.
Commit `e7833a64`. **Not yet compiled / deployed.**

**Next:** build #7, redeploy, re-run `a4091_serial_test.py` (all 3), then
`ncr7xx -t` full suite.

---

## 2026-08-28 — open: dual-lane register window (build #5 pending)

**Test:** `ncr7xx -t1` (register test) on build #4.

```
Reg SCRATCH f0ffc3ff != f0e7c3a5 (diff 0018005a) W32 R32
Reg TEMP    e1ff87ff != e1cf874b (diff 003000b4) W32 R32
...
Floating or bridged: 00ff00ff D0-D7 D16-D23
  Register test:   FAIL
```

**Issue:** byte-wide register window. Each 16-bit bus word transfers 1 real
53C710 register byte + `0xff` filler, so a 32-bit register access moves only
bytes 3 & 1 (reads: 2 & 0 = `0xff`; writes: 2 & 0 not written). ncr7xx
correctly localises it to data lines D0-D7 / D16-D23.

**Fix:** commit `958c936f` — each 16-bit word now carries the beswapped pair
of adjacent registers (D15:8 = reg `base|{3 or 1}`, D7:0 = reg
`base|{2 or 0}`). Byte / word / long all land correctly; read side-effects
(DSTAT/SSTAT0 clear, CTEST2 SIGP, CTEST3 FIFO pop) fire per strobed lane.
tb G14 checks a full 32-bit round-trip (`EF BE AD DE`, no filler). 14 groups
pass. **Not yet compiled / deployed.**

**Next:** build #5, redeploy, re-run `ncr7xx -t1` then `-t` (full suite).

---

## 2026-08-28 — build #4: register-window handshake deadlock — FIXED

**Test:** `ncr7xx -r` on build #3.

Read block-0 (16 registers — values sane, `beswap` confirmed by the swapped
"Reg" column, `SCNTL0=c0` / `SCID=80` / `DSTAT=80` / `DCMD=40` /
`CTEST1=f0` / `CTEST2=01`, chip = `53C710 rev V2`), then **hung** on the
first longword read (`DSP`/`DSPS`/`TEMP`/`DNAD` as `%08x`).

**Issue:** `brd_ready` used a sticky `brd_busy` latch that only cleared when
`brd_sel` dropped. A 68020 longword = two back-to-back 16-bit cycles with
`brd_sel` held the whole time → the 2nd half never re-armed → CPU stalled
forever (Minimig has no bus timeout).

**Fix:** commit `4dec97e4` — `brd_ready` is now a level (like `fastchip.v`),
high while selected + resolved, with a `brd_addr`-stable gate so each burst
half waits one cycle for fresh data. `brd_dout` made combinational.
tb G14 (`brd_read_burst`, holds `brd_sel` across two address phases, fails
on timeout) = the regression.

**Build #4:** full compile 0 errors, timing met (clk_114 +0.068, clk_sys
+0.779, worst +0.026 = stock HDMI pixel clock). RBF md5
`fd65fea0c8b58239a752e250ffdcd21f`. Deployed.

**Result:** `ncr7xx -r` completes. New finding → see dual-lane entry above.

---

## 2026-08-28 — build #3: autoconfig 16 MB — WORKS

**Test:** `showconfig` on real Amiga.

```
Commodore (West Chester) A 4091 SCSI:   Prod=514/84($202/$54)
    (@$50000000, size 16MB, subsize same)
```

Build #2 showed the board as **8 MB**: `er_Flags` had only `ZORRO_III` set,
so `er_Type[2:0]=0` was read as the Zorro-II 8 MB size code.

**Fix:** commit `958c936f`'s parent — `er_Flags = MEMSPACE | EXTENDED |
ZORRO_III` (`0xB0`). `EXTENDED` selects the Z3 extended size table where
`er_Type[2:0]=0` ⇒ 16 MB; `MEMSPACE` places it deterministically in Z3
memory space. `er_Type` stays `0x80` (no `DIAGVALID` — no boot ROM in this
build; add that bit only with `A4091_ROM_HEX`).

**Build #3:** 0 errors, timing met (clk_114 +0.351). Deployed.

---

## 2026-08-28 — build #2: first hardware bring-up — board enumerates

**Test:** `showconfig` after enabling `O[57]` (`mmcfg`) + core reload.

Board appears: `Commodore (West Chester) A 4091 SCSI  Prod=514/84`, `@$50000000`,
size 8 MB (see build #3). Autoconfig chain order works (A4091 after Toccata
+ Z3 RAM). No boot ROM in this build → no autoboot, `a4091.device` not
auto-loaded; `a4091_present=0` → SELECT times out.

Milestone: the whole FPGA path (Zorro III autoconfig responder, board
aperture, `cpu_wrapper` chain hand-off, INT2 wiring) works on silicon.

---

## 2026-08-28 — builds #1–#2: Quartus integration

`integration/{cpu_wrapper.v,minimig.v,Minimig.sv}.patch` applied on `quartus-host`
(rebased from `build-host`'s `6fc0d5e` to the release branch `eb7a26e`).

- **build #1** (RTL only): full compile 0 errors, RBF built, **setup slack
  −1.395** — all 4 violated paths = the A4091 DMA master
  (`cpu_wrapper|a4091_inst|siop|dma_req`/`dma_addr` on `clk_sys`) →
  `sdram_ctrl:ram1|sd_addr` on `clk_114`.
- **build #2**: added `Minimig.sdc.patch` —
  `set_multicycle_path -from {emu|cpu_wrapper|a4091_inst|*} -to {emu|ram*}
  -setup 2 -hold 1`. The stock CPU↔RAM multicycle's `-from {…|cpu_inst*}`
  filter didn't match the DMA master; the DMA holds its address stable
  waiting for `ramready` exactly like the CPU, so the same multicycle
  applies. → timing met (worst +0.086).

RTL build fix: `a4091.v` `dma_*` ports `output reg` → plain `output`
(Quartus Error 10663 — an instance can't drive an `output reg`).

---

## 2026-08-27/28 — RTL (sim): Phases 1–3 complete

Option A: 53C710 in fabric (`a4091.v` + `a4091_siop.v` + `a4091_target.v`),
ported from amiberry/WinUAE (`ncr_scsi.cpp`, `qemuvga/lsi53c710.cpp`,
`scsi.cpp`). 14-group `iverilog` bench (`A4091/tb`):

- Zorro III autoconfig, boot-ROM window (nibble fan-out), 53C710 register
  file + `beswap`, IRQ.
- SCRIPTS engine, all 4 groups: block move (direct / indirect /
  table-indirect) + phase engine (MO/CMD/DI/DO/ST/MI); Select + register
  ALU; transfer control (carry / phase / masked-SFBR); memory move.
- Virtual SCSI-2 target: TUR / REQUEST SENSE / INQUIRY / MODE SENSE /
  READ CAPACITY / READ(6/10) / WRITE(6/10); sectors stream over an
  `rtl/ide.v`-style HPS port. End-to-end SELECT → … → INT verified;
  INQUIRY / READ(10) land byte-correct in the Amiga-RAM model.
- `present[6:0]` — SELECT to an id with no media → `SSTAT0.STO`, so a
  no-HPS-server core enumerates cleanly.

Not done: HPS sector server (`minimig_scsi.cpp`), OSD menu, boot ROM
(`A4091_ROM_HEX`), disconnect/reselect + tagged queueing, Wait Reselect.

