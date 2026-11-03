// ============================================================================
// QHMU_HDMI_PLL
// 50 MHz -> ~74.285714 MHz pixel + ~371.428571 MHz 5x serializer
//
// Divider relationship in NOCOMP mode:
//   VCO    = 50 MHz * 52 / 7  = 371.428571 MHz
//   Pixel  = VCO / 5          =  74.285714 MHz
//   Serial = VCO / 1          = 371.428571 MHz
//
// Nominal 1080p30 requires 74.25 / 371.25 MHz.  The error is ~0.048%.
// The 5:1 relationship is exact, which is the critical requirement for the
// project's 10-bit TMDS DDR serializer.
// ============================================================================
module QHMU_HDMI_PLL(
    input  wire i_refclk,
    input  wire i_reset,
    output wire o_lock,
    output wire o_pixel_clk,
    output wire o_serial_clk
);
    wire [4:0] clkc;
    wire psdone_unused;
    wire [7:0] do_unused;

    assign o_pixel_clk  = clkc[0];
    assign o_serial_clk = clkc[1];

    EG_PHY_PLL #(
        .DPHASE_SOURCE("DISABLE"),
        .DYNCFG("DISABLE"),
        .FIN("50.000"),
        .FEEDBK_MODE("NOCOMP"),
        .STDBY_ENABLE("DISABLE"),
        .PLLRST_ENA("ENABLE"),
        .SYNC_ENABLE("DISABLE"),
        .DERIVE_PLL_CLOCKS("DISABLE"),
        .GEN_BASIC_CLOCK("DISABLE"),
        .GMC_GAIN(2),
        .ICP_CURRENT(9),
        .KVCO(2),
        .LPF_CAPACITOR(1),
        .LPF_RESISTOR(8),

        .REFCLK_DIV(7),
        .FBCLK_DIV(52),

        .CLKC0_ENABLE("ENABLE"),
        .CLKC0_DIV(5),
        .CLKC0_CPHASE(4),
        .CLKC0_FPHASE(0),

        .CLKC1_ENABLE("ENABLE"),
        .CLKC1_DIV(1),
        .CLKC1_CPHASE(0),
        .CLKC1_FPHASE(0)
    ) u_pll (
        .refclk(i_refclk),
        .reset(i_reset),
        .stdby(1'b0),
        .extlock(o_lock),

        .load_reg(1'b0),
        .psclk(1'b0),
        .psdown(1'b0),
        .psstep(1'b0),
        .psclksel(3'b000),
        .psdone(psdone_unused),

        .dclk(1'b0),
        .dcs(1'b0),
        .dwe(1'b0),
        .di(8'h00),
        .daddr(6'h00),
        .do(do_unused),

        .fbclk(1'b0),
        .clkc(clkc)
    );
endmodule
