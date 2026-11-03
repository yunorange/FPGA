module QHMU_CLOCK_RESET(
    input  wire i_clk_50m,
    output wire o_clk_ctrl,
    output wire o_clk_sdram,
    output wire o_clk_sdram_180,
    output wire o_clk_pixel,
    output wire o_clk_serial,
    output wire o_rst_ctrl,
    output wire o_rst_sdram,
    output wire o_rst_pixel,
    output wire o_all_locked
);
    wire hdmi_lock, sdram_lock;
    reg [11:0] por_cnt;
    wire por_rst;

    assign o_clk_ctrl = i_clk_50m;

    QHMU_HDMI_PLL u_hdmi_pll(
        .i_refclk(i_clk_50m), .i_reset(1'b0), .o_lock(hdmi_lock),
        .o_pixel_clk(o_clk_pixel), .o_serial_clk(o_clk_serial)
    );
    QHMU_SDRAM_PLL u_sdram_pll(
        .i_refclk(i_clk_50m), .i_reset(1'b0), .o_lock(sdram_lock),
        .o_sdram_clk(o_clk_sdram), .o_sdram_clk_180(o_clk_sdram_180)
    );

    assign o_all_locked = hdmi_lock & sdram_lock;

    always @(posedge i_clk_50m) begin
        if (!o_all_locked)
            por_cnt <= 12'd0;
        else if (!por_cnt[11])
            por_cnt <= por_cnt + 1'b1;
    end
    assign por_rst = ~por_cnt[11];

    QHMU_RESET_SYNC u_rst_ctrl (
        .i_clk(i_clk_50m), .i_async_rst(por_rst), .o_rst(o_rst_ctrl)
    );
    QHMU_RESET_SYNC u_rst_sdram (
        .i_clk(o_clk_sdram), .i_async_rst(por_rst), .o_rst(o_rst_sdram)
    );
    QHMU_RESET_SYNC u_rst_pixel (
        .i_clk(o_clk_pixel), .i_async_rst(por_rst), .o_rst(o_rst_pixel)
    );
endmodule
