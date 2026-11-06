# Command line build of the Orion-PRO core for the three boards (ISE 14.7), as the converted cores
# (msx, nes, tsconf) have it.
#
#   make                 all the boards (orionpro.kg)
#   make go|mini|minig   one board: synthesis, implementation, bitstream, .kg file
#   make minig-xst       one step: <board>-xst (.ngc), <board>-impl (.bin), <board>-core (.kg)
#   make minig-report    LUTs, slices, block RAMs and the timing result of the last build
#   make orionpro-xst       the machine alone (orionpro.prj, -iobuf NO): the fit check of docs/PLAN.md Ф0
#   make orionpro-report    its utilization from the .syr
#   make clean           the intermediate files (not the .bin / .kg files, they are in git)
#
# Inputs per board: karabas_<board>.prj (the source list, the shared modules as
# "../modules/rtl/..."), karabas_<board>.xst, karabas_<board>.ut, karabas_<board>.ucf.
# A step runs again when one of its inputs is newer than its output.
# The boards share xst/ and _ngo/, so they are built one after the other.

ISE_SETTINGS ?= /opt/Xilinx/14.7/ISE_DS/settings64.sh
PART = xc6slx25-ftg256-2
BOARDS = go mini minig

SHELL = /bin/bash
.SHELLFLAGS = -e -o pipefail -c
.NOTPARALLEL:
# settings64.sh takes the arguments of the shell that sources it: none here
XIL = source $(ISE_SETTINGS) > /dev/null;

# all boards in one file: a board build puts its bitstream in (make_core --boards)
KG = orionpro.kg
JSON = core.json

# map / par options (cost table 2 by default, the rule of all the cores)
MAP_T_go ?= 2
MAP_T_mini ?= 2
MAP_T_minig ?= 3  # -t 2 misses TS_pllx5_clkfx on placement (26110505, enc2 to serializer)
MAP = -logic_opt off -ol high -xe n -xt 3 -register_duplication off -r 4 -global_opt off -mt 2 -detail -ir off -pr b -lc auto -power off
PAR = -ol high -xe c -mt 4

# included or read by the sources, not in the prj
INCLUDES = $(wildcard ../modules/rtl/mcu/*.vh)


.PHONY: all clean $(BOARDS) $(BOARDS:=-xst) $(BOARDS:=-impl) $(BOARDS:=-core) $(BOARDS:=-report) orionpro-xst orionpro-report

all: $(BOARDS)

prj_src = $(shell sed -n 's/^[a-z]* work "\(.*\)"/\1/p' $(1) 2>/dev/null)

define board
SRC_$(1) := $$(call prj_src,karabas_$(1).prj)

karabas_$(1).ngc: karabas_$(1).prj karabas_$(1).xst $$(SRC_$(1)) $(INCLUDES)
	mkdir -p xst/projnav.tmp
	$(XIL) xst -intstyle ise -ifn karabas_$(1).xst -ofn karabas_$(1).syr

karabas_$(1).bin: karabas_$(1).ngc karabas_$(1).ucf karabas_$(1).ut
	$(XIL) ngdbuild -intstyle ise -dd _ngo -nt timestamp -uc karabas_$(1).ucf -p $(PART) karabas_$(1).ngc karabas_$(1).ngd
	$(XIL) map -intstyle ise -p $(PART) -w $(MAP) -t $(MAP_T_$(1)) -o karabas_$(1)_map.ncd karabas_$(1).ngd karabas_$(1).pcf
	$(XIL) par -w -intstyle ise $(PAR) karabas_$(1)_map.ncd karabas_$(1).ncd karabas_$(1).pcf
	$(XIL) trce -intstyle ise -v 3 -s 2 -n 3 -fastpaths -xml karabas_$(1).twx karabas_$(1).ncd -o karabas_$(1).twr karabas_$(1).pcf -ucf karabas_$(1).ucf
	$(XIL) bitgen -intstyle ise -f karabas_$(1).ut karabas_$(1).ncd

kg_$(1).stamp: karabas_$(1).bin $(JSON)
	python3 tools/check_osd.py $(JSON)
	python3 make_core.py $(JSON) $(KG) --boards $(1)
	touch $$@

$(1): kg_$(1).stamp
$(1)-xst: karabas_$(1).ngc
$(1)-impl: karabas_$(1).bin
$(1)-core: kg_$(1).stamp
$(1)-report:
	@grep -E "Number of (Slice LUTs|occupied Slices|RAMB16BWERs|RAMB8BWERs):" karabas_$(1)_map.mrp
	@grep -E "constraints? (was|were) met|constraints? not met|Timing Score" karabas_$(1).par | sort -u
endef

$(foreach b,$(BOARDS),$(eval $(call board,$(b))))



orionpro.ngc: orionpro.prj orionpro.xst $(call prj_src,orionpro.prj) $(INCLUDES)
	mkdir -p xst/projnav.tmp
	$(XIL) xst -intstyle ise -ifn orionpro.xst -ofn orionpro.syr

orionpro-xst: orionpro.ngc
orionpro-report:
	@sed -n '/Device utilization summary/,/Partition Resource Summary/p' orionpro.syr | grep -E "Number of (Slice Registers|Slice LUTs|Block RAM/FIFO|DSP48)"
	@grep -E "Minimum period|Maximum Frequency|latch" orionpro.syr | sort -u | head

clean:
	rm -f kg_*.stamp
	rm -rf xst _ngo _xmsgs xlnx_auto_0_xdb iseconfig
	rm -f $(foreach b,$(BOARDS),$(addprefix karabas_$(b),.ngc .ngd .ngr .syr .lso .bld .pcf .ncd _map.ncd _map.ngm \
		_map.map _map.mrp _map.xrpt .par .pad _pad.csv _pad.txt .twr .twx .unroutes .xpi .ptwx .bgn .bit .drc \
		_bitgen.xwbt _summary.xml _usage.xml _xst.xrpt _ngdbuild.xrpt _par.xrpt _guide.ncd))
	rm -f orionpro.ngc orionpro.ngr orionpro.syr orionpro.lso orionpro_xst.xrpt
