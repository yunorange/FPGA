`include "../QHMU_DEFINES.vh"

// ============================================================================
// QHMU_SUBTITLE_PLAYER
// Full-width SUBTITLE.BIN player with a five-sector rolling cache.
//
// File format (no header):
//   each 16-pixel vertical bitmap column is a 16-bit value;
//   byte 0 = column[7:0], byte 1 = column[15:8];
//   column[15] is the top pixel, column[0] is the bottom pixel.
//
// One FAT32 sector stores 256 columns. Five circular sectors are cached
// (1280 source columns), enough for a 960-column viewport plus up to 255
// columns of scroll offset. Each source pixel is doubled horizontally and
// vertically, producing a 1920 x 32 pixel subtitle strip across the full
// 1920x1080p30 output.
//
// File-size requirement: SUBTITLE.BIN must be at least 512 bytes and its size
// must be a multiple of 512 bytes. The FAT32 reader automatically loops it.
//
// RAM: one 2048 x 16 dual-clock RAM inference (only five 256-column banks are
// used); this is typically two embedded RAM blocks on the target FPGA.
// ============================================================================
module QHMU_SUBTITLE_PLAYER(
    input  wire        i_ctrl_clk,
    input  wire        i_ctrl_rst,

    input  wire        i_file_start,
    input  wire [31:0] i_file_size,
    input  wire [7:0]  i_file_data,
    input  wire        i_file_data_valid,
    input  wire        i_file_done,
    output wire        o_stream_ready,
    output reg         o_format_ok,
    output reg         o_error,

    input  wire        i_pixel_clk,
    input  wire        i_pixel_rst,
    input  wire        i_frame_start,
    input  wire        i_enable,
    input  wire [10:0] i_x,
    input  wire [10:0] i_y,
    output reg         o_hit,
    output reg  [23:0] o_rgb
);
    localparam [2:0] BANK0 = 3'd0;
    localparam [2:0] BANK1 = 3'd1;
    localparam [2:0] BANK2 = 3'd2;
    localparam [2:0] BANK3 = 3'd3;
    localparam [2:0] BANK4 = 3'd4;

    reg [2:0] wr_bank;
    reg [7:0] wr_col;
    reg       byte_half;
    reg [7:0] byte_lo;

    reg        ram_wr_en;
    reg [2:0]  ram_wr_bank;
    reg [7:0]  ram_wr_addr;
    reg [15:0] ram_wr_data;

    reg [4:0] bank_valid;
    reg [2:0] base_bank;
    reg [7:0] scroll_offset;
    reg        started;
    reg [31:0] file_size_q;

    function [2:0] bank_next;
        input [2:0] bank;
        begin
            if (bank >= BANK4)
                bank_next = BANK0;
            else
                bank_next = bank + 1'b1;
        end
    endfunction

    // One pulse per completed video frame is transferred to the control
    // domain. At 1080p30, one source column advances every frame (30 col/s).
    wire frame_tick_ctrl;
    QHMU_PULSE_SYNC u_frame_to_ctrl(
        .i_src_clk(i_pixel_clk), .i_src_rst(i_pixel_rst),
        .i_src_pulse(i_frame_start),
        .i_dst_clk(i_ctrl_clk), .i_dst_rst(i_ctrl_rst),
        .o_dst_pulse(frame_tick_ctrl)
    );

    // Keep filling sequential sectors until all five circular banks are valid.
    // A bank is released after the viewport has scrolled past that sector.
    assign o_stream_ready = o_format_ok && !( &bank_valid );

    always @(posedge i_ctrl_clk) begin
        if (i_ctrl_rst) begin
            wr_bank      <= BANK0;
            wr_col       <= 8'd0;
            byte_half    <= 1'b0;
            byte_lo      <= 8'd0;
            ram_wr_en    <= 1'b0;
            ram_wr_bank  <= BANK0;
            ram_wr_addr  <= 8'd0;
            ram_wr_data  <= 16'd0;
            bank_valid   <= 5'b00000;
            base_bank    <= BANK0;
            scroll_offset<= 8'd0;
            started      <= 1'b0;
            file_size_q  <= 32'd0;
            o_format_ok  <= 1'b0;
            o_error      <= 1'b0;
        end else begin
            ram_wr_en <= 1'b0;

            if (i_file_start) begin
                file_size_q <= i_file_size;
                if ((i_file_size >= 32'd512) &&
                    (i_file_size[8:0] == 9'd0)) begin
                    o_format_ok <= 1'b1;
                    o_error     <= 1'b0;
                end else begin
                    o_format_ok <= 1'b0;
                    o_error     <= 1'b1;
                end
            end

            // Incoming subtitle bytes are paired into one 16-bit vertical
            // bitmap column. The current sector is written to wr_bank.
            if (i_file_data_valid && o_format_ok) begin
                if (!byte_half) begin
                    byte_lo   <= i_file_data;
                    byte_half <= 1'b1;
                end else begin
                    ram_wr_en   <= 1'b1;
                    ram_wr_bank <= wr_bank;
                    ram_wr_addr <= wr_col;
                    ram_wr_data <= {i_file_data,byte_lo};
                    byte_half   <= 1'b0;

                    if (wr_col == 8'hFF) begin
                        bank_valid[wr_bank] <= 1'b1;
                        wr_col <= 8'd0;
                        wr_bank <= bank_next(wr_bank);
                    end else begin
                        wr_col <= wr_col + 1'b1;
                    end
                end
            end

            // Begin scrolling only after the full 1280-column ring is filled.
            if (!started && (&bank_valid)) begin
                started       <= 1'b1;
                base_bank     <= BANK0;
                scroll_offset <= 8'd0;
            end

            // Each sector boundary advances the ring base. The bank that just
            // scrolled out is freed for the next sequential sector from FAT32.
            if (frame_tick_ctrl && started && o_format_ok) begin
                if (scroll_offset != 8'hFF) begin
                    scroll_offset <= scroll_offset + 1'b1;
                end else begin
                    scroll_offset <= 8'd0;
                    bank_valid[base_bank] <= 1'b0;
                    wr_bank <= base_bank;
                    base_bank <= bank_next(base_bank);
                    wr_col <= 8'd0;
                    byte_half <= 1'b0;
                end
            end

            // The FAT reader normally loops the file. A malformed file is
            // rejected at open time; this catches a size change mid-stream.
            if (i_file_done && (file_size_q[8:0] != 9'd0))
                o_error <= 1'b1;
        end
    end

    // One 2048 x 16 dual-clock RAM stores five physical 256-column sectors.
    // Address = {physical_bank[2:0], column[7:0]}; banks 5..7 are unused.
    reg  [10:0] ram_rd_addr;
    wire [10:0] ram_wr_addr_full = {ram_wr_bank,ram_wr_addr};
    wire [15:0] ram_rd_data;

    QHMU_DPRAM_DC #(.DATA_WIDTH(16),.ADDR_WIDTH(11)) u_sub_ram(
        .i_wr_clk(i_ctrl_clk), .i_wr_en(ram_wr_en),
        .i_wr_addr(ram_wr_addr_full), .i_wr_data(ram_wr_data),
        .i_rd_clk(i_pixel_clk), .i_rd_addr(ram_rd_addr),
        .o_rd_data(ram_rd_data)
    );

    // Synchronize stable ring metadata into the pixel domain.
    wire [8:0] sub_cfg_ctrl = {started,bank_valid,base_bank};
    wire [8:0] sub_cfg_px;
    QHMU_SYNC_BUS #(.WIDTH(9)) u_sub_cfg_sync(
        .i_clk(i_pixel_clk), .i_async_data(sub_cfg_ctrl),
        .o_sync_data(sub_cfg_px)
    );

    wire       started_px    = sub_cfg_px[8];
    wire [4:0] valid_px      = sub_cfg_px[7:3];
    wire [2:0] base_bank_px  = sub_cfg_px[2:0];

    wire [7:0] scroll_offset_px;
    QHMU_SYNC_BUS #(.WIDTH(8)) u_sub_scroll_sync(
        .i_clk(i_pixel_clk), .i_async_data(scroll_offset),
        .o_sync_data(scroll_offset_px)
    );

    reg [10:0] sum_col;
    reg [2:0]  sector_index;
    reg [3:0]  bank_sum;
    reg [2:0]  bank_sel_comb;
    reg [7:0]  bank_col;

    always @(*) begin
        sum_col      = {3'd0,scroll_offset_px};
        sector_index = 3'd0;
        bank_sum     = {1'b0,base_bank_px};
        bank_sel_comb= base_bank_px;
        bank_col     = scroll_offset_px;

        if ((i_x >= `QHMU_SUBTITLE_X0) &&
            (i_x < (`QHMU_SUBTITLE_X0 +
                    (`QHMU_SUBTITLE_VIEW_W * `QHMU_SUBTITLE_SCALE)))) begin
            // 2x horizontal replication: one source column per two pixels.
            sum_col = {3'd0,scroll_offset_px} +
                      ((i_x-`QHMU_SUBTITLE_X0) >> 1);
        end

        sector_index = sum_col[10:8];
        bank_col     = sum_col[7:0];

        // Circular mapping: physical bank = (base bank + logical sector) % 5.
        bank_sum = {1'b0,base_bank_px} + {1'b0,sector_index};
        if (bank_sum >= 4'd5)
            bank_sum = bank_sum - 4'd5;
        bank_sel_comb = bank_sum[2:0];

        ram_rd_addr = {bank_sel_comb,bank_col};
    end

    // RAM read is synchronous. Delay active/row/valid by one pixel so the
    // bitmap bit is tested against the address/data from the same pixel.
    reg [3:0] row_d;
    reg       active_d;
    reg       bank_valid_d;
    reg [23:0] color_d;

    always @(posedge i_pixel_clk) begin
        if (i_pixel_rst) begin
            row_d        <= 4'd0;
            active_d     <= 1'b0;
            bank_valid_d <= 1'b0;
            color_d      <= 24'hFFE070;
            o_hit        <= 1'b0;
            o_rgb        <= 24'hFFE070;
        end else begin
            row_d <= (i_y-`QHMU_SUBTITLE_Y0) >> 1;

            active_d <= i_enable && started_px &&
                        (i_x >= `QHMU_SUBTITLE_X0) &&
                        (i_x < (`QHMU_SUBTITLE_X0 +
                                (`QHMU_SUBTITLE_VIEW_W *
                                 `QHMU_SUBTITLE_SCALE))) &&
                        (i_y >= `QHMU_SUBTITLE_Y0) &&
                        (i_y < (`QHMU_SUBTITLE_Y0 +
                                (16 * `QHMU_SUBTITLE_SCALE)));

            bank_valid_d <= valid_px[bank_sel_comb];
            color_d <= 24'hFFE070;

            o_hit <= active_d && bank_valid_d && ram_rd_data[15-row_d];
            o_rgb <= color_d;
        end
    end
endmodule
