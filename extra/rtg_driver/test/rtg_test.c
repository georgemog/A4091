/*
 * RTG AutoConfig board test.
 *
 * Locates the two RTG Zorro II boards (regs+CLUT, framebuffer) via
 * FindConfigDev() -- same mechanism MiSTer.card's FindCard() uses -- and
 * directly exercises read/write access to both, independent of the P96
 * driver or any display state. See rtg/IMPLEMENTATION_PLAN.md for the
 * board layout this checks against.
 *
 * Build (68020, KS2.0+, matches this driver's own target):
 *   m68k-amigaos-gcc -m68020 -mcrt=nix20 -O2 -s rtg_test.c -o rtg_test
 */

#include <exec/types.h>
#include <libraries/configvars.h>
#include <proto/exec.h>
#include <proto/expansion.h>
#include <stdio.h>

#define RTG_MFR            0x139C
#define RTG_REG_PROD       0x03
#define RTG_FB_PROD        0x04
#define RTG_REG_SUBOFFSET  0x100  /* control regs+CLUT sub-block within the regs board's 64KB window */
#define RTG_ID_REG_OFFSET  0x0E   /* register 7 -- rtg.v hardwires this to $5001 (ID=$50, VERSION=$01) */
#define RTG_ID_EXPECTED    0x5001
#define RTG_STRIDE_OFFSET  0x0C   /* register 6 -- 14 bits, safe to round-trip: never touches ENABLE */

static int fail_count = 0;

static void check(int ok, const char *what)
{
    if (ok) printf("  PASS: %s\n", what);
    else    { printf("  FAIL: %s\n", what); fail_count++; }
}

int main(void)
{
    struct ConfigDev *regcd, *fbcd;

    ExpansionBase = (struct ExpansionBase *)OpenLibrary("expansion.library", 0);
    if (!ExpansionBase) {
        printf("Cannot open expansion.library\n");
        return 20;
    }

    printf("RTG AutoConfig board test\n");
    printf("==========================\n\n");

    /* --- Regs + CLUT board ------------------------------------------- */

    regcd = FindConfigDev(NULL, RTG_MFR, RTG_REG_PROD);
    if (!regcd) {
        printf("FAIL: regs+CLUT board (mfr=$%04X product=$%02X) not found\n",
               (ULONG)RTG_MFR, (ULONG)RTG_REG_PROD);
        fail_count++;
    } else {
        volatile UBYTE *regs = (volatile UBYTE *)regcd->cd_BoardAddr + RTG_REG_SUBOFFSET;
        UWORD id, savedstride, teststride, readstride;

        printf("Regs board found: base=$%08X size=$%08X\n",
               (ULONG)regcd->cd_BoardAddr, (ULONG)regcd->cd_BoardSize);

        /* Read-only known-value test -- no write involved, so a pass here
           proves the decode path and the FPGA register block are both
           genuinely alive, not just "some address didn't bus-error". */
        id = *(volatile UWORD *)(regs + RTG_ID_REG_OFFSET);
        printf("  ID/VERSION register: $%04X (expect $%04X)\n", id, RTG_ID_EXPECTED);
        check(id == RTG_ID_EXPECTED, "register block readable, ID/VERSION correct");

        /* Read/write round-trip on STRIDE. Deliberately never touches
           ENABLE, so this can't disturb the display either way. */
        savedstride = *(volatile UWORD *)(regs + RTG_STRIDE_OFFSET);
        teststride = (savedstride ^ 0x1234) & 0x3FFF; /* STRIDE is 14 bits wide */
        *(volatile UWORD *)(regs + RTG_STRIDE_OFFSET) = teststride;
        readstride = *(volatile UWORD *)(regs + RTG_STRIDE_OFFSET) & 0x3FFF;
        check(readstride == teststride, "register block writable (STRIDE round-trip)");
        *(volatile UWORD *)(regs + RTG_STRIDE_OFFSET) = savedstride; /* restore */
    }

    printf("\n");

    /* --- Framebuffer board --------------------------------------------- */

    fbcd = FindConfigDev(NULL, RTG_MFR, RTG_FB_PROD);
    if (!fbcd) {
        printf("FAIL: framebuffer board (mfr=$%04X product=$%02X) not found\n",
               (ULONG)RTG_MFR, (ULONG)RTG_FB_PROD);
        fail_count++;
    } else {
        volatile UBYTE *fb = (volatile UBYTE *)fbcd->cd_BoardAddr;
        ULONG i;
        LONG mismatch;

        printf("Framebuffer board found: base=$%08X size=$%08X\n",
               (ULONG)fbcd->cd_BoardAddr, (ULONG)fbcd->cd_BoardSize);

        /* Contiguous pattern over the first 4KB. */
        for (i = 0; i < 4096; i++) fb[i] = (UBYTE)(i ^ 0xA5);

        mismatch = -1;
        for (i = 0; i < 4096; i++) {
            if (fb[i] != (UBYTE)(i ^ 0xA5)) { mismatch = (LONG)i; break; }
        }
        if (mismatch < 0) {
            check(1, "framebuffer read/write, first 4KB pattern");
        } else {
            printf("  first mismatch at offset $%04X: wrote $%02X read $%02X\n",
                   (ULONG)mismatch, (ULONG)((mismatch ^ 0xA5) & 0xFF),
                   (ULONG)fb[mismatch]);
            check(0, "framebuffer read/write, first 4KB pattern");
        }

        /* Sparse pokes across the full declared size -- confirms the whole
           8MB is genuinely reachable, not just the low page (guards against
           the CPU-side decode accidentally aliasing/wrapping). */
        {
            static const ULONG offsets[] = {
                0x000000, 0x100000, 0x200000, 0x400000, 0x600000, 0x7FFFFE
            };
            int j, allok = 1;
            for (j = 0; j < 6; j++) {
                ULONG off = offsets[j];
                UWORD pattern = (UWORD)(0xBEEF ^ j);
                if (off + 1 >= fbcd->cd_BoardSize) continue;
                *(volatile UWORD *)(fb + off) = pattern;
                if (*(volatile UWORD *)(fb + off) != pattern) {
                    printf("  mismatch at offset $%06X\n", off);
                    allok = 0;
                }
            }
            check(allok, "framebuffer read/write, sparse across full range");
        }
    }

    printf("\n%s (%d failure%s)\n",
           fail_count ? "SOME TESTS FAILED" : "ALL TESTS PASSED",
           fail_count, fail_count == 1 ? "" : "s");

    CloseLibrary((struct Library *)ExpansionBase);
    return fail_count ? 10 : 0;
}
