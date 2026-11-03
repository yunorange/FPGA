// QHMU_SDRAM_PLL
// Derived from the APUG010/APUG011 EG4 generated PLL reference.
// 50 MHz input -> C0 12.5 MHz feedback, C1 150 MHz 0 deg,
// C2 150 MHz 180 deg.  The original reference is 25 MHz with REFCLK_DIV=2;
// using REFCLK_DIV=4 preserves the same 12.5 MHz PLL reference point.
module QHMU_SDRAM_PLL(
    input  wire i_refclk,
    input  wire i_reset,
    output wire o_lock,
    output wire o_sdram_clk,
    output wire o_sdram_clk_180
);
    wire clk0_buf;
    wire clk0_feedback;
    wire clk_unused3, clk_unused4;
    wire psdone_unused;
    wire [7:0] do_unused;

    EG_LOGIC_BUFG u_feedback_buf(.i(clk0_buf), .o(clk0_feedback));

    EG_PHY_PLL #(
        .DPHASE_SOURCE("DISABLE"),
        .DYNCFG("DISABLE"),
        .FIN("50.000"),
        .FEEDBK_MODE("NORMAL"),
        .FEEDBK_PATH("CLKC0_EXT"),
        .STDBY_ENABLE("DISABLE"),
        .PLLRST_ENA("ENABLE"),
        .SYNC_ENABLE("DISABLE"),
        .DERIVE_PLL_CLOCKS("DISABLE"),
        .GEN_BASIC_CLOCK("DISABLE"),
        .GMC_GAIN(0),
        .ICP_CURRENT(9),
        .KVCO(2),
        .LPF_CAPACITOR(2),
        .LPF_RESISTOR(8),
        .REFCLK_DIV(4),
        .FBCLK_DIV(1),
        .CLKC0_ENABLE("ENABLE"),
        .CLKC0_DIV(84),
        .CLKC0_CPHASE(83),
        .CLKC0_FPHASE(0),
        .CLKC1_ENABLE("ENABLE"),
        .CLKC1_DIV(7),
        .CLKC1_CPHASE(6),
        .CLKC1_FPHASE(0),
        .CLKC2_ENABLE("ENABLE"),
        .CLKC2_DIV(7),
        .CLKC2_CPHASE(2),
        .CLKC2_FPHASE(4)
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
        .fbclk(clk0_feedback),
        .clkc({clk_unused4, clk_unused3, o_sdram_clk_180, o_sdram_clk, clk0_buf})
    );
endmodule
