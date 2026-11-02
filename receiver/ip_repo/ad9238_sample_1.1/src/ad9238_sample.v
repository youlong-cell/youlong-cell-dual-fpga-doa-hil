//////////////////////////////////////////////////////////////////////////////////
//                                                                              //
//                                                                              //
//  Author: meisq                                                               //
//          msq@qq.com                                                          //
//          ALINX(shanghai) Technology Co.,Ltd                                  //
//          heijin                                                              //
//     WEB: http://www.alinx.cn/                                                //
//     BBS: http://www.heijin.org/                                              //
//                                                                              //
//////////////////////////////////////////////////////////////////////////////////
//                                                                              //
// Copyright (c) 2017,ALINX(shanghai) Technology Co.,Ltd                        //
//                    All rights reserved                                       //
//                                                                              //
// This source file may be used and distributed without restriction provided    //
// that this copyright statement is not removed from the file and that any      //
// derivative work contains the original copyright notice and the associated    //
// disclaimer.                                                                  //
//                                                                              //
//////////////////////////////////////////////////////////////////////////////////

//================================================================================
//  Revision History:
//  Date          By            Revision    Change Description
//--------------------------------------------------------------------------------
//2020/3/16                   1.0          Original
//*******************************************************************************/
module ad9238_sample(
	input                       adc_clk,
	input                       adc_rst_n,
	input[11:0]                 adc_data,
	
    // Command and length are already in adc_clk after the wrapper's
    // xpm_cdc_handshake. Hold start_ack until sample_start is released.
    input  [31:0]               sample_len,
	input                       sample_start,
	output reg                  start_ack,
	
    output [15:0]               M_AXIS_tdata,
    output [1:0]                M_AXIS_tkeep,
    output                      M_AXIS_tlast,
    input                       M_AXIS_tready,
    output                      M_AXIS_tvalid,
    input [0:0]                 M_AXIS_RSTN,
	input                       M_AXIS_CLK,

    // Write-domain health information. The AXI-Lite wrapper synchronizes
    // these signals before software reads them. The dropped-sample count
    // remains binary here; xpm_cdc_gray registers its Gray code in adc_clk.
    output                      fifo_overflow_sticky,
    output [31:0]               fifo_drop_count_bin,
    output                      fifo_full_status,
    output                      capture_active
);


localparam       S_IDLE    		= 0;
localparam       S_SAMPLE  		= 1;
reg[2:0]         state;


reg[31:0]       sample_cnt;     //sample counter
reg [31:0]      sample_len_active; //frozen for the entire capture


reg [15:0]   	adc_buf_data ;     //fifo write data
wire         	adc_buf_rd  ;		//fifo read enable
wire         	empty;				//fifo empty
wire            fifo_full;
wire [16:0]     fifo_din;
wire [16:0]     fifo_dout;
wire            fifo_wr_en;
wire            sample_write_req;
wire            sample_is_last;
wire            drop_event;

reg             pending_last;
reg [15:0]      pending_last_data;
reg             overflow_sticky_reg;
reg [31:0]      drop_count_bin;


wire capture_start_event = (state == S_IDLE) && sample_start && !start_ack;

/* Expand adc data to 16 bits */
always@(posedge adc_clk or negedge adc_rst_n)
begin
	if(adc_rst_n == 1'b0)
		adc_buf_data <= 16'd0;
	else
		adc_buf_data <= {4'b0000, adc_data};
end


always@(posedge adc_clk or negedge adc_rst_n)
begin
	if(adc_rst_n == 1'b0)
	begin
		state <= S_IDLE;
		sample_cnt <= 32'd0;
		sample_len_active <= 32'd0;
		start_ack <= 1'b0;
	end
	else begin
		if (!sample_start)
			start_ack <= 1'b0;
		case(state)
			S_IDLE:
			begin
			  if (capture_start_event)
			  begin
				// XPM holds sample_len stable until this acknowledgement.
				sample_len_active <= sample_len;
				sample_cnt <= 32'd0;
				start_ack <= 1'b1;
				state <= S_SAMPLE;
			  end		    
			end
			S_SAMPLE:
			begin
				if ((sample_len_active == 32'd0) ||
				    (sample_cnt == sample_len_active - 1'b1))
				begin
					sample_cnt <= 32'd0;
					state <= S_IDLE;
				end
				else
				begin
					sample_cnt <= sample_cnt + 32'd1;
				end
				
			end		
			default:
				state <= S_IDLE;
		endcase
	end
end

/*
 * Packetize the capture before the asynchronous FIFO.  TLAST is stored beside
 * the ADC sample so it cannot move relative to TDATA when the DMA applies
 * back-pressure.  If the final sample arrives while the FIFO is full, keep it
 * in a one-entry holding register and insert it as soon as space is available;
 * this guarantees a terminating TLAST even after an overflow-shortened packet.
 */
assign sample_write_req = (state == S_SAMPLE) &&
                          (sample_cnt < sample_len_active);
assign sample_is_last   = sample_write_req &&
                          (sample_cnt == sample_len_active - 1'b1);
assign fifo_wr_en       = ~fifo_full && (pending_last || sample_write_req);
assign fifo_din         = pending_last ? {1'b1, pending_last_data} :
                                        {sample_is_last, adc_buf_data};

/* A full FIFO rejects ordinary samples.  The final sample is rescued above. */
assign drop_event = sample_write_req && fifo_full && ~sample_is_last;

always @(posedge adc_clk or negedge adc_rst_n)
begin
	if (adc_rst_n == 1'b0)
	begin
		pending_last      <= 1'b0;
		pending_last_data <= 16'd0;
	end
	else
	begin
		if (sample_is_last && fifo_full)
		begin
			pending_last      <= 1'b1;
			pending_last_data <= adc_buf_data;
		end
		else if (pending_last && ~fifo_full)
		begin
			pending_last <= 1'b0;
		end
	end
end

/*
 * Sticky overflow belongs to the current capture and is cleared at capture
 * start.  The cumulative dropped-sample counter clears only on reset so
 * software can detect events even if a status poll misses the sticky window.
 * The AXI-Lite wrapper uses xpm_cdc_gray to cross this binary counter.
 */
always @(posedge adc_clk or negedge adc_rst_n)
begin
	if (adc_rst_n == 1'b0)
	begin
		overflow_sticky_reg <= 1'b0;
		drop_count_bin      <= 32'd0;
	end
	else
	begin
		if (capture_start_event)
			overflow_sticky_reg <= 1'b0;
		else if (drop_event)
			overflow_sticky_reg <= 1'b1;

		if (drop_event)
			drop_count_bin <= drop_count_bin + 1'b1;
	end
end

assign fifo_overflow_sticky = overflow_sticky_reg;
assign fifo_drop_count_bin  = drop_count_bin;
assign fifo_full_status     = fifo_full;
assign capture_active       = (state == S_SAMPLE);



/*
* Instantiate async fifo by using Xilinx parameterized Macros. For ultrasclae, refer to ug974, for 7 series ug953
* write and read depth is 1024.  The 17th bit carries AXI-Stream TLAST.
*/
xpm_fifo_async #(
   .CDC_SYNC_STAGES      (2),        
   .DOUT_RESET_VALUE     ("1"),      
   .ECC_MODE             ("no_ecc"), 
   .FIFO_MEMORY_TYPE     ("auto"),   
   .FIFO_READ_LATENCY    (0),        
   .FIFO_WRITE_DEPTH     (1024),     
   .FULL_RESET_VALUE     (0),        
   .PROG_EMPTY_THRESH    (10),       
   .PROG_FULL_THRESH     (10),       
   .RD_DATA_COUNT_WIDTH  (11),       
   .READ_DATA_WIDTH      (17),        
   .READ_MODE            ("fwft"),   
   .RELATED_CLOCKS       (0),        
   .USE_ADV_FEATURES     ("0707"),   
   .WAKEUP_TIME          (0),        
   .WRITE_DATA_WIDTH     (17),        
   .WR_DATA_COUNT_WIDTH  (11)        
)
xpm_fifo_async_inst (
   .rst            (~adc_rst_n),
   .wr_clk         (adc_clk),
   .wr_en          (fifo_wr_en),
   .din            (fifo_din),
   .rd_clk         (M_AXIS_CLK),
   .rd_en          (adc_buf_rd),
   .dout           (fifo_dout),
   .empty          (empty),
   .full           (fifo_full),
   .almost_empty   (),
   .almost_full    (),
   .wr_data_count  (),
   .rd_data_count  (),    
   .prog_empty     (),
   .prog_full      (),    
   .data_valid     (),
   .dbiterr        (),
   .sbiterr        (),
   .overflow       (),
   .underflow      (),
   .wr_ack         (),   
   .wr_rst_busy    (),   
   .rd_rst_busy    (),
   .injectdbiterr  (1'b0),
   .injectsbiterr  (1'b0),   
   .sleep          (1'b0)   
   );


/*
 * AXI4-Stream source rules:
 *   - TVALID depends only on source state, never on TREADY.
 *   - TDATA/TLAST remain at the FWFT head while stalled.
 *   - the FIFO advances only on a completed TVALID && TREADY transfer.
 */
assign M_AXIS_tvalid = M_AXIS_RSTN[0] && ~empty;
assign adc_buf_rd    = M_AXIS_tvalid && M_AXIS_tready;
assign M_AXIS_tdata  = fifo_dout[15:0];
assign M_AXIS_tkeep  = 2'b11;
assign M_AXIS_tlast  = fifo_dout[16] && M_AXIS_tvalid;


endmodule
