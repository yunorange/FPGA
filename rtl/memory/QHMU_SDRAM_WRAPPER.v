module QHMU_SDRAM_WRAPPER(
    input  wire        i_clk,
    input  wire        i_clk_180,
    input  wire        i_rst,

    input  wire        i_app_wr_en,
    input  wire [20:0] i_app_wr_addr,
    input  wire [3:0]  i_app_wr_dm,
    input  wire [31:0] i_app_wr_data,
    input  wire        i_app_rd_en,
    input  wire [20:0] i_app_rd_addr,
    output wire        o_app_rd_valid,
    output wire [31:0] o_app_rd_data,

    output wire        o_init_done,
    output wire        o_refresh_active,
    output wire        o_busy
);
    wire sdram_clk;
    wire sdr_ras, sdr_cas, sdr_we;
    wire [1:0] sdr_ba;
    wire [10:0] sdr_addr;
    wire [3:0] sdr_dm;
    wire [31:0] sdr_dq;

    sdr_as_ram #(.self_refresh_open(1'b1)) u_sdr_as_ram (
        .Sdr_clk(i_clk),
        .Sdr_clk_sft(i_clk_180),
        .Rst(i_rst),
        .Sdr_init_done(o_init_done),
        .Sdr_init_ref_vld(o_refresh_active),
        .Sdr_busy(o_busy),
        .App_ref_req(1'b0),
        .App_wr_en(i_app_wr_en),
        .App_wr_addr(i_app_wr_addr),
        .App_wr_dm(i_app_wr_dm),
        .App_wr_din(i_app_wr_data),
        .App_rd_en(i_app_rd_en),
        .App_rd_addr(i_app_rd_addr),
        .Sdr_rd_en(o_app_rd_valid),
        .Sdr_rd_dout(o_app_rd_data),
        .SDRAM_CLK(sdram_clk),
        .SDR_RAS(sdr_ras),
        .SDR_CAS(sdr_cas),
        .SDR_WE(sdr_we),
        .SDR_BA(sdr_ba),
        .SDR_ADDR(sdr_addr),
        .SDR_DM(sdr_dm),
        .SDR_DQ(sdr_dq)
    );

    EG_PHY_SDRAM_2M_32 u_sdram_phy (
        .clk(sdram_clk),
        .ras_n(sdr_ras),
        .cas_n(sdr_cas),
        .we_n(sdr_we),
        .addr(sdr_addr),
        .ba(sdr_ba),
        .dq(sdr_dq),
        .cs_n(1'b0),
        .dm0(sdr_dm[0]),
        .dm1(sdr_dm[1]),
        .dm2(sdr_dm[2]),
        .dm3(sdr_dm[3]),
        .cke(1'b1)
    );
endmodule
