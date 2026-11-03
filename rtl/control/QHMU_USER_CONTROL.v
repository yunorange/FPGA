// ============================================================================
// QHMU_USER_CONTROL
// Resource-optimized local controls.
// KEY1/KEY2: previous/next image when SW0=0; brightness -/+ when SW0=1.
// KEY3: always toggles manual/automatic image mode.
// KEY4: transition cycle when SW0=0; contrast increase when SW0=1.
// SW1: auto policy: 0=8-second AUD timer, 1=paired MUS EOF.
// SW2: audio visualizer enable. SW3 is reserved.
// OSD and scrolling subtitle are always enabled.
// ============================================================================
module QHMU_USER_CONTROL(
    input  wire       i_clk,
    input  wire       i_rst,
    input  wire [3:0] i_key_n,
    input  wire [3:0] i_sw,
    input  wire       i_remote_valid,
    input  wire [3:0] i_remote_code,
    input  wire [7:0] i_remote_value,

    output reg        o_prev_pulse,
    output reg        o_next_pulse,
    output reg        o_auto_toggle_pulse,
    output reg [3:0]  o_transition_mode,
    output reg signed [7:0] o_brightness,
    output reg [7:0]  o_contrast,
    output wire       o_osd_enable,
    output wire       o_visualizer_enable,
    output wire       o_scroll_enable,
    output wire       o_audio_wait_mode
);
    reg [3:0] sw_meta, sw_sync;
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            sw_meta <= 4'd0;
            sw_sync <= 4'd0;
        end else begin
            sw_meta <= i_sw;
            sw_sync <= sw_meta;
        end
    end

    wire [3:0] key_press;
    wire [3:0] key_release_unused;
    wire [3:0] key_state_unused;
    genvar g;
    generate
        for (g=0; g<4; g=g+1) begin : G_KEY
            QHMU_DEBOUNCE u_db(
                .i_clk(i_clk), .i_rst(i_rst), .i_key_n(i_key_n[g]),
                .o_press_pulse(key_press[g]),
                .o_release_pulse(key_release_unused[g]),
                .o_state_n(key_state_unused[g])
            );
        end
    endgenerate

    // Display and subtitle no longer have user-selectable disable switches.
    assign o_osd_enable        = 1'b1;
    assign o_scroll_enable     = 1'b1;
    assign o_visualizer_enable = sw_sync[2];
    assign o_audio_wait_mode   = sw_sync[1];

    // Convert a 0..100 remote percentage into one of 25 discrete steps.
    // Comparator thresholds replace the previous multiply/divide-by-100
    // datapaths, which were unnecessarily expensive in the FPGA fabric.
    function [4:0] pct_to_step_round;
        input [7:0] pct_in;
        reg [6:0] p;
        begin
            p = (pct_in > 8'd100) ? 7'd100 : pct_in[6:0];
            if      (p < 7'd3)  pct_to_step_round = 5'd0;
            else if (p < 7'd7)  pct_to_step_round = 5'd1;
            else if (p < 7'd11) pct_to_step_round = 5'd2;
            else if (p < 7'd15) pct_to_step_round = 5'd3;
            else if (p < 7'd19) pct_to_step_round = 5'd4;
            else if (p < 7'd23) pct_to_step_round = 5'd5;
            else if (p < 7'd28) pct_to_step_round = 5'd6;
            else if (p < 7'd32) pct_to_step_round = 5'd7;
            else if (p < 7'd36) pct_to_step_round = 5'd8;
            else if (p < 7'd40) pct_to_step_round = 5'd9;
            else if (p < 7'd44) pct_to_step_round = 5'd10;
            else if (p < 7'd48) pct_to_step_round = 5'd11;
            else if (p < 7'd53) pct_to_step_round = 5'd12;
            else if (p < 7'd57) pct_to_step_round = 5'd13;
            else if (p < 7'd61) pct_to_step_round = 5'd14;
            else if (p < 7'd65) pct_to_step_round = 5'd15;
            else if (p < 7'd69) pct_to_step_round = 5'd16;
            else if (p < 7'd73) pct_to_step_round = 5'd17;
            else if (p < 7'd78) pct_to_step_round = 5'd18;
            else if (p < 7'd82) pct_to_step_round = 5'd19;
            else if (p < 7'd86) pct_to_step_round = 5'd20;
            else if (p < 7'd90) pct_to_step_round = 5'd21;
            else if (p < 7'd94) pct_to_step_round = 5'd22;
            else if (p < 7'd98) pct_to_step_round = 5'd23;
            else                pct_to_step_round = 5'd24;
        end
    endfunction

    function [4:0] pct_to_step_floor;
        input [7:0] pct_in;
        reg [6:0] p;
        begin
            p = (pct_in > 8'd100) ? 7'd100 : pct_in[6:0];
            if      (p < 7'd5)  pct_to_step_floor = 5'd0;
            else if (p < 7'd9)  pct_to_step_floor = 5'd1;
            else if (p < 7'd13) pct_to_step_floor = 5'd2;
            else if (p < 7'd17) pct_to_step_floor = 5'd3;
            else if (p < 7'd21) pct_to_step_floor = 5'd4;
            else if (p < 7'd25) pct_to_step_floor = 5'd5;
            else if (p < 7'd29) pct_to_step_floor = 5'd6;
            else if (p < 7'd34) pct_to_step_floor = 5'd7;
            else if (p < 7'd38) pct_to_step_floor = 5'd8;
            else if (p < 7'd42) pct_to_step_floor = 5'd9;
            else if (p < 7'd46) pct_to_step_floor = 5'd10;
            else if (p < 7'd50) pct_to_step_floor = 5'd11;
            else if (p < 7'd55) pct_to_step_floor = 5'd12;
            else if (p < 7'd59) pct_to_step_floor = 5'd13;
            else if (p < 7'd63) pct_to_step_floor = 5'd14;
            else if (p < 7'd67) pct_to_step_floor = 5'd15;
            else if (p < 7'd71) pct_to_step_floor = 5'd16;
            else if (p < 7'd75) pct_to_step_floor = 5'd17;
            else if (p < 7'd80) pct_to_step_floor = 5'd18;
            else if (p < 7'd84) pct_to_step_floor = 5'd19;
            else if (p < 7'd88) pct_to_step_floor = 5'd20;
            else if (p < 7'd92) pct_to_step_floor = 5'd21;
            else if (p < 7'd96) pct_to_step_floor = 5'd22;
            else if (p < 7'd100)pct_to_step_floor = 5'd23;
            else                pct_to_step_floor = 5'd24;
        end
    endfunction

    function signed [7:0] pct_to_brightness;
        input [7:0] pct;
        reg [4:0] step;
        reg [7:0] scaled;
        reg signed [8:0] scaled_signed;
        begin
            step = pct_to_step_round(pct);
            scaled = {step,3'b000};
            scaled_signed = $signed({1'b0,scaled});
            pct_to_brightness = scaled_signed - 9'sd96;
        end
    endfunction

    function [7:0] pct_to_contrast;
        input [7:0] pct;
        reg [4:0] step;
        begin
            step = pct_to_step_floor(pct);
            pct_to_contrast = {step,3'b000} + 8'd48;
        end
    endfunction

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            o_prev_pulse        <= 1'b0;
            o_next_pulse        <= 1'b0;
            o_auto_toggle_pulse <= 1'b0;
            o_transition_mode   <= 4'd0;
            o_brightness        <= 8'sd0;
            o_contrast          <= 8'd128;
        end else begin
            o_prev_pulse        <= 1'b0;
            o_next_pulse        <= 1'b0;
            o_auto_toggle_pulse <= 1'b0;

            // KEY3 is the dedicated manual/automatic mode key.  It is
            // intentionally not gated by SW0; otherwise the key appears dead
            // whenever the brightness/contrast switch is in its other position.
            if (key_press[2])
                o_auto_toggle_pulse <= 1'b1;

            if (!sw_sync[0]) begin
                if (key_press[0]) o_prev_pulse <= 1'b1;
                if (key_press[1]) o_next_pulse <= 1'b1;
                if (key_press[3]) begin
                    if (o_transition_mode >= 4'd4)
                        o_transition_mode <= 4'd0;
                    else
                        o_transition_mode <= o_transition_mode + 1'b1;
                end
            end else begin
                if (key_press[0] && (o_brightness > -8'sd96))
                    o_brightness <= o_brightness - 8'sd8;
                if (key_press[1] && (o_brightness < 8'sd96))
                    o_brightness <= o_brightness + 8'sd8;
                // KEY3 is reserved for the mode toggle in both SW0 positions.
                // Contrast remains adjustable from the UDP control command.
                if (key_press[3] && (o_contrast < 8'd240))
                    o_contrast <= o_contrast + 8'd8;
            end

            if (i_remote_valid) begin
                case (i_remote_code)
                    4'h1: o_prev_pulse <= 1'b1;
                    4'h2: o_next_pulse <= 1'b1;
                    4'h3: o_auto_toggle_pulse <= 1'b1;
                    4'h4: o_transition_mode <= (i_remote_value > 8'd4) ? 4'd0 : i_remote_value[3:0];
                    4'h5: o_brightness <= pct_to_brightness(i_remote_value);
                    4'h6: o_contrast <= pct_to_contrast(i_remote_value);
                    default: begin end
                endcase
            end
        end
    end
endmodule
