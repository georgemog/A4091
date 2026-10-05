// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Nigel Shearman

/* scsi_fmt <device> <unit>
 * Issue SCSI FORMAT UNIT (0x04) via HD_SCSICMD, several variants, report result.
 * Output goes to stdout (redirect to SHARE:).
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

static void hexdump(const char *tag, UBYTE *b, int n)
{
    int i;
    printf("  %s:", tag);
    for (i = 0; i < n; i++) printf(" %02x", b[i]);
    printf("\n");
}

static void try_format(const char *label, UBYTE *cdb, int cdblen,
                       UBYTE *data, int datalen, int dir)
{
    struct SCSICmd sc;
    UBYTE sense[32];
    LONG err;

    memset(&sc, 0, sizeof sc);
    memset(sense, 0, sizeof sense);
    sc.scsi_Data       = (UWORD *)data;
    sc.scsi_Length     = datalen;
    sc.scsi_Command    = cdb;
    sc.scsi_CmdLength  = cdblen;
    sc.scsi_Flags      = SCSIF_AUTOSENSE | (dir ? SCSIF_WRITE : SCSIF_READ);
    sc.scsi_SenseData  = sense;
    sc.scsi_SenseLength = sizeof sense;

    tio->iotd_Req.io_Command = HD_SCSICMD;
    tio->iotd_Req.io_Data    = &sc;
    tio->iotd_Req.io_Length  = sizeof sc;
    tio->iotd_Req.io_Actual  = 0;
    tio->iotd_Req.io_Error   = 0;

    printf("--- %s ---\n", label);
    hexdump("CDB", cdb, cdblen);
    if (datalen) hexdump("DATA-OUT", data, datalen > 16 ? 16 : datalen);

    err = DoIO((struct IORequest *)tio);

    printf("  DoIO err=%ld  io_Error=%d  scsi_Status=%d  scsi_Actual=%lu  senseActual=%d\n",
           err, tio->iotd_Req.io_Error, sc.scsi_Status,
           (unsigned long)sc.scsi_Actual, sc.scsi_SenseActual);
    if (sc.scsi_SenseActual)
        hexdump("SENSE", sense, sc.scsi_SenseActual > 18 ? 18 : sc.scsi_SenseActual);
    if (!dir && data && sc.scsi_Actual)
        hexdump("DATA-IN", data, sc.scsi_Actual > 40 ? 40 : (int)sc.scsi_Actual);
    printf("\n");
}

int main(int argc, char **argv)
{
    ULONG unit;
    UBYTE cdb[10];
    UBYTE dl[64];

    if (argc < 3) { printf("usage: scsi_fmt <device> <unit>\n"); return 20; }
    unit = atoi(argv[2]);

    mp = CreateMsgPort();
    tio = (struct IOExtTD *)CreateIORequest(mp, sizeof *tio);
    if (!mp || !tio) { printf("no port/io\n"); return 20; }

    if (OpenDevice((CONST_STRPTR)argv[1], unit, (struct IORequest *)tio, 0)) {
        printf("OpenDevice %s unit %lu FAILED err=%d\n", argv[1], unit,
               tio->iotd_Req.io_Error);
        return 20;
    }
    printf("Opened %s unit %lu\n\n", argv[1], unit);

    /* 1) FORMAT UNIT, FmtData=0, no data */
    memset(cdb, 0, 6); cdb[0] = 0x04;
    try_format("FORMAT UNIT FmtData=0 (no DATA-OUT)", cdb, 6, NULL, 0, 1);

    /* 2) FORMAT UNIT, FmtData=1, 4-byte empty defect list header */
    memset(cdb, 0, 6); cdb[0] = 0x04; cdb[1] = 0x10;   /* FmtData */
    memset(dl, 0, 4);
    try_format("FORMAT UNIT FmtData=1, empty 4-byte defect list", cdb, 6, dl, 4, 1);

    /* 3) FORMAT UNIT, FmtData=1, defect list header with IMMED-ish flags 0 */
    memset(cdb, 0, 6); cdb[0] = 0x04; cdb[1] = 0x10;
    dl[0] = 0; dl[1] = 0x00; dl[2] = 0; dl[3] = 0;
    try_format("FORMAT UNIT FmtData=1 again", cdb, 6, dl, 4, 1);

    /* 4) MODE SELECT(6), 12-byte param list (4-byte header + 8-byte block
     *    descriptor), as HDToolBox sends before a low-level format. */
    memset(cdb, 0, 6); cdb[0] = 0x15; cdb[1] = 0x10; cdb[4] = 12;  /* PF=1, len 12 */
    memset(dl, 0, 12);
    dl[3] = 8;                       /* block descriptor length */
    dl[9] = 0x02;                    /* block length 512 */
    try_format("MODE SELECT(6) 12-byte param list", cdb, 6, dl, 12, 1);

    /* 5) MODE SENSE(6) page 4 - geometry (read-back) */
    memset(cdb, 0, 6); cdb[0] = 0x1a; cdb[2] = 0x04; cdb[4] = 0x40;
    memset(dl, 0xee, 64);
    try_format("MODE SENSE(6) page 04", cdb, 6, dl, 64, 0);

    /* 6) READ DEFECT DATA(10) */
    memset(cdb, 0, 10); cdb[0] = 0x37; cdb[2] = 0x08; cdb[8] = 4;
    memset(dl, 0xee, 8);
    try_format("READ DEFECT DATA(10)", cdb, 10, dl, 4, 0);

    CloseDevice((struct IORequest *)tio);
    DeleteIORequest((struct IORequest *)tio);
    DeleteMsgPort(mp);
    return 0;
}
