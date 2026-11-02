# R3-Step4C: independent PS clocks; cut only asynchronous arrival at FIRST D.
# Stage1->stage2 remains normal destination-clock STA. Preserve XPM constraints.
# Top-level Tcl guard: FILE_TYPE=TCL, implementation-only, enabled, LATE.
# Assert ALL targets before ANY exception. No wildcard fallback.
proc cdc_hw_validate {} {
global cdc_hw_targets cdc_hw_seen
set cdc_hw_targets {
 {clk_pl_1 clk_pl_2 design_1_i/fft_result_bank_system_0/inst/u_bridge/claim_grant_sync1_reg/D}
 {clk_pl_1 clk_pl_2 design_1_i/fft_result_bank_system_0/inst/u_bridge/claimed0_sync1_reg/D}
 {clk_pl_1 clk_pl_2 design_1_i/fft_result_bank_system_0/inst/u_bridge/claimed1_sync1_reg/D}
 {clk_pl_1 clk_pl_2 design_1_i/fft_result_bank_system_0/inst/u_bridge/ready0_sync1_reg/D}
 {clk_pl_1 clk_pl_2 design_1_i/fft_result_bank_system_0/inst/u_bridge/ready1_sync1_reg/D}
 {clk_pl_1 clk_pl_2 design_1_i/fft_result_bank_system_0/inst/u_bridge/release_grant_sync1_reg/D}
 {clk_pl_1 clk_pl_2 design_1_i/fine_production_system_0/inst/chain/u_ps_bridge/active_sync1_reg/D}
 {clk_pl_1 clk_pl_2 design_1_i/fine_production_system_0/inst/chain/u_ps_bridge/adc_up_sync1_reg/D}
 {clk_pl_1 clk_pl_2 design_1_i/fine_production_system_0/inst/chain/u_ps_bridge/fault_sync1_reg/D}
 {clk_pl_2 clk_pl_1 design_1_i/fft_ctrl_0/inst/start_sync1_reg/D}
}
set cdc_hw_seen {}; set cdc_hw_adc_to_axi 0; set cdc_hw_axi_to_adc 0
foreach cdc_hw_row $cdc_hw_targets {
 lassign $cdc_hw_row cdc_hw_src cdc_hw_dst cdc_hw_name
 if {$cdc_hw_src eq "clk_pl_1" && $cdc_hw_dst eq "clk_pl_2"} {
  incr cdc_hw_adc_to_axi
 } elseif {$cdc_hw_src eq "clk_pl_2" && $cdc_hw_dst eq "clk_pl_1"} {
  incr cdc_hw_axi_to_adc
 } else {error "CDC_HW_ASSERT: unexpected direction"}
 if {[lsearch -exact $cdc_hw_seen $cdc_hw_name]>=0} {error "CDC_HW_ASSERT: duplicate $cdc_hw_name"}
 lappend cdc_hw_seen $cdc_hw_name
 foreach cdc_hw_clk [list $cdc_hw_src $cdc_hw_dst] {
  set cdc_hw_obj [get_clocks -quiet $cdc_hw_clk]
  if {[llength $cdc_hw_obj]!=1 || [get_property NAME $cdc_hw_obj] ne $cdc_hw_clk} {error "CDC_HW_ASSERT: exact clock missing $cdc_hw_clk"}
 }
 set cdc_hw_d2 [string map {sync1_reg/D sync2_reg/D} $cdc_hw_name]
 if {$cdc_hw_d2 eq $cdc_hw_name} {error "CDC_HW_ASSERT: invalid stage naming"}
 foreach cdc_hw_pinname [list $cdc_hw_name $cdc_hw_d2] {
  set cdc_hw_pin [get_pins -quiet $cdc_hw_pinname]
  if {[llength $cdc_hw_pin]!=1 || [get_property NAME $cdc_hw_pin] ne $cdc_hw_pinname} {error "CDC_HW_ASSERT: exact pin count/identity $cdc_hw_pinname"}
  if {[get_property REF_PIN_NAME $cdc_hw_pin] ne "D"} {error "CDC_HW_ASSERT: not D"}
  set cdc_hw_cell [get_cells -quiet -of_objects $cdc_hw_pin]
  if {[llength $cdc_hw_cell]!=1 || [get_property REF_NAME $cdc_hw_cell] ni {FDRE FDSE FDCE FDPE}} {error "CDC_HW_ASSERT: not FF $cdc_hw_pinname"}
  if {[string toupper [get_property ASYNC_REG $cdc_hw_cell]] ni {TRUE 1 YES}} {error "CDC_HW_ASSERT: missing ASYNC_REG $cdc_hw_pinname"}
  set cdc_hw_clks [get_clocks -quiet -of_objects [get_pins -of_objects $cdc_hw_cell -filter {IS_CLOCK == 1}]]
  if {[llength $cdc_hw_clks]!=1 || [get_property NAME $cdc_hw_clks] ne $cdc_hw_dst} {error "CDC_HW_ASSERT: wrong receiving clock $cdc_hw_pinname"}
 }
 set cdc_hw_qname [string range $cdc_hw_name 0 end-1]Q
 set cdc_hw_q [get_pins -quiet $cdc_hw_qname]
 if {[llength $cdc_hw_q]!=1 || [get_property NAME $cdc_hw_q] ne $cdc_hw_qname} {error "CDC_HW_ASSERT: missing first Q"}
 set cdc_hw_sinks [get_pins -quiet -leaf -of_objects [get_nets -quiet -segments -of_objects $cdc_hw_q] -filter {DIRECTION == IN}]
 if {[llength $cdc_hw_sinks]!=1 || [get_property NAME $cdc_hw_sinks] ne $cdc_hw_d2} {error "CDC_HW_ASSERT: first Q must drive ONLY stage2 D $cdc_hw_name"}
 set cdc_hw_starts [all_fanin -flat -startpoints_only -to [get_pins $cdc_hw_name]]
 set cdc_hw_clks [get_clocks -quiet -of_objects $cdc_hw_starts]
 if {[llength $cdc_hw_clks]!=1 || [get_property NAME $cdc_hw_clks] ne $cdc_hw_src} {error "CDC_HW_ASSERT: wrong source clock $cdc_hw_name"}
}
if {$cdc_hw_adc_to_axi!=9 || $cdc_hw_axi_to_adc!=1 || [llength $cdc_hw_seen]!=10} {error "CDC_HW_ASSERT: expected 9+1 exact targets"}
}
# ALL_TARGETS_VALIDATED: no exception has been applied before this boundary.
proc cdc_hw_apply {} {
 global cdc_hw_targets cdc_hw_seen
 cdc_hw_validate
 # In native project constraint loading info script refers to the outer build
 # script. Resolve the ONE registered file instead; never broaden pin matching.
 set files [get_files -all -quiet cdc_handwritten_sync.xdc]
 if {[llength $files]==1} {
  set file [get_property NAME $files]
  if {[file tail $file] ne "cdc_handwritten_sync.xdc" || [get_property FILE_TYPE $files] ne "XDC" || [get_property IS_ENABLED $files]} {error "CDC_HW_ASSERT: standalone XDC registration changed"}
 } elseif {[llength $files]==0 && [file tail [info script]] eq "cdc_handwritten_sync_guard.tcl"} {
  # Standalone DCP preflight/direct source: no project file object exists.
  set file [file join [file dirname [file normalize [info script]]] cdc_handwritten_sync.xdc]
 } else {error "CDC_HW_ASSERT: expected exactly ONE standalone registered XDC"}
 if {![file isfile $file]} {error "CDC_HW_ASSERT: missing standalone XDC"}
 set timed 0
 foreach row $cdc_hw_targets {
  lassign $row src dst pin
  incr timed [llength [get_timing_paths -quiet -no_report_unconstrained -from [get_clocks $src] -to [get_pins $pin] -max_paths 1]]
 }
 if {$timed==10} {
  source $file
 } elseif {$timed!=0} {error "CDC_HW_ASSERT: partially applied exceptions $timed/10 still timed"}
 foreach row $cdc_hw_targets {
  lassign $row src dst pin
  if {[llength [get_timing_paths -quiet -no_report_unconstrained -from [get_clocks $src] -to [get_pins $pin] -max_paths 1]]} {error "CDC_HW_ASSERT: exact first-D exception not applied"}
 }
 puts "CDC_HW_EXACT_10_ASSERTED_AND_APPLIED"
}
# One command wraps validation + application: even when Vivado catches a
# constraint-script error, the procedure cannot continue to apply exceptions.
# The same file is the opt_design PRE hook, where error is fatal to the run.
cdc_hw_apply
