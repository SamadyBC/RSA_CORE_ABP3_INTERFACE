// ---------------------------------------------------------
// Useful commands
// ---------------------------------------------------------

// Reset the current Conformal session and clear the loaded
// design and setup data.
// reset

// Write the Conformal session log to rsa_core_lec.log,
// replacing any existing file with the same name.
set log file run-svlg2gates.log -replace

// ---------------------------------------------------------
// GOLDEN: original SystemVerilog
// ---------------------------------------------------------

read design -systemverilog -golden ../rtl/rsa_core.sv

// Asks Conformal to show the detailed occurrences of rule
// RTL1.5b, including where in the RTL the mismatch occurs.
// report rule check RTL1.5b -golden -verbose

// ---------------------------------------------------------
// REVISED: Synthesized gate-level netlist
// ---------------------------------------------------------
read library -liberty -revised ../lib/typical.lib
read design -verilog -revised ../genus/synth/rsa_core-gatelevel.v

// Asks Conformal to show the detailed occurrences of rule
// RTL1.5b, including where in the RTL the mismatch occurs.
// report rule check DIR6.1 -revised -verbose

// ---------------------------------------------------------
// Top design
// ---------------------------------------------------------

set root module rsa_core -Golden
set root module rsa_core -Revised

// Uncomment this line only if you know that unreachable
// points were intentionally left unconnected in both Golden
// and Revised designs
// set mapping method -noreport_unreach

// Inspect what Conformal elaborated
report design data
report black box -detail

// ---------------------------------------------------------
// Logic equivalence checkingquit
// ---------------------------------------------------------

// Switch Conformal to Logic Equivalence Checking (LEC) mode.
set system mode lec

// Report all unmapped comparison points in the Golden and
// Revised designs.
// report unmapped points

// Add all eligible key points as comparison points between
// the Golden and Revised designs.
add compared points -all

// Compare all mapped comparison points between the Golden
// and Revised designs.
compare

// Report the final equivalence verification results for
// the compared Golden and Revised designs.
report verification

exit -force
