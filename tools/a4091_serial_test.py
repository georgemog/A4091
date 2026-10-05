#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Nigel Shearman
"""
a4091_serial_test.py - drive the Amiga shell over the MiSTer serial bridge
and run the A4091 bring-up checks.

RUNS ON THE MiSTer (needs /dev/ttyS1 = the Paula UART bridge, 115200 8N1).
Deploy to /media/fat/trans/ and:

    ssh root@mister 'python3 /media/fat/trans/a4091_serial_test.py'
    ssh root@mister 'python3 /media/fat/trans/a4091_serial_test.py -t ncr7xx-r'

Tests (all by default):
  showconfig   - board present? mfg 514 / product 84 / declared size
  ncr7xx-r     - 53C710 register dump; flags 00ff00ff filler lanes
  ncr7xx-t1    - 53C710 register test; PASS/FAIL + 'Floating or bridged'

The Amiga must be sitting at a shell prompt. amiga_term.py (or any other
user of /dev/ttyS1) must be stopped first.
"""
import argparse
import os
import re
import select
import sys
import termios
import time

PORT   = "/dev/ttyS1"
BAUD   = termios.B115200
SHARE  = "share:a4091"          # volume as it appears on the Amiga (`list` to check)

PROMPT_RE = re.compile(rb'[\w.:/]*>\s*$')      # e.g.  4.DHO:>   or  4.DHO:a4091>
CSI_RE    = re.compile(rb'\x9b[0-9;?]*[ -/]*[@-~]')   # 8-bit CSI -> strip


def open_serial(port=PORT):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = list(termios.tcgetattr(fd))
    a[0] = 0
    a[1] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[3] = 0
    a[4] = BAUD
    a[5] = BAUD
    a[6] = list(a[6])
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def clean(raw):
    """Amiga serial bytes -> plain text: drop 8-bit CSI, SI, normalise EOL."""
    raw = CSI_RE.sub(b'', raw)
    raw = raw.replace(b'\x0f', b'')
    txt = raw.decode('latin-1')
    txt = txt.replace('\n\r', '\n').replace('\r\n', '\n').replace('\r', '\n')
    return txt


def drain(fd, quiet=0.3, hard=3.0):
    """Read until the line has been quiet for `quiet` s (or `hard` s total)."""
    buf = bytearray()
    t0 = time.time()
    last = t0
    while time.time() - t0 < hard:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            chunk = os.read(fd, 4096)
            if chunk:
                buf += chunk
                last = time.time()
        elif time.time() - last > quiet:
            break
    return bytes(buf)


def wait_prompt(fd, timeout):
    """Read until a shell prompt is seen at the tail, or timeout. Returns text."""
    buf = bytearray()
    t0 = time.time()
    while time.time() - t0 < timeout:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            chunk = os.read(fd, 4096)
            if chunk:
                buf += chunk
                tail = CSI_RE.sub(b'', bytes(buf))[-40:].replace(b'\r', b'').replace(b'\x0f', b'')
                if PROMPT_RE.search(tail):
                    return clean(bytes(buf)), True
    return clean(bytes(buf)), False


def send_slow(fd, s, cps_delay=0.008):
    """Byte-at-a-time with an inter-char gap - the Paula UART RX has no flow
    control and drops characters on a fast burst."""
    for ch in s.encode('ascii'):
        os.write(fd, bytes([ch]))
        time.sleep(cps_delay)


def run_cmd(fd, cmd, timeout=30.0):
    termios.tcflush(fd, termios.TCIFLUSH)
    send_slow(fd, cmd + "\r")
    text, got_prompt = wait_prompt(fd, timeout)
    lines = text.split('\n')
    # strip the echoed command line and the trailing prompt line
    if lines and cmd in lines[0]:
        lines = lines[1:]
    while lines and (PROMPT_RE.search(lines[-1].encode('latin-1')) or not lines[-1].strip()):
        lines.pop()
    return '\n'.join(lines), got_prompt


# --------------------------------------------------------------------------
def t_showconfig(fd):
    out, ok = run_cmd(fd, "showconfig", timeout=15)
    print(out)
    if not ok:
        return False, "no prompt (timeout)"
    m = re.search(r'A ?4091 SCSI.*?Prod=(\d+)/(\d+).*?size\s*([0-9]+ ?[KMG]B)',
                  out, re.S)
    if not m:
        if 'A 4091' in out or 'A4091' in out:
            return False, "board line found but could not parse Prod/size"
        return False, "A4091 board NOT in ShowConfig"
    mfg, prod, size = m.group(1), m.group(2), m.group(3).replace(' ', '')
    detail = "mfg=%s product=%s size=%s" % (mfg, prod, size)
    if (mfg, prod) != ("514", "84"):
        return False, "wrong ident: " + detail
    return True, detail


def t_ncr7xx_r(fd):
    out, ok = run_cmd(fd, SHARE + "/ncr7xx -r", timeout=30)
    print(out)
    if not ok:
        return False, "no prompt (timeout / hang)"
    if "53C710" not in out:
        return False, "chip not detected"
    fillers = re.findall(r'\b00ff00ff\b|\bff00ff\b', out)
    rev = re.search(r'53C710 rev (V\d)', out)
    detail = "chip=53C710 %s" % (rev.group(1) if rev else "?")
    if fillers:
        return False, detail + " -- %d register(s) read as 00ff00ff filler" % len(fillers)
    return True, detail + " -- no filler lanes"


def t_ncr7xx_t1(fd):
    out, ok = run_cmd(fd, SHARE + "/ncr7xx -t1", timeout=90)
    print(out)
    if not ok:
        return False, "no prompt (timeout / hang)"
    floating = re.search(r'Floating or bridged:\s*(.*)', out)
    verdict  = re.search(r'Register test:\s*(PASS|FAIL)', out)
    if verdict and verdict.group(1) == "PASS":
        return True, "Register test PASS"
    d = "Register test %s" % (verdict.group(1) if verdict else "??")
    if floating:
        d += " -- Floating/bridged: " + floating.group(1).strip()
    return False, d


def t_ncr7xx_rom(fd):
    """ncr7xx -t 'Device access' subtest: reads the board ROM window and
    reconstructs the a4091.rom image byte-for-byte. Passes once the ROM is
    bundled into the core."""
    out, ok = run_cmd(fd, SHARE + "/ncr7xx -t", timeout=180)
    print(out)
    if not ok:
        return False, "no prompt (timeout / hang)"
    # collect every "<name>:   PASS|FAIL" subtest verdict
    subs = re.findall(r'^\s*([A-Z][A-Za-z0-9 /_-]+?):\s+(PASS|FAIL)\s*$', out, re.M)
    summary = ", ".join("%s=%s" % (n.strip(), v) for n, v in subs)
    dev = dict((n.strip(), v) for n, v in subs)
    rom_mismatch = re.search(r'ROM pos [0-9a-f]+: .* != expected', out)
    stuck = re.search(r'Stuck (?:low|high):', out)
    if rom_mismatch or stuck:
        return False, "ROM window wrong (%s%s)" % (
            "mismatch" if rom_mismatch else "", " " + stuck.group(0) if stuck else "")
    if dev.get("Device access") == "PASS":
        return True, "Device access PASS" + (" | " + summary if summary else "")
    return False, "Device access not PASS | " + (summary or "no verdicts parsed")


TESTS = {
    "showconfig": t_showconfig,
    "ncr7xx-r":   t_ncr7xx_r,
    "ncr7xx-t1":  t_ncr7xx_t1,
    "ncr7xx-rom": t_ncr7xx_rom,
}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-t", "--test", choices=list(TESTS) + ["all"], default="all")
    ap.add_argument("-p", "--port", default=PORT)
    args = ap.parse_args(argv)

    try:
        fd = open_serial(args.port)
    except OSError as e:
        sys.exit("cannot open %s: %s  (is amiga_term running?)" % (args.port, e))

    # make sure we start at a prompt
    os.write(fd, b"\r")
    _, ok = wait_prompt(fd, 5)
    if not ok:
        print("WARNING: no shell prompt within 5s - Amiga busy or not at CLI?",
              file=sys.stderr)

    todo = list(TESTS) if args.test == "all" else [args.test]
    results = []
    for name in todo:
        print("\n" + "=" * 60 + "\n== %s\n" % name + "=" * 60)
        try:
            ok, detail = TESTS[name](fd)
        except Exception as e:                       # noqa: BLE001
            ok, detail = False, "harness error: %r" % e
        results.append((name, ok, detail))
        print("\n--> %-11s %s   %s" % (name, "PASS" if ok else "FAIL", detail))

    os.close(fd)
    print("\n" + "=" * 60)
    for name, ok, detail in results:
        print("  %-11s %-4s  %s" % (name, "PASS" if ok else "FAIL", detail))
    sys.exit(0 if all(ok for _, ok, _ in results) else 1)


if __name__ == "__main__":
    main()
