# HIL20_UART candidate base constraints, 2026-10-17.
# Mechanical copy of original constraints excluding ONLY four legacy UART assignments.
# DAC/keys/LED/clocks/delays unchanged; use together with uart_j11.xdc.

# Configuration interface settings.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]

# 200 MHz differential reference clock. The Clocking Wizard XDC creates the
# 5.000 ns primary clock on
# sys_clk_p. Do not duplicate that create_clock here.
set_property PACKAGE_PIN R4 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {sys_clk_p sys_clk_n}]
set_property PACKAGE_PIN T4 [get_ports sys_clk_n]

# External reset and USB-UART pins.
set_property PACKAGE_PIN T6 [get_ports rst_n]
set_property IOSTANDARD LVCMOS15 [get_ports rst_n]
set_property PULLUP true [get_ports rst_n]

# UART pins intentionally moved to companion uart_j11.xdc.
# Do not import the original legacy CP2102 pin assignments.

# Board keys and LEDs. Pin locations and active levels follow the ALINX
# 02_key_test / A_KEY examples for the AX7103: keys are active low (pressed = 0)
# and LEDs are lit by a high level. key_in[0] is the mode key (KEY0); key_in[1]
# is the output enable toggle (KEY1).
#
# LED mapping matches the ALINX silk-screen numbering exactly:
#   led[0]=D15  led[1]=D14  led[2]=C13  led[3]=B13
# Source: A7/A_KEY/A_KEY.srcs/constrs_1/new/pin.xdc and
#         A7/Alinx/Alinx.srcs/constrs_1/new/pin.xdc (both agree).
# NOTE 2026-09-24: the previous revision mapped led[0]->B13 and led[1]->C13,
# which are physically LED3 and LED2 on the silk screen. With 4 LEDs now used
# the indices are aligned with the silk screen to avoid off-by-two confusion.
set_property PACKAGE_PIN J21 [get_ports {key_in[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {key_in[0]}]
set_property PACKAGE_PIN E13 [get_ports {key_in[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {key_in[1]}]

set_property PACKAGE_PIN D15 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property PACKAGE_PIN D14 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property PACKAGE_PIN C13 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
set_property PACKAGE_PIN B13 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]

# AN9767 channel 1 on AX7103 J13.
set_property PACKAGE_PIN W16 [get_ports {da1_data[13]}]
set_property PACKAGE_PIN W15 [get_ports {da1_data[12]}]
set_property PACKAGE_PIN V17 [get_ports {da1_data[11]}]
set_property PACKAGE_PIN W17 [get_ports {da1_data[10]}]
set_property PACKAGE_PIN U15 [get_ports {da1_data[9]}]
set_property PACKAGE_PIN V15 [get_ports {da1_data[8]}]
set_property PACKAGE_PIN AB21 [get_ports {da1_data[7]}]
set_property PACKAGE_PIN AB22 [get_ports {da1_data[6]}]
set_property PACKAGE_PIN AA21 [get_ports {da1_data[5]}]
set_property PACKAGE_PIN AA20 [get_ports {da1_data[4]}]
set_property PACKAGE_PIN AB20 [get_ports {da1_data[3]}]
set_property PACKAGE_PIN AA19 [get_ports {da1_data[2]}]
set_property PACKAGE_PIN AA18 [get_ports {da1_data[1]}]
set_property PACKAGE_PIN AB18 [get_ports {da1_data[0]}]
set_property PACKAGE_PIN T20 [get_ports da1_wrt]
set_property PACKAGE_PIN Y17 [get_ports da1_clk]

# AN9767 channel 2 on AX7103 J13.
set_property PACKAGE_PIN T21 [get_ports {da2_data[13]}]
set_property PACKAGE_PIN U21 [get_ports {da2_data[12]}]
set_property PACKAGE_PIN Y21 [get_ports {da2_data[11]}]
set_property PACKAGE_PIN Y22 [get_ports {da2_data[10]}]
set_property PACKAGE_PIN W20 [get_ports {da2_data[9]}]
set_property PACKAGE_PIN W19 [get_ports {da2_data[8]}]
set_property PACKAGE_PIN Y19 [get_ports {da2_data[7]}]
set_property PACKAGE_PIN Y18 [get_ports {da2_data[6]}]
set_property PACKAGE_PIN V22 [get_ports {da2_data[5]}]
set_property PACKAGE_PIN U22 [get_ports {da2_data[4]}]
set_property PACKAGE_PIN T18 [get_ports {da2_data[3]}]
set_property PACKAGE_PIN R18 [get_ports {da2_data[2]}]
set_property PACKAGE_PIN R14 [get_ports {da2_data[1]}]
set_property PACKAGE_PIN P14 [get_ports {da2_data[0]}]
set_property PACKAGE_PIN W21 [get_ports da2_wrt]
set_property PACKAGE_PIN W22 [get_ports da2_clk]

set_property IOSTANDARD LVCMOS33 [get_ports {da1_data[*] da1_wrt da1_clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {da2_data[*] da2_wrt da2_clk}]
set_property DRIVE 8 [get_ports {da1_data[*] da1_wrt da1_clk}]
set_property DRIVE 8 [get_ports {da2_data[*] da2_wrt da2_clk}]
set_property SLEW FAST [get_ports {da1_data[*] da1_wrt da1_clk}]
set_property SLEW FAST [get_ports {da2_data[*] da2_wrt da2_clk}]

# The AD9767 Rev. G minimum input setup/hold times are 2.0 ns / 1.5 ns.
# These constraints cover device timing with zero assumed PCB data-to-WRT skew.
# Board trace skew must be added after it is extracted from the PCB files.
create_generated_clock -name da1_wrt_sample_clk \
    -source [get_pins dac_wrt_oddr_ch1/C] -divide_by 1 -invert [get_ports da1_wrt]
create_generated_clock -name da2_wrt_sample_clk \
    -source [get_pins dac_wrt_oddr_ch2/C] -divide_by 1 -invert [get_ports da2_wrt]

set_output_delay -clock da1_wrt_sample_clk -max 2.000 [get_ports {da1_data[*]}]
set_output_delay -clock da1_wrt_sample_clk -min -1.500 [get_ports {da1_data[*]}]
set_output_delay -clock da2_wrt_sample_clk -max 2.000 [get_ports {da2_data[*]}]
set_output_delay -clock da2_wrt_sample_clk -min -1.500 [get_ports {da2_data[*]}]

# AD9767 minimum WRT/CLK high and low pulse width is 3.5 ns. The forwarded
# 125 MHz 50% duty clock provides 4.0 ns nominal high and low time. Vivado
# 2023.1 does not accept set_min_pulse_width in XDC, so this is verified from
# the generated-clock waveform and must also be checked on the oscilloscope.
