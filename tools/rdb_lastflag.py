#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Nigel Shearman
"""
Show or edit the RDBFF_LAST / RDBFF_LASTLUN / RDBFF_LASTTID flags in an
Amiga RigidDiskBlock (.hdf).

Why this exists: the A4091 boot ROM's mounter walks SCSI targets in order and
stops as soon as a drive's RDB has RDBFF_LAST set:

    3rdparty/mounter/mounter.c
        md->wasLastDev = (flags & RDBFF_LAST) != 0;
        ...
        if (md->wasLastDev && !ms->ignoreLast) break;   // no further targets

HDToolBox opens each unit directly, so it still lists every drive - but at
boot only the drives up to and including the first RDBFF_LAST one get mounted.
Images partitioned independently (each one "the only drive" at the time) all
end up with the flag set, so only SCSI ID 1 mounts.

Fix: clear RDBFF_LAST on every drive except the highest SCSI ID in use.

    rdb_lastflag.py disk.hdf                 # show flags
    rdb_lastflag.py --clear-last disk.hdf    # clear RDBFF_LAST, fix checksum
    rdb_lastflag.py --set-last disk.hdf      # set it again

Writes in place; use --backup to save the RDB block first.
"""
import argparse
import struct
import sys

RDB_MAGIC = b"RDSK"
FLAGS = [
    (0, "LAST",      "no drives after this one  <- stops the A4091 mounter"),
    (1, "LASTLUN",   "no LUNs after this one"),
    (2, "LASTTID",   "no target IDs after this one"),
    (3, "NORESELECT", "do not reselect this drive"),
    (4, "DISKID",    "disk identification valid"),
    (5, "CTRLRID",   "controller identification valid"),
    (6, "SYNCH",     "drive supports synchronous SCSI mode"),
]


def find_rdb(fh, max_blocks=16, block=512):
    for n in range(max_blocks):
        fh.seek(n * block)
        data = fh.read(block)
        if data[:4] == RDB_MAGIC:
            return n, data
    return None, None


def checksum(block, summed_longs):
    """RDB checksum: the first summed_longs longwords must sum to 0."""
    total = 0
    for i in range(summed_longs):
        total = (total + struct.unpack_from(">I", block, i * 4)[0]) & 0xFFFFFFFF
    return total


def describe(flags):
    out = []
    for bit, name, why in FLAGS:
        if flags & (1 << bit):
            out.append("    bit %d %-11s %s" % (bit, name, why))
    return "\n".join(out) if out else "    (none)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--clear-last", action="store_true",
                   help="clear RDBFF_LAST so the mounter keeps scanning targets")
    g.add_argument("--set-last", action="store_true",
                   help="set RDBFF_LAST (correct for the highest SCSI ID in use)")
    ap.add_argument("--backup", metavar="FILE",
                    help="write the original RDB block here before editing")
    args = ap.parse_args()

    mode = "r+b" if (args.clear_last or args.set_last) else "rb"
    with open(args.image, mode) as fh:
        blk_no, block = find_rdb(fh)
        if block is None:
            sys.exit("%s: no RDSK block found in the first 16 blocks" % args.image)

        summed, chksum, flags = struct.unpack_from(">III", block, 4)[0], \
            struct.unpack_from(">I", block, 8)[0], \
            struct.unpack_from(">I", block, 0x14)[0]
        summed = struct.unpack_from(">I", block, 4)[0]

        print("%s: RDSK at block %d, rdb_Flags = 0x%02x" % (args.image, blk_no, flags))
        print(describe(flags))
        bad = checksum(block, summed)
        if bad:
            print("    WARNING: existing checksum does not verify (sum=0x%08x)" % bad)

        if not (args.clear_last or args.set_last):
            return

        new = (flags & ~1) if args.clear_last else (flags | 1)
        if new == flags:
            print("already %s; nothing to do" % ("clear" if args.clear_last else "set"))
            return

        if args.backup:
            with open(args.backup, "wb") as bf:
                bf.write(block)
            print("original RDB block saved to %s" % args.backup)

        block = bytearray(block)
        struct.pack_into(">I", block, 0x14, new)
        struct.pack_into(">I", block, 8, 0)              # zero the checksum field
        struct.pack_into(">I", block, 8, (-checksum(block, summed)) & 0xFFFFFFFF)
        assert checksum(block, summed) == 0

        fh.seek(blk_no * 512)
        fh.write(bytes(block))
        fh.flush()
        print("rdb_Flags 0x%02x -> 0x%02x, checksum recomputed" % (flags, new))


if __name__ == "__main__":
    main()
