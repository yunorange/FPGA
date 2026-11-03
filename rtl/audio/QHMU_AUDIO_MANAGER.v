// ============================================================================
// QHMU_AUDIO_MANAGER - three-policy media playback controller.
//
// Manual mode:
//   * Images are changed only by KEY1/KEY2.
//   * MUS0001.WAV ... MUSxxxx.WAV form an independent circular playlist.
//   * MUS EOF advances the music index, never the image index.
//
// Automatic mode:
//   * SW1=0: paired AUDxxxx.WAV; image changes on the 8-second image timer.
//   * SW1=1: paired MUSxxxx.WAV; image changes only after the final PCM sample
//            has left the HDMI audio FIFO (or the paired MUS file is missing).
//
// The image-commit pulse is required for a one-image catalog: the index remains
// zero when the manager wraps PIC0001.BMP back to itself.
// ============================================================================
module QHMU_AUDIO_MANAGER(
    input  wire       i_clk,
    input  wire       i_rst,
    input  wire       i_display_valid,
    input  wire [4:0] i_image_index,
    input  wire       i_image_commit_pulse,
    input  wire       i_auto_mode,
    input  wire       i_auto_wait_audio,
    input  wire [5:0] i_audio_count,
    input  wire [5:0] i_music_count,
    input  wire       i_audio_file_start,
    input  wire       i_audio_open_miss,
    input  wire       i_playback_done,
    input  wire       i_wav_error,

    output reg        o_audio_open_req,
    output reg [4:0]  o_audio_open_index,
    output reg        o_audio_select_music,
    output reg        o_audio_flush,
    output reg        o_next_image_pulse
);
    reg        display_valid_d;
    reg        auto_mode_d;
    reg        audio_wait_mode_d;
    reg [4:0]  image_index_d;
    reg [4:0]  manual_track_index;
    reg [5:0]  manual_miss_count;
    reg        track_pending;
    reg        track_active;
    reg        wav_error_d;

    wire       mode_entry;
    wire       policy_change;
    wire       auto_image_commit;
    wire       wav_error_rise;
    wire [5:0] image_index_ext;
    wire [5:0] manual_next_ext;
    wire [4:0] manual_next_index;
    wire       auto_track_present;

    assign mode_entry = !display_valid_d || (i_auto_mode != auto_mode_d);
    assign policy_change = i_auto_mode &&
                           (i_auto_wait_audio != audio_wait_mode_d);
    assign auto_image_commit = i_image_commit_pulse ||
                               (i_image_index != image_index_d);
    assign wav_error_rise = i_wav_error && !wav_error_d;

    assign image_index_ext = {1'b0, i_image_index};
    assign manual_next_ext = {1'b0, manual_track_index} + 6'd1;
    assign manual_next_index =
        (i_music_count == 6'd0 || manual_next_ext >= i_music_count) ?
        5'd0 : manual_next_ext[4:0];

    // Timed automatic mode selects AUD; variable-duration mode selects MUS.
    assign auto_track_present = i_auto_wait_audio ?
                                (image_index_ext < i_music_count) :
                                (image_index_ext < i_audio_count);

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            display_valid_d      <= 1'b0;
            auto_mode_d          <= 1'b0;
            audio_wait_mode_d    <= 1'b0;
            image_index_d        <= 5'd0;
            manual_track_index   <= 5'd0;
            manual_miss_count    <= 6'd0;
            track_pending        <= 1'b0;
            track_active         <= 1'b0;
            wav_error_d          <= 1'b0;
            o_audio_open_req     <= 1'b0;
            o_audio_open_index   <= 5'd0;
            o_audio_select_music <= 1'b1;
            o_audio_flush        <= 1'b0;
            o_next_image_pulse   <= 1'b0;
        end else begin
            o_audio_open_req   <= 1'b0;
            o_audio_flush      <= 1'b0;
            o_next_image_pulse <= 1'b0;

            display_valid_d   <= i_display_valid;
            auto_mode_d       <= i_auto_mode;
            audio_wait_mode_d <= i_auto_wait_audio;
            image_index_d     <= i_image_index;
            wav_error_d       <= i_wav_error;

            if (!i_display_valid) begin
                track_pending     <= 1'b0;
                track_active      <= 1'b0;
                manual_miss_count <= 6'd0;
            end else if (mode_entry) begin
                // Switching mode always flushes the old stream.
                track_pending <= 1'b0;
                track_active  <= 1'b0;
                o_audio_flush <= 1'b1;

                if (i_auto_mode) begin
                    // Auto entry: AUD for timed mode, paired MUS for EOF mode.
                    o_audio_select_music <= i_auto_wait_audio;
                    if (auto_track_present) begin
                        o_audio_open_index <= i_image_index;
                        o_audio_open_req   <= 1'b1;
                        track_pending      <= 1'b1;
                    end else if (i_auto_wait_audio) begin
                        // No paired MUS must not leave variable mode stalled.
                        o_next_image_pulse <= 1'b1;
                    end
                end else begin
                    // Manual entry starts the independent MUS playlist at 0001.
                    manual_track_index <= 5'd0;
                    manual_miss_count  <= 6'd0;
                    o_audio_select_music <= 1'b1;
                    if (i_music_count != 6'd0) begin
                        o_audio_open_index <= 5'd0;
                        o_audio_open_req   <= 1'b1;
                        track_pending      <= 1'b1;
                    end
                end
            end else if (policy_change) begin
                // SW1 changed while already in auto mode: restart the paired
                // track using the newly selected AUD/MUS policy.
                track_pending <= 1'b0;
                track_active  <= 1'b0;
                o_audio_flush <= 1'b1;
                o_audio_select_music <= i_auto_wait_audio;
                if (auto_track_present) begin
                    o_audio_open_index <= i_image_index;
                    o_audio_open_req   <= 1'b1;
                    track_pending      <= 1'b1;
                end else if (i_auto_wait_audio) begin
                    o_next_image_pulse <= 1'b1;
                end
            end else if (i_auto_mode && auto_image_commit) begin
                // New committed image: open its paired AUD or MUS file.
                track_pending <= 1'b0;
                track_active  <= 1'b0;
                o_audio_flush <= 1'b1;
                o_audio_select_music <= i_auto_wait_audio;
                if (auto_track_present) begin
                    o_audio_open_index <= i_image_index;
                    o_audio_open_req   <= 1'b1;
                    track_pending      <= 1'b1;
                end else if (i_auto_wait_audio) begin
                    o_next_image_pulse <= 1'b1;
                end
            end else if (i_audio_file_start && track_pending) begin
                track_pending <= 1'b0;
                track_active  <= 1'b1;
            end else if (i_audio_open_miss && track_pending) begin
                track_pending <= 1'b0;
                track_active  <= 1'b0;

                if (!i_auto_mode) begin
                    // Skip a missing MUS entry. Stop after one complete pass
                    // of consecutive misses instead of issuing requests forever.
                    if ((i_music_count > 6'd1) &&
                        ((manual_miss_count + 6'd1) < i_music_count)) begin
                        manual_miss_count  <= manual_miss_count + 6'd1;
                        manual_track_index <= manual_next_index;
                        o_audio_select_music <= 1'b1;
                        o_audio_open_index <= manual_next_index;
                        o_audio_open_req   <= 1'b1;
                        o_audio_flush      <= 1'b1;
                        track_pending      <= 1'b1;
                    end
                end else if (i_auto_wait_audio) begin
                    // In variable mode, a missing paired MUS is equivalent to
                    // a completed item so the image playlist can continue.
                    o_next_image_pulse <= 1'b1;
                end
            end else if (i_playback_done && track_active) begin
                track_active <= 1'b0;

                if (!i_auto_mode) begin
                    // Manual mode: advance MUS playlist only; never change PIC.
                    manual_miss_count <= 6'd0;
                    if (i_music_count != 6'd0) begin
                        manual_track_index <= manual_next_index;
                        o_audio_select_music <= 1'b1;
                        o_audio_open_index <= manual_next_index;
                        o_audio_open_req   <= 1'b1;
                        o_audio_flush      <= 1'b1;
                        track_pending      <= 1'b1;
                    end
                end else if (i_auto_wait_audio) begin
                    // Variable-duration auto mode advances after true PCM EOF.
                    o_next_image_pulse <= 1'b1;
                end
                // Timed auto mode deliberately ignores AUD EOF; its 8-second
                // timer in QHMU_IMAGE_MANAGER owns image advancement.
            end else if (wav_error_rise && track_active) begin
                track_active <= 1'b0;

                if (!i_auto_mode) begin
                    if ((i_music_count > 6'd1) &&
                        ((manual_miss_count + 6'd1) < i_music_count)) begin
                        manual_miss_count  <= manual_miss_count + 6'd1;
                        manual_track_index <= manual_next_index;
                        o_audio_select_music <= 1'b1;
                        o_audio_open_index <= manual_next_index;
                        o_audio_open_req   <= 1'b1;
                        o_audio_flush      <= 1'b1;
                        track_pending      <= 1'b1;
                    end
                end else if (i_auto_wait_audio) begin
                    o_next_image_pulse <= 1'b1;
                end
            end
        end
    end
endmodule
