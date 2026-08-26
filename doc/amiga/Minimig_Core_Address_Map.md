# Minimig-AGA_MiSTer Core Address Map

Verified against this project's own RTL (`rtl/gary.v`, `rtl/memory_router.v`,
`rtl/cpu_wrapper.v`, `rtl/fastchip.v`), not the generic Amiga reference —
this is what *this core* actually decodes, which in places (RTG board,
`sel_bank_1`) differs from or extends genuine Amiga hardware convention.
See `rtg/IMPLEMENTATION_PLAN.md` (outer repo) for the RTG board's design
history and the investigation that produced some of the notes below.

## CPU address space ($00000000-$FFFFFFFF)

| Range | Size | What | Source |
|---|---|---|---|
| `$000000-$1FFFFF` | 2MB | Chip RAM | `memory_router.v`: `sel_chipram = !cpu_addr[31:21] && cchip` |
| `$200000-$3FFFFF` | 2MB | Part of Z2 fast RAM range; also `gary.v`'s `sel_bank_1` (floating-bus/legacy quirk, see note below) | `gary.v`: `sel_bank_1 = cpu_address_in[23:21]==3'b001` |
| `$200000-$9FFFFF` | 8MB | Zorro II fast RAM ("Z2RAM") — fixed base, must be first in the AutoConfig chain, no dynamic base register (a deliberate simplification in this core, see `cpu_wrapper.v` comment). **Officially documented** in the Amiga Hardware Reference Manual's A1000/A500/A2000 System Memory Map as `20 0000 - 9F FFFF: Primary 8 MB Auto-config space` — not just this core's convention, this is the real, Commodore-documented canonical Zorro II RAM slot on genuine Amiga hardware. | `memory_router.v`: `sel_z2ram` |
| `$A80000-$AFFFFF` | 512KB | Kickstart ROM mirror (write-triggered, see note below) | `memory_router.v`: `sel_kickram`, `addr[23:19]==5'b10101` |
| `$B00000-$B7FFFF` | 512KB | Kickstart ROM mirror (write-triggered) | `memory_router.v`: `sel_kickram`, `addr[23:19]==5'b10110` |
| `$BF0000-$BFFFFF` | 64KB | CIA-A/CIA-B | `gary.v`: `sel_cia = cpu_address_in[23:16]==8'hBF` |
| `$E00000-$E7FFFF` | 512KB | Kickstart ROM mirror (write-triggered, non-CDTV mode only) | `memory_router.v`: `sel_kickram`, `addr[23:19]==5'b11100` |
| `$F80000-$FBFFFF` | 256KB | Kickstart ROM mirror, lower half (`sel_kicklower`) | `memory_router.v`: `sel_kicklower` |
| `$F80000-$FFFFFF` | 512KB | Kickstart ROM mirror (write-triggered, full range) | `memory_router.v`: `sel_kickram`, `&addr[23:19]` |
| `$DA0000-$DAFFFF` | 64KB | IDE | `gary.v`/`fastchip.v`: `sel_ide` |
| `$DC0000-$DCFFFF` | 64KB | RTC (MSM6242B-compatible) | `gary.v`: `sel_rtc = cpu_address_in[23:16]==8'b1101_1100` |
| `$DD4000-$DD5FFF` | 8KB | Shared disk (host filesystem bridge) | `memory_router.v`: `sel_dd = (cpu_addr[31:16]==16'h00DD) && (cpu_addr[15:13]==3'b010)` |
| `$DE0000-$DEFFFF` | 64KB | GAYLE | `gary.v`/`fastchip.v`: `sel_gayle` |
| `$DF0000-$DFFFFF` | 64KB | Custom chip registers | `gary.v`: `sel_reg`, gated `~(sel_rtc \| sel_ide \| sel_gayle \| sel_network)` |
| `$E80000-$E8FFFF` | 64KB | Zorro AutoConfig probe space — every `ac_*` device in the chain answers here in priority order until configured | `cpu_wrapper.v`: `sel_autoconfig` |
| `$E90000-$E9FFFF`* | 64KB | Toccata sound card (AutoConfig'd, dynamic base — this is where it currently lands) | `cpu_wrapper.v` (`ac_toccata`), `gary.v` (`sel_toccata`) |
| `$EA0000-$EAFFFF`* | 64KB | A2065 Ethernet (AutoConfig'd, dynamic base) | `cpu_wrapper.v` (`ac_a2065`), `gary.v` (`sel_a2065`) |
| `$EB0000-$EBFFFF`* | 64KB | RTG regs + CLUT board (AutoConfig'd, dynamic base — mfr `$139C` product `$03`) | `cpu_wrapper.v` (`ac_rtg`), `fastchip.v` (`sel_rtg`, register decode) |
| `$02000000-$027FFFFF`† | 8MB | **RTG framebuffer — CURRENTLY DEPLOYED** as a fixed decode, not AutoConfig-dynamic (`cd_BoardAddr` reports `$200000`, a diagnostic mismatch — see the dedicated section below, this is not the intended end state) | `memory_router.v`: `sel_rtg = (cpu_addr[31:24]==8'h02) && rtg_fb_ena` |
| `$40000000-$4FFFFFFF`* | 256MB | Zorro III FastRAM (AutoConfig'd, dynamic base — mfr `$139C` product `$10`) | `cpu_wrapper.v` (`ac_memcard[2]`), `memory_router.v` (`sel_z3ram0`/`sel_z3ram1`) |

\* AutoConfig'd ranges are **dynamic** — the OS picks the base at boot from
whatever's free. The values shown are what this project's own test hardware
happened to land on (via `showconfig`), not guaranteed addresses. Z3 boards
in particular can land anywhere in the Zorro III space depending on what
else is present and what size class they declare.

† `$02000000` is a **fixed** decode, not AutoConfig-assigned — the RTL
compares `cpu_addr` against this literal constant, gated only by
`rtg_fb_ena` (whether the board has been claimed at all). See below.

**"Write-triggered"**: `sel_kickram` requires `wr` (a write cycle) to
assert at all — these mirrors aren't readable/writable data storage in the
normal sense, they're address ranges the Kickstart ROM overlay/remap logic
watches for write access to as a trigger (the surrounding source comment
"don't sel_kickram when writing" reads as contradicting its own `&& wr`
condition — noted as-is, not resolved, since it predates this session's
changes and wasn't touched).

## RTG framebuffer board — address is currently under active revision

**Currently deployed: `$02000000` (Amiga/Zorro-side), fixed in RTL, not
dynamic.** ARM/HPS physical side is `$27000000` (see below), unchanged
across every variant this session. This is a diagnostic state, not the
intended final design — see the last bullet below for the planned fix.

The RTG framebuffer board's AutoConfig'd address has changed several times
during development (see `rtg/IMPLEMENTATION_PLAN.md` for the full history)
and is **not settled** as of this document:

- Originally fixed at `$02000000` (pre-AutoConfig design, no ConfigDev at all).
- Briefly a single combined Zorro III window with the regs board (`$40000000`-ish, 128MB, offset `+$800000` for the framebuffer half).
- Then moved to claim the fixed `$200000-$9FFFFF` Z2 slot directly (mutually exclusive with Z2RAM) — this was **confirmed via testing to cause real corruption/input-failure bugs**, traced to that being the conventional "Zorro II fast RAM" range that other system software appears to treat specially regardless of the `MEMLIST` AutoConfig flag.
- Currently (diagnostic only, not a real fix) forced back to the fixed `$02000000` address in the RTL decode while still doing genuine AutoConfig discovery/claiming — this mismatches `cd_BoardAddr` from the real hardware address, which breaks PMMU page-descriptor correctness on 68030/040 (the actual goal of the whole AutoConfig project), so it's not the intended end state.
- Next planned step: its own separate Zorro III board (dynamic base, matched `cd_BoardAddr`, no PMMU cost) — like the FastRAM board above, just for the framebuffer specifically, with the regs board staying as the already-proven-working Zorro II board unchanged.

## ARM/HPS physical side (separate from the above entirely)

The RTG framebuffer's *physical* storage in DDR3 has stayed at a **fixed
ARM-side address throughout every experiment above** — `$27000000`
(`memory_router.v`'s `ramaddr[26:23]=4'b1110` slot). This is invisible to
the Amiga CPU/OS; only the Zorro-visible address (above) is what AmigaOS
software actually sees and reasons about. Testing this session confirmed
the ARM-side location was never the variable that mattered for the bugs
found — only the Zorro-side address was.

## Things explicitly *not* verified in this session

The following are documented elsewhere in this project (e.g. `CLAUDE.md`)
but weren't independently re-confirmed against RTL while building this
table — treat with the same caution as any inherited documentation:

- `$DD6000-$DDFFFF` network bridge windows (documented in `CLAUDE.md`, not
  re-checked against this specific core's current RTL this session).
- Whatever lives in the remaining gaps not covered by any table row above
  (e.g. `$400000-$9FFFFF` beyond Z2RAM's own range if Z2RAM is disabled,
  `$B80000-$DBFFFF` minus IDE, `$E00000-$E7FFFF` minus the Kickstart mirror
  above) — not necessarily unmapped, just not something this session's
  investigation had reason to trace.
