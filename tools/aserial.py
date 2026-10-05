#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Nigel Shearman
# Run an AmigaDOS command over the MiSTer Minimig serial console
# (ttyS1, newcli AUX:115200 from S:User-Startup) and print its output.
#
#   aserial.py "info"
#   aserial.py -t 180 "SHARE:a4091/devtest -b -B 512k,4 -m Fast a4091.device 1"
#
# TX is paced (~25 ms/char) because the Amiga serial.device RX drops
# characters at 115200 with no flow control.
import sys, os, time, select, termios, re

PORT = "/dev/ttyS1"

def open_port():
    fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY)
    a = termios.tcgetattr(fd)
    a[0] = termios.IGNBRK
    a[1] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL | termios.B115200
    a[3] = 0
    a[4] = a[5] = termios.B115200
    for i in range(len(a[6])):
        a[6][i] = 0
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 1
    termios.tcsetattr(fd, termios.TCSANOW, a)
    return fd

def drain(fd, quiet=0.4):
    while select.select([fd], [], [], quiet)[0]:
        os.read(fd, 4096)

def send(fd, s, cps=0.025):
    for ch in s:
        os.write(fd, ch.encode("latin1"))
        termios.tcdrain(fd)
        time.sleep(cps)

def clean(b):
    t = b.decode("latin1")
    t = re.sub(r"\x9b[0-9;]*[A-Za-z]", "", t)   # AmigaDOS CSI (0x9b)
    t = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", t) # ESC[ CSI
    return t.replace("\x0f", "").replace("\r", "")

def run(cmd, timeout=30):
    fd = open_port()
    drain(fd)
    send(fd, "   " + cmd + "\r")           # 3 lead spaces: first char often eaten
    buf = b""
    t0 = time.time()
    last = t0
    while time.time() - t0 < timeout:
        if select.select([fd], [], [], 0.5)[0]:
            d = os.read(fd, 8192)
            if d:
                buf += d
                last = time.time()
        tail = clean(buf).split("\n")[-1]
        if re.search(r"\d+\.[A-Za-z0-9_]+:>\s*$", tail) and time.time() - last > 1.0:
            break
    os.close(fd)
    lines = clean(buf).split("\n")
    out = []
    for l in lines:
        if re.search(r"\d+\.[A-Za-z0-9_]+:>\s*$", l):
            continue
        if not out and cmd.strip() and cmd.strip() in l:
            continue
        out.append(l)
    return "\n".join(out).strip("\n")

if __name__ == "__main__":
    a = sys.argv[1:]
    to = 30.0
    if a and a[0] == "-t":
        to = float(a[1]); a = a[2:]
    print(run(" ".join(a), to))
