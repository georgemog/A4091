# A4091 on MiSTer (Minimig-AGA) — implementation plan

Derived from the amiberry / WinUAE model ([`amiberry-analysis.md`](amiberry-analysis.md)).

---

## 0. Target and scope

**Deliverable:** the Minimig-AGA MiSTer core exposes a Zorro III NCR 53C710 DMA
SCSI-2 host adapter (A4091) that AmigaOS autoboots from, with up to 7 virtual
SCSI targets backed by `.hdf` / `.iso` images on the SD card.

**In scope:** direct-access (disk) targets, autoboot, HDToolBox / RDB,
read+write, `ncr7xx` self-test pass, CD-ROM (nice-to-have).

**Out of scope (initially):** real synchronous SCSI timing, tape, LUN > 0
(WinUAE itself doesn't do LUNs), physical SCSI passthrough.

**Gate:** Zorro III needs a full 32-bit address bus → only enabled in
'020+/TG68030 mode. Hide the feature otherwise.

---

## 1. Phase 0 — recon of the actual core (do this first)

The submodule dirs (`Minimig-AGA_MiSTer/`, `Main_MiSTer/`) are **empty in this
worktree**. Everything below assumes a full checkout. Before any RTL, answer:

| Question | Where to look |
|---|---|
| Any AutoConfig support today? (Minimig fast RAM may be hard-wired, not autoconfig'd) | `gary.v`, `minimig.v`, `expansion*.v`, `$E80000` decode |
| Does the CPU path already carry full 32-bit addresses in '030 mode? | `cpu_wrapper.v` (CLAUDE.md shows `cpu_addr[31:16]` already used for `sel_dd/sel_net`) |
| SDRAM arbiter structure — how many masters, how to add one | `sdram.v` / `sdram_ctrl*.v`, the chipset/CPU arbitration FSM |
| How is the existing Minimig HDD image mounted & sector-served by HPS? | Main_MiSTer `support/minimig/`, `user_io`, the `hdd`/`img` SPI/mailbox protocol; Minimig `gayle.v` / hdd fifo |
| How are INT2/INT6 injected from outside Paula? | `paula.v` interrupt inputs, `minimig.v` top |
| Lightweight HPS↔FPGA bridge window layout (network bridge at `$DD6000+`, ARM `0x27FF….`) | CLAUDE.md memory map, `cpu_wrapper.v`, Platform Designer `.qsys` |
| DE10 SDRAM vs DDR3 — where does Amiga chip/fast RAM physically live? | `sys/` + `sdram.v`; **critical** — decides whether HPS can DMA Amiga RAM directly (it cannot if RAM is in FPGA-attached SDRAM) |

Output of Phase 0: a one-page integration map + a go/no-go on "HPS can touch
Amiga RAM". That single answer picks the architecture.

---

## 2. Architecture options

### Option A — 53C710 in RTL, HPS serves blocks  *(recommended)*

```
 Amiga CPU ──Z3 slave──► a4091.v ── SCRIPTS VM ── SCSI phase FSM ── virtual targets
                            │                                          │
                            ├── DMA master ──► SDRAM arbiter ──► Amiga RAM
                            └── INT2 ──► paula.v                        │
                                                              sector req/data
                                                                        │
                                                       HPS: .hdf/.iso on SD (reuse
                                                       Minimig hardfile/img service)
```

- DMA stays FPGA-side (where Amiga RAM is). No new real-time HPS daemon.
- SCSI target data path = the pattern MiSTer already uses for every HDD.
- Most faithful; best perf.
- Cost: ~1500–2500 lines of Verilog (SCRIPTS VM + phase FSM + DMA + target model).

### Option B — WinUAE C on HPS, thin FPGA  *(fast prototype)*

- Port `ncr_scsi.cpp` + `lsi53c710.cpp` + `scsi.cpp` to an ARM daemon,
  like `minimig_netd`.
- FPGA provides only:
  1. Zorro III autoconfig + ROM window.
  2. 53C710 register window — **forwarded to HPS**, Amiga CPU wait-stated
     (`DTACK` held) until the daemon answers. Register traffic is setup-only
     and cold, ~tens of accesses per command → a few µs stall each is fine.
  3. A **DMA mover block**: HPS posts `{dir, amiga_addr, len}` over the
     lightweight bridge; FPGA bursts to/from a bounce buffer in bridge RAM
     that HPS reads/writes. Plus INT2 line driven by HPS.
- Con: every SCRIPTS instruction fetch is an 8-byte DMA. Single-stepping that
  over the bridge is slow. Mitigation: FPGA **sequential prefetch** of
  `dsp`-region dwords into a FIFO the daemon drains; flush on non-sequential
  `dsp`. Random table-indirect pointer fetches and the data payload use the
  explicit mover.
- Reuses thousands of lines of debugged code. Good for bring-up and as the
  golden co-sim oracle. Replaceable by Option A later without changing the
  Amiga-visible behaviour.

### Option C — everything on HPS incl. direct Amiga-RAM DMA

Only viable if Phase 0 says HPS can `mmap` Amiga RAM. For an SDRAM-backed
Minimig it can't → **rejected** unless proven otherwise.

**Recommendation:** build Option B first to get a booting system and a
reference trace, then implement Option A as the shipping core. If schedule is
tight, Option B can ship.

---

## 3. FPGA design — `a4091.v` (Option A)

### 3.1 Zorro III autoconfig responder

- Ident: manufacturer **514**, product **84**, `ERT_ZORROIII`, 16 MB,
  ROM-vector present (autoboot). Byte values pulled from the ROM image
  (bytes `0x00-0x1F` / `0x40-0x5F`), exactly as WinUAE does, or hard-coded.
- Respond to nibble reads in `$00E8_0000` config space; on base-address write
  latch `board_base` and switch to "configured": claim
  `[board_base, board_base + 0x0100_0000)`.
- Handle the Z3 "shut up" (`0x4C`) path.
- **New RTL for Minimig** — verify nothing like it exists in Phase 0.

### 3.2 Board slave decode (configured)

| Offset | Region | Behaviour |
|---|---|---|
| `0x000000..0x7FFFFF` | Boot ROM | read-only, from BRAM |
| `0x800000..0x87FFFF` | 53C710 regs | `addr & 0x3F`, **beswap** `(a&~3)|(3-(a&3))`, byte access, generate `DTACK` |
| `0x8C0003` | DIP byte | `{~settings[4:0], scsi_id[2:0] inverted? }` per §2.4 of analysis (low 3 bits **not** inverted) |

### 3.3 Boot ROM

- 32 KB (or 64 KB) image, loaded by HPS at core start into BRAM.
- Store **raw** and do the nibble fan-out in the read mux
  (`byte b → {b|0x0f, 0xff, (b<<4)|0x0f, 0xff}` for `a[1:0] = 0..3`), or
  pre-expand in HPS and store ×4. Raw + mux saves BRAM.
- ROM source: open [a4091-software](https://github.com/A4091/a4091-software)
  AutoConfig ROM (redistributable). User-supplied `391592-02` as an option.

### 3.4 53C710 core

**Register file:** 64 bytes, the map in `amiberry-analysis.md` §3.
Writing `DSP[31:24]` (`0x2f`) with `DMODE.MAN=0` kicks the sequencer.

**SCRIPTS sequencer FSM:** port `lsi_execute_script()`:
- states: `FETCH` (2 dwords via DMA, byteswap), `DECODE`, one exec state per
  group, back to `FETCH` unless `waiting` / single-step / interrupt.
- Group 0 block-move: direct / indirect / table-indirect address forms;
  phase-match check → `SSTAT0.MA` on mismatch.
- Group 1: select / wait-disc / wait-resel / set / clear, and the
  `MOV/SHL/OR/XOR/AND/SHR/ADD/ADC` register ALU (carry in `carry`).
- Group 2: jump/call/return/interrupt with carry / phase / masked-SFBR
  conditions; `temp` holds the call return address.
- Group 3: memory-move (`DCMD==0xC0` only), else `DSTAT.IID`.
- runaway guard (insn counter → forced UDC).

**SCSI phase FSM:** port `lsi_do_command / _dma / _status / _msgin / _msgout`,
`lsi_set_phase`, selection, `SFBR`, message decode. **Start single-nexus**
(one outstanding command, no disconnect) to cut scope; add disconnect/reselect
+ tag queue in Phase 4.

**DMA master:** one port into the SDRAM arbiter.
- used for: SCRIPTS fetch, table-indirect `{count,ptr}` fetch, CDB fetch,
  data-in/out payload, memory-move.
- byte-addressable, arbitrary 32-bit address; SCRIPTS dwords are little-endian
  in RAM → byteswap on fetch only (data payload is byte-stream, no swap).
- burst sizing is a tuning knob vs CPU/chipset starvation (see risks).

**Interrupt:** `lsi_update_irq` logic → single INT2 line into `paula.v`.
`ISTAT.DIP/.SIP`, `DSTAT&DIEN`, `SSTAT0&SIEN0`.

**Diagnostics:** loopback (`CTEST4.SLBE`+`SCNTL1.ADB`), 8-entry SCSI FIFO,
`SSTAT1.PAR`, `CTEST5.ADCK/.BBCK` strobes — required for `ncr7xx` to pass.

### 3.5 Virtual SCSI targets

Per configured target, a small SCSI-2 direct-access model. Minimum command set
for a bootable RDB hardfile:

`TEST UNIT READY` · `INQUIRY` · `REQUEST SENSE` · `READ CAPACITY(10)` ·
`READ(6)` · `READ(10)` · `WRITE(6)` · `WRITE(10)` · `MODE SENSE(6)` (pages
0x03/0x04 geometry) · `START STOP UNIT` · `VERIFY` (as TUR) ·
`READ DEFECT DATA` (empty).

Data blocks come from HPS (§3.6). Contingent-allegiance / unit-attention
handling as in `scsi.cpp` (`handle_ca`).

Could also be done as a tiny HPS helper if the FPGA command decode gets ugly —
FPGA keeps SCRIPTS + phase, HPS answers CDBs. Decide during Phase 3.

### 3.6 HPS block backend

Extend the existing Minimig hardfile/img service with **N SCSI slots**:
- OSD: assign image file per target, read-only flag.
- request path: FPGA target model emits `{slot, lba, count, dir}`; HPS
  seeks the file, streams sectors into the FPGA DMA FIFO (reads) or drains
  it (writes).
- reuse whatever sector-transfer primitive Gayle/IDE already uses; do **not**
  invent a new bridge if one exists.

---

## 4. Main_MiSTer / HPS software

- OSD menu block: `A4091 enable`, 7 × `SCSI unit N = <file>`, `SCSI host ID`,
  `Fast bus`, `Delayed autoboot`, `Sync`, `Termination`, `LUN` (mirror the
  WinUAE `a4091_settings`).
- ROM handling: bundle / fetch the open AutoConfig ROM; allow user override.
- Persist assignments in the core's config the same way Minimig persists
  `ext_cfg` bits (see the `minimig-extcfg-menu-mechanism` note).
- Image mount / unmount / flush; write-protect honouring.

---

## 5. Phased delivery

| Phase | Content | Done when | State |
|---|---|---|---|
| **0** | Recon (§1). Integration map, arbiter plan, RAM-location answer. | Document written; architecture chosen. | **done** → [`integration.md`](integration.md) (branch `MiSTer` @ `6fc0d5e`) |
| **1** | Z3 autoconfig board + ROM window only. No SCSI. | Board shows in `ShowConfig`; ROM readable; `$E80000` latch + Z3 aperture + `DTACK` proven. | **RTL + TB pass**; **core patches written** ([`integration/`](integration/)) — `cpu_wrapper.v` / `minimig.v` / `Minimig.sv`, apply clean; needs Quartus build + hw test |
| **2** | 53C710 register file + `beswap` + DIP + INT2. No SCRIPTS. | `ncr7xx` register / loopback / FIFO / CTEST5 tests pass. | **RTL + TB pass**; wired via the Phase-1 patches; on-target `ncr7xx` pending build |
| **3** | SCRIPTS VM + DMA master + single-nexus phase FSM + 1 HPS-backed disk. | Prepared `.hdf` autoboots AmigaOS 3.1/3.2. | **RTL + TB pass** — all 4 SCRIPTS groups, phase engine (MO/CMD/DI/DO/ST/MI), register ALU, virtual SCSI-2 target (INQUIRY/READ(10)/WRITE(10)/…); end-to-end nexus verified in sim. On-target autoboot pending Phase-1 `cpu_wrapper.v` wiring. Indirect addressing, memory-move copy, disconnect/reselect still TODO ([`rtl/STATUS.md`](rtl/STATUS.md)) |
| **4** | Multi-target, disconnect/reselect, tag queue, write, RDB/HDToolBox, CD-ROM. | Fresh AmigaOS install to a blank image via HDToolBox; multiple units mount. | not started |
| **5** | Perf tuning (DMA burst vs arbiter), regression vs WinUAE traces, OSD polish, docs. | Throughput acceptable; no chipset/CPU regression; `git-bug` issues closed. | not started |

Option B can substitute for Phases 2–3 as a prototype and stay as the
co-simulation oracle.

---

## 6. Validation

- **Golden reference:** amiberry/WinUAE with the *same* ROM and *same* `.hdf`.
  Instrument `lsi_execute_script` / `scsi_emulate_cmd` to log
  `(dsp, insn, phase, cdb, lba, len)`; diff against an equivalent RTL trace
  (SignalTap or a Verilator testbench).
- **`ncr7xx`** and **`a4091d`** from a4091-software on the target.
- **OS matrix:** AmigaOS 3.1 / 3.2 autoboot, HDToolBox partition+format,
  optionally NetBSD-amiga installer (exercises disconnect/reselect hard).
- **Verilator bench** for `a4091.v`: feed hand-assembled SCRIPTS programs,
  check register/DMA effects against the C model compiled as a library.

---

## 7. Risks

| Risk | Mitigation |
|---|---|
| Minimig has **no Z3 autoconfig** → all new RTL, config-space corner cases | Phase 1 in isolation; crib from MiSTer cores that do Z3 (e.g. Minimig forks, or the AoR/rtg patches) |
| A4091 needs "**Buster -11**" behaviour; breaks on A3640 fast-ROM timing | Emulated Buster is ideal; document the '030-mode gate; don't claim A3640 parity |
| **Third DMA master** regresses CPU/chipset timing (user has documented CPI / arbiter sensitivity in the 68030 work) | Tunable burst length; measure Dhrystone / chipset DMA before+after; give DMA lowest priority slot |
| **68030 data cache** vs DMA'd buffers | `a4091.device` issues `CacheClearE`; FPGA DMA writes SDRAM directly (CPU cache separate) — verify TG68030 cache model actually snoops or that the driver's flushes suffice |
| **beswap / SCRIPTS-endian** wiring bugs (classic 53C710 failure mode) | co-sim harness in Phase 2/3 before touching real SCSI |
| Disconnect/reselect + tagged queue complexity | single-nexus in Phase 3, defer to Phase 4; NetBSD is the stress test |
| ROM licensing | open a4091-software AutoConfig ROM; `391592-02` user-supplied only |
| HPS block latency stalls SCRIPTS during data phase | prefetch / double-buffer sectors in the FPGA FIFO; SCRIPTS `waiting` state already models this |

---

## 8. Reference material to keep in `A4091/ref/`

- `ncr_scsi.cpp`, `lsi53c710.cpp`, `scsi.cpp`, `qemuuaeglue.h`,
  `expansion.cpp` (a4091 entry), `rommgr.cpp` (ROM DB) from amiberry.
- [A4091/a4091-software](https://github.com/A4091/a4091-software) — open ROM,
  `a4091.device` (NetBSD 53C710 core), `ncr7xx`, `a4091d`.
- NetBSD `sys/dev/ic/siop*` / `oosiop*` — independent 53C710 reference.
- NCR 53C710 Data Manual (register + SCRIPTS reference).
- [amiga.resource.cx/exp/a4091](http://amiga.resource.cx/exp/a4091) — DIP map,
  autoconfig IDs, Buster-11 note.
