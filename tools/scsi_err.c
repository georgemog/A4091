// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Nigel Shearman

/* scsi_err <device> <unit>
 * Provoke error paths, then confirm the device still works (recovery test).
 *  1. READ(10) 4 blocks at LBA 0x00200000 (way past a 16 MB disk)
 *  2. an illegal opcode via HD_SCSICMD
 *  3. a normal READ(10) of LBA 0 - must still succeed
 * Times each DoIO so a recovery storm (multi-second watchdog spins) is visible.
 */
#include <exec/types.h>
#include <exec/memory.h>
#include <devices/trackdisk.h>
#include <devices/scsidisk.h>
#include <dos/dos.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <clib/timer_protos.h>
#include <devices/timer.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static struct MsgPort *mp;
static struct IOExtTD  *tio;
static UBYTE *buf;

static ULONG now_ms(void)
{
    struct DateStamp ds;
    DateStamp(&ds);
    return (ULONG)ds.ds_Minute * 60000UL + (ULONG)ds.ds_Tick * 20UL;
}

static void timed_read(const char *tag, ULONG offset, ULONG len)
{
    ULONG t0, t1;
    LONG err;
    memset(buf, 0xEE, len);
    tio->iotd_Req.io_Command = CMD_READ;
    tio->iotd_Req.io_Offset  = offset;
    tio->iotd_Req.io_Data    = buf;
    tio->iotd_Req.io_Length  = len;
    tio->iotd_Req.io_Actual  = 0;
    tio->iotd_Req.io_Error   = 0;
    t0 = now_ms();
    err = DoIO((struct IORequest *)tio);
    t1 = now_ms();
    printf("  %-22s off=%lu len=%lu  err=%ld io_Error=%d  %lu ms  first=%02x %02x %02x %02x\n",
           tag, offset, len, err, tio->iotd_Req.io_Error, t1 - t0,
           buf[0], buf[1], buf[2], buf[3]);
}

static void raw_bad_opcode(void)
{
    struct SCSICmd sc;
    UBYTE cdb[6], sense[32];
    ULONG t0, t1;
    LONG err;
    memset(&sc, 0, sizeof sc);
    memset(cdb, 0, 6);
    cdb[0] = 0x1f;   /* not a real opcode */
    sc.scsi_Command    = cdb;
    sc.scsi_CmdLength  = 6;
    sc.scsi_Flags      = SCSIF_AUTOSENSE | SCSIF_READ;
    sc.scsi_SenseData  = sense;
    sc.scsi_SenseLength = sizeof sense;
    tio->iotd_Req.io_Command = HD_SCSICMD;
    tio->iotd_Req.io_Data    = &sc;
    tio->iotd_Req.io_Length  = sizeof sc;
    tio->iotd_Req.io_Actual  = 0;
    tio->iotd_Req.io_Error   = 0;
    t0 = now_ms();
    err = DoIO((struct IORequest *)tio);
    t1 = now_ms();
    printf("  %-22s err=%ld io_Error=%d status=%d sense k/asc/ascq=%02x/%02x/%02x  %lu ms\n",
           "bad opcode 0x1f", err, tio->iotd_Req.io_Error, sc.scsi_Status,
           sense[2] & 0xf, sense[12], sense[13], t1 - t0);
}

int main(int argc, char **argv)
{
    ULONG unit;
    int pass;
    if (argc < 3) { printf("usage: scsi_err <device> <unit>\n"); return 20; }
    unit = atoi(argv[2]);
    mp  = CreateMsgPort();
    tio = (struct IOExtTD *)CreateIORequest(mp, sizeof *tio);
    buf = AllocMem(8192, MEMF_ANY | MEMF_CLEAR);
    if (!mp || !tio || !buf) { printf("alloc fail\n"); return 20; }
    if (OpenDevice((CONST_STRPTR)argv[1], unit, (struct IORequest *)tio, 0)) {
        printf("OpenDevice failed err=%d\n", tio->iotd_Req.io_Error);
        return 20;
    }
    printf("recovery test on %s unit %lu\n", argv[1], unit);

    for (pass = 1; pass <= 2; pass++) {
        printf("--- pass %d ---\n", pass);
        timed_read("baseline LBA 0",    0,            2048);
        timed_read("OUT-OF-RANGE read", 0x00200000UL, 2048);   /* LBA 4M */
        raw_bad_opcode();
        timed_read("recovery LBA 0",    0,            2048);
        timed_read("recovery LBA 8",    8UL * 512,    4096);
    }
    CloseDevice((struct IORequest *)tio);
    DeleteIORequest((struct IORequest *)tio);
    DeleteMsgPort(mp);
    FreeMem(buf, 8192);
    return 0;
}
