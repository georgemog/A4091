/*
 * RTG direct-paint test.
 *
 * Bypasses MiSTer.card / Picasso96 / Workbench entirely: finds both boards
 * via FindConfigDev (same as rtg_test/rtg_dump) and pokes registers +
 * framebuffer + CLUT directly to force a recognisable image onto the
 * screen. Purely a diagnostic to separate "RTL/hardware path is broken"
 * from "the P96 driver's own mode-switch sequence is broken" -- if this
 * shows a real image, the whole AutoConfig/register/framebuffer chain is
 * proven end to end and the remaining bug is 100% in MiSTer.card.asm's
 * software, not the RTL. If it doesn't, the bug is in hardware/RTL.
 *
 * Draws four horizontal colour bars (red/green/blue/white) plus a border,
 * deliberately nothing like Workbench's default grey, so a pass is
 * unambiguous.
 *
 * Build: m68k-amigaos-gcc -m68020 -mcrt=nix20 -O2 -s rtg_paint.c -o rtg_paint
 */

#include <exec/types.h>
#include <libraries/configvars.h>
#include <proto/exec.h>
#include <proto/expansion.h>
#include <stdio.h>

#define RTG_MFR            0x139C
#define RTG_REG_PROD       0x03
#define RTG_FB_PROD        0x04
#define RTG_REG_SUBOFFSET  0x100
#define RTG_CLUT_SUBOFFSET 0x400
#define FB_BASE            0x27000000UL  /* ARM physical addr of the fixed DDR3 framebuffer slot */

#define REG_ADDR_HI   0x00
#define REG_ADDR_LO   0x02
#define REG_FORMAT    0x04
#define REG_ENABLE    0x06
#define REG_HSIZE     0x08
#define REG_VSIZE     0x0A
#define REG_STRIDE    0x0C

#define PAINT_WIDTH   640
#define PAINT_HEIGHT  480

static void set_clut(volatile UBYTE *regs, int index, UBYTE r, UBYTE g, UBYTE b)
{
    volatile UWORD *p = (volatile UWORD *)(regs + RTG_CLUT_SUBOFFSET + index * 4);
    p[0] = r;              /* first word: $00RR -- must be written first, see rtl/rtg.v */
    p[1] = ((UWORD)g << 8) | b; /* second word: $GGBB -- this one actually commits the entry */
}

static void wreg(volatile UBYTE *regs, int off, UWORD val)
{
    *(volatile UWORD *)(regs + off) = val;
}

int main(void)
{
    struct ConfigDev *regcd, *fbcd;
    volatile UBYTE *regs;
    volatile UBYTE *fb;
    ULONG y;
    UBYTE band;

    ExpansionBase = (struct ExpansionBase *)OpenLibrary("expansion.library", 0);
    if (!ExpansionBase) {
        printf("Cannot open expansion.library\n");
        return 20;
    }

    regcd = FindConfigDev(NULL, RTG_MFR, RTG_REG_PROD);
    fbcd  = FindConfigDev(NULL, RTG_MFR, RTG_FB_PROD);
    if (!regcd || !fbcd) {
        printf("FAIL: board(s) not found (regs=%s fb=%s)\n",
               regcd ? "ok" : "MISSING", fbcd ? "ok" : "MISSING");
        CloseLibrary((struct Library *)ExpansionBase);
        return 10;
    }

    regs = (volatile UBYTE *)regcd->cd_BoardAddr + RTG_REG_SUBOFFSET;
    fb   = (volatile UBYTE *)fbcd->cd_BoardAddr;

    printf("Painting directly -- bypassing P96/Workbench entirely.\n");
    printf("Regs at $%08X, framebuffer at $%08X\n",
           (ULONG)regcd->cd_BoardAddr, (ULONG)fbcd->cd_BoardAddr);

    /* Turn the display off while we set it up, to avoid a half-configured
       flash -- same discipline InitCard/SetGC ought to follow. */
    wreg(regs, REG_ENABLE, 0);

    /* Palette: 0=black border, 1=red, 2=green, 3=blue, 4=white. Deliberately
       nothing resembling Workbench's default $787878 grey. */
    set_clut(regs, 0, 0x00, 0x00, 0x00);
    set_clut(regs, 1, 0xFF, 0x00, 0x00);
    set_clut(regs, 2, 0x00, 0xFF, 0x00);
    set_clut(regs, 3, 0x00, 0x00, 0xFF);
    set_clut(regs, 4, 0xFF, 0xFF, 0xFF);

    /* Framebuffer: a 4-pixel black border around four horizontal colour
       bars. STRIDE == PAINT_WIDTH since this is 8bpp (1 byte/pixel). */
    for (y = 0; y < PAINT_HEIGHT; y++) {
        volatile UBYTE *row = fb + (y * PAINT_WIDTH);
        ULONG x;

        if (y < 4 || y >= PAINT_HEIGHT - 4) {
            band = 0; /* top/bottom border rows: solid black */
        } else if (y < PAINT_HEIGHT / 4) {
            band = 1; /* red */
        } else if (y < PAINT_HEIGHT / 2) {
            band = 2; /* green */
        } else if (y < 3 * PAINT_HEIGHT / 4) {
            band = 3; /* blue */
        } else {
            band = 4; /* white */
        }

        for (x = 0; x < PAINT_WIDTH; x++) {
            row[x] = (x < 4 || x >= PAINT_WIDTH - 4) ? 0 : band; /* left/right border too */
        }
    }

    /* Geometry + base, then enable last (matches the sane sequence
       rtg_dump already found the driver using: BASE/geometry set before
       ENABLE goes high). */
    wreg(regs, REG_ADDR_HI, (UWORD)(FB_BASE >> 16));
    wreg(regs, REG_ADDR_LO, (UWORD)(FB_BASE & 0xFFFF));
    wreg(regs, REG_FORMAT, 0x03);          /* 8bpp(palette) */
    wreg(regs, REG_HSIZE, PAINT_WIDTH);
    wreg(regs, REG_VSIZE, PAINT_HEIGHT);
    wreg(regs, REG_STRIDE, PAINT_WIDTH);
    wreg(regs, REG_ENABLE, 1);

    printf("\nDone. You should see: black border, then red/green/blue/white\n");
    printf("horizontal bars top to bottom, at %dx%d.\n\n", PAINT_WIDTH, PAINT_HEIGHT);
    printf("If you see that:  the entire AutoConfig/register/framebuffer/RTL\n");
    printf("                  path is proven correct end to end. The grey-\n");
    printf("                  screen bug is in MiSTer.card.asm's own mode-\n");
    printf("                  switch sequence, not the hardware.\n");
    printf("If still grey:    the bug is genuinely in RTL/hardware -- worth\n");
    printf("                  revisiting gary.v's sel_bank_1 interaction\n");
    printf("                  with the $200000-$3FFFFF range, or similar.\n");
    printf("\nRun rtg_dump again afterwards to confirm the registers still\n");
    printf("read back what this program just wrote.\n");

    CloseLibrary((struct Library *)ExpansionBase);
    return 0;
}
