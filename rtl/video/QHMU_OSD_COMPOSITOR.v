`include "../QHMU_DEFINES.vh"
`include "./QHMU_FONT24_STATUS.v"

// Chinese OSD renderer. Text glyphs are loaded from OSD_FONT.BIN on the SD card.
// The font RAM uses a synchronous read port; this module pipelines the RGB and
// AXI timing one pixel so font data and pixel data stay aligned.
module QHMU_OSD_COMPOSITOR(
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_frame_start,
    input  wire [10:0] i_x,
    input  wire [10:0] i_y,
    input  wire [23:0] i_pixel,
    input  wire        i_osd_enable,
    input  wire        i_visualizer_enable,
    input  wire        i_scroll_enable,
    input  wire [4:0]  i_image_index,
    input  wire [5:0]  i_file_count,
    input  wire [15:0] i_original_width,
    input  wire [15:0] i_original_height,
    input  wire [6:0]  i_brightness_pct,
    input  wire [6:0]  i_contrast_pct,
    input  wire [3:0]  i_transition_mode,
    input  wire        i_auto_mode,
    input  wire        i_audio_wait_mode,

    input  wire        i_font_load_clk,
    input  wire        i_font_load_rst,
    input  wire        i_font_load_start,
    input  wire [31:0] i_font_load_size,
    input  wire [7:0]  i_font_load_data,
    input  wire        i_font_load_valid,
    input  wire        i_font_load_done,
    output wire        o_font_loaded,
    output wire        o_font_error,

    input  wire        i_subtitle_hit,
    input  wire [23:0] i_subtitle_rgb,
    input  wire        i_visualizer_hit,
    input  wire [23:0] i_visualizer_rgb,
    output reg  [23:0] o_pixel
);
    reg [7:0] glyph;
    reg [4:0] font_row,font_col;
    wire [23:0] font_bits;
    wire font_loaded_ctrl;
    wire font_error_ctrl;

    QHMU_FONT24_STATUS u_font(
        .i_load_clk(i_font_load_clk), .i_load_rst(i_font_load_rst),
        .i_load_start(i_font_load_start), .i_load_size(i_font_load_size),
        .i_load_data(i_font_load_data), .i_load_valid(i_font_load_valid),
        .i_load_done(i_font_load_done),
        .o_loaded(font_loaded_ctrl), .o_error(font_error_ctrl),
        .i_pixel_clk(i_clk), .i_glyph(glyph), .i_row(font_row),
        .o_bits(font_bits)
    );

    assign o_font_loaded = font_loaded_ctrl;
    assign o_font_error  = font_error_ctrl;

    wire font_loaded_px;
    QHMU_SYNC_BUS #(.WIDTH(1)) u_font_loaded_sync(
        .i_clk(i_clk), .i_async_data(font_loaded_ctrl),
        .o_sync_data(font_loaded_px)
    );

    reg status_zone;
    reg [23:0] base_pixel_comb;

    function [7:0] digit_glyph;
        input [3:0] d;
        begin digit_glyph = "0" + d; end
    endfunction

    function [3:0] tens_0_99;
        input [7:0] v;
        begin
            if(v>=90)tens_0_99=9; else if(v>=80)tens_0_99=8;
            else if(v>=70)tens_0_99=7; else if(v>=60)tens_0_99=6;
            else if(v>=50)tens_0_99=5; else if(v>=40)tens_0_99=4;
            else if(v>=30)tens_0_99=3; else if(v>=20)tens_0_99=2;
            else if(v>=10)tens_0_99=1; else tens_0_99=0;
        end
    endfunction

    function [3:0] ones_0_99;
        input [7:0] v;
        begin
            if(v>=90)ones_0_99=v-90; else if(v>=80)ones_0_99=v-80;
            else if(v>=70)ones_0_99=v-70; else if(v>=60)ones_0_99=v-60;
            else if(v>=50)ones_0_99=v-50; else if(v>=40)ones_0_99=v-40;
            else if(v>=30)ones_0_99=v-30; else if(v>=20)ones_0_99=v-20;
            else if(v>=10)ones_0_99=v-10; else ones_0_99=v[3:0];
        end
    endfunction

    // Width/height are at most 1920x1080, so 11 input bits are sufficient.
    // The reduced 11-bit double-dabble converter replaces the old 16-bit
    // converter and is instantiated only for these two resolution values.
    function [15:0] bin11_to_bcd4;
        input [10:0] value;
        reg [26:0] sh;
        integer n;
        begin
            sh = 27'd0;
            sh[10:0] = value;
            for (n=0; n<11; n=n+1) begin
                if (sh[14:11] >= 5) sh[14:11] = sh[14:11] + 3;
                if (sh[18:15] >= 5) sh[18:15] = sh[18:15] + 3;
                if (sh[22:19] >= 5) sh[22:19] = sh[22:19] + 3;
                if (sh[26:23] >= 5) sh[26:23] = sh[26:23] + 3;
                sh = sh << 1;
            end
            bin11_to_bcd4 = sh[26:11];
        end
    endfunction

    wire [15:0] bcd_w = bin11_to_bcd4(i_original_width[10:0]);
    wire [15:0] bcd_h = bin11_to_bcd4(i_original_height[10:0]);

    function [3:0] hundreds_pct;
        input [6:0] v;
        begin hundreds_pct = (v >= 7'd100) ? 4'd1 : 4'd0; end
    endfunction

    function [3:0] tens_pct;
        input [6:0] v;
        begin
            if (v >= 7'd100) tens_pct = 4'd0;
            else tens_pct = tens_0_99({1'b0,v});
        end
    endfunction

    function [3:0] ones_pct;
        input [6:0] v;
        begin
            if (v >= 7'd100) ones_pct = 4'd0;
            else ones_pct = ones_0_99({1'b0,v});
        end
    endfunction

    // Glyph codes 0x80..0x9E follow the fixed Chinese order in OSD_FONT.BIN.
    // Line 1: 图片:01/32  分辨率:0640×0480  亮度:050  对比度:050 (32px cells)
    function [7:0] line1_char;
        input [5:0] p;
        reg [7:0] cur1,tot1;
        begin
            cur1 = (i_file_count == 6'd0) ? 8'd0 : ({3'd0,i_image_index} + 8'd1);
            tot1 = {2'd0,i_file_count};
            case(p)
                0:line1_char=8'h80; 1:line1_char=8'h81; 2:line1_char=":";
                3:line1_char=digit_glyph(tens_0_99(cur1));
                4:line1_char=digit_glyph(ones_0_99(cur1));
                5:line1_char="/";
                6:line1_char=digit_glyph(tens_0_99(tot1));
                7:line1_char=digit_glyph(ones_0_99(tot1));
                8:line1_char=" "; 9:line1_char=" ";
                10:line1_char=8'h82; 11:line1_char=8'h83; 12:line1_char=8'h84;
                13:line1_char=":";
                14:line1_char=digit_glyph(bcd_w[15:12]);
                15:line1_char=digit_glyph(bcd_w[11:8]);
                16:line1_char=digit_glyph(bcd_w[7:4]);
                17:line1_char=digit_glyph(bcd_w[3:0]);
                18:line1_char=8'h7F;
                19:line1_char=digit_glyph(bcd_h[15:12]);
                20:line1_char=digit_glyph(bcd_h[11:8]);
                21:line1_char=digit_glyph(bcd_h[7:4]);
                22:line1_char=digit_glyph(bcd_h[3:0]);
                23:line1_char=" "; 24:line1_char=" ";
                25:line1_char=8'h85; 26:line1_char=8'h86; 27:line1_char=":";
                28:line1_char=digit_glyph(hundreds_pct(i_brightness_pct));
                29:line1_char=digit_glyph(tens_pct(i_brightness_pct));
                30:line1_char=digit_glyph(ones_pct(i_brightness_pct));
                31:line1_char=" "; 32:line1_char=" ";
                33:line1_char=8'h87; 34:line1_char=8'h88; 35:line1_char=8'h86;
                36:line1_char=":";
                37:line1_char=digit_glyph(hundreds_pct(i_contrast_pct));
                38:line1_char=digit_glyph(tens_pct(i_contrast_pct));
                39:line1_char=digit_glyph(ones_pct(i_contrast_pct));
                default:line1_char=" ";
            endcase
        end
    endfunction

    function [7:0] transition_char;
        input [3:0] mode;
        input [2:0] p;
        begin
            transition_char = " ";
            case (mode)
                4'd0: case (p) // 淡入淡出
                    0: transition_char=8'h93;
                    1: transition_char=8'h94;
                    2: transition_char=8'h93;
                    3: transition_char=8'h95;
                    default: transition_char=" ";
                endcase
                4'd1: case (p) // 分割
                    0: transition_char=8'h82;
                    1: transition_char=8'h96;
                    default: transition_char=" ";
                endcase
                4'd2: case (p) // 直接切换
                    0: transition_char=8'h97;
                    1: transition_char=8'h98;
                    2: transition_char=8'h8B;
                    3: transition_char=8'h8C;
                    default: transition_char=" ";
                endcase
                4'd3: case (p) // 揭开
                    0: transition_char=8'h99;
                    1: transition_char=8'h9A;
                    default: transition_char=" ";
                endcase
                4'd4: case (p) // 推入
                    0: transition_char=8'h9B;
                    1: transition_char=8'h94;
                    default: transition_char=" ";
                endcase
                default: transition_char=" ";
            endcase
        end
    endfunction

    // Line 2: 格式:BMP  切换模式:...  播放模式:手动/自动[定时/变时]
    // In auto mode, append "定时" for AUD timer playback or "变时" for
    // paired MUS playback that waits for the final PCM sample to finish.
    // The Latin BMP token uses the Times-compatible B/M/P glyph slots.
    // Each glyph uses a 32-pixel horizontal cell; the 24x24 bitmap is centered with 4px side margins.
    function [7:0] line2_char;
        input [5:0] p;
        begin
            case(p)
                0:line2_char=8'h89; 1:line2_char=8'h8A; 2:line2_char=":";
                3:line2_char=8'h42; 4:line2_char=8'h4D; 5:line2_char=8'h50;
                6:line2_char=" ";
                7:line2_char=8'h8B; 8:line2_char=8'h8C;
                9:line2_char=8'h8D; 10:line2_char=8'h8A;
                11:line2_char=":";
                12:line2_char=transition_char(i_transition_mode,3'd0);
                13:line2_char=transition_char(i_transition_mode,3'd1);
                14:line2_char=transition_char(i_transition_mode,3'd2);
                15:line2_char=transition_char(i_transition_mode,3'd3);
                16:line2_char=" ";
                17:line2_char=8'h8E; 18:line2_char=8'h8F;
                19:line2_char=8'h8D; 20:line2_char=8'h8A;
                21:line2_char=":";
                22:line2_char=i_auto_mode ? 8'h92 : 8'h90;
                23:line2_char=8'h91;
                24:line2_char=i_auto_mode ?
                              (i_audio_wait_mode ? 8'h9E : 8'h9C) : " ";
                25:line2_char=i_auto_mode ? 8'h9D : " ";
                default:line2_char=" ";
            endcase
        end
    endfunction

    reg [5:0] cpos;
    reg [4:0] local_x;

    always @(*) begin
        glyph = " ";
        font_row = 5'd0;
        font_col = 5'd0;
        cpos = i_x >> 5;
        local_x = i_x[4:0];
        status_zone = 1'b0;
        base_pixel_comb = i_pixel;

        if (i_osd_enable) begin
            if (i_y < 11'd80)
                base_pixel_comb = 24'h102448;

            // 24x24 glyphs at native pixel size. Each glyph is centered in a
            // 32x32 cell: 4px left/right margin, 4px top/bottom margin.
            // Forty cells occupy 1280px; this power-of-two cell geometry keeps
            // the per-pixel path shallow and avoids a divider in the OSD path.
            if ((i_y >= 11'd4) && (i_y < 11'd36)) begin
                if (cpos < 6'd40)
                    glyph = line1_char(cpos);
                if ((i_y >= 11'd8) && (i_y < 11'd32) &&
                    (local_x >= 5'd4) && (local_x < 5'd28) &&
                    (cpos < 6'd40)) begin
                    font_row = i_y - 11'd8;
                    font_col = local_x - 5'd4;
                    status_zone = 1'b1;
                end
            end else if ((i_y >= 11'd42) && (i_y < 11'd74)) begin
                if (cpos < 6'd26)
                    glyph = line2_char(cpos);
                if ((i_y >= 11'd46) && (i_y < 11'd70) &&
                    (local_x >= 5'd4) && (local_x < 5'd28) &&
                    (cpos < 6'd26)) begin
                    font_row = i_y - 11'd46;
                    font_col = local_x - 5'd4;
                    status_zone = 1'b1;
                end
            end
        end
    end

    reg [23:0] base_pixel_d;
    reg [4:0] font_col_d;
    reg status_zone_d, osd_enable_d, font_loaded_d;
    reg subtitle_hit_d, visualizer_hit_d;
    reg [23:0] subtitle_rgb_d, visualizer_rgb_d;

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            base_pixel_d <= 24'd0;
            font_col_d <= 5'd0;
            status_zone_d <= 1'b0;
            osd_enable_d <= 1'b0;
            font_loaded_d <= 1'b0;
            subtitle_hit_d <= 1'b0;
            visualizer_hit_d <= 1'b0;
            subtitle_rgb_d <= 24'd0;
            visualizer_rgb_d <= 24'd0;
        end else begin
            base_pixel_d <= base_pixel_comb;
            font_col_d <= font_col;
            status_zone_d <= status_zone;
            osd_enable_d <= i_osd_enable;
            font_loaded_d <= font_loaded_px;
            subtitle_hit_d <= i_scroll_enable && i_subtitle_hit;
            visualizer_hit_d <= i_visualizer_enable && i_visualizer_hit;
            subtitle_rgb_d <= i_subtitle_rgb;
            visualizer_rgb_d <= i_visualizer_rgb;
        end
    end

    always @(*) begin
        o_pixel = base_pixel_d;
        if (osd_enable_d && font_loaded_d && status_zone_d &&
            font_bits[23-font_col_d])
            o_pixel = 24'hFFFFFF;

        if (subtitle_hit_d)
            o_pixel = subtitle_rgb_d;
        if (visualizer_hit_d)
            o_pixel = visualizer_rgb_d;
    end

    wire _unused = i_frame_start;
endmodule
