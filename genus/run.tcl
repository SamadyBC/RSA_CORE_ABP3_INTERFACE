# Template Script for RTL->Gate-Level Flow
# (generated from GENUS 17.10-p007_1) 
puts "Hostname : [info hostname]"

## Preset global variables and attributes
#####################################################################
set DESIGN rsa_core
set DATE [clock format [clock seconds] -format "%b%d-%T"] 
set _OUTPUTS_PATH outputs_${DATE}
set _REPORTS_PATH reports_${DATE}

set_db / .init_lib_search_path  {../lib ../lef}
#set_db / .script_search_path {. <path>} 
set_db / .init_hdl_search_path  {../rtl}
set_db / .information_level 1

## Library setup
#####################################################################
set_db / .library {typical.lib}
set_db / .lef_library  {gsclib045_tech.lef gsclib045_macro.lef}

## Load Design
#####################################################################
read_hdl -sv "rsa_core.sv"
elaborate $DESIGN
check_design
check_design -unresolved

## Constraints Setup
#####################################################################
read_sdc ../sdc/rsa_core.sdc
check_timing_intent

if {![file exists ${_OUTPUTS_PATH}]} {
  file mkdir ${_OUTPUTS_PATH}
  puts "Creating directory ${_OUTPUTS_PATH}"
}

if {![file exists ${_REPORTS_PATH}]} {
  file mkdir ${_REPORTS_PATH}
  puts "Creating directory ${_REPORTS_PATH}"
}

## Synthesizing to generic 
#####################################################################
set_db / .syn_generic_effort medium
syn_generic
report_area   > $_REPORTS_PATH/generic/${DESIGN}_area.rpt
report_timing > $_REPORTS_PATH/generic/${DESIGN}_timing.rpt 

####################################################################################################
## Synthesizing to gates
####################################################################################################
set_db / .syn_map_effort high
syn_map
report_dp     > $_REPORTS_PATH/map/${DESIGN}_datapath.rpt
report_area   > $_REPORTS_PATH/map/${DESIGN}_area.rpt
report_power  > $_REPORTS_PATH/map/${DESIGN}_power.rpt
report_gates  > $_REPORTS_PATH/map/${DESIGN}_gates.rpt
report_timing > $_REPORTS_PATH/map/${DESIGN}_timing.rpt

#######################################################################################################
## Optimize Netlist
#######################################################################################################
# syn_opt

write_hdl     > ${_OUTPUTS_PATH}/${DESIGN}-gatelevel.v
write_script  > ${_OUTPUTS_PATH}/${DESIGN}-gatelevel.script
write_sdc     > ${_OUTPUTS_PATH}/${DESIGN}-gatelevel.sdc
write_sdf     > ${_OUTPUTS_PATH}/${DESIGN}-gatelevel.sdf
write_reports -directory ${_OUTPUTS_PATH}/ -tag "report"

#################################
### write_do_lec
#################################

#write_do_lec -golden_design fv_map -revised_design ${_OUTPUTS_PATH}/${DESIGN}_m.v -logfile  ${_LOG_PATH}/intermediate2final.lec.log > ${_OUTPUTS_PATH}/intermediate2final.lec.do
##Uncomment if the RTL is to be compared with the final netlist..
##write_do_lec -revised_design ${_OUTPUTS_PATH}/${DESIGN}_m.v -logfile ${_LOG_PATH}/rtl2final.lec.log > ${_OUTPUTS_PATH}/rtl2final.lec.do

puts "Final Runtime & Memory."
time_info FINAL
puts "============================"
puts "Synthesis Finished ........."
puts "============================"

quit
