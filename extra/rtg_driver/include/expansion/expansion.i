;
; Minimal expansion.library ConfigDev field offsets, only what MiSTer.card.asm
; needs (FindCard's AutoConfig lookup). Offsets verified against AROS's
; machine-generated struct dump (rom/m68kemu/m68k_offsets.txt) rather than
; retyped from memory.
;

cd_Flags     = 14
cd_BoardAddr = 32
cd_BoardSize = 36

CDB_CONFIGME = 1        ; bit number in cd_Flags; this board needs a driver to claim it
