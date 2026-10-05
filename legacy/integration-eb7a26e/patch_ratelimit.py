import sys
p = "/opt/development/minimig/Main_MiSTer/user_io.cpp"
s = open(p).read()

# 1. Rate-limit the whole poll body. user_io_poll() runs tens of thousands of
#    times/sec for minimig; the % 90 re-mount was flooding img_mounted (~700/s)
#    and the 0x64 SPI poll was saturating the bus. Gate the body to ~every
#    64th call and cap re-mounts at a fixed count.
old_head = '''	static int polls = 0;
	static int opened = 0;
	fileTYPE *f = &sd_image[A4091_SD_SLOT];

	polls++;

	if (!opened)'''
new_head = '''	static uint32_t polls = 0;
	static int      opened = 0;
	static int      remounts = 0;
	fileTYPE *f = &sd_image[A4091_SD_SLOT];

	polls++;
	if (polls & 0x3f) return;   // throttle: run the body ~every 64th call

	if (!opened)'''
if old_head not in s: sys.exit("head not found")
s = s.replace(old_head, new_head)

# 2. Replace the flooding re-mount with a slow PERPETUAL one. A fixed cap
#    (was 250) meant that after a `load_core` reload - which resets the FPGA
#    but not this MiSTer process - the fresh a4091_sd never received SDINFO
#    and img_present stayed 0. With the 0x3f pre-throttle, 0x3fff here is a
#    re-mount roughly every ~30-60 s: negligible bus load, self-healing on
#    every core reload.
old_rm = '''	if (f->size && (polls % 90) == 0)
	{
		EnableIO();
		spi8(UIO_SET_SDINFO);
		if (io_ver) { spi32_w(f->size); spi32_w(f->size >> 32); }
		else        { spi32_b(f->size); spi32_b(f->size >> 32); }
		DisableIO();
		spi_uio_cmd8(UIO_SET_SDSTAT, (1 << A4091_SD_SLOT) | 0x80);
		a4log("  re-mount slot %d @ poll %d (size=%llu)\\n",
		      A4091_SD_SLOT, polls, (unsigned long long)f->size);
	}'''
new_rm = '''	if (f->size && (polls & 0x3fff) == 0)
	{
		remounts++;
		EnableIO();
		spi8(UIO_SET_SDINFO);
		if (io_ver) { spi32_w(f->size); spi32_w(f->size >> 32); }
		else        { spi32_b(f->size); spi32_b(f->size >> 32); }
		DisableIO();
		spi_uio_cmd8(UIO_SET_SDSTAT, (1 << A4091_SD_SLOT) | 0x80);
		if (remounts <= 8 || (remounts & 63) == 0)
			a4log("  re-mount %d @ poll %u\\n", remounts, polls);
	}'''
if old_rm not in s: sys.exit("remount block not found")
s = s.replace(old_rm, new_rm)

open(p, "w").write(s)
print("rate-limited")
