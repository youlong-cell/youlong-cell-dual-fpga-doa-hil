if {[catch {
# \u4ece\u663e\u5f0f\u6e90\u96c6\u521b\u5efa\u5f53\u524d\u6536\u53d1\u7aef\u5de5\u7a0b\uff1b\u4e0d\u7efc\u5408\u3001\u4e0d\u5b9e\u73b0\u3001\u4e0d\u751f\u6210\u955c\u50cf\u6216\u64cd\u4f5c\u677f\u5361\u3002
proc doa_read_utf8 {path} {
    set f [open $path r]
    fconfigure $f -encoding utf-8 -translation auto
    set text [read $f]
    close $f
    return $text
}
proc doa_write_utf8 {path text} {
    set f [open $path w]
    fconfigure $f -encoding utf-8 -translation lf
    puts $f $text
    close $f
}
proc doa_input_check {root logdir} {
    # \u54c8\u5e0c\u5728\u72ec\u7acbPowerShell\u8fdb\u7a0b\u5b8c\u6210\uff0cVivado\u5185\u90e8\u4e0d\u53cd\u590d\u542f\u52a8\u5916\u90e8\u6821\u9a8c\u7a0b\u5e8f\u3002
    set stamp [file join $logdir INPUTS_VERIFIED.txt]
    if {![file isfile $stamp]} {error "PREFLIGHT_NOT_COMPLETED"}
    set proof [doa_read_utf8 $stamp]
    if {[string first "CATALOG=$::doa_catalog_id\n" $proof]!=0} {error "PREFLIGHT_CATALOG_MISMATCH"}
    set count [expr {[llength $::doa_input_hashes]/2}]
    if {[string first "COUNT=$count\n" $proof]<0} {error "PREFLIGHT_COUNT_MISMATCH"}
    foreach {relative expected} $::doa_input_hashes {
        if {![file isfile [file join $root $relative]]} {error "SOURCE_MISSING: $relative"}
    }
    puts "INPUT_PREFLIGHT_ACCEPTED count=$count"
}
proc doa_assert_unstarted {} {
    foreach run [get_runs] {
        set status [get_property STATUS $run]
        if {$status ne "Not started"} {error "CREATE_ONLY_RUN_STATE: $run = $status"}
    }
}
proc doa_create_side {root side logdir} {
    set spec [dict get $::doa_specs $side]
    set out [file join $root $side vivado]
    set project [file join $out [format %s.xpr $side]]
    set marker [file join $out CREATE_ONLY_VERIFIED.txt]
    if {[file exists $project]} {
        # \u5df2\u6709\u5de5\u7a0b\u4fdd\u7559\uff0c\u4e0d\u5173\u95ed\u7528\u6237GUI\u3001\u4e0d\u8986\u76d6\u6216\u81ea\u52a8\u5220\u9664\u3002
        if {![file isfile $marker] || [string first "CATALOG=$::doa_catalog_id\n" [doa_read_utf8 $marker]]!=0} {
            error "EXISTING_PROJECT_IDENTITY_UNPROVEN: $project"
        }
        puts "PROJECT_PRESERVED side=$side path=$project"
        return [list $side PRESERVED $project]
    }
    if {[file exists $out]} {error "PARTIAL_OUTPUT_EXISTS: $out"}
    file mkdir $out
    create_project $side $out -part [dict get $spec part]
    set_property target_language Verilog [current_project]
    config_ip_cache -disable_cache
    set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]
    set_property top [dict get $spec top] [get_filesets sources_1]
    foreach row [dict get $spec sources] {
        lassign $row relative role disabled
        if {[file extension $relative] eq ".bd"} {continue}
        set path [file normalize [file join $root $relative]]
        if {$role eq "constrs_1"} {
            add_files -fileset constrs_1 -norecurse [list $path]
            if {$disabled} {set_property IS_ENABLED false [get_files [list $path]]}
            if {[file tail $path] eq "cdc_handwritten_sync_guard.tcl"} {
                set_property FILE_TYPE TCL [get_files [list $path]]
                set_property USED_IN_SYNTHESIS false [get_files [list $path]]
                set_property USED_IN_IMPLEMENTATION true [get_files [list $path]]
                set_property PROCESSING_ORDER LATE [get_files [list $path]]
                set_property STEPS.OPT_DESIGN.TCL.PRE $path [get_runs impl_1]
            }
        } else {add_files -norecurse [list $path]}
    }
    set includes {}
    foreach relative [dict get $spec include_dirs] {
        lappend includes [file normalize [file join $root $relative]]
    }
    if {[llength $includes]} {
        set_property include_dirs $includes [get_filesets sources_1]
        set_property include_dirs $includes [get_filesets sim_1]
    }
    foreach relative [dict get $spec sim_sources] {
        add_files -fileset sim_1 -norecurse [list [file join $root $relative]]
    }
    set_property top [dict get $spec sim_top] [get_filesets sim_1]
    if {$side eq "transmitter"} {
        set original [file join $root transmitter ip dac_pll dac_pll.xci]
        set text [doa_read_utf8 $original]
        # \u53ea\u6539\u8f93\u51fa\u526f\u672c\u7684\u751f\u6210\u76ee\u5f55\uff0c\u5176\u4f59PLL\u53c2\u6570\u9010\u5b57\u4fdd\u6301\u3002
        set pattern {"gen_directory"\s*:\s*"[^"]*"}
        if {[regexp -all $pattern $text]!=1} {error "PLL_GENERATION_DIRECTORY_AMBIGUOUS"}
        regsub $pattern $text {"gen_directory": "../../ip_generated"} staged_text
        set stage [file join $out ip dac_pll dac_pll.xci]
        file mkdir [file dirname $stage]
        doa_write_utf8 $stage $staged_text
        import_ip [list $stage]
        generate_target all [get_ips dac_pll]
        set_property STEPS.SYNTH_DESIGN.TCL.POST \
            [file normalize [file join $root transmitter constraints apply_uart_j11.tcl]] [get_runs synth_1]
    } else {
        set bd [file join $out receiver.srcs sources_1 bd design_1 design_1.bd]
        file mkdir [file dirname $bd]
        file copy [file join $root receiver bd design_1.bd] $bd
        set_property ip_repo_paths [list [file normalize [file join $root receiver ip_repo]]] [current_project]
        update_ip_catalog
        update_compile_order -fileset sources_1
        add_files -norecurse [list $bd]
        open_bd_design $bd
        validate_bd_design
        generate_target all [get_files [list $bd]]
        foreach required {psu_init.c psu_init.h} {
            set matches [glob -nocomplain [file join [file dirname $bd] ip design_1_zynq_ultra_ps_e_0_0 $required]]
            if {[llength $matches]!=1 || [file size [lindex $matches 0]]==0} {error "PS_INIT_OUTPUT_MISSING: $required"}
        }
        set wrappers [make_wrapper -files [get_files [list $bd]] -top]
        add_files -norecurse [list $wrappers]
        set_property top [dict get $spec top] [get_filesets sources_1]
    }
    update_compile_order -fileset sources_1
    update_compile_order -fileset sim_1
    report_ip_status -file [file join $logdir [format %s_ip_status.rpt $side]]
    if {[get_property PART [current_project]] ne [dict get $spec part]} {error "CREATED_PART_MISMATCH"}
    if {[get_property TOP [get_filesets sources_1]] ne [dict get $spec top]} {error "CREATED_TOP_MISMATCH"}
    doa_assert_unstarted
    set status "CATALOG=$::doa_catalog_id\nSIDE=$side\nPART=[dict get $spec part]\nTOP=[dict get $spec top]\nSYNTHESIS=Not started\nIMPLEMENTATION=Not started\nPROJECT=$project"
    doa_write_utf8 $marker $status
    doa_write_utf8 [file join $logdir [format %s_created.txt $side]] $status
    close_project
    if {![file isfile $project]} {error "XPR_NOT_WRITTEN: $project"}
    return [list $side CREATED $project]
}
proc doa_main {} {
    if {[llength $::argv]!=2} {error "USAGE: run.tcl side log_directory"}
    if {![string match "2023.1*" [version -short]]} {error "VIVADO_2023_1_REQUIRED"}
    set root [file normalize [file join [file dirname [info script]] ..]]
    set side [lindex $::argv 0]
    if {$side ni {transmitter receiver}} {error "SIDE_INVALID"}
    set logdir [file normalize [lindex $::argv 1]]
    if {![file isdirectory $logdir]} {error "LOG_DIRECTORY_NOT_PREPARED"}
    uplevel #0 [list source [file join [file dirname [info script]] sources.tcl]]
    doa_input_check $root $logdir
    set result [doa_create_side $root $side $logdir]
    doa_write_utf8 [file join $logdir [format %s_result.txt $side]] "CREATE_PROJECT_SIDE_OK\n$result"

}
doa_main


} error_message error_options]} {
 puts stderr $error_message
 puts stderr [dict get $error_options -errorinfo]
 exit 1
}
exit 0
