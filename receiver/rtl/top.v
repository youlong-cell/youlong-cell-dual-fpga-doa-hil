`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// AXU2CGA + AN9238 receiver top
//
// The PS miniDP uses dedicated GT/DPAUX pins. The PL expansion connector is
// ADC-only: A11/K12 forward the two sample clocks and the remaining ext_*
// pins receive ADC data. KEY1 keeps the historical lcd_mode BD port name for
// software/BD compatibility, but it only controls the PL mode controller.
//////////////////////////////////////////////////////////////////////////////////
module top (
    output wire ext_A11,  // ADC CH1 clock
    input  wire ext_A12,  // ADC CH1 data[0]
    input  wire ext_A13,  // ADC CH1 data[1]
    input  wire ext_B13,  // ADC CH1 data[2]
    input  wire ext_A14,  // ADC CH1 data[3]
    input  wire ext_B14,  // ADC CH1 data[4]
    input  wire ext_E13,  // ADC CH1 data[5]
    input  wire ext_E14,  // ADC CH1 data[6]
    input  wire ext_A15,  // ADC CH1 data[7]
    input  wire ext_B15,  // ADC CH1 data[8]
    input  wire ext_C13,  // ADC CH1 data[9]
    input  wire ext_C14,  // ADC CH1 data[10]
    input  wire ext_B10,  // ADC CH1 data[11]
    output wire ext_K12,  // ADC CH0 clock
    input  wire ext_F12,  // ADC CH0 data[0]
    input  wire ext_F11,  // ADC CH0 data[1]
    input  wire ext_H14,  // ADC CH0 data[2]
    input  wire ext_H13,  // ADC CH0 data[3]
    input  wire ext_G15,  // ADC CH0 data[4]
    input  wire ext_G14,  // ADC CH0 data[5]
    input  wire ext_G11,  // ADC CH0 data[6]
    input  wire ext_F10,  // ADC CH0 data[7]
    input  wire ext_J12,  // ADC CH0 data[8]
    input  wire ext_H12,  // ADC CH0 data[9]
    input  wire ext_K14,  // ADC CH0 data[10]
    input  wire ext_J14,  // ADC CH0 data[11]
    input  wire lcd_mode  // KEY1, active-low; retained BD port name
);

    wire adc_ch0_clk;
    wire adc_ch1_clk;
    wire [11:0] adc_ch0_data_raw;
    wire [11:0] adc_ch1_data_raw;

    assign ext_A11 = adc_ch1_clk;
    assign ext_K12 = adc_ch0_clk;

    assign adc_ch1_data_raw = {ext_B10, ext_C14, ext_C13, ext_B15,
                               ext_A15, ext_E14, ext_E13, ext_B14,
                               ext_A14, ext_B13, ext_A13, ext_A12};
    assign adc_ch0_data_raw = {ext_J14, ext_K14, ext_H12, ext_J12,
                               ext_F10, ext_G11, ext_G14, ext_G15,
                               ext_H13, ext_H14, ext_F11, ext_F12};

    // One HDIO register per bit is shared by the DMA and PL FFT consumers.
    (* IOB = "TRUE" *) reg [11:0] adc_ch0_data_iob;
    (* IOB = "TRUE" *) reg [11:0] adc_ch1_data_iob;

    always @(posedge adc_ch0_clk)
        adc_ch0_data_iob <= adc_ch0_data_raw;

    always @(posedge adc_ch1_clk)
        adc_ch1_data_iob <= adc_ch1_data_raw;

    design_1 design_1_i (
        .adc_ch0_clk  (adc_ch0_clk),
        .adc_ch0_data (adc_ch0_data_iob),
        .adc_ch1_clk  (adc_ch1_clk),
        .adc_ch1_data (adc_ch1_data_iob),
        .lcd_mode     (lcd_mode)
    );
endmodule
