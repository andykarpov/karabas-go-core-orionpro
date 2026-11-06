// karabas: the build configuration of the VG93 model (github.com/demyanenko-d/FD1793_1818VG93, via
// karabas-go-core-profi) for orion_fdd_phys: SYSCLK is clk_sys, 40 MHz, the clock of the machine.
// No VG93_TURBO_STEP: the Orion expects the step rates of a KR1818VG93 at 1 MHz.
`ifndef VG93_CONFIG_VH
`define VG93_CONFIG_VH
`define VG93_EMBEDDED                 // DRQ / INTRQ push-pull inside the FPGA
`define VG93_MFM_ONLY                 // DDEN_n tied low
`define VG93_NO_TEST                  // TEST_n tied high
`define VG93_NO_RG                    // RG not used (orion_fdd_phys runs its separator free)
`define VG93_NO_PIN33                 // /VFOE not used
`define VG93_FAST_SYSCLK              // SYSCLK >= 40 MHz, the separator gives 1-SYSCLK pulses
`endif
