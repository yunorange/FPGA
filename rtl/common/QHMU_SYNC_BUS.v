module QHMU_SYNC_BUS #(
    parameter WIDTH = 1
)(
    input  wire             i_clk,
    input  wire [WIDTH-1:0] i_async_data,
    output reg  [WIDTH-1:0] o_sync_data
);
    reg [WIDTH-1:0] sync_ff1;
    always @(posedge i_clk) begin
        sync_ff1   <= i_async_data;
        o_sync_data <= sync_ff1;
    end
endmodule
