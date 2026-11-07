#!/bin/bash
# The unit tests of small modules: seconds each. usage: run_unit.sh
set -eu
H=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$H/../rtl" && pwd)
B=$H/build/unit
mkdir -p "$B"
err=0
t() {   # t NAME TB SOURCES...
	local n=$1 tb=$2; shift 2
	verilator --binary -Wno-fatal -Wno-lint -Wno-style --top-module tb -Mdir "$B/$n" -o tb "$H/$tb" "$@" > "$B/$n.log" 2>&1 || { tail -20 "$B/$n.log"; err=1; return; }
	"$B/$n/tb" | tee -a "$B/$n.log" | grep -q '^PASS' && echo "$n: PASS" || { echo "$n: FAIL"; grep FAIL "$B/$n.log"; err=1; }
}
t mouse tb_mouse.v "$R/orion/orion_mouse.v"
exit $err
