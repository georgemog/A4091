// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Nigel Shearman

/* peek - dump memory. peek <hexaddr> [hexlen]  (default len 0x80) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <exec/types.h>
#include <dos/dos.h>
#include <proto/dos.h>

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

int main(int argc, char **argv)
{
    char ts[24];
    tstamp(ts); printf("[%s] peek\n", ts);
    if (argc < 2) { printf("peek <hexaddr> [hexlen]\n"); return 20; }
    ULONG a = strtoul(argv[1], 0, 16);
    ULONG n = (argc > 2) ? strtoul(argv[2], 0, 16) : 0x80;
    a &= ~1UL;
    volatile UBYTE *p = (volatile UBYTE *)a;
    for (ULONG i = 0; i < n; i += 16) {
        printf("%08lx: ", a + i);
        for (ULONG j = 0; j < 16 && i + j < n; j++) printf("%02x ", p[i + j]);
        printf(" ");
        for (ULONG j = 0; j < 16 && i + j < n; j++) {
            UBYTE c = p[i + j];
            printf("%c", (c >= 32 && c < 127) ? c : '.');
        }
        printf("\n");
    }
    return 0;
}
