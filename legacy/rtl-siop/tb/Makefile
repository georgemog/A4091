RTL   = ../rtl/a4091.v ../rtl/a4091_bridge.v
TB    = a4091_tb.v
OUT   = a4091_tb.vvp

all: run

DEFS ?=          # set DEFS=-DA4091_DEBUG for SCRIPTS/phase tracing

# a4091.v $readmemh's this at elaboration; G2 then overwrites low bytes via rom_wr
ROMHEX = -DA4091_ROM_HEX=\"../rtl/a4091_rom.hex\"

$(OUT): $(RTL) $(TB) ../rtl/a4091_rom.hex
	iverilog -g2012 -Wall $(ROMHEX) $(DEFS) -o $(OUT) $(RTL) $(TB)

run: $(OUT)
	vvp $(OUT)

wave: run
	gtkwave a4091_tb.vcd &

clean:
	rm -f $(OUT) a4091_tb.vcd

.PHONY: all run wave clean
