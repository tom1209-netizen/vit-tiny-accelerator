`timescale 1ns / 1ps

module depthwise_conv_unit #(
    parameter DATA_WIDTH   = 8,    // Element width (INT8)
    parameter LANES        = 8,    // Parallel channels per beat
    parameter INPUT_WIDTH  = 64,   // 8 * 8 = 64 bits (input)
    parameter OUTPUT_WIDTH = 256,  // 8 * 32 = 256 bits (INT32 output)
    parameter MAX_WIDTH    = 28,   // Maximum image width (columns) - smaller layers
    parameter MAX_CHANNELS = 128,  // Maximum channels - reduce for BRAM fit
    parameter ACC_WIDTH    = 32    // Accumulator width (INT32)
) (
    input wire clk,
    input wire rst_n,

    // Control interface
    input  wire        start,
    output reg         done,
    input  wire [15:0] cfg_height,   // Image height (rows)
    input  wire [15:0] cfg_width,    // Image width (columns)
    input  wire [15:0] cfg_channels, // Total channels (multiple of 8)

    // Kernel weights input (load 9 coefficients per channel group)
    input  wire [INPUT_WIDTH-1:0] axis_kernel_in_tdata,
    input  wire                   axis_kernel_in_tvalid,
    output wire                   axis_kernel_in_tready,

    // Feature map input (8 x INT8)
    input  wire [INPUT_WIDTH-1:0] axis_data_in_tdata,
    input  wire                   axis_data_in_tvalid,
    input  wire                   axis_data_in_tlast,
    output wire                   axis_data_in_tready,

    // Feature map output (8 x INT32) -> goes to requant_unit
    output wire [OUTPUT_WIDTH-1:0] axis_data_out_tdata,
    output wire                    axis_data_out_tvalid,
    output wire                    axis_data_out_tlast,
    input  wire                    axis_data_out_tready
);

    // =========================================================================
    // Local Parameters
    // =========================================================================
    localparam KERNEL_SIZE = 9;  // 3x3 kernel
    localparam KERNEL_PACK_WIDTH = KERNEL_SIZE * INPUT_WIDTH;  // 576 bits per channel group
    // Line buffer depth: MAX_WIDTH × (MAX_CHANNELS/LANES) = 28 × 16 = 448 beats/row
    // Each buffer: 448 × 64 = 28,672 bits < 1 RAMB36 each, 3 total (fits easily)
    localparam MAX_BEATS_ROW = MAX_WIDTH * (MAX_CHANNELS / LANES);

    // =========================================================================
    // FSM States - Extended for sequential BRAM reads
    // =========================================================================
    localparam [3:0] S_IDLE        = 4'd0,
                     S_LOAD_KERNEL = 4'd1,
                     S_PROCESS     = 4'd2,  // Wait for data availability
    S_FETCH_LEFT = 4'd3,  // Read left column from BRAM
    S_FETCH_CTR = 4'd4,  // Read center column from BRAM
    S_FETCH_RIGHT = 4'd5,  // Read right column from BRAM
    S_FETCH_DONE = 4'd6,  // Wait for right column read to complete
    S_DONE = 4'd7;

    reg [3:0] state, next_state;

    // =========================================================================
    // Configuration Registers (latched on start)
    // =========================================================================
    reg [15:0] num_rows;  // Image height
    reg [15:0] num_cols;  // Image width
    reg [15:0] num_chan_beats;  // = channels / 8
    reg [31:0] total_output_beats;  // = num_rows * num_cols * num_chan_beats
    reg [15:0] total_kernel_beats;  // = num_chan_beats * 9

    // Pre-computed flag for kernel loading completion (avoids 16-bit comparison in FSM)
    reg kernel_load_almost_done;  // Set when kernel_load_cnt == total_kernel_beats - 2

    // =========================================================================
    // Kernel Weight Storage - packed registers (9×64-bit per channel group)
    // Use registers (not BRAM) since kernel storage is small (~1KB for 16 groups)
    // This avoids BRAM fragmentation from the 576-bit wide words
    // =========================================================================
    (* ram_style = "registers" *)
    reg [KERNEL_PACK_WIDTH-1:0] kernel_mem[0:(MAX_CHANNELS/LANES)-1];
    reg [KERNEL_PACK_WIDTH-1:0] kernel_data_q;

    // Kernel loading state - declared here for use in FSM
    reg [15:0] kernel_load_cnt;
    reg [3:0] kernel_coeff_idx;
    reg [3:0] kernel_chan_group;  // Which channel group (0 to 15)

    // Stage 2 pipeline registers for kernel write
    reg kernel_wr_en_d;
    reg [3:0] kernel_coeff_idx_d;
    reg [3:0] kernel_chan_group_d;
    reg [INPUT_WIDTH-1:0] kernel_data_d;

    integer init_kb;
    initial begin
        for (init_kb = 0; init_kb < MAX_CHANNELS / LANES; init_kb = init_kb + 1)
        kernel_mem[init_kb] = {KERNEL_PACK_WIDTH{1'b0}};
    end

    // =========================================================================
    // Line Buffers - 3 true dual-port BRAMs (one per circular row slot)
    // Port A: write from input stream (in S_PROCESS/S_FETCH states)
    // Port B: read for window extraction (sequential left/center/right)
    // =========================================================================
    (* ram_style = "block" *) reg [INPUT_WIDTH-1:0] line_buf_0[0:MAX_BEATS_ROW-1];
    (* ram_style = "block" *) reg [INPUT_WIDTH-1:0] line_buf_1[0:MAX_BEATS_ROW-1];
    (* ram_style = "block" *) reg [INPUT_WIDTH-1:0] line_buf_2[0:MAX_BEATS_ROW-1];

    integer init_beat;
    initial begin
        for (init_beat = 0; init_beat < MAX_BEATS_ROW; init_beat = init_beat + 1) begin
            line_buf_0[init_beat] = {INPUT_WIDTH{1'b0}};
            line_buf_1[init_beat] = {INPUT_WIDTH{1'b0}};
            line_buf_2[init_beat] = {INPUT_WIDTH{1'b0}};
        end
    end

    // BRAM read registers (1-cycle latency)
    reg [15:0] lb_rd_addr;
    reg [INPUT_WIDTH-1:0] lb_rd_data_0, lb_rd_data_1, lb_rd_data_2;

    // =========================================================================
    // Input Tracking
    // =========================================================================
    reg [15:0] in_row;
    reg [15:0] in_col;
    reg [15:0] in_chan_beat;
    reg [15:0] in_beat_in_row;
    reg [1:0] in_row_mod3;  // Pre-computed in_row % 3 for timing closure

    // =========================================================================
    // Output Processing Tracking
    // =========================================================================
    reg [15:0] out_row;
    reg [15:0] out_col;
    reg [15:0] out_chan_beat;
    reg [31:0] out_beat_cnt;
    reg processing_enabled;

    // Pre-computed circular buffer indices (avoid expensive mod-3 operations)
    // These track out_row % 3 and (out_row +/- 1) % 3 with simple increment logic
    reg [1:0] out_row_mod3;  // = out_row % 3

    // Pre-computed beat addresses (avoid expensive multiplications)
    // beat_in_row = out_col * num_chan_beats + out_chan_beat
    // This is just a counter that increments each fetch and resets per row
    reg [15:0] out_beat_in_row;

    // Pre-computed edge flags (avoid expensive 16-bit comparisons)
    // These update when position changes, using simple logic
    reg is_first_col_reg;  // = (out_col == 0)
    reg is_last_col_reg;  // = (out_col == num_cols - 1)
    reg is_first_row_reg;  // = (out_row == 0)
    reg is_last_row_reg;  // = (out_row == num_rows - 1)

    // =========================================================================
    // Window Extraction Registers (filled over 3 fetch cycles)
    // =========================================================================
    reg [INPUT_WIDTH-1:0] win_word_row0                                              [0:2];
    reg [INPUT_WIDTH-1:0] win_word_row1                                              [0:2];
    reg [INPUT_WIDTH-1:0] win_word_row2                                              [0:2];

    // Latched metadata for current window being fetched
    reg [           15:0] fetch_chan_beat;
    reg                   fetch_is_last;
    reg is_top_row_r, is_bottom_row_r, is_left_col_r, is_right_col_r;
    reg [1:0] row_above_idx_r, row_center_idx_r, row_below_idx_r;
    reg [15:0] beat_left_r, beat_center_r, beat_right_r;

    // =========================================================================
    // MAC Pipeline - Time-Shared DSP Design
    // =========================================================================
    // Uses 8 DSPs (one per lane) instead of 72, cycling through 9 kernel positions
    // This reduces DSP usage by 9x with ~1.8x throughput reduction

    // Window and kernel data storage (captured from fetch)
    reg signed [DATA_WIDTH-1:0] win_data[0:KERNEL_SIZE-1][0:LANES-1];  // 9 positions × 8 lanes
    reg signed [DATA_WIDTH-1:0] ker_data[0:KERNEL_SIZE-1][0:LANES-1];  // 9 positions × 8 lanes
    reg mac_data_valid;  // Window/kernel data is ready
    reg mac_data_last;  // Last beat flag

    // MAC running flag (used for flow control)
    reg mac_running;

    // Final result
    reg signed [ACC_WIDTH-1:0] mac_result[0:LANES-1];
    reg mac_valid;
    reg mac_last;

    // =========================================================================
    // Output Registers
    // =========================================================================
    reg [OUTPUT_WIDTH-1:0] out_data_reg;
    reg out_valid_reg;
    reg out_last_reg;
    reg last_beat_sent;
    reg last_fetch_initiated;  // Set when we start processing the last beat

    // =========================================================================
    // Handshaking
    // =========================================================================
    wire kernel_handshake = axis_kernel_in_tvalid && axis_kernel_in_tready;
    wire input_handshake = axis_data_in_tvalid && axis_data_in_tready;
    wire output_handshake = axis_data_out_tvalid && axis_data_out_tready;

    assign axis_kernel_in_tready = (state == S_LOAD_KERNEL);

    // Accept input during PROCESS and FETCH states (overlap input with window extraction)
    // Flow control: With 3 line buffers, processing row R needs rows R-1, R, R+1.
    // Row R+2 would overwrite R-1, so input must stay at most 1 row ahead.
    // NOTE: This comparison MUST be combinational (not registered) to prevent
    // line buffer overwrites. The 16-bit comparison is acceptable here since
    // it only affects input_tready, not the main processing path.
    wire in_fetch_states = (state == S_FETCH_LEFT) || (state == S_FETCH_CTR) || (state == S_FETCH_RIGHT);
    wire input_within_safe_row = (in_row <= out_row + 1);  // Prevent line buffer overwrite
    assign axis_data_in_tready = ((state == S_PROCESS) || in_fetch_states) && 
                                  (!out_valid_reg || output_handshake) &&
                                  input_within_safe_row;

    assign axis_data_out_tdata = out_data_reg;
    assign axis_data_out_tvalid = out_valid_reg;
    assign axis_data_out_tlast = out_last_reg;

    // =========================================================================
    // Data Availability Logic - PIPELINED for timing closure
    // The original combinational path through DSP48 multiplication was ~13ns.
    // This version pipelines just the needed_beat computation (DSP48 is the main delay)
    // =========================================================================

    // --- Combinational boundary flags (fast LUT logic) ---
    // Use registered row flags where possible for timing
    wire is_last_output_row = is_last_row_reg;  // Pre-computed registered value
    wire is_last_output_col = (out_col == num_cols - 1);
    wire is_last_chan_beat = (out_chan_beat == num_chan_beats - 1);
    wire is_last_output_beat = is_last_output_row && is_last_output_col && is_last_chan_beat;

    // --- Stage 1 (registered): Pre-compute needed_beat for NEXT cycle ---
    // We register this computation to break the DSP48 critical path.
    // The key insight: we compute needed_beat AHEAD of time, anticipating
    // the position we'll be checking next.
    
    reg [31:0] needed_beat_r;
    reg is_last_output_row_r;

    // Stage 1: Compute next_col_beat through DSP (no comparison in path)
    reg [31:0] next_col_beat_r;
    reg is_last_output_col_d;  // Delayed comparison result for Stage 2
    reg [15:0] num_chan_beats_d;  // Delayed for subtraction
    reg [15:0] out_chan_beat_d;  // Delayed for addition

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            next_col_beat_r <= 32'd0;
            is_last_output_col_d <= 1'b0;
            num_chan_beats_d <= 16'd0;
            out_chan_beat_d <= 16'd0;
        end else begin
            // Stage 1: Register the DSP result and save context for Stage 2
            next_col_beat_r <= (out_col + 1) * num_chan_beats;
            is_last_output_col_d <= is_last_output_col;
            num_chan_beats_d <= num_chan_beats;
            out_chan_beat_d <= out_chan_beat;
        end
    end

    // Stage 2: Apply adjustment and add out_chan_beat
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            needed_beat_r <= 32'd0;
            is_last_output_row_r <= 1'b0;
        end else begin
            is_last_output_row_r <= is_last_output_row;

            // Adjust based on delayed is_last_output_col flag
            // If was at last col, subtract num_chan_beats (to get current col * ncb)
            if (is_last_output_col_d)
                needed_beat_r <= next_col_beat_r - num_chan_beats_d + out_chan_beat_d;
            else needed_beat_r <= next_col_beat_r + out_chan_beat_d;
        end
    end

    // --- Combinational comparisons using registered needed_beat ---
    // These comparisons now use the registered needed_beat_r from previous cycle.
    // Since output position only changes in S_FETCH_DONE, and we check this in 
    // S_PROCESS (after S_FETCH_DONE), the registered value is one cycle stale
    // but reflects the PREVIOUS position. We need to use current position for
    // the row comparisons but registered needed_beat for the beat comparison.
    //
    // IMPORTANT: After S_FETCH_DONE advances position, needed_beat_r will be
    // updated after TWO clock edges (Stage 1 + Stage 2). So we need to wait
    // two cycles for the pipeline to update.

    reg [1:0] pipeline_countdown;  // Countdown for pipeline warmup

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipeline_countdown <= 2'd0;
        end else if (state == S_FETCH_DONE) begin
            // Position is about to change, need 2 cycles for pipeline to update
            pipeline_countdown <= 2'd2;
        end else if (pipeline_countdown != 2'd0) begin
            pipeline_countdown <= pipeline_countdown - 1'd1;
        end
    end

    wire pipeline_valid = (pipeline_countdown == 2'd0);

    wire has_row_below_data = is_last_output_row ||
                              (in_row > out_row + 1) ||
                              (in_row == out_row + 1 && in_beat_in_row > needed_beat_r[15:0]);

    wire has_current_row_data = (in_row > out_row) ||
                                (in_row == out_row && in_beat_in_row > needed_beat_r[15:0]);

    wire can_start_fetch = processing_enabled && pipeline_valid &&
                           has_row_below_data && has_current_row_data && 
                           (!out_valid_reg || output_handshake);

    // Beat addresses for window columns - use pre-computed out_beat_in_row
    // beat_center = out_beat_in_row (the current beat within the row)
    // beat_left = out_beat_in_row - num_chan_beats (one column to the left)
    // beat_right = out_beat_in_row + num_chan_beats (one column to the right)
    // Handle edge cases: left edge repeats, right edge repeats
    wire [15:0] beat_center = out_beat_in_row;

    // Compute both possibilities in parallel - no comparison in adder path
    wire [15:0] beat_left_normal = out_beat_in_row - num_chan_beats;
    wire [15:0] beat_right_normal = out_beat_in_row + num_chan_beats;

    // MUX using REGISTERED edge flags (no carry chain in this path)
    wire [15:0] beat_left = is_first_col_reg ? out_beat_in_row : beat_left_normal;
    wire [15:0] beat_right = is_last_col_reg ? out_beat_in_row : beat_right_normal;

    // Row indices in circular buffer - use pre-computed mod3 for timing closure
    // Simple increment/decrement mod 3: 0→1→2→0 or 0→2→1→0
    wire [1:0] row_center_idx = out_row_mod3;
    wire [1:0] row_above_idx = (out_row == 0) ? 2'd0 : 
                               (out_row_mod3 == 2'd0) ? 2'd2 : out_row_mod3 - 1;
    wire [1:0] row_below_idx = (out_row == num_rows - 1) ? 2'd0 :
                               (out_row_mod3 == 2'd2) ? 2'd0 : out_row_mod3 + 1;

    // Border flags - use pre-computed registered values for timing closure
    wire is_top_row = is_first_row_reg;
    wire is_bottom_row = is_last_row_reg;
    wire is_left_col = is_first_col_reg;
    wire is_right_col = is_last_col_reg;

    // =========================================================================
    // FSM State Register
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else state <= next_state;
    end

    // =========================================================================
    // FSM Next State Logic
    // =========================================================================
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (start && cfg_height > 0 && cfg_width > 0 && cfg_channels >= LANES)
                    next_state = S_LOAD_KERNEL;
            end

            S_LOAD_KERNEL: begin
                // Use pre-computed flag to avoid 16-bit comparison in critical path
                if (kernel_load_almost_done && kernel_handshake) next_state = S_PROCESS;
            end

            S_PROCESS: begin
                if (last_beat_sent) next_state = S_DONE;
                else if (can_start_fetch && !last_fetch_initiated) next_state = S_FETCH_LEFT;
                // If last_fetch_initiated but not last_beat_sent, wait for pipeline to drain
            end

            S_FETCH_LEFT: begin
                next_state = S_FETCH_CTR;  // 1 cycle for BRAM address setup
            end

            S_FETCH_CTR: begin
                next_state = S_FETCH_RIGHT;  // Capture left, issue center read
            end

            S_FETCH_RIGHT: begin
                next_state = S_FETCH_DONE;  // Wait for right column read to complete
            end

            S_FETCH_DONE: begin
                // Return to S_PROCESS to let MAC pipeline complete
                next_state = S_PROCESS;
            end

            S_DONE: begin
                next_state = S_IDLE;
            end

            default: next_state = S_IDLE;
        endcase
    end

    // =========================================================================
    // Configuration Capture
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            num_rows           <= 16'd0;
            num_cols           <= 16'd0;
            num_chan_beats     <= 16'd0;
            total_output_beats <= 32'd0;
            total_kernel_beats <= 16'd0;
        end else if (state == S_IDLE && start) begin
            num_rows           <= cfg_height;
            num_cols           <= cfg_width;
            num_chan_beats     <= cfg_channels >> 3;
            total_output_beats <= cfg_height * cfg_width * (cfg_channels >> 3);
            total_kernel_beats <= (cfg_channels >> 3) * KERNEL_SIZE;
        end
    end

    // =========================================================================
    // Kernel Loading - Pipelined for timing closure
    // The kernel load path uses a 2-stage pipeline:
    //   Stage 1: Compute write address (channel group) and coefficient index
    //   Stage 2: Register the data and write enables, then write to kernel_mem
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            kernel_load_cnt <= 16'd0;
            kernel_coeff_idx <= 4'd0;
            kernel_chan_group <= 4'd0;
            kernel_load_almost_done <= 1'b0;
        end else if (state == S_IDLE) begin
            kernel_load_cnt <= 16'd0;
            kernel_coeff_idx <= 4'd0;
            kernel_chan_group <= 4'd0;
            kernel_load_almost_done <= 1'b0;
        end else if (state == S_LOAD_KERNEL && kernel_handshake) begin
            kernel_load_cnt <= kernel_load_cnt + 1;
            // Pre-compute "almost done" flag - true when we're at second-to-last beat
            // On next handshake, kernel loading will complete
            kernel_load_almost_done <= (kernel_load_cnt == total_kernel_beats - 2);
            if (kernel_coeff_idx == KERNEL_SIZE - 1) begin
                kernel_coeff_idx  <= 4'd0;
                kernel_chan_group <= kernel_chan_group + 1;
            end else begin
                kernel_coeff_idx <= kernel_coeff_idx + 1;
            end
        end
    end

    // Stage 2: Register write data and enables
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            kernel_wr_en_d      <= 1'b0;
            kernel_coeff_idx_d  <= 4'd0;
            kernel_chan_group_d <= 4'd0;
            kernel_data_d       <= {INPUT_WIDTH{1'b0}};
        end else begin
            kernel_wr_en_d      <= (state == S_LOAD_KERNEL) && kernel_handshake;
            kernel_coeff_idx_d  <= kernel_coeff_idx;
            kernel_chan_group_d <= kernel_chan_group;
            kernel_data_d       <= axis_kernel_in_tdata;
        end
    end

    // Kernel memory write using pipelined signals
    always @(posedge clk) begin
        if (kernel_wr_en_d) begin
            kernel_mem[kernel_chan_group_d][kernel_coeff_idx_d*INPUT_WIDTH +: INPUT_WIDTH] 
                <= kernel_data_d;
        end
    end

    // =========================================================================
    // Input Reception & Line Buffer Write
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_row         <= 16'd0;
            in_col         <= 16'd0;
            in_chan_beat   <= 16'd0;
            in_beat_in_row <= 16'd0;
            in_row_mod3    <= 2'd0;
        end else if (state == S_IDLE) begin
            in_row         <= 16'd0;
            in_col         <= 16'd0;
            in_chan_beat   <= 16'd0;
            in_beat_in_row <= 16'd0;
            in_row_mod3    <= 2'd0;
        end else if (input_handshake) begin
            if (in_chan_beat == num_chan_beats - 1) begin
                in_chan_beat <= 16'd0;
                if (in_col == num_cols - 1) begin
                    in_col         <= 16'd0;
                    in_row         <= in_row + 1;
                    in_beat_in_row <= 16'd0;
                    // Increment mod 3: 0→1→2→0
                    in_row_mod3    <= (in_row_mod3 == 2'd2) ? 2'd0 : in_row_mod3 + 1;
                end else begin
                    in_col         <= in_col + 1;
                    in_beat_in_row <= in_beat_in_row + 1;
                end
            end else begin
                in_chan_beat   <= in_chan_beat + 1;
                in_beat_in_row <= in_beat_in_row + 1;
            end
        end
    end

    // Line buffer write (synchronous for BRAM inference)
    // Uses pre-computed in_row_mod3 for timing closure
    always @(posedge clk) begin
        if (input_handshake) begin
            case (in_row_mod3)
                2'd0: line_buf_0[in_beat_in_row] <= axis_data_in_tdata;
                2'd1: line_buf_1[in_beat_in_row] <= axis_data_in_tdata;
                2'd2: line_buf_2[in_beat_in_row] <= axis_data_in_tdata;
            endcase
        end
    end

    // =========================================================================
    // Pre-computed Row Comparison Flags
    // These flags avoid 16-bit carry chains in the critical path by registering
    // the comparison results. They are 1 cycle old but we account for this
    // with the pipeline_countdown mechanism.
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_row_gt_out_row_plus1 <= 1'b0;
            in_row_eq_out_row_plus1 <= 1'b0;
            in_row_gt_out_row       <= 1'b0;
            in_row_eq_out_row       <= 1'b1;  // Both start at 0
        end else begin
            // Simply register the comparison results from current values
            // These will be 1 cycle old, but pipeline_countdown handles this
            in_row_gt_out_row_plus1 <= (in_row > out_row + 1);
            in_row_eq_out_row_plus1 <= (in_row == out_row + 1);
            in_row_gt_out_row       <= (in_row > out_row);
            in_row_eq_out_row       <= (in_row == out_row);
        end
    end

    // =========================================================================
    // Output Position & Processing Enable
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_row            <= 16'd0;
            out_col            <= 16'd0;
            out_chan_beat      <= 16'd0;
            out_beat_cnt       <= 32'd0;
            processing_enabled <= 1'b0;
            out_row_mod3       <= 2'd0;
            out_beat_in_row    <= 16'd0;
            is_first_col_reg   <= 1'b1;  // Start at col 0
            is_last_col_reg    <= 1'b0;  // Computed after config
            is_first_row_reg   <= 1'b1;  // Start at row 0
            is_last_row_reg    <= 1'b0;  // Computed after config
        end else if (state == S_IDLE) begin
            out_row            <= 16'd0;
            out_col            <= 16'd0;
            out_chan_beat      <= 16'd0;
            out_beat_cnt       <= 32'd0;
            processing_enabled <= 1'b0;
            out_row_mod3       <= 2'd0;
            out_beat_in_row    <= 16'd0;
            is_first_col_reg   <= 1'b1;  // Start at col 0
            is_last_col_reg    <= (num_cols == 16'd1);  // Edge case: single column
            is_first_row_reg   <= 1'b1;  // Start at row 0
            is_last_row_reg    <= (num_rows == 16'd1);  // Edge case: single row
        end else begin
            // Enable processing once we have some input
            if (in_row >= 1 || (in_row == 0 && in_col > 0)) processing_enabled <= 1'b1;

            // Count output beats consumed
            if (output_handshake && out_valid_reg) out_beat_cnt <= out_beat_cnt + 1;

            // Advance output position AFTER the fetch completes (in S_FETCH_DONE)
            if (state == S_FETCH_DONE) begin
                // Always increment beat_in_row (wraps at end of row)
                if (out_chan_beat == num_chan_beats - 1) begin
                    out_chan_beat <= 16'd0;
                    if (out_col == num_cols - 1) begin
                        // Moving to column 0 of next row
                        out_col <= 16'd0;
                        out_row <= out_row + 1;
                        out_beat_in_row <= 16'd0;
                        out_row_mod3 <= (out_row_mod3 == 2'd2) ? 2'd0 : out_row_mod3 + 1;
                        is_first_col_reg <= 1'b1;
                        is_last_col_reg <= (num_cols == 16'd1);
                        // Update row edge flags for next row
                        is_first_row_reg <= 1'b0;  // No longer at first row
                        // Will be at last row if current row is num_rows - 2
                        is_last_row_reg <= (out_row == num_rows - 2);
                    end else begin
                        // Moving to next column
                        out_col <= out_col + 1;
                        out_beat_in_row <= out_beat_in_row + 1;
                        is_first_col_reg <= 1'b0;  // No longer at first column
                        // Will be at last col if current col is num_cols - 2
                        is_last_col_reg <= (out_col == num_cols - 2);
                    end
                end else begin
                    out_chan_beat   <= out_chan_beat + 1;
                    out_beat_in_row <= out_beat_in_row + 1;
                end
            end
        end
    end

    // =========================================================================
    // Window Fetch: Capture metadata at start of fetch sequence
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_chan_beat      <= 16'd0;
            fetch_is_last        <= 1'b0;
            last_fetch_initiated <= 1'b0;
            is_top_row_r         <= 1'b0;
            is_bottom_row_r      <= 1'b0;
            is_left_col_r        <= 1'b0;
            is_right_col_r       <= 1'b0;
            row_above_idx_r      <= 2'd0;
            row_center_idx_r     <= 2'd0;
            row_below_idx_r      <= 2'd0;
            beat_left_r          <= 16'd0;
            beat_center_r        <= 16'd0;
            beat_right_r         <= 16'd0;
        end else if (state == S_IDLE) begin
            last_fetch_initiated <= 1'b0;
        end else if (state == S_PROCESS && next_state == S_FETCH_LEFT) begin
            fetch_chan_beat <= out_chan_beat;
            fetch_is_last   <= is_last_output_beat;
            // Track if this is the last fetch sequence
            if (is_last_output_beat) last_fetch_initiated <= 1'b1;
            is_top_row_r     <= is_top_row;
            is_bottom_row_r  <= is_bottom_row;
            is_left_col_r    <= is_left_col;
            is_right_col_r   <= is_right_col;
            row_above_idx_r  <= row_above_idx;
            row_center_idx_r <= row_center_idx;
            row_below_idx_r  <= row_below_idx;
            beat_left_r      <= beat_left;
            beat_center_r    <= beat_center;
            beat_right_r     <= beat_right;
        end
    end

    // =========================================================================
    // BRAM Read Address Generation
    // Uses registered beat addresses (beat_left_r, beat_center_r, beat_right_r)
    // to avoid is_last_output_col comparison in critical path.
    // The addresses are captured when transitioning S_PROCESS -> S_FETCH_LEFT.
    // =========================================================================
    always @(posedge clk) begin
        case (state)
            S_PROCESS: begin
                // When initiating fetch, set first address (left column)
                if (next_state == S_FETCH_LEFT) lb_rd_addr <= beat_left;
            end
            S_FETCH_LEFT: begin
                // Use REGISTERED beat_center_r captured at start of fetch
                lb_rd_addr <= beat_center_r;
            end
            S_FETCH_CTR: begin
                // Use REGISTERED beat_right_r captured at start of fetch
                lb_rd_addr <= beat_right_r;
            end
            default: begin
                // Hold address
            end
        endcase
    end

    // BRAM synchronous read
    always @(posedge clk) begin
        lb_rd_data_0 <= line_buf_0[lb_rd_addr];
        lb_rd_data_1 <= line_buf_1[lb_rd_addr];
        lb_rd_data_2 <= line_buf_2[lb_rd_addr];
    end

    // =========================================================================
    // Window Data Capture from BRAM reads
    // =========================================================================
    // Helper function to select row data based on circular buffer index
    function [INPUT_WIDTH-1:0] select_row_data;
        input [1:0] row_idx;
        input [INPUT_WIDTH-1:0] data_0, data_1, data_2;
        begin
            case (row_idx)
                2'd0: select_row_data = data_0;
                2'd1: select_row_data = data_1;
                default: select_row_data = data_2;
            endcase
        end
    endfunction

    integer wi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (wi = 0; wi < 3; wi = wi + 1) begin
                win_word_row0[wi] <= {INPUT_WIDTH{1'b0}};
                win_word_row1[wi] <= {INPUT_WIDTH{1'b0}};
                win_word_row2[wi] <= {INPUT_WIDTH{1'b0}};
            end
        end else begin
            case (state)
                S_FETCH_CTR: begin
                    // Capture LEFT column (lb_rd_data now has beat_left data from previous cycle)
                    if (is_left_col_r) begin
                        win_word_row0[0] <= {INPUT_WIDTH{1'b0}};
                        win_word_row1[0] <= {INPUT_WIDTH{1'b0}};
                        win_word_row2[0] <= {INPUT_WIDTH{1'b0}};
                    end else begin
                        win_word_row0[0] <= is_top_row_r ? {INPUT_WIDTH{1'b0}} : select_row_data(
                            row_above_idx_r, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2
                        );
                        win_word_row1[0] <= select_row_data(
                            row_center_idx_r, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2
                        );
                        win_word_row2[0] <= is_bottom_row_r ? {INPUT_WIDTH{1'b0}} : select_row_data(
                            row_below_idx_r, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2
                        );
                    end
                end

                S_FETCH_RIGHT: begin
                    // Capture CENTER column (lb_rd_data now has beat_center data from previous cycle)
                    win_word_row0[1] <= is_top_row_r ? {INPUT_WIDTH{1'b0}} : select_row_data(
                        row_above_idx_r, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2
                    );
                    win_word_row1[1] <= select_row_data(
                        row_center_idx_r, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2
                    );
                    win_word_row2[1] <= is_bottom_row_r ? {INPUT_WIDTH{1'b0}} : select_row_data(
                        row_below_idx_r, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2
                    );
                end

                default: begin
                    // Hold values
                end
            endcase
        end
    end

    // =========================================================================
    // Kernel Read (synchronous)
    // =========================================================================
    always @(posedge clk) begin
        if (state == S_FETCH_CTR) kernel_data_q <= kernel_mem[fetch_chan_beat];
    end

    // =========================================================================
    // MAC Pipeline - Delayed to allow window capture to complete
    // =========================================================================
    // Detect when we're in S_FETCH_DONE (lb_rd_data now has beat_right data)
    wire mac_prepare = (state == S_FETCH_DONE);

    // Capture RIGHT column in S_FETCH_DONE (lb_rd_data has beat_right data from previous cycle)
    // This is separate from the state-based capture to get the correct BRAM timing
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_word_row0[2] <= {INPUT_WIDTH{1'b0}};
            win_word_row1[2] <= {INPUT_WIDTH{1'b0}};
            win_word_row2[2] <= {INPUT_WIDTH{1'b0}};
        end else if (mac_prepare) begin
            if (is_right_col_r) begin
                win_word_row0[2] <= {INPUT_WIDTH{1'b0}};
                win_word_row1[2] <= {INPUT_WIDTH{1'b0}};
                win_word_row2[2] <= {INPUT_WIDTH{1'b0}};
            end else begin
                win_word_row0[2] <= is_top_row_r ? {INPUT_WIDTH{1'b0}} : select_row_data(
                    row_above_idx_r, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2
                );
                win_word_row1[2] <= select_row_data(
                    row_center_idx_r, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2
                );
                win_word_row2[2] <= is_bottom_row_r ? {INPUT_WIDTH{1'b0}} : select_row_data(
                    row_below_idx_r, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2
                );
            end
        end
    end

    // Delay the actual MAC trigger by one cycle so win_word is stable
    reg mac_trigger_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) mac_trigger_d <= 1'b0;
        else mac_trigger_d <= mac_prepare;
    end

    wire mac_trigger = mac_trigger_d;

    // =========================================================================
    // Time-Shared MAC: Stage 1 - Capture Window and Kernel Data
    // =========================================================================
    // When mac_trigger fires, capture all 9 window positions and kernel coefficients
    integer ci;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_data_valid <= 1'b0;
            mac_data_last  <= 1'b0;
            for (ci = 0; ci < LANES; ci = ci + 1) begin
                win_data[0][ci] <= {DATA_WIDTH{1'b0}};
                ker_data[0][ci] <= {DATA_WIDTH{1'b0}};
                win_data[1][ci] <= {DATA_WIDTH{1'b0}};
                ker_data[1][ci] <= {DATA_WIDTH{1'b0}};
                win_data[2][ci] <= {DATA_WIDTH{1'b0}};
                ker_data[2][ci] <= {DATA_WIDTH{1'b0}};
                win_data[3][ci] <= {DATA_WIDTH{1'b0}};
                ker_data[3][ci] <= {DATA_WIDTH{1'b0}};
                win_data[4][ci] <= {DATA_WIDTH{1'b0}};
                ker_data[4][ci] <= {DATA_WIDTH{1'b0}};
                win_data[5][ci] <= {DATA_WIDTH{1'b0}};
                ker_data[5][ci] <= {DATA_WIDTH{1'b0}};
                win_data[6][ci] <= {DATA_WIDTH{1'b0}};
                ker_data[6][ci] <= {DATA_WIDTH{1'b0}};
                win_data[7][ci] <= {DATA_WIDTH{1'b0}};
                ker_data[7][ci] <= {DATA_WIDTH{1'b0}};
                win_data[8][ci] <= {DATA_WIDTH{1'b0}};
                ker_data[8][ci] <= {DATA_WIDTH{1'b0}};
            end
        end else if (mac_trigger && !mac_running) begin
            // Only capture new data when not already running a MAC operation
            mac_data_valid <= 1'b1;
            mac_data_last  <= fetch_is_last;

            for (ci = 0; ci < LANES; ci = ci + 1) begin
                // Kernel mapping: [row][col] -> index
                // [0][0]=0, [0][1]=1, [0][2]=2
                // [1][0]=3, [1][1]=4, [1][2]=5
                // [2][0]=6, [2][1]=7, [2][2]=8

                // Row 0: above
                win_data[0][ci] <= $signed(win_word_row0[0][ci*DATA_WIDTH+:DATA_WIDTH]);
                ker_data[0][ci] <= $signed(
                    kernel_data_q[(0*INPUT_WIDTH)+(ci*DATA_WIDTH)+:DATA_WIDTH]
                );
                win_data[1][ci] <= $signed(win_word_row0[1][ci*DATA_WIDTH+:DATA_WIDTH]);
                ker_data[1][ci] <= $signed(
                    kernel_data_q[(1*INPUT_WIDTH)+(ci*DATA_WIDTH)+:DATA_WIDTH]
                );
                win_data[2][ci] <= $signed(win_word_row0[2][ci*DATA_WIDTH+:DATA_WIDTH]);
                ker_data[2][ci] <= $signed(
                    kernel_data_q[(2*INPUT_WIDTH)+(ci*DATA_WIDTH)+:DATA_WIDTH]
                );

                // Row 1: center
                win_data[3][ci] <= $signed(win_word_row1[0][ci*DATA_WIDTH+:DATA_WIDTH]);
                ker_data[3][ci] <= $signed(
                    kernel_data_q[(3*INPUT_WIDTH)+(ci*DATA_WIDTH)+:DATA_WIDTH]
                );
                win_data[4][ci] <= $signed(win_word_row1[1][ci*DATA_WIDTH+:DATA_WIDTH]);
                ker_data[4][ci] <= $signed(
                    kernel_data_q[(4*INPUT_WIDTH)+(ci*DATA_WIDTH)+:DATA_WIDTH]
                );
                win_data[5][ci] <= $signed(win_word_row1[2][ci*DATA_WIDTH+:DATA_WIDTH]);
                ker_data[5][ci] <= $signed(
                    kernel_data_q[(5*INPUT_WIDTH)+(ci*DATA_WIDTH)+:DATA_WIDTH]
                );

                // Row 2: below
                win_data[6][ci] <= $signed(win_word_row2[0][ci*DATA_WIDTH+:DATA_WIDTH]);
                ker_data[6][ci] <= $signed(
                    kernel_data_q[(6*INPUT_WIDTH)+(ci*DATA_WIDTH)+:DATA_WIDTH]
                );
                win_data[7][ci] <= $signed(win_word_row2[1][ci*DATA_WIDTH+:DATA_WIDTH]);
                ker_data[7][ci] <= $signed(
                    kernel_data_q[(7*INPUT_WIDTH)+(ci*DATA_WIDTH)+:DATA_WIDTH]
                );
                win_data[8][ci] <= $signed(win_word_row2[2][ci*DATA_WIDTH+:DATA_WIDTH]);
                ker_data[8][ci] <= $signed(
                    kernel_data_q[(8*INPUT_WIDTH)+(ci*DATA_WIDTH)+:DATA_WIDTH]
                );
            end
        end else begin
            mac_data_valid <= 1'b0;
        end
    end

    // =========================================================================
    // Time-Shared MAC: Simplified Sequential Implementation
    // =========================================================================
    // This uses a simple FSM to process all 9 positions sequentially
    // 
    // States: IDLE -> MULT(0-8) -> DONE
    // Each MULT state: multiply one position and accumulate the previous result

    localparam MAC_IDLE = 2'd0;
    localparam MAC_MULT = 2'd1;  // Multiply and accumulate
    localparam MAC_DONE = 2'd2;

    reg [1:0] mac_state;
    reg [3:0] mac_cnt;  // Position counter 0-8
    reg mac_last_saved;

    // Current operands for multiply
    reg signed [DATA_WIDTH-1:0] cur_win[0:LANES-1];
    reg signed [DATA_WIDTH-1:0] cur_ker[0:LANES-1];

    // Product register
    (* use_dsp = "yes" *) reg signed [2*DATA_WIDTH-1:0] prod[0:LANES-1];

    // Accumulator
    reg signed [ACC_WIDTH-1:0] mac_acc[0:LANES-1];

    // Pipeline register for product valid
    reg prod_done;

    integer mi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_state <= MAC_IDLE;
            mac_cnt <= 4'd0;
            mac_running <= 1'b0;
            mac_last_saved <= 1'b0;
            prod_done <= 1'b0;
            for (mi = 0; mi < LANES; mi = mi + 1) begin
                cur_win[mi] <= {DATA_WIDTH{1'b0}};
                cur_ker[mi] <= {DATA_WIDTH{1'b0}};
                prod[mi] <= {(2 * DATA_WIDTH) {1'b0}};
                mac_acc[mi] <= {ACC_WIDTH{1'b0}};
            end
        end else begin
            prod_done <= 1'b0;

            case (mac_state)
                MAC_IDLE: begin
                    if (mac_data_valid) begin
                        mac_state <= MAC_MULT;
                        mac_cnt <= 4'd0;
                        mac_running <= 1'b1;
                        mac_last_saved <= mac_data_last;
                        // Clear accumulator
                        for (mi = 0; mi < LANES; mi = mi + 1) begin
                            mac_acc[mi] <= {ACC_WIDTH{1'b0}};
                        end
                        // Load first position
                        for (mi = 0; mi < LANES; mi = mi + 1) begin
                            cur_win[mi] <= win_data[0][mi];
                            cur_ker[mi] <= ker_data[0][mi];
                        end
                    end
                end

                MAC_MULT: begin
                    // Multiply current position
                    for (mi = 0; mi < LANES; mi = mi + 1) begin
                        prod[mi] <= cur_win[mi] * cur_ker[mi];
                    end

                    // Next cycle: accumulate this product and load next position
                    if (mac_cnt < 4'd8) begin
                        mac_cnt <= mac_cnt + 1;
                        // Load next position
                        for (mi = 0; mi < LANES; mi = mi + 1) begin
                            case (mac_cnt)
                                4'd0: begin
                                    cur_win[mi] <= win_data[1][mi];
                                    cur_ker[mi] <= ker_data[1][mi];
                                end
                                4'd1: begin
                                    cur_win[mi] <= win_data[2][mi];
                                    cur_ker[mi] <= ker_data[2][mi];
                                end
                                4'd2: begin
                                    cur_win[mi] <= win_data[3][mi];
                                    cur_ker[mi] <= ker_data[3][mi];
                                end
                                4'd3: begin
                                    cur_win[mi] <= win_data[4][mi];
                                    cur_ker[mi] <= ker_data[4][mi];
                                end
                                4'd4: begin
                                    cur_win[mi] <= win_data[5][mi];
                                    cur_ker[mi] <= ker_data[5][mi];
                                end
                                4'd5: begin
                                    cur_win[mi] <= win_data[6][mi];
                                    cur_ker[mi] <= ker_data[6][mi];
                                end
                                4'd6: begin
                                    cur_win[mi] <= win_data[7][mi];
                                    cur_ker[mi] <= ker_data[7][mi];
                                end
                                4'd7: begin
                                    cur_win[mi] <= win_data[8][mi];
                                    cur_ker[mi] <= ker_data[8][mi];
                                end
                                default: ;
                            endcase
                        end
                    end else begin
                        // Last multiply done, move to DONE state to output
                        mac_state <= MAC_DONE;
                    end
                end

                MAC_DONE: begin
                    // Accumulate the last product
                    for (mi = 0; mi < LANES; mi = mi + 1) begin
                        mac_acc[mi] <= mac_acc[mi] + {{(ACC_WIDTH-2*DATA_WIDTH){prod[mi][2*DATA_WIDTH-1]}}, prod[mi]};
                    end
                    prod_done   <= 1'b1;
                    mac_running <= 1'b0;
                    mac_state   <= MAC_IDLE;
                end
            endcase

            // Accumulate products (one cycle after multiply)
            if (mac_state == MAC_MULT && mac_cnt > 4'd0) begin
                for (mi = 0; mi < LANES; mi = mi + 1) begin
                    mac_acc[mi] <= mac_acc[mi] + {{(ACC_WIDTH-2*DATA_WIDTH){prod[mi][2*DATA_WIDTH-1]}}, prod[mi]};
                end
            end
        end
    end

    // Output result
    integer ri;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_valid <= 1'b0;
            mac_last  <= 1'b0;
            for (ri = 0; ri < LANES; ri = ri + 1) mac_result[ri] <= {ACC_WIDTH{1'b0}};
        end else if (prod_done) begin
            mac_valid <= 1'b1;
            mac_last  <= mac_last_saved;
            for (ri = 0; ri < LANES; ri = ri + 1) begin
                mac_result[ri] <= mac_acc[ri];
            end
        end else begin
            mac_valid <= 1'b0;
            mac_last  <= 1'b0;
        end
    end

    // =========================================================================
    // Output Assembly
    // =========================================================================
    integer oi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_data_reg   <= {OUTPUT_WIDTH{1'b0}};
            out_valid_reg  <= 1'b0;
            out_last_reg   <= 1'b0;
            last_beat_sent <= 1'b0;
        end else if (state == S_IDLE) begin
            out_valid_reg  <= 1'b0;
            out_last_reg   <= 1'b0;
            last_beat_sent <= 1'b0;
        end else begin
            if (output_handshake) begin
                out_valid_reg <= 1'b0;
                if (out_last_reg) last_beat_sent <= 1'b1;
            end

            if (mac_valid) begin
                for (oi = 0; oi < LANES; oi = oi + 1)
                out_data_reg[oi*ACC_WIDTH+:ACC_WIDTH] <= mac_result[oi];
                out_valid_reg <= 1'b1;
                out_last_reg  <= mac_last;
            end
        end
    end

    // =========================================================================
    // Done Signal - wait until last output beat is actually sent
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) done <= 1'b0;
        else if (state == S_DONE && last_beat_sent) done <= 1'b1;
        else done <= 1'b0;
    end

endmodule
