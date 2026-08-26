/*
 * RTG register dump -- FIXED-ADDRESS variant, for the ORIGINAL upstream
 * core/driver (pre-AutoConfig): board lives at the classic hardcoded
 * $B80100 (regs+CLUT)/$02000000 (framebuffer), no FindConfigDev involved
 * at all. Otherwise identical to rtg_dump.c -- used to get a baseline
 * comparison against the AutoConfig'd build, to isolate whether symptoms
 * (cursor, color depth) are pre-existing or introduced by the AutoConfig
 * changes. See rtg/IMPLEMENTATION_PLAN.md.
 *
 * Build: m68k-amigaos-gcc -m68020 -mcrt=nix20 -O2 -s rtg_dump_orig.c -o rtg_dump_orig
 */

#include <exec/types.h>
#include <stdio.h>

#define RTG_REG_BASE       0x00B80100UL  /* original fixed REGISTER_BASE, control regs already included */
#define RTG_CLUT_SUBOFFSET 0x300         /* CLUT is at $B80400 = REGISTER_BASE($B80100) + $300 */

#define REG_ADDR_HI   0x00
#define REG_ADDR_LO   0x02
#define REG_FORMAT    0x04
#define REG_ENABLE    0x06
#define REG_HSIZE     0x08
#define REG_VSIZE     0x0A
#define REG_STRIDE    0x0C
#define REG_ID        0x0E

static void dump_clut_entry(volatile UBYTE *regs, int index)
{
    volatile UWORD *p = (volatile UWORD *)(regs + RTG_CLUT_SUBOFFSET + index * 4);
    UWORD w0 = p[0];
    UWORD w1 = p[1];
    printf("  CLUT[%3d] = R=$%02X G=$%02X B=$%02X\n",
           index, w0 & 0xFF, (w1 >> 8) & 0xFF, w1 & 0xFF);
}

int main(void)
{
    volatile UBYTE *regs = (volatile UBYTE *)RTG_REG_BASE;
    UWORD addr_hi, addr_lo, format, enable, hsize, vsize, stride, id;
    ULONG base;

    addr_hi = *(volatile UWORD *)(regs + REG_ADDR_HI);
    addr_lo = *(volatile UWORD *)(regs + REG_ADDR_LO);
    format  = *(volatile UWORD *)(regs + REG_FORMAT);
    enable  = *(volatile UWORD *)(regs + REG_ENABLE);
    hsize   = *(volatile UWORD *)(regs + REG_HSIZE);
    vsize   = *(volatile UWORD *)(regs + REG_VSIZE);
    stride  = *(volatile UWORD *)(regs + REG_STRIDE);
    id      = *(volatile UWORD *)(regs + REG_ID);
    base    = ((ULONG)addr_hi << 16) | addr_lo;

    printf("RTG register dump (ORIGINAL fixed-address build, regs at $%08lX)\n", RTG_REG_BASE);
    printf("================================================\n");
    printf("  ID/VERSION : $%04X  (sanity check, always $5001)\n", id);
    printf("  ENABLE     : %u        %s\n", enable & 1,
           (enable & 1) ? "(RTG output should be live)" : "(RTG output OFF)");
    printf("  BASE       : $%08X  (framebuffer address the FPGA scans out from)\n", base);
    {
        const char *depth_name;
        int bytes_per_pixel;
        switch (format & 0x07) {
            case 3:  depth_name = "8bpp indexed (palette/CLUT)"; bytes_per_pixel = 1; break;
            case 4:  depth_name = "16bpp RGB";                   bytes_per_pixel = 2; break;
            case 5:  depth_name = "24bpp RGB";                   bytes_per_pixel = 3; break;
            case 6:  depth_name = "32bpp RGBA";                  bytes_per_pixel = 4; break;
            default: depth_name = "unrecognised/reserved code";  bytes_per_pixel = 0; break;
        }
        printf("  FORMAT     : $%02X  (%s)\n", format & 0x1F, depth_name);
        if (bytes_per_pixel > 0) {
            UWORD expected_stride = (UWORD)(hsize * bytes_per_pixel);
            printf("               %d byte%s/pixel -- STRIDE for HSIZE=%u would be %u"
                   " (currently %u%s)\n",
                   bytes_per_pixel, bytes_per_pixel == 1 ? "" : "s",
                   hsize & 0x0FFF, expected_stride, stride & 0x3FFF,
                   (expected_stride == (stride & 0x3FFF)) ? ", matches" : ", MISMATCH");
        }
    }
    printf("  HSIZE      : %u\n", hsize & 0x0FFF);
    printf("  VSIZE      : %u\n", vsize & 0x0FFF);
    printf("  STRIDE     : %u bytes/line\n", stride & 0x3FFF);
    printf("\n");

    if ((format & 0x07) == 0x03) {
        int allzero, k;
        static const int sample[] = {0, 1, 2, 3, 128, 255};
        printf("FORMAT is 8bpp(palette) -- dumping a sample of the CLUT:\n");
        allzero = 1;
        for (k = 0; k < 6; k++) dump_clut_entry(regs, sample[k]);
        for (k = 0; k < 256; k++) {
            volatile UWORD *p = (volatile UWORD *)(regs + RTG_CLUT_SUBOFFSET + k * 4);
            if (p[0] != 0 || p[1] != 0) { allzero = 0; break; }
        }
        printf("  (all 256 entries all-zero: %s)\n\n", allzero ? "YES" : "no");
    }

    return 0;
}
