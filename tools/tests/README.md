# A4091 software-SIOP regression suite

Guards the two silent-crash bugs found bringing the software SIOP up
(the Z3->DDR map anchor + the `req->bus` NULL deref) and the SCSI
command surface (probe / geometry / read packets / SEEK / RC10 / RC16 /
write integrity / format).

## `ddrmap_test.c` — host unit test (no hardware)

```
cc -Wall -O2 ddrmap_test.c -o ddrmap_test && ./ddrmap_test
```

Replicates `minimig_a4091.cpp :: ddr_ptr()` and
`a4091_lsi_glue.h :: cpu_to_le32` and checks them against the values
captured with `devmem` on real hardware: the driver's `scripts[]` at
Amiga `0x40000090` reads back at HPS phys `0x30000090` with each 16-bit
halfword byte-swapped, and `read_dword()` reconstructs the true SCRIPTS
words. Run it in CI / before any change to the DDR mapping or the glue
endian helpers.

## `swsiop_regress.py` — hardware functional suite

RUNS ON THE MiSTer (needs `/dev/ttyS1`). Deploy the dir and run:

```
scp -r swsiop_tests root@mister:/tmp/
ssh root@mister 'cd /tmp/swsiop_tests && python3 swsiop_regress.py'
```

Preconditions:

* Minimig core loaded, RBF = a software-SIOP bridge build
* `A4091 SCSI` enabled, ID1 = a scratch RDB `.hdf` whose partition
  **LowCyl > 0** (a full non-quick format writes every block of the
  partition; LowCyl 0 self-destructs the RDB). Keep a pristine copy -
  `Test200MB.hdf.pristine` on the box is one.
* boot from IDE DH0; AmigaOS sitting at a Shell prompt
* `<shared>:a4091/devtest`, `C:lha`, `DH0:Amelinium.lha` present
* nothing else holding `/dev/ttyS1` (`fuser -k /dev/ttyS1`)

Options:

| flag | effect |
|---|---|
| `-v` | print raw device output |
| `-k RE` | only tests whose name matches RE |
| `--allow-format` | also run the destructive `quick_format` test |
| `--bench` | also print `devtest -b` throughput (informational) |
| `--scsivol DEV:` | AmigaDOS device for the test drive (default `DH0.1:`) |

Exit 0 = every selected test passed.

Tests: `mount`, `probe`, `geometry`, `read_capacity10`,
`read_capacity16`, `read_packets`, `td_seek`, `marker_roundtrip`,
`write_integrity` (3.3 MB LhA copy + `lha t` CRC), `quick_format`.
