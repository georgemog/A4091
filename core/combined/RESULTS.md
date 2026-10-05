# Combined core — hardware results

RBF `minimig_20260906_A4091_RTG_A2065_v2.rbf` (Quartus `quartus-host`, seed 1,
0 errors / 80 warnings, clk_114 setup slack **+0.053**, 58 % ALMs).
MiSTer `mister`, AmigaOS 3.2 booting from IDE DH0, `Main_MiSTer`
binary of 2026-09-06 15:34 (A4091 patch + upstream A2065).

## AutoConfig chain (`showconfig`)

```
 MacroSystems (Germany) Toccata SoundCard:   Prod=18260/12($4754/$C) (@$E90000 64KB)
 Commodore (West Chester) A 2065 Ethernet:   Prod=514/112($202/$70) (@$EA0000 64KB)
 Rok Krajnc Minimig Z3 FastRAM:   Prod=5020/16($139C/$10)   (@$40000000, 256MB)
 Rok Krajnc Minimig Z3 GraphicsCard:   Prod=5020/48($139C/$30)  (@$50000000, 16MB)
 Commodore (West Chester) A 4091 SCSI:   Prod=514/84($202/$54)   (@$51000000, 16MB)
```

## A4091 — PASS

`DH0.1` (RegrTest) auto-mounts at boot. `devtest -p` finds
`1 MiSTer A4091 HD 0001 Disk 512 209 MB`; `devtest -g` reports
TD_GETGEOMETRY / RC10 / RC16 all `512 × 409600, C=3200 H=16 S=8`.

`tools/tests/swsiop_regress.py` — **9/9 PASS**
(probe, geometry, read_capacity10, read_capacity16, read_packets, td_seek,
mount, marker_roundtrip, write_integrity).

## A2065 — PASS

`Lance-Test addrs` → `Board 1 at addr EA0000`. `Lance-Test diags`:

```
Buffer memory test.............. PASS
LANCE configuration test........ PASS
Interrupt test.................. PASS
LANCE collision logic test...... PASS
Internal loopback test.......... PASS
Controller PASSED diagnostics.
```

ARM side is live too — `eth0` shows `promiscuity 1` (BPF delivery mode).

## RTG — board + register/framebuffer path verified, display not yet eyeballed

`rtg/tools/rtg_paint_z3.c` (Z3 port of the old two-board `rtg_paint`) finds
the board and paints 640×480 colour bars:

```
Board @ $50000000 size 16 MB - fb $50000000 regs $50800100
```

Read-back after the paint:

* framebuffer row 100 = `00 00 00 00 01 01 01 …` — border then the red band,
  exactly as written
* registers `$50800100` = `27 00 00 00 | 00 03 | 00 01 | 02 80 | 01 e0 | 02 80 | 50 01`
  → BASE `$27000000`, FORMAT 3 (8bpp), **ENABLE 1**, HSIZE 640, VSIZE 480,
  STRIDE 640, ID `$5001`

So AutoConfig → register decode → framebuffer decode all work at the board's
new `$50000000` base. **Open:** the MiSTer `screenshot` capture still came
back 906×540 (the Amiga chipset video path), so whether the display actually
switches to the RTG framebuffer needs a look at the monitor, or a P96
screenmode switch (`SYS:Prefs/Picasso96Mode`, `MiSTer.card` of 2026-08-27 is
installed in `LIBS:Picasso96`).

## Notes

* Enable A4091 with OSD `O[57]` (already on in `/media/fat/config/minimig.cfg`).
* Previous known-good A4091-only RBF is
  `minimig_20260906_A4091_snoop2_noevict.rbf`; the old symlink target is saved
  in `/media/fat/trans/prev_minimig_rbf.txt`.


## Follow-up (2026-09-07): second SCSI drive never mounted at boot

**Symptom:** HDToolBox listed both drives (ID1 + ID2), but only `DH0.1` (ID1)
mounted; no DosNode existed for ID2's `SH1` partition. `devtest -p` saw both
units and `devtest -g a4091.device 2` returned correct geometry, so the
bridge, the ARM SIOP and the driver were all fine.

**Root cause — `RDBFF_LAST` in the RDB, not the core.** The boot ROM's mounter
walks SCSI targets in order and gives up as soon as a drive claims to be the
last one (`3rdparty/mounter/mounter.c`):

```c
md->wasLastDev = (flags & RDBFF_LAST) != 0;      /* rdb_Flags bit 0 */
...
if (md->wasLastDev && !ms->ignoreLast) {
        dbg("RDBFF_LAST exit\n");
        break;                                   /* no further targets */
}
```

Both `.hdf`s were partitioned independently, each as "the only drive", so both
carried `rdb_Flags = 0x17` — `LAST | LASTLUN | LASTTID | DISKID`. The mounter
mounted ID1, saw `LAST`, and stopped. HDToolBox opens each unit directly, so
it was unaffected. Reproduced on the previous A4091-only RBF too — pre-existing
behaviour, not a regression from the combined core.

**Fix:** clear `RDBFF_LAST` on every drive except the highest SCSI ID in use.
`tools/rdb_lastflag.py` shows and edits the flag (recomputing the RDB
checksum):

```bash
python3 rdb_lastflag.py Test200MB.hdf                       # show
python3 rdb_lastflag.py --clear-last --backup rdb.bak Test200MB.hdf
```

Applied to `Test200MB.hdf` (ID1): `rdb_Flags 0x17 -> 0x16`; `Test200MB-2.hdf`
(ID2) keeps the flag, which is now truthful. Original RDB block backed up to
`/media/fat/trans/Test200MB.rdb.bak`. After a core reload, `info` shows:

```
DH0.1     199M  ...  Read/Write RegrTest
SH1       Not a DOS disk
```

ID2 is mounted; "Not a DOS disk" is just that partition never having been
formatted. No FPGA rebuild was needed — the RBF is unchanged.

The alternative fix is driver-side: the A4091's `ignore_last` setting
(`ms->ignoreLast`) makes the mounter ignore the flag entirely, but it lives in
battmem/NVRAM which the Minimig core does not persist.


## Follow-up 2 (2026-09-07): present RDBFF_LAST per the *current* chain

Rather than editing images (or forking the boot ROM to force `ignoreLast`),
`a4091_scsi.cpp` now fixes the flag up on the read path. Every served READ
that reaches into the first 16 blocks gets `rdb_patch_block()` applied: if the
block starts with `RDSK`, `rdb_Flags` bit 0 is **set for the highest
configured SCSI ID and cleared for every other drive**, and the RDB checksum
is recomputed — in the returned buffer only. The `.hdf` bytes are never
touched, so images stay portable and HDToolBox keeps working.

```c
case 0x08: case 0x28: {                // READ(6/10)
        int got = FileReadAdv(t->f, b, bytes);
        ...
        rdb_fixup_last(t, b, bytes);   // <- new
```

Verified end to end with the *broken* state deliberately restored on disk —
both images set back to `rdb_Flags = 0x17`:

```
scsi: ID1 present (409600 blocks)
scsi: ID2 present (409600 blocks)
scsi: ID1 RDB block 0: RDBFF_LAST cleared (last ID is 2)
```

`info` shows both drives: `DH0.1` (RegrTest) and `SH1` (Test2, 199M R/W).

Notes:

* Write path is deliberately untouched. If AmigaOS ever writes the block back
  (HDToolBox "Save Changes"), what lands on disk is the corrected flag — which
  is what the image should have said anyway.
* The fixup keys off `present` targets, so it re-evaluates whenever the OSD
  image set changes: adding a drive at a higher ID moves the flag automatically.
* `tools/rdb_lastflag.py` is still useful for inspecting or permanently
  correcting an image, but is no longer needed to make multi-drive setups work.

Deployed as `/media/fat/MiSTer` (previous binary kept as
`/media/fat/MiSTer.pre_rdbfix`). Note `inittab` starts MiSTer with `sysinit`,
not `respawn` — `killall MiSTer` frees the busy binary so it can be replaced,
then reboot.


## Follow-up 3 (2026-09-07): fully loaded bus - cloned images collide by volume identity

With all six SCSI IDs populated, only two drive icons appeared on Workbench.
Not a mount failure - `info` showed **all six devices mounted** (`DH0.1`,
`SH1`..`SH5`), and the ARM log confirmed the RDB fixup doing its job as the
chain grew:

```
scsi: ID1 RDB block 0: RDBFF_LAST cleared (last ID is 4)
scsi: ID4 RDB block 0: RDBFF_LAST cleared (last ID is 6)
```

The images for IDs 2-6 were clones of one already-formatted `.hdf`, so every
filesystem carried the same volume **name** *and* the same **creation date** -
which is exactly the pair AmigaOS uses to identify a volume. DOS therefore
treated the five as one volume: `info` printed the same label for every
device, Workbench drew one icon, and a `Relabel` on any of them appeared to
rename all of them.

Fix is Amiga-side, one line per drive:

```
Relabel SH2: Test3      ; SH3: Test4, SH4: Test5, SH5: Test6
```

Each `Relabel` really did write its own image (file mtimes confirm one write
per `.hdf`), but the stale shared volume node hid it until a reboot. After
`C:Reboot` all six volumes are distinct: RegrTest, Test2, Test3, Test4, Test5,
Test6.

**When cloning `.hdf` images, relabel each copy before use** - or partition and
format each one separately, which also gives it its own creation date.


## Milestone (2026-09-07): AmigaOS autoboots from the A4091

IDE disabled, SCSI ID 1 pointed at the 3.2 GB `AmigaOS3.2.hdf`, and the
machine boots AmigaOS 3.2 from the A4091's autoboot ROM - with the other five
drives on the same chain:

```
SYS  ->  DHO:                       ; DF0-3 empty, no IDE hardfile
DH0      3199M  Read/Write  DHO     ; SCSI ID 1
SH1..SH5  199M each                 ; Test2..Test6

devtest -p a4091.device
  1 MiSTer   A4091 HD   0001 Disk  512  3355 MB
  2..6       A4091 HD   0001 Disk  512   209 MB

scsi: ID1 present (6553600 blocks)
scsi: ID1 RDB block 0: RDBFF_LAST cleared (last ID is 6)
```

This supersedes the long-standing bring-up constraint "boot from IDE, the SCSI
drive is a non-bootable data drive at ID 1, never boot from SCSI" - that was a
safety rail for debugging the DMA/SIOP path, and it is no longer needed. The
full ROM path (autoconfig -> DiagArea copy -> romtag -> mounter -> boot) now
works on the combined core.

Note the regression suite still defaults to `--scsivol DH0.1:`, which no longer
exists in this configuration; pass `--scsivol SH1:` (or whichever scratch
volume) when running it against a SCSI-booted setup.
