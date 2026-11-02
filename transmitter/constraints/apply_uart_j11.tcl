# Fail-closed UART pin binding entry; source in an open candidate design.
# User authorized only these two UART pins. No timing exceptions or hardware action.
# Tcl checks are deliberately outside .xdc: Vivado2023.1 read_xdc rejects if/foreach.
set _hil_j11_part [get_property PART [current_design]]
if {$_hil_j11_part ne "xc7a100tfgg484-2"} {
    error "HIL20_J11_PART_MISMATCH: expected xc7a100tfgg484-2, got $_hil_j11_part"
}
foreach {_hil_j11_name _hil_j11_ball _hil_j11_direction} {uart_rx P16 IN uart_tx R17 OUT} {
    set _hil_j11_port [get_ports -quiet $_hil_j11_name]
    if {[llength $_hil_j11_port] != 1} {
        error "HIL20_J11_PORT_COUNT: $_hil_j11_name must resolve exactly once"
    }
    if {[get_property DIRECTION $_hil_j11_port] ne $_hil_j11_direction} {
        error "HIL20_J11_DIRECTION: $_hil_j11_name"
    }
    if {[llength [get_package_pins -quiet $_hil_j11_ball]] != 1} {
        error "HIL20_J11_PACKAGE_PIN_MISSING: $_hil_j11_ball"
    }
    set _hil_j11_previous [get_property PACKAGE_PIN $_hil_j11_port]
    if {$_hil_j11_previous ne "" && $_hil_j11_previous ne $_hil_j11_ball} {
        error "HIL20_J11_PREEXISTING_CONFLICT: $_hil_j11_name at $_hil_j11_previous"
    }
    foreach _hil_j11_other [get_ports -quiet *] {
        if {$_hil_j11_other ne $_hil_j11_port &&
            [get_property PACKAGE_PIN $_hil_j11_other] eq $_hil_j11_ball} {
            error "HIL20_J11_PIN_ALREADY_USED: $_hil_j11_ball"
        }
    }
}

read_xdc [file join [file dirname [file normalize [info script]]] uart_j11.xdc]
foreach {_hil_j11_name _hil_j11_ball} {uart_rx P16 uart_tx R17} {
    if {[get_property PACKAGE_PIN [get_ports $_hil_j11_name]] ne $_hil_j11_ball ||
        [get_property IOSTANDARD [get_ports $_hil_j11_name]] ne "LVCMOS33"} {
        error "HIL20_J11_POST_BINDING_FAIL: $_hil_j11_name"
    }
}
puts "HIL20_J11_BINDING_APPLIED uart_rx=P16 uart_tx=R17 LVCMOS33"

