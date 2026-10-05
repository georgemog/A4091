# How MacLC_MiSTer handles SCSI — and what it says about the A4091 boot hang

Reviewed: `github.com/danifunker/MacLC_MiSTer` + `github.com/danifunker/Main_MiSTer`
(2026-08-29). MacLC emulates a Mac LC: 68020 + an **NCR 5380** SCSI controller,
booting System 6/7 off `.hda`/`.img` hard-disk images. Same shape as the A4091:
*real vendor disk driver ↔ SCSI-controller RTL ↔ HPS-served 512 B blocks.*
MacLC has bled through this exact class of bug for months; their write-ups are
the best available playbook.

---

## 1. Transport (how blocks reach the core)

| Path | Mechanism |
|---|---|
| **Hard disk / plain images** | stock `hps_io` `sd_*` virtual-drive slots (`VDNUM 4`, slots 0-3). Works because MacLC is **not** `is_minimig()` — Main_MiSTer's generic `UIO_SECTOR_RD/WR` poll loop runs for it. |
| **CD-ROM (CHD / CUE)** | `hps_ext.v` cmds `0x61`/`0x62` — a "task-file / management channel" — plus `support/maclc/maclc_cd.cpp` in Main_MiSTer (`libchdr` decode → normalized 2048 B sectors). *"Phase 2 did NOT need the feared EXT_BUS bridge."* |
| **BlueSCSI Toolbox (file share)** | a **dedicated isolated VD slot** (`VD_TOOLBOX = 3`) + a request/status/data block contract, handler in `support/maclc/`. |

**Takeaway for A4091:** our option-1 (`hps_ext` cmd `0x64`-`0x67` + `a4091_sd_poll()`
in `user_io.cpp`) is the *same* pattern MacLC uses for CD/Toolbox — because
`is_minimig()` also skips the generic loop. The transport is not the problem.
MacLC also proves the "dedicated slot, zero regression to the disk path" and
"gate everything on `img_mounted` so a stock HPS degrades cleanly" disciplines.

---

## 2. The hang class — MacLC's "Welcome to Macintosh" == our AmigaOS boot hang

From `port_scsi_fixes_prompt.md`, `docs/scsi_byteslip_2026-06-10.md`,
`docs/SCSI_CMD_GAPS.md`. MacLC could not boot System 7 (hung at "Welcome") and
occasionally corrupted disks. Root causes, in order of relevance to us:

### 2.1 Allocation-length over-serve deadlock  *(prime suspect for A4091)*
> targets served INQUIRY / REQUEST SENSE for the **raw allocation length**
> instead of `min(alloc, actual)`. When the Mac's mount scan transfers fewer
> bytes than alloc, the target **holds REQ forever with leftover bytes** and the
> Mac spins polling the controller for a phase change.

The enforced invariant (both LBMacTwo fix commits): **a response serves exactly
what its own length fields promise, clamped by the allocation length — and the
DATA phase ENDS there, advancing to STATUS.** Never hold REQ for more than the
initiator asked for; never REQ past what you have.

Concrete MacLC fixes: INQUIRY additional-length `32→31` (true 36-byte response);
MODE SENSE(6) clamped to 12 with mode-data-length header byte = 11 (was 0);
`alloc == 0 → 4`; **undo any `0 → 256` mapping of READ/WRITE(6) allocation
lengths**; zero-length transfers must *complete* (`data_done`), not flush a stale
buffer.

**A4091 status:** `a4091_target.v` *does* clamp `resp_len` for INQUIRY / REQUEST
SENSE / MODE SENSE. But the deadlock lives one level up — in the **SIOP phase
engine**: a `MOVE n, WHEN DATA_IN` transfers `dbc` bytes (from the driver's
SCRIPTS); the target has `rsp_len` bytes. If `dbc != rsp_len` the phase never
ends cleanly. `S_DIA` already checks `data_rem == 0 || dbc == 0` → good, but
verify it fires for *every* exit and that `set_phase(PH_ST)` is actually
observed by the driver's next phase-branch.

### 2.2 Completion-IRQ latch — the System 7 fix  *(prime suspect for A4091)*
`rtl/ncr5380.sv` (LBMacTwo `b760944`):
> Starting a DMA transfer arms a phase-mismatch monitor. While armed, a
> **FALLING edge of phase-match latches IRQ** — this is how drivers detect that a
> pseudo-DMA transfer ended (target moved to STATUS). Reading reg 7 clears it.
> The driver often clears DMA mode *just before* the phase change; the old
> `MR.DMA_MODE`-gated latch dropped the IRQ and the HD SC 4.3 async path **slept
> on a completion that never came (`ParamBlockRec.ioResult` never cleared).**

And, `scsi_byteslip` §1-2:
> `o_irq` was dangling and `pseudovia.sv` had **no SCSI inputs**, so the driver
> sleeps on IFR flags that could never set. FIXED: level-driven `scsi_irq` /
> `scsi_drq` inputs (assert sets, deassert clears). **Why LEVEL, never edge:**
> the edge model deadlocks — the latched IRQ from the previous chunk holds the
> line, no new edge fires at the next chunk boundary, the poll sleeps forever.

**A4091 status:**
- INT2 delivery is fine: `paula_intcontroller.v` does `intreq[3] <= tmp[3] | int2`
  — **level-sensitive**, re-triggers while asserted. Not the MacLC edge-miss bug.
- `assign irq = (dstat & dien) | (sstat0 & sien0)` — a level. OK.
- **The gap:** does the SIOP actually *raise* `irq` at the point the
  a4091.device's async path sleeps on? The a4091.device (NetBSD `siop.c`
  lineage) runs SCRIPTS chunk-by-chunk and its ISR wakes the I/O on the
  53C710's **SCRIPTS-INT** and **phase-mismatch** interrupts. Our SIOP fires
  the INT for *hand-written* tb SCRIPTS (G5-G8 pass) but has **no
  phase-mismatch interrupt** — if the real SCRIPTS end a `MOVE` early (target
  switched phase before `dbc` hit 0) the driver expects `DSTAT`/`SSTAT` +
  interrupt + a stop; we just keep running. → SCRIPTS desync → the final INT
  is never reached → `ioResult` never set → task sleeps forever → boot hangs.

### 2.3 Every command must COMPLETE
> 12-byte (group-5) CDBs never completed, which **hung the target on ANY such
> command — a latent bus wedge.**

Unknown / unsupported opcode → **CHECK CONDITION + STATUS**, never a stall.
`a4091_target.v` has a `default:` → CHECK path; make sure the SIOP side also
can't spin on a CDB length / group it doesn't decode.

### 2.4 Selection requires a free bus
> selection requires `!bus_busy` — real SCSI cannot select while BSY is
> asserted. (Fixes a stale-buffer corruption class.)

Minor for us (virtual bus, single target) but cheap to honour.

### 2.5 Truthful status bits for polled drivers
`BSR.IRQ` = the latch, `BSR.EODMA` = "bus not in data phase" (was constant 0).
Polled drivers read these between chunks. **A4091 analog:** `DSTAT` / `SSTAT0/1/2`
/ `ISTAT` bit-exact behaviour — the a4091.device polls `ISTAT`/`DSTAT` when not
using interrupts. Audit `rreg()` for `0x0c`/`0x0d`/`0x0e`/`0x0f`/`0x21` against
the 53C710 datasheet and amiberry.

### 2.6 Byte-slip (buffer even/odd pairing)
MacLC's multi-sector WRITEs landed "one foreign byte inserted mid-stream, rest
shifted +1". Root cause: even/odd byte capture keyed on `data_cnt[0]` parity
racing the dpram write edge. We hit the *same* class in `a4091_sd` / `hps_ext`
(the `blk_wr` / `b_wr` pipeline offsets). Their fix: capture on the *even* beat,
pair explicitly, never rely on parity + timing.

---

## 3. MacLC's method (worth copying)

1. **Instrumentation gated by `SIMULATION`** — `NCR_STALL` printer (dumps
   req/ack/dreq/dma_en/pmatch/phase when the bus is idle too long),
   `SCSI_WR_OVERRUN`, `NCR_WR_PHASE_MISMATCH`, `dbg_ring` / `dbg_ring2` /
   `dbg_probes.sv` — a whole 32-bit debug bus surfaced to JTAG / a probe window.
2. **Oracle sources** — they diff their FSM against **two** references:
   BlueSCSI-v2 firmware (`BlueSCSI_cdrom.cpp` etc.) and the **Snow** Mac
   emulator (`core/src/mac/scsi/`). For A4091 the oracles are **amiberry
   `src/qemuvga/lsi53c710.cpp`** (already in `A4091/ref/`) and the
   **a4091-software** driver source.
3. **Forensic disk-diff** — `hda_match_sources.py` classifies changed sectors
   as COPY / SHIFT±d / legit-churn against a pristine image. Caught the
   byte-slip precisely.
4. **Field-test corrections in the doc** — e.g. "M0 detection must ALSO be
   gated on `tb_ready`; leaving it pure-RTL hangs the client on close."

---

## 4. Recommended A4091 next steps (revised by this review)

Priority order — the hang is almost certainly 2.1 + 2.2:

1. **Instrument the SIOP.** Expose `st`, `dsp[31:0]`, `dbc[23:0]`, `dcmd`,
   `sstat2[2:0]` (phase), `dstat`, `dma_addr`, `dma_req` in unused board debug
   space (e.g. `0x8C0010..`) or spare SCRATCH — readable over serial *after*
   the watchdog lets boot survive. One hardware run then shows exactly which
   `dsp` / phase it stops at.
2. **Fix the watchdog to actually deliver.** On expiry set a `DSTAT` bit that
   the driver has enabled in `DIEN` (log what the driver writes to `DIEN` —
   likely `0x35`: HD|SIR|ABRT|BF). Also force `dma_req` low + a
   `d8`-engine reset so `a4091_dma_active` drops and the CPU un-stalls
   (the SIOP-FSM watchdog alone can't clear a stuck `d8` DMA).
3. **Add a phase-mismatch interrupt.** When a `MOVE` (`S_DIA`/`S_DOA`) ends
   because the target changed phase before `dbc == 0`: set the phase-mismatch
   bit (`SSTAT0`/`DSTAT` per datasheet), `S_STOP`, raise `irq`. The NetBSD
   driver's SCRIPTS are *built around* this interrupt.
4. **Clamp + end every DATA phase** at `min(dbc, target_len)` and verify
   `set_phase(PH_ST)` is what the driver's next phase-branch reads.
5. **Trace against amiberry.** Run the a4091.device probe in amiberry with
   `lsi53c710` logging → capture the exact SCRIPTS instruction stream +
   phase sequence → match the SIOP to it. This is the highest-signal step and
   mirrors how MacLC used Snow/BlueSCSI.

MacLC took ~15 documented sessions to get disk I/O solid. Budget accordingly;
the SIOP fidelity gap (real driver SCRIPTS vs our hand-SCRIPT-tuned engine) is
the core of it.
