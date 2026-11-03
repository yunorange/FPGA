// Board-level SD-card SPI block interface. The low-level implementation is the
// proven Anlogic demo stack (spi_master + sd_card_cmd + sector controller).
module QHMU_SD_BLOCK_IF(
    input  wire        i_clk,
    input  wire        i_rst,

    output wire        o_sd_cs_n,
    output wire        o_sd_clk,
    output wire        o_sd_mosi,
    input  wire        i_sd_miso,

    output wire        o_init_done,

    input  wire        i_read_req,
    input  wire [31:0] i_read_lba,
    output wire [7:0]  o_read_data,
    output wire        o_read_valid,
    output wire        o_read_done,

    input  wire        i_write_req,
    input  wire [31:0] i_write_lba,
    input  wire [7:0]  i_write_data,
    output wire        o_write_data_req,
    output wire        o_write_done
);
    sd_card_top #(
        .SPI_LOW_SPEED_DIV(248),
        .SPI_HIGH_SPEED_DIV(2)
    ) u_sd_card (
        .clk(i_clk),
        .rst(i_rst),
        .SD_nCS(o_sd_cs_n),
        .SD_DCLK(o_sd_clk),
        .SD_MOSI(o_sd_mosi),
        .SD_MISO(i_sd_miso),
        .sd_init_done(o_init_done),
        .sd_sec_read(i_read_req),
        .sd_sec_read_addr(i_read_lba),
        .sd_sec_read_data(o_read_data),
        .sd_sec_read_data_valid(o_read_valid),
        .sd_sec_read_end(o_read_done),
        .sd_sec_write(i_write_req),
        .sd_sec_write_addr(i_write_lba),
        .sd_sec_write_data(i_write_data),
        .sd_sec_write_data_req(o_write_data_req),
        .sd_sec_write_end(o_write_done)
    );
endmodule
