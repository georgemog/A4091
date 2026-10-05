// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Nigel Shearman

/* A4091 software-SIOP: host unit test for the two silent-crash bugs.
 *
 *   1. Amiga Z3 fast RAM -> HPS DDR physical mapping + 16-bit byte swap
 *      (minimig_a4091.cpp :: ddr_ptr)
 *   2. big-endian guest longword <-> LE host word
 *      (a4091_lsi_glue.h :: cpu_to_le32, a4091_lsi.cpp :: read_dword)
 *
 * Values are the ones verified with `devmem` on real hardware
 * (JOURNAL 20260906-0530): the driver's scripts[] at Amiga 0x40000090
 * reads back at HPS phys 0x30000090 with each halfword swapped.
 *
 *   cc -Wall -O2 ddrmap_test.c -o ddrmap_test && ./ddrmap_test
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

/* ---- copies of the production logic (keep in sync) ------------------- */

#define A4091_AMIGA_BASE 0x40000000u
#define A4091_DDR_BASE   0x30000000u

/* minimig_a4091.cpp :: ddr_ptr() address math */
static uint32_t phys_of(uint32_t amiga_addr)
{
	return (A4091_DDR_BASE + (amiga_addr - A4091_AMIGA_BASE)) ^ 1u;
}

/* a4091_lsi_glue.h :: cpu_to_le32 (full 32-bit reverse) */
static uint32_t cpu_to_le32(uint32_t v)
{
	return ((v & 0x000000ffu) << 24) | ((v & 0x0000ff00u) << 8) |
	       ((v & 0x00ff0000u) >> 8)  | ((v & 0xff000000u) >> 24);
}

/* ---- test harness --------------------------------------------------- */

static int fails;
#define CHECK(cond, ...) do { \
	if (cond) { printf("  PASS  " __VA_ARGS__); putchar('\n'); } \
	else      { printf("  FAIL  " __VA_ARGS__); putchar('\n'); fails++; } \
} while (0)

/* Model a chunk of HPS DDR as the FPGA stores it: the Amiga writes a
 * big-endian 16-bit word; ddram_ctrl lands it byte-reversed inside the
 * LE 64-bit DDR word. So ddr[phys(A)] == amiga_be_byte(A ^ 1). */
static void ddr_store_amiga_be32(uint8_t *ddr, uint32_t amiga_addr, uint32_t val_be)
{
	uint8_t be[4] = { val_be >> 24, val_be >> 16, val_be >> 8, val_be };
	for (int k = 0; k < 4; k++)
		ddr[phys_of(amiga_addr + k) - A4091_DDR_BASE] = be[k];
}

/* What pci710_dma_rw(TO_DEVICE) must return for 4 bytes at A: the raw
 * Amiga byte stream (big-endian), i.e. amiga_be_byte(A+i). */
static void dma_read_amiga(const uint8_t *ddr, uint32_t amiga_addr, uint8_t *buf, int n)
{
	for (int i = 0; i < n; i++)
		buf[i] = ddr[phys_of(amiga_addr + i) - A4091_DDR_BASE];
}

int main(void)
{
	printf("A4091 software-SIOP :: ddrmap_test\n");

	/* 1. base + no-op offset */
	CHECK(phys_of(0x40000000) == (0x30000000u ^ 1u), "phys(0x40000000) low");
	CHECK((phys_of(0x40000090) & ~1u) == 0x30000090u, "phys(0x40000090) -> 0x30000090");
	CHECK((phys_of(0x4001b0f0) & ~1u) == 0x3001b0f0u, "phys(DSA 0x4001b0f0) -> 0x3001b0f0");

	/* 2. XOR-1: even Amiga offset -> odd DDR byte, and back */
	CHECK((phys_of(0x40000000) & 1u) == 1u, "even Amiga addr -> odd DDR byte");
	CHECK((phys_of(0x40000001) & 1u) == 0u, "odd Amiga addr  -> even DDR byte");

	/* 3. the real scripts[] head, from siop_script.ss:
	 *    scripts[0]=0x47000000  scripts[1]=0x00000150
	 *    scripts[2]=0x878b0000  scripts[3]=0x00000030
	 * On HW devmem read these back at 0x30000090 as (LE 32-bit):
	 *    0x00004700 0x01500000 0x0000878b 0x00300000
	 */
	uint8_t ddr[0x40000];
	memset(ddr, 0xEE, sizeof ddr);
	const uint32_t SCR = 0x40000090;
	const uint32_t script[4] = { 0x47000000, 0x00000150, 0x878b0000, 0x00000030 };
	for (int i = 0; i < 4; i++)
		ddr_store_amiga_be32(ddr, SCR + 4 * i, script[i]);

	/* devmem (LE host word) view must match the HW capture */
	const uint32_t devmem_le[4] = { 0x00004700, 0x01500000, 0x0000878b, 0x00300000 };
	for (int i = 0; i < 4; i++) {
		uint32_t w;
		memcpy(&w, ddr + (phys_of(SCR + 4 * i) & ~1u) - A4091_DDR_BASE, 4);
		CHECK(w == devmem_le[i], "devmem view word[%d] = %08x (want %08x)", i, w, devmem_le[i]);
	}

	/* 4. the VM's read_dword() must reconstruct the true SCRIPTS value:
	 *    read_dword = cpu_to_le32( dma_read(4 bytes, big-endian) ) */
	for (int i = 0; i < 4; i++) {
		uint8_t b[4];
		uint32_t raw;
		dma_read_amiga(ddr, SCR + 4 * i, b, 4);
		memcpy(&raw, b, 4);                 /* host is LE */
		uint32_t insn = cpu_to_le32(raw);
		CHECK(insn == script[i], "read_dword(scripts+%d) = %08x (want %08x)",
		      4 * i, insn, script[i]);
	}

	/* 5. round-trip a byte buffer (a sector-style write then read) */
	uint8_t pat[512], out[512];
	for (int i = 0; i < 512; i++) pat[i] = (uint8_t)(i * 7 + 3);
	for (int i = 0; i < 512; i++)               /* write: pat[i] -> Amiga byte i */
		ddr[phys_of(0x40010000 + i) - A4091_DDR_BASE] = pat[i];
	dma_read_amiga(ddr, 0x40010000, out, 512);
	CHECK(memcmp(pat, out, 512) == 0, "512-byte sector write/read round-trip");

	printf("\n%s (%d failure%s)\n", fails ? "FAILED" : "OK", fails, fails == 1 ? "" : "s");
	return fails ? 1 : 0;
}
