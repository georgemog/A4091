# Third-party notices

This project's own code is GPL-3.0-or-later (see `LICENSE`). It also contains,
links or ships work from the projects below, under their own terms.

## Boot ROM and Amiga binaries — A4091/a4091-software

`rtl/a4091_rom.mif` (the boot ROM, baked into the FPGA core) and the release
binaries `a4091.rom`, `a4091_nodriver.rom`, `a4091.device`, `a4091d`, `ncr7xx`,
`devtest` and `A4091.guide` are built from
<https://github.com/A4091/a4091-software> at commit `a199fa8`, plus the patches
in `rom/driver-patches/`. The source is available at that URL. Each file in it
carries its own BSD-style notice. The principal ones are:

```
Copyright 2022-2025 Stefan Reinauer & Chris Hooper

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
```

The NetBSD-derived SCSI layer (`siop.c`, `scsipi*`, `sd.c` …):

```
Copyright (c) 1990 The Regents of the University of California.
All rights reserved.
Copyright (c) 1994 Michael L. Hitch

This code is derived from software contributed to Berkeley by
Van Jacobson of Lawrence Berkeley Laboratory.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
3. Neither the name of the University nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.
```

The RDB mounter (<https://github.com/A4091/mounter>), linked into the ROM:

```
Copyright 2021-2022 Toni Wilen
Copyright 2022-2026 Stefan Reinauer
Copyright 2023-2026 Matt Harlum

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
```

`devtest` is from <https://github.com/cdhooper/amiga_devtest> (BSD-2-Clause,
Chris Hooper). The ROM may also embed components from the a4091-software
`3rdparty/` submodules (ODFileSystem, TinySetPatch: BSD-2-Clause, Stefan
Reinauer). See each repository for its full text.

## 53C710 model — QEMU / WinUAE

`main_mister/a4091_lsi.cpp` is a port of WinUAE's `src/qemuvga/lsi53c710.cpp`,
taken from amiberry commit `4c21701`. That file is Toni Wilen's 53C710
adaptation of QEMU's LSI53C895A model:

```
Copyright (c) 2006 CodeSourcery.
Written by Paul Brook
This code is licensed under the LGPL.
```

`main_mister/a4091_scsi_defs.h` and `main_mister/a4091_lsi_glue.h` are trimmed or
replaced versions of WinUAE `src/qemuvga/scsi/scsi.h` and `qemuuaeglue.h`
(QEMU / Toni Wilen). WinUAE: <https://github.com/tonioni/WinUAE>, amiberry:
<https://github.com/BlitterStudio/amiberry>.

## BSD queue macros — NetBSD

`main_mister/a4091_queue.h` is NetBSD `sys/queue.h` (via QEMU and WinUAE) and
keeps its original BSD copyright notice in the file header.

## MiSTer

The patches in `core/` and `main_mister/` modify
[Minimig-AGA_MiSTer](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer) and
[Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer), both GPL-3.0.
`legacy/` contains older patch sets against the same projects.
