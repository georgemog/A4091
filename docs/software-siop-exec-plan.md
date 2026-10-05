# A4091 software SIOP — execution plan

Companion to [`software-siop-plan.md`](software-siop-plan.md) (the design /
rationale). This file is the concrete build order: branch, PRs, file changes,
open questions, verification.

Decided 2026-09-06: **new branch, RTL SIOP replaced (no O[]-bit coexistence).**
`minimig_20260905_A4091_displit.rbf` is the stopgap core on the box meanwhile.

---

## Source material (all on the build box `build-host`)

| File | Lines | Use |
|---|---|---|
| `/opt/development/WinUAE/qemuvga/lsi53c710.cpp` | 2505 | the 53C710 + SCRIPTS interpreter to port (Phase B) |
| `/opt/development/WinUAE/qemuvga/lsi53c710.h` | — | its state struct / regs |
| `/opt/development/WinUAE/qemuvga/qemuuaeglue.h` | — | `pci710_dma_rw(dev,addr,buf,len,dir)` — the ONE memory hook, and the QEMU type shims |
| `/opt/development/WinUAE/scsi.cpp` | — | full SCSI-2 device emulator (Phase C2) |
| `/opt/development/WinUAE/ncr_scsi.cpp` | — | WinUAE's own A4091 board glue — reference for wiring the 710 to a board |
| `A4091/rtl/a4091_target.v` | 317 | the hand-rolled SCSI target to port 1:1 for Phase C1 |
| `a4091-software` `a4091.device` | — | unchanged — the Amiga driver already talks to a real 53C710 register model |

`lsi53c710.cpp` routes **every** guest-memory access through
`pci710_dma_rw(PCIDevice*, addr, buf, len, dir)` (~10 call sites, all via the
`pci710_dma_read/write` inlines). That function is the entire porting seam for
the DATA path.

---

## Branch

```
git checkout -b claude/a4091-software-siop        # off the current branch (has the P1 fix + stopgap + all journal/issues history)
```

The RTL SIOP (`a4091_siop.v`, `a4091_target.v`, `a4091_sd.v`) stays intact on
the current branch. On the new branch it is deleted from the Quartus file list
in Phase A; the `.v` files can stay in the tree (unreferenced) for one release
so the diff is reviewable, then be removed.

---

## Phase A — RTL bridge (FPGA)   target: 3–5 days, 1–2 PRs

Gut `a4091.v` to autoconfig + ROM + a register RAM + 3 flags. The hard,
already-verified part (Zorro-III bus timing, DTACK, autoconfig enumeration,
ROM window) is **unchanged**.

### A.1 — new `a4091_bridge.v` (replaces siop+target+sd)

| Block | Detail |
|---|---|
| shadow register RAM | `reg [7:0] siop_regs [0:255]` — dual-port. Port A = CPU (`sel_reg` decode, exactly today's `brd_ready`/`brd_dout` path, retargeted from the SIOP net to this RAM). Port B = `hps_ext` burst. CPU R/W lands here at Zorro speed, **zero SPI**. |
| kick detect | `wire kick_stb = reg_wr & (reg_addr == 8'h2F)` (DSP[31:24]); keep the existing `kick_lo_seen` two-write guard from `a4091_siop.v` so a kick only fires after the low DSP byte (0x2C) also landed. Sticky `kick_pending`, cleared by an `hps_ext` command. |
| IRQ | `reg int_pending`, set by `hps_ext`; `assign a4091_int2 = int_pending`. Cleared by `hps_ext`, or by a CPU read of ISTAT (side-effect tap on `reg_rd & reg_addr==0x21`) — match real 53C710 (reading ISTAT with DIP clears it). |
| chip / Z2 DMA | keep `sdram_ctrl`'s existing a4091 DMA slot (`a4091_sdmaCS/Addr/WE/WR`, and the ddram_ctrl `dma*` port). Drive both from a new `hps_ext` mailbox instead of the SIOP. Bulk moves are ARM→DDR memcpy; this path is only chip/Z2-fast bounce buffers. |
| debug window `0x8D0000` | slim to: shadow-reg dump + `kick_pending` / `int_pending` + a small event counter. Drop the SIOP/ring/rc10 fields. |

### A.2 — `hps_ext.v` mailbox redesign

Replace the a4091 commands `0x64`–`0x69` with:

| cmd | dir | payload |
|---|---|---|
| `0x64` | FPGA→HPS | poll: `{kick_pending, int_acked, dma_req, ...}` |
| `0x65` | FPGA→HPS | burst read shadow regs (256 B, or the ~40 that matter) |
| `0x66` | HPS→FPGA | burst write shadow regs |
| `0x67` | HPS→FPGA | set `int_pending` / clear `kick_pending` |
| `0x68` | HPS→FPGA | chip-DMA request: `{addr[23:1], len, we}` |
| `0x69` | bi | chip-DMA data in/out (streamed) |

Geometry push (old `0x69` per-ID) is gone — the ARM owns geometry now (it has
the `.hdf` sizes). The 6-ID OSD/config work stays: the ARM reads
`minimig_config.scsi[0..5]` and answers READ CAPACITY per selected target from
its own table.

### A.3 — Quartus project

- Remove `a4091_siop.v`, `a4091_target.v`, `a4091_sd.v` from `files.qip`; add
  `a4091_bridge.v`.
- `a4091_tb.v` — replace the SIOP/target bench with a small bench that pokes
  the shadow regs, asserts `kick`, checks `int2` + burst read-back. The SCSI
  correctness bench moves to the ARM side (host unit tests, Phase B/C).
- Expect timing to **improve** — the 48-state SIOP FSM and the byte-DMA
  critical paths (incl. today's `sdram_ctrl` `sd_addr` congestion from the
  DMA-slot 4th priority tier) are gone.

### A.4 — bring-up (RTL only, no ARM model yet)

Autoconfig still enumerates (`devtest -p` from the stopgap driver). A tiny ARM
stub that just echoes shadow regs + never kicks proves the register path is
Zorro-speed and the burst mailbox works.

---

## Phase B — port `lsi53c710.cpp` to the ARM   target: 2–4 days

New file in Main_MiSTer: `support/minimig/a4091_lsi.cpp` (+ `.h`), the ported
2505-line interpreter.

1. **Types.** `uae_u8/16/32/64` → `uint8_t/16/32/64`; `TCHAR`/`_T()` dropped;
   `PCIDevice*` → an opaque `void*` or a small local struct.
2. **The one memory hook.** Implement:
   ```c
   int a4091_dma_rw(void *dev, uint32_t addr, void *buf, uint32_t len, int to_device);
   ```
   - `addr` in the **Z3-fast window** → `memcpy` against the `/dev/mem` DDR
     mmap. Subtract the Z3 base, apply the 68k↔ARM offset (CLAUDE.md memory
     map: Amiga `0xDDxxxx` ↔ ARM `0x27FFxxxx` pattern; Z3 fast base is
     computed by Main_MiSTer's DDR layout — **OPEN Q1**).
   - else (chip / Z2-fast) → `0x68`/`0x69` mailbox to the FPGA `sdram_ctrl`
     slot.
   - **Endianness:** 53C710 is big-endian on the Zorro bus, ARM is LE, DDR
     holds Amiga-order bytes. The RTL did `beswap (a&~3)|(3-(a&3))`. Do the
     same swizzle here, contained to this one function. Unit-test on the ARM
     against known patterns before HW.
3. **IRQ hook.** `lsi_update_irq()` → set a local `bool irq`; the poll loop
   pushes transitions via `0x67`.
4. **Register entry points.** `lsi_reg_readb/writeb(s, offset, val)` already
   exist — the poll loop calls them to load the shadow regs into the model
   before `lsi_execute_script`, and to read them back after.
5. **Strip:** PCI config space, MSI, QEMU `VMState` serialization, `qemu_irq`.
   ~300 lines.
6. **Host unit test** (`a4091_lsi_test`, x86 or ARM): feed a canned READ(10)
   SCRIPTS program + a fake target, assert the DMA buffer contents. This is
   the regression net the RTL never had.

---

## Phase C — SCSI device emulation

### C1 (first, ~1 day) — port `a4091_target.v` decode to C

`support/minimig/a4091_scsi.c`. The RTL target's `T_DECODE` table 1:1:
TUR / INQUIRY / READ CAPACITY 10&16 / READ&WRITE 6&10&16 / MODE SENSE&SELECT /
REQUEST SENSE / FORMAT UNIT (→ done, like `a4091_target OP_FORMAT`) / START-STOP
/ SYNCHRONIZE CACHE. Backing store: `FileSeek` + `FileReadAdv/FileWriteAdv` on
`a4091_f[id]` — the code already in `minimig_a4091.cpp`'s `a4091_sd_poll`.
Per-ID geometry from `minimig_config.scsi[0..5]`.

### C2 (later, +3 days) — port WinUAE `scsi.cpp` `scsi_emulate_cmd()`

Full MODE page set, defect lists, the works — what makes `ncr7xx` self-test and
every disk tool pass. Do after C1 unblocks HDToolBox.

---

## Phase D — Main_MiSTer integration   target: 3–5 days

1. `support/minimig/minimig_a4091.cpp` rewritten: drop the sector-server /
   `a4091_sd_poll` mailbox loop; keep `a4091_apply_config()` (opens the 6
   `.hdf`s, now feeds the C-side target table, no FPGA geometry push).
2. New `a4091_hps_thread()` — own thread (model can block on file IO):
   ```
   mmap /dev/mem @ DDR Z3 window   (once, on core load)          // OPEN Q1
   for (;;) {
       if (kick_pending()) {                                     // 0x64 poll
           load_shadow_regs(&lsi);                               // 0x65 burst
           lsi_execute_script(&lsi);                             // runs to INT
           store_shadow_regs(&lsi);                              // 0x66 burst
           if (lsi.irq) set_int();                               // 0x67
           clear_kick();                                         // 0x67
       }
       if (int_acked()) lsi.irq = 0;
       usleep(50);
   }
   ```
3. `user_io.cpp` — replace the `a4091_sd_poll()` call with thread start/stop.
4. `xs->timeout` (Amiga side): the model completes in µs–ms, well inside
   `SD_IO_TIMEOUT`. No watchdog risk. The RTL SCRIPTS watchdog is gone.

---

## Open questions (resolve as they gate a phase)

| # | Question | Gates | Approach |
|---|---|---|---|
| Q1 | Exact `/dev/mem` offset for the Z3-fast base in HPS DDR, and whether it moves with core config | Phase B step 2, Phase D step 2 | read from the same place `Main_MiSTer` computes the DDR layout; assert at bring-up against a known Z3 write from the Amiga (have the driver poke a marker, read it via mmap) |
| Q2 | Does `a4091.device` ever point DSP at code in **chip** RAM (not just data buffers)? | whether the chip-DMA mailbox needs to be fast | grep the driver; the plan assumes SCRIPTS + DSA are in fast RAM post-boot |
| Q3 | `lsi53c710.cpp` `SCSIDevice`/`scsi_req_*` coupling — how much of the QEMU SCSI bus layer comes with it | Phase B strip list | read lsi53c710.cpp lines 500–650, 750–900 |
| Q4 | Kick latency: poll `0x64` at 50 µs vs wire a real HPS IRQ from the FPGA | throughput under many small I/Os | start with poll; measure; add IRQ only if HDToolBox feels sluggish |
| Q5 | ARM toolchain has C++11 + threads for the port (it does — `minimig_netd` uses both) | Phase B | confirmed by CLAUDE.md build notes |

---

## Verification ladder (each phase gates the next)

1. **A** — `devtest -p` enumerates (autoconfig unchanged); ARM stub echoes shadow
   regs; burst mailbox round-trips 256 B.
2. **B** — host unit test: canned READ(10) SCRIPTS + fake target → DMA buffer
   byte-exact. Endianness swizzle unit-tested separately.
3. **B+C1+D-min on HW** — `devtest -c TUR` → INQUIRY → READ CAPACITY (geometry
   correct = register + kick + IRQ + DDR-DMA all work).
4. `devtest -i 512k -d -y -l 400 -m Fast` → **200 MB, 0 errors** (the exact test
   `S_DI16` failed — the memcpy makes it correct by construction).
5. `devtest -i 16m -d -y` → single large transfer, no 16 KB cap any more.
6. Full `Format DRIVE SH0: NAME Test FFS` → 3008 cyl clean.
7. HDToolBox: partition, save RDB, low-level format, verify.
8. **C2** — `ncr7xx` self-test passes.
9. Throughput: `devtest -b -B 512k,4 -m Fast` → target **> 10 MB/s** (vs 0.7
   today); ceiling is `.hdf` read off SD/USB.
10. Boot still lands on IDE DH0; SCSI drives are non-boot data drives; warm
    `C:Reboot` remounts.

---

## Rough sequencing

| PR | Content | Verify |
|---|---|---|
| 1 | branch; `a4091_bridge.v` (shadow RAM + kick + IRQ); `hps_ext.v` mailbox; Quartus file list; stub tb | ladder 1 |
| 2 | chip-DMA mailbox in bridge + `sdram_ctrl` wiring | mailbox loopback |
| 3 | `a4091_lsi.cpp` port + host unit test | ladder 2 |
| 4 | `a4091_scsi.c` (C1) + `minimig_a4091.cpp` rewrite + thread + poll loop | ladder 3–6 |
| 5 | HW bring-up fixes; Q1 resolution | ladder 3–6 on real box |
| 6 | `scsi.cpp` port (C2) | ladder 7–8 |
| 7 | throughput measurement + tuning (IRQ if needed) | ladder 9 |
| 8 | delete the unreferenced RTL SIOP `.v` files; strip debug | ladder 10 |

First HDToolBox ≈ PRs 1–5 (~2 weeks). Robust ≈ +6–8 (~3–4 weeks).
