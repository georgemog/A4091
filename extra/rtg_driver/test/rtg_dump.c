/*
 * RTG register dump -- reads back the *current* state of every rtg.v
 * register, whatever it happens to be. Meant to be run AFTER attempting an
 * RTG screen-mode switch (e.g. right after the screen goes grey), to see
 * what the P96 driver actually wrote -- narrows "driver never set valid
 * geometry" from "geometry is fine, something else is wrong" without
 * guessing. See rtg/IMPLEMENTATION_PLAN.md for the board/register layout.
 *
 * Build: m68k-amigaos-gcc -m68020 -mcrt=nix20 -O2 -s rtg_dump.c -o rtg_dump
 */

#include <exec/types.h>
#include <libraries/configvars.h>
#include <proto/exec.h>
#include <proto/expansion.h>
#include <stdio.h>

#define RTG_MFR            0x139C
#define RTG_REG_PROD       0x03
#define RTG_REG_SUBOFFSET  0x100
#define RTG_CLUT_SUBOFFSET 0x400  /* 256 entries * 4 bytes, 00/RR/GG/BB packed as two words -- rtl/rtg.v */

/* Register word offsets from RTG_REG_SUBOFFSET, per rtl/rtg.v's REGISTER MAP */
#define REG_ADDR_HI   0x00  /* base[31:16] */
#define REG_ADDR_LO   0x02  /* base[15:0]  */
#define REG_FORMAT    0x04  /* format[4:0] */
#define REG_ENABLE    0x06  /* ena[0]      */
#define REG_HSIZE     0x08  /* hsize[11:0] */
#define REG_VSIZE     0x0A  /* vsize[11:0] */
#define REG_STRIDE    0x0C  /* stride[13:0]*/
#define REG_ID        0x0E  /* fixed $5001 */

static void dump_clut_entry(volatile UBYTE *regs, int index)
{
    volatile UWORD *p = (volatile UWORD *)(regs + RTG_CLUT_SUBOFFSET + index * 4);
    UWORD w0 = p[0]; /* $00RR */
    UWORD w1 = p[1]; /* $GGBB */
    printf("  CLUT[%3d] = R=$%02X G=$%02X B=$%02X\n",
           index, w0 & 0xFF, (w1 >> 8) & 0xFF, w1 & 0xFF);
}

int main(void)
{
    struct ConfigDev *regcd;
    volatile UBYTE *regs;
    UWORD addr_hi, addr_lo, format, enable, hsize, vsize, stride, id;
    ULONG base;

    ExpansionBase = (struct ExpansionBase *)OpenLibrary("expansion.library", 0);
    if (!ExpansionBase) {
        printf("Cannot open expansion.library\n");
        return 20;
    }

    regcd = FindConfigDev(NULL, RTG_MFR, RTG_REG_PROD);
    if (!regcd) {
        printf("FAIL: regs+CLUT board (mfr=$%04X product=$%02X) not found\n",
               (ULONG)RTG_MFR, (ULONG)RTG_REG_PROD);
        CloseLibrary((struct Library *)ExpansionBase);
        return 10;
    }

    regs = (volatile UBYTE *)regcd->cd_BoardAddr + RTG_REG_SUBOFFSET;

    addr_hi = *(volatile UWORD *)(regs + REG_ADDR_HI);
    addr_lo = *(volatile UWORD *)(regs + REG_ADDR_LO);
    format  = *(volatile UWORD *)(regs + REG_FORMAT);
    enable  = *(volatile UWORD *)(regs + REG_ENABLE);
    hsize   = *(volatile UWORD *)(regs + REG_HSIZE);
    vsize   = *(volatile UWORD *)(regs + REG_VSIZE);
    stride  = *(volatile UWORD *)(regs + REG_STRIDE);
    id      = *(volatile UWORD *)(regs + REG_ID);
    base    = ((ULONG)addr_hi << 16) | addr_lo;

    printf("RTG register dump (regs board at $%08X)\n", (ULONG)regcd->cd_BoardAddr);
    printf("================================================\n");
    printf("  ID/VERSION : $%04X  (sanity check, always $5001)\n", id);
    printf("  ENABLE     : %u        %s\n", enable & 1,
           (enable & 1) ? "(RTG output should be live)" : "(RTG output OFF -- driver never enabled it)");
    printf("  BASE       : $%08X  (framebuffer address the FPGA scans out from)\n", base);
    {
        /* FB_FORMAT[2:0] encoding, per sys/emu_ports.vh:43 (this project's
           own framework header, not guessed): 011=8bpp(palette) 100=16bpp
           101=24bpp 110=32bpp. Bytes/pixel follows directly from that. */
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
        for (k = 0; k < 6; k++) {
            dump_clut_entry(regs, sample[k]);
        }
        for (k = 0; k < 256; k++) {
            volatile UWORD *p = (volatile UWORD *)(regs + RTG_CLUT_SUBOFFSET + k * 4);
            if (p[0] != 0 || p[1] != 0) { allzero = 0; break; }
        }
        printf("  (all 256 entries all-zero: %s)\n\n", allzero ? "YES" : "no");
        if (allzero) {
            printf("DIAGNOSIS: FORMAT/geometry/enable are all correct, but the entire\n");
            printf("CLUT is zero -- the driver's SetColorArray was never called, or\n");
            printf("wrote nothing. Every indexed pixel resolves to black/undefined,\n");
            printf("which is consistent with a blank/grey screen. Check SetColorArray\n");
            printf("and whether Intuition/P96 actually invoked it for this screen.\n\n");
        }
    }

    if (!(enable & 1)) {
        printf("DIAGNOSIS: ENABLE is 0 -- the driver's mode-switch never reached\n");
        printf("the point of turning RTG output on. Check SetSwitch/SetGC.\n");
    } else if (hsize == 0 || vsize == 0) {
        printf("DIAGNOSIS: RTG is enabled but HSIZE or VSIZE is 0 -- output is on\n");
        printf("with no valid geometry, which reads as a blank/grey screen. Check\n");
        printf("SetGC -- it should have written HSIZE/VSIZE before or as part of\n");
        printf("enabling the display.\n");
    } else if (base < (ULONG)regcd->cd_BoardAddr && base != 0) {
        /* Weak sanity check only -- BASE should point at the framebuffer
           board's address range, not somewhere unrelated */
        printf("DIAGNOSIS: ENABLE and geometry look set, but BASE ($%08X) doesn't\n"
               "look like it's pointing into the framebuffer board's range --\n"
               "worth double-checking against the framebuffer board's actual\n"
               "base from rtg_test.\n", base);
    } else {
        printf("DIAGNOSIS: ENABLE, geometry, and BASE all look plausible. If the\n"
               "screen is still grey, the bug is likely downstream of these\n"
               "registers -- pixel data itself, FORMAT mismatch, or the video\n"
               "pipeline/scaler side rather than anything AutoConfig-related.\n");
    }

    CloseLibrary((struct Library *)ExpansionBase);
    return 0;
}
