// Simple true dual-clock RAM abstraction used as a video line cache.
module QHMU_DPRAM_DC #(
    parameter DATA_WIDTH = 24,
    parameter ADDR_WIDTH = 10
)(
    input  wire                  i_wr_clk,
    input  wire                  i_wr_en,
    input  wire [ADDR_WIDTH-1:0] i_wr_addr,
    input  wire [DATA_WIDTH-1:0] i_wr_data,

    input  wire                  i_rd_clk,
    input  wire [ADDR_WIDTH-1:0] i_rd_addr,
    output reg  [DATA_WIDTH-1:0] o_rd_data
);
    localparam DEPTH = (1 << ADDR_WIDTH);
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge i_wr_clk) begin
        if (i_wr_en)
            mem[i_wr_addr] <= i_wr_data;
    end

    always @(posedge i_rd_clk) begin
        o_rd_data <= mem[i_rd_addr];
    end
endmodule
