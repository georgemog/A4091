# A4091 RTL — status

Option A (53C710 in fabric). Files:

| File | What | State |
|---|---|---|
| `a4091.v` | top: Zorro III autoconfig responder, board window decode, boot-ROM BRAM + nibble fan-out, DIP byte, 53C710 register beswap, board bus handshake, DMA-master pass-through, IRQ, `a4091_target` instance | **Phase 1–2 working** |
| `a4091_siop.v` | 53C710: register file, interrupt logic, byte DMA engine, SCRIPTS sequencer (all 4 groups incl. indirect/table-indirect addressing + memory-move copy), SCSI phase engine (MO/CMD/DI/DO/ST/MI), register ALU | **Phase 3 working** |
| `a4091_target.v` | virtual SCSI-2 direct-access device + HPS sector port; DATA OUT flush handshake (`wr_busy`) | **Phase 3 working** |
| `../tb/a4091_tb.v` | iverilog bench, 13 groups | **all pass** |

```
cd A4091/tb && make                       # "==== ALL PASS ===="
cd A4091/tb && make DEFS=-DA4091_DEBUG     # + per-instruction SCRIPTS trace
```

## What works

**Board (Phase 1–2)** — autoconfig ident nibbles + base latch; ROM window
(byte→/4 fan-out); 53C710 register file at `0x800000` with the
`(a&~3)|(3-(a&3))` byte-lane swap; DIP byte at `0x8C0003`; single-cycle bus
handshake; INT2 = `(DSTAT&DIEN)|(SSTAT0&SIEN0)`.

**SCRIPTS engine (Phase 3)** — instruction fetch (big-endian dwords, the 68k
NCR-assembler layout); `DSP[31:24]` write kicks it; runaway guard.
- **Group 0 Block Move** — direct, indirect (`*ptr`), and table-indirect
  (`{count,addr} = *(DSA + s24(offset))`) addressing; phase-match check →
  `SSTAT0.MA` on mismatch; dispatch to the phase engine.
- **Group 1** — Select (+ATN), Wait Disconnect, Set/Clear (ATN, carry), and
  the full register ALU `MOV/SHL/OR/XOR/AND/SHR/ADD/ADC` (opcodes 5/6/7,
  SFBR / immediate / register operands, carry).
- **Group 2 Transfer Control** — Jump / Call / Return / Interrupt, conditions
  on carry, phase compare, and masked-SFBR data compare.
- **Group 3 Memory Move** — 3-dword form, `IID` on non-`0xC0`, byte copy
  `src → dst` for `insn[23:0]` bytes.

**SCSI phase engine** — Select → MSG OUT (IDENTIFY/LUN) → CMD → DATA IN/OUT →
STATUS → MSG IN (COMMAND COMPLETE) → disconnect, all with `SFBR` set per
phase for the driver's branch logic. CON stays asserted for the nexus
(synchronous target, no real disconnect/reselect).

**Virtual target** — TUR, REQUEST SENSE, INQUIRY, MODE SENSE(6),
READ CAPACITY(10), READ(6/10), WRITE(6/10), START STOP. Non-sector responses
generated in-target; READ/WRITE stream sectors over the `sec_*` port
(HPS / `rtl/ide.v`-style block serve). DATA OUT: the SIOP holds STATUS until
the target's HPS flush completes (`wr_busy`). Verified end-to-end: INQUIRY
(direct / indirect / table-indirect moves) and a full 512-byte READ(10) land
byte-correct in the Amiga-RAM model; WRITE(10) bytes reach the HPS stream;
group-3 memcpy verified.

## Known shortcuts / TODO

| Item | Note |
|---|---|
| Wait Reselect | no-op continue — the synchronous model never disconnects, so a script that *unconditionally* waits for reselect just falls through (harmless for the connected path, wrong if a driver hard-assumes a disconnect). Real a4091.device paths TBD. |
| target data buffer read is async | fine for the model / distributed RAM; a BRAM build needs a settle cycle in the DI loop |
| 40/64-bit DMA (`CCNTL1`) | not modelled (A4091 is 32-bit anyway) |
| autoconfig ident bytes | standard A4091 layout, **not yet** reconciled with the a4091-software ROM image |
| disconnect / reselect / tagged queueing | omitted (matches WinUAE `max_lun=0`); NetBSD would exercise it |
| ROM > 32 KB | index is 32 KB (v40.13) only |
| `ncr7xx` self-test (loopback / FIFO / CTEST5) | register-level bits present; full self-test not run on target yet |

Also here: `present[6:0]` input — a Select to an id with no bit set raises
`SSTAT0.STO` (selection timeout), so a core with no HPS server enumerates
cleanly.

## Next

1. ~~`cpu_wrapper.v` integration~~ — **done**, Phase-1 patches in
   `../integration/` (`cpu_wrapper.v` autoconfig chain + Z3 aperture + DMA
   port hijack, `minimig.v` INT2 OR, `Minimig.sv` wire-up). Needs a Quartus
   build on `quartus-host` + hardware bring-up.
2. `a4091_target.v` ↔ real Main_MiSTer HPS block server (`minimig_scsi.cpp`),
   OSD menu, image mount, drive `a4091_present`.
3. Boot ROM: `A4091/rom/make_hex.sh` from the open a4091-software AutoConfig
   ROM; reconcile `AC_*` ident bytes.
4. Bring-up on hardware; run `ncr7xx` / `a4091d`; AmigaOS autoboot from a
   prepared `.hdf`.
5. WinUAE co-sim: diff a SCRIPTS trace (`-DA4091_DEBUG`) against instrumented
   `lsi_execute_script`.
