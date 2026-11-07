#!/bin/bash
# Boots the BIOS of the Orion-PRO. Builds sim_boot (verilator) into src/sim/build, runs it from src/.
# Each run leaves a frame in build/*.ppm; the check is that the frame is not black.
set -eu
H=$(cd "$(dirname "$0")" && pwd)
S=$(cd "$H/.." && pwd)
B=$H/build
mkdir -p "$B"
"$H/vhdl2v.sh" "$B/vhdl" > /dev/null 2> "$B/vhdl.log" || { cat "$B/vhdl.log"; exit 1; }
R=$S/rtl
M=$S/../modules/rtl
SRC="$H/tb_boot.v $R/orion/orionpro_system.v $R/orion/orion_cpu.v $R/orion/orion_ppi.v $R/orion/orion_ide.v $M/mcu/hdf_ata.v $R/orion/orion_pal.v $R/orion/orion_mouse.v $R/orion/orion_video_576.v $R/orion/orion_fdd_phys.v $R/jt49/jt49.v $R/jt49/jt49_cen.v $R/jt49/jt49_div.v $R/jt49/jt49_eg.v $R/jt49/jt49_exp.v $R/jt49/jt49_noise.v $R/orion/orion_sram.v $R/orion/orion_video.v $R/orion/orion_kbd.v $R/orion/orion_loader.v $R/orion/orion_fdd_cache.v $R/fdd/wd1793.v $M/mcu/img_sdc.v $M/mem/kg_spram.v $M/mem/kg_sdpram.v $M/mem/kg_tdpram.v $B/vhdl/t80pa.v"
verilator --language 1364-2005 --cc --exe --build -j 8 -O3 --top-module tb_boot -Mdir "$B/obj" -o sim_boot \
	-Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-PINNOTFOUND \
	--x-initial fast -CFLAGS -O2 $SRC "$H/sim_boot.cpp" > "$B/build.log" 2>&1 || { tail -30 "$B/build.log"; exit 1; }
[ -z "${BUILD_ONLY:-}" ] || exit 0
cd "$S"
SIM=$B/obj/sim_boot
ROMS="--rom roms/rom2.bin:0x3E0000 --rom roms/rom1.bin:0x3F0000"
T=${BOOT_MS:-3000}
err=0
for m in ${BOOTS-0 1 2}; do
	"$SIM" $ROMS --boot $m --ms $T --ppm "$B/boot_$m.ppm"
	[ "$(tail -c +16 "$B/boot_$m.ppm" | tr -d '\000' | wc -c)" -gt 0 ] || { echo "boot $m: empty screen"; err=1; }
done
# the EGA planes and the IDE (mkrom_pro.py): sector 0 at 4000, the sector written to LBA 2 at 5000.
# A byte of page 0 at CPU address a is at SRAM 2a. The write loop counts B down from 0: the words are FF00, 00FF..
python3 "$H/mkrom_pro.py" "$B/pro.rom" "$B/pro.img"
EX="--expect 0x8000:0x00 --expect 0x8002:0xFF --expect 0x8004:0x01 --expect 0x8006:0xFE --expect 0xA000:0x00 --expect 0xA002:0xFF --expect 0xA004:0xFF --expect 0xA006:0x00"
"$SIM" --rom "$B/pro.rom:0x3F0000" --hdd "$B/pro.img" --ms 400 --ppm "$B/pro.ppm" $EX || err=1
echo "run_boot: $err errors"
exit $err
