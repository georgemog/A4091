// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Nigel Shearman

/* scsi_wr6 <device> <unit> [blocks] [lba]
 * Issue a raw SCSI WRITE(6) via HD_SCSICMD - reproduces the HDToolBox
 * low-level-format bulk write (0a 00 00 00 88 = 136 blocks at LBA 0) that
 * hangs the a4091 software SIOP.  Then a READ(6) of the same range to check
 * data + confirm the bus survived.  Output -> stdout (redirect to SHARE:).
 */
#include <exec/types.h>
#include <exec/memory.h>
#include <exec/io.h>
#include <devices/scsidisk.h>
#include <devices/trackdisk.h>
#include <dos/dos.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static struct MsgPort *mp;
static struct IOExtTD  *tio;

static LONG docmd(const char *label, UBYTE *cdb, int cdblen,
                  UBYTE *data, ULONG datalen, int write)
{
    struct SCSICmd sc;
    UBYTE sense[32];
    LONG err;

    memset(&sc, 0, sizeof sc);
    memset(sense, 0, sizeof sense);
    sc.scsi_Data        = (UWORD *)data;
    sc.scsi_Length      = datalen;
    sc.scsi_Command     = cdb;
    sc.scsi_CmdLength   = cdblen;
    sc.scsi_Flags       = SCSIF_AUTOSENSE | (write ? SCSIF_WRITE : SCSIF_READ);
    sc.scsi_SenseData   = sense;
    sc.scsi_SenseLength = sizeof sense;

    tio->iotd_Req.io_Command = HD_SCSICMD;
    tio->iotd_Req.io_Data    = &sc;
    tio->iotd_Req.io_Length  = sizeof sc;
    tio->iotd_Req.io_Actual  = 0;
    tio->iotd_Req.io_Error   = 0;

    printf("--- %s (cdb %02x %02x %02x %02x %02x %02x, %lu bytes) ---\n",
           label, cdb[0], cdb[1], cdb[2], cdb[3], cdb[4], cdb[5],
           (unsigned long)datalen);
    err = DoIO((struct IORequest *)tio);
    printf("  DoIO err=%ld io_Error=%d scsi_Status=%d scsi_Actual=%lu senseKey=%02x asc=%02x/%02x\n",
           err, tio->iotd_Req.io_Error, sc.scsi_Status,
           (unsigned long)sc.scsi_Actual,
           sense[2] & 0x0f, sense[12], sense[13]);
    return err;
}

int main(int argc, char **argv)
{
    ULONG unit, blocks = 136, lba = 0, i, bytes;
    UBYTE cdb[6];
    UBYTE *buf;

    if (argc < 3) { printf("usage: scsi_wr6 <device> <unit> [blocks] [lba]\n"); return 20; }
    unit = atoi(argv[2]);
    if (argc > 3) blocks = atoi(argv[3]);
    if (argc > 4) lba = atoi(argv[4]);
    if (blocks < 1 || blocks > 255) { printf("blocks 1..255\n"); return 20; }
    bytes = blocks * 512;

    buf = AllocMem(bytes, MEMF_PUBLIC | MEMF_CLEAR);
    if (!buf) { printf("no buf\n"); return 20; }
    for (i = 0; i < bytes; i++) buf[i] = (UBYTE)(0xA0 + (i & 0x1f));

    mp = CreateMsgPort();
    tio = (struct IOExtTD *)CreateIORequest(mp, sizeof *tio);
    if (!mp || !tio) { printf("no port/io\n"); return 20; }
    if (OpenDevice((CONST_STRPTR)argv[1], unit, (struct IORequest *)tio, 0)) {
        printf("OpenDevice %s unit %lu FAILED err=%d\n", argv[1], unit, tio->iotd_Req.io_Error);
        return 20;
    }
    printf("Opened %s unit %lu ; WRITE(6) %lu blocks @ LBA %lu\n\n", argv[1], unit, blocks, lba);

    memset(cdb, 0, 6);
    cdb[0] = 0x0a;
    cdb[1] = (lba >> 16) & 0x1f;
    cdb[2] = (lba >> 8) & 0xff;
    cdb[3] = lba & 0xff;
    cdb[4] = blocks & 0xff;              /* 0 would mean 256 */
    docmd("WRITE(6) with data", cdb, 6, buf, bytes, 1);

    /* HDToolBox low-level format: WRITE(6) with block count but NO data
     * buffer - it expects the drive to zero the blocks itself. */
    docmd("WRITE(6) no-data (HDToolBox low-level format)", cdb, 6, NULL, 0, 1);

    memset(buf, 0, bytes);
    memset(cdb, 0, 6);
    cdb[0] = 0x08;
    cdb[1] = (lba >> 16) & 0x1f;
    cdb[2] = (lba >> 8) & 0xff;
    cdb[3] = lba & 0xff;
    cdb[4] = blocks & 0xff;
    docmd("READ(6) verify", cdb, 6, buf, bytes, 0);
    printf("  first16:");
    for (i = 0; i < 16; i++) printf(" %02x", buf[i]);
    printf("\n");

    CloseDevice((struct IORequest *)tio);
    DeleteIORequest((struct IORequest *)tio);
    DeleteMsgPort(mp);
    FreeMem(buf, bytes);
    printf("\ndone\n");
    return 0;
}
