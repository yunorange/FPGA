# QHMU_HDMI_TOP: 50-MHz board clock and maximum-rate RGMII receive clock.
create_clock -name I_CLK_50M -period 20.000 -waveform {0.000 10.000} [get_ports {I_CLK_50M}]
create_clock -name I_PHY_RGMII_RX_CLK -period 8.000 -waveform {0.000 4.000} [get_ports {I_PHY_RGMII_RX_CLK}]
derive_pll_clocks
