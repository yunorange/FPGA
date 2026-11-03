// 8-digit common-anode style dynamic seven-segment driver used by HX4S20C.
// Segment and digit-select outputs are active low.  digit[0] is scanned first.
module QHMU_SEG7_DRIVER #(
    parameter CLK_HZ = 50_000_000,
    parameter FRAME_HZ = 200
)(
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire [31:0] i_digits,
    output reg  [7:0]  o_seg,
    output reg  [7:0]  o_sel
);
    localparam integer TICK_DIV = CLK_HZ/(FRAME_HZ*8);
    reg [15:0] tick_cnt;
    reg [2:0] digit_idx;
    reg [3:0] nibble;

    function [6:0] hex7;
        input [3:0] v;
        begin
            case(v)
                4'h0: hex7=7'b1000000; 4'h1: hex7=7'b1111001;
                4'h2: hex7=7'b0100100; 4'h3: hex7=7'b0110000;
                4'h4: hex7=7'b0011001; 4'h5: hex7=7'b0010010;
                4'h6: hex7=7'b0000010; 4'h7: hex7=7'b1111000;
                4'h8: hex7=7'b0000000; 4'h9: hex7=7'b0010000;
                4'hA: hex7=7'b0001000; 4'hB: hex7=7'b0000011;
                4'hC: hex7=7'b1000110; 4'hD: hex7=7'b0100001;
                4'hE: hex7=7'b0000110; default: hex7=7'b0001110;
            endcase
        end
    endfunction

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            tick_cnt <= 0;
            digit_idx <= 0;
        end else if (tick_cnt >= TICK_DIV-1) begin
            tick_cnt <= 0;
            digit_idx <= digit_idx + 1'b1;
        end else begin
            tick_cnt <= tick_cnt + 1'b1;
        end
    end

    always @(*) begin
        case(digit_idx)
            3'd0: begin o_sel=8'b11111110; nibble=i_digits[3:0]; end
            3'd1: begin o_sel=8'b11111101; nibble=i_digits[7:4]; end
            3'd2: begin o_sel=8'b11111011; nibble=i_digits[11:8]; end
            3'd3: begin o_sel=8'b11110111; nibble=i_digits[15:12]; end
            3'd4: begin o_sel=8'b11101111; nibble=i_digits[19:16]; end
            3'd5: begin o_sel=8'b11011111; nibble=i_digits[23:20]; end
            3'd6: begin o_sel=8'b10111111; nibble=i_digits[27:24]; end
            default: begin o_sel=8'b01111111; nibble=i_digits[31:28]; end
        endcase
        o_seg = {1'b1,hex7(nibble)}; // decimal point off
    end
endmodule
