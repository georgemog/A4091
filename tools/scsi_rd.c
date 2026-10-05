// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Nigel Shearman

/* scsi_rd <device> <unit> <nblocks>
 * One CMD_READ of nblocks*512 from LBA 0, then print the first 4 bytes of
 * each block. Deterministic ground truth for the DATA IN ring: compare the
 * output against the .hdf on the Linux side.
 * Repeats the read 3x to expose read-to-read inconsistency.
 */
#include <exec/types.h>
#include <exec/memory.h>
#include <devices/trackdisk.h>
#include <dos/dos.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    struct MsgPort *mp;
    struct IOExtTD *tio;
    ULONG unit, nblk, len;
    UBYTE *buf;
    int pass, i;

    if (argc < 4) { printf("usage: scsi_rd <device> <unit> <nblocks>\n"); return 20; }
    unit = atoi(argv[2]);
    nblk = atoi(argv[3]);
    len  = nblk * 512;

    mp  = CreateMsgPort();
    tio = (struct IOExtTD *)CreateIORequest(mp, sizeof *tio);
    buf = AllocMem(len, MEMF_ANY | MEMF_CLEAR);
    if (!mp || !tio || !buf) { printf("alloc fail\n"); return 20; }

    if (OpenDevice((CONST_STRPTR)argv[1], unit, (struct IORequest *)tio, 0)) {
        printf("OpenDevice failed err=%d\n", tio->iotd_Req.io_Error);
        return 20;
    }
    printf("CMD_READ %lu blocks (%lu bytes) from LBA 0, buf=%p\n\n",
           nblk, len, buf);

    for (pass = 1; pass <= 3; pass++) {
        LONG err;
        memset(buf, 0xEE, len);
        tio->iotd_Req.io_Command = CMD_READ;
        tio->iotd_Req.io_Offset  = 0;
        tio->iotd_Req.io_Data    = buf;
        tio->iotd_Req.io_Length  = len;
        tio->iotd_Req.io_Actual  = 0;
        tio->iotd_Req.io_Error   = 0;
        err = DoIO((struct IORequest *)tio);
        printf("pass %d: err=%ld io_Error=%d io_Actual=%lu\n",
               pass, err, tio->iotd_Req.io_Error,
               (unsigned long)tio->iotd_Req.io_Actual);
        for (i = 0; i < (int)nblk; i++) {
            UBYTE *b = buf + i * 512;
            printf("  blk %3d: %02x %02x %02x %02x\n", i, b[0], b[1], b[2], b[3]);
        }
        printf("\n");
    }

    CloseDevice((struct IORequest *)tio);
    DeleteIORequest((struct IORequest *)tio);
    DeleteMsgPort(mp);
    FreeMem(buf, len);
    return 0;
}
