// QHMU_TMDS_SERIALIZER
// EG4 implementation of the APUG092 10:1 TMDS serializer. A 5x pixel clock
// shifts two bits per cycle and EG_LOGIC_ODDR transmits one bit per edge.
module QHMU_TMDS_SERIALIZER(
    input  wire       i_pixel_clk,
    input  wire       i_serial_clk,
    input  wire       i_rst,
    input  wire [9:0] i_data,
    output wire       o_serial
);
    reg odd_even;
    reg odd_even_d1, odd_even_d2;
    reg load_en, load_en_d1, load_en_d2;
    reg [9:0] shift_data;
    reg [1:0] oddr_data;

    always @(posedge i_pixel_clk or posedge i_rst) begin
        if (i_rst)
            odd_even <= 1'b0;
        else
            odd_even <= ~odd_even;
    end

    always @(posedge i_serial_clk or posedge i_rst) begin
        if (i_rst) begin
            odd_even_d1 <= 1'b0;
            odd_even_d2 <= 1'b0;
            load_en     <= 1'b0;
            load_en_d1  <= 1'b0;
            load_en_d2  <= 1'b0;
        end else begin
            odd_even_d1 <= odd_even;
            odd_even_d2 <= odd_even_d1;
            load_en     <= odd_even_d1 ^ odd_even_d2;
            load_en_d1  <= load_en;
            load_en_d2  <= load_en_d1;
        end
    end

    always @(posedge i_serial_clk or posedge i_rst) begin
        if (i_rst)
            shift_data <= 10'd0;
        else if (load_en_d2)
            shift_data <= i_data;
        else
            shift_data <= shift_data << 2;
    end

    always @(posedge i_serial_clk or posedge i_rst) begin
        if (i_rst)
            oddr_data <= 2'b00;
        else
            oddr_data <= shift_data[9:8];
    end

    EG_LOGIC_ODDR u_oddr(
        .clk(i_serial_clk),
        .rst(i_rst),
        .d1(oddr_data[0]),
        .d0(oddr_data[1]),
        .q(o_serial)
    );
endmodule
