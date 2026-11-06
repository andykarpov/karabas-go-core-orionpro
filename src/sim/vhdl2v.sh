#!/bin/bash
# T80pa as a Verilog netlist (ghdl --synth), for verilator; the same way as core-msx.
set -eu
OUT=${1:?output dir}
R=$(cd "$(dirname "$0")/../rtl/t80" && pwd)
mkdir -p "$OUT"
cd "$OUT"
G="--std=93c -fexplicit --ieee=synopsys -frelaxed"
# T80.vhd: its signal ALU_Q and the output Q of its instance alu both become alu_q in the netlist
# of ghdl: a copy with the signal renamed (for the simulation only)
sed -E 's/\bALU_Q\b/ALU_Q_s/g' "$R/T80.vhd" > T80_sim.vhd
ghdl -a $G "$R/T80_Pack.vhd" "$R/T80_ALU.vhd" "$R/T80_MCode.vhd" "$R/T80_Reg.vhd" T80_sim.vhd "$R/T80pa.vhd"
ghdl --synth $G --out=verilog t80pa | sed -E -e 's/(\w)\\(\w+) /\1\2_x /g' > t80pa.v
# the generic is fixed in the netlist (its default, the value orion_cpu sets): a parameter for the
# instance; the module keeps the case of its VHDL name
python3 - <<'PY'
import re
s = open('t80pa.v').read()
m = re.search(r'\nmodule T80pa\b[^;]*;', s)
s = s[:m.end()] + '\n  parameter Mode = 0;' + s[m.end():]
open('t80pa.v', 'w').write(s)
PY
