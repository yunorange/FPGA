`include "../QHMU_DEFINES.vh"

// QHMU 24-bit BI_RGB BMP loader - TD-safe V2.
// Key changes versus the earlier version:
//   1) o_load_busy is COMBINATIONAL from a small loader FSM; there is no busy FF.
//   2) o_load_error/o_load_done are one-cycle REGISTERED pulses with an
//      unconditional low default; no sticky/self-feedback error path exists.
//   3) i_file_done is represented by a DRAIN state, eliminating file_done_seen.
//   4) No output combinational error path depends on FIFO-ready/full logic.
module QHMU_BMP_LOADER(
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_file_start,
    input  wire [31:0] i_file_size,
    input  wire [7:0]  i_file_data,
    input  wire        i_file_valid,
    input  wire        i_file_done,
    input  wire        i_target_buffer,

    output reg         o_wr_valid,
    output reg  [20:0] o_wr_addr,
    output reg  [31:0] o_wr_data,
    output reg  [3:0]  o_wr_dm,
    input  wire        i_wr_ready,

    output wire        o_load_busy,
    output reg         o_load_done,
    output reg         o_load_error,
    output reg  [10:0] o_image_width,
    output reg  [9:0]  o_image_height
);

    localparam [1:0] LS_IDLE   = 2'b00;
    localparam [1:0] LS_ACTIVE = 2'b01;
    localparam [1:0] LS_DRAIN  = 2'b10;

    reg [1:0] load_state;

    reg [31:0] byte_pos;
    reg [31:0] pixel_offset;
    reg [31:0] bmp_width;
    reg [31:0] bmp_height_raw;
    reg [15:0] bmp_bpp;
    reg [31:0] bmp_compression;
    reg [7:0]  sig0;
    reg [7:0]  sig1;

    reg [31:0] row_raw_bytes;
    reg [31:0] row_stride_bytes;
    reg [31:0] row_byte_pos;
    reg [9:0]  file_row;
    reg [10:0] pixel_x;
    reg [1:0]  pixel_phase;
    reg [7:0]  pix_b;
    reg [7:0]  pix_g;
    reg         format_ok;

    // Masked dummy writes complete the final 4-word write group of a row.
    reg [1:0]  dummy_pending;
    reg [20:0] dummy_addr;

    wire [31:0] height_abs32;
    wire [20:0] buffer_base;
    wire [9:0]  dest_y;
    wire [20:0] pixel_word_addr;

    wire header_check_now;
    wire header_valid_now;
    wire pixel_data_now;
    wire pixel_commit_now;
    wire write_fail_now;
    wire frame_complete_now;

    assign o_load_busy = (load_state != LS_IDLE);

    assign height_abs32 = bmp_height_raw[31] ?
                          (~bmp_height_raw + 32'd1) : bmp_height_raw;
    assign buffer_base = i_target_buffer ? `QHMU_FB1_BASE : `QHMU_FB0_BASE;
    assign dest_y = bmp_height_raw[31] ?
                    file_row : (height_abs32[9:0] - 10'd1 - file_row);
    assign pixel_word_addr = buffer_base +
                             ({11'd0,dest_y} << `QHMU_FB_STRIDE_SHIFT) +
                             {10'd0,pixel_x};

    assign header_check_now = (load_state == LS_ACTIVE) &&
                              i_file_valid && (byte_pos == 32'd53);

    assign header_valid_now = (sig0 == 8'h42) &&
                              (sig1 == 8'h4D) &&
                              (bmp_bpp == 16'd24) &&
                              (bmp_compression == 32'd0) &&
                              (bmp_width != 32'd0) &&
                              (bmp_width <= `QHMU_MAX_SRC_W) &&
                              (height_abs32 != 32'd0) &&
                              (height_abs32 <= `QHMU_MAX_SRC_H);

    assign pixel_data_now = (load_state == LS_ACTIVE) &&
                            i_file_valid && format_ok &&
                            (byte_pos >= pixel_offset) &&
                            (file_row < height_abs32[9:0]) &&
                            (row_byte_pos < row_raw_bytes);

    assign pixel_commit_now = pixel_data_now && (pixel_phase == 2'd2);

    assign write_fail_now = pixel_commit_now &&
                            (!i_wr_ready || (dummy_pending != 2'd0));

    assign frame_complete_now = format_ok &&
                                (file_row >= height_abs32[9:0]);

    // i_rst is already synchronized in QHMU_HDMI_TOP, so use a synchronous
    // reset here.  This avoids extra asynchronous control-set inference.
    always @(posedge i_clk) begin
        if (i_rst) begin
            load_state         <= LS_IDLE;
            byte_pos           <= 32'd0;
            pixel_offset       <= 32'd0;
            bmp_width          <= 32'd0;
            bmp_height_raw     <= 32'd0;
            bmp_bpp            <= 16'd0;
            bmp_compression    <= 32'd0;
            sig0               <= 8'd0;
            sig1               <= 8'd0;
            row_raw_bytes      <= 32'd0;
            row_stride_bytes   <= 32'd0;
            row_byte_pos       <= 32'd0;
            file_row           <= 10'd0;
            pixel_x            <= 11'd0;
            pixel_phase        <= 2'd0;
            pix_b              <= 8'd0;
            pix_g              <= 8'd0;
            format_ok          <= 1'b0;
            dummy_pending      <= 2'd0;
            dummy_addr         <= 21'd0;
            o_wr_valid         <= 1'b0;
            o_wr_addr          <= 21'd0;
            o_wr_data          <= 32'd0;
            o_wr_dm            <= 4'h0;
            o_load_done        <= 1'b0;
            o_load_error       <= 1'b0;
            o_image_width      <= 11'd0;
            o_image_height     <= 10'd0;
        end else begin
            // Pulse-style outputs.  These are always assigned, so TD does not
            // need to infer a clock-enable/self-hold network for them.
            o_wr_valid   <= 1'b0;
            o_load_done  <= 1'b0;
            o_load_error <= 1'b0;

            // New file always has highest priority and completely restarts the
            // parser.  This also makes recovery from a previous error explicit.
            if (i_file_start) begin
                load_state         <= LS_ACTIVE;
                byte_pos           <= 32'd0;
                pixel_offset       <= 32'd0;
                bmp_width          <= 32'd0;
                bmp_height_raw     <= 32'd0;
                bmp_bpp            <= 16'd0;
                bmp_compression    <= 32'd0;
                sig0               <= 8'd0;
                sig1               <= 8'd0;
                row_raw_bytes      <= 32'd0;
                row_stride_bytes   <= 32'd0;
                row_byte_pos       <= 32'd0;
                file_row           <= 10'd0;
                pixel_x            <= 11'd0;
                pixel_phase        <= 2'd0;
                pix_b              <= 8'd0;
                pix_g              <= 8'd0;
                format_ok          <= 1'b0;
                dummy_pending      <= 2'd0;
                dummy_addr         <= 21'd0;
                o_image_width      <= 11'd0;
                o_image_height     <= 10'd0;
            end else begin
                case (load_state)
                    LS_IDLE: begin
                        load_state <= LS_IDLE;
                    end

                    LS_ACTIVE: begin
                        // First abort conditions.  Neither error output nor busy
                        // feeds combinationally back into these decisions.
                        if (header_check_now && !header_valid_now) begin
                            load_state   <= LS_IDLE;
                            format_ok    <= 1'b0;
                            o_load_error <= 1'b1;
                        end else if (write_fail_now) begin
                            load_state   <= LS_IDLE;
                            o_load_error <= 1'b1;
                        end else begin
                            load_state <= i_file_done ? LS_DRAIN : LS_ACTIVE;

                            // Emit masked padding words only in cycles that do
                            // not carry a byte from the SD/FAT stream.
                            if ((dummy_pending != 2'd0) && i_wr_ready && !i_file_valid) begin
                                o_wr_valid    <= 1'b1;
                                o_wr_addr     <= dummy_addr;
                                o_wr_data     <= 32'd0;
                                o_wr_dm       <= 4'hF;
                                dummy_addr    <= dummy_addr + 21'd1;
                                dummy_pending <= dummy_pending - 2'd1;
                            end

                            if (i_file_valid) begin
                                case (byte_pos)
                                    32'd0:  sig0 <= i_file_data;
                                    32'd1:  sig1 <= i_file_data;
                                    32'd10: pixel_offset[7:0]     <= i_file_data;
                                    32'd11: pixel_offset[15:8]    <= i_file_data;
                                    32'd12: pixel_offset[23:16]   <= i_file_data;
                                    32'd13: pixel_offset[31:24]   <= i_file_data;
                                    32'd18: bmp_width[7:0]        <= i_file_data;
                                    32'd19: bmp_width[15:8]       <= i_file_data;
                                    32'd20: bmp_width[23:16]      <= i_file_data;
                                    32'd21: bmp_width[31:24]      <= i_file_data;
                                    32'd22: bmp_height_raw[7:0]   <= i_file_data;
                                    32'd23: bmp_height_raw[15:8]  <= i_file_data;
                                    32'd24: bmp_height_raw[23:16] <= i_file_data;
                                    32'd25: bmp_height_raw[31:24] <= i_file_data;
                                    32'd28: bmp_bpp[7:0]          <= i_file_data;
                                    32'd29: bmp_bpp[15:8]         <= i_file_data;
                                    32'd30: bmp_compression[7:0]  <= i_file_data;
                                    32'd31: bmp_compression[15:8] <= i_file_data;
                                    32'd32: bmp_compression[23:16]<= i_file_data;
                                    32'd33: bmp_compression[31:24]<= i_file_data;
                                    default: ;
                                endcase

                                if (header_check_now && header_valid_now) begin
                                    format_ok         <= 1'b1;
                                    row_raw_bytes     <= bmp_width + (bmp_width << 1);
                                    row_stride_bytes  <= ((bmp_width + (bmp_width << 1)) + 32'd3) & 32'hFFFFFFFC;
                                    o_image_width     <= bmp_width[10:0];
                                    o_image_height    <= height_abs32[9:0];
                                end

                                if (pixel_data_now) begin
                                    case (pixel_phase)
                                        2'd0: begin
                                            pix_b       <= i_file_data;
                                            pixel_phase <= 2'd1;
                                        end
                                        2'd1: begin
                                            pix_g       <= i_file_data;
                                            pixel_phase <= 2'd2;
                                        end
                                        default: begin
                                            o_wr_valid <= 1'b1;
                                            o_wr_addr  <= pixel_word_addr;
                                            o_wr_data  <= {8'h00,i_file_data,pix_g,pix_b};
                                            o_wr_dm    <= 4'h0;
                                            pixel_phase <= 2'd0;

                                            if (pixel_x == (bmp_width[10:0] - 11'd1)) begin
                                                pixel_x <= 11'd0;
                                                case (bmp_width[1:0])
                                                    2'd0: dummy_pending <= 2'd0;
                                                    2'd1: dummy_pending <= 2'd3;
                                                    2'd2: dummy_pending <= 2'd2;
                                                    default: dummy_pending <= 2'd1;
                                                endcase
                                                dummy_addr <= buffer_base +
                                                              ({11'd0,dest_y} << `QHMU_FB_STRIDE_SHIFT) +
                                                              bmp_width[20:0];
                                            end else begin
                                                pixel_x <= pixel_x + 11'd1;
                                            end
                                        end
                                    endcase
                                end

                                if (format_ok && (byte_pos >= pixel_offset) &&
                                    (file_row < height_abs32[9:0])) begin
                                    if (row_byte_pos == (row_stride_bytes - 32'd1)) begin
                                        row_byte_pos <= 32'd0;
                                        file_row     <= file_row + 10'd1;
                                        pixel_phase  <= 2'd0;
                                        pixel_x      <= 11'd0;
                                    end else begin
                                        row_byte_pos <= row_byte_pos + 32'd1;
                                    end
                                end

                                byte_pos <= byte_pos + 32'd1;
                            end
                        end
                    end

                    LS_DRAIN: begin
                        if (dummy_pending != 2'd0) begin
                            load_state <= LS_DRAIN;
                            if (i_wr_ready) begin
                                o_wr_valid    <= 1'b1;
                                o_wr_addr     <= dummy_addr;
                                o_wr_data     <= 32'd0;
                                o_wr_dm       <= 4'hF;
                                dummy_addr    <= dummy_addr + 21'd1;
                                dummy_pending <= dummy_pending - 2'd1;
                            end
                        end else begin
                            load_state <= LS_IDLE;
                            if (frame_complete_now)
                                o_load_done <= 1'b1;
                            else
                                o_load_error <= 1'b1;
                        end
                    end

                    default: begin
                        load_state   <= LS_IDLE;
                        o_load_error <= 1'b1;
                    end
                endcase
            end
        end
    end

    wire _unused_file_size;
    assign _unused_file_size = ^i_file_size;

endmodule
