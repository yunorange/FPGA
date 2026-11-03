// Short 1-kHz active beep generator for UI/error feedback.
module QHMU_BUZZER #(
    parameter CLK_HZ = 50_000_000,
    parameter BEEP_MS = 80
)(
    input  wire i_clk,
    input  wire i_rst,
    input  wire i_trigger,
    output reg  o_buzzer
);
    localparam integer HALF_PERIOD = CLK_HZ/2000;
    localparam integer BEEP_CYCLES = (CLK_HZ/1000)*BEEP_MS;
    reg [25:0] remain;
    reg [15:0] tone_cnt;

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            remain <= 0;
            tone_cnt <= 0;
            o_buzzer <= 1'b0;
        end else begin
            if (i_trigger)
                remain <= BEEP_CYCLES;
            else if (remain != 0)
                remain <= remain - 1'b1;

            if (remain != 0) begin
                if (tone_cnt >= HALF_PERIOD-1) begin
                    tone_cnt <= 0;
                    o_buzzer <= ~o_buzzer;
                end else
                    tone_cnt <= tone_cnt + 1'b1;
            end else begin
                tone_cnt <= 0;
                o_buzzer <= 1'b0;
            end
        end
    end
endmodule
