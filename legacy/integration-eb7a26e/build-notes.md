# A4091 test build — Quartus server (quartus-host)

Base: `Minimig-AGA_MiSTer` branch `MiSTer` @ `eb7a26e` ("Release 20260603").
Quartus Prime 17.0.0 Lite, `/opt/altera/17.0`, Cyclone V.
Build dir: a `git worktree` off the release branch + the 4 patches + `rtl/a4091/*.v`.

## Result — build #2 (with `Minimig.sdc.patch`) — **TIMING MET**

| Stage | Outcome |
|---|---|
| Analysis & Synthesis | **0 errors**, 98 warnings |
| Fitter | **0 errors**, 9 warnings |
| Assembler | **0 errors** → `Minimig.rbf` (3,502,436 B) |
| Timing Analyzer | **0 errors** — **setup +0.086, hold +0.253** |

Per-clock setup slack (all positive, TNS 0.000 everywhere):

| Clock | Slack |
|---|---|
| `pll_hdmi counter[0]` (HDMI pixel) | +0.086 |
| `emu\|pll counter[0]` = **clk_114** (SDRAM ctrl, A4091 DMA target) | **+0.351** |
| `emu\|pll counter[1]` = **clk_sys** 28.6875 MHz | +0.779 |
| FPGA_CLK2_50 / h2f_user0 / spi_sck / FPGA_CLK1_50 / pll_audio | +3.6 … +14.9 |

The A4091 multicycle constraint cleared the DMA violation; the `clk_114`
domain that carries the A4091 DMA→SDRAM path is now **+0.351** (the −0.115
`cpu_cache` path seen in the STA-only recheck was placement variance — gone
on a fresh fit). Worst path is now the stock HDMI pixel clock, +0.086.

Resources: 23,020 / 41,910 ALMs (55 %), 29,531 registers, 240 / 553 RAM
blocks (43 %). `dbuf` (A4091 4 KB data buffer) + the boot-ROM BRAM are the
A4091 memory cost.

RBF copied to `A4091/build/Minimig_a4091_20260828.rbf`.

### Follow-up (not a build blocker)

Quartus reports several 53C710 registers "assigned but never read" that the
CPU-side readback path *should* read — `dsps`, `scratch`, `dcmd`, `sstat1`.
The read path is a Verilog `function rreg()` in the `default:` arm of the
register-read `case`. The sim bench reads these fine (G5/G6/G10 read DSPS via
the CPU port), so either Quartus isn't recognising the function-based read or
something is being pruned. Convert `rreg()` to an explicit flattened `case`
in the CPU-read block, or verify on hardware with `a4091d` that DSPS reads
back after a SCRIPTS interrupt.

## Result — build #1 (RTL only, no SDC change)

| Stage | Outcome |
|---|---|
| Analysis & Synthesis | **0 errors**, 98 warnings |
| Fitter | **0 errors**, 9 warnings |
| Assembler | **0 errors** → `Minimig.rbf` (3.49 MB) |
| Timing Analyzer | 0 errors — **setup slack −1.395 ns (VIOLATED)** |

### Warnings (A4091), all benign

- `a4091_siop.v`: ~15 × "register assigned a value but never read"
  (`scntl0`, `sdid`, `scid`, `sxfer`, `sodl`, `sidl`, `dcmd`, `dwt`, `lcrc`,
  `current_lun`, `select_id`, `ctest5-7`, `dsps`, `scratch`) — 53C710
  registers the driver writes but nothing reads back yet. Quartus optimizes
  them away.
- width-truncation warnings on intentional `x + {N'd0, small}` address math.
- `msg[1..7] has no driver` — the synchronous MSG-IN path only ever sends one
  byte (COMMAND COMPLETE).
- `dbuf` inferred as block RAM with read-during-write pass-through — expected.

### Timing violation — cause + fix

All 4 violated paths were the A4091 DMA:

```
From: cpu_wrapper|a4091_inst|siop|dma_req  (and dma_addr[16])   [clk_sys, 28.6875 MHz]
To:   sdram_ctrl:ram1|sd_addr[7], sd_addr[8]                     [clk_114, 114.75 MHz]
Data Delay 10.3 ns, relationship 8.808 ns -> slack -1.395
```

`Minimig.sdc` already multicycles the CPU→RAM crossing:

```
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst*} -to {emu|ram*} -setup 2 / -hold 1
```

but the `-from` pattern (`cpu_inst*`) only matches the TG68 / fx68k cores, not
the A4091 DMA master. The A4091 DMA holds its address/req stable across
clk_114 cycles while it waits for `ramready` — the **same contract as the
CPU** — so the same multicycle is correct. Added
(`Minimig.sdc.patch`):

```
set_multicycle_path -from {emu|cpu_wrapper|a4091_inst|*} -to {emu|ram*} -setup 2
set_multicycle_path -from {emu|cpu_wrapper|a4091_inst|*} -to {emu|ram*} -hold 1
```

STA re-check on the same fitted netlist: worst A4091 path clears; new worst
becomes **−0.115 ns** in `ddram_ctrl|ram2|cpu_cache_new` — a **stock**
Minimig 68020-cache path on the razor-thin `clk_114` domain (matches the
documented "`clk_114` … SDRAM ctrl on `clk_114` is razor-thin" baseline of
this core), **not** A4091. Build #2 re-fits with the SDC fix to confirm the
A4091 additions leave the baseline unchanged.

## Apply order (for a real build)

```
git apply cpu_wrapper.v.patch minimig.v.patch Minimig.sv.patch Minimig.sdc.patch
mkdir -p rtl/a4091 && cp <A4091>/rtl/a4091{,_siop,_target}.v rtl/a4091/
# files.qip: 3 VERILOG_FILE lines after the rtl/cpu_wrapper.v line
quartus_sh --flow compile Minimig
```

## Hardware bring-up — 2026-08-28

`minimig_20260828_A4091.rbf` on real MiSTer + Amiga. With OSD `O[57]` set
(via `A4091/tools/mmcfg.py --a4091 minimig.cfg`, then core reload) AmigaOS
`showconfig`:

```
Commodore (West Chester) A 4091 SCSI:   Prod=514/84($202/$54)
    (@$50000000, size 8MB, subsize same)
```

Autoconfig works — mfg 514, product 84, correct chain position (after
Toccata + Z3 RAM).

- **size 8 MB, not 16** — `a4091.v` `AC_TYPE` er_Type[2:0]=000. Harmless: the
  `cpu_wrapper` aperture is the full `cpu_addr[31:24]==base` (16 MB), the
  register window at base+0x800000 still decodes, nothing else claims
  base+8..16 MB. Fix the ident bytes (+ reconcile all `AC_*` with the
  a4091-software ROM) in a later build.
- `.cfg` edit only lands on **core reload** (`echo load_core … > /dev/MiSTer_cmd`),
  not an Amiga `reboot`.

Next: `ncr7xx` / `a4091d` register + beswap test on silicon.

## Build #4 — 2026-08-28 (register-window handshake fix)

`ncr7xx -r` on hw read block-0 (16 regs, values sane, beswap confirmed) then
**hung on the first longword read** (`DSP`/`DSPS`/`TEMP`/`DNAD` as `%08x`).
Root cause: `brd_ready` sticky-busy latch never re-armed for the 2nd half of
a held-brd_sel burst -> permanent CPU stall. Fixed (commit `4dec97e4`,
tb G14). Rebuilt:

| Stage | Outcome |
|---|---|
| Full Compilation | **0 errors** |
| Timing | setup **+0.026** (HDMI pixel clk), **clk_114 +0.068**, clk_sys +0.779, hold +0.247 |

clk_114 slack thinner than build #3 (+0.351) — placement/seed variance on
the stock razor-thin domain, not A4091 (A4091's clk_114 path is just the DMA
multicycle). Still positive, TNS 0.000. If it regresses further: pin a seed
or relax the composite (`yc_out`) / HDMI path.

RBF md5 `fd65fea0c8b58239a752e250ffdcd21f`.
