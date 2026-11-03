`include "../QHMU_DEFINES.vh"
`include "QHMU_ASPECT_FIT.v"

// ============================================================================
// QHMU_VIDEO_STREAMER
// Variable-resolution BMP framebuffer -> 1920x1080 HDMI pixel stream.
//
// Key behavior:
//   * source image dimensions may change for every BMP;
//   * aspect ratio is preserved;
//   * image is centered;
//   * unused area is pure black (pillarbox / letterbox);
//   * nearest-neighbor DDA scaling; no per-pixel divider;
//   * A/B frame buffers may have DIFFERENT aspect ratios during transitions.
//
// Source frame-buffer format is RGBX8888 with fixed 1024-word row stride.
// ============================================================================
module QHMU_VIDEO_STREAMER(
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_display_valid,
    input  wire        i_active_buffer,
    input  wire        i_secondary_enable,
    input  wire [1:0]  i_buffer_valid,
    input  wire [10:0] i_buf0_width,
    input  wire [9:0]  i_buf0_height,
    input  wire [10:0] i_buf1_width,
    input  wire [9:0]  i_buf1_height,

    output reg         o_line_req_valid,
    output reg  [44:0] o_line_req_data,
    input  wire        i_line_req_ready,
    input  wire        i_line_done_toggle,
    input  wire        i_line_done_bank,

    output reg  [9:0]  o_line_rd_addr_a,
    output reg  [9:0]  o_line_rd_addr_b,
    input  wire [23:0] i_line_a_bank0,
    input  wire [23:0] i_line_a_bank1,
    input  wire [23:0] i_line_b_bank0,
    input  wire [23:0] i_line_b_bank1,

    output reg         o_axis_user,
    output reg         o_axis_valid,
    output reg         o_axis_last,
    output reg  [23:0] o_pix_a,
    output reg  [23:0] o_pix_b,
    output reg         o_content_a,
    output reg         o_content_b,
    output reg  [10:0] o_x,
    output reg  [10:0] o_y,
    output wire        o_frame_start,
    output wire        o_frame_end,
    output reg         o_underrun
);
    reg [11:0] hcnt;
    reg [10:0] vcnt;

    // ------------------------------------------------------------------------
    // Aspect-fit cache for each physical frame buffer.
    // ------------------------------------------------------------------------
    wire fit0_valid, fit1_valid;
    wire [10:0] fit0_w, fit0_h, fit0_x, fit0_y;
    wire [10:0] fit1_w, fit1_h, fit1_x, fit1_y;

    QHMU_ASPECT_FIT u_fit0(
        .i_clk(i_clk), .i_rst(i_rst),
        .i_src_w(i_buf0_width), .i_src_h(i_buf0_height),
        .o_valid(fit0_valid),
        .o_scaled_w(fit0_w), .o_scaled_h(fit0_h),
        .o_offset_x(fit0_x), .o_offset_y(fit0_y)
    );

    QHMU_ASPECT_FIT u_fit1(
        .i_clk(i_clk), .i_rst(i_rst),
        .i_src_w(i_buf1_width), .i_src_h(i_buf1_height),
        .o_valid(fit1_valid),
        .o_scaled_w(fit1_w), .o_scaled_h(fit1_h),
        .o_offset_x(fit1_x), .o_offset_y(fit1_y)
    );

    wire [10:0] width_a =
        i_active_buffer ? i_buf1_width : i_buf0_width;
    wire [9:0] height_a =
        i_active_buffer ? i_buf1_height : i_buf0_height;
    wire [10:0] width_b =
        i_active_buffer ? i_buf0_width : i_buf1_width;
    wire [9:0] height_b =
        i_active_buffer ? i_buf0_height : i_buf1_height;

    wire valid_a =
        i_active_buffer ? i_buffer_valid[1] : i_buffer_valid[0];
    wire valid_b =
        i_active_buffer ? i_buffer_valid[0] : i_buffer_valid[1];

    wire fit_valid_a = i_active_buffer ? fit1_valid : fit0_valid;
    wire fit_valid_b = i_active_buffer ? fit0_valid : fit1_valid;

    wire [10:0] fit_w_a = i_active_buffer ? fit1_w : fit0_w;
    wire [10:0] fit_h_a = i_active_buffer ? fit1_h : fit0_h;
    wire [10:0] fit_x_a = i_active_buffer ? fit1_x : fit0_x;
    wire [10:0] fit_y_a = i_active_buffer ? fit1_y : fit0_y;

    wire [10:0] fit_w_b = i_active_buffer ? fit0_w : fit1_w;
    wire [10:0] fit_h_b = i_active_buffer ? fit0_h : fit1_h;
    wire [10:0] fit_x_b = i_active_buffer ? fit0_x : fit1_x;
    wire [10:0] fit_y_b = i_active_buffer ? fit0_y : fit1_y;

    wire [11:0] fit_x_end_a = {1'b0,fit_x_a}+{1'b0,fit_w_a};
    wire [11:0] fit_x_end_b = {1'b0,fit_x_b}+{1'b0,fit_w_b};
    wire [11:0] fit_y_end_a = {1'b0,fit_y_a}+{1'b0,fit_h_a};
    wire [11:0] fit_y_end_b = {1'b0,fit_y_b}+{1'b0,fit_h_b};

    wire active_video =
        (vcnt >= `QHMU_VBLANK) &&
        (vcnt <  `QHMU_VBLANK+`QHMU_OUT_H) &&
        (hcnt >= `QHMU_HBLANK) &&
        (hcnt <  `QHMU_HBLANK+`QHMU_OUT_W);

    wire [10:0] x_now = hcnt - `QHMU_HBLANK;
    wire [10:0] y_now = vcnt - `QHMU_VBLANK;

    assign o_frame_start = (hcnt==12'd0) && (vcnt==11'd0);
    assign o_frame_end =
        (hcnt==`QHMU_HTOTAL-1) && (vcnt==`QHMU_VTOTAL-1);

    wire inside_a_y =
        i_display_valid && valid_a && fit_valid_a &&
        ({1'b0,y_now} >= {1'b0,fit_y_a}) &&
        ({1'b0,y_now} < fit_y_end_a);

    wire inside_b_y =
        i_display_valid && valid_b && fit_valid_b &&
        ({1'b0,y_now} >= {1'b0,fit_y_b}) &&
        ({1'b0,y_now} < fit_y_end_b);

    wire inside_a_xy =
        inside_a_y &&
        ({1'b0,x_now} >= {1'b0,fit_x_a}) &&
        ({1'b0,x_now} < fit_x_end_a);

    wire inside_b_xy =
        inside_b_y &&
        ({1'b0,x_now} >= {1'b0,fit_x_b}) &&
        ({1'b0,x_now} < fit_x_end_b);

    // ------------------------------------------------------------------------
    // Line-completion toggle synchronization.
    // ------------------------------------------------------------------------
    reg done_ff1, done_ff2, done_ff3;
    reg done_bank_ff1, done_bank_ff2;
    reg [1:0] line_ready;

    always @(posedge i_clk) begin
        if (i_rst) begin
            done_ff1<=1'b0; done_ff2<=1'b0; done_ff3<=1'b0;
            done_bank_ff1<=1'b0; done_bank_ff2<=1'b0;
            line_ready<=2'b00;
        end else begin
            done_ff1<=i_line_done_toggle;
            done_ff2<=done_ff1;
            done_ff3<=done_ff2;
            done_bank_ff1<=i_line_done_bank;
            done_bank_ff2<=done_bank_ff1;

            if (done_ff2 ^ done_ff3)
                line_ready[done_bank_ff2] <= 1'b1;

            if (o_line_req_valid && i_line_req_ready)
                line_ready[o_line_req_data[44]] <= 1'b0;
        end
    end

    // ------------------------------------------------------------------------
    // 1920x1080 source timing.
    // ------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (i_rst) begin
            hcnt<=12'd0;
            vcnt<=11'd0;
        end else if (hcnt==`QHMU_HTOTAL-1) begin
            hcnt<=12'd0;
            if (vcnt==`QHMU_VTOTAL-1)
                vcnt<=11'd0;
            else
                vcnt<=vcnt+1'b1;
        end else begin
            hcnt<=hcnt+1'b1;
        end
    end

    // ------------------------------------------------------------------------
    // Vertical DDA.  State advances only while the relevant image rectangle is
    // active, so top/bottom black bars do not consume source rows.
    // ------------------------------------------------------------------------
    reg [9:0]  y_src_a, y_src_b;
    reg [10:0] y_phase_a, y_phase_b;

    wire [11:0] y_sum_a =
        {1'b0,y_phase_a}+{2'b00,height_a};
    wire [11:0] y_sum_b =
        {1'b0,y_phase_b}+{2'b00,height_b};

    // The source framebuffer is limited to <=1024x1023 while the output is
    // 1920x1080, so normally the DDA advances by zero or one source sample.
    // The three-step logic is retained for robustness.
    wire [12:0] fit_h_a_1 = {2'b00,fit_h_a};
    wire [12:0] fit_h_a_2 = fit_h_a_1 << 1;
    wire [12:0] fit_h_a_3 = fit_h_a_2 + fit_h_a_1;
    wire [12:0] fit_h_b_1 = {2'b00,fit_h_b};
    wire [12:0] fit_h_b_2 = fit_h_b_1 << 1;
    wire [12:0] fit_h_b_3 = fit_h_b_2 + fit_h_b_1;
    wire [12:0] y_sum_a_ext = {1'b0,y_sum_a};
    wire [12:0] y_sum_b_ext = {1'b0,y_sum_b};
    wire [1:0] y_step_a = (fit_h_a!=0 && y_sum_a_ext>=fit_h_a_3) ? 2'd3 :
                          (fit_h_a!=0 && y_sum_a_ext>=fit_h_a_2) ? 2'd2 :
                          (fit_h_a!=0 && y_sum_a_ext>=fit_h_a_1) ? 2'd1 : 2'd0;
    wire [1:0] y_step_b = (fit_h_b!=0 && y_sum_b_ext>=fit_h_b_3) ? 2'd3 :
                          (fit_h_b!=0 && y_sum_b_ext>=fit_h_b_2) ? 2'd2 :
                          (fit_h_b!=0 && y_sum_b_ext>=fit_h_b_1) ? 2'd1 : 2'd0;
    wire [9:0] y_src_a_adv = y_src_a + y_step_a;
    wire [9:0] y_src_b_adv = y_src_b + y_step_b;
    wire [12:0] y_rem_a = y_sum_a_ext -
                           ((y_step_a==3)?fit_h_a_3:(y_step_a==2)?fit_h_a_2:
                            (y_step_a==1)?fit_h_a_1:13'd0);
    wire [12:0] y_rem_b = y_sum_b_ext -
                           ((y_step_b==3)?fit_h_b_3:(y_step_b==2)?fit_h_b_2:
                            (y_step_b==1)?fit_h_b_1:13'd0);
    wire [10:0] y_phase_a_adv = y_rem_a[10:0];
    wire [10:0] y_phase_b_adv = y_rem_b[10:0];

    always @(posedge i_clk) begin
        if (i_rst || o_frame_start) begin
            y_src_a<=10'd0;
            y_src_b<=10'd0;
            y_phase_a<=11'd0;
            y_phase_b<=11'd0;
        end else if ((hcnt==`QHMU_HBLANK) &&
                     (vcnt>=`QHMU_VBLANK) &&
                     (vcnt<`QHMU_VBLANK+`QHMU_OUT_H)) begin
            if (inside_a_y) begin
                y_src_a<=y_src_a_adv;
                y_phase_a<=y_phase_a_adv;
            end
            if (inside_b_y) begin
                y_src_b<=y_src_b_adv;
                y_phase_b<=y_phase_b_adv;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Request the line needed by the NEXT output row.  When one side of a
    // transition is in a black bar, its requested width is set to zero; the
    // APUG011 arbiter can therefore skip that source line entirely.
    // ------------------------------------------------------------------------
    reg req_pending;
    reg [44:0] req_hold;

    wire [10:0] next_y = y_now + 1'b1;

    wire next_inside_a_y =
        (y_now < `QHMU_OUT_H-1) &&
        i_display_valid && valid_a && fit_valid_a &&
        ({1'b0,next_y} >= {1'b0,fit_y_a}) &&
        ({1'b0,next_y} < fit_y_end_a);

    wire next_inside_b_y =
        (y_now < `QHMU_OUT_H-1) &&
        i_display_valid && valid_b && fit_valid_b &&
        ({1'b0,next_y} >= {1'b0,fit_y_b}) &&
        ({1'b0,next_y} < fit_y_end_b);

    wire [9:0] next_src_y_a =
        inside_a_y ? y_src_a_adv : 10'd0;
    wire [9:0] next_src_y_b =
        inside_b_y ? y_src_b_adv : 10'd0;

    wire first_a_visible =
        i_display_valid && valid_a && fit_valid_a &&
        (fit_y_a == 11'd0);
    wire first_b_visible =
        i_display_valid && valid_b && fit_valid_b &&
        i_secondary_enable && (fit_y_b == 11'd0);

    always @(posedge i_clk) begin
        if (i_rst) begin
            req_pending<=1'b0;
            req_hold<=45'd0;
            o_line_req_valid<=1'b0;
            o_line_req_data<=45'd0;
        end else begin
            o_line_req_valid<=1'b0;

            if (req_pending && i_line_req_ready) begin
                o_line_req_data<=req_hold;
                o_line_req_valid<=1'b1;
                req_pending<=1'b0;
            end

            // Preload output row 0 during vertical blank when needed.
            if (!req_pending && (vcnt==11'd0) && (hcnt==12'd16) &&
                (first_a_visible || first_b_visible)) begin
                req_hold <= {
                    1'b0,
                    i_active_buffer,
                    first_b_visible,
                    10'd0,
                    first_a_visible ? width_a : 11'd0,
                    10'd0,
                    first_b_visible ? width_b : 11'd0
                };
                req_pending<=1'b1;
            end
            // During each output line, fetch data for the next line.
            else if (!req_pending &&
                     (hcnt==`QHMU_HBLANK) &&
                     (vcnt>=`QHMU_VBLANK) &&
                     (vcnt<`QHMU_VBLANK+`QHMU_OUT_H-1) &&
                     (next_inside_a_y ||
                      (i_secondary_enable && next_inside_b_y))) begin
                req_hold <= {
                    next_y[0],
                    i_active_buffer,
                    (i_secondary_enable && next_inside_b_y),
                    next_src_y_a,
                    next_inside_a_y ? width_a : 11'd0,
                    next_src_y_b,
                    (i_secondary_enable && next_inside_b_y) ?
                        width_b : 11'd0
                };
                req_pending<=1'b1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Horizontal DDA.  Two clocks of look-ahead are used for the synchronous
    // dual-port line RAM plus the registered output pixel stage.
    // ------------------------------------------------------------------------
    reg [9:0]  x_src_a, x_src_b;
    reg [10:0] x_phase_a, x_phase_b;

    wire [11:0] x_sum_a =
        {1'b0,x_phase_a}+{1'b0,width_a};
    wire [11:0] x_sum_b =
        {1'b0,x_phase_b}+{1'b0,width_b};

    wire [12:0] fit_w_a_1 = {2'b00,fit_w_a};
    wire [12:0] fit_w_a_2 = fit_w_a_1 << 1;
    wire [12:0] fit_w_a_3 = fit_w_a_2 + fit_w_a_1;
    wire [12:0] fit_w_b_1 = {2'b00,fit_w_b};
    wire [12:0] fit_w_b_2 = fit_w_b_1 << 1;
    wire [12:0] fit_w_b_3 = fit_w_b_2 + fit_w_b_1;
    wire [12:0] x_sum_a_ext = {1'b0,x_sum_a};
    wire [12:0] x_sum_b_ext = {1'b0,x_sum_b};
    wire [1:0] x_step_a = (fit_w_a!=0 && x_sum_a_ext>=fit_w_a_3) ? 2'd3 :
                          (fit_w_a!=0 && x_sum_a_ext>=fit_w_a_2) ? 2'd2 :
                          (fit_w_a!=0 && x_sum_a_ext>=fit_w_a_1) ? 2'd1 : 2'd0;
    wire [1:0] x_step_b = (fit_w_b!=0 && x_sum_b_ext>=fit_w_b_3) ? 2'd3 :
                          (fit_w_b!=0 && x_sum_b_ext>=fit_w_b_2) ? 2'd2 :
                          (fit_w_b!=0 && x_sum_b_ext>=fit_w_b_1) ? 2'd1 : 2'd0;
    wire [9:0] x_src_a_adv = x_src_a + x_step_a;
    wire [9:0] x_src_b_adv = x_src_b + x_step_b;
    wire [12:0] x_rem_a = x_sum_a_ext -
                           ((x_step_a==3)?fit_w_a_3:(x_step_a==2)?fit_w_a_2:
                            (x_step_a==1)?fit_w_a_1:13'd0);
    wire [12:0] x_rem_b = x_sum_b_ext -
                           ((x_step_b==3)?fit_w_b_3:(x_step_b==2)?fit_w_b_2:
                            (x_step_b==1)?fit_w_b_1:13'd0);
    wire [10:0] x_phase_a_adv = x_rem_a[10:0];
    wire [10:0] x_phase_b_adv = x_rem_b[10:0];

    wire [11:0] pre_x12 =
        hcnt - (`QHMU_HBLANK-2);
    wire [10:0] pre_x = pre_x12[10:0];

    wire pre_inside_a =
        fit_valid_a &&
        ({1'b0,pre_x} >= {1'b0,fit_x_a}) &&
        ({1'b0,pre_x} < fit_x_end_a);

    wire pre_inside_b =
        fit_valid_b &&
        ({1'b0,pre_x} >= {1'b0,fit_x_b}) &&
        ({1'b0,pre_x} < fit_x_end_b);

    always @(posedge i_clk) begin
        if (i_rst) begin
            o_line_rd_addr_a<=10'd0;
            o_line_rd_addr_b<=10'd0;
            x_src_a<=10'd0; x_src_b<=10'd0;
            x_phase_a<=11'd0; x_phase_b<=11'd0;
        end else begin
            // Reset one clock before the two-cycle look-ahead window.
            if (hcnt==`QHMU_HBLANK-3) begin
                o_line_rd_addr_a<=10'd0;
                o_line_rd_addr_b<=10'd0;
                x_src_a<=10'd0; x_src_b<=10'd0;
                x_phase_a<=11'd0; x_phase_b<=11'd0;
            end else if ((hcnt>=`QHMU_HBLANK-2) &&
                         (hcnt<`QHMU_HBLANK+`QHMU_OUT_W-2)) begin
                if (pre_inside_a) begin
                    o_line_rd_addr_a<=x_src_a;
                    x_src_a<=x_src_a_adv;
                    x_phase_a<=x_phase_a_adv;
                end else begin
                    o_line_rd_addr_a<=10'd0;
                end

                if (pre_inside_b) begin
                    o_line_rd_addr_b<=x_src_b;
                    x_src_b<=x_src_b_adv;
                    x_phase_b<=x_phase_b_adv;
                end else begin
                    o_line_rd_addr_b<=10'd0;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Registered HDMI pixel stream.  Black bars are generated here rather than
    // written into SDRAM, so no memory bandwidth is wasted on the background.
    // ------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (i_rst) begin
            o_axis_user<=1'b0;
            o_axis_valid<=1'b0;
            o_axis_last<=1'b0;
            o_pix_a<=24'h000000;
            o_pix_b<=24'h000000;
            o_content_a<=1'b0;
            o_content_b<=1'b0;
            o_x<=11'd0;
            o_y<=11'd0;
            o_underrun<=1'b0;
        end else begin
            o_axis_user<=1'b0;
            o_axis_valid<=1'b0;
            o_axis_last<=1'b0;
            o_content_a<=1'b0;
            o_content_b<=1'b0;

            // Do not make a one-time startup miss latch the error LED forever.
            // A healthy later frame clears the underrun indication.
            if (o_frame_start)
                o_underrun<=1'b0;

            if (active_video) begin
                o_x<=x_now;
                o_y<=y_now;
                o_axis_valid<=1'b1;
                o_axis_user<=(x_now==11'd0)&&(y_now==11'd0);
                o_axis_last<=(x_now==`QHMU_OUT_W-1);

                if (inside_a_xy) begin
                    o_content_a<=1'b1;
                    if (line_ready[y_now[0]])
                        o_pix_a<=y_now[0] ?
                            i_line_a_bank1 : i_line_a_bank0;
                    else begin
                        o_pix_a<=24'h000000;
                        o_underrun<=1'b1;
                    end
                end else begin
                    o_pix_a<=24'h000000;
                end

                if (i_secondary_enable && inside_b_xy) begin
                    o_content_b<=1'b1;
                    if (line_ready[y_now[0]])
                        o_pix_b<=y_now[0] ?
                            i_line_b_bank1 : i_line_b_bank0;
                    else begin
                        o_pix_b<=24'h000000;
                        o_underrun<=1'b1;
                    end
                end else begin
                    o_pix_b<=24'h000000;
                end
            end else begin
                o_x<=11'd0;
                o_y<=11'd0;
                o_pix_a<=24'h000000;
                o_pix_b<=24'h000000;
            end
        end
    end
endmodule
