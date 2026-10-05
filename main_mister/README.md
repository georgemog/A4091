# A4091 software SIOP — Main_MiSTer integration

The FPGA `a4091_bridge.v` is a thin Zorro-III bridge (256-byte shadow
53C710 register RAM + kick flag + IRQ). The 53C710 + SCRIPTS VM, the
SCSI-2 target, and the Z3-fast⇄HPS-DDR memory seam all run on the ARM,
in `Main_MiSTer`.

Base: `Main_MiSTer` @ `915ca33` ("minimig: repair the reserved CPU value
when loading a config").

## New files (canonical here)

Copy verbatim into `Main_MiSTer/support/minimig/`:

| file | role |
|---|---|
| `minimig_a4091.cpp` / `.h` | kick-poll loop, `pci710_dma_rw` (the one memory seam: `phys = 0x30000000 + (A − 0x40000000)`, 16-bit byte swap), `a4091_apply_config`, IRQ push |
| `a4091_lsi.cpp` | port of WinUAE `qemuvga/lsi53c710.cpp` — 53C710 + SCRIPTS interpreter. `a4091_lsi_load/store/run` seam |
| `a4091_lsi_glue.h` | shims: `DeviceState`, `pci710_dma_read/write`, `cpu_to_le32`, `sextract32`, … |
| `a4091_scsi.cpp` | C1 SCSI-2 direct-access target: INQUIRY / RC10 / RC16 / MODE SENSE / TUR / SEEK / READ / WRITE on the mounted `.hdf`s, up to 6 IDs |
| `a4091_scsi_defs.h` | WinUAE `scsi/scsi.h` trimmed (no block/sysemu) |
| `a4091_queue.h` | WinUAE `queue.h` verbatim (BSD `QTAILQ`) |

`support/*/*.cpp` is globbed by the Makefile, so the new `.cpp`s build
with no Makefile edit.

## Patch (modified existing files)

`main_mister_swsiop.patch` — `git apply` in the `Main_MiSTer` tree:

* `user_io.cpp` — call `a4091_sd_poll()` in the poll loop; `a4091_apply_config()` on config load
* `menu.cpp` — the "A4091 SCSI" OSD section (IDs 1–6, Disabled / Fixed-HDD, image picker)
* `minimig_config.{cpp,h}` — `scsi_cfg` + `mm_hardfileTYPE scsi[6]` appended to `mm_configTYPE` (tail-appended so old `.minimig` configs still load); `ApplyConfiguration` printout

## Build

```
cd Main_MiSTer
git apply /path/to/Minimig-AGA-A4091/main_mister/main_mister_swsiop.patch
cp /path/to/Minimig-AGA-A4091/main_mister/{a4091_lsi.cpp,a4091_lsi_glue.h,a4091_queue.h,a4091_scsi.cpp,a4091_scsi_defs.h,minimig_a4091.cpp,minimig_a4091.h} support/minimig/
export PATH=/opt/armV7-linux-gcc/bin:$PATH
make -j4
```

Build knobs (default off):

* `-DA4091_SWSIOP_TRACE` — per-SCRIPTS-instruction tracing to
  `/media/usb0/a4091_sd.log` (≈10× slower, 100 MB+ per format).
* runtime: `touch /media/usb0/a4091_debug` + core reload — opens the log
  without a rebuild (BADF / config lines only unless `TRACE` is also set).

## Verify

`../tools/tests/` — `ddrmap_test.c` (host unit test) and
`swsiop_regress.py` (MiSTer serial suite, 10 checks).
