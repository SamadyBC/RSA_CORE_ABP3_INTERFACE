// Log file
set log file conformal_lint.log -replace

// Read the SystemVerilog design
read design -systemverilog -golden ../rtl/rsa_core.sv

// Define the top-level module
set root module rsa_core -golden

// Report all failing RTL rule checks
report rule check -RTL -status FAIL -verbose

exit -force