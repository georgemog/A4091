# a4091.device patches for the Minimig MiSTer target

Against `a4091-software` @ `a199fa8`. Apply in the a4091-software tree
(`git apply -p1` / `patch -p1`), then:

```
git submodule update --init --recursive
PATH=/opt/amiga/bin:/opt/vbcc/bin:$PATH VBCC=/opt/vbcc make DEVICE=A4091 a4091.rom
../make_hex.sh a4091.rom ../rtl/a4091_rom.hex     # for a4091.v $readmemh
```

The FPGA bakes the ROM in via `$readmemh` at synthesis, so a driver
change needs a Quartus RBF rebuild.

- **mm_siop.patch** — `siop.c`
  - `mm_ramctrl_cache_evict(buf)`: after a DATA-IN DMA completes, sweep an
    8 KB scratch arena (stride 8) to evict the stale DMA-buffer lines from
    the Minimig RAM-controller read cache (`cpu_cache_new` - 4 KB 2-way -
    does not snoop the a4091 DMA / the software-SIOP's mmap DDR writes).
    Sweeps only the cache for the buffer's RAM type (chip < 0x200000 or
    slow 0xC00000-0xD7FFFF via sdram_ctrl; else fast via ddram_ctrl).
    Called from `siop_scsidone` for `XS_CTL_DATA_IN`. Without it geometry
    / INQUIRY / RC10 read back stale zero.
  - **History:** was a 2x 32 KB sweep (both caches) = ~11.6 ms per 16 KB
    DATA-IN on the ~10 MHz 68020, the throughput bottleneck (~1.1 MB/s).
    One 8 KB sweep is ~1.5 ms.

- **mm_sd.patch** — `sd.c`
  - `MM_MAX_XFER 4096`: cap every SCSI transfer in `sd_readwrite`.
    Historically the RTL target's data buffer was 4 KB; a larger DATA
    phase wrapped it -> phase mismatch -> bus reset -> HDToolBox "I/O
    error code 48". The `sd_complete` / `chan_continue_iotd` path
    re-issues the remainder; also inits `chan_current_blkno`.
    (Software SIOP: still splits at this size - the trace shows 16 KB
    READ(6) commands, so this build's cap is 16 KB - see the patch.)

Minimig-target workarounds, not upstream-worthy as-is. The proper fix is
FPGA-side (make `cpu_cache_new` snoop/invalidate the a4091 writes) — see
`../../docs/ISSUES.md`.
