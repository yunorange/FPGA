`include "../QHMU_DEFINES.vh"

// ============================================================================
// QHMU_ASPECT_FIT
// Low-resource aspect-ratio-preserving fit calculator for 1920x1080.
//
// It calculates:
//   scaled_w, scaled_h : largest rectangle that fits inside 1920x1080
//   offset_x, offset_y : centered pillarbox/letterbox offsets
//
// No variable hardware divider is inferred.  One small restoring divider is
// executed over 24 clocks whenever the source width/height changes.
//
// Examples:
//   640x480 -> 1440x1080, X offset 240
//   680x680 -> 1080x1080, X offset 420
//   1024x576 -> 1920x1080, offsets 0
// ============================================================================
module QHMU_ASPECT_FIT(
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire [10:0] i_src_w,
    input  wire [9:0]  i_src_h,

    output reg         o_valid,
    output reg  [10:0] o_scaled_w,
    output reg  [10:0] o_scaled_h,
    output reg  [10:0] o_offset_x,
    output reg  [10:0] o_offset_y
);
    reg [10:0] last_w;
    reg [9:0]  last_h;
    reg        busy;
    reg        fit_by_width;

    reg [23:0] dividend;
    reg [15:0] divisor;
    reg [23:0] quotient;
    reg [24:0] remainder;
    reg [4:0]  div_count;

    wire [23:0] w_ext = {13'd0,i_src_w};
    wire [23:0] h_ext = {14'd0,i_src_h};

    // Constant multipliers implemented with shifts/add/subtract:
    // 1080 = 1024 + 64 - 8
    // 1920 = 2048 - 128
    wire [23:0] w_x_1080 =
        (w_ext << 10) + (w_ext << 6) - (w_ext << 3);
    wire [23:0] h_x_1920 =
        (h_ext << 11) - (h_ext << 7);

    // w/h >= 1920/1080 => fit to output width.
    wire source_is_wide = (w_x_1080 >= h_x_1920);

    wire [24:0] rem_shift =
        {remainder[23:0],dividend[23]};
    wire [24:0] divisor_ext = {9'd0,divisor};
    wire div_ge = (rem_shift >= divisor_ext);
    wire [24:0] rem_after =
        div_ge ? (rem_shift-divisor_ext) : rem_shift;
    wire [23:0] quot_after =
        {quotient[22:0],div_ge};

    wire [10:0] quotient_clamped =
        (quot_after[10:0] == 11'd0) ? 11'd1 :
        quot_after[10:0];

    always @(posedge i_clk) begin
        if (i_rst) begin
            last_w       <= 11'h7FF;
            last_h       <= 10'h3FF;
            busy         <= 1'b0;
            fit_by_width <= 1'b0;
            dividend     <= 24'd0;
            divisor      <= 16'd1;
            quotient     <= 24'd0;
            remainder    <= 25'd0;
            div_count    <= 5'd0;
            o_valid      <= 1'b0;
            o_scaled_w   <= 11'd0;
            o_scaled_h   <= 11'd0;
            o_offset_x   <= 11'd0;
            o_offset_y   <= 11'd0;
        end else begin
            if ((i_src_w == 11'd0) || (i_src_h == 10'd0)) begin
                last_w     <= i_src_w;
                last_h     <= i_src_h;
                busy       <= 1'b0;
                o_valid    <= 1'b0;
                o_scaled_w <= 11'd0;
                o_scaled_h <= 11'd0;
                o_offset_x <= 11'd0;
                o_offset_y <= 11'd0;
            end else if (!busy &&
                         ((!o_valid) ||
                          (i_src_w != last_w) ||
                          (i_src_h != last_h))) begin
                last_w       <= i_src_w;
                last_h       <= i_src_h;
                fit_by_width <= source_is_wide;
                quotient     <= 24'd0;
                remainder    <= 25'd0;
                div_count    <= 5'd0;
                busy         <= 1'b1;
                o_valid      <= 1'b0;

                if (source_is_wide) begin
                    // scaled_h = src_h * 1920 / src_w
                    dividend <= h_x_1920;
                    divisor  <= {5'd0,i_src_w};
                end else begin
                    // scaled_w = src_w * 1080 / src_h
                    dividend <= w_x_1080;
                    divisor  <= {6'd0,i_src_h};
                end
            end else if (busy) begin
                dividend  <= {dividend[22:0],1'b0};
                remainder <= rem_after;
                quotient  <= quot_after;

                if (div_count == 5'd23) begin
                    busy    <= 1'b0;
                    o_valid <= 1'b1;

                    if (fit_by_width) begin
                        o_scaled_w <= 11'd1920;
                        o_scaled_h <= quotient_clamped;
                        o_offset_x <= 11'd0;
                        o_offset_y <=
                            (11'd1080-quotient_clamped) >> 1;
                    end else begin
                        o_scaled_w <= quotient_clamped;
                        o_scaled_h <= 11'd1080;
                        o_offset_x <=
                            (11'd1920-quotient_clamped) >> 1;
                        o_offset_y <= 11'd0;
                    end
                end else begin
                    div_count <= div_count + 1'b1;
                end
            end
        end
    end
endmodule
