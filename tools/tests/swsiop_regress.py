#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Nigel Shearman
# A4091 software-SIOP regression suite.
#
# RUNS ON THE MiSTer.  Deploy the whole swsiop_tests/ dir and run:
#     ssh root@mister 'cd /tmp/swsiop_tests && python3 swsiop_regress.py'
#
# Preconditions:
#   * Minimig core loaded, RBF = a software-SIOP bridge build
#   * MiSTer.ini / Minimig.cfg: A4091 enabled, SCSI ID1 = a scratch .hdf
#     (default test drive Test200MB.hdf), boot from IDE DH0
#   * AmigaOS booted to a Shell prompt
#   * <shared>:a4091/devtest present, C:lha present, DH0:Amelinium.lha present
#
# Exit 0 = all selected tests pass.  -v prints device output.

import argparse
import re
import sys
import time

import aserial_lib as A

DEV       = "a4091.device"
UNIT      = "1"
SCSIVOL   = "DH0.1:"                  # AmigaDOS device for the a4091 ID1 partition
                                     # (override with --scsivol; RDB names it "DH0",
                                     # auto-renamed .1 to avoid the IDE DHO clash)
DEVTEST   = "SHARE:a4091/devtest"
BIGFILE   = "DH0:Amelinium.lha"       # ~3.3 MB, 10 CRC-checked members
MARKER    = "A4091-SWSIOP-REGRESS"

VERBOSE = False
RESULTS = []


def log(msg):
    print(msg, flush=True)


def check(name, ok, detail=""):
    RESULTS.append((name, ok))
    log("  %-22s %s%s" % (name, "PASS" if ok else "FAIL",
                          ("  " + detail) if detail else ""))
    return ok


def dev(cmd, timeout=60):
    out = A.run(cmd, timeout=timeout)
    if VERBOSE:
        log("    $ %s\n%s" % (cmd, "\n".join("    | " + l for l in out.split("\n"))))
    return out


_CACHE = {}


def devtest(flag, timeout=150):
    """Run `devtest <flag> a4091.device 1` once; cache the output."""
    if flag not in _CACHE:
        _CACHE[flag] = dev("%s %s %s %s" % (DEVTEST, flag, DEV, UNIT), timeout=timeout)
    return _CACHE[flag]


# --------------------------------------------------------------------------
def t_mount():
    out = dev("info " + SCSIVOL)
    # info line:  <dev>  <size>  <used>  <free>  <full>%  <errs>  Read/Write  <vol>
    m = re.search(r"\S+\s+\d+[KMG]?\s+\d+\s+\d+\s+\d+%?\s+(\d+)\s+Read/Write\b", out)
    if not m:
        return check("mount", False, "no R/W line: " + out.replace("\n", " ")[:70])
    return check("mount", m.group(1) == "0", "errs=%s" % m.group(1))


def t_probe():
    out = dev(DEVTEST + " -p " + DEV, timeout=90)
    ok = bool(re.search(r"\bMiSTer\b", out) and re.search(r"A4091 HD", out)
              and re.search(r"\b512\b", out))
    return check("probe", ok, out.strip().split("\n")[-1] if out.strip() else "no output")


def t_geometry():
    out = devtest("-g")
    m = re.search(r"TD_GETGEOMETRY\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", out)
    if not m:
        return check("geometry", False, "no TD_GETGEOMETRY line")
    ssize, sects, c, h, s = (int(x) for x in m.groups())
    ok = ssize == 512 and sects == 409600 and c == 3200 and h == 16 and s == 8
    return check("geometry", ok, "ssize=%d sects=%d C=%d H=%d S=%d" % (ssize, sects, c, h, s))


def t_read_packets():
    out = devtest("-t")
    need = ["CMD_READ", "ETD_READ", "TD_READ64", "NSCMD_TD_READ64", "NSCMD_ETD_READ64"]
    bad = []
    for k in need:
        m = re.search(re.escape(k) + r"\s+(\w+)", out)
        if not m or m.group(1) != "Success":
            bad.append(k + "=" + (m.group(1) if m else "MISSING"))
    return check("read_packets", not bad, ",".join(bad) or "all Success")


def t_read_capacity():
    out = devtest("-g")
    m = re.search(r"READ_CAPACITY_10\s+512\s+(\d+)", out)
    ok = bool(m) and int(m.group(1)) == 409600
    return check("read_capacity10", ok, m.group(1) if m else "missing")


def t_seek():
    # SEEK(6)=0x0b : devtest issues TD_SEEK. C1 target must ACK it.
    out = devtest("-t")
    m = re.search(r"TD_SEEK\s+(\S+)", out)
    got = m.group(1) if m else "MISSING"
    return check("td_seek", got == "Success", got)


def t_read_capacity16():
    # devtest -g issues READ CAPACITY(16) (SERVICE ACTION IN / 0x9e SA 0x10).
    out = devtest("-g")
    m = re.search(r"READ_CAPACITY_16\s+(\d+)\s+(\d+)", out)
    ok = bool(m) and int(m.group(1)) == 512 and int(m.group(2)) == 409600
    return check("read_capacity16", ok,
                 ("%s x %s" % m.groups()) if m else "not answered")


def t_write_integrity():
    dev("delete " + SCSIVOL + "regr.lha quiet")
    dev("copy " + BIGFILE + " " + SCSIVOL + "regr.lha", timeout=240)
    ls = dev("list " + SCSIVOL + "regr.lha")
    size_ok = bool(re.search(r"regr\.lha\s+3394770", ls))
    t = dev("lha t " + SCSIVOL + "regr.lha", timeout=120)
    crc_ok = "all files OK" in t
    dev("delete " + SCSIVOL + "regr.lha quiet")
    return check("write_integrity", size_ok and crc_ok,
                 "size_ok=%s crc_ok=%s" % (size_ok, crc_ok))


def t_marker_roundtrip():
    dev('echo "%s" >%smarker.txt' % (MARKER, SCSIVOL))
    back = dev("type " + SCSIVOL + "marker.txt")
    dev("delete " + SCSIVOL + "marker.txt quiet")
    return check("marker_roundtrip", MARKER in back, back.strip()[:40])


def t_quick_format():
    A.run_prompted("Format DRIVE %s NAME RegrTest FFS QUICK" % SCSIVOL,
                   pre_wait=3.0, timeout=90)
    time.sleep(2)
    info = dev("info " + SCSIVOL)
    m = re.search(r"\S+\s+\d+[KMG]?\s+\d+\s+\d+\s+\d+%?\s+(\d+)\s+Read/Write\s+RegrTest", info)
    return check("quick_format", bool(m),
                 "remounted RegrTest 0 errs" if m else info.strip().replace("\n", " ")[-70:])


TESTS = [
    # -- SIOP layer: no DOS volume needed, non-destructive, run first --
    ("probe",           t_probe),
    ("geometry",        t_geometry),
    ("read_capacity10", t_read_capacity),
    ("read_capacity16", t_read_capacity16),
    ("read_packets",    t_read_packets),
    ("td_seek",         t_seek),
    # -- filesystem layer: quick_format goes first so the rest start clean --
    ("quick_format",    t_quick_format),
    ("mount",           t_mount),
    ("marker_roundtrip", t_marker_roundtrip),
    ("write_integrity", t_write_integrity),
]


def main():
    global VERBOSE
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", action="store_true", help="print device output")
    ap.add_argument("-k", metavar="RE", help="only run tests matching RE")
    ap.add_argument("--allow-format", action="store_true",
                    help="run the destructive quick_format test")
    ap.add_argument("--bench", action="store_true",
                    help="also print a devtest -b throughput number (not pass/fail)")
    ap.add_argument("--scsivol", default=SCSIVOL,
                    help="AmigaDOS device for the a4091 test drive (default %s)" % SCSIVOL)
    args = ap.parse_args()
    VERBOSE = args.v
    globals()["SCSIVOL"] = args.scsivol

    log("A4091 software-SIOP regression  (%s)" % time.strftime("%Y-%m-%d %H:%M:%S"))
    sel = [(n, f) for n, f in TESTS
           if (not args.k or re.search(args.k, n))
           and (n != "quick_format" or args.allow_format)]
    for n, f in sel:
        try:
            f()
        except Exception as e:
            check(n, False, "EXC %s" % e)

    if args.bench:
        # 64 KB transfers: representative of real FS I/O and within the
        # ~128 KB single-command ceiling (see RW_MAX_BYTES in a4091_scsi.cpp).
        out = dev(DEVTEST + " -b -B 64k,4 " + DEV + " " + UNIT, timeout=200)
        if VERBOSE:
            log("\n".join("    | " + l for l in out.split("\n")))
        for m in re.finditer(r"^\s*(\S.*?)\s+([\d.]+)\s+(K|M)B/s", out, re.M):
            log("  bench  %-24s %s %sB/s" % (m.group(1), m.group(2), m.group(3)))

    npass = sum(1 for _, ok in RESULTS if ok)
    log("\n%d/%d passed" % (npass, len(RESULTS)))
    sys.exit(0 if npass == len(RESULTS) else 1)


if __name__ == "__main__":
    main()
