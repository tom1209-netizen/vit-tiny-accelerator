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

    // =========================================================================
    // Kernel Weight Storage - packed registers (9×64-bit per channel group)
    // Use registers (not BRAM) since kernel storage is small (~1KB for 16 groups)
    // This avoids BRAM fragmentation from the 576-bit wide words
    // =========================================================================
    (* ram_style = "registers" *)
    reg [KERNEL_PACK_WIDTH-1:0] kernel_mem[0:(MAX_CHANNELS/LANES)-1];
    reg [15:0] kernel_load_cnt;
    reg [3:0] kernel_coeff_idx;
    reg [KERNEL_PACK_WIDTH-1:0] kernel_data_q;

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

    // =========================================================================
    // Output Processing Tracking
    // =========================================================================
    reg [15:0] out_row;
    reg [15:0] out_col;
    reg [15:0] out_chan_beat;
    reg [31:0] out_beat_cnt;
    reg processing_enabled;

    // =========================================================================
    // Window Extraction Registers (filled over 3 fetch cycles)
    // =========================================================================
    reg [INPUT_WIDTH-1:0] win_word_row0[0:2];
    reg [INPUT_WIDTH-1:0] win_word_row1[0:2];
    reg [INPUT_WIDTH-1:0] win_word_row2[0:2];

    // Latched metadata for current window being fetched
    reg [15:0] fetch_chan_beat;
    reg fetch_is_last;
    reg is_top_row_r, is_bottom_row_r, is_left_col_r, is_right_col_r;
    reg [1:0] row_above_idx_r, row_center_idx_r, row_below_idx_r;
    reg [15:0] beat_left_r, beat_center_r, beat_right_r;

    // =========================================================================
    // MAC Pipeline
    // =========================================================================
    reg signed [2*DATA_WIDTH-1:0] prod[0:KERNEL_SIZE-1][0:LANES-1];
    reg prod_valid;
    reg prod_last;

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
    wire in_fetch_states = (state == S_FETCH_LEFT) || (state == S_FETCH_CTR) || (state == S_FETCH_RIGHT);
    wire input_not_too_far = (in_row <= out_row + 1);
    assign axis_data_in_tready = ((state == S_PROCESS) || in_fetch_states) && 
                                  (!out_valid_reg || output_handshake) &&
                                  input_not_too_far;

    assign axis_data_out_tdata = out_data_reg;
    assign axis_data_out_tvalid = out_valid_reg;
    assign axis_data_out_tlast = out_last_reg;

    // =========================================================================
    // Data Availability Logic
    // =========================================================================
    wire is_last_output_row = (out_row == num_rows - 1);
    wire is_last_output_col = (out_col == num_cols - 1);
    wire is_last_chan_beat = (out_chan_beat == num_chan_beats - 1);

    // Current output beat index (computed from position)
    wire [31:0] current_out_beat = out_row * (num_cols * num_chan_beats) + 
                                   out_col * num_chan_beats + 
                                   out_chan_beat;
    wire is_last_output_beat = is_last_output_row && is_last_output_col && is_last_chan_beat;

    wire [15:0] needed_beat = is_last_output_col ?
                              (out_col * num_chan_beats + out_chan_beat) :
                              ((out_col + 1) * num_chan_beats + out_chan_beat);

    wire has_row_below_data = is_last_output_row ||
                              (in_row > out_row + 1) ||
                              (in_row == out_row + 1 && in_beat_in_row > needed_beat);

    wire has_current_row_data = (in_row > out_row) ||
                                (in_row == out_row && in_beat_in_row > needed_beat);

    wire can_start_fetch = processing_enabled && has_row_below_data && 
                           has_current_row_data && (!out_valid_reg || output_handshake);

    // Beat addresses for window columns
    wire [15:0] col_left = (out_col == 0) ? 16'd0 : out_col - 1;
    wire [15:0] col_center = out_col;
    wire [15:0] col_right = (out_col == num_cols - 1) ? num_cols - 1 : out_col + 1;

    wire [15:0] beat_left = col_left * num_chan_beats + out_chan_beat;
    wire [15:0] beat_center = col_center * num_chan_beats + out_chan_beat;
    wire [15:0] beat_right = col_right * num_chan_beats + out_chan_beat;

    // Row indices in circular buffer
    wire [1:0] row_above_idx = (out_row == 0) ? 2'd0 : (out_row - 1) % 3;
    wire [1:0] row_center_idx = out_row % 3;
    wire [1:0] row_below_idx = (out_row == num_rows - 1) ? 2'd0 : (out_row + 1) % 3;

    // Border flags
    wire is_top_row = (out_row == 0);
    wire is_bottom_row = (out_row == num_rows - 1);
    wire is_left_col = (out_col == 0);
    wire is_right_col = (out_col == num_cols - 1);

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
                if (kernel_load_cnt >= total_kernel_beats - 1 && kernel_handshake)
                    next_state = S_PROCESS;
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
    // Kernel Loading
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            kernel_load_cnt  <= 16'd0;
            kernel_coeff_idx <= 4'd0;
        end else if (state == S_IDLE) begin
            kernel_load_cnt  <= 16'd0;
            kernel_coeff_idx <= 4'd0;
        end else if (state == S_LOAD_KERNEL && kernel_handshake) begin
            kernel_load_cnt <= kernel_load_cnt + 1;
            if (kernel_coeff_idx == KERNEL_SIZE - 1) kernel_coeff_idx <= 4'd0;
            else kernel_coeff_idx <= kernel_coeff_idx + 1;
        end
    end

    // Kernel memory write (synchronous for BRAM inference)
    always @(posedge clk) begin
        if (state == S_LOAD_KERNEL && kernel_handshake) begin
            kernel_mem[kernel_load_cnt / KERNEL_SIZE][kernel_coeff_idx*INPUT_WIDTH +: INPUT_WIDTH] 
                <= axis_kernel_in_tdata;
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
        end else if (state == S_IDLE) begin
            in_row         <= 16'd0;
            in_col         <= 16'd0;
            in_chan_beat   <= 16'd0;
            in_beat_in_row <= 16'd0;
        end else if (input_handshake) begin
            if (in_chan_beat == num_chan_beats - 1) begin
                in_chan_beat <= 16'd0;
                if (in_col == num_cols - 1) begin
                    in_col         <= 16'd0;
                    in_row         <= in_row + 1;
                    in_beat_in_row <= 16'd0;
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
    always @(posedge clk) begin
        if (input_handshake) begin
            case (in_row % 3)
                2'd0: line_buf_0[in_beat_in_row] <= axis_data_in_tdata;
                2'd1: line_buf_1[in_beat_in_row] <= axis_data_in_tdata;
                2'd2: line_buf_2[in_beat_in_row] <= axis_data_in_tdata;
            endcase
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
        end else if (state == S_IDLE) begin
            out_row            <= 16'd0;
            out_col            <= 16'd0;
            out_chan_beat      <= 16'd0;
            out_beat_cnt       <= 32'd0;
            processing_enabled <= 1'b0;
        end else begin
            // Enable processing once we have some input
            if (in_row >= 1 || (in_row == 0 && in_col > 0)) processing_enabled <= 1'b1;

            // Count output beats consumed
            if (output_handshake && out_valid_reg) out_beat_cnt <= out_beat_cnt + 1;

            // Advance output position AFTER the fetch completes (in S_FETCH_DONE)
            if (state == S_FETCH_DONE) begin
                if (out_chan_beat == num_chan_beats - 1) begin
                    out_chan_beat <= 16'd0;
                    if (out_col == num_cols - 1) begin
                        out_col <= 16'd0;
                        out_row <= out_row + 1;
                    end else begin
                        out_col <= out_col + 1;
                    end
                end else begin
                    out_chan_beat <= out_chan_beat + 1;
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
    // =========================================================================
    always @(posedge clk) begin
        case (state)
            S_PROCESS: begin
                if (next_state == S_FETCH_LEFT) lb_rd_addr <= beat_left;
            end
            S_FETCH_LEFT: begin
                // Use combinational beat_center since position hasn't changed yet
                lb_rd_addr <= beat_center;
            end
            S_FETCH_CTR: begin
                // Use combinational beat_right since position hasn't changed yet
                lb_rd_addr <= beat_right;
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

    // MAC Stage 1: Multiply
    integer mi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_valid <= 1'b0;
            prod_last  <= 1'b0;
            for (mi = 0; mi < LANES; mi = mi + 1) begin
                prod[0][mi] <= {(2 * DATA_WIDTH) {1'b0}};
                prod[1][mi] <= {(2 * DATA_WIDTH) {1'b0}};
                prod[2][mi] <= {(2 * DATA_WIDTH) {1'b0}};
                prod[3][mi] <= {(2 * DATA_WIDTH) {1'b0}};
                prod[4][mi] <= {(2 * DATA_WIDTH) {1'b0}};
                prod[5][mi] <= {(2 * DATA_WIDTH) {1'b0}};
                prod[6][mi] <= {(2 * DATA_WIDTH) {1'b0}};
                prod[7][mi] <= {(2 * DATA_WIDTH) {1'b0}};
                prod[8][mi] <= {(2 * DATA_WIDTH) {1'b0}};
            end
        end else if (mac_trigger) begin
            prod_valid <= 1'b1;
            prod_last  <= fetch_is_last;

            for (mi = 0; mi < LANES; mi = mi + 1) begin
                // Kernel mapping: [row][col] -> index
                // [0][0]=0, [0][1]=1, [0][2]=2
                // [1][0]=3, [1][1]=4, [1][2]=5
                // [2][0]=6, [2][1]=7, [2][2]=8

                // Row 0: above
                prod[0][mi] <= $signed(
                    win_word_row0[0][mi*DATA_WIDTH+:DATA_WIDTH]
                ) * $signed(
                    kernel_data_q[(0*INPUT_WIDTH)+(mi*DATA_WIDTH)+:DATA_WIDTH]
                );
                prod[1][mi] <= $signed(
                    win_word_row0[1][mi*DATA_WIDTH+:DATA_WIDTH]
                ) * $signed(
                    kernel_data_q[(1*INPUT_WIDTH)+(mi*DATA_WIDTH)+:DATA_WIDTH]
                );
                prod[2][mi] <= $signed(
                    win_word_row0[2][mi*DATA_WIDTH+:DATA_WIDTH]
                ) * $signed(
                    kernel_data_q[(2*INPUT_WIDTH)+(mi*DATA_WIDTH)+:DATA_WIDTH]
                );

                // Row 1: center
                prod[3][mi] <= $signed(
                    win_word_row1[0][mi*DATA_WIDTH+:DATA_WIDTH]
                ) * $signed(
                    kernel_data_q[(3*INPUT_WIDTH)+(mi*DATA_WIDTH)+:DATA_WIDTH]
                );
                prod[4][mi] <= $signed(
                    win_word_row1[1][mi*DATA_WIDTH+:DATA_WIDTH]
                ) * $signed(
                    kernel_data_q[(4*INPUT_WIDTH)+(mi*DATA_WIDTH)+:DATA_WIDTH]
                );
                prod[5][mi] <= $signed(
                    win_word_row1[2][mi*DATA_WIDTH+:DATA_WIDTH]
                ) * $signed(
                    kernel_data_q[(5*INPUT_WIDTH)+(mi*DATA_WIDTH)+:DATA_WIDTH]
                );

                // Row 2: below
                prod[6][mi] <= $signed(
                    win_word_row2[0][mi*DATA_WIDTH+:DATA_WIDTH]
                ) * $signed(
                    kernel_data_q[(6*INPUT_WIDTH)+(mi*DATA_WIDTH)+:DATA_WIDTH]
                );
                prod[7][mi] <= $signed(
                    win_word_row2[1][mi*DATA_WIDTH+:DATA_WIDTH]
                ) * $signed(
                    kernel_data_q[(7*INPUT_WIDTH)+(mi*DATA_WIDTH)+:DATA_WIDTH]
                );
                prod[8][mi] <= $signed(
                    win_word_row2[2][mi*DATA_WIDTH+:DATA_WIDTH]
                ) * $signed(
                    kernel_data_q[(8*INPUT_WIDTH)+(mi*DATA_WIDTH)+:DATA_WIDTH]
                );
            end
        end else begin
            prod_valid <= 1'b0;
            prod_last  <= 1'b0;
        end
    end

    // MAC Stage 2: Adder Tree
    integer ai;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_valid <= 1'b0;
            mac_last  <= 1'b0;
            for (ai = 0; ai < LANES; ai = ai + 1) mac_result[ai] <= {ACC_WIDTH{1'b0}};
        end else if (prod_valid) begin
            mac_valid <= 1'b1;
            mac_last  <= prod_last;
            for (ai = 0; ai < LANES; ai = ai + 1) begin
                mac_result[ai] <=
                    {{(ACC_WIDTH-2*DATA_WIDTH){prod[0][ai][2*DATA_WIDTH-1]}}, prod[0][ai]} +
                    {{(ACC_WIDTH-2*DATA_WIDTH){prod[1][ai][2*DATA_WIDTH-1]}}, prod[1][ai]} +
                    {{(ACC_WIDTH-2*DATA_WIDTH){prod[2][ai][2*DATA_WIDTH-1]}}, prod[2][ai]} +
                    {{(ACC_WIDTH-2*DATA_WIDTH){prod[3][ai][2*DATA_WIDTH-1]}}, prod[3][ai]} +
                    {{(ACC_WIDTH-2*DATA_WIDTH){prod[4][ai][2*DATA_WIDTH-1]}}, prod[4][ai]} +
                    {{(ACC_WIDTH-2*DATA_WIDTH){prod[5][ai][2*DATA_WIDTH-1]}}, prod[5][ai]} +
                    {{(ACC_WIDTH-2*DATA_WIDTH){prod[6][ai][2*DATA_WIDTH-1]}}, prod[6][ai]} +
                    {{(ACC_WIDTH-2*DATA_WIDTH){prod[7][ai][2*DATA_WIDTH-1]}}, prod[7][ai]} +
                    {{(ACC_WIDTH-2*DATA_WIDTH){prod[8][ai][2*DATA_WIDTH-1]}}, prod[8][ai]};
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
