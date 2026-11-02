# HIL20_UART J11-only physical assignments, 2026-10-17.
# Apply via apply_uart_j11.tcl: Vivado read_xdc does not execute arbitrary if/foreach.
# J11.3 <- HC05 TXD; J11.4 -> HC05 RXD; do not combine with old CP2102 XDC.
set_property PACKAGE_PIN P16 [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]
set_property PACKAGE_PIN R17 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]
