// Uncomment the next line for 115200; leave commented for 9600, then rebuild.
// `define HIL20_UART_USE_115200
// Build script --baud 115200 supplies the same selector externally.
// This selects FPGA timing; it does NOT configure/identify the HC05 module.
`ifndef HIL20_UART_BAUD_CONFIG_VH
`define HIL20_UART_BAUD_CONFIG_VH
`ifdef HIL20_UART_USE_115200
    `define HIL20_UART_BAUD 115200
`else
    `define HIL20_UART_BAUD 9600
`endif
`endif
