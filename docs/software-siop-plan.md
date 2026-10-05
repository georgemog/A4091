# A4091 — software 53C710 on the MiSTer ARM (alternative architecture)

Status: **proposal / fallback**. The current path is the all-RTL SIOP
(`a4091_siop.v` + `a4091_target.v` + `a4091_sd.v`). This document describes
moving the 53C710 + SCRIPTS engine + SCSI emulation to the HPS ARM, leaving the
FPGA as a thin Zorro-III ↔ ARM bridge. Cross-reference
[`amiberry-analysis.md`](amiberry-analysis.md) for how WinUAE/amiberry structure
the same emulation.

Adopt this only if the RTL SIOP keeps producing byte-DMA timing bugs after the
DATA-OUT prime (build #74) and the target-buffer fix. It is a ~3-week rebuild
that trades ~4000 lines of working-but-fragile RTL for a mature, debuggable
software model.

---

## 1. Why

### 1.1 The failure mode it removes

The RTL SIOP moves DATA-phase bytes **one at a time** through the d8 engine
(`dma8()` per byte → `D_IDLE → D_WAIT → D_HOLD`), each byte a full round-trip
through `ddram_ctrl` / `sdram_ctrl`'s shared single-FSM DMA port. This has cost
us, in order:

| Build | Bug | Cause |
|---|---|---|
| #64 | status byte / RC10 data lost | same-cycle ACK raced `DDRAM_BUSY` |
| #64→#71 | grey-screen wedge | state-5 park blocked `cache_req` forever |
| #71 | fixed with a 128-cycle timeout | but a timed-out read returns stale data |
| #73 | DATA-OUT drops the first byte | first post-phase-gap d8 read unreliable |
| open | >8-block transfer corruption | `a4091_target` dbuf is 4 KB (8 blocks) |

Every one of these is "byte-serial DMA through a RAM controller that was designed
for occasional 68k cache-line fills." A software model does the DATA phase as a
`memcpy` and the entire class disappears.

### 1.2 What it inherits for free

WinUAE's `qemuvga/lsi53c710.cpp` is a mature 53C710 + SCRIPTS interpreter (from
QEMU, years of use, boots every AmigaOS, passes `ncr7xx` self-test). WinUAE's
`qemuvga/scsi.cpp` is a full SCSI-2 direct-access emulator (INQUIRY, all MODE
pages, READ CAPACITY 10/16, READ/WRITE 6/10/16, FORMAT UNIT, REQUEST SENSE,
TEST UNIT READY, START/STOP, SYNCHRONIZE CACHE, …). The RTL target
(`a4091_target.v`) implements maybe a third of that, by hand.

### 1.3 Debuggability

`printf` + `gdb` on the ARM, instant edit-compile-run (~3 s), vs a ~50-minute
Quartus build per hypothesis. This alone has cost days on the current path.

---

## 2. Architecture

```
   Amiga 68k (TG68 020)                         HPS ARM (Linux, Main_MiSTer)
   ───────────────────                          ───────────────────────────
   a4091.device                                 a4091d thread (new)
     ├ pokes 53C710 regs  ──┐                     ├ lsi53c710.cpp   (SCRIPTS VM)
     ├ writes DSP (kick)     │                    ├ scsi_emulate()  (SCSI-2 disk)
     └ INT2 ISR  ◄───────┐   │                    └ backing store = .hdf via
                         │   │                        FileReadAdv / FileWriteAdv
                         │   │
         ┌───────────────┴───▼──────────────────────────────────┐
         │                     FPGA  (thin bridge)              │
         │  • Zorro-III autoconfig ROM  (unchanged, a4091.v)    │
         │  • shadow 53C710 register file (256 B, dual-port)    │
         │      CPU R/W lands here at Zorro speed, no SPI       │
         │  • "kick" event: DSP[31:24] write → set kick flag    │
         │  • IRQ: ARM sets int_pending → assert a4091_int2     │
         │  • DMA to CHIP / Z2 RAM: the existing sdram_ctrl     │
         │      DMA slot, driven from an ARM mailbox            │
         └──────────────────────────────────────────────────────┘
                         ▲
                         │  Z3 fast RAM lives in HPS DDR — the ARM
                         │  reaches it directly (mmap /dev/mem), no FPGA
```

Key insight: the driver's DATA buffers are **almost always Zorro-III fast RAM**
(the disk driver AllocMems `MEMF_FAST` post-boot; devtest uses `-m Fast`). Z3
fast is physically HPS DDR. The ARM `mmap`s `/dev/mem` at the DDR base + the Z3
offset and does a plain `memcpy` for the DATA phase. Correct by construction,
hundreds of MB/s.

Chip RAM / Zorro-II fast buffers (the autoboot ROM driver's early acb, rare) go
through the existing `sdram_ctrl` DMA slot, now driven by an ARM command instead
of the RTL SIOP.

---

## 3. Register access — the latency question

Naïve "every 53C710 register poke is an SPI round-trip" is too slow: the driver
writes ~15–20 registers to set up each command (DSA, DSP, DCNTL, DMODE, DIEN,
SIEN, SCNTL0/1, SXFER, SCID, SDID, …) and reads ~6 in the ISR (ISTAT, DSTAT,
SSTAT0/2, DSPS, SBCL). At ~2 µs/SPI that is ~50 µs/command — tolerable for
HDToolBox, sluggish for anything bulk.

**Solution: RTL shadow register file.**

- The FPGA holds a 256-byte dual-port RAM = the 53C710 register space.
- CPU reads/writes decode exactly like today (`sel_reg`, `brd_ready`) but land
  in the shadow RAM directly — **zero SPI, Zorro-speed.**
- The ARM reads/writes the shadow RAM as one bulk SPI burst (all 256 bytes, or
  the ~40 that matter) when it needs to.
- Only **one** register write is special: `DSP[31:24]` (offset 0x2F). Writing it
  starts SCRIPTS on real hardware. In the bridge it sets a `kick` flag that the
  ARM polls (or that raises an HPS interrupt if we wire one).

Per-command SPI traffic then:

1. ARM sees `kick` → 1 burst read of shadow regs (DSA, DSP, DCNTL, …).
2. ARM runs SCRIPTS to completion (DMA via DDR memcpy / sdram-slot mailbox).
3. ARM writes back the result regs (DSTAT, DSPS, SSTAT, SBCL, DSA, DNAD, DBC)
   + sets `int_pending`. 1 burst write.
4. RTL asserts `a4091_int2`; the ISR reads the (already-updated) shadow regs at
   Zorro speed and clears `int_pending` by reading ISTAT.

≈ 3 SPI transactions per SCSI command. HDToolBox: a few ms total. Bulk 32 KB
transfer: the memcpy dominates and it's fast.

---

## 4. Implementation phases

### Phase A — RTL bridge (FPGA)  ~3–5 days

Delete `a4091_siop.v`, `a4091_target.v`, `a4091_sd.v` from the build. Keep
`a4091.v` but gut it to:

| Block | Keep / change |
|---|---|
| Zorro-III autoconfig + ROM window | **keep as-is** (already works — geometry/reads prove the bus) |
| `sel_reg` decode + `brd_ready` | keep; retarget the data path to the shadow RAM |
| shadow register RAM | **new** — `dpram #(8, 8) siop_regs [0:255]`, port A = CPU, port B = SPI |
| kick detect | **new** — `wire kick_stb = reg_wr & (reg_addr == 8'h2F)` → sticky flag, cleared by SPI |
| IRQ | **new** — `reg int_pending` set by SPI cmd, cleared by SPI cmd or by CPU reading ISTAT via a side-effect tap; `assign int2 = int_pending` |
| chip/Z2 DMA slot | keep `sdram_ctrl`'s DMA slot; drive `a4091_sdmaAddr/CS/WE/WR` from a new SPI mailbox (0x69 addr, 0x6A data-in, 0x6B data-out) |
| `hps_ext` mailbox | replace 0x64–0x68 with: 0x64 kick-poll, 0x65 shadow-reg burst read, 0x66 shadow-reg burst write, 0x67 set int_pending, 0x68 chip-DMA addr/len, 0x69 chip-DMA data |
| debug window (`dbg_q` @ 0x8D0000) | keep a slimmed version — shadow-reg dump + kick/int flags |

Net RTL change: **~-3500 lines**, +~200. The remaining `a4091.v` is
autoconfig + a register RAM + 3 flags. Low risk — the hard part (Zorro bus
timing, DTACK) is unchanged and already verified.

Timing should *improve* — the byte-DMA critical paths and the 48-state SIOP FSM
are gone.

### Phase B — port `lsi53c710.cpp` to the ARM  ~2–4 days

Source: `WinUAE/src/qemuvga/lsi53c710.cpp` (~2500 lines) + `lsi53c710.h`.
It is QEMU-derived and quite self-contained. Work:

1. **Types.** `uae_u8/16/32/64` → `uint8_t/…`. `TCHAR`/`_T()` → drop.
2. **Memory callbacks.** QEMU version calls
   `pci_dma_read/write(&s->dev, addr, buf, len)`. Replace with:
   ```c
   static void a4091_dma_read (uint32_t addr, uint8_t *buf, int len);
   static void a4091_dma_write(uint32_t addr, const uint8_t *buf, int len);
   ```
   Each: if `addr` in the Z3-fast window → `memcpy` against the DDR mmap
   (with the Z3-base subtract and the 68k↔ARM `0x27FF0000`-style offset — see
   CLAUDE.md memory map); else → chip-DMA mailbox to the FPGA.
   **Endianness:** 53C710 is big-endian on the Zorro bus; the ARM is
   little-endian; DDR holds bytes in Amiga order. The current RTL does
   `beswap (a&~3)|(3-(a&3))`. Do the same byte-swizzle in these two functions
   and it is contained to one place.
3. **IRQ callback.** `lsi_update_irq()` currently pokes a PCI IRQ line.
   Replace with: set a local `irq` bool; the poll loop pushes it to the FPGA
   via the 0x67 mailbox when it transitions.
4. **Register read/write entry points.** `lsi_reg_readb / lsi_reg_writeb`
   already take `(addr, val)`. The poll loop calls these to load the shadow
   regs into the model before running, and to read them out after.
5. **SCRIPTS execution.** `lsi_execute_script(s)` is the main loop. It already
   returns when it hits `INT`, `WAIT DISCONNECT`, a phase mismatch, or a
   host-service point. Call it from the poll loop after a kick.
6. **Strip:** PCI config space, MSI, the QEMU `VMState` serialization,
   `qemu_irq` plumbing. ~300 lines gone.

### Phase C — SCSI device emulation  ~1–4 days

Two options:

- **C1 (fast, ~1 day):** keep the current hand-rolled target logic
  (`a4091_target.v`'s decode table) but reimplemented in C. It already handles
  TUR / INQUIRY / READ CAPACITY 10&16 / READ&WRITE 6&10 / MODE SENSE / REQUEST
  SENSE well enough for HDToolBox. Port the state machine 1:1.
- **C2 (robust, ~4 days):** port `WinUAE/src/qemuvga/scsi.cpp`
  `scsi_emulate_cmd()` (~2000 lines). Full MODE page set, FORMAT UNIT,
  defect lists, the works. This is what makes `ncr7xx` self-test and every
  disk tool pass. Backing store hook = `scsi_read_dma / scsi_write_dma` →
  `FileSeek` + `FileReadAdv / FileWriteAdv` on the mounted `.hdf` (the code
  already in `a4091_sd_poll`).

Recommend C1 first (unblocks HDToolBox), C2 later for completeness.

### Phase D — integration into `Main_MiSTer`  ~1 week

1. New file `a4091_hps.cpp` — the model + poll. Own thread or hooked into
   `user_io_poll()` (thread is cleaner; the model can block on file IO).
2. Boot: on core load, `mmap /dev/mem` at the DDR Z3 window; open the `.hdf`;
   push the autoconfig-visible geometry to the FPGA if needed.
3. Poll loop:
   ```
   for (;;) {
       if (fpga_kick_pending()) {
           load_shadow_regs(&lsi);
           lsi_execute_script(&lsi);      // runs to INT / stop
           store_shadow_regs(&lsi);
           if (lsi.irq) fpga_set_int();
           fpga_clear_kick();
       }
       if (fpga_int_acked()) lsi.irq = 0;
       usleep(50);
   }
   ```
4. The driver's DSP-write is two 16-bit Zorro cycles (regs 2F/2E then 2D/2C).
   Kick only on the 2F write **and** after 2C landed — the RTL already has this
   "`kick_lo_seen`" guard; keep it.
5. `xs->timeout` on the Amiga side: the software model completes a command in
   µs–ms, well inside `SD_IO_TIMEOUT`. No watchdog risk.

### Phase E — bring-up on real HW  (folded into D)

1. Autoconfig still enumerates (unchanged) — verify with `devtest -p`.
2. `devtest -c TUR` → INQUIRY → READ CAPACITY. If geometry reads correct, the
   register + kick + IRQ + DDR-DMA path all work.
3. `devtest -ii 512 -d -y` → integrity write/read. The memcpy makes this exact.
4. `devtest -i 65536 -d -y` → large transfer (no 4 KB buffer any more).
5. HDToolBox: partition, save RDB, format, verify.
6. `ncr7xx` self-test (needs C2).

---

## 5. Risks

| Risk | Mitigation |
|---|---|
| Zorro bus timing from a "software master" — the model can't respond in bus-cycle time | It doesn't have to. The CPU only ever touches the **shadow regs** (RTL, fast). The model runs asynchronously between kicks. DMA is model→DDR, never on the Zorro bus. |
| IRQ latency — ARM sets int_pending ~µs after the command completes | Fine. Real 53C710 interrupt latency to the 68k is comparable; the driver is level-triggered on ISTAT.DIP. |
| Endianness bugs in the two DMA functions | Contained to one place, unit-testable on the ARM against known patterns before touching HW. |
| Chip-RAM DMA path (sdram slot + mailbox) is new and slow | Only the autoboot ROM driver hits it, and we already ship the nodriver ROM. Disk driver → Z3 → DDR fast path. |
| `mmap /dev/mem` Z3 base wrong / moves with core config | Read it from the same place `Main_MiSTer` already computes the DDR layout; assert against a known Z3 write from the Amiga at bring-up. |
| Throwing away working RTL for a regression | Keep the RTL SIOP on a branch. The bridge RTL is small enough to co-exist behind an `O[]` bit during transition. |
| Effort overrun | Phase A + B + C1 + D-minimal ≈ 2 weeks to first HDToolBox. Budget 3–4 for robust. |

---

## 6. Decision criteria

Switch to this plan if **either**:

- The DATA-OUT prime (#74) does not fix the dropped first byte, and the next
  one or two hypotheses also fail — i.e. the byte-DMA path stays whack-a-mole.
- We need >8-block transfers working and the `a4091_target` dbuf rework
  (flow-controlled streaming or `BUFAW=13`) turns out non-trivial.

Stay on the RTL path if:

- #74 lands clean → geometry + read + write all work → only the >8-block
  buffer cap remains, which is a small driver-side `MAX_XFER = 4096` or a
  one-line `BUFAW` bump + `data_off`/`tgt_buf_addr` width check.

---

## 7. Effort summary

| Phase | Work | Days |
|---|---|---|
| A | RTL bridge (strip SIOP, shadow regs, kick, IRQ, chip-DMA mailbox) | 3–5 |
| B | port `lsi53c710.cpp` | 2–4 |
| C1 | SCSI target in C (port current logic) | 1 |
| C2 | port WinUAE `scsi.cpp` (full SCSI-2) | +3 |
| D | `Main_MiSTer` integration + thread + poll | 3–5 |
| E | HW bring-up | folded into D |
| **First HDToolBox** | A + B + C1 + D-min | **~2 weeks** |
| **Robust (self-test, all tools)** | + C2 + polish | **~3–4 weeks** |
