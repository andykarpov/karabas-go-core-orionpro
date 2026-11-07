# Orion-PRO core for Karabas Go / Mini / Mini G

A core of the Soviet home computer Orion-PRO (Orionsoft, 1993–2000) for the Karabas Go family of boards (Xilinx Spartan-6 XC6SLX25). Built for all three boards; checked on Mini G, Go and Mini not tried yet. Sibling of [karabas-go-core-orion128](https://github.com/andykarpov/karabas-go-core-orion128).

What works: Z80 at 2.5 / 5 / 10 MHz, up to 2 MB of RAM with the memory dispatcher, ROM1 / ROM2 3.21 (built in), the BIOS menu, Monitor and tests, the Orion-128 compatibility mode with the ROM2 shell, the screens of the Orion-128 and the 16-colour modes with the Multicard palette, RK-86 and MS7007 keyboards, two floppy drives (`.odi`), IDE hard disks, the RTC of the board, AY, the Multicard mouse (USB mouse), COM1 through the firmware. AltairDOS / Best-DOS boots from a floppy image.

- [README.ru.md](README.ru.md): this page in Russian.
- [docs/GUIDE.md](docs/GUIDE.md): **how to use it** (Russian): what to put on the SD card, how to make a system floppy, what to load in which order.
- [docs/PLAN.md](docs/PLAN.md): research, decisions and phases (Russian).
- [docs/HARDWARE.md](docs/HARDWARE.md): the supported hardware, memory map and ports (Russian).
- [docs/BACKLOG.md](docs/BACKLOG.md): open questions and findings (Russian).

Clone with `--recursive`: the board modules are the submodule `modules/` ([karabas-go-modules](https://github.com/andykarpov/karabas-go-modules)). `src/make_core.py` needs [karabas-go-tools](https://github.com/andykarpov/karabas-go-tools) next to this repository.

ROM1 and ROM2 3.21 are from [OriZEmu](https://github.com/serge-404/OriZEmu); the behaviour of the ports follows OriZEmu in its v3.20 mode.

License: GPL v3.
