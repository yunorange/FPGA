// ============================================================================
// QHMU_AUDIO_FIFO
// Dedicated 32-bit asynchronous PCM FIFO.
//
// Default depth: 2048 stereo frames = ~42.7 ms at 48 kHz.
// The write-side almost-full flag reserves 256 frames so that one complete
// 512-byte SD sector (128 stereo 16-bit frames) can always be accepted after a
// sector transaction has started.
// ============================================================================
module QHMU_AUDIO_FIFO #(
    parameter ADDR_WIDTH = 11,
    parameter ALMOST_FULL_MARGIN = 256
)(
    input  wire        i_wr_clk,
    input  wire        i_wr_rst,
    input  wire        i_wr_en,
    input  wire [31:0] i_wr_data,
    output wire        o_wr_full,
    output wire        o_wr_almost_full,

    input  wire        i_rd_clk,
    input  wire        i_rd_rst,
    input  wire        i_rd_en,
    output reg  [31:0] o_rd_data,
    output reg         o_rd_valid,
    output wire        o_rd_empty
);
    localparam PTR_W = ADDR_WIDTH + 1;
    localparam DEPTH = (1 << ADDR_WIDTH);
    localparam AFULL_LEVEL = DEPTH - ALMOST_FULL_MARGIN;

    reg [31:0] mem [0:DEPTH-1];

    reg [PTR_W-1:0] wr_bin;
    reg [PTR_W-1:0] wr_gray;
    reg [PTR_W-1:0] rd_bin;
    reg [PTR_W-1:0] rd_gray;

    reg [PTR_W-1:0] rd_gray_w1;
    reg [PTR_W-1:0] rd_gray_w2;
    reg [PTR_W-1:0] wr_gray_r1;
    reg [PTR_W-1:0] wr_gray_r2;

    reg wr_full_r;
    reg rd_empty_r;

    wire wr_fire = i_wr_en && !wr_full_r;
    wire rd_fire = i_rd_en && !rd_empty_r;

    wire [PTR_W-1:0] wr_bin_next =
        wr_bin + (wr_fire ? {{(PTR_W-1){1'b0}},1'b1} : {PTR_W{1'b0}});
    wire [PTR_W-1:0] wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;

    wire [PTR_W-1:0] rd_bin_next =
        rd_bin + (rd_fire ? {{(PTR_W-1){1'b0}},1'b1} : {PTR_W{1'b0}});
    wire [PTR_W-1:0] rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

    wire [PTR_W-1:0] rd_gray_full_cmp = {
        ~rd_gray_w2[PTR_W-1:PTR_W-2],
         rd_gray_w2[PTR_W-3:0]
    };

    wire wr_full_next  = (wr_gray_next == rd_gray_full_cmp);
    wire rd_empty_next = (rd_gray_next == wr_gray_r2);

    function [PTR_W-1:0] gray_to_bin;
        input [PTR_W-1:0] gray;
        integer i;
        begin
            gray_to_bin[PTR_W-1] = gray[PTR_W-1];
            for (i=PTR_W-2; i>=0; i=i-1)
                gray_to_bin[i] = gray_to_bin[i+1] ^ gray[i];
        end
    endfunction

    wire [PTR_W-1:0] rd_bin_sync_w = gray_to_bin(rd_gray_w2);
    wire [PTR_W-1:0] wr_used_words = wr_bin - rd_bin_sync_w;

    assign o_wr_full        = wr_full_r;
    assign o_rd_empty       = rd_empty_r;
    assign o_wr_almost_full = (wr_used_words >= AFULL_LEVEL);

    always @(posedge i_wr_clk or posedge i_wr_rst) begin
        if (i_wr_rst) begin
            wr_bin     <= {PTR_W{1'b0}};
            wr_gray    <= {PTR_W{1'b0}};
            rd_gray_w1 <= {PTR_W{1'b0}};
            rd_gray_w2 <= {PTR_W{1'b0}};
            wr_full_r  <= 1'b0;
        end else begin
            rd_gray_w1 <= rd_gray;
            rd_gray_w2 <= rd_gray_w1;
            wr_full_r  <= wr_full_next;

            if (wr_fire) begin
                mem[wr_bin[ADDR_WIDTH-1:0]] <= i_wr_data;
                wr_bin  <= wr_bin_next;
                wr_gray <= wr_gray_next;
            end
        end
    end

    always @(posedge i_rd_clk or posedge i_rd_rst) begin
        if (i_rd_rst) begin
            rd_bin      <= {PTR_W{1'b0}};
            rd_gray     <= {PTR_W{1'b0}};
            wr_gray_r1  <= {PTR_W{1'b0}};
            wr_gray_r2  <= {PTR_W{1'b0}};
            rd_empty_r  <= 1'b1;
            o_rd_data   <= 32'd0;
            o_rd_valid  <= 1'b0;
        end else begin
            wr_gray_r1 <= wr_gray;
            wr_gray_r2 <= wr_gray_r1;
            rd_empty_r <= rd_empty_next;
            o_rd_valid <= 1'b0;

            if (rd_fire) begin
                o_rd_data  <= mem[rd_bin[ADDR_WIDTH-1:0]];
                o_rd_valid <= 1'b1;
                rd_bin     <= rd_bin_next;
                rd_gray    <= rd_gray_next;
            end
        end
    end
endmodule
