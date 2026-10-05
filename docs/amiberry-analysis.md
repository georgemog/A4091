# amiberry / WinUAE A4091 — how it works

Reference commit: `BlitterStudio/amiberry` master, Aug 2026 clone.
The A4091 shares almost all code with the other NCR 53C710 boards; only the
autoconfig / address-map / ROM wrapper is A4091-specific.

---

## 1. Board registration

`src/expansion.cpp`:

```c
{
    _T("a4091"), _T("A4091"), _T("Commodore"),
    NULL, ncr710_a4091_autoconfig_init, NULL, a4091_add_scsi_unit,
    ROMTYPE_A4091, 0, 0, BOARD_AUTOCONFIG_Z3, false,
    NULL, 0,
    false, EXPANSIONTYPE_SCSI,
    0, 0, 0, false, NULL,
    true, 0, a4091_settings
},
```

`a4091_settings` (DIP switches, exposed in the GUI):
Fast Bus · Delayed autoboot · Synchronous mode · Termination · LUN.

`src/rommgr.cpp` ROM DB: `A4091 v40.4` (id 240), `v40.9` (id 57),
`v40.13` (id 58, `391592-02`). 32768-byte images.

Autoconfig IDs (from hardware DB): manufacturer **514** (or 513 on an early rev),
product **84**, board type **Zorro III**.

---

## 2. Board glue — `src/ncr_scsi.cpp`

### 2.1 Constants

```
BOARD_SIZE         0x1000000   (16 MB Z3 window)
A4091_ROM_SIZE     0x10000     (rom buffer alloc = SIZE*4, nibble-expanded)
A4091_ROM_OFFSET   0x0000
A4091_IO_OFFSET    0x00800000  (53C710 registers)
A4091_IO_ALT       0x00840000  (mirror)
A4091_IO_END       0x00880000
A4091_DIP_OFFSET   0x008c0003  (DIP switch byte)
```

### 2.2 `struct ncr_state`

One per board. Fields that matter: `rom`, `acmemory[128]` (autoconfig space),
`baseaddress`, `board_mask`, `configured`, `rom_start/end/offset`,
`io_start/end/mask`, `irq`, `irq_func`, `devobject.lsistate` (the SIOP),
`scsid[8]` (SCSI targets), `scsibus`.

### 2.3 `ncr710_a4091_autoconfig_init(aci)`

1. Read the ROM file (`ROMTYPE_A4091`). **Nibble expansion** — the physical ROM
   is byte-wide but wired to the top data nibble during autoconfig, so each
   source byte `b` is stored as 4 bytes:
   ```
   rom[i*4+0] = b | 0x0f;        // high nibble -> D31..D28
   rom[i*4+1] = 0xff;
   rom[i*4+2] = (b << 4) | 0x0f; // low  nibble -> D31..D28
   rom[i*4+3] = 0xff;
   ```
2. The autoconfig bytes are lifted straight out of the ROM image:
   ROM bytes `0x00..0x1F` → `autoconfig_raw[i*4+0]`,
   ROM bytes `0x40..0x5F` → `autoconfig_raw[(i-0x40)*4+2]`.
   (i.e. the board's ident data lives in the diag ROM, standard CBM scheme.)
3. `rom_start=0`, `rom_offset=0`, `rom_end=0x800000`,
   `io_start=0x800000`, `io_end=0x880000`, `io_mask=0x3f`.
4. `ncr->bank = &ncr_bank_generic`.

### 2.4 Address decode (post-config, `board_mask = 0x00FFFFFF`)

| Board offset | Meaning | Handler |
|---|---|---|
| `0x000000..0x7FFFFF` | Boot ROM (only low ~64 KB real) | `read_rombyte()` |
| `0x800000..0x87FFFF` | NCR 53C710 registers, `& 0x3f`, mirrored | `ncr710_io_bget/bput` → `lsi710_mmio_read/write` |
| `0x840000` | register mirror | same |
| `0x8C0003` | DIP switch byte | inline in `ncr_bget2` |

DIP byte:
```c
v2  = rc->device_id;              // bits [2:0] = SCSI host ID
v2 |= rc->device_settings << 3;   // bits [7:3] = board options
v2 ^= 0xff & ~7;                  // invert everything except the low 3 bits
```

### 2.5 Autoconfig write handling

Z3 path in `ncr_wput` at unconfigured offset `0x44`:
```c
map_banks_z3(bank, expamem_board_pointer >> 16, BOARD_SIZE >> 16);
ncr->board_mask  = 0x00ffffff;
ncr->baseaddress = expamem_board_pointer;
ncr->configured  = 1;
expamem_next(bank, NULL);
```
(`0x4c` = shut-up. Z2 boards in the same file use `0x48/0x4a/0x4c`.)

### 2.6 Register endianness — `beswap()`

```c
static uaecptr beswap(uaecptr addr) { return (addr & ~3) | (3 - (addr & 3)); }
```
The little-endian 53C710 is wired big-endian on the 68k bus: byte lane `n`
within each aligned longword is swapped to `3-n` before hitting the SIOP
register file. Every `lsi710_mmio_read/write` goes through `beswap`.

### 2.7 Bus-master DMA — `pci710_dma_rw()`

```c
while (len-- > 0) {
    if (dir == TO_DEVICE) *p++ = dma_get_byte(addr++);
    else                   dma_put_byte(addr++, *p++);
}
```
`dma_get_byte/put_byte` (`memory.cpp`) = plain `get_byte/put_byte` into the
full Amiga address space, honouring `ABFLAG_NODMA`. The SIOP is a true bus
master at arbitrary 32-bit addresses (chip RAM, Z2/Z3 fast RAM, …).

### 2.8 Interrupt

`irq_func = set_irq2` → `safe_interrupt_set(IRQ_SOURCE_NCR, unit, false)` =
**autovector level 2 (INT2)**. `ncr_rethink()` re-levels it each cycle.
(The real board can jumper INT2/INT6; the emulation is INT2 only.)

### 2.9 SCSI unit wiring

`a4091_add_scsi_unit(ch, ci, rc)` → `ncr_add_scsi_unit(&ncra4091[...], ch, ci,
rc, newncr=false)` → `lsi710_scsi_init` + `lsi710_scsi_reset`, then
`add_scsi_hd / add_scsi_cd / add_scsi_tape` allocate a `SCSIDevice` per target.

---

## 3. The SIOP — `src/qemuvga/lsi53c710.cpp`

`LSIState710` holds the register file. 53C710 register map (from
`lsi_reg_readb2 / writeb2`, `io_mask 0x3f` = 64 bytes):

| Off | Reg | Off | Reg | Off | Reg | Off | Reg |
|----|------|----|------|----|------|----|------|
| 00 | SCNTL0 | 10-13 | DSA | 20 | DFIFO | 30-33 | DSPS |
| 01 | SCNTL1 | 14 | CTEST0 | 21 | ISTAT | 34-37 | SCRATCH |
| 02 | SDID | 15 | CTEST1 | 22 | CTEST8 | 38 | DMODE |
| 03 | SIEN | 16 | CTEST2 | 23 | LCRC | 39 | DIEN |
| 04 | SCID | 17 | CTEST3 | 24-26 | DBC | 3a | DWT |
| 05 | SXFER | 18 | CTEST4 | 27 | DCMD | 3b | DCNTL |
| 06 | SODL | 19 | CTEST5 | 28-2b | DNAD | | |
| 07 | SOCL | 1a | CTEST6 | 2c-2f | DSP | | |
| 09 | SIDL | 1b | CTEST7 | | | | |
| 0a | SBDL | 1c-1f | TEMP | | | | |
| 0b | SBCL | | | | | | |
| 0c | DSTAT | | | | | | |
| 0d | SSTAT0 | | | | | | |
| 0e | SSTAT1 | | | | | | |
| 0f | SSTAT2 | | | | | | |

Writing `DSP[24:31]` (offset `0x2f`) with `DMODE.MAN=0` **starts SCRIPTS**.
`DCNTL.STD` with `DMODE.MAN=1` single-steps.

### 3.1 SCRIPTS interpreter — `lsi_execute_script()`

Loop: `insn = read_dword(dsp); addr = read_dword(dsp+4); dsp += 8;`
(`read_dword` byteswaps — SCRIPTS is stored **little-endian** in Amiga RAM.)
Dispatch on `insn[31:30]`:

**Group 0 — Block Move.** `dbc = insn & 0xFFFFFF`. Addressing:
direct / indirect (`insn[29]`, `addr = *addr`) / table-indirect
(`insn[28]`, fetch `{count,ptr}` from `dsa + sext24(addr)`).
Phase check against `SSTAT2[2:0]`; mismatch → `SSTAT0.MA` interrupt.
Then by phase: `PHASE_DO/DI` → `lsi_do_dma`, `CMD` → `lsi_do_command`,
`ST` → `lsi_do_status`, `MO` → `lsi_do_msgout`, `MI` → `lsi_do_msgin`.

**Group 1 — I/O + register ALU.**
opcodes 0-4: Select / Wait Disconnect / Wait Reselect / Set / Clear
(ATN, ACK, target-mode, carry).
opcodes 5-7: register read-modify-write — `MOV/SHL/OR/XOR/AND/SHR/ADD/ADC`
between `SFBR`, an 8-bit immediate, and any register.

**Group 2 — Transfer Control.** Jump / Call / Return / Interrupt,
conditions on carry, phase (`== / !=`), and masked `SFBR` compare.
`Interrupt` → `DSTAT.SIR` (or just re-level IRQ if `insn[20]`).

**Group 3 — Memory Move.** Only `DCMD == 0xC0` valid on the 710
(`lsi_memcpy`, 4 KB chunks); anything else → `DSTAT.IID` illegal-instruction.

Runaway guard: >10000 insns without `waiting` → force UDC disconnect.
`>10000` and self-modifying spin loops are handled.

### 3.2 SCSI phase engine

- `lsi_do_command`: DMA the CDB from `dnad`, `scsi710_device_find` by ID bits,
  `scsi710_req_new` + `scsi710_req_enqueue`. If not immediate → queue msg bytes
  `SAVE DATA POINTER` + `DISCONNECT`, `lsi_queue_command`.
- `lsi_do_dma`: moves `min(dbc, dma_len)` bytes between Amiga RAM (`dnad`) and
  the SCSI request buffer, advancing pointers; calls `scsi710_req_continue`
  when the chunk is drained.
- `lsi_do_status` / `lsi_do_msgin` / `lsi_do_msgout`: 1-byte status, message
  bytes (COMMAND COMPLETE, SAVE/RESTORE PTRS, DISCONNECT, IDENTIFY/LUN,
  SIMPLE/HEAD/ORDERED tag, ABORT / ABORT TAG / BDR / CLEAR QUEUE,
  SDTR/WDTR parsed-then-ignored, MESSAGE REJECT for the rest).
- `lsi_reselect` / `lsi_wait_reselect` / `lsi_queue_req`: disconnect/reconnect
  with a tag queue (`QTAILQ` of `lsi_request`).
- `max_target = 7`, `max_lun = 0` ("LUN support is buggy"), `tcq = true`.

### 3.3 Diagnostic support (needed for `ncr7xx` self-test)

- **SCSI loopback** (`CTEST4.SLBE 0x10` + `SCNTL1.ADB`): `SODL/SOCL` output
  latches feed straight back into `SBDL/SBCL`.
- **SCSI FIFO**: 8 × 9-bit (byte + generated parity). `SODL` writes push
  (with `CTEST4.SFWR`), `CTEST3` reads pop, count in `SSTAT2[7:4]`,
  `CTEST8.CLF` clears.
- **Parity**: odd, or even under `SCNTL1.AESP`; shows in `SSTAT1.PAR`.
- **CTEST5.ADCK / .BBCK**: self-clearing strobes that clock `DNAD += 4` /
  `DBC -= 4` for the DMA address / byte-count diagnostic.

### 3.4 Interrupts — `lsi_update_irq()`

`DSTAT & DIEN` or `SSTAT0 & SIEN0` → assert. `ISTAT.DIP / .SIP` track which.
`lsi_script_dma_interrupt` / `lsi_script_scsi_interrupt` stop SCRIPTS and
raise. `ISTAT.ABRT` aborts; `ISTAT` soft-reset bit → `lsi_soft_reset`.

---

## 4. SCSI command layer — `src/scsi.cpp`

`scsi_emulate_analyze` (sets direction / transfer length) then
`scsi_emulate_cmd` dispatches to:

| Backend | Function |
|---|---|
| Hardfile (`UAEDEV_HDF`) | `scsi_hd_emulate` |
| CD (`UAEDEV_CD`) | `scsi_cd_emulate` (ATAPI-aware) |
| Tape (`UAEDEV_TAPE`) | `scsi_tape_emulate` |

Handles REQUEST SENSE / contingent allegiance (`handle_ca`), unit attention,
INQUIRY, READ CAPACITY, READ/WRITE (6/10/12), MODE SENSE/SELECT, TUR,
START/STOP, RDB is just LBA 0+. This is the layer that reads/writes the actual
image file.

---

## 5. What a port needs from all this

| Piece | Complexity | Notes |
|---|---|---|
| Zorro III autoconfig responder | low | fixed 20-byte ident, base latch |
| Boot ROM window + nibble expansion | low | BRAM |
| 53C710 register file (64 B, beswap) | low | |
| SCRIPTS interpreter (4 groups) | medium | ~1 large case statement |
| SCSI phase FSM + msg handling | medium-high | disconnect/reselect + tags are the fiddly part; single-nexus first |
| Bus-master DMA to Amiga RAM | medium | new arbiter port; endianness |
| SCSI-2 direct-access command model | medium | ~10 opcodes for a bootable HDF |
| INT2 injection | low | |
| Diagnostic latches/FIFO/strobes | low-medium | only to pass `ncr7xx` |
