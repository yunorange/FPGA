`ifndef QHMU_NET_APP_V
`define QHMU_NET_APP_V

// ============================================================================
// QHMU_NET_APP
// Application adapter for Anlogic's official UDP/IP stack.
//
// Network settings:
//   FPGA IP / UDP : 192.168.240.2 : 5001
//   PC IP / UDP   : 192.168.240.100 : 5002
//
// RX command format (minimum 2 bytes):
//   byte 0 = command code 1..6
//   byte 1 = command value
//
// TX status format (8 bytes):
//   80 00 brightness contrast transition image_index file_count flags
//   flags[0] = auto mode, flags[1] = audio-wait mode
//
// This module runs entirely in the UDP application clock domain.  The
// status buses are sampled through two-stage synchronizers; they change only
// at human-control / playback rates, not at packet rates.
// ============================================================================
module QHMU_NET_APP (
    input  wire        i_clk,
    input  wire        i_rst,

    input  wire        i_app_rx_data_valid,
    input  wire [7:0]  i_app_rx_data,
    input  wire [15:0] i_app_rx_data_length,
    input  wire [15:0] i_app_rx_port_num,

    input  wire        i_udp_tx_ready,
    input  wire        i_app_tx_ack,
    output reg         o_app_tx_request,
    output reg         o_app_tx_data_valid,
    output reg  [7:0]  o_app_tx_data,
    output reg  [15:0] o_app_tx_data_length,

    input  wire [6:0]  i_status_brightness,
    input  wire [6:0]  i_status_contrast,
    input  wire [3:0]  i_status_transition,
    input  wire [5:0]  i_status_image_index,
    input  wire [5:0]  i_status_file_count,
    input  wire        i_status_auto,
    input  wire        i_status_audio_wait,

    output reg         o_cmd_toggle,
    output reg  [3:0]  o_cmd_code,
    output reg  [7:0]  o_cmd_value,
    output reg         o_udp_rx_seen,
    output reg         o_udp_tx_seen,
    output reg  [7:0]  o_udp_rx_count
);

    // Fixed destination of the PC control application.
    // The protocol stack uses these values when a status reply is requested.
    // (The corresponding wires are exported by QHMU_RGMII_TEMAC_UDP.)

    // Status CDC: these values are slowly changing control/status buses.
    reg [6:0] status_brightness_meta, status_brightness_sync;
    reg [6:0] status_contrast_meta, status_contrast_sync;
    reg [3:0] status_transition_meta, status_transition_sync;
    reg [5:0] status_index_meta, status_index_sync;
    reg [5:0] status_count_meta, status_count_sync;
    reg       status_auto_meta, status_auto_sync;
    reg       status_audio_wait_meta, status_audio_wait_sync;

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            status_brightness_meta <= 7'd50;
            status_brightness_sync <= 7'd50;
            status_contrast_meta   <= 7'd50;
            status_contrast_sync   <= 7'd50;
            status_transition_meta <= 4'd0;
            status_transition_sync <= 4'd0;
            status_index_meta      <= 6'd0;
            status_index_sync      <= 6'd0;
            status_count_meta      <= 6'd0;
            status_count_sync      <= 6'd0;
            status_auto_meta       <= 1'b0;
            status_auto_sync       <= 1'b0;
            status_audio_wait_meta <= 1'b0;
            status_audio_wait_sync <= 1'b0;
        end else begin
            status_brightness_meta <= i_status_brightness;
            status_brightness_sync <= status_brightness_meta;
            status_contrast_meta   <= i_status_contrast;
            status_contrast_sync   <= status_contrast_meta;
            status_transition_meta <= i_status_transition;
            status_transition_sync <= status_transition_meta;
            status_index_meta      <= i_status_image_index;
            status_index_sync      <= status_index_meta;
            status_count_meta      <= i_status_file_count;
            status_count_sync      <= status_count_meta;
            status_auto_meta       <= i_status_auto;
            status_auto_sync       <= status_auto_meta;
            status_audio_wait_meta <= i_status_audio_wait;
            status_audio_wait_sync <= status_audio_wait_meta;
        end
    end

    // UDP receive packet assembly.
    //
    // Prefer the packet length supplied by the official UDP stack. A short
    // idle-gap fallback is retained for revisions where that metadata is zero.
    // The packet-end pulse is registered so the command and length remain
    // stable for the command/TX state machines.
    reg        rx_active;
    reg [2:0]  rx_gap_count;
    reg [15:0] rx_byte_count;
    reg [15:0] rx_expected_length;
    reg        rx_packet_end;
    reg [15:0] rx_packet_length;
    reg [7:0]  rx_command;
    reg [7:0]  rx_value;

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            rx_active          <= 1'b0;
            rx_gap_count       <= 3'd0;
            rx_byte_count      <= 16'd0;
            rx_expected_length <= 16'd0;
            rx_packet_end      <= 1'b0;
            rx_packet_length   <= 16'd0;
            rx_command         <= 8'd0;
            rx_value           <= 8'd0;
        end else begin
            rx_packet_end <= 1'b0;

            if (i_app_rx_data_valid) begin
                rx_gap_count <= 3'd0;

                if (!rx_active) begin
                    rx_active          <= 1'b1;
                    rx_expected_length <= i_app_rx_data_length;
                    rx_byte_count      <= 16'd1;
                    rx_command         <= i_app_rx_data;
                    if (i_app_rx_data_length == 16'd1) begin
                        rx_packet_end    <= 1'b1;
                        rx_packet_length <= 16'd1;
                        rx_active        <= 1'b0;
                        rx_byte_count    <= 16'd0;
                    end
                end else begin
                    if (rx_byte_count == 16'd1)
                        rx_value <= i_app_rx_data;

                    if ((rx_expected_length != 16'd0) &&
                        ((rx_byte_count + 16'd1) >= rx_expected_length)) begin
                        rx_packet_end    <= 1'b1;
                        rx_packet_length <= rx_byte_count + 16'd1;
                        rx_active        <= 1'b0;
                        rx_byte_count    <= 16'd0;
                        rx_gap_count     <= 3'd0;
                    end else if (rx_byte_count != 16'hffff) begin
                        rx_byte_count <= rx_byte_count + 1'b1;
                    end
                end
            end else if (rx_active) begin
                if (rx_gap_count == 3'd3) begin
                    rx_packet_end    <= 1'b1;
                    rx_packet_length <= rx_byte_count;
                    rx_active        <= 1'b0;
                    rx_gap_count     <= 3'd0;
                    rx_byte_count    <= 16'd0;
                end else begin
                    rx_gap_count <= rx_gap_count + 1'b1;
                end
            end
        end
    end

    // Count and decode completed UDP datagrams. Commands 1..6 use byte 0
    // as the command and byte 1 as its value; payloads >=2 bytes request
    // an 8-byte status response.
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            o_cmd_toggle   <= 1'b0;
            o_cmd_code     <= 4'd0;
            o_cmd_value    <= 8'd0;
            o_udp_rx_seen  <= 1'b0;
            o_udp_rx_count <= 8'd0;
        end else begin
            if (rx_packet_end && (rx_packet_length >= 16'd2)) begin
                o_udp_rx_seen <= 1'b1;
                if (o_udp_rx_count != 8'hff)
                    o_udp_rx_count <= o_udp_rx_count + 1'b1;
                if ((rx_command >= 8'h01) && (rx_command <= 8'h06)) begin
                    o_cmd_code   <= rx_command[3:0];
                    o_cmd_value  <= rx_value;
                    o_cmd_toggle <= ~o_cmd_toggle;
                end
            end
        end
    end

    // Status snapshot is frozen when a response request is accepted by the
    // UDP stack.  This prevents a multi-byte reply from mixing status updates.
    reg [6:0] rsp_brightness;
    reg [6:0] rsp_contrast;
    reg [3:0] rsp_transition;
    reg [5:0] rsp_index;
    reg [5:0] rsp_count;
    reg       rsp_auto;
    reg       rsp_audio_wait;

    function [7:0] response_byte;
        input [2:0] index;
        begin
            case (index)
                3'd0: response_byte = 8'h80;
                3'd1: response_byte = 8'h00;
                3'd2: response_byte = {1'b0,rsp_brightness};
                3'd3: response_byte = {1'b0,rsp_contrast};
                3'd4: response_byte = {4'd0,rsp_transition};
                3'd5: response_byte = {2'd0,rsp_index} + 8'd1;
                3'd6: response_byte = {2'd0,rsp_count};
                default: response_byte = {6'd0,rsp_audio_wait,rsp_auto};
            endcase
        end
    endfunction

    localparam [1:0] TX_IDLE     = 2'd0;
    localparam [1:0] TX_WAIT_ACK = 2'd1;
    localparam [1:0] TX_SEND     = 2'd2;

    reg [1:0] tx_state;
    reg [2:0] tx_index;
    reg       tx_pending;

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            tx_state             <= TX_IDLE;
            tx_index             <= 3'd0;
            tx_pending           <= 1'b0;
            o_app_tx_request     <= 1'b0;
            o_app_tx_data_valid  <= 1'b0;
            o_app_tx_data        <= 8'd0;
            o_app_tx_data_length <= 16'd0;
            rsp_brightness       <= 7'd50;
            rsp_contrast         <= 7'd50;
            rsp_transition       <= 4'd0;
            rsp_index            <= 6'd0;
            rsp_count            <= 6'd0;
            rsp_auto             <= 1'b0;
            rsp_audio_wait       <= 1'b0;
            o_udp_tx_seen        <= 1'b0;
        end else begin
            // Preserve one pending reply if a datagram arrives while the
            // previous reply is being transmitted.
            if (rx_packet_end && (rx_packet_length >= 16'd2))
                tx_pending <= 1'b1;
            else if ((tx_state == TX_IDLE) && tx_pending && i_udp_tx_ready)
                tx_pending <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    o_app_tx_request    <= 1'b0;
                    o_app_tx_data_valid <= 1'b0;
                    if (tx_pending && i_udp_tx_ready) begin
                        rsp_brightness <= status_brightness_sync;
                        rsp_contrast   <= status_contrast_sync;
                        rsp_transition <= status_transition_sync;
                        rsp_index      <= status_index_sync;
                        rsp_count      <= status_count_sync;
                        rsp_auto       <= status_auto_sync;
                        rsp_audio_wait <= status_audio_wait_sync;
                        o_app_tx_request <= 1'b1;
                        tx_state <= TX_WAIT_ACK;
                    end
                end

                TX_WAIT_ACK: begin
                    o_app_tx_request    <= 1'b1;
                    o_app_tx_data_valid <= 1'b0;
                    if (i_app_tx_ack) begin
                        o_app_tx_request     <= 1'b0;
                        o_app_tx_data_length <= 16'd8;
                        o_app_tx_data        <= response_byte(3'd0);
                        o_app_tx_data_valid  <= 1'b1;
                        tx_index             <= 3'd0;
                        tx_state             <= TX_SEND;
                    end
                end

                TX_SEND: begin
                    if (tx_index == 3'd7) begin
                        // The stack samples byte 7 on this clock edge; valid
                        // is deasserted for the following cycle.
                        o_app_tx_data_valid <= 1'b0;
                        o_udp_tx_seen       <= 1'b1;
                        tx_state            <= TX_IDLE;
                    end else begin
                        tx_index            <= tx_index + 1'b1;
                        o_app_tx_data       <= response_byte(tx_index + 1'b1);
                        o_app_tx_data_valid <= 1'b1;
                    end
                end

                default: begin
                    tx_state <= TX_IDLE;
                    o_app_tx_request <= 1'b0;
                    o_app_tx_data_valid <= 1'b0;
                end
            endcase
        end
    end

    // These inputs are provided by the protocol stack for diagnostics and
    // future source-port filtering.  The current PC utility uses a fixed peer.
    wire _unused_app_rx_metadata = ^{i_app_rx_data_length, i_app_rx_port_num};

endmodule
`endif
