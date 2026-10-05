#!/bin/sh
# Generate the A4091 boot-ROM init files from the a4091-software image:
#   a4091_rom.hex  - one hex byte per line, for a4091.v's tb $readmemh
#   a4091_rom.mif  - Quartus MIF, for a4091.v's (* ram_init_file *) so a
#                    driver-only rebuild is a ~2 min MIF/HEX Update
#
#   git clone https://github.com/A4091/a4091-software && cd a4091-software
#   git checkout a199fa8 && git submodule update --init --recursive
#   git apply ../driver-patches/mm_siop.patch ../driver-patches/mm_sd.patch
#   PATH=/opt/amiga/bin:/opt/vbcc/bin:$PATH VBCC=/opt/vbcc make DEVICE=A4091 a4091.rom
#   ../rom/make_hex.sh a4091.rom
in="${1:-a4091.rom}"
outhex="${2:-a4091_rom.hex}"
outmif="${outhex%.hex}.mif"
[ -f "$in" ] || { echo "usage: $0 <a4091.rom> [a4091_rom.hex]"; exit 1; }

n=$(wc -c < "$in" | tr -d ' ')
[ "$n" = 32768 ] || [ "$n" = 65536 ] || { echo "expected 32K or 64K ROM, got $n"; exit 1; }

od -An -v -tx1 "$in" | tr -s ' ' '\n' | sed '/^$/d' > "$outhex"

{
	echo "DEPTH = $n;"
	echo "WIDTH = 8;"
	echo "ADDRESS_RADIX = HEX;"
	echo "DATA_RADIX = HEX;"
	echo "CONTENT BEGIN"
	od -An -v -tx1 "$in" | tr -s ' ' '\n' | sed '/^$/d' | \
		awk '{ printf "%04X : %s;\n", NR-1, toupper($0) }'
	echo "END;"
} > "$outmif"

echo "$n bytes -> $outhex + $outmif"
