# Capture command/length now use xpm_cdc_handshake and its generated constraints.
# Health/status synchronizers: only the first stage receives asynchronous data.
# ASYNC_REG attributes on both stages preserve the intended implementation.
set_false_path -quiet -to [get_pins {ad9238_sample_v1_0_S00_AXI_inst/overflow_sync0_reg/D}]
set_false_path -quiet -to [get_pins {ad9238_sample_v1_0_S00_AXI_inst/fifo_full_sync0_reg/D}]
set_false_path -quiet -to [get_pins {ad9238_sample_v1_0_S00_AXI_inst/active_sync0_reg/D}]
