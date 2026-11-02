`timescale 1ns/1ps
// R2-PROD Verilog-2001 module_ref shell; adc_clk domain, no new CDC or ABI.
// The core is BYTE-IDENTICAL to the approved R2-EVAL artifact, SHA256:
// 66f9910bba8eb0daa513a88ada722ae9d5a158ac563cb856ddfa764517d8fcc5.
// Its historical "Evaluation only" comment is retained to preserve the hash.
// U1.47, 48 restoring steps, exact RNE q+(rem>q), single outstanding.
// Illegal radicands are rejected upstream; this unsigned shell never abs/clamps.
module fine_doa_sqrt (
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 aclk CLK",
       X_INTERFACE_PARAMETER="XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF S_AXIS_CARTESIAN:M_AXIS_DOUT, ASSOCIATED_RESET aresetn" *)
    input wire aclk,
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 aresetn RST",
       X_INTERFACE_PARAMETER="XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    input wire aresetn,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 S_AXIS_CARTESIAN TVALID" *)
    input wire s_axis_cartesian_tvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 S_AXIS_CARTESIAN TREADY" *)
    output wire s_axis_cartesian_tready,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 S_AXIS_CARTESIAN TDATA" *)
    input wire [47:0] s_axis_cartesian_tdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS_DOUT TVALID" *)
    output wire m_axis_dout_tvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS_DOUT TREADY" *)
    input wire m_axis_dout_tready,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS_DOUT TDATA" *)
    output wire [47:0] m_axis_dout_tdata
);
    r2_iterative_sqrt approved_core (
        .aclk(aclk),.aresetn(aresetn),
        .s_axis_cartesian_tvalid(s_axis_cartesian_tvalid),
        .s_axis_cartesian_tready(s_axis_cartesian_tready),
        .s_axis_cartesian_tdata(s_axis_cartesian_tdata),
        .m_axis_dout_tvalid(m_axis_dout_tvalid),
        .m_axis_dout_tready(m_axis_dout_tready),
        .m_axis_dout_tdata(m_axis_dout_tdata)
    );
endmodule
