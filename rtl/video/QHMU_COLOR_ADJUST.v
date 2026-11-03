// ============================================================================
// QHMU_COLOR_ADJUST - explicitly sized RGB brightness/contrast datapath.
// Each channel uses a 9x9 signed multiply instead of 32-bit integer arithmetic.
// Default brightness=0 and contrast=128 is bit-exact passthrough.
// ============================================================================
module QHMU_COLOR_ADJUST(
    input  wire [23:0] i_pixel,
    input  wire signed [7:0] i_brightness,
    input  wire [7:0]  i_contrast,
    output reg  [23:0] o_pixel
);
    wire signed [8:0] r_center = $signed({1'b0,i_pixel[23:16]}) - 9'sd128;
    wire signed [8:0] g_center = $signed({1'b0,i_pixel[15:8]})  - 9'sd128;
    wire signed [8:0] b_center = $signed({1'b0,i_pixel[7:0]})   - 9'sd128;
    wire signed [8:0] contrast_ext = $signed({1'b0,i_contrast});

    wire signed [17:0] r_product = r_center * contrast_ext;
    wire signed [17:0] g_product = g_center * contrast_ext;
    wire signed [17:0] b_product = b_center * contrast_ext;

    wire signed [10:0] brightness_ext = {{3{i_brightness[7]}},i_brightness};
    wire signed [10:0] r_calc = (r_product >>> 7) + 11'sd128 + brightness_ext;
    wire signed [10:0] g_calc = (g_product >>> 7) + 11'sd128 + brightness_ext;
    wire signed [10:0] b_calc = (b_product >>> 7) + 11'sd128 + brightness_ext;

    always @* begin
        if (r_calc < 11'sd0)       o_pixel[23:16] = 8'd0;
        else if (r_calc > 11'sd255)o_pixel[23:16] = 8'd255;
        else                  o_pixel[23:16] = r_calc[7:0];

        if (g_calc < 11'sd0)       o_pixel[15:8] = 8'd0;
        else if (g_calc > 11'sd255)o_pixel[15:8] = 8'd255;
        else                  o_pixel[15:8] = g_calc[7:0];

        if (b_calc < 11'sd0)       o_pixel[7:0] = 8'd0;
        else if (b_calc > 11'sd255)o_pixel[7:0] = 8'd255;
        else                  o_pixel[7:0] = b_calc[7:0];
    end
endmodule
