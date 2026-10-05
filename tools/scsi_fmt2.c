// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Nigel Shearman

/* scsi_fmt2 <device> <unit>
 * Exercise the SCSI ops HDToolBox low-level format uses:
 *   MODE SENSE, MODE SELECT, FORMAT UNIT (several defect-list sizes),
 *   WRITE(10) multi-block, READ(10) verify.
 * Output -> stdout (redirect to SHARE:).
 */
#include <exec/types.h>
#include <exec/memory.h>
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
static UBYTE *buf;   /* 64 KB chip */

static void hx(const char *t, UBYTE *b, int n)
{
    int i; printf("  %s:", t);
    for (i = 0; i < n; i++) printf(" %02x", b[i]);
    printf("\n");
}

static LONG scmd(const char *label, UBYTE *cdb, int cdblen,
                 UBYTE *data, int datalen, int write)
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

    printf("--- %s ---\n", label);
    hx("CDB", cdb, cdblen);
    err = DoIO((struct IORequest *)tio);
    printf("  err=%ld io_Error=%d status=%d actual=%lu",
           err, tio->iotd_Req.io_Error, sc.scsi_Status,
           (unsigned long)sc.scsi_Actual);
    if (sc.scsi_SenseActual) {
        printf("  SENSE key=%02x asc=%02x ascq=%02x",
               sense[2] & 0xf, sense[12], sense[13]);
    }
    printf("\n\n");
    return err ? err : tio->iotd_Req.io_Error;
}

int main(int argc, char **argv)
{
    ULONG unit;
    UBYTE cdb[10];
    int i, fails = 0;

    if (argc < 3) { printf("usage: scsi_fmt2 <device> <unit>\n"); return 20; }
    unit = atoi(argv[2]);

    mp  = CreateMsgPort();
    tio = (struct IOExtTD *)CreateIORequest(mp, sizeof *tio);
    buf = AllocMem(65536, MEMF_CHIP | MEMF_CLEAR);
    if (!mp || !tio || !buf) { printf("alloc fail\n"); return 20; }

    if (OpenDevice((CONST_STRPTR)argv[1], unit, (struct IORequest *)tio, 0)) {
        printf("OpenDevice FAILED err=%d\n", tio->iotd_Req.io_Error);
        return 20;
    }
    printf("Opened %s unit %lu\n\n", argv[1], unit);

    /* MODE SENSE(6) page 3 (format) */
    memset(cdb, 0, 6); cdb[0] = 0x1a; cdb[2] = 0x03; cdb[4] = 0x40;
    fails += !!scmd("MODE SENSE(6) pg3", cdb, 6, buf, 0x40, 0);

    /* MODE SELECT(6) - HDToolBox writes format params. 12-byte param list. */
    memset(cdb, 0, 6); cdb[0] = 0x15; cdb[1] = 0x10; cdb[4] = 12;
    memset(buf, 0, 12);
    buf[3] = 8;                 /* block descriptor length */
    fails += !!scmd("MODE SELECT(6) 12B", cdb, 6, buf, 12, 1);

    /* FORMAT UNIT, FmtData=1, defect list header only (len=0) */
    memset(cdb, 0, 6); cdb[0] = 0x04; cdb[1] = 0x10;
    memset(buf, 0, 4);
    fails += !!scmd("FORMAT UNIT FmtData=1 hdr-only", cdb, 6, buf, 4, 1);

    /* FORMAT UNIT, FmtData=1, defect list length 508 (total 512) */
    memset(cdb, 0, 6); cdb[0] = 0x04; cdb[1] = 0x10;
    memset(buf, 0, 512);
    buf[2] = 508 >> 8; buf[3] = 508 & 0xff;
    fails += !!scmd("FORMAT UNIT FmtData=1 512B defect list", cdb, 6, buf, 512, 1);

    /* WRITE(10) 8 blocks (surface-format style) */
    memset(cdb, 0, 10); cdb[0] = 0x2a;
    cdb[2]=0; cdb[3]=0; cdb[4]=0x01; cdb[5]=0x10;   /* lba 272 */
    cdb[7]=0; cdb[8]=8;                              /* 8 blocks */
    for (i = 0; i < 8*512; i++) buf[i] = (UBYTE)(i & 0xff);
    fails += !!scmd("WRITE(10) 8 blk @lba272", cdb, 10, buf, 8*512, 1);

    /* READ(10) back, verify */
    memset(cdb, 0, 10); cdb[0] = 0x28;
    cdb[2]=0; cdb[3]=0; cdb[4]=0x01; cdb[5]=0x10;
    cdb[7]=0; cdb[8]=8;
    memset(buf, 0xEE, 8*512);
    fails += !!scmd("READ(10) 8 blk @lba272", cdb, 10, buf, 8*512, 0);
    {
        int bad = 0;
        for (i = 0; i < 8*512; i++) if (buf[i] != (UBYTE)(i & 0xff)) bad++;
        printf("  verify: %d / %d bytes mismatch\n\n", bad, 8*512);
        if (bad) fails++;
    }

    printf("=== %s (%d failing steps) ===\n", fails ? "FAIL" : "ALL PASS", fails);

    CloseDevice((struct IORequest *)tio);
    DeleteIORequest((struct IORequest *)tio);
    DeleteMsgPort(mp);
    FreeMem(buf, 65536);
    return fails ? 5 : 0;
}
