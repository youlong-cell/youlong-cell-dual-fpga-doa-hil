`timescale 1ns/1ps
// Single adc_clk result slot. This is NOT a CDC/AXI bridge.
// Window release is confirmed by the producer before offer_valid is asserted.
// No backpressure to producer: retain the old unacked result and count/drop new.
module fine_result_slot #(
    parameter integer PAYLOAD_WIDTH=1047,
    parameter integer ENABLE_MAINTENANCE=0
) (
    input wire clk,resetn,
    input wire maintenance_invalidate,
    input wire offer_valid,
    input wire [PAYLOAD_WIDTH-1:0] offer_payload,
    input wire [63:0] offer_epoch,
    input wire [31:0] offer_seq,offer_config_version,
    output reg offer_stored,offer_dropped,
    output wire result_valid,
    output reg [PAYLOAD_WIDTH-1:0] result_payload,
    input wire ack_valid,
    input wire [63:0] ack_epoch,
    input wire [31:0] ack_seq,ack_config_version,
    output reg ack_response_valid,ack_granted,
    output reg [63:0] ack_response_epoch,
    output reg [31:0] ack_response_seq,ack_response_config_version,
    output reg [31:0] drop_count,protocol_error_count,
    output reg [63:0] last_drop_epoch,
    output reg [31:0] last_drop_seq,last_drop_config_version
);
    reg occupied;
    reg [63:0] held_epoch;
    reg [31:0] held_seq,held_config_version;
    // Match the PRE-edge slot, never a simultaneously arriving new result.
    wire ack_match=ack_valid && occupied && ack_epoch==held_epoch &&
                   ack_seq==held_seq && ack_config_version==held_config_version;
    assign result_valid=resetn && occupied;
    always @(posedge clk) begin
        if(!resetn) begin
            occupied<=0; result_payload<=0; held_epoch<=0;
            held_seq<=0; held_config_version<=0;
            offer_stored<=0; offer_dropped<=0;
            ack_response_valid<=0; ack_granted<=0; ack_response_epoch<=0;
            ack_response_seq<=0; ack_response_config_version<=0;
            drop_count<=0; protocol_error_count<=0;
            last_drop_epoch<=0; last_drop_seq<=0; last_drop_config_version<=0;
        end else if(ENABLE_MAINTENANCE && maintenance_invalidate) begin
            occupied<=0;offer_stored<=0;offer_dropped<=0;
            ack_response_valid<=0;ack_granted<=0;
        end else begin
            offer_stored<=0; offer_dropped<=0;
            ack_response_valid<=ack_valid; ack_granted<=ack_match;
            if(ack_valid) begin
                ack_response_epoch<=ack_epoch; ack_response_seq<=ack_seq;
                ack_response_config_version<=ack_config_version;
                if(!ack_match && protocol_error_count!=32'hffffffff)
                    protocol_error_count<=protocol_error_count+32'd1;
            end
            if(ack_match) occupied<=0;
            if(offer_valid) begin
                if(!occupied || ack_match) begin
                    occupied<=1; result_payload<=offer_payload;
                    held_epoch<=offer_epoch; held_seq<=offer_seq;
                    held_config_version<=offer_config_version; offer_stored<=1;
                end else begin
                    offer_dropped<=1;
                    if(drop_count!=32'hffffffff) drop_count<=drop_count+32'd1;
                    last_drop_epoch<=offer_epoch; last_drop_seq<=offer_seq;
                    last_drop_config_version<=offer_config_version;
                end
            end
        end
    end
endmodule
