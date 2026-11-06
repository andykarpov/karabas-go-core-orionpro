#!/bin/bash
# The machine on both processors. Builds sim_boot (verilator) into src/sim/build, runs it from src/.
#  1. no ROM disk: M2 prints its prompt.
#  2. ROM disk: M2 loads ORDOS, which shows VC. The frames of the two processors must be the same.
#  3. a key (Down) moves the cursor of VC: the frame differs from the one before it.
#  4. the Z80 Card ports and the AY, a test ROM (mkrom_card.py), at 2.5 and 10 MHz; its picture of 512 points
#     in build/card_*.ppm.
#  5. an ORDOS file loaded through the file loader lands in the RAM disk with its FF.
set -eu
H=$(cd "$(dirname "$0")" && pwd)
S=$(cd "$H/.." && pwd)
B=$H/build
mkdir -p "$B"
"$H/vhdl2v.sh" "$B/vhdl" > /dev/null 2> "$B/vhdl.log" || { cat "$B/vhdl.log"; exit 1; }
R=$S/rtl
SRC="$H/tb_boot.v $R/orion/orion_system.v $R/orion/orion_cpu.v $R/orion/orion_ppi.v $R/orion/orion_ide.v $R/orion/orion_video_576.v $R/orion/orion_fdd_phys.v $R/orion/orion_sd.v $R/../../modules/rtl/mem/kg_tdpram.v $R/../../modules/rtl/mcu/hdf_ata.v $R/jt49/jt49.v $R/jt49/jt49_cen.v $R/jt49/jt49_div.v $R/jt49/jt49_eg.v $R/jt49/jt49_exp.v $R/jt49/jt49_noise.v $R/orion/orion_sram.v $R/orion/orion_video.v $R/orion/orion_kbd.v $R/orion/orion_loader.v $R/orion/orion_fdd_cache.v $R/fdd/wd1793.v $S/../modules/rtl/mcu/img_sdc.v $S/../modules/rtl/mem/kg_spram.v $S/../modules/rtl/mem/kg_sdpram.v $R/vm80a/vm80a.v $B/vhdl/t80pa.v"
verilator --language 1364-2005 --cc --exe --build -j 8 -O3 --top-module tb_boot -Mdir "$B/obj" -o sim_boot \
	-Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-PINNOTFOUND \
	--x-initial fast -CFLAGS -O2 $SRC "$H/sim_boot.cpp" > "$B/build.log" 2>&1 || { tail -30 "$B/build.log"; exit 1; }
[ -z "${BUILD_ONLY:-}" ] || exit 0
cd "$S"
SIM=$B/obj/sim_boot
M2=roms/M2rk.bin:0x200000
RD=roms/romdisk1.bin:0x100000
err=0
T=${ORD_MS:-4000}
"$SIM" --rom $M2 --ms 1500 --ppm "$B/m2_8080.ppm"
"$SIM" --rom $M2 --z80 --ms 1500 --ppm "$B/m2_z80.ppm"
"$SIM" --rom $M2 --rom $RD --ms $T --ppm "$B/ord_8080.ppm"
"$SIM" --rom $M2 --rom $RD --z80 --ms $T --ppm "$B/ord_z80.ppm"
"$SIM" --rom $M2 --rom $RD --ms $((T + 800)) --key $T:E0,72 --key $((T + 100)):E0,F0,72 --ppm "$B/key_8080.ppm"
# the prompt line only (8 points x 2, from y 44): below it the cursor blinks, in another phase on each
cmp -n $((15 + (44 + 16) * 800 * 3)) "$B/m2_8080.ppm" "$B/m2_z80.ppm" || err=1
cmp "$B/ord_8080.ppm" "$B/ord_z80.ppm" || err=1
for f in m2_8080 ord_8080; do
	[ "$(tail -c +16 "$B/$f.ppm" | tr -d '\000' | wc -c)" -gt 0 ] || { echo "$f: empty screen"; err=1; }
done
if cmp -s "$B/ord_8080.ppm" "$B/key_8080.ppm"; then echo "the key changed nothing"; err=1; fi
python3 "$H/mkrom_card.py" "$B/card.rom"
head -c 65536 /dev/zero | tr '\000' '\021' > "$B/rd0.bin"
head -c 16 /dev/zero | tr '\000' '\063' > "$B/rd3.bin"
EX="--expect 0x1C000:0x5A --expect 0x1C002:0x77 --expect 0x1C004:>10 --expect 0x1C006:0xC0 --expect 0x1C008:0x33 --expect 0x1C00A:0xA5 --expect 0x1C00C:0x3C"
for sp in 0 2; do
	"$SIM" --rom "$B/card.rom:0x200000" --rom "$B/rd3.bin:0x130000" --z80 --speed $sp --ms 500 --ppm "$B/card_$sp.ppm" $EX || err=1
done
python3 - "$B/t.ord" <<'PY'
import sys
data = bytes(range(32, 96))
open(sys.argv[1], 'wb').write(b'TESTFILE' + b'\x00\x10' + len(data).to_bytes(2, 'little') + bytes(4) + data + bytes(100))
PY
# page 1: the name, the first data byte, the byte after the record (16 + 64 = 0x50)
"$SIM" --rom $M2 --ms 300 --file 100:1:"$B/t.ord" --expect 0x1:0x54 --expect 0x21:0x20 --expect 0xA1:0xFF || err=1
echo "run_boot: $err errors"
exit $err
