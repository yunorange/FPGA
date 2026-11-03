// Toggle-based pulse synchronizer. Source pulses may not occur faster than the
// destination can observe two synchronizer stages.
module QHMU_PULSE_SYNC(
    input  wire i_src_clk,
    input  wire i_src_rst,
    input  wire i_src_pulse,
    input  wire i_dst_clk,
    input  wire i_dst_rst,
    output reg  o_dst_pulse
);
    reg src_toggle;
    reg dst_ff1, dst_ff2, dst_ff3;

    always @(posedge i_src_clk or posedge i_src_rst) begin
        if (i_src_rst)
            src_toggle <= 1'b0;
        else if (i_src_pulse)
            src_toggle <= ~src_toggle;
    end

    always @(posedge i_dst_clk or posedge i_dst_rst) begin
        if (i_dst_rst) begin
            dst_ff1    <= 1'b0;
            dst_ff2    <= 1'b0;
            dst_ff3    <= 1'b0;
            o_dst_pulse <= 1'b0;
        end else begin
            dst_ff1     <= src_toggle;
            dst_ff2     <= dst_ff1;
            dst_ff3     <= dst_ff2;
            o_dst_pulse <= dst_ff2 ^ dst_ff3;
        end
    end
endmodule
