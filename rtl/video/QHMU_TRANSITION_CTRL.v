module QHMU_TRANSITION_CTRL(
    input  wire       i_clk,
    input  wire       i_rst,
    input  wire       i_frame_start,
    input  wire       i_start_pulse,
    input  wire [3:0] i_mode,
    output reg        o_active_buffer,
    output reg        o_transition_active,
    output reg [3:0]  o_mode,
    output reg [7:0]  o_alpha,
    output reg        o_done_pulse
);
    reg start_pending;

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            start_pending       <= 1'b0;
            o_active_buffer     <= 1'b0;
            o_transition_active <= 1'b0;
            o_mode              <= 4'd0;
            o_alpha             <= 8'd0;
            o_done_pulse        <= 1'b0;
        end else begin
            o_done_pulse <= 1'b0;
            if (i_start_pulse)
                start_pending <= 1'b1;

            if (i_frame_start) begin
                if (start_pending && !o_transition_active) begin
                    start_pending <= 1'b0;
                    o_mode <= i_mode;
                    if (i_mode == 4'd2) begin
                        o_active_buffer <= ~o_active_buffer;
                        o_done_pulse <= 1'b1;
                        o_alpha <= 8'd0;
                    end else begin
                        o_transition_active <= 1'b1;
                        o_alpha <= 8'd0;
                    end
                end else if (o_transition_active) begin
                    if (o_alpha >= 8'd240) begin
                        o_transition_active <= 1'b0;
                        o_active_buffer <= ~o_active_buffer;
                        o_alpha <= 8'd0;
                        o_done_pulse <= 1'b1;
                    end else begin
                        o_alpha <= o_alpha + 8'd48;
                    end
                end
            end
        end
    end
endmodule
