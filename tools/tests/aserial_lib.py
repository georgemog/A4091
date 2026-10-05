#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Nigel Shearman
# Minimig serial-console helper for the A4091 software-SIOP regression suite.
# RUNS ON THE MiSTer (needs /dev/ttyS1 = Paula UART bridge, 115200 8N1).
# Derived from A4091/tools/aserial.py; importable.
#
# The Amiga must be sitting at a Shell prompt (booted from IDE DH0).
# Any other user of /dev/ttyS1 (amiga_term.py) must be stopped first.

import os
import re
import select
import termios
import time

PORT = "/dev/ttyS1"

# AmigaDOS Shell prompt, e.g.  "4.DHO:>"  or  "1.Workbench:Tools>"
_PROMPT = re.compile(r"\d+\.[A-Za-z0-9_]+:[^>\n]*>\s*$")


def _open(port=PORT):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
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


def _drain(fd, quiet=0.4):
    while select.select([fd], [], [], quiet)[0]:
        os.read(fd, 4096)


def _send(fd, s, cps=0.025):
    # TX paced: the Amiga serial.device drops chars at 115200 with no flow control.
    for ch in s:
        os.write(fd, ch.encode("latin1"))
        termios.tcdrain(fd)
        time.sleep(cps)


def _clean(b):
    t = b.decode("latin1")
    t = re.sub(r"\x9b[0-9;]*[A-Za-z]", "", t)    # AmigaDOS CSI (0x9b)
    t = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", t)  # ESC[ CSI
    return t.replace("\x0f", "").replace("\r", "")


def run(cmd, timeout=45, settle=1.0):
    """Send one Shell command, return its output (prompt + echo stripped)."""
    fd = _open()
    try:
        _drain(fd)
        _send(fd, "   " + cmd + "\r")   # 3 lead spaces: first char often eaten
        buf = b""
        t0 = last = time.time()
        while time.time() - t0 < timeout:
            if select.select([fd], [], [], 0.5)[0]:
                d = os.read(fd, 8192)
                if d:
                    buf += d
                    last = time.time()
            tail = _clean(buf).split("\n")[-1]
            if _PROMPT.search(tail) and time.time() - last > settle:
                break
    finally:
        os.close(fd)
    out = []
    for l in _clean(buf).split("\n"):
        if _PROMPT.search(l):
            continue
        if not out and cmd.strip() and cmd.strip() in l:
            continue
        out.append(l)
    return "\n".join(out).strip("\n")


def run_prompted(cmd, answer="\r", pre_wait=3.0, timeout=45):
    """Send a command that stops for a console prompt (Format), answer it,
    then read until the prompt returns or timeout. Returns raw text."""
    fd = _open()
    try:
        _drain(fd)
        _send(fd, "   " + cmd + "\r")
        time.sleep(pre_wait)
        _send(fd, answer)
        buf = b""
        t0 = last = time.time()
        while time.time() - t0 < timeout:
            if select.select([fd], [], [], 0.5)[0]:
                d = os.read(fd, 8192)
                if d:
                    buf += d
                    last = time.time()
            tail = _clean(buf).split("\n")[-1]
            if _PROMPT.search(tail) and time.time() - last > 1.5:
                break
    finally:
        os.close(fd)
    return _clean(buf)
