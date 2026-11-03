// QHMU_FONT24_STATUS
// Dual-clock 24x24 font RAM loaded from OSD_FONT.BIN.
// OSF2 = 4-byte header + 48 glyphs * 24 rows * 3 bytes = 3460 bytes.
// Each row is 24 bits, MSB first. Slot order: space, '/', 0..9, ':', B, M, P,
// multiplication sign, 28 existing Chinese glyphs (0x80..0x9B), then
// 定(0x9C), 时(0x9D), 变(0x9E) for the automatic playback-policy indicator.
module QHMU_FONT24_STATUS(
    input  wire        i_load_clk,
    input  wire        i_load_rst,
    input  wire        i_load_start,
    input  wire [31:0] i_load_size,
    input  wire [7:0]  i_load_data,
    input  wire        i_load_valid,
    input  wire        i_load_done,
    output reg         o_loaded,
    output reg         o_error,

    input  wire        i_pixel_clk,
    input  wire [7:0]  i_glyph,
    input  wire [4:0]  i_row,
    output reg  [23:0] o_bits
);
    localparam [31:0] FONT_FILE_BYTES = 32'd3460;
    localparam [15:0] FONT_WORDS = 16'd1152;

    // 48 glyphs * 24 rows. The memory is dual-clock: control-domain write,
    // pixel-domain synchronous read. All 1152 words are used.
    reg [23:0] font_mem [0:1151];

    reg [15:0] byte_count;
    reg [1:0]  header_index;
    reg        header_ok;
    reg        size_ok;
    reg [1:0]  byte_group;
    reg [7:0]  byte0;
    reg [7:0]  byte1;
    reg [10:0] write_addr;
    reg [7:0]  expected_header;
    reg        ram_wr_en;
    reg [10:0] ram_wr_addr;
    reg [23:0] ram_wr_data;
    reg        finish_pending;

    function [5:0] glyph_slot;
        input [7:0] g;
        begin
            glyph_slot = 6'd0;
            case (g)
                8'h20: glyph_slot=6'd0;
                8'h2F: glyph_slot=6'd1;
                8'h30: glyph_slot=6'd2;
                8'h31: glyph_slot=6'd3;
                8'h32: glyph_slot=6'd4;
                8'h33: glyph_slot=6'd5;
                8'h34: glyph_slot=6'd6;
                8'h35: glyph_slot=6'd7;
                8'h36: glyph_slot=6'd8;
                8'h37: glyph_slot=6'd9;
                8'h38: glyph_slot=6'd10;
                8'h39: glyph_slot=6'd11;
                8'h3A: glyph_slot=6'd12;
                8'h42: glyph_slot=6'd13; // B
                8'h4D: glyph_slot=6'd14; // M
                8'h50: glyph_slot=6'd15; // P
                8'h7F: glyph_slot=6'd16; // multiplication sign
                default: begin
                    if ((g >= 8'h80) && (g <= 8'h9B))
                        glyph_slot = 6'd17 + (g - 8'h80);
                    else if (g == 8'h9C)
                        glyph_slot = 6'd45; // 定
                    else if (g == 8'h9D)
                        glyph_slot = 6'd46; // 时
                    else if (g == 8'h9E)
                        glyph_slot = 6'd47; // 变
                    else
                        glyph_slot = 6'd0;
                end
            endcase
        end
    endfunction

    always @* begin
        case (header_index)
            2'd0: expected_header = 8'h4F; // O
            2'd1: expected_header = 8'h53; // S
            2'd2: expected_header = 8'h46; // F
            default: expected_header = 8'h32; // 2
        endcase
    end

    always @(posedge i_load_clk or posedge i_load_rst) begin
        if (i_load_rst) begin
            byte_count   <= 16'd0;
            header_index <= 2'd0;
            header_ok    <= 1'b1;
            size_ok      <= 1'b0;
            byte_group   <= 2'd0;
            byte0        <= 8'd0;
            byte1        <= 8'd0;
            write_addr   <= 11'd0;
            ram_wr_en    <= 1'b0;
            ram_wr_addr  <= 11'd0;
            ram_wr_data  <= 24'd0;
            finish_pending <= 1'b0;
            o_loaded     <= 1'b0;
            o_error      <= 1'b0;
        end else begin
            ram_wr_en <= 1'b0;

            if (i_load_start) begin
                byte_count     <= 16'd0;
                header_index   <= 2'd0;
                header_ok      <= 1'b1;
                size_ok        <= (i_load_size == FONT_FILE_BYTES);
                byte_group     <= 2'd0;
                byte0          <= 8'd0;
                byte1          <= 8'd0;
                write_addr     <= 11'd0;
                ram_wr_en      <= 1'b0;
                finish_pending <= 1'b0;
                o_loaded       <= 1'b0;
                o_error        <= (i_load_size != FONT_FILE_BYTES);
            end

            if (i_load_valid && size_ok && !o_loaded) begin
                byte_count <= byte_count + 1'b1;
                if (byte_count < 16'd4) begin
                    if (i_load_data != expected_header)
                        header_ok <= 1'b0;
                    header_index <= header_index + 1'b1;
                end else if (byte_count < FONT_FILE_BYTES) begin
                    case (byte_group)
                        2'd0: begin
                            byte0 <= i_load_data;
                            byte_group <= 2'd1;
                        end
                        2'd1: begin
                            byte1 <= i_load_data;
                            byte_group <= 2'd2;
                        end
                        default: begin
                            ram_wr_en   <= 1'b1;
                            ram_wr_addr <= write_addr;
                            ram_wr_data <= {byte0, byte1, i_load_data};
                            write_addr  <= write_addr + 1'b1;
                            byte_group  <= 2'd0;
                        end
                    endcase
                end
            end

            // Delay validation until the final registered RAM write has had
            // a clock edge to commit into font_mem.
            if (i_load_done)
                finish_pending <= 1'b1;

            if (finish_pending) begin
                finish_pending <= 1'b0;
                if (size_ok && header_ok &&
                    (byte_count == FONT_FILE_BYTES) &&
                    (byte_group == 2'd0) &&
                    (write_addr == FONT_WORDS)) begin
                    o_loaded <= 1'b1;
                    o_error  <= 1'b0;
                end else begin
                    o_loaded <= 1'b0;
                    o_error  <= 1'b1;
                end
            end
        end
    end

    // Keep RAM write in a separate clocked process for embedded-RAM inference.
    always @(posedge i_load_clk) begin
        if (ram_wr_en)
            font_mem[ram_wr_addr] <= ram_wr_data;
    end

    wire [10:0] read_addr =
        (glyph_slot(i_glyph) * 11'd24) + {6'd0, i_row};

    always @(posedge i_pixel_clk)
        o_bits <= font_mem[read_addr];
endmodule
