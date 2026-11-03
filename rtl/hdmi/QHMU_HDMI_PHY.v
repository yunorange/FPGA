// QHMU_HDMI_PHY
// APUG092-compatible EG4 physical layer.  Only the positive member of each
// differential pair is exposed in RTL; the LVDS25 pin assignment creates the
// complementary N pin in the EG4 I/O cell.
module QHMU_HDMI_PHY(
    input  wire       i_pixel_clk,
    input  wire       i_serial_clk,
    input  wire       i_rst,
    input  wire [9:0] i_tmds_ch0,
    input  wire [9:0] i_tmds_ch1,
    input  wire [9:0] i_tmds_ch2,
    input  wire [9:0] i_tmds_clk,
    output wire       o_tmds_d0_p,
    output wire       o_tmds_d1_p,
    output wire       o_tmds_d2_p,
    output wire       o_tmds_clk_p
);
    // APUG092 reverses the 10-bit link word before loading its serializer.
    wire [9:0] ch0 = {i_tmds_ch0[0],i_tmds_ch0[1],i_tmds_ch0[2],i_tmds_ch0[3],i_tmds_ch0[4],
                      i_tmds_ch0[5],i_tmds_ch0[6],i_tmds_ch0[7],i_tmds_ch0[8],i_tmds_ch0[9]};
    wire [9:0] ch1 = {i_tmds_ch1[0],i_tmds_ch1[1],i_tmds_ch1[2],i_tmds_ch1[3],i_tmds_ch1[4],
                      i_tmds_ch1[5],i_tmds_ch1[6],i_tmds_ch1[7],i_tmds_ch1[8],i_tmds_ch1[9]};
    wire [9:0] ch2 = {i_tmds_ch2[0],i_tmds_ch2[1],i_tmds_ch2[2],i_tmds_ch2[3],i_tmds_ch2[4],
                      i_tmds_ch2[5],i_tmds_ch2[6],i_tmds_ch2[7],i_tmds_ch2[8],i_tmds_ch2[9]};
    wire [9:0] clk = {i_tmds_clk[0],i_tmds_clk[1],i_tmds_clk[2],i_tmds_clk[3],i_tmds_clk[4],
                      i_tmds_clk[5],i_tmds_clk[6],i_tmds_clk[7],i_tmds_clk[8],i_tmds_clk[9]};

    QHMU_TMDS_SERIALIZER u_d0(.i_pixel_clk(i_pixel_clk),.i_serial_clk(i_serial_clk),.i_rst(i_rst),.i_data(ch0),.o_serial(o_tmds_d0_p));
    QHMU_TMDS_SERIALIZER u_d1(.i_pixel_clk(i_pixel_clk),.i_serial_clk(i_serial_clk),.i_rst(i_rst),.i_data(ch1),.o_serial(o_tmds_d1_p));
    QHMU_TMDS_SERIALIZER u_d2(.i_pixel_clk(i_pixel_clk),.i_serial_clk(i_serial_clk),.i_rst(i_rst),.i_data(ch2),.o_serial(o_tmds_d2_p));
    QHMU_TMDS_SERIALIZER u_ck(.i_pixel_clk(i_pixel_clk),.i_serial_clk(i_serial_clk),.i_rst(i_rst),.i_data(clk),.o_serial(o_tmds_clk_p));
endmodule
