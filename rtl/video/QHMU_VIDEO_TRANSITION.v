`include "../QHMU_DEFINES.vh"

// QHMU_VIDEO_TRANSITION — resource-conscious five-mode transition compositor.
// Mode encoding (must match QHMU_USER_CONTROL and QHMU_OSD_COMPOSITOR):
//   0: Fade in/out through black
//   1: Split / reveal from the center toward both edges
//   2: Direct cut
//   3: Reveal along a diagonal
//   4: Push the incoming image upward from the bottom
//
// The controller advances alpha through 0,48,96,144,192,240 once per frame.
// No variable multipliers or full-frame coordinate transforms are used.
module QHMU_VIDEO_TRANSITION(
    input  wire [23:0] i_pix_a,
    input  wire [23:0] i_pix_b,
    input  wire        i_content_a,
    input  wire        i_content_b,
    input  wire [10:0] i_x,
    input  wire [10:0] i_y,
    input  wire        i_active,
    input  wire [3:0]  i_mode,
    input  wire [7:0]  i_alpha,
    output reg  [23:0] o_pixel,
    output reg         o_content
);
    reg [11:0] threshold_y;
    reg [11:0] threshold_half_w;
    reg [11:0] threshold_diag;
    reg [10:0] dx;
    reg choose_b;

    // Only the three thresholds used by the retained geometric transitions.
    always @* begin
        threshold_y      = 12'd0;
        threshold_half_w = 12'd0;
        threshold_diag   = 12'd0;
        case (i_alpha)
            8'd0: begin
                threshold_y      = 12'd0;
                threshold_half_w = 12'd0;
                threshold_diag   = 12'd0;
            end
            8'd48: begin
                threshold_y      = 12'd216;
                threshold_half_w = 12'd192;
                threshold_diag   = 12'd600;
            end
            8'd96: begin
                threshold_y      = 12'd432;
                threshold_half_w = 12'd384;
                threshold_diag   = 12'd1200;
            end
            8'd144: begin
                threshold_y      = 12'd648;
                threshold_half_w = 12'd576;
                threshold_diag   = 12'd1800;
            end
            8'd192: begin
                threshold_y      = 12'd864;
                threshold_half_w = 12'd768;
                threshold_diag   = 12'd2400;
            end
            default: begin
                threshold_y      = 12'd1080;
                threshold_half_w = 12'd960;
                threshold_diag   = 12'd3000;
            end
        endcase
    end

    always @* begin
        dx       = (i_x >= 11'd960) ? (i_x - 11'd960) :
                                          (11'd960 - i_x);
        choose_b = 1'b0;
        o_pixel  = i_pix_a;
        o_content = i_content_a;

        if (i_active) begin
            case (i_mode)
                // Fade-out then fade-in. Quantized shifts avoid per-pixel DSPs.
                4'd0: begin
                    case (i_alpha)
                        8'd0: begin
                            o_pixel   = i_pix_a;
                            o_content = i_content_a;
                        end
                        8'd48: begin
                            o_pixel = {i_pix_a[23:16] >> 1,
                                       i_pix_a[15:8]  >> 1,
                                       i_pix_a[7:0]   >> 1};
                            o_content = i_content_a;
                        end
                        8'd96: begin
                            o_pixel = {i_pix_a[23:16] >> 2,
                                       i_pix_a[15:8]  >> 2,
                                       i_pix_a[7:0]   >> 2};
                            o_content = i_content_a;
                        end
                        8'd144: begin
                            o_pixel = {i_pix_b[23:16] >> 2,
                                       i_pix_b[15:8]  >> 2,
                                       i_pix_b[7:0]   >> 2};
                            o_content = i_content_b;
                        end
                        8'd192: begin
                            o_pixel = {i_pix_b[23:16] >> 1,
                                       i_pix_b[15:8]  >> 1,
                                       i_pix_b[7:0]   >> 1};
                            o_content = i_content_b;
                        end
                        default: begin
                            o_pixel   = i_pix_b;
                            o_content = i_content_b;
                        end
                    endcase
                end

                // Split: incoming image grows outward from the center.
                4'd1: choose_b = ({1'b0, dx} <= threshold_half_w);

                // Direct cut is also handled immediately by the controller.
                4'd2: choose_b = 1'b1;

                // Reveal: incoming image is revealed along a diagonal.
                4'd3: choose_b = (({1'b0, i_x} + {1'b0, i_y}) < threshold_diag);

                // Push: incoming image moves upward from the bottom edge.
                4'd4: choose_b = (i_y >= (`QHMU_OUT_H - threshold_y));

                default: choose_b = 1'b0;
            endcase

            if (i_mode != 4'd0) begin
                if (choose_b) begin
                    o_pixel   = i_pix_b;
                    o_content = i_content_b;
                end else begin
                    o_pixel   = i_pix_a;
                    o_content = i_content_a;
                end
            end
        end
    end
endmodule
