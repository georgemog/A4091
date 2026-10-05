# A4091 SCSI for the Minimig-AGA MiSTer core

Emulation of the Commodore/DKB **A4091**, a Zorro III Fast SCSI-2 host adapter
built around the NCR 53C710 SCSI I/O Processor. It runs in the
[Minimig-AGA_MiSTer](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer) core on
a DE10-Nano. AmigaOS sees a real A4091: the stock-compatible
[a4091-software](https://github.com/A4091/a4091-software) driver autoboots from
the board ROM and runs unchanged. Up to six SCSI targets are backed by `.hdf`
images on the MiSTer's storage.

> **Status (2026-10):** working on real MiSTer hardware. AmigaOS 3.2 autoboots
> from SCSI ID 1. Six drives probe, mount and carry distinct volumes. HDToolBox
> low-level format and `Format` both work. The 9-test hardware regression passes.
> Measured with `devtest -b`: read **8.5 MB/s**, write **4.2 MB/s**, which is in
> the range of a real A4091 in an A4000.
>
> **Not yet upstream.** The core integration in [`core/combined/`](core/combined/)
> is a patch against `rtg-z3-graphics-card`, a development branch of
> Minimig-AGA_MiSTer that adds a Zorro III RTG graphics board (see
> [The RTG branch](#the-rtg-branch-zorro-iii-graphics-card)). The tested core
> therefore carries three boards: A4091 + Z3 RTG + A2065. Porting the A4091
> alone onto current upstream `Minimig-AGA_MiSTer` / `Main_MiSTer` is the
> next step. See [Roadmap](#roadmap).
>
> **Ready-to-build core:** the full combined tree (A4091 + Z3 RTG + A2065,
> validated on hardware) is on the
> [`minimig-core`](https://github.com/georgemog/A4091/tree/minimig-core) branch.
> The RTG-only tree is on
> [`rtg-z3-graphics-card`](https://github.com/georgemog/A4091/tree/rtg-z3-graphics-card).

## How it works: a "software SIOP"

```
 Amiga 68k ── Zorro III ──► a4091.v / a4091_bridge.v (FPGA)
                             • AutoConfig (mfr 514 / prod 84), 16 MB window
                             • boot ROM (a4091-software, baked into the RBF)
                             • 256-byte shadow 53C710 register file
                             • "kick" on DSP write, INT2 to Paula
                                     │  hps_ext mailbox 'h64–'h68 (SPI)
                                     ▼
                         Main_MiSTer on the ARM (HPS)
                             • minimig_a4091.cpp: kick poll, IRQ, memory seam
                             • a4091_lsi.cpp: 53C710 + SCRIPTS VM (port of
                               WinUAE/QEMU lsi53c710)
                             • a4091_scsi.cpp: SCSI-2 disk target on .hdf files
                                     │  DATA phase = memcpy into HPS DDR
                                     ▼
                Z3 fast RAM (physically HPS DDR) — the guest's DMA buffers
```

The first attempt put the whole 53C710 in RTL (see [`legacy/`](legacy/)). It
worked in simulation and partly on hardware, but its 16-bit DMA path kept
corrupting data. Moving the SIOP to the ARM removed that whole class of bugs.
The FPGA is now a thin bridge with no bus master. The full story is in
[`docs/JOURNAL.md`](docs/JOURNAL.md), newest first.

## Repository layout

Branches:

| Branch | What |
|---|---|
| `main` | This project: docs, ARM-side code, ROM recipe, tools, patches |
| [`minimig-core`](https://github.com/georgemog/A4091/tree/minimig-core) | Full Minimig-AGA_MiSTer tree with A4091 + Z3 RTG + A2065, ready for Quartus. It is upstream history through `b265a3b` (Release 20260823), then the 3 RTG commits, then the combined A4091 commit = `rtg-z3-graphics-card` + `core/combined/a4091-on-rtgz3.patch` + `rtl/` |
| [`rtg-z3-graphics-card`](https://github.com/georgemog/A4091/tree/rtg-z3-graphics-card) | Only the Zorro III RTG board, on upstream `b265a3b` |

On `main`:

| Path | What |
|---|---|
| [`rtl/`](rtl/) | FPGA side: `a4091.v` (AutoConfig, board window, boot ROM, bridge instance), `a4091_bridge.v` (shadow regs, kick, IRQ, debug bus), `a4091_rom.mif` (boot ROM image for Quartus) |
| [`main_mister/`](main_mister/) | ARM side: new `support/minimig/` files plus `main_mister_swsiop.patch` for `menu.cpp`, `user_io.cpp`, `minimig_config.{cpp,h}`. Base `Main_MiSTer@915ca33` |
| [`core/combined/`](core/combined/) | Core integration as a patch (`cpu_wrapper.v`, `minimig.v`, `Minimig.sv`, `hps_ext.v`, `files.qip`), build recipe, hardware results |
| [`rom/`](rom/) | Boot-ROM recipe: `make_hex.sh` and the Minimig-specific `driver-patches/` against `a4091-software@a199fa8` |
| [`tools/`](tools/) | Host and Amiga helpers: `mmcfg.py` (enable `O[57]` in `minimig.cfg`), `rdb_lastflag.py`, `aserial.py` (drive the Amiga shell over serial), small SCSI exercisers, the `a4091dbg` / `peek` diagnostics |
| [`tools/tests/`](tools/tests/) | `swsiop_regress.py` (hardware regression, runs on the MiSTer) and `ddrmap_test.c` (host unit test) |
| [`docs/`](docs/) | Design notes, plans, the WinUAE/amiberry analysis, `ISSUES.md`, and the full `JOURNAL.md` |
| [`legacy/`](legacy/) | The superseded all-RTL 53C710 and the original `eb7a26e`-era patch set, kept for reference |

## Building

**Boot ROM / driver.** Check out `a4091-software` at `a199fa8`, apply
`rom/driver-patches/`, then `make DEVICE=A4091 a4091.rom`. Convert the result with
`rom/make_hex.sh` to `rtl/a4091_rom.mif`. Full recipe:
[`rom/driver-patches/README.md`](rom/driver-patches/README.md).

**FPGA core.** Quartus 17.0 Lite. Easiest is to build the
[`minimig-core`](https://github.com/georgemog/A4091/tree/minimig-core) branch
as-is. Alternatively, apply the core patch to `rtg-z3-graphics-card` and copy
`rtl/*` to `rtl/a4091/`. Recipe and timing notes:
[`core/combined/README.md`](core/combined/README.md).

**Main_MiSTer.** Copy `main_mister/*.{cpp,h}` into `support/minimig/` and
`git apply main_mister/main_mister_swsiop.patch`. Then build with the usual
ARMv7 toolchain. See [`main_mister/README.md`](main_mister/README.md).

## Using it

1. Enable the board with OSD option `O[57]`. The board needs the 68020 CPU
   setting, because Zorro III requires a 32-bit address bus. Until the OSD item
   lands upstream, `tools/mmcfg.py --a4091 minimig.cfg` sets the bit. Reload the
   core afterwards.
2. In the OSD "A4091 SCSI" section, assign `.hdf` images to IDs 1–6.
3. Boot. The ROM installs `a4091.device` and mounts RDB partitions. With IDE
   disabled, AmigaOS autoboots from the SCSI disk.

Z3 fast RAM must be enabled. The ARM side currently assumes it sits at
`$40000000` (see [Known limitations](#known-limitations)).

### Runtime files

Prebuilt Amiga binaries are attached to the
[Releases](../../releases) page instead of committed:

| File | Goes to | What |
|---|---|---|
| `a4091.rom` | (baked into the RBF) | Autoboot ROM with the driver, md5 `978f7ac9037cb0bdf80e953bdb408340` |
| `a4091_nodriver.rom` | — | ROM without the embedded driver, for debugging with a `DEVS:` copy |
| `a4091.device` | `DEVS:` (optional) | v42.39. Only needed to override the copy in the ROM |
| `devtest`, `ncr7xx`, `a4091d`, `A4091.guide` | anywhere | a4091-software tools and manual |
| `a4091dbg`, `peek`, `scsi_fmt` | anywhere | this project's diagnostics, with sources in `tools/` |

## The RTG branch (Zorro III graphics card)

The only integration tested on hardware so far,
[`core/combined/a4091-on-rtgz3.patch`](core/combined/a4091-on-rtgz3.patch),
applies to **`rtg-z3-graphics-card`**, not to upstream. That branch is a
separate piece of work on Minimig-AGA_MiSTer. It gives the core's existing RTG
framebuffer a real Zorro AutoConfig identity.

**Why it exists.** Upstream's RTG decodes at fixed addresses, and the P96 driver
finds it without AutoConfig. That leaves the OS with no `ConfigDev` for the
board. Without one, a 68030/040 PMMU cannot build correct page descriptors for
the framebuffer. The branch makes the board a genuine, dynamically placed
Zorro III device.

**Base and commits.** It sits on upstream `b265a3b` (Release 20260823), which
already includes the A2065:

| Commit | Change |
|---|---|
| `13ed7a8` | RTG as two real Zorro II AutoConfig boards: regs+CLUT, and the framebuffer at `$200000` |
| `4308734` | Fix the framebuffer physical-offset math for a real `cd_BoardAddr`. The pass-through decode had rotated the 8 MB window by +2 MB, so the CPU and the ARM video scanout disagreed about where offset 0 was |
| `02eff9c` | Replace both with **one Zorro III board**, current state |

**The board** (`02eff9c`):

| | |
|---|---|
| Ident | mfr `0x139C`, product `0x30`, "Rok Krajnc Minimig Z3 GraphicsCard", 16 MB |
| Board offset `0`–`$7FFFFF` | 8 MB framebuffer in DDR3, decoded in `memory_router.v` (`sel_rtg`). Like the Z3 FastRAM board, it uses a 128 MB-granularity base compare |
| Board offset `$800000`–`$80FFFF` | 64 KB regs + CLUT. This is upstream's `fastchip.v` `rtg` block, reached by widening `cpu_wrapper.v`'s `fastchip_sel` |
| Files touched | `rtl/cpu_wrapper.v` (`ac_rtg` chain link), `rtl/memory_router.v`, `rtl/chipdma_arb.v`, `rtl/fastchip.v`, `rtl/gary.v`, `extra/rtg_driver/MiSTer.card.asm` |
| Amiga driver | The Zorro III `MiSTer.card` does `FindConfigDev(0x139C, 0x30)`. The stock card from the Minimig archive will **not** find this board |

On hardware the RTG-only build shows the board in `showconfig`. The test
pattern, P96 800×600×8 and the mouse pointer all work. In the combined core,
the RTG registers and framebuffer read back byte-exact. Nobody has yet watched
the monitor switch to the RTG framebuffer there (`core/combined/RESULTS.md`).

**Interaction with the A4091: AutoConfig order matters.** The branch puts the
RTG board *before* the Z3 FastRAM board in the chain. That pushes FastRAM from
`$40000000` to `$50000000`. The A4091's ARM side hardcodes the FastRAM base,
so every DMA buffer then falls outside its window. The board still enumerates,
but the SCSI probe finds nothing. The combined patch therefore moves `ac_rtg`
after `ac_memcard[2]`. The resulting chain is CDTV → Z2 RAM → Toccata → A2065
→ Z3 RAM → RTG → A4091. Two more things to know:

* RTG decodes on a 128 MB base, split by `cpu_addr[26:23]`. A board placed in
  the same 128 MB block at `[26:23] == 1` would collide with the regs window.
  AmigaOS's board-size alignment avoids this today.
* The A4091 is safe only as the last link, because of its 8 MB declared /
  16 MB decoded quirk.

**Availability.** The branch is published here as
[`rtg-z3-graphics-card`](https://github.com/georgemog/A4091/tree/rtg-z3-graphics-card).
The combined result is
[`minimig-core`](https://github.com/georgemog/A4091/tree/minimig-core). To build
it, clone that branch and run `quartus_sh --flow compile Minimig` (Quartus 17.0
Lite). The tree carries `SEED 1`. The
upstream A4091 port in the [Roadmap](#roadmap) has no RTG dependency at all.
Upstream has no `ac_rtg`, so the A4091 just follows the Z3 RAM board.

## Known limitations

* **Z3 RAM base hardcoded.** `minimig_a4091.cpp` maps `$40000000` → HPS
  `0x30000000`. If AutoConfig order or the RAM configuration moves Z3 RAM, the
  board still enumerates, but the probe finds no drives. The fix is to export the
  real base from the FPGA.
* **AutoConfig size.** The board declares 8 MB but decodes 16 MB. This is
  harmless only while the A4091 is last in the chain.
* **One command at a time**, no disconnect/reselect. Fine for AmigaOS.
* **Debug logging** writes to `/media/usb0/` when `/media/usb0/a4091_debug` exists.
* Write throughput is limited by per-command SPI round trips and file writes,
  not by the SCSI side.

Details and history: [`docs/ISSUES.md`](docs/ISSUES.md).

## Roadmap

1. Port the core patch onto current upstream `Minimig-AGA_MiSTer` (`MiSTer`
   branch), A4091 only, off by default. Then open a PR.
2. Rebase `main_mister/` onto current `Main_MiSTer` master. Upstream has
   appended config fields since `915ca33`, so move the SCSI fields to the new
   tail. Then open a PR.
3. Fix the Z3-base hardcode and the AutoConfig size byte. Make the debug log
   path configurable.
4. Upstream the driver tweaks to `a4091-software` as a build option, so the ROM
   builds from upstream.
5. Propose the Z3 RTG board (`rtg-z3-graphics-card`) upstream on its own.

## Credits and licence

* NCR 53C710 model: QEMU `lsi53c895a` (Paul Brook / CodeSourcery, LGPL),
  adapted to the 710 by **Toni Wilen** for WinUAE and carried in
  [amiberry](https://github.com/BlitterStudio/amiberry). `a4091_lsi.cpp` is a
  port of that code.
* Driver and boot ROM: [A4091/a4091-software](https://github.com/A4091/a4091-software)
  by **Chris Hooper** and **Stefan Reinauer** (BSD). It includes the mounter by
  Toni Wilen, Stefan Reinauer and Matt Harlum.
* Minimig-AGA MiSTer core and Main_MiSTer: the MiSTer-devel contributors (GPL-3.0).

This project's own code is **GPL-3.0-or-later** ([`LICENSE`](LICENSE)).
Third-party terms, including the notices that must accompany the boot ROM binary,
are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
