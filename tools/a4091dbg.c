// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Nigel Shearman

/*
 * a4091dbg - dump the A4091 SIOP debug snapshot window (board offset 0x8D0000).
 *
 * Finds the A4091 (mfg 514 / prod 84) via expansion.library, reads the
 * read-only 16-bit debug words the RTL exposes, and prints them. Run it after
 * a failed unit-0 probe (O[56]=1 + a mounted .hdf) to see where the SIOP
 * stopped: st, DSP, DBC, DSTAT/SSTAT (phase + stop reason), DIEN, dma_req,
 * and the SELECT / phase-mismatch / instruction counters.
 *
 *   m68k-amigaos-gcc -m68020 -mcrt=nix20 -O2 -s a4091dbg.c -o a4091dbg
 */
#include <exec/types.h>
#include <exec/memory.h>
#include <libraries/configregs.h>
#include <libraries/configvars.h>
#include <dos/dos.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/expansion.h>
#include <stdio.h>
#include <string.h>

/* YYYYMMDD-hhmmss from the AmigaOS clock. Just DateStamp() + a plain
 * days-since-1978 -> calendar walk: no clib time() (hangs on this box),
 * no ClockData/Amiga2Date header quirks. */
static void tstamp(char *buf)
{
    static const int md[12] = {31,28,31,30,31,30,31,31,30,31,30,31};
    struct DateStamp ds;
    long days, y, m, dm;
    int leap;

    DateStamp(&ds);
    days = ds.ds_Days;
    for (y = 1978;; y++) {
        leap = ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0);
        if (days < (leap ? 366 : 365)) break;
        days -= leap ? 366 : 365;
    }
    for (m = 0; m < 12; m++) {
        dm = md[m] + ((m == 1 && leap) ? 1 : 0);
        if (days < dm) break;
        days -= dm;
    }
    sprintf(buf, "%04ld%02ld%02ld-%02ld%02ld%02ld",
            y, m + 1, days + 1,
            (long)ds.ds_Minute / 60, (long)ds.ds_Minute % 60,
            (long)ds.ds_Tick / TICKS_PER_SECOND);
}

#define A4091_MFG   514
#define A4091_PROD  84
#define DBG_OFFSET  0x008D0000UL

static volatile UWORD *dbgwin(void)
{
    struct ConfigDev *cd = NULL;
    ExpansionBase = (APTR)OpenLibrary("expansion.library", 0);
    if (!ExpansionBase) { printf("no expansion.library\n"); return NULL; }

    while ((cd = FindConfigDev(cd, A4091_MFG, A4091_PROD))) {
        ULONG base = (ULONG)cd->cd_BoardAddr;
        printf("A4091 board @ 0x%08lx  size %lu\n", base, (ULONG)cd->cd_BoardSize);
        return (volatile UWORD *)(base + DBG_OFFSET);
    }
    printf("A4091 (mfg %d prod %d) not in the expansion list\n", A4091_MFG, A4091_PROD);
    return NULL;
}

static const char *stname(unsigned s)
{
    switch (s) {
    case 0:  return "IDLE";
    case 1:  return "FA";    case 2:  return "FB";   case 3:  return "DEC";
    case 4:  return "DISP";  case 5:  return "BM";
    case 6:  return "CMDA";  case 7:  return "CMDB"; case 8:  return "CMDX"; case 9: return "CMDW";
    case 10: return "DIA";   case 11: return "DIB";  case 12: return "DIC";
    case 13: return "DOA";   case 14: return "DOB";  case 15: return "DOC";
    case 16: return "STA";   case 17: return "STB";
    case 18: return "MIA";   case 19: return "MIB";  case 20: return "MIC";
    case 21: return "MOA";   case 22: return "MOB";  case 23: return "MOC";
    case 24: return "IO";    case 25: return "MM";
    case 26: return "RUN";   case 27: return "XFER"; case 28: return "STOP";
    case 29: return "BMADDR";case 30: return "BMPTR";case 31: return "BMPTRW";
    case 32: return "MMA";   case 33: return "MMA2"; case 34: return "MMB"; case 35: return "MMC";
    case 36: return "MMCW";  case 37: return "MMD";
    case 38: return "DOW1";  case 39: return "DOW2"; case 40: return "DIS";
    default: return "?";
    }
}

static const char *reason(unsigned r)
{
    switch (r) { case 0: return "none"; case 1: return "WDOG"; case 2: return "d8-TIMEOUT";
                 default: return "?"; }
}

int main(void)
{
    char ts[24];
    volatile UWORD *w;

    tstamp(ts);
    printf("[%s] a4091dbg\n", ts);

    w = dbgwin();
    if (!w) return 20;

    UWORD sig   = w[0x00];
    UWORD st    = w[0x01];
    ULONG dsp   = ((ULONG)w[0x03] << 16) | w[0x02];
    ULONG dbc   = ((ULONG)(w[0x05] & 0xff) << 16) | w[0x04];
    UWORD dcst  = w[0x06];   /* [15:8]=DSTAT [7:0]=DCMD */
    UWORD ss10  = w[0x07];   /* [15:8]=SSTAT1 [7:0]=SSTAT0 */
    UWORD is2   = w[0x08];   /* [15:8]=ISTAT [7:0]=SSTAT2 */
    UWORD rndn  = w[0x09];   /* [15:8]=reason [7:0]=DIEN */
    ULONG dmaa  = ((ULONG)w[0x0b] << 16) | w[0x0a];
    UWORD insns = w[0x0c];
    UWORD selpm = w[0x0d];   /* [15:8]=sel_cnt [7:0]=pmm_cnt */
    UWORD kkid  = w[0x0e];   /* [15:8]=kick_cnt [7:0]=select_id */
    UWORD ident = w[0x0f];

    printf("sig=%04x (expect a491)\n", sig);
    if (sig != 0xA491) { printf("  -> debug window not responding; wrong build?\n"); }

    printf("st        = %2u %-7s   idle=%u dma_req=%u\n",
           st & 0x3f, stname(st & 0x3f), (st >> 8) & 1, (st >> 9) & 1);
    printf("DSP       = %08lx   (where SCRIPTS stopped)\n", dsp);
    printf("DBC       = %06lx     (bytes left in the current move)\n", dbc);
    printf("DCMD      = %02x        DSTAT = %02x  [", dcst & 0xff, dcst >> 8);
    { UWORD d = dcst >> 8;
      if (d & 0x80) printf("DFE "); if (d & 0x20) printf("BF "); if (d & 0x10) printf("ABRT ");
      if (d & 0x08) printf("SSI "); if (d & 0x04) printf("SIR "); if (d & 0x02) printf("WTD ");
      if (d & 0x01) printf("IID "); }
    printf("]\n");
    printf("SSTAT0    = %02x        SSTAT1 = %02x   SSTAT2 = %02x  (phase=%u)\n",
           ss10 & 0xff, ss10 >> 8, is2 & 0xff, is2 & 0x07);
    printf("ISTAT     = %02x        DIEN   = %02x\n", is2 >> 8, rndn & 0xff);
    printf("stop rsn  = %02x %s\n", rndn >> 8, reason(rndn >> 8));
    printf("last DMA  = %08lx\n", dmaa);
    printf("counters  : insns=%u  selects=%u  phase-mismatch=%u  kicks=%u\n",
           insns, selpm >> 8, selpm & 0xff, kkid >> 8);
    printf("select_id = %02x        ident echo = %04x\n", kkid & 0xff, ident);

    {
        UWORD present  = w[0x1b] & 0x7f;
        UWORD selinfo  = w[0x1c];   /* [15:8]=sel_idb [5:3]=selphase [1:0]=selpath */
        UWORD scn      = w[0x1d];   /* [7:0]=scntl1  [10:8]=selphase */
        ULONG blocks   = ((ULONG)w[0x1f] << 16) | w[0x1e];
        static const char *pn[4] = {"none","CON-alt","STO-timeout","SELECT-ok"};
        printf("\nSELECT trace:\n");
        printf("  present bitmask = %02x   (bit N set = target id N has an image)\n", present);
        printf("  disk_blocks     = %lu\n", blocks);
        printf("  *(DSA+1) id byte= %02x   SCNTL1 = %02x\n",
               (selinfo >> 8) & 0xff, scn & 0xff);
        printf("  last S_SELC path= %u %s   phase set after select = %u\n",
               selinfo & 3, pn[selinfo & 3], (selinfo >> 3) & 7);
    }

    {
        UWORD sd = w[0x20];   /* [15:8]=mnt_cnt [2]=img_present [1]=disk_ena [0]=dbg build */
        UWORD li = w[0x21];   /* arg of last INT insn */
        UWORD rc = w[0x22];   /* [15:8]=stop reason  [7:0]=last CDB opcode */
        printf("  a4091_sd: img_mounted pulses=%u  img_present=%u  disk_ena(O56)=%u\n",
               (sd >> 8) & 0xff, (sd >> 2) & 1, (sd >> 1) & 1);
        printf("  last INT  = %04x   %s\n", li,
               li == 0xff00 ? "ok (command complete)" :
               (li & 0xff00) == 0xff00 ? "err (script error path)" : "");
        printf("  last CDB opcode = %02x   this-run stop reason = %02x\n",
               rc & 0xff, rc >> 8);
    }

    {
        UWORD s23 = w[0x23];
        int   k;
        printf("  sector-server: reads=%u  writes=%u\n", s23 & 0xff, s23 >> 8);
        {
            UWORD sd2 = w[0x3c];
            static const char *sdst[8] = {"IDLE","RD_REQ","RD_WAIT","RD_STR",
                                          "WR_FILL","WR_REQ","WR_WAIT","DONE"};
            printf("  a4091_sd FSM: st=%s  sd_rd=%u sd_wr=%u  ena=%u  secrd_caught=%u  ena_bounces=%u\n",
                   sdst[sd2 & 7], (sd2 >> 14) & 1, (sd2 >> 15) & 1,
                   (sd2 >> 13) & 1, (sd2 >> 4) & 0xf, (sd2 >> 8) & 0x1f);
        }
        printf("  DEBUG ddram a4091 DMA-accept TIMEOUT count = %u   (core-reset-domain, survives Amiga reboot)\n",
               w[0x3d]);
        printf("  target command ring (wp=%u):\n", (w[0x24] >> 10) & 3);
        for (k = 0; k < 4; k++) {
            UWORD cd = w[0x25 + k*2];
            UWORD ln = w[0x26 + k*2];
            printf("    [%d] cdb=%02x  dir=%u  len=%u\n",
                   k, cd & 0xff, (cd >> 14) & 3, ln);
        }
        {
            ULONG da = ((ULONG)w[0x31] << 16) | w[0x30];
            UWORD r0 = w[0x32], r1 = w[0x33], r2 = w[0x34], r3 = w[0x35];
            printf("  DATA-IN: total bytes=%u  last-run len=%u  first byte=%02x  @%08lx\n",
                   w[0x2d], w[0x2e], w[0x2f] >> 8, da);
            printf("  last READ CAPACITY(10) data-in: %02x %02x %02x %02x  %02x %02x %02x %02x\n",
                   r0 >> 8, r0 & 0xff, r1 >> 8, r1 & 0xff,
                   r2 >> 8, r2 & 0xff, r3 >> 8, r3 & 0xff);
            printf("    -> blocks=%lu  blksize=%lu\n",
                   ((ULONG)r0 << 16) | r1, ((ULONG)r2 << 16) | r3);
            printf("    RC10 SCRIPTS dbc0=%u  resid=%u  target rsp_len=%u  INT=%04x\n",
                   w[0x36], w[0x37], w[0x39], w[0x38]);
            printf("    RC10 data-in dest addr = %08lx   (last-run dest = %08lx)\n",
                   ((ULONG)w[0x3b] << 16) | w[0x3a], da);
        }
    }

    ULONG i0     = ((ULONG)w[0x11] << 16) | w[0x10];
    ULONG i0arg  = ((ULONG)w[0x13] << 16) | w[0x12];
    ULONG i0dsp  = ((ULONG)w[0x15] << 16) | w[0x14];
    ULONG sti    = ((ULONG)w[0x17] << 16) | w[0x16];
    ULONG stdsp  = ((ULONG)w[0x19] << 16) | w[0x18];
    printf("\nfirst insn after a kick:  @%08lx  %08lx  arg=%08lx  (op grp %lu, dcmd %02lx)\n",
           i0dsp, i0, i0arg, (i0 >> 30) & 3, (i0 >> 24) & 0xff);
    printf("insn when it last stopped: @%08lx  %08lx\n", stdsp, sti);

    /* instruction ring: last 16 decoded {dsp, insn, arg}, oldest first.
     * window @ w[0x80 + entry*8 + sub] (0x8D0100), wp at w[0x1a]. */
    {
        UWORD wp = w[0x1a] & 0x0f;
        int   k;
        printf("\ninstruction ring (wp=%u, oldest first):\n", wp);
        for (k = 0; k < 16; k++) {
            int e = (wp + k) & 0x0f;
            volatile UWORD *r = w + 0x80 + (e << 3);
            ULONG rdsp  = ((ULONG)r[1] << 16) | r[0];
            ULONG rinsn = ((ULONG)r[3] << 16) | r[2];
            ULONG rarg  = ((ULONG)r[5] << 16) | r[4];
            const char *mk = (e == ((wp - 1) & 0x0f)) ? "  <- newest" : "";
            printf("  [%2d] @%08lx  %08lx  arg=%08lx  grp%lu%s\n",
                   e, rdsp, rinsn, rarg, (rinsn >> 30) & 3, mk);
        }
    }

    { char te[24]; tstamp(te); printf("\n[%s] done\n", te); }
    if (ExpansionBase) CloseLibrary((struct Library *)ExpansionBase);
    return 0;
}
