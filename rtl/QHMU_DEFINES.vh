`ifndef QHMU_DEFINES_VH
`define QHMU_DEFINES_VH

// Ethernet bring-up diagnostics.
// Uncomment to route the four board LEDs to official TEMAC/RGMII debug indicators.
`define QHMU_NET_DEBUG

// ============================================================================
// QHMU_HDMI_PRO - 2K-class 1920x1080p30 output
//
// "2K" in this project means 1920x1080 output because the supplied Anlogic
// APUG092 HDMI1.4b Transmitter Core is documented/configured for 1080p-class
// output.  This build intentionally uses 30 Hz instead of 60 Hz to reduce
// pixel/TMDS clock pressure and SDRAM bandwidth on EG4S20.
//
// Nominal CTA-861 1080p30 timing:
//   active  : 1920 x 1080
//   total   : 2200 x 1125
//   VIC     : 34
//
// The PLL below produces approximately:
//   pixel   : 74.285714 MHz
//   serial  : 371.428571 MHz = 5 x pixel
// which is within 0.05% of the nominal 74.25 / 371.25 MHz clocks.
// ============================================================================
`define QHMU_OUT_W              1920
`define QHMU_OUT_H              1080

`define QHMU_HTOTAL             2200
`define QHMU_HACTIVE            1920
`define QHMU_HSA                44
`define QHMU_HFP                88
`define QHMU_HBP                148

`define QHMU_VTOTAL             1125
`define QHMU_VACTIVE            1080
`define QHMU_VSA                5
`define QHMU_VFP                4
`define QHMU_VBP                36

`define QHMU_HBLANK             (`QHMU_HTOTAL-`QHMU_HACTIVE)
`define QHMU_VBLANK             (`QHMU_VTOTAL-`QHMU_VACTIVE)

// EG4S20 internal SDRAM: 2M x 32 bit = 8 MiB.
// Two equal 1M-word RGBX8888 frame buffers.
// Each source row has a fixed 1024-word stride.
`define QHMU_FB_STRIDE          1024
`define QHMU_FB_STRIDE_SHIFT    10
`define QHMU_MAX_SRC_W          1024
`define QHMU_MAX_SRC_H          1023
`define QHMU_FB0_BASE           21'h000000
`define QHMU_FB1_BASE           21'h100000
`define QHMU_MAX_FILES          32

// SUBTITLE.BIN full-width rolling text.
// The 1920-pixel HDMI width is represented by 960 source bitmap columns at
// 2x horizontal scale. Five 256-column sectors (1280 columns total) are
// cached so the complete viewport remains available while scrolling.
`define QHMU_SUBTITLE_VIEW_W    960
`define QHMU_SUBTITLE_SCALE     2
`define QHMU_SUBTITLE_X0        0
`define QHMU_SUBTITLE_Y0        1036

`endif
