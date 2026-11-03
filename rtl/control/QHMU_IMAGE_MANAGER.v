// QHMU_IMAGE_MANAGER_TD_SAFE_V5_32MEDIA.v
// Conservative Verilog-2001 style for older Anlogic TD synthesis front ends.
// V4 adds TD-specific synthesis keep directives on explicit D nets.
// Design rules used here:
//   1. No encoded vector FSM. Five scalar one-hot state FFs are used.
//   2. Every sequential FF is assigned unconditionally from an explicit *_d net.
//   3. No inferred clock-enable is required in this module.
//   4. No asynchronous reset is inferred in this module. i_rst is already
//      synchronized to i_clk by QHMU_CLOCK_RESET/QHMU_RESET_SYNC.
//   5. No partial-bit sequential assignments are used.

module QHMU_IMAGE_MANAGER #(
    parameter CLK_HZ = 50_000_000,
    parameter AUTO_SECONDS = 8
)(
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_catalog_done,
    input  wire [5:0]  i_file_count,
    input  wire        i_fat_busy,
    input  wire        i_prev_pulse,
    input  wire        i_next_pulse,
    input  wire        i_auto_toggle_pulse,
    input  wire        i_audio_wait_mode,
    input  wire        i_audio_next_pulse,

    output wire        o_open_req,
    output wire [4:0]  o_open_index,
    output reg         o_load_target_buffer,

    input  wire        i_bmp_load_done,
    input  wire        i_bmp_load_error,
    input  wire [10:0] i_bmp_width,
    input  wire [9:0]  i_bmp_height,
    input  wire        i_sdram_write_idle,

    input  wire        i_active_buffer_sync,
    output wire        o_transition_start,
    input  wire        i_transition_done,

    output reg         o_display_valid,
    output reg         o_auto_mode,
    output reg  [4:0]  o_current_index,
    output reg  [1:0]  o_buffer_valid,
    output reg  [10:0] o_buf0_width,
    output reg  [9:0]  o_buf0_height,
    output reg  [10:0] o_buf1_width,
    output reg  [9:0]  o_buf1_height,
    output reg         o_error
);

    localparam integer AUTO_CYCLES = CLK_HZ * AUTO_SECONDS;
    localparam [28:0] AUTO_LIMIT = AUTO_CYCLES - 1;

    // --------------------------------------------------------------------
    // One-hot state registers
    // --------------------------------------------------------------------
    reg st_boot;
    reg st_idle;
    reg st_loading;
    reg st_drain;
    reg st_transition;

    reg [28:0] auto_cnt;
    reg [4:0]  pending_index;
    reg        first_image_loaded;

    // --------------------------------------------------------------------
    // Combinational status / events
    // --------------------------------------------------------------------
    wire can_request;
    wire state_valid;
    wire auto_timeout;
    wire idle_next_evt;
    wire idle_prev_evt;
    wire idle_load_evt;
    wire boot_open_evt;
    wire load_error_evt;
    wire load_done_evt;
    wire first_commit_evt;
    wire transition_begin_evt;
    wire transition_commit_evt;
    wire load_meta0_evt;
    wire load_meta1_evt;

    wire [5:0] cur_plus_one_ext;
    wire [4:0] next_index_calc;
    wire [4:0] prev_index_calc;

    assign can_request = i_catalog_done && (i_file_count != 6'd0) && !i_fat_busy;
    assign state_valid = st_boot | st_idle | st_loading | st_drain | st_transition;

    assign auto_timeout = st_idle && o_auto_mode && !i_audio_wait_mode &&
                          o_display_valid && (auto_cnt >= AUTO_LIMIT);

    assign cur_plus_one_ext = {1'b0, o_current_index} + 6'd1;

    assign next_index_calc = (i_file_count <= 6'd1) ? 5'd0 :
                             (cur_plus_one_ext >= i_file_count) ? 5'd0 :
                             (o_current_index + 5'd1);

    assign prev_index_calc = (i_file_count <= 6'd1) ? 5'd0 :
                             (o_current_index == 5'd0) ?
                             (i_file_count[4:0] - 5'd1) :
                             (o_current_index - 5'd1);

    // Next/auto has priority over previous, same as the original manager.
    assign idle_next_evt = st_idle && can_request &&
                           (i_next_pulse || i_audio_next_pulse || auto_timeout);
    assign idle_prev_evt = st_idle && can_request &&
                           !idle_next_evt && i_prev_pulse;
    assign idle_load_evt = idle_next_evt | idle_prev_evt;
    assign boot_open_evt = st_boot && can_request;

    assign load_error_evt = st_loading && i_bmp_load_error;
    assign load_done_evt  = st_loading && !i_bmp_load_error && i_bmp_load_done;

    assign first_commit_evt = st_drain && i_sdram_write_idle &&
                              !first_image_loaded;
    assign transition_begin_evt = st_drain && i_sdram_write_idle &&
                                  first_image_loaded;
    assign transition_commit_evt = st_transition && i_transition_done;

    assign load_meta0_evt = load_done_evt && !o_load_target_buffer;
    assign load_meta1_evt = load_done_evt &&  o_load_target_buffer;

    // These outputs are true one-control-clock events because the source state
    // changes at the next rising edge.
    assign o_open_req = boot_open_evt | idle_load_evt;

    assign o_open_index = boot_open_evt ? 5'd0 :
                          idle_prev_evt ? prev_index_calc :
                          next_index_calc;

    assign o_transition_start = transition_begin_evt;

    // --------------------------------------------------------------------
    // Explicit D nets for the one-hot state FFs.
    // There is no sequential case statement and no inferred state clock enable.
    // --------------------------------------------------------------------
    wire st_boot_logic;
    wire st_idle_logic;
    wire st_loading_logic;
    wire st_drain_logic;
    wire st_transition_logic;

    wire st_boot_d;              //synthesis keep
    wire st_idle_d;              //synthesis keep
    wire st_loading_d;           //synthesis keep
    wire st_drain_d;             //synthesis keep
    wire st_transition_d;        //synthesis keep

    assign st_boot_logic =
           (!state_valid) |
           (st_boot && !can_request) |
           (load_error_evt && !first_image_loaded);

    assign st_idle_logic =
           (st_idle && !idle_load_evt) |
           (load_error_evt && first_image_loaded) |
           first_commit_evt |
           transition_commit_evt;

    assign st_loading_logic =
           boot_open_evt |
           idle_load_evt |
           (st_loading && !i_bmp_load_error && !i_bmp_load_done);

    assign st_drain_logic =
           load_done_evt |
           (st_drain && !i_sdram_write_idle);

    assign st_transition_logic =
           transition_begin_evt |
           (st_transition && !i_transition_done);

    assign st_boot_d       = i_rst ? 1'b1 : st_boot_logic;
    assign st_idle_d       = i_rst ? 1'b0 : st_idle_logic;
    assign st_loading_d    = i_rst ? 1'b0 : st_loading_logic;
    assign st_drain_d      = i_rst ? 1'b0 : st_drain_logic;
    assign st_transition_d = i_rst ? 1'b0 : st_transition_logic;

    // --------------------------------------------------------------------
    // Explicit D nets for all remaining registers.
    // --------------------------------------------------------------------
    wire        auto_mode_d;            //synthesis keep
    wire [28:0] auto_cnt_d;             //synthesis keep
    wire [4:0]  pending_index_d;        //synthesis keep
    wire        load_target_d;          //synthesis keep
    wire        first_image_loaded_d;   //synthesis keep
    wire        display_valid_d;        //synthesis keep
    wire [4:0]  current_index_d;        //synthesis keep
    wire [1:0]  buffer_valid_d;         //synthesis keep
    wire [10:0] buf0_width_d;           //synthesis keep
    wire [9:0]  buf0_height_d;          //synthesis keep
    wire [10:0] buf1_width_d;           //synthesis keep
    wire [9:0]  buf1_height_d;          //synthesis keep
    wire        error_set;               //synthesis keep
    wire        error_hold;              //synthesis keep
    wire        error_d;                 //synthesis keep

    // Auto mode
    assign auto_mode_d = i_rst ? 1'b0 :
                         i_auto_toggle_pulse ? ~o_auto_mode :
                         o_auto_mode;

    // Auto timer
    assign auto_cnt_d = i_rst ? 29'd0 :
                        (!st_idle || !o_auto_mode || !o_display_valid || i_audio_wait_mode) ? 29'd0 :
                        (auto_cnt >= AUTO_LIMIT) ? 29'd0 :
                        (auto_cnt + 29'd1);

    // File request context
    assign pending_index_d = i_rst ? 5'd0 :
                             boot_open_evt ? 5'd0 :
                             idle_next_evt ? next_index_calc :
                             idle_prev_evt ? prev_index_calc :
                             pending_index;

    assign load_target_d = i_rst ? 1'b0 :
                           boot_open_evt ? 1'b0 :
                           idle_load_evt ? ~i_active_buffer_sync :
                           o_load_target_buffer;

    // First image / displayed image ownership
    assign first_image_loaded_d = i_rst ? 1'b0 :
                                  first_commit_evt ? 1'b1 :
                                  first_image_loaded;

    assign display_valid_d = i_rst ? 1'b0 :
                             first_commit_evt ? 1'b1 :
                             o_display_valid;

    assign current_index_d = i_rst ? 5'd0 :
                             first_commit_evt ? pending_index :
                             transition_commit_evt ? pending_index :
                             o_current_index;

    // Buffer-valid vector; no partial-bit sequential assignment.
    assign buffer_valid_d = i_rst ? 2'b00 :
                            load_meta0_evt ? (o_buffer_valid | 2'b01) :
                            load_meta1_evt ? (o_buffer_valid | 2'b10) :
                            o_buffer_valid;

    // Metadata reset to zero. Width/height are don't-care until valid=1.
    assign buf0_width_d = i_rst ? 11'd0 :
                          load_meta0_evt ? i_bmp_width :
                          o_buf0_width;

    assign buf0_height_d = i_rst ? 10'd0 :
                           load_meta0_evt ? i_bmp_height :
                           o_buf0_height;

    assign buf1_width_d = i_rst ? 11'd0 :
                          load_meta1_evt ? i_bmp_width :
                          o_buf1_width;

    assign buf1_height_d = i_rst ? 10'd0 :
                           load_meta1_evt ? i_bmp_height :
                           o_buf1_height;

    // Sticky error.  Keep the combinational D path explicit so older TD
    // versions do not optimize the self-hold function into a missing CE net.
    assign error_set  = (st_loading | st_idle) & i_bmp_load_error;
    assign error_hold = o_error | error_set;
    assign error_d    = (~i_rst) & error_hold;

    // --------------------------------------------------------------------
    // Flip-flops: unconditional D assignment only.
    // --------------------------------------------------------------------
    always @(posedge i_clk) begin
        st_boot              <= st_boot_d;
        st_idle              <= st_idle_d;
        st_loading           <= st_loading_d;
        st_drain             <= st_drain_d;
        st_transition        <= st_transition_d;

        o_auto_mode          <= auto_mode_d;
        auto_cnt             <= auto_cnt_d;
        pending_index        <= pending_index_d;
        o_load_target_buffer <= load_target_d;

        first_image_loaded   <= first_image_loaded_d;
        o_display_valid      <= display_valid_d;
        o_current_index      <= current_index_d;

        o_buffer_valid       <= buffer_valid_d;
        o_buf0_width         <= buf0_width_d;
        o_buf0_height        <= buf0_height_d;
        o_buf1_width         <= buf1_width_d;
        o_buf1_height        <= buf1_height_d;

        o_error              <= error_d;
    end

endmodule
