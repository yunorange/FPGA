`include "../QHMU_DEFINES.vh"

// ============================================================================
// QHMU_FAT32_READER
// QHMU_HDMI_PRO media reader
//
// Read-only FAT32 reader with four runtime streams sharing one SD block
// interface:
//   * Image stream   : PIC0001.BMP ... PIC0032.BMP
//   * Audio stream   : AUD0001.WAV ... AUD0032.WAV
//   * Subtitle stream: SUBTITLE.BIN (automatically looped)
//   * Font stream    : OSD_FONT.BIN (loaded once at startup)
//
// The directory slot is derived from the four decimal digits in the 8.3 short
// filename.  Therefore file order in the FAT directory no longer changes the
// image/audio pairing.
//
// Runtime scheduling:
//   - image and audio keep separate cluster/sector contexts;
//   - audio receives one sector after at most two image sectors;
//   - audio can throttle at sector boundaries through i_audio_stream_ready;
//   - image o_busy intentionally reports IMAGE activity only so the slideshow
//     may continue while audio is streaming.
//
// Supported volume assumptions are unchanged from the original project:
//   FAT32, 512-byte sectors, MBR-partitioned or super-floppy.
// ============================================================================
module QHMU_FAT32_READER #(
    parameter MAX_FILES = `QHMU_MAX_FILES
)(
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_sd_init_done,

    output reg         o_sd_read_req,
    output reg  [31:0] o_sd_read_lba,
    input  wire [7:0]  i_sd_data,
    input  wire        i_sd_data_valid,
    input  wire        i_sd_read_done,

    output reg         o_catalog_done,
    output reg  [5:0]  o_file_count,
    output reg  [5:0]  o_audio_count,       // AUDxxxx.WAV count
    output reg  [5:0]  o_music_count,       // MUSxxxx.WAV count
    output reg         o_fs_error,

    // Image/BMP stream.  Interface remains compatible with the old module.
    input  wire        i_open_req,
    input  wire [4:0]  i_open_index,
    output wire        o_busy,
    output reg         o_file_start,
    output reg  [31:0] o_file_size,
    output reg  [7:0]  o_file_data,
    output reg         o_file_data_valid,
    output reg         o_file_done,

    // Audio/WAV stream.
    input  wire        i_audio_open_req,
    input  wire [4:0]  i_audio_open_index,
    input  wire        i_audio_select_music, // 1=MUS, 0=AUD
    input  wire        i_audio_stream_ready,
    output wire        o_audio_busy,
    output reg         o_audio_file_start,
    output reg  [31:0] o_audio_file_size,
    output reg  [7:0]  o_audio_file_data,
    output reg         o_audio_file_data_valid,
    output reg         o_audio_file_done,
    output reg         o_audio_open_miss,    // one-cycle pulse when selected pair is absent

    // Fixed scrolling subtitle stream. SUBTITLE.BIN is opened automatically
    // after catalog scan and loops forever. Backpressure is sector-granular.
    input  wire        i_subtitle_stream_ready,
    output wire        o_subtitle_busy,
    output reg         o_subtitle_present,
    output reg         o_subtitle_file_start,
    output reg  [31:0] o_subtitle_file_size,
    output reg  [7:0]  o_subtitle_file_data,
    output reg         o_subtitle_file_data_valid,
    output reg         o_subtitle_file_done,

    // One-shot startup OSD font stream.
    output reg         o_font_present,
    output reg         o_font_file_start,
    output reg  [31:0] o_font_file_size,
    output reg  [7:0]  o_font_file_data,
    output reg         o_font_file_data_valid,
    output reg         o_font_file_done
);
    localparam S_WAIT_SD       = 5'd0;
    localparam S_BOOT_REQ      = 5'd1;
    localparam S_BOOT_DATA     = 5'd2;
    localparam S_BOOT_DECIDE   = 5'd3;
    localparam S_VBR_REQ       = 5'd4;
    localparam S_VBR_DATA      = 5'd5;
    localparam S_VBR_DONE      = 5'd6;
    localparam S_DIR_REQ       = 5'd7;
    localparam S_DIR_DATA      = 5'd8;
    localparam S_DIR_NEXT      = 5'd9;
    localparam S_CAT_FAT_REQ   = 5'd10;
    localparam S_CAT_FAT_DATA  = 5'd11;
    localparam S_CAT_FAT_DONE  = 5'd12;

    localparam S_RUN_IDLE      = 5'd16;
    localparam S_RUN_REQ       = 5'd17;
    localparam S_RUN_DATA      = 5'd18;
    localparam S_RUN_FINISH    = 5'd19;
    localparam S_RUN_IMG_OPEN  = 5'd20;
    localparam S_RUN_AUD_OPEN  = 5'd21;
    localparam S_ERROR         = 5'd31;

    localparam [1:0] STREAM_IMAGE    = 2'd0;
    localparam [1:0] STREAM_AUDIO    = 2'd1;
    localparam [1:0] STREAM_SUBTITLE = 2'd2;
    localparam [1:0] STREAM_FONT     = 2'd3;

    reg [4:0] state;
    reg [9:0] byte_index;

    // FAT32 BPB / volume geometry.
    reg [31:0] volume_lba;
    reg [31:0] partition_lba;
    reg [7:0]  mbr_partition_type;
    reg [15:0] bpb_bytes_per_sector;
    reg [7:0]  bpb_sectors_per_cluster;
    reg [15:0] bpb_reserved_sectors;
    reg [7:0]  bpb_num_fats;
    reg [31:0] bpb_fat_size;
    reg [31:0] bpb_root_cluster;
    reg [63:0] bpb_fs_type;
    reg [15:0] boot_signature;
    reg [31:0] first_fat_sector;
    reg [31:0] first_data_sector;

    // Separate PICxxxx.BMP, MUSxxxx.WAV and AUDxxxx.WAV catalogs.
    // The six catalog arrays are intentionally NOT reset.  Their contents are
    // qualified by the resettable valid bitmaps below.  They are written and
    // read in dedicated clock-only processes (no asynchronous reset), allowing
    // TD to infer embedded RAM instead of thousands of resettable flip-flops.
    reg [31:0] image_cluster [0:MAX_FILES-1];
    reg [31:0] image_bytes   [0:MAX_FILES-1];
    reg [31:0] audio_cluster [0:MAX_FILES-1]; // AUD catalog
    reg [31:0] audio_bytes   [0:MAX_FILES-1];
    reg [31:0] music_cluster [0:MAX_FILES-1]; // MUS catalog
    reg [31:0] music_bytes   [0:MAX_FILES-1];

    // Registered RAM read data.  These registers are not reset; an open state
    // can only consume them after the matching valid bit has been checked.
    reg [31:0] img_catalog_cluster_q;
    reg [31:0] img_catalog_bytes_q;
    reg [31:0] aud_catalog_cluster_q;
    reg [31:0] aud_catalog_bytes_q;

    reg [MAX_FILES-1:0] image_valid;
    reg [MAX_FILES-1:0] audio_valid;
    reg [MAX_FILES-1:0] music_valid;

    reg [31:0] subtitle_cluster;
    reg [31:0] subtitle_bytes;
    reg        subtitle_valid;

    // One-shot OSD font file catalog/context.
    reg [31:0] font_cluster;
    reg [31:0] font_bytes;
    reg        font_valid;
    reg        font_loaded;
    reg        font_active;
    reg        font_need_fat;
    reg [31:0] font_cluster_cur;
    reg [7:0]  font_sector_in_cluster;
    reg [31:0] font_bytes_remaining;

    // Root-directory scanner.
    reg [31:0] dir_cluster;
    reg [7:0]  dir_sector_in_cluster;
    reg        dir_end_seen;

    reg [7:0]  entry_name0;
    reg [7:0]  entry_name1;
    reg [7:0]  entry_name2;
    reg [7:0]  entry_name3;
    reg [7:0]  entry_name4;
    reg [7:0]  entry_name5;
    reg [7:0]  entry_name6;
    reg [7:0]  entry_name7;
    reg [7:0]  entry_first;
    reg [7:0]  entry_attr;
    reg [7:0]  entry_ext0;
    reg [7:0]  entry_ext1;
    reg [7:0]  entry_ext2;
    reg [15:0] entry_cluster_hi;
    reg [15:0] entry_cluster_lo;
    reg [31:0] entry_size;

    // Directory-cluster FAT lookup.
    reg [31:0] cat_fat_query_cluster;
    reg [8:0]  cat_fat_entry_offset;
    reg [31:0] cat_fat_next_cluster;

    // Independent runtime image stream context.
    reg        img_active;
    reg        img_need_fat;
    reg [31:0] img_cluster;
    reg [7:0]  img_sector_in_cluster;
    reg [31:0] img_bytes_remaining;
    reg        img_open_pending;
    reg [4:0]  img_pending_index;

    // Independent runtime audio stream context.
    reg        aud_active;
    reg        aud_need_fat;
    reg [31:0] aud_cluster;
    reg [7:0]  aud_sector_in_cluster;
    reg [31:0] aud_bytes_remaining;
    reg        aud_open_pending;
    reg [4:0]  aud_pending_index;
    reg        aud_pending_music;

    // Automatically-looped subtitle context.
    reg        sub_active;
    reg        sub_need_fat;
    reg [31:0] sub_cluster;
    reg [7:0]  sub_sector_in_cluster;
    reg [31:0] sub_bytes_remaining;

    // Current physical SD sector transaction.
    reg [1:0]  run_stream;
    reg        run_is_fat;
    reg [8:0]  run_fat_entry_offset;
    reg [31:0] run_fat_next_cluster;
    reg [1:0]  image_sectors_since_audio;


    function [31:0] cluster_lba;
        input [31:0] cluster_num;
        begin
            cluster_lba = first_data_sector +
                          ((cluster_num - 32'd2) * bpb_sectors_per_cluster);
        end
    endfunction

    function is_digit;
        input [7:0] c;
        begin
            is_digit = (c >= "0") && (c <= "9");
        end
    endfunction

    // PIC0001 / MUS0001 / AUD0001 -> slot 0.  6'h3F means invalid/out of range.
    function [5:0] media_slot;
        input [7:0] d0;
        input [7:0] d1;
        input [7:0] d2;
        input [7:0] d3;
        reg [3:0] tens;
        reg [3:0] ones;
        reg [6:0] n;
        begin
            media_slot = 6'h3F;
            // This project uses 0001..0032. Restricting the first two
            // digits to zero avoids a general 4-digit decimal multiplier.
            if ((d0 == "0") && (d1 == "0") && is_digit(d2) && is_digit(d3)) begin
                tens = d2 - "0";
                ones = d3 - "0";
                n = ({3'd0,tens} << 3) + ({3'd0,tens} << 1) + {3'd0,ones};
                if ((n >= 7'd1) && (n <= MAX_FILES))
                    media_slot = n[5:0] - 6'd1;
            end
        end
    endfunction

    wire [5:0] entry_slot = media_slot(entry_name3, entry_name4,
                                       entry_name5, entry_name6);

    wire entry_is_pic =
        (entry_name0 == "P") && (entry_name1 == "I") &&
        (entry_name2 == "C") &&
        (entry_ext0 == "B") && (entry_ext1 == "M") &&
        (entry_ext2 == "P");

    wire entry_is_aud =
        (entry_name0 == "A") && (entry_name1 == "U") &&
        (entry_name2 == "D") &&
        (entry_ext0 == "W") && (entry_ext1 == "A") &&
        (entry_ext2 == "V");

    wire entry_is_mus =
        (entry_name0 == "M") && (entry_name1 == "U") &&
        (entry_name2 == "S") &&
        (entry_ext0 == "W") && (entry_ext1 == "A") &&
        (entry_ext2 == "V");

    wire entry_is_sub =
        (entry_name0 == "S") && (entry_name1 == "U") &&
        (entry_name2 == "B") && (entry_name3 == "T") &&
        (entry_name4 == "I") && (entry_name5 == "T") &&
        (entry_name6 == "L") && (entry_name7 == "E") &&
        (entry_ext0 == "B") && (entry_ext1 == "I") &&
        (entry_ext2 == "N");

    wire entry_is_font =
        (entry_name0 == "O") && (entry_name1 == "S") &&
        (entry_name2 == "D") && (entry_name3 == "_") &&
        (entry_name4 == "F") && (entry_name5 == "O") &&
        (entry_name6 == "N") && (entry_name7 == "T") &&
        (entry_ext0 == "B") && (entry_ext1 == "I") &&
        (entry_ext2 == "N");

    // MBR partition types: FAT32 CHS/LBA and hidden FAT32 variants.
    // The target card uses type 0x0C (FAT32 LBA), start LBA 16.
    wire mbr_fat32_partition_type =
        (mbr_partition_type == 8'h0B) || (mbr_partition_type == 8'h0C) ||
        (mbr_partition_type == 8'h1B) || (mbr_partition_type == 8'h1C);

    wire boot_looks_like_fat32 =
        (bpb_bytes_per_sector == 16'd512) &&
        (bpb_sectors_per_cluster != 8'd0) &&
        (bpb_reserved_sectors != 16'd0) &&
        (bpb_num_fats != 8'd0) &&
        (bpb_fat_size != 32'd0) &&
        (bpb_fs_type == 64'h4641543332202020); // "FAT32   "

    // IMPORTANT: image manager must not be blocked merely because audio is
    // active.  It only needs to know whether the image stream is occupied.
    assign o_busy          = !o_catalog_done || img_active || img_open_pending ||
                             (state == S_RUN_IMG_OPEN);
    assign o_audio_busy    = aud_active || aud_open_pending ||
                             (state == S_RUN_AUD_OPEN);
    assign o_subtitle_busy = sub_active;

    // A directory entry is committed when byte 31 arrives.  The directory
    // scanner has already captured the short name, attributes, start cluster,
    // and lower 24 bits of file size in the preceding byte cycles.
    wire media_dir_entry_valid =
        (state == S_DIR_DATA) && i_sd_data_valid &&
        (byte_index[4:0] == 5'd31) &&
        (entry_first != 8'h00) && (entry_first != 8'hE5) &&
        (entry_attr != 8'h0F) && ((entry_attr & 8'h18) == 8'h00) &&
        (entry_slot != 6'h3F);

    // Separate clock-only write process: this coding style is important for
    // Anlogic TD RAM inference.  Do not move these writes back into the
    // asynchronous-reset state-machine process.
    always @(posedge i_clk) begin
        if (!i_rst && media_dir_entry_valid) begin
            if (entry_is_pic && !image_valid[entry_slot[4:0]]) begin
                image_cluster[entry_slot[4:0]] <=
                    {entry_cluster_hi, entry_cluster_lo};
                image_bytes[entry_slot[4:0]] <=
                    {i_sd_data, entry_size[23:0]};
            end

            if (entry_is_aud && !audio_valid[entry_slot[4:0]]) begin
                audio_cluster[entry_slot[4:0]] <=
                    {entry_cluster_hi, entry_cluster_lo};
                audio_bytes[entry_slot[4:0]] <=
                    {i_sd_data, entry_size[23:0]};
            end

            if (entry_is_mus && !music_valid[entry_slot[4:0]]) begin
                music_cluster[entry_slot[4:0]] <=
                    {entry_cluster_hi, entry_cluster_lo};
                music_bytes[entry_slot[4:0]] <=
                    {i_sd_data, entry_size[23:0]};
            end
        end
    end

    // Synchronous RAM read ports.  The state machine checks the valid bitmap
    // and enters an OPEN state on the same edge that this process captures the
    // selected catalog row.  The OPEN state consumes the registered data one
    // clock later, matching embedded-RAM read latency.
    always @(posedge i_clk) begin
        if ((state == S_RUN_IDLE) && img_open_pending &&
            (img_pending_index < MAX_FILES) &&
            image_valid[img_pending_index]) begin
            img_catalog_cluster_q <= image_cluster[img_pending_index];
            img_catalog_bytes_q   <= image_bytes[img_pending_index];
        end

        if ((state == S_RUN_IDLE) && aud_open_pending &&
            (aud_pending_index < MAX_FILES)) begin
            if (aud_pending_music && music_valid[aud_pending_index]) begin
                aud_catalog_cluster_q <= music_cluster[aud_pending_index];
                aud_catalog_bytes_q   <= music_bytes[aud_pending_index];
            end else if (!aud_pending_music && audio_valid[aud_pending_index]) begin
                aud_catalog_cluster_q <= audio_cluster[aud_pending_index];
                aud_catalog_bytes_q   <= audio_bytes[aud_pending_index];
            end
        end
    end

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            state                   <= S_WAIT_SD;
            o_sd_read_req           <= 1'b0;
            o_sd_read_lba           <= 32'd0;
            o_catalog_done          <= 1'b0;
            o_file_count            <= 6'd0;
            o_audio_count           <= 6'd0;
            o_music_count           <= 6'd0;
            o_fs_error              <= 1'b0;
            o_file_start            <= 1'b0;
            o_file_size             <= 32'd0;
            o_file_data             <= 8'd0;
            o_file_data_valid       <= 1'b0;
            o_file_done             <= 1'b0;
            o_audio_file_start      <= 1'b0;
            o_audio_file_size       <= 32'd0;
            o_audio_file_data       <= 8'd0;
            o_audio_file_data_valid <= 1'b0;
            o_audio_file_done       <= 1'b0;
            o_audio_open_miss       <= 1'b0;
            o_subtitle_present      <= 1'b0;
            o_subtitle_file_start   <= 1'b0;
            o_subtitle_file_size    <= 32'd0;
            o_subtitle_file_data    <= 8'd0;
            o_subtitle_file_data_valid <= 1'b0;
            o_subtitle_file_done    <= 1'b0;
            o_font_present          <= 1'b0;
            o_font_file_start       <= 1'b0;
            o_font_file_size        <= 32'd0;
            o_font_file_data        <= 8'd0;
            o_font_file_data_valid  <= 1'b0;
            o_font_file_done        <= 1'b0;

            byte_index              <= 10'd0;
            volume_lba              <= 32'd0;
            partition_lba           <= 32'd0;
            mbr_partition_type      <= 8'd0;
            bpb_bytes_per_sector    <= 16'd0;
            bpb_sectors_per_cluster <= 8'd0;
            bpb_reserved_sectors    <= 16'd0;
            bpb_num_fats            <= 8'd0;
            bpb_fat_size            <= 32'd0;
            bpb_root_cluster        <= 32'd2;
            bpb_fs_type             <= 64'd0;
            boot_signature          <= 16'd0;
            first_fat_sector        <= 32'd0;
            first_data_sector       <= 32'd0;

            image_valid             <= {MAX_FILES{1'b0}};
            audio_valid             <= {MAX_FILES{1'b0}};
            music_valid             <= {MAX_FILES{1'b0}};
            subtitle_cluster         <= 32'd0;
            subtitle_bytes           <= 32'd0;
            subtitle_valid           <= 1'b0;
            font_cluster             <= 32'd0;
            font_bytes               <= 32'd0;
            font_valid               <= 1'b0;
            font_loaded              <= 1'b0;
            font_active              <= 1'b0;
            font_need_fat            <= 1'b0;
            font_cluster_cur         <= 32'd0;
            font_sector_in_cluster   <= 8'd0;
            font_bytes_remaining     <= 32'd0;
            dir_cluster             <= 32'd2;
            dir_sector_in_cluster   <= 8'd0;
            dir_end_seen            <= 1'b0;

            entry_name0             <= 8'd0;
            entry_name1             <= 8'd0;
            entry_name2             <= 8'd0;
            entry_name3             <= 8'd0;
            entry_name4             <= 8'd0;
            entry_name5             <= 8'd0;
            entry_name6             <= 8'd0;
            entry_name7             <= 8'd0;
            entry_first             <= 8'd0;
            entry_attr              <= 8'd0;
            entry_ext0              <= 8'd0;
            entry_ext1              <= 8'd0;
            entry_ext2              <= 8'd0;
            entry_cluster_hi        <= 16'd0;
            entry_cluster_lo        <= 16'd0;
            entry_size              <= 32'd0;

            cat_fat_query_cluster   <= 32'd0;
            cat_fat_entry_offset    <= 9'd0;
            cat_fat_next_cluster    <= 32'd0;

            img_active              <= 1'b0;
            img_need_fat            <= 1'b0;
            img_cluster             <= 32'd0;
            img_sector_in_cluster   <= 8'd0;
            img_bytes_remaining     <= 32'd0;
            img_open_pending        <= 1'b0;
            img_pending_index       <= 5'd0;

            aud_active              <= 1'b0;
            aud_need_fat            <= 1'b0;
            aud_cluster             <= 32'd0;
            aud_sector_in_cluster   <= 8'd0;
            aud_bytes_remaining     <= 32'd0;
            aud_open_pending        <= 1'b0;
            aud_pending_index       <= 5'd0;
            aud_pending_music       <= 1'b0;

            sub_active              <= 1'b0;
            sub_need_fat            <= 1'b0;
            sub_cluster             <= 32'd0;
            sub_sector_in_cluster   <= 8'd0;
            sub_bytes_remaining     <= 32'd0;

            run_stream              <= STREAM_IMAGE;
            run_is_fat              <= 1'b0;
            run_fat_entry_offset    <= 9'd0;
            run_fat_next_cluster    <= 32'd0;
            image_sectors_since_audio <= 2'd0;

            // Catalog RAM contents are intentionally left untouched on reset.
        end else begin
            // Default pulse outputs.
            o_sd_read_req           <= 1'b0;
            o_file_start            <= 1'b0;
            o_file_data_valid       <= 1'b0;
            o_file_done             <= 1'b0;
            o_audio_file_start      <= 1'b0;
            o_audio_file_data_valid <= 1'b0;
            o_audio_file_done       <= 1'b0;
            o_audio_open_miss       <= 1'b0;
            o_subtitle_file_start      <= 1'b0;
            o_subtitle_file_data_valid <= 1'b0;
            o_subtitle_file_done       <= 1'b0;
            o_font_file_start          <= 1'b0;
            o_font_file_data_valid     <= 1'b0;
            o_font_file_done           <= 1'b0;

            // Runtime open requests are latched so that a one-cycle request is
            // never lost while the SD controller is finishing another sector.
            if (o_catalog_done && i_open_req && !img_active && !img_open_pending) begin
                img_open_pending  <= 1'b1;
                img_pending_index <= i_open_index;
            end

            // Audio open means "switch/restart track".  A new request replaces
            // the old audio context at the next sector boundary.
            if (o_catalog_done && i_audio_open_req) begin
                aud_open_pending  <= 1'b1;
                aud_pending_index <= i_audio_open_index;
                aud_pending_music <= i_audio_select_music;
            end

            case (state)
                S_WAIT_SD: begin
                    if (i_sd_init_done)
                        state <= S_BOOT_REQ;
                end

                S_BOOT_REQ: begin
                    o_sd_read_lba <= 32'd0;
                    o_sd_read_req <= 1'b1;
                    byte_index <= 10'd0;
                    bpb_bytes_per_sector    <= 16'd0;
                    bpb_sectors_per_cluster <= 8'd0;
                    bpb_reserved_sectors    <= 16'd0;
                    bpb_num_fats            <= 8'd0;
                    bpb_fat_size            <= 32'd0;
                    bpb_root_cluster        <= 32'd0;
                    bpb_fs_type             <= 64'd0;
                    boot_signature          <= 16'd0;
                    partition_lba           <= 32'd0;
                    mbr_partition_type      <= 8'd0;
                    state <= S_BOOT_DATA;
                end

                S_BOOT_DATA: begin
                    if (i_sd_data_valid) begin
                        case (byte_index)
                            10'd11: bpb_bytes_per_sector[7:0]  <= i_sd_data;
                            10'd12: bpb_bytes_per_sector[15:8] <= i_sd_data;
                            10'd13: bpb_sectors_per_cluster    <= i_sd_data;
                            10'd14: bpb_reserved_sectors[7:0]  <= i_sd_data;
                            10'd15: bpb_reserved_sectors[15:8] <= i_sd_data;
                            10'd16: bpb_num_fats               <= i_sd_data;
                            10'd36: bpb_fat_size[7:0]          <= i_sd_data;
                            10'd37: bpb_fat_size[15:8]         <= i_sd_data;
                            10'd38: bpb_fat_size[23:16]        <= i_sd_data;
                            10'd39: bpb_fat_size[31:24]        <= i_sd_data;
                            10'd44: bpb_root_cluster[7:0]      <= i_sd_data;
                            10'd45: bpb_root_cluster[15:8]     <= i_sd_data;
                            10'd46: bpb_root_cluster[23:16]    <= i_sd_data;
                            10'd47: bpb_root_cluster[31:24]    <= i_sd_data;
                            10'd82: bpb_fs_type[63:56]         <= i_sd_data;
                            10'd83: bpb_fs_type[55:48]         <= i_sd_data;
                            10'd84: bpb_fs_type[47:40]         <= i_sd_data;
                            10'd85: bpb_fs_type[39:32]         <= i_sd_data;
                            10'd86: bpb_fs_type[31:24]         <= i_sd_data;
                            10'd87: bpb_fs_type[23:16]         <= i_sd_data;
                            10'd88: bpb_fs_type[15:8]          <= i_sd_data;
                            10'd89: bpb_fs_type[7:0]           <= i_sd_data;
                            10'd450: mbr_partition_type       <= i_sd_data;
                            10'd454: partition_lba[7:0]        <= i_sd_data;
                            10'd455: partition_lba[15:8]       <= i_sd_data;
                            10'd456: partition_lba[23:16]      <= i_sd_data;
                            10'd457: partition_lba[31:24]      <= i_sd_data;
                            10'd510: boot_signature[7:0]       <= i_sd_data;
                            10'd511: boot_signature[15:8]      <= i_sd_data;
                            default: ;
                        endcase
                        byte_index <= byte_index + 1'b1;
                    end
                    if (i_sd_read_done)
                        state <= S_BOOT_DECIDE;
                end

                S_BOOT_DECIDE: begin
                    // IMPORTANT: check the MBR partition entry first. The MBR
                    // bootstrap area can coincidentally resemble FAT32 BPB
                    // fields; treating LBA 0 as a super-floppy then yields
                    // bogus geometry and the wrong root-directory LBA.
                    if ((boot_signature == 16'hAA55) &&
                        (partition_lba != 32'd0) &&
                        mbr_fat32_partition_type) begin
                        volume_lba <= partition_lba;
                        state <= S_VBR_REQ;
                    end else if ((boot_signature == 16'hAA55) &&
                                 boot_looks_like_fat32) begin
                        // Super-floppy FAT32 volume (no MBR partition entry).
                        volume_lba <= 32'd0;
                        state <= S_VBR_DONE;
                    end else begin
                        state <= S_ERROR;
                    end
                end

                S_VBR_REQ: begin
                    o_sd_read_lba <= volume_lba;
                    o_sd_read_req <= 1'b1;
                    byte_index <= 10'd0;
                    bpb_bytes_per_sector    <= 16'd0;
                    bpb_sectors_per_cluster <= 8'd0;
                    bpb_reserved_sectors    <= 16'd0;
                    bpb_num_fats            <= 8'd0;
                    bpb_fat_size            <= 32'd0;
                    bpb_root_cluster        <= 32'd0;
                    bpb_fs_type             <= 64'd0;
                    state <= S_VBR_DATA;
                end

                S_VBR_DATA: begin
                    if (i_sd_data_valid) begin
                        case (byte_index)
                            10'd11: bpb_bytes_per_sector[7:0]  <= i_sd_data;
                            10'd12: bpb_bytes_per_sector[15:8] <= i_sd_data;
                            10'd13: bpb_sectors_per_cluster    <= i_sd_data;
                            10'd14: bpb_reserved_sectors[7:0]  <= i_sd_data;
                            10'd15: bpb_reserved_sectors[15:8] <= i_sd_data;
                            10'd16: bpb_num_fats               <= i_sd_data;
                            10'd36: bpb_fat_size[7:0]          <= i_sd_data;
                            10'd37: bpb_fat_size[15:8]         <= i_sd_data;
                            10'd38: bpb_fat_size[23:16]        <= i_sd_data;
                            10'd39: bpb_fat_size[31:24]        <= i_sd_data;
                            10'd44: bpb_root_cluster[7:0]      <= i_sd_data;
                            10'd45: bpb_root_cluster[15:8]     <= i_sd_data;
                            10'd46: bpb_root_cluster[23:16]    <= i_sd_data;
                            10'd47: bpb_root_cluster[31:24]    <= i_sd_data;
                            10'd82: bpb_fs_type[63:56]         <= i_sd_data;
                            10'd83: bpb_fs_type[55:48]         <= i_sd_data;
                            10'd84: bpb_fs_type[47:40]         <= i_sd_data;
                            10'd85: bpb_fs_type[39:32]         <= i_sd_data;
                            10'd86: bpb_fs_type[31:24]         <= i_sd_data;
                            10'd87: bpb_fs_type[23:16]         <= i_sd_data;
                            10'd88: bpb_fs_type[15:8]          <= i_sd_data;
                            10'd89: bpb_fs_type[7:0]           <= i_sd_data;
                            default: ;
                        endcase
                        byte_index <= byte_index + 1'b1;
                    end
                    if (i_sd_read_done)
                        state <= S_VBR_DONE;
                end

                S_VBR_DONE: begin
                    if ((bpb_bytes_per_sector != 16'd512) ||
                        (bpb_sectors_per_cluster == 8'd0) ||
                        (bpb_reserved_sectors == 16'd0) ||
                        (bpb_num_fats == 8'd0) ||
                        (bpb_fat_size == 32'd0) ||
                        (bpb_root_cluster < 32'd2)) begin
                        state <= S_ERROR;
                    end else begin
                        first_fat_sector  <= volume_lba + bpb_reserved_sectors;
                        first_data_sector <= volume_lba + bpb_reserved_sectors +
                                             (bpb_num_fats * bpb_fat_size);
                        dir_cluster       <= bpb_root_cluster;
                        dir_sector_in_cluster <= 8'd0;
                        dir_end_seen      <= 1'b0;
                        o_file_count      <= 6'd0;
                        o_audio_count     <= 6'd0;
                        o_music_count     <= 6'd0;
                        image_valid       <= {MAX_FILES{1'b0}};
                        audio_valid       <= {MAX_FILES{1'b0}};
                        music_valid       <= {MAX_FILES{1'b0}};
                        subtitle_valid    <= 1'b0;
                        font_valid        <= 1'b0;
                        font_loaded       <= 1'b0;
                        o_subtitle_present<= 1'b0;
                        o_font_present    <= 1'b0;
                        state <= S_DIR_REQ;
                    end
                end

                S_DIR_REQ: begin
                    o_sd_read_lba <= cluster_lba(dir_cluster) +
                                     dir_sector_in_cluster;
                    o_sd_read_req <= 1'b1;
                    byte_index    <= 10'd0;
                    dir_end_seen  <= 1'b0;
                    state         <= S_DIR_DATA;
                end

                S_DIR_DATA: begin
                    if (i_sd_data_valid) begin
                        case (byte_index[4:0])
                            5'd0: begin
                                entry_name0 <= i_sd_data;
                                entry_first <= i_sd_data;
                            end
                            5'd1:  entry_name1 <= i_sd_data;
                            5'd2:  entry_name2 <= i_sd_data;
                            5'd3:  entry_name3 <= i_sd_data;
                            5'd4:  entry_name4 <= i_sd_data;
                            5'd5:  entry_name5 <= i_sd_data;
                            5'd6:  entry_name6 <= i_sd_data;
                            5'd7:  entry_name7 <= i_sd_data;
                            5'd8:  entry_ext0 <= i_sd_data;
                            5'd9:  entry_ext1 <= i_sd_data;
                            5'd10: entry_ext2 <= i_sd_data;
                            5'd11: entry_attr <= i_sd_data;
                            5'd20: entry_cluster_hi[7:0] <= i_sd_data;
                            5'd21: entry_cluster_hi[15:8] <= i_sd_data;
                            5'd26: entry_cluster_lo[7:0] <= i_sd_data;
                            5'd27: entry_cluster_lo[15:8] <= i_sd_data;
                            5'd28: entry_size[7:0] <= i_sd_data;
                            5'd29: entry_size[15:8] <= i_sd_data;
                            5'd30: entry_size[23:16] <= i_sd_data;
                            5'd31: begin
                                entry_size[31:24] <= i_sd_data;

                                if (entry_first == 8'h00) begin
                                    dir_end_seen <= 1'b1;
                                end else if ((entry_first != 8'hE5) &&
                                             (entry_attr != 8'h0F) &&
                                             ((entry_attr & 8'h18) == 8'h00)) begin
                                    if ((entry_slot != 6'h3F) && entry_is_pic &&
                                        !image_valid[entry_slot[4:0]]) begin
                                        image_valid[entry_slot[4:0]] <= 1'b1;
                                        if (o_file_count < MAX_FILES)
                                            o_file_count <= o_file_count + 1'b1;
                                    end

                                    if ((entry_slot != 6'h3F) && entry_is_aud &&
                                        !audio_valid[entry_slot[4:0]]) begin
                                        audio_valid[entry_slot[4:0]] <= 1'b1;
                                        if (o_audio_count < MAX_FILES)
                                            o_audio_count <= o_audio_count + 1'b1;
                                    end

                                    if ((entry_slot != 6'h3F) && entry_is_mus &&
                                        !music_valid[entry_slot[4:0]]) begin
                                        music_valid[entry_slot[4:0]] <= 1'b1;
                                        if (o_music_count < MAX_FILES)
                                            o_music_count <= o_music_count + 1'b1;
                                    end

                                    if (entry_is_sub && !subtitle_valid) begin
                                        subtitle_cluster <= {entry_cluster_hi,entry_cluster_lo};
                                        subtitle_bytes   <= {i_sd_data,entry_size[23:0]};
                                        subtitle_valid   <= 1'b1;
                                        o_subtitle_present <= 1'b1;
                                    end

                                    if (entry_is_font && !font_valid) begin
                                        font_cluster <= {entry_cluster_hi,entry_cluster_lo};
                                        font_bytes   <= {i_sd_data,entry_size[23:0]};
                                        font_valid   <= 1'b1;
                                        o_font_present <= 1'b1;
                                    end
                                end
                            end
                            default: ;
                        endcase
                        byte_index <= byte_index + 1'b1;
                    end

                    if (i_sd_read_done)
                        state <= S_DIR_NEXT;
                end

                S_DIR_NEXT: begin
                    if (dir_end_seen) begin
                        o_catalog_done <= 1'b1;
                        state <= S_RUN_IDLE;
                    end else if (dir_sector_in_cluster + 1'b1 <
                                 bpb_sectors_per_cluster) begin
                        dir_sector_in_cluster <= dir_sector_in_cluster + 1'b1;
                        state <= S_DIR_REQ;
                    end else begin
                        cat_fat_query_cluster <= dir_cluster;
                        state <= S_CAT_FAT_REQ;
                    end
                end

                S_CAT_FAT_REQ: begin
                    cat_fat_entry_offset <= {cat_fat_query_cluster[6:0],2'b00};
                    o_sd_read_lba <= first_fat_sector +
                                     (cat_fat_query_cluster >> 7);
                    o_sd_read_req <= 1'b1;
                    byte_index <= 10'd0;
                    cat_fat_next_cluster <= 32'd0;
                    state <= S_CAT_FAT_DATA;
                end

                S_CAT_FAT_DATA: begin
                    if (i_sd_data_valid) begin
                        if (byte_index == cat_fat_entry_offset)
                            cat_fat_next_cluster[7:0] <= i_sd_data;
                        else if (byte_index == cat_fat_entry_offset + 1'b1)
                            cat_fat_next_cluster[15:8] <= i_sd_data;
                        else if (byte_index == cat_fat_entry_offset + 2'd2)
                            cat_fat_next_cluster[23:16] <= i_sd_data;
                        else if (byte_index == cat_fat_entry_offset + 2'd3)
                            cat_fat_next_cluster[31:24] <= i_sd_data;
                        byte_index <= byte_index + 1'b1;
                    end
                    if (i_sd_read_done)
                        state <= S_CAT_FAT_DONE;
                end

                S_CAT_FAT_DONE: begin
                    if ((cat_fat_next_cluster & 32'h0FFFFFFF) >=
                        32'h0FFFFFF8) begin
                        o_catalog_done <= 1'b1;
                        state <= S_RUN_IDLE;
                    end else if ((cat_fat_next_cluster & 32'h0FFFFFFF) <
                                 32'd2) begin
                        state <= S_ERROR;
                    end else begin
                        dir_cluster <= cat_fat_next_cluster & 32'h0FFFFFFF;
                        dir_sector_in_cluster <= 8'd0;
                        state <= S_DIR_REQ;
                    end
                end

                // ------------------------------------------------------------
                // Runtime multi-stream scheduler.
                // ------------------------------------------------------------
                S_RUN_IDLE: begin
                    // Catalog RAM has a synchronous read latency.  Select the
                    // row here, then consume its registered data in OPEN state.
                    // User-requested image/audio opens retain the same priority.
                    if (img_open_pending) begin
                        img_open_pending <= 1'b0;
                        if ((img_pending_index < MAX_FILES) &&
                            image_valid[img_pending_index]) begin
                            state <= S_RUN_IMG_OPEN;
                        end
                    end
                    // A new audio request atomically replaces the old track at
                    // a sector boundary.
                    else if (aud_open_pending) begin
                        aud_open_pending <= 1'b0;
                        aud_active       <= 1'b0;
                        aud_need_fat     <= 1'b0;
                        if (aud_pending_index < MAX_FILES) begin
                            if ((aud_pending_music && music_valid[aud_pending_index]) ||
                                (!aud_pending_music && audio_valid[aud_pending_index])) begin
                                state <= S_RUN_AUD_OPEN;
                            end else begin
                                o_audio_open_miss <= 1'b1;
                            end
                        end else begin
                            o_audio_open_miss <= 1'b1;
                        end
                    end
                    // Load OSD_FONT.BIN once after the directory scan.
                    else if (!font_active && !font_loaded && font_valid) begin
                        font_active            <= 1'b1;
                        font_need_fat          <= 1'b0;
                        font_cluster_cur       <= font_cluster;
                        font_sector_in_cluster <= 8'd0;
                        font_bytes_remaining   <= font_bytes;
                        o_font_file_size       <= font_bytes;
                        o_font_file_start      <= 1'b1;
                    end
                    // Start/restart the one fixed subtitle file automatically.
                    else if (!sub_active && subtitle_valid) begin
                        sub_active            <= 1'b1;
                        sub_need_fat          <= 1'b0;
                        sub_cluster           <= subtitle_cluster;
                        sub_sector_in_cluster <= 8'd0;
                        sub_bytes_remaining   <= subtitle_bytes;
                        o_subtitle_file_size  <= subtitle_bytes;
                        o_subtitle_file_start <= 1'b1;
                    end
                    // Font is a short one-shot stream. Load it before background
                    // subtitle refresh, while image/audio opens retain priority.
                    else if (font_active && font_need_fat) begin
                        run_stream           <= STREAM_FONT;
                        run_is_fat           <= 1'b1;
                        run_fat_entry_offset <= {font_cluster_cur[6:0],2'b00};
                        run_fat_next_cluster <= 32'd0;
                        o_sd_read_lba        <= first_fat_sector + (font_cluster_cur >> 7);
                        state                <= S_RUN_REQ;
                    end
                    else if (font_active && !font_need_fat) begin
                        run_stream    <= STREAM_FONT;
                        run_is_fat    <= 1'b0;
                        o_sd_read_lba <= cluster_lba(font_cluster_cur) +
                                         font_sector_in_cluster;
                        state         <= S_RUN_REQ;
                    end
                    // Subtitle only asks for one sector every few seconds. Give
                    // that request priority so the bottom scanline sees a full
                    // replacement bank by the time it is displayed.
                    else if (sub_active && sub_need_fat && i_subtitle_stream_ready) begin
                        run_stream           <= STREAM_SUBTITLE;
                        run_is_fat           <= 1'b1;
                        run_fat_entry_offset <= {sub_cluster[6:0],2'b00};
                        run_fat_next_cluster <= 32'd0;
                        o_sd_read_lba        <= first_fat_sector + (sub_cluster >> 7);
                        state                <= S_RUN_REQ;
                    end
                    else if (sub_active && !sub_need_fat && i_subtitle_stream_ready) begin
                        run_stream    <= STREAM_SUBTITLE;
                        run_is_fat    <= 1'b0;
                        o_sd_read_lba <= cluster_lba(sub_cluster) + sub_sector_in_cluster;
                        state         <= S_RUN_REQ;
                    end
                    // Audio FAT lookup is time-critical once two image sectors
                    // have passed; otherwise image gets first use of the bus.
                    else if (aud_active && aud_need_fat &&
                             ((image_sectors_since_audio >= 2) || !img_active)) begin
                        run_stream           <= STREAM_AUDIO;
                        run_is_fat           <= 1'b1;
                        run_fat_entry_offset <= {aud_cluster[6:0],2'b00};
                        run_fat_next_cluster <= 32'd0;
                        o_sd_read_lba        <= first_fat_sector + (aud_cluster >> 7);
                        state                <= S_RUN_REQ;
                    end
                    else if (img_active && img_need_fat) begin
                        run_stream           <= STREAM_IMAGE;
                        run_is_fat           <= 1'b1;
                        run_fat_entry_offset <= {img_cluster[6:0],2'b00};
                        run_fat_next_cluster <= 32'd0;
                        o_sd_read_lba        <= first_fat_sector + (img_cluster >> 7);
                        state                <= S_RUN_REQ;
                    end
                    // Give audio one 512-byte sector after at most two image
                    // sectors.  This is comfortably above 192 kB/s for 48-kHz
                    // stereo 16-bit PCM at the project's SD SPI rate.
                    else if (aud_active && !aud_need_fat &&
                             i_audio_stream_ready &&
                             ((image_sectors_since_audio >= 2) || !img_active)) begin
                        run_stream    <= STREAM_AUDIO;
                        run_is_fat    <= 1'b0;
                        o_sd_read_lba <= cluster_lba(aud_cluster) +
                                         aud_sector_in_cluster;
                        state         <= S_RUN_REQ;
                    end
                    else if (img_active && !img_need_fat) begin
                        run_stream    <= STREAM_IMAGE;
                        run_is_fat    <= 1'b0;
                        o_sd_read_lba <= cluster_lba(img_cluster) +
                                         img_sector_in_cluster;
                        state         <= S_RUN_REQ;
                    end
                    else if (aud_active && aud_need_fat) begin
                        run_stream           <= STREAM_AUDIO;
                        run_is_fat           <= 1'b1;
                        run_fat_entry_offset <= {aud_cluster[6:0],2'b00};
                        run_fat_next_cluster <= 32'd0;
                        o_sd_read_lba        <= first_fat_sector + (aud_cluster >> 7);
                        state                <= S_RUN_REQ;
                    end
                    else if (aud_active && !aud_need_fat &&
                             i_audio_stream_ready) begin
                        run_stream    <= STREAM_AUDIO;
                        run_is_fat    <= 1'b0;
                        o_sd_read_lba <= cluster_lba(aud_cluster) +
                                         aud_sector_in_cluster;
                        state         <= S_RUN_REQ;
                    end
                end

                S_RUN_IMG_OPEN: begin
                    img_active            <= 1'b1;
                    img_need_fat          <= 1'b0;
                    img_cluster           <= img_catalog_cluster_q;
                    img_sector_in_cluster <= 8'd0;
                    img_bytes_remaining   <= img_catalog_bytes_q;
                    o_file_size           <= img_catalog_bytes_q;
                    o_file_start          <= 1'b1;
                    state                 <= S_RUN_IDLE;
                end

                S_RUN_AUD_OPEN: begin
                    aud_active            <= 1'b1;
                    aud_need_fat          <= 1'b0;
                    aud_cluster           <= aud_catalog_cluster_q;
                    aud_sector_in_cluster <= 8'd0;
                    aud_bytes_remaining   <= aud_catalog_bytes_q;
                    o_audio_file_size     <= aud_catalog_bytes_q;
                    o_audio_file_start    <= 1'b1;
                    state                 <= S_RUN_IDLE;
                end

                S_RUN_REQ: begin
                    o_sd_read_req <= 1'b1;
                    byte_index <= 10'd0;
                    state <= S_RUN_DATA;
                end

                S_RUN_DATA: begin
                    if (i_sd_data_valid) begin
                        if (run_is_fat) begin
                            if (byte_index == run_fat_entry_offset)
                                run_fat_next_cluster[7:0] <= i_sd_data;
                            else if (byte_index == run_fat_entry_offset + 1'b1)
                                run_fat_next_cluster[15:8] <= i_sd_data;
                            else if (byte_index == run_fat_entry_offset + 2'd2)
                                run_fat_next_cluster[23:16] <= i_sd_data;
                            else if (byte_index == run_fat_entry_offset + 2'd3)
                                run_fat_next_cluster[31:24] <= i_sd_data;
                        end else if (run_stream == STREAM_IMAGE) begin
                            if (img_bytes_remaining != 32'd0) begin
                                o_file_data       <= i_sd_data;
                                o_file_data_valid <= 1'b1;
                                img_bytes_remaining <= img_bytes_remaining - 1'b1;
                            end
                        end else if (run_stream == STREAM_AUDIO) begin
                            if ((aud_bytes_remaining != 32'd0) &&
                                !aud_open_pending) begin
                                o_audio_file_data       <= i_sd_data;
                                o_audio_file_data_valid <= 1'b1;
                                aud_bytes_remaining <= aud_bytes_remaining - 1'b1;
                            end
                        end else if (run_stream == STREAM_SUBTITLE) begin
                            if (sub_bytes_remaining != 32'd0) begin
                                o_subtitle_file_data       <= i_sd_data;
                                o_subtitle_file_data_valid <= 1'b1;
                                sub_bytes_remaining <= sub_bytes_remaining - 1'b1;
                            end
                        end else begin
                            if (font_bytes_remaining != 32'd0) begin
                                o_font_file_data       <= i_sd_data;
                                o_font_file_data_valid <= 1'b1;
                                font_bytes_remaining   <= font_bytes_remaining - 1'b1;
                            end
                        end
                        byte_index <= byte_index + 1'b1;
                    end

                    if (i_sd_read_done)
                        state <= S_RUN_FINISH;
                end

                S_RUN_FINISH: begin
                    if (run_is_fat) begin
                        if ((run_fat_next_cluster & 32'h0FFFFFFF) >=
                            32'h0FFFFFF8) begin
                            // End-of-chain before bytes_remaining reached zero
                            // indicates a truncated/corrupt file.
                            if (run_stream == STREAM_IMAGE) begin
                                img_active <= 1'b0;
                                o_file_done <= 1'b1;
                            end else if (run_stream == STREAM_AUDIO) begin
                                aud_active <= 1'b0;
                                o_audio_file_done <= 1'b1;
                            end else if (run_stream == STREAM_SUBTITLE) begin
                                sub_active <= 1'b0;
                                o_subtitle_file_done <= 1'b1;
                            end else begin
                                font_active <= 1'b0;
                                font_loaded <= 1'b1;
                                o_font_file_done <= 1'b1;
                            end
                        end else if ((run_fat_next_cluster & 32'h0FFFFFFF) <
                                     32'd2) begin
                            o_fs_error <= 1'b1;
                            if (run_stream == STREAM_IMAGE)
                                img_active <= 1'b0;
                            else if (run_stream == STREAM_AUDIO)
                                aud_active <= 1'b0;
                            else if (run_stream == STREAM_SUBTITLE)
                                sub_active <= 1'b0;
                            else begin
                                font_active <= 1'b0;
                                font_loaded <= 1'b1;
                                o_font_file_done <= 1'b1;
                            end
                        end else if (run_stream == STREAM_IMAGE) begin
                            img_cluster           <= run_fat_next_cluster & 32'h0FFFFFFF;
                            img_sector_in_cluster <= 8'd0;
                            img_need_fat          <= 1'b0;
                        end else if (run_stream == STREAM_AUDIO) begin
                            aud_cluster           <= run_fat_next_cluster & 32'h0FFFFFFF;
                            aud_sector_in_cluster <= 8'd0;
                            aud_need_fat          <= 1'b0;
                        end else if (run_stream == STREAM_SUBTITLE) begin
                            sub_cluster           <= run_fat_next_cluster & 32'h0FFFFFFF;
                            sub_sector_in_cluster <= 8'd0;
                            sub_need_fat          <= 1'b0;
                        end else begin
                            font_cluster_cur       <= run_fat_next_cluster & 32'h0FFFFFFF;
                            font_sector_in_cluster <= 8'd0;
                            font_need_fat          <= 1'b0;
                        end
                    end else if (run_stream == STREAM_IMAGE) begin
                        if (img_bytes_remaining == 32'd0) begin
                            img_active <= 1'b0;
                            o_file_done <= 1'b1;
                        end else if (img_sector_in_cluster + 1'b1 <
                                     bpb_sectors_per_cluster) begin
                            img_sector_in_cluster <= img_sector_in_cluster + 1'b1;
                        end else begin
                            img_need_fat <= 1'b1;
                        end

                        if (image_sectors_since_audio < 2)
                            image_sectors_since_audio <=
                                image_sectors_since_audio + 1'b1;
                    end else if (run_stream == STREAM_AUDIO) begin
                        if (aud_open_pending) begin
                            aud_active <= 1'b0;
                        end else if (aud_bytes_remaining == 32'd0) begin
                            aud_active <= 1'b0;
                            o_audio_file_done <= 1'b1;
                        end else if (aud_sector_in_cluster + 1'b1 <
                                     bpb_sectors_per_cluster) begin
                            aud_sector_in_cluster <= aud_sector_in_cluster + 1'b1;
                        end else begin
                            aud_need_fat <= 1'b1;
                        end
                        image_sectors_since_audio <= 2'd0;
                    end else if (run_stream == STREAM_SUBTITLE) begin
                        if (sub_bytes_remaining == 32'd0) begin
                            // Automatic restart is installed in S_RUN_IDLE.
                            sub_active <= 1'b0;
                            o_subtitle_file_done <= 1'b1;
                        end else if (sub_sector_in_cluster + 1'b1 <
                                     bpb_sectors_per_cluster) begin
                            sub_sector_in_cluster <= sub_sector_in_cluster + 1'b1;
                        end else begin
                            sub_need_fat <= 1'b1;
                        end
                    end else begin
                        if (font_bytes_remaining == 32'd0) begin
                            font_active <= 1'b0;
                            font_loaded <= 1'b1;
                            o_font_file_done <= 1'b1;
                        end else if (font_sector_in_cluster + 1'b1 <
                                     bpb_sectors_per_cluster) begin
                            font_sector_in_cluster <= font_sector_in_cluster + 1'b1;
                        end else begin
                            font_need_fat <= 1'b1;
                        end
                    end
                    state <= S_RUN_IDLE;
                end

                S_ERROR: begin
                    o_fs_error <= 1'b1;
                    img_active <= 1'b0;
                    aud_active <= 1'b0;
                    sub_active <= 1'b0;
                    font_active <= 1'b0;
                    state <= S_ERROR;
                end

                default: begin
                    state <= S_ERROR;
                end
            endcase
        end
    end
endmodule
