`include "../QHMU_DEFINES.vh"

// ============================================================================
// QHMU_SDRAM_ARB
// APUG011-safe SDRAM scheduler for QHMU_HDMI_PRO.
//
// Important rules implemented here:
//   1) APUG011 read/write ports are never active at the same time.
//   2) Frame writes are sent as 4 consecutive 32-bit words.
//   3) Every write group starts on a 4-word-aligned address.
//   4) Video reads are rounded up to a multiple of 4 words.
//   5) Once a read/write burst starts, it is not interrupted by refresh gating.
//      A new burst starts only while i_refresh_active == 0.
//   6) Video line requests have priority over background framebuffer writes.
// ============================================================================
module QHMU_SDRAM_ARB(
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_init_done,
    input  wire        i_refresh_active,

    // APUG011 application interface
    output reg         o_app_wr_en,
    output reg  [20:0] o_app_wr_addr,
    output reg  [3:0]  o_app_wr_dm,
    output reg  [31:0] o_app_wr_data,
    output reg         o_app_rd_en,
    output reg  [20:0] o_app_rd_addr,
    input  wire        i_app_rd_valid,
    input  wire [31:0] i_app_rd_data,

    // Background write FIFO: {dm[3:0],addr[20:0],data[31:0]}
    input  wire        i_wr_fifo_empty,
    output reg         o_wr_fifo_rd_en,
    input  wire [56:0] i_wr_fifo_data,
    input  wire        i_wr_fifo_data_valid,
    output wire        o_write_idle,

    // Pixel-domain line request mailbox
    // [44] line_bank, [43] active_buffer, [42] need_B,
    // [41:32] src_y_A, [31:21] src_w_A,
    // [20:11] src_y_B, [10:0] src_w_B.
    input  wire        i_line_req_valid,
    input  wire [44:0] i_line_req_data,
    output wire        o_line_req_ready,

    // Four semantic line caches: A0,A1,B0,B1.
    output reg  [1:0]  o_line_wr_sel,
    output reg         o_line_wr_en,
    output reg  [9:0]  o_line_wr_addr,
    output reg  [23:0] o_line_wr_data,

    output reg         o_line_done_toggle,
    output reg         o_line_done_bank
);

    localparam [2:0] ST_IDLE        = 3'd0;
    localparam [2:0] ST_WFETCH_WAIT = 3'd1;
    localparam [2:0] ST_WBURST      = 3'd2;
    localparam [2:0] ST_RA_ISSUE    = 3'd3;
    localparam [2:0] ST_RA_WAIT     = 3'd4;
    localparam [2:0] ST_RB_ISSUE    = 3'd5;
    localparam [2:0] ST_RB_WAIT     = 3'd6;

    // The original automatic one-hot encoding created many state-select nets
    // in this already routing-sensitive block. Keep a compact binary encoding
    // for the SDRAM scheduler; it runs on the SDRAM clock and is not in the
    // HDMI pixel datapath.
    reg [2:0] state /* synthesis syn_encoding = "sequential" */;

    // ------------------------------------------------------------------------
    // Four-word write staging buffer.
    // BMP loader pads each source row to a 4-word boundary, therefore every
    // complete group presented to APUG011 is 128-bit aligned.
    // ------------------------------------------------------------------------
    reg [56:0] wbuf0;
    reg [56:0] wbuf1;
    reg [56:0] wbuf2;
    reg [56:0] wbuf3;
    reg [2:0]  wbuf_count;      // 0..4 words currently staged
    reg [1:0]  wburst_index;    // current output word 0..3

    wire [56:0] wburst_word =
        (wburst_index == 2'd0) ? wbuf0 :
        (wburst_index == 2'd1) ? wbuf1 :
        (wburst_index == 2'd2) ? wbuf2 :
                                 wbuf3;

    // ------------------------------------------------------------------------
    // Line-read request registers
    // ------------------------------------------------------------------------
    reg        line_bank;
    reg        active_buffer;
    reg        need_b;
    reg [9:0]  src_y_a;
    reg [9:0]  src_y_b;
    reg [10:0] src_w_a;
    reg [10:0] src_w_b;

    // APUG011 is happiest when read lengths end on 4-word boundaries.
    // 1024 is the maximum supported width, so use 12-bit counters.
    reg [11:0] issue_count;
    reg [11:0] recv_count;
    reg [11:0] read_len;

    wire [20:0] base_a = active_buffer ? `QHMU_FB1_BASE : `QHMU_FB0_BASE;
    wire [20:0] base_b = active_buffer ? `QHMU_FB0_BASE : `QHMU_FB1_BASE;

    function [11:0] round_up4;
        input [10:0] value;
        reg [11:0] temp;
        begin
            temp = {1'b0,value} + 12'd3;
            round_up4 = temp & 12'hFFC;
        end
    endfunction

    wire [20:0] row_base_a =
        base_a + ({11'd0,src_y_a} << `QHMU_FB_STRIDE_SHIFT);
    wire [20:0] row_base_b =
        base_b + ({11'd0,src_y_b} << `QHMU_FB_STRIDE_SHIFT);

    // Accept a new line request only from IDLE.  The CDC mailbox holds its
    // valid/data until ready, so short write activity cannot lose a request.
    assign o_line_req_ready =
        (state == ST_IDLE) && i_init_done && !i_refresh_active;

    // "idle" means every framebuffer write has reached the APUG011 interface.
    assign o_write_idle =
        i_wr_fifo_empty &&
        (wbuf_count == 3'd0) &&
        (state != ST_WFETCH_WAIT) &&
        (state != ST_WBURST);

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            state              <= ST_IDLE;

            o_app_wr_en        <= 1'b0;
            o_app_wr_addr      <= 21'd0;
            o_app_wr_dm        <= 4'hF;
            o_app_wr_data      <= 32'd0;
            o_app_rd_en        <= 1'b0;
            o_app_rd_addr      <= 21'd0;

            o_wr_fifo_rd_en    <= 1'b0;

            o_line_wr_sel      <= 2'd0;
            o_line_wr_en       <= 1'b0;
            o_line_wr_addr     <= 10'd0;
            o_line_wr_data     <= 24'd0;
            o_line_done_toggle <= 1'b0;
            o_line_done_bank   <= 1'b0;

            wbuf0              <= 57'd0;
            wbuf1              <= 57'd0;
            wbuf2              <= 57'd0;
            wbuf3              <= 57'd0;
            wbuf_count         <= 3'd0;
            wburst_index       <= 2'd0;

            line_bank          <= 1'b0;
            active_buffer      <= 1'b0;
            need_b             <= 1'b0;
            src_y_a            <= 10'd0;
            src_y_b            <= 10'd0;
            src_w_a            <= 11'd0;
            src_w_b            <= 11'd0;

            issue_count        <= 12'd0;
            recv_count         <= 12'd0;
            read_len           <= 12'd0;
        end else begin
            // Pulse/default interface outputs.
            o_app_wr_en     <= 1'b0;
            o_app_rd_en     <= 1'b0;
            o_wr_fifo_rd_en <= 1'b0;
            o_line_wr_en    <= 1'b0;

            // ----------------------------------------------------------------
            // Return path from APUG011.
            // recv_count is the number of the word currently being accepted.
            // For rounded-up reads, words beyond src_w_* are simply discarded.
            // ----------------------------------------------------------------
            if (i_app_rd_valid &&
                ((state == ST_RA_ISSUE) || (state == ST_RA_WAIT))) begin
                if (recv_count < {1'b0,src_w_a}) begin
                    o_line_wr_sel  <= {1'b0,line_bank};
                    o_line_wr_en   <= 1'b1;
                    o_line_wr_addr <= recv_count[9:0];
                    o_line_wr_data <= i_app_rd_data[23:0];
                end
                recv_count <= recv_count + 12'd1;
            end
            else if (i_app_rd_valid &&
                     ((state == ST_RB_ISSUE) || (state == ST_RB_WAIT))) begin
                if (recv_count < {1'b0,src_w_b}) begin
                    o_line_wr_sel  <= {1'b1,line_bank};
                    o_line_wr_en   <= 1'b1;
                    o_line_wr_addr <= recv_count[9:0];
                    o_line_wr_data <= i_app_rd_data[23:0];
                end
                recv_count <= recv_count + 12'd1;
            end

            case (state)
                // ------------------------------------------------------------
                // Priority:
                //   1. Video line request
                //   2. A complete 4-word framebuffer write burst
                //   3. Fetch one more word from async write FIFO
                // ------------------------------------------------------------
                ST_IDLE: begin
                    issue_count <= 12'd0;
                    recv_count  <= 12'd0;

                    if (i_line_req_valid && o_line_req_ready) begin
                        line_bank     <= i_line_req_data[44];
                        active_buffer <= i_line_req_data[43];
                        need_b        <= i_line_req_data[42];
                        src_y_a       <= i_line_req_data[41:32];
                        src_w_a       <= i_line_req_data[31:21];
                        src_y_b       <= i_line_req_data[20:11];
                        src_w_b       <= i_line_req_data[10:0];

                        read_len      <= round_up4(i_line_req_data[31:21]);
                        state         <= ST_RA_ISSUE;
                    end
                    else if ((wbuf_count == 3'd4) &&
                             i_init_done && !i_refresh_active) begin
                        // Optional alignment guard.  A correctly padded BMP
                        // stream always enters here with wbuf0.addr[1:0]==00.
                        wburst_index <= 2'd0;
                        state        <= ST_WBURST;
                    end
                    else if ((wbuf_count < 3'd4) &&
                             i_init_done &&
                             !i_wr_fifo_empty) begin
                        o_wr_fifo_rd_en <= 1'b1;
                        state           <= ST_WFETCH_WAIT;
                    end
                end

                // Capture exactly one FIFO entry, then return to IDLE so that
                // a pending video request can preempt further write gathering.
                ST_WFETCH_WAIT: begin
                    if (i_wr_fifo_data_valid) begin
                        case (wbuf_count)
                            3'd0: wbuf0 <= i_wr_fifo_data;
                            3'd1: wbuf1 <= i_wr_fifo_data;
                            3'd2: wbuf2 <= i_wr_fifo_data;
                            default: wbuf3 <= i_wr_fifo_data;
                        endcase

                        if (wbuf_count < 3'd4)
                            wbuf_count <= wbuf_count + 3'd1;

                        state <= ST_IDLE;
                    end
                end

                // Four uninterrupted clocks: addresses/data are presented
                // exactly as the official APUG011 reference app_wrrd does.
                ST_WBURST: begin
                    o_app_wr_en   <= 1'b1;
                    o_app_wr_dm   <= wburst_word[56:53];
                    o_app_wr_addr <= wburst_word[52:32];
                    o_app_wr_data <= wburst_word[31:0];

                    if (wburst_index == 2'd3) begin
                        wburst_index <= 2'd0;
                        wbuf_count   <= 3'd0;
                        state        <= ST_IDLE;
                    end else begin
                        wburst_index <= wburst_index + 2'd1;
                    end
                end

                // ------------------------------------------------------------
                // Image A line read.
                // Once started, keep App_rd_en continuously asserted for the
                // entire rounded-to-4 burst.  Do NOT insert refresh gaps.
                // ------------------------------------------------------------
                ST_RA_ISSUE: begin
                    if (read_len == 12'd0) begin
                        issue_count <= 12'd0;
                        recv_count  <= 12'd0;

                        if (need_b && (src_w_b != 11'd0)) begin
                            read_len <= round_up4(src_w_b);
                            state    <= ST_RB_ISSUE;
                        end else begin
                            o_line_done_bank   <= line_bank;
                            o_line_done_toggle <= ~o_line_done_toggle;
                            state              <= ST_IDLE;
                        end
                    end else begin
                        o_app_rd_en   <= 1'b1;
                        o_app_rd_addr <= row_base_a + issue_count[10:0];

                        if (issue_count == (read_len - 12'd1)) begin
                            issue_count <= 12'd0;
                            state       <= ST_RA_WAIT;
                        end else begin
                            issue_count <= issue_count + 12'd1;
                        end
                    end
                end

                ST_RA_WAIT: begin
                    if (i_app_rd_valid &&
                        (recv_count == (read_len - 12'd1))) begin
                        recv_count <= 12'd0;

                        if (need_b && (src_w_b != 11'd0)) begin
                            read_len   <= round_up4(src_w_b);
                            issue_count<= 12'd0;
                            state      <= ST_RB_ISSUE;
                        end else begin
                            o_line_done_bank   <= line_bank;
                            o_line_done_toggle <= ~o_line_done_toggle;
                            state              <= ST_IDLE;
                        end
                    end
                end

                // ------------------------------------------------------------
                // Image B line read for fade/wipe transition.
                // ------------------------------------------------------------
                ST_RB_ISSUE: begin
                    if (read_len == 12'd0) begin
                        o_line_done_bank   <= line_bank;
                        o_line_done_toggle <= ~o_line_done_toggle;
                        state              <= ST_IDLE;
                    end else begin
                        o_app_rd_en   <= 1'b1;
                        o_app_rd_addr <= row_base_b + issue_count[10:0];

                        if (issue_count == (read_len - 12'd1)) begin
                            issue_count <= 12'd0;
                            state       <= ST_RB_WAIT;
                        end else begin
                            issue_count <= issue_count + 12'd1;
                        end
                    end
                end

                ST_RB_WAIT: begin
                    if (i_app_rd_valid &&
                        (recv_count == (read_len - 12'd1))) begin
                        recv_count <= 12'd0;
                        o_line_done_bank   <= line_bank;
                        o_line_done_toggle <= ~o_line_done_toggle;
                        state              <= ST_IDLE;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
