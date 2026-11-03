module QHMU_HDMI_ACR #(
    parameter ACR_N = 6144
)(
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_audio_valid,
    output reg         o_acr_valid,
    output reg  [19:0] o_acr_cts,
    output reg  [19:0] o_acr_n
);
    localparam AUDIO_DIV = ACR_N >> 7;
    reg [7:0] div_cnt;
    reg [19:0] cts_cnt;
    wire sample_div = i_audio_valid && (div_cnt == AUDIO_DIV-1);

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            div_cnt <= 0;
            cts_cnt <= 0;
            o_acr_valid <= 0;
            o_acr_cts <= 0;
            o_acr_n <= 0;
        end else begin
            o_acr_valid <= 1'b0;
            if (i_audio_valid) begin
                if (div_cnt == AUDIO_DIV-1)
                    div_cnt <= 0;
                else
                    div_cnt <= div_cnt + 1'b1;
            end
            if (sample_div) begin
                o_acr_valid <= 1'b1;
                o_acr_cts   <= cts_cnt + 1'b1;
                o_acr_n     <= ACR_N;
                cts_cnt     <= 0;
            end else begin
                cts_cnt <= cts_cnt + 1'b1;
            end
        end
    end
endmodule
