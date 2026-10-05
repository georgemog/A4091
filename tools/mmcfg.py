#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Nigel Shearman
"""
mmcfg.py - read / modify a MiSTer Minimig config file (config/minimig*.cfg)

The file is a raw dump of Main_MiSTer's `mm_configTYPE`
(support/minimig/minimig_config.h). Layout of the parts we touch:

  off 0     char          id[8]       = "MNMGCFG0"
  off 8     uint16 (LE)   version
  off 10    uint16 (LE)   ext_cfg2    <- OSD O[48..63]  (bit n = O[48+n])
  off 12    char          kickstart[992]
  off 1004  char          label[32]
  off 1036  uint16 (LE)   ext_cfg     <- OSD O[32..47]  (bit n = O[32+n])
  ...

Minimig routes O[0..31] as always-0 and O[32..63] as ext_cfg / ext_cfg2
(minimig_set_extcfg). Any ext_cfg bit auto-persists across Save/Load config.

Examples:
  mmcfg.py --show minimig.cfg
  mmcfg.py --o 57 --set  minimig.cfg          # enable A4091 (O[57])
  mmcfg.py --o 58 --clear minimig.cfg         # disable PiStorm (O[58])
  mmcfg.py --o 57 --set --out new.cfg minimig.cfg
  mmcfg.py --a4091 minimig.cfg                # shorthand for --o 57 --set
"""
import argparse
import struct
import sys

MAGIC   = b"MNMGCFG0"
OFF_EC2 = 10      # ext_cfg2  O[48..63]
OFF_EC1 = 1036    # ext_cfg   O[32..47]

O57_A4091   = 57
O58_PISTORM = 58


def u16(buf, off):
    return struct.unpack_from("<H", buf, off)[0]


def bits(base, word):
    on = [f"O[{base + i}]" for i in range(16) if word & (1 << i)]
    return " ".join(on) if on else "-"


def show(path, buf):
    ec1, ec2 = u16(buf, OFF_EC1), u16(buf, OFF_EC2)
    print(f"{'file:':<20}{path}")
    print(f"{'size:':<20}{len(buf)} bytes")
    print(f"{'version:':<20}0x{u16(buf, 8):04x}")
    print(f"{'ext_cfg  O[32..47]:':<20}0x{ec1:04x}   {bits(32, ec1)}")
    print(f"{'ext_cfg2 O[48..63]:':<20}0x{ec2:04x}   {bits(48, ec2)}")
    print(f"{'  O[57] A4091:':<20}{'ON' if ec2 & (1 << 9) else 'off'}")
    print(f"{'  O[58] PiStorm:':<20}{'ON' if ec2 & (1 << 10) else 'off'}")


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="mmcfg.py",
        description="toggle Minimig config ext_cfg / ext_cfg2 (OSD O[32..63]) bits",
    )
    ap.add_argument("file", help="path to minimig*.cfg")
    ap.add_argument("-s", "--show", action="store_true",
                    help="print id / version / ext_cfg / ext_cfg2 and exit")
    ap.add_argument("-o", "--o", type=int, metavar="N", dest="o",
                    help="target OSD bit O[N], N = 32..63")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--set", action="store_true", help="set the bit")
    g.add_argument("-c", "--clear", action="store_true", help="clear the bit")
    ap.add_argument("--a4091", action="store_true",
                    help="shorthand: --o 57 --set (enable the A4091 board)")
    ap.add_argument("--out", metavar="FILE",
                    help="write to FILE instead of in-place")
    ap.add_argument("--no-backup", action="store_true",
                    help="do not write <file>.bak (in-place edits only)")
    args = ap.parse_args(argv)

    if args.a4091:
        args.o, args.set = O57_A4091, True

    try:
        with open(args.file, "rb") as f:
            buf = bytearray(f.read())
    except OSError as e:
        sys.exit(f"open {args.file}: {e}")

    if buf[:8] != MAGIC:
        sys.exit(f"not a Minimig config (bad id): {args.file}")
    if len(buf) < OFF_EC1 + 2:
        sys.exit(f"config too short ({len(buf)} bytes)")

    if args.show or args.o is None:
        show(args.file, buf)
        if args.o is None:
            return 0

    if not (32 <= args.o <= 63):
        sys.exit("--o must be 32..63")
    if not (args.set or args.clear):
        sys.exit("give one of --set / --clear (or --a4091)")

    if args.o >= 48:
        off, bit, name = OFF_EC2, args.o - 48, "ext_cfg2"
    else:
        off, bit, name = OFF_EC1, args.o - 32, "ext_cfg"

    old = u16(buf, off)
    new = (old | (1 << bit)) if args.set else (old & ~(1 << bit))

    if new == old:
        print(f"O[{args.o}] already {'set' if args.set else 'clear'} "
              f"in {name} (0x{old:04x}) - no change")
        return 0

    struct.pack_into("<H", buf, off, new)

    dst = args.out or args.file
    if not args.out and not args.no_backup:
        bak = args.file + ".bak"
        with open(args.file, "rb") as src, open(bak, "wb") as b:
            b.write(src.read())
        print(f"backup -> {bak}")

    with open(dst, "wb") as w:
        w.write(buf)

    print(f"O[{args.o}]: {'set' if args.set else 'clear'} bit {bit} in {name}  "
          f"0x{old:04x} -> 0x{new:04x}   wrote {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
