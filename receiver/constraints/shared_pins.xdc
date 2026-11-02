# =============================================================================
# shared_pins.xdc - shared 3.3 V expansion-connector constraints
#
# Used by top.v with ext_* ADC port names. PS miniDP has no PL display pins.
# The ext_* names retain the verified board pin mapping; do not enable
# ad9238.xdc at the same time.
# =============================================================================

# ========================================
# Shared expansion pins (ext_*)
# ========================================

# --- A11: ADC ch1_clk(O) / LCD intr(I) ---
set_property PACKAGE_PIN A11 [get_ports ext_A11]
set_property IOSTANDARD LVCMOS33 [get_ports ext_A11]

# --- A12: ADC ch1_data[0](I) / LCD bl_pwm(O) ---
set_property PACKAGE_PIN A12 [get_ports ext_A12]
set_property IOSTANDARD LVCMOS33 [get_ports ext_A12]

# --- A13: ADC ch1_data[1](I) / LCD i2c_scl(I/O) ---
set_property PACKAGE_PIN A13 [get_ports ext_A13]
set_property IOSTANDARD LVCMOS33 [get_ports ext_A13]
set_property PULLUP true [get_ports ext_A13]

# --- B13: ADC ch1_data[2](I) / LCD i2c_sda(I/O) ---
set_property PACKAGE_PIN B13 [get_ports ext_B13]
set_property IOSTANDARD LVCMOS33 [get_ports ext_B13]
set_property PULLUP true [get_ports ext_B13]

# --- A14: ADC ch1_data[3](I) / LCD hsync(O) ---
set_property PACKAGE_PIN A14 [get_ports ext_A14]
set_property IOSTANDARD LVCMOS33 [get_ports ext_A14]

# --- B14: ADC ch1_data[4](I) / LCD vsync(O) ---
set_property PACKAGE_PIN B14 [get_ports ext_B14]
set_property IOSTANDARD LVCMOS33 [get_ports ext_B14]

# --- E13: ADC ch1_data[5](I) / LCD pclk(O) ---
set_property PACKAGE_PIN E13 [get_ports ext_E13]
set_property IOSTANDARD LVCMOS33 [get_ports ext_E13]

# --- E14: ADC ch1_data[6](I) / LCD de(O) ---
set_property PACKAGE_PIN E14 [get_ports ext_E14]
set_property IOSTANDARD LVCMOS33 [get_ports ext_E14]

# --- A15: ADC ch1_data[7](I) / LCD data[6](O) ---
set_property PACKAGE_PIN A15 [get_ports ext_A15]
set_property IOSTANDARD LVCMOS33 [get_ports ext_A15]

# --- B15: ADC ch1_data[8](I) / LCD data[7](O) ---
set_property PACKAGE_PIN B15 [get_ports ext_B15]
set_property IOSTANDARD LVCMOS33 [get_ports ext_B15]

# --- C13: ADC ch1_data[9](I) / LCD data[4](O) ---
set_property PACKAGE_PIN C13 [get_ports ext_C13]
set_property IOSTANDARD LVCMOS33 [get_ports ext_C13]

# --- C14: ADC ch1_data[10](I) / LCD data[5](O) ---
set_property PACKAGE_PIN C14 [get_ports ext_C14]
set_property IOSTANDARD LVCMOS33 [get_ports ext_C14]

# --- B10: ADC ch1_data[11](I) / LCD data[2](O) ---
set_property PACKAGE_PIN B10 [get_ports ext_B10]
set_property IOSTANDARD LVCMOS33 [get_ports ext_B10]

# --- K12: ADC ch0_clk(O) / LCD data[18](O) ---
set_property PACKAGE_PIN K12 [get_ports ext_K12]
set_property IOSTANDARD LVCMOS33 [get_ports ext_K12]

# --- F12: ADC ch0_data[0](I) / LCD data[15](O) ---
set_property PACKAGE_PIN F12 [get_ports ext_F12]
set_property IOSTANDARD LVCMOS33 [get_ports ext_F12]

# --- F11: ADC ch0_data[1](I) / LCD data[14](O) ---
set_property PACKAGE_PIN F11 [get_ports ext_F11]
set_property IOSTANDARD LVCMOS33 [get_ports ext_F11]

# --- H13: ADC ch0_data[3](I) / LCD data[12](O) ---
set_property PACKAGE_PIN H13 [get_ports ext_H13]
set_property IOSTANDARD LVCMOS33 [get_ports ext_H13]

# --- H14: ADC ch0_data[2](I) / LCD data[13](O) ---
set_property PACKAGE_PIN H14 [get_ports ext_H14]
set_property IOSTANDARD LVCMOS33 [get_ports ext_H14]

# --- G14: ADC ch0_data[5](I) / LCD data[10](O) ---
set_property PACKAGE_PIN G14 [get_ports ext_G14]
set_property IOSTANDARD LVCMOS33 [get_ports ext_G14]

# --- G15: ADC ch0_data[4](I) / LCD data[11](O) ---
set_property PACKAGE_PIN G15 [get_ports ext_G15]
set_property IOSTANDARD LVCMOS33 [get_ports ext_G15]

# --- F10: ADC ch0_data[7](I) / LCD data[8](O) ---
set_property PACKAGE_PIN F10 [get_ports ext_F10]
set_property IOSTANDARD LVCMOS33 [get_ports ext_F10]

# --- G11: ADC ch0_data[6](I) / LCD data[9](O) ---
set_property PACKAGE_PIN G11 [get_ports ext_G11]
set_property IOSTANDARD LVCMOS33 [get_ports ext_G11]

# --- H12: ADC ch0_data[9](I) / LCD data[22](O) ---
set_property PACKAGE_PIN H12 [get_ports ext_H12]
set_property IOSTANDARD LVCMOS33 [get_ports ext_H12]

# --- J12: ADC ch0_data[8](I) / LCD data[23](O) ---
set_property PACKAGE_PIN J12 [get_ports ext_J12]
set_property IOSTANDARD LVCMOS33 [get_ports ext_J12]

# --- J14: ADC ch0_data[11](I) / LCD data[20](O) ---
set_property PACKAGE_PIN J14 [get_ports ext_J14]
set_property IOSTANDARD LVCMOS33 [get_ports ext_J14]

# --- K14: ADC ch0_data[10](I) / LCD data[21](O) ---
set_property PACKAGE_PIN K14 [get_ports ext_K14]
set_property IOSTANDARD LVCMOS33 [get_ports ext_K14]

# ========================================
# AD9238 source-synchronous input timing
# ========================================
#
# AD9238 Rev. D, Table 4 / Figure 2:
#   data changes 2.0 ns to 6.0 ns after the ADC clock rising edge.
#
# No routed PCB database is available in the supplied ALINX material.  The
# following board-flight envelope therefore covers each leg (FPGA->ADC clock
# and ADC->FPGA data) from 0.2 ns to 0.6 ns.  At approximately 6 ps/mm this is
# about 33 mm to 100 mm per leg, including the carrier, connector and AN9238.
# Replace these four PCB values if measured trace lengths are later available.
#
# Relative to the forwarded clock at the FPGA package pin:
#   input_delay = clock PCB flight + AD9238 tCO + data PCB flight

set adc_tco_min_ns       2.000
set adc_tco_max_ns       6.000
set adc_clk_pcb_min_ns   0.200
set adc_clk_pcb_max_ns   0.600
set adc_data_pcb_min_ns  0.200
set adc_data_pcb_max_ns  0.600

set adc_input_min_ns [expr {$adc_clk_pcb_min_ns + $adc_tco_min_ns + $adc_data_pcb_min_ns}]
set adc_input_max_ns [expr {$adc_clk_pcb_max_ns + $adc_tco_max_ns + $adc_data_pcb_max_ns}]

set adc0_data_ports [get_ports {ext_F12 ext_F11 ext_H14 ext_H13 ext_G15 ext_G14 ext_G11 ext_F10 ext_J12 ext_H12 ext_K14 ext_J14}]
set adc1_data_ports [get_ports {ext_A12 ext_A13 ext_B13 ext_A14 ext_B14 ext_E13 ext_E14 ext_A15 ext_B15 ext_C13 ext_C14 ext_B10}]

# clk_pl_1 is the 62.499 MHz PS-generated ADC clock.  Defining the clocks on
# the physical output ports includes the FPGA clock-output path in STA and
# leaves set_input_delay to describe only the external round trip.
set adc_clk_source [get_pins {design_1_i/zynq_ultra_ps_e_0/inst/PS8_i/PLCLK[1]}]
create_generated_clock -name adc0_clk_fwd -source $adc_clk_source -divide_by 1 [get_ports ext_K12]
create_generated_clock -name adc1_clk_fwd -source $adc_clk_source -divide_by 1 [get_ports ext_A11]

set_input_delay -clock adc0_clk_fwd -min $adc_input_min_ns $adc0_data_ports
set_input_delay -clock adc0_clk_fwd -max $adc_input_max_ns $adc0_data_ports
set_input_delay -clock adc1_clk_fwd -min $adc_input_min_ns $adc1_data_ports
set_input_delay -clock adc1_clk_fwd -max $adc_input_max_ns $adc1_data_ports

# These are forwarded clocks, not data outputs.  A set_output_delay constraint
# would invent a non-existent external setup/hold check; generated clocks are
# the correct output-side timing model.  ALINX also uses FAST slew for them.
set_property SLEW FAST [get_ports {ext_K12 ext_A11}]

# ========================================
# Mode-selection key (AA13 = PL KEY1)
# Released = logic 1 through pull-up; pressed = logic 0 to ground.
# pl_mode_controller debounces each press and advances the six-state UI mode.
# ========================================
set_property PACKAGE_PIN AA13 [get_ports lcd_mode]
set_property IOSTANDARD LVCMOS33 [get_ports lcd_mode]
set_property PULLUP true [get_ports lcd_mode]
# KEY1 is asynchronous to PL clock 2.  The first two registers in
# pl_mode_controller are marked ASYNC_REG; do not time the package-pin path.
set_false_path -from [get_ports lcd_mode]

# ========================================
# Enable compressed bitstream output.
# ========================================
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
