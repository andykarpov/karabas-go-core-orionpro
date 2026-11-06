# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A core of the Soviet home computer Orion-PRO (Z80, 2.5 / 5 / 10 MHz, memory dispatcher, EGA-like screens, an Orion-128 compatible mode) for the Karabas Go, Mini and Mini G boards: Xilinx Spartan-6 XC6SLX25, ISE 14.7 (XST). Docs, in Russian: `docs/PLAN.md` (sources, decisions, phases), `docs/HARDWARE.md` (memory map, ports), `docs/BACKLOG.md` (open decisions, things to verify). Follow the phases; record a changed decision in PLAN.md.

All file work goes through the firmware (OSD, `FL` / `F` items, burst): no loader or soft CPU in the core. The core is GPL v3 (`LICENSE`).

The parent is `../karabas-go-core-orion128`: this core started as a copy of it, so a fix in the shared parts (`orion_sram`, `orion_video*`, `orion_kbd`, `orion_fdd_cache`, the tops, the Makefile) probably belongs in both. Also `../karabas-go-core-msx` (`wd1793`, `jt49`), `../karabas-go-core-profi` (vg93), `../karabas-go-core-menu` (800 x 600 on all boards).

## Layout

- `src/Makefile`: the ISE flow. `src/karabas_<board>.{prj,xst,ut,ucf}`: its inputs.
- `src/make_core.py`: a symlink to `../../karabas-go-tools/make_core/make_core.py`. `src/tools/check_osd.py`: the slot check of `make core`.
- `src/core.json`: the core file description (kgo2, `orionpro.kg`, all three boards).
- `src/rtl/orion/`: `orionpro_system.v` (the machine), `orion_cpu.v` (T80pa as one bus), the rest as in core-orion128.
- `src/roms/`: `rom1.bin`, `rom2.bin` (BIOS 3.21 of OriZEmu).
- `src/orionpro.prj`, `orionpro.xst`: the machine alone, `make orionpro-xst`, `make orionpro-report`.
- `modules/`: the git submodule [karabas-go-modules](https://github.com/andykarpov/karabas-go-modules), its rules are in `modules/CLAUDE.md`. Clone with `--recursive`.

## Build

- `cd src && make minig` (or `go`, `mini`; no target: all boards), `make minig-xst`, `-impl`, `-core`, `make minig-report`. The boards share `xst/` and `_ngo/`: one build at a time.
- Map with `-t 2` by default (`MAP_T_<board>`); Mini G uses `-t 3`, inherited from core-orion128 (the HDMI serializer path). XST returns 0 on an HDL error: check `ERROR` in the `.syr`.
- A new source file goes into `karabas_<board>.prj`. No coregen.
- The `.bin` and `.kg` files of a release are committed, and `build` of `core.json` is the id `YYMMDDNN`.

## Rules of the core

- **One clock, 40 MHz**, with enables, plus the 27 MHz of 576p. No derived clocks, no writes on `wr_n` edges, no latches.
- **Video: standard timing, syncs always present**: the monitor of the user rejects anything else.
- **Mini / Mini G: `FT_CLK_OUT` always carries about 8 MHz.** **Go: unused `FDC_*` outputs are 0.** **SDRAM unused**, on Mini G2 its `~CS` is the FLASH_CS_N line, drive that 1.
- **OSD:** `CMD_SWITCHES` index = position of the item in `osd`, unless the item has `"index"`. To move items without a rebuild, pin `"index"` and repack only the `.kg` (`python3 make_core.py core.json orionpro.kg`). `F` and `FL` items need different `slot` numbers.
- **Verilog-2001 that XST accepts.** Imported code keeps its form; local changes are marked `// karabas:`.
- Before a step that needs the board, tell the user. Ask before a firmware flash.
- Keep checks short: the user does not want long regressions.

## Verifying a change

- Simulate first: `src/sim/run_boot.sh` (verilator, T80 through `ghdl --synth`). Compare utilization and timing (`make minig-report`) with the build before.
- OriZEmu is the reference for the behaviour, `Sources/BIOS` of romychs/Orion-PRO for the BIOS.

## Memory

The Claude Code memory of this repo is shared with all karabas-go repos, `../karabas-go-notes`. Commit and push it after every memory change.
