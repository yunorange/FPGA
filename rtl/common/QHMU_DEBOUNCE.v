module QHMU_DEBOUNCE #(
    parameter CLK_HZ = 50_000_000,
    parameter DEBOUNCE_MS = 20
)(
    input  wire i_clk,
    input  wire i_rst,
    input  wire i_key_n,
    output reg  o_press_pulse,
    output reg  o_release_pulse,
    output reg  o_state_n
);
    localparam integer STABLE_CYCLES = (CLK_HZ/1000)*DEBOUNCE_MS;
    reg sync1, sync2;
    reg [20:0] cnt;

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            sync1 <= 1'b1;
            sync2 <= 1'b1;
        end else begin
            sync1 <= i_key_n;
            sync2 <= sync1;
        end
    end

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            cnt             <= 21'd0;
            o_state_n       <= 1'b1;
            o_press_pulse   <= 1'b0;
            o_release_pulse <= 1'b0;
        end else begin
            o_press_pulse   <= 1'b0;
            o_release_pulse <= 1'b0;
            if (sync2 == o_state_n) begin
                cnt <= 21'd0;
            end else if (cnt >= STABLE_CYCLES-1) begin
                cnt       <= 21'd0;
                o_state_n <= sync2;
                if (!sync2)
                    o_press_pulse <= 1'b1;
                else
                    o_release_pulse <= 1'b1;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end
endmodule
