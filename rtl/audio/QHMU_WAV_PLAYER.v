// ============================================================================
// QHMU_WAV_PLAYER
// QHMU_HDMI_PRO SD-card WAV decoder / HDMI PCM source
//
// Supported audio format (deliberately fixed to the HDMI core configuration):
//   RIFF/WAVE, PCM format 1, stereo, 48,000 Hz, 16-bit little-endian.
//
// The FAT32 media reader supplies a byte stream in the 50-MHz control domain.
// PCM stereo frames are packed into a 2048-frame asynchronous FIFO.  In the
// Pixel-domain sample timing uses a fractional accumulator, so 48 kHz remains exact-average at arbitrary HDMI pixel clocks.
// During underflow or before a valid WAV reaches the FIFO, the module still
// emits 48-kHz zero samples so HDMI audio timing remains continuous.
// ============================================================================
module QHMU_WAV_PLAYER #(
    parameter integer PIXEL_HZ = 25200000,
    parameter integer SAMPLE_HZ = 48000
)(
    input  wire        i_ctrl_clk,
    input  wire        i_ctrl_rst,
    input  wire        i_flush,

    input  wire        i_file_start,
    input  wire [31:0] i_file_size,
    input  wire [7:0]  i_file_data,
    input  wire        i_file_data_valid,
    input  wire        i_file_done,
    output wire        o_stream_ready,
    output reg         o_format_ok,
    output reg         o_error,

    input  wire        i_pixel_clk,
    input  wire        i_pixel_rst,
    output reg         o_audio_valid,
    output reg  [23:0] o_left,
    output reg  [23:0] o_right,
    output reg         o_underflow_pulse,
    output reg         o_playback_done
);
    // Parser states.
    localparam P_WAIT       = 4'd0;
    localparam P_RIFF       = 4'd1;
    localparam P_CHUNK_ID   = 4'd2;
    localparam P_CHUNK_SIZE = 4'd3;
    localparam P_FMT        = 4'd4;
    localparam P_SKIP       = 4'd6;
    localparam P_PAD        = 4'd7;
    localparam P_DATA       = 4'd8;
    localparam P_DATA_END   = 4'd9;
    localparam P_ERROR      = 4'd15;

    reg [3:0] parser_state;
    reg [3:0] sub_index;
    reg [31:0] file_pos;

    reg [7:0] chunk_id0;
    reg [7:0] chunk_id1;
    reg [7:0] chunk_id2;
    reg [7:0] chunk_id3;
    reg [31:0] chunk_size;
    reg [31:0] chunk_remaining;
    reg chunk_pad_needed;

    reg [15:0] wav_format;
    reg [15:0] wav_channels;
    reg [31:0] wav_sample_rate;
    reg [15:0] wav_block_align;
    reg [15:0] wav_bits_per_sample;
    reg [5:0]  fmt_pos;

    reg [31:0] data_remaining;
    reg [1:0]  pcm_phase;
    reg [7:0]  left_lo;
    reg [7:0]  left_hi;
    reg [7:0]  right_lo;

    reg         fifo_wr_en;
    reg [31:0]  fifo_wr_data;
    wire        fifo_full;
    wire        fifo_almost_full;

    wire        fifo_empty;
    reg         fifo_rd_en;
    wire [31:0] fifo_rd_data;
    wire        fifo_rd_valid;

    // Pixel-domain sample state is declared before the control-domain CDC
    // synchronizer that observes these flags.
    reg [31:0] rate_accum;
    reg [31:0] sample_hold;
    reg sample_hold_valid;
    reg read_pending;
    wire [32:0] rate_sum = {1'b0,rate_accum} + SAMPLE_HZ;
    wire sample_tick = (rate_sum >= PIXEL_HZ);

    // Pixel-to-control drain status synchronizers. A FAT file-read completion
    // is not the same as audio playback completion: PCM may still be queued.
    reg fifo_empty_meta, fifo_empty_sync;
    reg sample_hold_meta, sample_hold_sync;
    reg read_pending_meta, read_pending_sync;
    reg file_input_done;
    reg playback_done_sent;

    wire flush_pixel;
    QHMU_PULSE_SYNC u_audio_flush_sync(
        .i_src_clk(i_ctrl_clk), .i_src_rst(i_ctrl_rst),
        .i_src_pulse(i_flush),
        .i_dst_clk(i_pixel_clk), .i_dst_rst(i_pixel_rst),
        .o_dst_pulse(flush_pixel)
    );

    QHMU_AUDIO_FIFO #(
        .ADDR_WIDTH(11),
        .ALMOST_FULL_MARGIN(256)
    ) u_pcm_fifo (
        .i_wr_clk(i_ctrl_clk),
        .i_wr_rst(i_ctrl_rst | i_flush),
        .i_wr_en(fifo_wr_en),
        .i_wr_data(fifo_wr_data),
        .o_wr_full(fifo_full),
        .o_wr_almost_full(fifo_almost_full),

        .i_rd_clk(i_pixel_clk),
        .i_rd_rst(i_pixel_rst | flush_pixel),
        .i_rd_en(fifo_rd_en),
        .o_rd_data(fifo_rd_data),
        .o_rd_valid(fifo_rd_valid),
        .o_rd_empty(fifo_empty)
    );

    // Leave enough room for an entire SD sector once the media reader starts
    // it.  Parser errors do NOT stop the FAT stream; the file is drained and
    // the next track can still be opened cleanly.
    assign o_stream_ready = !fifo_almost_full;

    // ------------------------------------------------------------------------
    // RIFF/WAV parser in the control clock domain.
    // ------------------------------------------------------------------------
    always @(posedge i_ctrl_clk or posedge i_ctrl_rst) begin
        if (i_ctrl_rst) begin
            parser_state        <= P_WAIT;
            sub_index           <= 4'd0;
            file_pos            <= 32'd0;
            chunk_id0           <= 8'd0;
            chunk_id1           <= 8'd0;
            chunk_id2           <= 8'd0;
            chunk_id3           <= 8'd0;
            chunk_size          <= 32'd0;
            chunk_remaining     <= 32'd0;
            chunk_pad_needed    <= 1'b0;
            wav_format          <= 16'd0;
            wav_channels        <= 16'd0;
            wav_sample_rate     <= 32'd0;
            wav_block_align     <= 16'd0;
            wav_bits_per_sample <= 16'd0;
            fmt_pos             <= 6'd0;
            data_remaining      <= 32'd0;
            pcm_phase           <= 2'd0;
            left_lo             <= 8'd0;
            left_hi             <= 8'd0;
            right_lo            <= 8'd0;
            fifo_wr_en          <= 1'b0;
            fifo_wr_data        <= 32'd0;
            o_format_ok         <= 1'b0;
            o_error             <= 1'b0;
        end else begin
            fifo_wr_en <= 1'b0;

            if (i_flush) begin
                parser_state        <= P_WAIT;
                sub_index           <= 4'd0;
                file_pos            <= 32'd0;
                chunk_remaining     <= 32'd0;
                data_remaining      <= 32'd0;
                pcm_phase           <= 2'd0;
                o_format_ok         <= 1'b0;
                o_error             <= 1'b0;
            end else if (i_file_start) begin
                parser_state        <= P_RIFF;
                sub_index           <= 4'd0;
                file_pos            <= 32'd0;
                chunk_id0           <= 8'd0;
                chunk_id1           <= 8'd0;
                chunk_id2           <= 8'd0;
                chunk_id3           <= 8'd0;
                chunk_size          <= 32'd0;
                chunk_remaining     <= 32'd0;
                chunk_pad_needed    <= 1'b0;
                wav_format          <= 16'd0;
                wav_channels        <= 16'd0;
                wav_sample_rate     <= 32'd0;
                wav_block_align     <= 16'd0;
                wav_bits_per_sample <= 16'd0;
                fmt_pos             <= 6'd0;
                data_remaining      <= 32'd0;
                pcm_phase           <= 2'd0;
                o_format_ok         <= 1'b0;
                o_error             <= 1'b0;
            end else if (i_file_data_valid) begin
                file_pos <= file_pos + 1'b1;

                case (parser_state)
                    P_RIFF: begin
                        // RIFF....WAVE (12-byte container header).
                        if (((file_pos == 0)  && (i_file_data != "R")) ||
                            ((file_pos == 1)  && (i_file_data != "I")) ||
                            ((file_pos == 2)  && (i_file_data != "F")) ||
                            ((file_pos == 3)  && (i_file_data != "F")) ||
                            ((file_pos == 8)  && (i_file_data != "W")) ||
                            ((file_pos == 9)  && (i_file_data != "A")) ||
                            ((file_pos == 10) && (i_file_data != "V")) ||
                            ((file_pos == 11) && (i_file_data != "E"))) begin
                            o_error      <= 1'b1;
                            parser_state <= P_ERROR;
                        end else if (file_pos == 11) begin
                            sub_index    <= 4'd0;
                            parser_state <= P_CHUNK_ID;
                        end
                    end

                    P_CHUNK_ID: begin
                        case (sub_index)
                            4'd0: chunk_id0 <= i_file_data;
                            4'd1: chunk_id1 <= i_file_data;
                            4'd2: chunk_id2 <= i_file_data;
                            4'd3: chunk_id3 <= i_file_data;
                            default: ;
                        endcase

                        if (sub_index == 4'd3) begin
                            sub_index    <= 4'd0;
                            chunk_size   <= 32'd0;
                            parser_state <= P_CHUNK_SIZE;
                        end else begin
                            sub_index <= sub_index + 1'b1;
                        end
                    end

                    P_CHUNK_SIZE: begin
                        case (sub_index)
                            4'd0: chunk_size[7:0]   <= i_file_data;
                            4'd1: chunk_size[15:8]  <= i_file_data;
                            4'd2: chunk_size[23:16] <= i_file_data;
                            4'd3: begin
                                chunk_size[31:24] <= i_file_data;
                                chunk_remaining <= {i_file_data,chunk_size[23:0]};
                                chunk_pad_needed <= chunk_size[0];

                                if ((chunk_id0 == "f") &&
                                    (chunk_id1 == "m") &&
                                    (chunk_id2 == "t") &&
                                    (chunk_id3 == " ")) begin
                                    fmt_pos      <= 6'd0;
                                    parser_state <= P_FMT;
                                end else if ((chunk_id0 == "d") &&
                                             (chunk_id1 == "a") &&
                                             (chunk_id2 == "t") &&
                                             (chunk_id3 == "a")) begin
                                    if (o_format_ok) begin
                                        data_remaining <= {i_file_data,chunk_size[23:0]};
                                        pcm_phase      <= 2'd0;
                                        parser_state   <= P_DATA;
                                    end else begin
                                        o_error      <= 1'b1;
                                        parser_state <= P_ERROR;
                                    end
                                end else begin
                                    parser_state <= P_SKIP;
                                end
                            end
                            default: ;
                        endcase

                        if (sub_index != 4'd3)
                            sub_index <= sub_index + 1'b1;
                        else
                            sub_index <= 4'd0;
                    end

                    P_FMT: begin
                        // Standard WAVEFORMAT fields; extensions are skipped.
                        case (fmt_pos)
                            6'd0:  wav_format[7:0] <= i_file_data;
                            6'd1:  wav_format[15:8] <= i_file_data;
                            6'd2:  wav_channels[7:0] <= i_file_data;
                            6'd3:  wav_channels[15:8] <= i_file_data;
                            6'd4:  wav_sample_rate[7:0] <= i_file_data;
                            6'd5:  wav_sample_rate[15:8] <= i_file_data;
                            6'd6:  wav_sample_rate[23:16] <= i_file_data;
                            6'd7:  wav_sample_rate[31:24] <= i_file_data;
                            6'd12: wav_block_align[7:0] <= i_file_data;
                            6'd13: wav_block_align[15:8] <= i_file_data;
                            6'd14: wav_bits_per_sample[7:0] <= i_file_data;
                            6'd15: wav_bits_per_sample[15:8] <= i_file_data;
                            default: ;
                        endcase

                        if (chunk_remaining <= 32'd1) begin
                            chunk_remaining <= 32'd0;

                            // Validate after the final fmt byte.  For the
                            // standard 16-byte PCM fmt chunk, the current byte
                            // is bits_per_sample[15:8], so include it directly.
                            if ((fmt_pos >= 6'd15) &&
                                (wav_format == 16'd1) &&
                                (wav_channels == 16'd2) &&
                                (wav_sample_rate == 32'd48000) &&
                                (wav_block_align == 16'd4) &&
                                (((fmt_pos == 6'd15) ?
                                  {i_file_data,wav_bits_per_sample[7:0]} :
                                  wav_bits_per_sample) == 16'd16)) begin
                                o_format_ok <= 1'b1;
                                if (chunk_pad_needed)
                                    parser_state <= P_PAD;
                                else begin
                                    sub_index <= 4'd0;
                                    parser_state <= P_CHUNK_ID;
                                end
                            end else begin
                                o_error      <= 1'b1;
                                parser_state <= P_ERROR;
                            end
                        end else begin
                            chunk_remaining <= chunk_remaining - 1'b1;
                            if (fmt_pos != 6'h3F)
                                fmt_pos <= fmt_pos + 1'b1;
                        end
                    end

                    P_SKIP: begin
                        if (chunk_remaining <= 32'd1) begin
                            chunk_remaining <= 32'd0;
                            if (chunk_pad_needed)
                                parser_state <= P_PAD;
                            else begin
                                sub_index <= 4'd0;
                                parser_state <= P_CHUNK_ID;
                            end
                        end else begin
                            chunk_remaining <= chunk_remaining - 1'b1;
                        end
                    end

                    P_PAD: begin
                        // One RIFF pad byte after an odd-sized chunk.
                        sub_index    <= 4'd0;
                        parser_state <= P_CHUNK_ID;
                    end

                    P_DATA: begin
                        if (data_remaining != 32'd0) begin
                            case (pcm_phase)
                                2'd0: left_lo  <= i_file_data;
                                2'd1: left_hi  <= i_file_data;
                                2'd2: right_lo <= i_file_data;
                                2'd3: begin
                                    if (!fifo_full) begin
                                        fifo_wr_data <= {
                                            left_hi, left_lo,
                                            i_file_data, right_lo
                                        };
                                        fifo_wr_en <= 1'b1;
                                    end else begin
                                        o_error <= 1'b1;
                                    end
                                end
                            endcase

                            if (pcm_phase == 2'd3)
                                pcm_phase <= 2'd0;
                            else
                                pcm_phase <= pcm_phase + 1'b1;

                            if (data_remaining == 32'd1) begin
                                data_remaining <= 32'd0;
                                parser_state   <= P_DATA_END;
                            end else begin
                                data_remaining <= data_remaining - 1'b1;
                            end
                        end
                    end

                    P_DATA_END: begin
                        // Ignore optional trailing RIFF chunks.  Playback data
                        // already resides in the PCM FIFO.
                        parser_state <= P_DATA_END;
                    end

                    P_ERROR: begin
                        // Drain the physical file stream without producing PCM.
                        parser_state <= P_ERROR;
                    end

                    default: parser_state <= P_WAIT;
                endcase
            end

            // A truncated RIFF/data stream is an error.  P_DATA_END is normal.
            if (i_file_done &&
                (parser_state != P_DATA_END) &&
                (parser_state != P_WAIT) &&
                (parser_state != P_ERROR)) begin
                o_error <= 1'b1;
                parser_state <= P_ERROR;
            end
        end
    end

    // Synchronize the read-side FIFO empty and sample-hold flags back to the
    // control domain. The manager advances only after the final PCM sample has
    // actually been emitted by the HDMI pixel/audio clock domain.
    always @(posedge i_ctrl_clk or posedge i_ctrl_rst) begin
        if (i_ctrl_rst) begin
            fifo_empty_meta   <= 1'b1;
            fifo_empty_sync   <= 1'b1;
            sample_hold_meta  <= 1'b0;
            sample_hold_sync  <= 1'b0;
            read_pending_meta <= 1'b0;
            read_pending_sync <= 1'b0;
        end else begin
            fifo_empty_meta   <= fifo_empty;
            fifo_empty_sync   <= fifo_empty_meta;
            sample_hold_meta  <= sample_hold_valid;
            sample_hold_sync  <= sample_hold_meta;
            read_pending_meta <= read_pending;
            read_pending_sync <= read_pending_meta;
        end
    end

    always @(posedge i_ctrl_clk or posedge i_ctrl_rst) begin
        if (i_ctrl_rst) begin
            file_input_done  <= 1'b0;
            playback_done_sent <= 1'b0;
            o_playback_done  <= 1'b0;
        end else begin
            o_playback_done <= 1'b0;
            if (i_flush) begin
                file_input_done    <= 1'b0;
                playback_done_sent <= 1'b0;
            end else if (i_file_start) begin
                file_input_done    <= 1'b0;
                playback_done_sent <= 1'b0;
            end

            if (i_file_done)
                file_input_done <= 1'b1;

            if (file_input_done &&
                ((parser_state == P_DATA_END) || (parser_state == P_ERROR)) &&
                !fifo_wr_en && fifo_empty_sync &&
                !sample_hold_sync && !read_pending_sync &&
                !playback_done_sent) begin
                o_playback_done    <= 1'b1;
                playback_done_sent <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Exact-average 48-kHz playback in the pixel clock domain.
    // Fractional accumulator works for 25.2 MHz, 74.25 MHz, 148.5 MHz, etc.
    // ------------------------------------------------------------------------
    always @(posedge i_pixel_clk or posedge i_pixel_rst) begin
        if (i_pixel_rst) begin
            rate_accum<=0; sample_hold<=0; sample_hold_valid<=0; read_pending<=0;
            fifo_rd_en<=0; o_audio_valid<=0; o_left<=0; o_right<=0; o_underflow_pulse<=0;
        end else if (flush_pixel) begin
            rate_accum<=0; sample_hold<=0; sample_hold_valid<=0; read_pending<=0;
            fifo_rd_en<=0; o_audio_valid<=0; o_left<=0; o_right<=0; o_underflow_pulse<=0;
        end else begin
            fifo_rd_en<=0; o_audio_valid<=0; o_underflow_pulse<=0;
            if (fifo_rd_valid) begin
                sample_hold<=fifo_rd_data; sample_hold_valid<=1'b1; read_pending<=1'b0;
            end
            if (!sample_hold_valid && !read_pending && !fifo_empty) begin
                fifo_rd_en<=1'b1; read_pending<=1'b1;
            end
            if (sample_tick) begin
                rate_accum <= rate_sum - PIXEL_HZ;
                o_audio_valid <= 1'b1;
                if (sample_hold_valid) begin
                    o_left<={sample_hold[31:16],8'h00};
                    o_right<={sample_hold[15:0],8'h00};
                    sample_hold_valid<=1'b0;
                end else begin
                    o_left<=0; o_right<=0; o_underflow_pulse<=1'b1;
                end
            end else rate_accum <= rate_sum[31:0];
        end
    end
endmodule
