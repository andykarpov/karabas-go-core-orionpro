#!/bin/bash
# The floppy: a boot of an .odi image on the Z80 with a Monitor that loads from the disk, on the
# model of the file mounter of sim_boot. usage: run_fdd.sh MONITOR IMAGE [MS]. Build with run_boot.sh.
set -eu
H=$(cd "$(dirname "$0")" && pwd)
S=$(cd "$H/.." && pwd)
"$H/build/obj/sim_boot" --rom "$1:0x200000" --rom "$S/roms/romdisk1.bin:0x100000" --disk "$2" --z80 --ms "${3:-3000}" --ppm "$H/build/fdd.ppm"
