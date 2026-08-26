/*
 * RTG framebuffer stress test -- mimics P96's software cursor access
 * pattern (rapid save/draw/erase/restore of a small block, moving position
 * each iteration) rather than rtg_test's slow, sequential, one-shot
 * read/write checks. Built because the mouse cursor is confirmed broken
 * on the new AutoConfig'd RTL (regardless of hardcoded vs FindConfigDev
 * addressing in the driver) while working fine on the original -- static
 * register/framebuffer snapshots are identical between the two (see
 * rtg_dump vs rtg_dump_orig), so if there's a real difference it's
 * dynamic/timing-related, which only a rapid access pattern can expose.
 *
 * For each iteration: save a 16x16 block, overwrite it with a marker
 * pattern and immediately verify the write landed, then restore the saved
 * block and verify THAT round-tripped too. Slides the block across a row
 * each iteration, no delays between iterations -- as tight/rapid as this
 * CPU can drive the bus.
 *
 * Build: m68k-amigaos-gcc -m68020 -mcrt=nix20 -O2 -s rtg_stress.c -o rtg_stress
 */

#include <exec/types.h>
#include <libraries/configvars.h>
#include <proto/exec.h>
#include <proto/expansion.h>
#include <stdio.h>

#define RTG_MFR       0x139C
#define RTG_FB_PROD   0x04

#define BLOCK_W       16
#define BLOCK_H       16
#define FB_WIDTH      800
#define FB_HEIGHT     600
#define ITERATIONS    2000

int main(void)
{
    struct ConfigDev *fbcd;
    volatile UBYTE *fb;
    UBYTE saved[BLOCK_H][BLOCK_W];
    ULONG iter, write_mismatches, restore_mismatches;
    LONG first_write_mismatch, first_restore_mismatch;

    ExpansionBase = (struct ExpansionBase *)OpenLibrary("expansion.library", 0);
    if (!ExpansionBase) {
        printf("Cannot open expansion.library\n");
        return 20;
    }

    fbcd = FindConfigDev(NULL, RTG_MFR, RTG_FB_PROD);
    if (!fbcd) {
        printf("FAIL: framebuffer board not found\n");
        CloseLibrary((struct Library *)ExpansionBase);
        return 10;
    }
    fb = (volatile UBYTE *)fbcd->cd_BoardAddr;

    printf("Stress test: %d iterations, %dx%d block, sliding across row 0\n",
           ITERATIONS, BLOCK_W, BLOCK_H);
    printf("Framebuffer at $%08X. No delays between iterations.\n\n",
           (ULONG)fbcd->cd_BoardAddr);

    write_mismatches = 0;
    restore_mismatches = 0;
    first_write_mismatch = -1;
    first_restore_mismatch = -1;

    for (iter = 0; iter < ITERATIONS; iter++) {
        ULONG x0 = iter % (FB_WIDTH - BLOCK_W);
        ULONG y0 = 0;
        UBYTE marker = (UBYTE)(iter & 0xFF);
        ULONG x, y;
        int mismatch_here;

        /* 1: save current block content (like P96 saving the background
           under the cursor before drawing it) */
        for (y = 0; y < BLOCK_H; y++) {
            volatile UBYTE *row = fb + (y0 + y) * FB_WIDTH + x0;
            for (x = 0; x < BLOCK_W; x++) saved[y][x] = row[x];
        }

        /* 2: draw a marker pattern (like P96 drawing the cursor image),
           then immediately verify it actually landed */
        for (y = 0; y < BLOCK_H; y++) {
            volatile UBYTE *row = fb + (y0 + y) * FB_WIDTH + x0;
            for (x = 0; x < BLOCK_W; x++) row[x] = marker;
        }
        mismatch_here = 0;
        for (y = 0; y < BLOCK_H && !mismatch_here; y++) {
            volatile UBYTE *row = fb + (y0 + y) * FB_WIDTH + x0;
            for (x = 0; x < BLOCK_W; x++) {
                if (row[x] != marker) {
                    write_mismatches++;
                    if (first_write_mismatch < 0) first_write_mismatch = (LONG)iter;
                    mismatch_here = 1;
                    break;
                }
            }
        }

        /* 3: restore the saved block (like P96 erasing the cursor/moving
           it away), then verify THAT round-tripped too */
        for (y = 0; y < BLOCK_H; y++) {
            volatile UBYTE *row = fb + (y0 + y) * FB_WIDTH + x0;
            for (x = 0; x < BLOCK_W; x++) row[x] = saved[y][x];
        }
        mismatch_here = 0;
        for (y = 0; y < BLOCK_H && !mismatch_here; y++) {
            volatile UBYTE *row = fb + (y0 + y) * FB_WIDTH + x0;
            for (x = 0; x < BLOCK_W; x++) {
                if (row[x] != saved[y][x]) {
                    restore_mismatches++;
                    if (first_restore_mismatch < 0) first_restore_mismatch = (LONG)iter;
                    mismatch_here = 1;
                    break;
                }
            }
        }
    }

    printf("Write-then-verify mismatches   : %u%s\n", write_mismatches,
           write_mismatches ? "" : "  (none -- writes always landed immediately)");
    if (first_write_mismatch >= 0)
        printf("  first at iteration %d\n", first_write_mismatch);
    printf("Restore-then-verify mismatches : %u%s\n", restore_mismatches,
           restore_mismatches ? "" : "  (none -- restores always landed immediately)");
    if (first_restore_mismatch >= 0)
        printf("  first at iteration %d\n", first_restore_mismatch);

    printf("\n%s\n", (write_mismatches || restore_mismatches)
           ? "FAIL -- rapid read-modify-write access pattern corrupts data.\n"
             "This is consistent with a timing-sensitive decode issue in the\n"
             "new RTL, not present in the old fixed-address decode."
           : "PASS -- rapid access pattern is clean. The cursor bug is likely\n"
             "NOT a framebuffer read/write timing issue -- worth looking\n"
             "elsewhere (register-side timing, or P96's own cursor state\n"
             "machine interacting with something else that changed).");

    CloseLibrary((struct Library *)ExpansionBase);
    return (write_mismatches || restore_mismatches) ? 1 : 0;
}
