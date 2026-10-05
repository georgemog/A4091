#!/bin/sh
# Smoke-check the combined core (A4091 + Z3 RTG + A2065) on real hardware.
#
# RUNS ON THE MiSTer. Needs /dev/ttyS1 free (the Paula serial bridge) and the
# Amiga sitting at a Shell prompt, booted from IDE DH0.
#
#   scp tools/aserial.py root@mister:/media/fat/trans/
#   scp A4091/integration/combined/verify_combined.sh root@mister:/media/fat/trans/
#   ssh root@mister 'sh /media/fat/trans/verify_combined.sh'
#
# Checks, in order:
#   1. all three boards enumerate  (showconfig)
#   2. A4091  - a4091.device probes its unit           (devtest -p)
#   3. A4091  - geometry off the mounted .hdf          (devtest -g)
#   4. A2065  - LANCE diagnostics                      (Lance-Test)
#   5. RTG    - the Z3 board is claimed by MiSTer.card (P96 board list)
# Deeper A4091 coverage is tools/tests/swsiop_regress.py.

set -e
TRANS=/media/fat/trans
AS="python3 $TRANS/aserial.py"
SHARE=SHARE:

fuser -k /dev/ttyS1 2>/dev/null || true

echo "=== 1. showconfig (expect: A2065 Ethernet, Z3 GraphicsCard, A4091 SCSI) ==="
$AS -t 60 "showconfig" | grep -iE "board|prod|zorro|4091|2065|graphic|ram" || true

echo
echo "=== 2. A4091 probe ==="
$AS -t 90 "${SHARE}a4091/devtest -p" || true

echo
echo "=== 3. A4091 geometry ==="
$AS -t 90 "${SHARE}a4091/devtest -g" || true

echo
echo "=== 4. A2065 LANCE diagnostics ==="
$AS -t 180 "${SHARE}RunLanceTest" || true

echo
echo "=== 5. RTG board / P96 ==="
$AS -t 60 "version MiSTer.card full" || true
$AS -t 60 "avail" | tail -3 || true

echo
echo "done. For the full A4091 suite:"
echo "  cd /tmp/swsiop_tests && python3 swsiop_regress.py"
