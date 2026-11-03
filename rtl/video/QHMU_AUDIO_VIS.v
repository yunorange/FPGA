// ============================================================================
// QHMU_AUDIO_VIS - compact 3-band PCM visualizer.
// Uses explicitly sized signed datapaths (no 32-bit integer arithmetic).
// Sixteen bars are drawn across 1920 pixels; optional enable remains on SW2.
// ============================================================================
module QHMU_AUDIO_VIS(
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_frame_start,
    input  wire        i_audio_valid,
    input  wire [23:0] i_left,
    input  wire [23:0] i_right,
    input  wire [10:0] i_x,
    input  wire [10:0] i_y,
    input  wire        i_enable,
    output reg         o_hit,
    output reg  [23:0] o_rgb
);
    reg signed [17:0] low_lp;
    reg signed [17:0] mid_lp;
    reg [15:0] low_peak, mid_peak, high_peak;
    reg [3:0] low_level, mid_level, high_level;

    wire signed [16:0] mono_sum = $signed(i_left[23:8]) + $signed(i_right[23:8]);
    wire signed [15:0] mono_sample = mono_sum >>> 1;

    wire signed [18:0] low_delta = $signed({mono_sample[15],mono_sample}) -
                                   $signed({low_lp[17],low_lp});
    wire signed [18:0] mid_delta = $signed({mono_sample[15],mono_sample}) -
                                   $signed({mid_lp[17],mid_lp});
    wire signed [18:0] low_next_ext = $signed({low_lp[17],low_lp}) + (low_delta >>> 5);
    wire signed [18:0] mid_next_ext = $signed({mid_lp[17],mid_lp}) + (mid_delta >>> 2);
    wire signed [17:0] low_next = low_next_ext[17:0];
    wire signed [17:0] mid_next = mid_next_ext[17:0];

    wire signed [18:0] mid_band = $signed({mid_next[17],mid_next}) -
                                  $signed({low_next[17],low_next});
    wire signed [18:0] high_band = $signed({mono_sample[15],mono_sample}) -
                                   $signed({mid_next[17],mid_next});

    wire [17:0] low_abs_ext = low_next[17] ? (~low_next + 18'd1) : low_next;
    wire [18:0] mid_abs_ext = mid_band[18] ? (~mid_band + 19'd1) : mid_band;
    wire [18:0] high_abs_ext = high_band[18] ? (~high_band + 19'd1) : high_band;
    wire [15:0] low_abs = (low_abs_ext > 18'd65535) ? 16'hFFFF : low_abs_ext[15:0];
    wire [15:0] mid_abs = (mid_abs_ext > 19'd65535) ? 16'hFFFF : mid_abs_ext[15:0];
    wire [15:0] high_abs = (high_abs_ext > 19'd65535) ? 16'hFFFF : high_abs_ext[15:0];

    function [3:0] amp_to_level;
        input [15:0] amp;
        begin
            if      (amp < 16'd256)   amp_to_level=4'd0;
            else if (amp < 16'd512)   amp_to_level=4'd1;
            else if (amp < 16'd1024)  amp_to_level=4'd2;
            else if (amp < 16'd2048)  amp_to_level=4'd3;
            else if (amp < 16'd4096)  amp_to_level=4'd4;
            else if (amp < 16'd6144)  amp_to_level=4'd5;
            else if (amp < 16'd8192)  amp_to_level=4'd6;
            else if (amp < 16'd12288) amp_to_level=4'd7;
            else if (amp < 16'd16384) amp_to_level=4'd8;
            else if (amp < 16'd20480) amp_to_level=4'd9;
            else if (amp < 16'd24576) amp_to_level=4'd10;
            else if (amp < 16'd28672) amp_to_level=4'd11;
            else                      amp_to_level=4'd12;
        end
    endfunction

    wire [3:0] low_target=amp_to_level(low_peak);
    wire [3:0] mid_target=amp_to_level(mid_peak);
    wire [3:0] high_target=amp_to_level(high_peak);

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            low_lp<=18'sd0; mid_lp<=18'sd0;
            low_peak<=16'd0; mid_peak<=16'd0; high_peak<=16'd0;
            low_level<=4'd0; mid_level<=4'd0; high_level<=4'd0;
        end else begin
            if (i_audio_valid) begin
                low_lp <= low_next;
                mid_lp <= mid_next;
                if (low_abs > low_peak) low_peak <= low_abs;
                if (mid_abs > mid_peak) mid_peak <= mid_abs;
                if (high_abs > high_peak) high_peak <= high_abs;
            end
            if (i_frame_start) begin
                if (low_target >= low_level) low_level <= low_target;
                else if (low_level != 0) low_level <= low_level - 1'b1;
                if (mid_target >= mid_level) mid_level <= mid_target;
                else if (mid_level != 0) mid_level <= mid_level - 1'b1;
                if (high_target >= high_level) high_level <= high_target;
                else if (high_level != 0) high_level <= high_level - 1'b1;
                low_peak<=16'd0; mid_peak<=16'd0; high_peak<=16'd0;
            end
        end
    end

    function [3:0] bar_height;
        input [3:0] idx;
        input [3:0] lo;
        input [3:0] mi;
        input [3:0] hi;
        reg [4:0] temp;
        begin
            temp=0;
            case(idx)
                4'd0:temp=(lo>4'd2)?({1'b0,lo}-5'd2):5'd0;
                4'd1:temp=(lo>4'd1)?({1'b0,lo}-5'd1):5'd0;
                4'd2:temp={1'b0,lo};
                4'd3:temp={1'b0,lo}+5'd1;
                4'd4:temp=({1'b0,lo}+{1'b0,mi})>>1;
                4'd5:temp=(mi>4'd1)?({1'b0,mi}-5'd1):5'd0;
                4'd6:temp={1'b0,mi};
                4'd7:temp={1'b0,mi}+5'd1;
                4'd8:temp={1'b0,mi};
                4'd9:temp=({1'b0,mi}+{1'b0,hi})>>1;
                4'd10:temp=(hi>4'd1)?({1'b0,hi}-5'd1):5'd0;
                4'd11:temp={1'b0,hi};
                4'd12:temp={1'b0,hi}+5'd1;
                4'd13:temp={1'b0,hi};
                4'd14:temp=(hi>4'd1)?({1'b0,hi}-5'd1):5'd0;
                default:temp=(hi>4'd2)?({1'b0,hi}-5'd2):5'd0;
            endcase
            bar_height=(temp>5'd12)?4'd12:temp[3:0];
        end
    endfunction

    function [23:0] bar_color;
        input [3:0] idx;
        begin
            case(idx)
                4'd0:bar_color=24'hFF3048; 4'd1:bar_color=24'hFF6030;
                4'd2:bar_color=24'hFF9828; 4'd3:bar_color=24'hFFD020;
                4'd4:bar_color=24'hB8E828; 4'd5:bar_color=24'h58E848;
                4'd6:bar_color=24'h28E880; 4'd7:bar_color=24'h20E8B8;
                4'd8:bar_color=24'h20D8E8; 4'd9:bar_color=24'h28A8FF;
                4'd10:bar_color=24'h4878FF; 4'd11:bar_color=24'h7048FF;
                4'd12:bar_color=24'hA840F0; 4'd13:bar_color=24'hD838E8;
                4'd14:bar_color=24'hF038A8; default:bar_color=24'hFF4068;
            endcase
        end
    endfunction

    reg [3:0] bar_idx, bar_blocks, block_idx, block_phase;
    reg [10:0] local_x, dy;
    always @* begin
        o_hit=1'b0; o_rgb=24'h000000;
        bar_idx=4'd0; bar_blocks=4'd0; local_x=11'd0; dy=11'd0;
        block_idx=4'd0; block_phase=4'd0;
        if (i_enable && (i_x < `QHMU_OUT_W)) begin
            if ((low_level==0)&&(mid_level==0)&&(high_level==0)&&
                (i_y>=11'd968)&&(i_y<=11'd972)) begin
                o_hit=1'b1; o_rgb=24'h607890;
            end
            if ((i_y>=11'd768)&&(i_y<11'd960)) begin
                bar_idx=i_x/11'd120;
                local_x=i_x-({7'd0,bar_idx}*11'd120);
                dy=11'd959-i_y;
                block_idx=dy>>4;
                block_phase=dy[3:0];
                bar_blocks=bar_height(bar_idx,low_level,mid_level,high_level);
                if ((local_x<11'd88)&&(block_phase<4'd12)&&(block_idx<bar_blocks)) begin
                    o_hit=1'b1; o_rgb=bar_color(bar_idx);
                end
            end
        end
    end
endmodule
