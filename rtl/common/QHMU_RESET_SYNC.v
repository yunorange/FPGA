module QHMU_RESET_SYNC #(
    parameter STAGES = 3
)(
    input  wire i_clk,
    input  wire i_async_rst,
    output wire o_rst
);
    reg [STAGES-1:0] rst_pipe;
    always @(posedge i_clk or posedge i_async_rst) begin
        if (i_async_rst)
            rst_pipe <= {STAGES{1'b1}};
        else
            rst_pipe <= {rst_pipe[STAGES-2:0], 1'b0};
    end
    assign o_rst = rst_pipe[STAGES-1];
endmodule
