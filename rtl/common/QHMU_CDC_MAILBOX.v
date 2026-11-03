// One-entry multi-bit CDC mailbox. The source data bus is held stable from the
// request toggle until the destination acknowledges the consumed word.
module QHMU_CDC_MAILBOX #(
    parameter WIDTH = 32
)(
    input  wire             i_src_clk,
    input  wire             i_src_rst,
    input  wire             i_src_valid,
    input  wire [WIDTH-1:0] i_src_data,
    output wire             o_src_ready,

    input  wire             i_dst_clk,
    input  wire             i_dst_rst,
    output wire             o_dst_valid,
    output wire [WIDTH-1:0] o_dst_data,
    input  wire             i_dst_ready
);
    reg [WIDTH-1:0] src_hold;
    reg req_toggle;
    reg ack_sync1, ack_sync2;

    reg req_sync1, req_sync2;
    reg ack_toggle;
    reg dst_pending;
    reg [WIDTH-1:0] dst_hold;

    assign o_src_ready = (ack_sync2 == req_toggle);
    assign o_dst_valid = dst_pending;
    assign o_dst_data  = dst_hold;

    always @(posedge i_src_clk or posedge i_src_rst) begin
        if (i_src_rst) begin
            src_hold   <= {WIDTH{1'b0}};
            req_toggle <= 1'b0;
            ack_sync1  <= 1'b0;
            ack_sync2  <= 1'b0;
        end else begin
            ack_sync1 <= ack_toggle;
            ack_sync2 <= ack_sync1;
            if (i_src_valid && o_src_ready) begin
                src_hold   <= i_src_data;
                req_toggle <= ~req_toggle;
            end
        end
    end

    always @(posedge i_dst_clk or posedge i_dst_rst) begin
        if (i_dst_rst) begin
            req_sync1   <= 1'b0;
            req_sync2   <= 1'b0;
            ack_toggle  <= 1'b0;
            dst_pending <= 1'b0;
            dst_hold    <= {WIDTH{1'b0}};
        end else begin
            req_sync1 <= req_toggle;
            req_sync2 <= req_sync1;

            if (!dst_pending && (req_sync2 != ack_toggle)) begin
                dst_hold    <= src_hold;
                dst_pending <= 1'b1;
            end

            if (dst_pending && i_dst_ready) begin
                dst_pending <= 1'b0;
                ack_toggle  <= req_sync2;
            end
        end
    end
endmodule
