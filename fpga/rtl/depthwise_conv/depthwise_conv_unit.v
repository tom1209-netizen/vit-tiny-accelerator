`timescale 1ns / 1ps

module depthwise_conv_unit #(
    parameter DATA_WIDTH   = 8,    // Element width (INT8)
    parameter LANES        = 8,    // Parallel channels per beat
    parameter INPUT_WIDTH  = 64,   // 8 * 8 = 64 bits (input)
    parameter OUTPUT_WIDTH = 256,  // 8 * 32 = 256 bits (INT32 output)
    parameter MAX_WIDTH    = 64,   // Maximum image width (columns)
    parameter MAX_CHANNELS = 512,  // Maximum channels
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


    // Local Parameters
    localparam KERNEL_SIZE = 9;  // 3x3 kernel
    localparam MAX_BEATS_ROW = MAX_WIDTH * (MAX_CHANNELS / LANES);  // Max beats per row


    // FSM States
    localparam [2:0] S_IDLE = 3'd0, S_LOAD_KERNEL = 3'd1, S_PROCESS = 3'd2, S_DONE = 3'd3;

    reg [2:0] state, next_state;


    // Configuration Registers (latched on start)
    reg [15:0] num_rows;  // Image height
    reg [15:0] num_cols;  // Image width  
    reg [15:0] num_chan_beats;  // = channels / 8
    reg [15:0] beats_per_row;  // = num_cols * num_chan_beats
    reg [31:0] total_output_beats;  // = num_rows * beats_per_row
    reg [15:0] total_kernel_beats;  // = num_chan_beats * 9


    // Kernel Weight Storage
    // kernel_mem[chan_beat][coeff_idx][lane] = INT8 kernel coefficient
    reg signed [DATA_WIDTH-1:0] kernel_mem[0:(MAX_CHANNELS/LANES)-1][0:KERNEL_SIZE-1][0:LANES-1];
    reg [15:0] kernel_load_cnt;
    reg [3:0] kernel_coeff_idx;  // 0-8 for 9 coefficients

    // Initialize kernel memory for simulation
    integer init_kb, init_kc, init_kl;
    initial begin
        for (init_kb = 0; init_kb < MAX_CHANNELS / LANES; init_kb = init_kb + 1)
        for (init_kc = 0; init_kc < KERNEL_SIZE; init_kc = init_kc + 1)
        for (init_kl = 0; init_kl < LANES; init_kl = init_kl + 1)
        kernel_mem[init_kb][init_kc][init_kl] = 0;
    end


    // Line Buffers - Store 3 rows for 3x3 window
    // Each entry stores one beat (8 channels)
    // line_buf[row_idx][beat_idx][lane]
    reg signed [DATA_WIDTH-1:0] line_buf[0:2][0:MAX_BEATS_ROW-1][0:LANES-1];

    // Track which line buffer slot holds which relative row
    // row_mapping[0] = oldest row (row-2), row_mapping[2] = newest row (row)
    reg [1:0] row_slot[0:2];  // Circular buffer indices

    // Initialize line buffer for simulation (BRAM inits to 0 in hardware)
    integer init_row, init_beat, init_lane;
    initial begin
        for (init_row = 0; init_row < 3; init_row = init_row + 1)
        for (init_beat = 0; init_beat < MAX_BEATS_ROW; init_beat = init_beat + 1)
        for (init_lane = 0; init_lane < LANES; init_lane = init_lane + 1)
        line_buf[init_row][init_beat][init_lane] = 0;
    end


    // Input Tracking
    reg [15:0] in_row;  // Current input row (0 to H-1)
    reg [15:0] in_col;  // Current input column (0 to W-1)
    reg [15:0] in_chan_beat;  // Current channel beat (0 to C/8-1)
    reg [15:0] in_beat_in_row;  // Beat index within current row


    // Output Processing Tracking
    reg [15:0] out_row;  // Current output row being computed
    reg [15:0] out_col;  // Current output column
    reg [15:0] out_chan_beat;  // Current output channel beat
    reg [31:0] out_beat_cnt;  // Total output beats CONSUMED
    reg [31:0] win_gen_cnt;  // Total windows GENERATED (separate from consumed)
    reg processing_enabled;  // Can start processing (have enough rows)


    // Window Extraction Pipeline
    // Stage 0: Read window data from line buffers
    reg signed [DATA_WIDTH-1:0] win_row0[0:2][0:LANES-1];  // Row above (or padding)
    reg signed [DATA_WIDTH-1:0] win_row1[0:2][0:LANES-1];  // Current row
    reg signed [DATA_WIDTH-1:0] win_row2[0:2][0:LANES-1];  // Row below (or padding)
    reg win_valid_s0;
    reg win_last_s0;
    reg [15:0] win_chan_beat_s0;

    // Stage 1: Apply kernel multiplication
    reg signed [2*DATA_WIDTH-1:0] prod[0:KERNEL_SIZE-1][0:LANES-1];
    reg prod_valid;
    reg prod_last;
    reg [15:0] prod_chan_beat;

    // Stage 2: Adder tree result
    reg signed [ACC_WIDTH-1:0] mac_result[0:LANES-1];
    reg mac_valid;
    reg mac_last;


    // Output Registers
    reg [OUTPUT_WIDTH-1:0] out_data_reg;
    reg out_valid_reg;
    reg out_last_reg;
    reg last_beat_sent;  // Flag to indicate last output has been consumed


    // Handshaking
    wire kernel_handshake = axis_kernel_in_tvalid && axis_kernel_in_tready;
    wire input_handshake = axis_data_in_tvalid && axis_data_in_tready;
    wire output_handshake = axis_data_out_tvalid && axis_data_out_tready;

    assign axis_kernel_in_tready = (state == S_LOAD_KERNEL);

    // Accept input when processing and output has room or is being consumed
    assign axis_data_in_tready   = (state == S_PROCESS) && (!out_valid_reg || output_handshake);

    assign axis_data_out_tdata   = out_data_reg;
    assign axis_data_out_tvalid  = out_valid_reg;
    assign axis_data_out_tlast   = out_last_reg;


    // FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (start && cfg_height > 0 && cfg_width > 0 && cfg_channels >= LANES)
                    next_state = S_LOAD_KERNEL;
            end
            S_LOAD_KERNEL: begin
                // Done loading all kernel weights
                if (kernel_load_cnt >= total_kernel_beats - 1 && kernel_handshake)
                    next_state = S_PROCESS;
            end
            S_PROCESS: begin
                // Done when last output has been consumed
                if (last_beat_sent) next_state = S_DONE;
            end
            S_DONE: begin
                next_state = S_IDLE;
            end
            default: next_state = S_IDLE;
        endcase
    end


    // Configuration Capture
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            num_rows           <= 0;
            num_cols           <= 0;
            num_chan_beats     <= 0;
            beats_per_row      <= 0;
            total_output_beats <= 0;
            total_kernel_beats <= 0;
        end else if (state == S_IDLE && start) begin
            num_rows           <= cfg_height;
            num_cols           <= cfg_width;
            num_chan_beats     <= cfg_channels >> 3;
            beats_per_row      <= cfg_width * (cfg_channels >> 3);
            total_output_beats <= cfg_height * cfg_width * (cfg_channels >> 3);
            total_kernel_beats <= (cfg_channels >> 3) * KERNEL_SIZE;
        end
    end


    // Kernel Loading
    integer kl;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            kernel_load_cnt  <= 0;
            kernel_coeff_idx <= 0;
        end else if (state == S_IDLE) begin
            kernel_load_cnt  <= 0;
            kernel_coeff_idx <= 0;
        end else if (state == S_LOAD_KERNEL && kernel_handshake) begin
            // Store 8 kernel coefficients (one per lane)
            for (kl = 0; kl < LANES; kl = kl + 1) begin
                kernel_mem[kernel_load_cnt/KERNEL_SIZE][kernel_coeff_idx][kl] <=
                    $signed(axis_kernel_in_tdata[kl*DATA_WIDTH+:DATA_WIDTH]);
            end

            kernel_load_cnt <= kernel_load_cnt + 1;

            if (kernel_coeff_idx == KERNEL_SIZE - 1) kernel_coeff_idx <= 0;
            else kernel_coeff_idx <= kernel_coeff_idx + 1;
        end
    end


    // Input Reception & Line Buffer Storage
    integer il;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_row         <= 0;
            in_col         <= 0;
            in_chan_beat   <= 0;
            in_beat_in_row <= 0;
        end else if (state == S_IDLE) begin
            in_row         <= 0;
            in_col         <= 0;
            in_chan_beat   <= 0;
            in_beat_in_row <= 0;
        end else if (state == S_PROCESS && input_handshake) begin
            // Store input into line buffer (circular, row % 3)
            for (il = 0; il < LANES; il = il + 1) begin
                line_buf[in_row%3][in_beat_in_row][il] <=
                    $signed(axis_data_in_tdata[il*DATA_WIDTH+:DATA_WIDTH]);
            end

            // Advance position counters
            if (in_chan_beat == num_chan_beats - 1) begin
                in_chan_beat <= 0;
                if (in_col == num_cols - 1) begin
                    in_col <= 0;
                    in_row <= in_row + 1;
                    in_beat_in_row <= 0;
                end else begin
                    in_col <= in_col + 1;
                    in_beat_in_row <= in_beat_in_row + 1;
                end
            end else begin
                in_chan_beat   <= in_chan_beat + 1;
                in_beat_in_row <= in_beat_in_row + 1;
            end
        end
    end


    // Output Position Tracking
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_row            <= 0;
            out_col            <= 0;
            out_chan_beat      <= 0;
            out_beat_cnt       <= 0;
            win_gen_cnt        <= 0;
            processing_enabled <= 0;
        end else if (state == S_IDLE) begin
            out_row            <= 0;
            out_col            <= 0;
            out_chan_beat      <= 0;
            out_beat_cnt       <= 0;
            win_gen_cnt        <= 0;
            processing_enabled <= 0;
        end else if (state == S_PROCESS) begin
            // Enable processing once we have first row of input
            // (For row 0, we use zero padding for row above)
            if (in_row >= 1 || (in_row == 0 && in_col > 0)) processing_enabled <= 1;

            // Advance output position when output is consumed (just for count tracking)
            if (output_handshake && out_valid_reg) begin
                out_beat_cnt <= out_beat_cnt + 1;
            end
        end
    end

    // Window Extraction - Stage 0
    // Extract 3x3 window with zero padding for borders
    // For output pixel at (out_row, out_col), we need:
    //   - Row above: line_buf[(out_row-1) % 3] or zeros if out_row == 0
    //   - Center row: line_buf[out_row % 3]
    //   - Row below: line_buf[(out_row+1) % 3] or zeros if out_row == H-1
    // Similar for columns: left/right neighbors or zeros at borders

    // For a 3x3 window, we need the row BELOW to be buffered before we can process
    // Exception: for the last row, we use zero padding so we don't need row below
    // CRITICAL: We must process output row N BEFORE input row N+3 arrives,
    //           because row N+3 would overwrite row N's line buffer slot!
    wire is_last_output_row = (out_row == num_rows - 1);
    wire is_last_output_col = (out_col == num_cols - 1);

    // For columns, we need the RIGHT neighbor which is at col+1 (or padding if last col)
    wire [15:0] needed_beat = is_last_output_col ? 
                              (out_col * num_chan_beats + out_chan_beat) :
                              ((out_col + 1) * num_chan_beats + out_chan_beat);

    // Row below data availability:
    // - For last output row: use zero padding, always available
    // - Otherwise: need in_row >= out_row + 2 (row_below complete), OR
    //              in_row == out_row + 1 and we have enough beats for col_right
    wire has_row_below_data = is_last_output_row || 
                               (in_row > out_row + 1) ||
                               (in_row == out_row + 1 && in_beat_in_row > needed_beat);

    wire has_current_row_data = (in_row > out_row) || 
                                 (in_row == out_row && in_beat_in_row > needed_beat);

    wire can_produce_output = processing_enabled && has_row_below_data && has_current_row_data;

    // Calculate beat indices for the 3 columns in the window
    wire [15:0] col_left = (out_col == 0) ? 0 : out_col - 1;
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

    integer wi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_valid_s0     <= 0;
            win_last_s0      <= 0;
            win_chan_beat_s0 <= 0;
            for (wi = 0; wi < LANES; wi = wi + 1) begin
                win_row0[0][wi] <= 0;
                win_row0[1][wi] <= 0;
                win_row0[2][wi] <= 0;
                win_row1[0][wi] <= 0;
                win_row1[1][wi] <= 0;
                win_row1[2][wi] <= 0;
                win_row2[0][wi] <= 0;
                win_row2[1][wi] <= 0;
                win_row2[2][wi] <= 0;
            end
        end else if (state == S_PROCESS && can_produce_output && (!out_valid_reg || output_handshake)) begin
            win_valid_s0     <= 1;
            win_last_s0      <= (win_gen_cnt == total_output_beats - 1);
            win_chan_beat_s0 <= out_chan_beat;
            win_gen_cnt      <= win_gen_cnt + 1;  // Track windows generated

            // Advance position counters for NEXT window
            if (out_chan_beat == num_chan_beats - 1) begin
                out_chan_beat <= 0;
                if (out_col == num_cols - 1) begin
                    out_col <= 0;
                    out_row <= out_row + 1;
                end else begin
                    out_col <= out_col + 1;
                end
            end else begin
                out_chan_beat <= out_chan_beat + 1;
            end

            for (wi = 0; wi < LANES; wi = wi + 1) begin
                // Row above (row 0 of window)
                if (is_top_row) begin
                    win_row0[0][wi] <= 0;  // Zero padding
                    win_row0[1][wi] <= 0;
                    win_row0[2][wi] <= 0;
                end else begin
                    win_row0[0][wi] <= is_left_col ? 8'sd0 : line_buf[row_above_idx][beat_left][wi];
                    win_row0[1][wi] <= line_buf[row_above_idx][beat_center][wi];
                    win_row0[2][wi] <= is_right_col ? 8'sd0 : line_buf[row_above_idx][beat_right][wi];
                end

                // Center row (row 1 of window)
                win_row1[0][wi] <= is_left_col ? 8'sd0 : line_buf[row_center_idx][beat_left][wi];
                win_row1[1][wi] <= line_buf[row_center_idx][beat_center][wi];
                win_row1[2][wi] <= is_right_col ? 8'sd0 : line_buf[row_center_idx][beat_right][wi];

                // Row below (row 2 of window)
                if (is_bottom_row) begin
                    win_row2[0][wi] <= 0;  // Zero padding
                    win_row2[1][wi] <= 0;
                    win_row2[2][wi] <= 0;
                end else begin
                    win_row2[0][wi] <= is_left_col ? 8'sd0 : line_buf[row_below_idx][beat_left][wi];
                    win_row2[1][wi] <= line_buf[row_below_idx][beat_center][wi];
                    win_row2[2][wi] <= is_right_col ? 8'sd0 : line_buf[row_below_idx][beat_right][wi];
                end
            end
        end else begin
            win_valid_s0 <= 0;
        end
    end


    // MAC Stage 1: Multiply window with kernel
    integer mi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_valid     <= 0;
            prod_last      <= 0;
            prod_chan_beat <= 0;
            for (mi = 0; mi < LANES; mi = mi + 1) begin
                prod[0][mi] <= 0;
                prod[1][mi] <= 0;
                prod[2][mi] <= 0;
                prod[3][mi] <= 0;
                prod[4][mi] <= 0;
                prod[5][mi] <= 0;
                prod[6][mi] <= 0;
                prod[7][mi] <= 0;
                prod[8][mi] <= 0;
            end
        end else if (win_valid_s0) begin
            prod_valid     <= 1;
            prod_last      <= win_last_s0;
            prod_chan_beat <= win_chan_beat_s0;

            for (mi = 0; mi < LANES; mi = mi + 1) begin
                // Window position [row][col] -> kernel index:
                // [0][0]=0, [0][1]=1, [0][2]=2
                // [1][0]=3, [1][1]=4, [1][2]=5
                // [2][0]=6, [2][1]=7, [2][2]=8
                prod[0][mi] <= win_row0[0][mi] * kernel_mem[win_chan_beat_s0][0][mi];
                prod[1][mi] <= win_row0[1][mi] * kernel_mem[win_chan_beat_s0][1][mi];
                prod[2][mi] <= win_row0[2][mi] * kernel_mem[win_chan_beat_s0][2][mi];
                prod[3][mi] <= win_row1[0][mi] * kernel_mem[win_chan_beat_s0][3][mi];
                prod[4][mi] <= win_row1[1][mi] * kernel_mem[win_chan_beat_s0][4][mi];
                prod[5][mi] <= win_row1[2][mi] * kernel_mem[win_chan_beat_s0][5][mi];
                prod[6][mi] <= win_row2[0][mi] * kernel_mem[win_chan_beat_s0][6][mi];
                prod[7][mi] <= win_row2[1][mi] * kernel_mem[win_chan_beat_s0][7][mi];
                prod[8][mi] <= win_row2[2][mi] * kernel_mem[win_chan_beat_s0][8][mi];
            end
        end else begin
            prod_valid <= 0;
        end
    end


    // MAC Stage 2: Adder Tree (9 inputs -> 1 sum per lane)
    integer ai;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_valid <= 0;
            mac_last  <= 0;
            for (ai = 0; ai < LANES; ai = ai + 1) mac_result[ai] <= 0;
        end else if (prod_valid) begin
            mac_valid <= 1;
            mac_last  <= prod_last;

            for (ai = 0; ai < LANES; ai = ai + 1) begin
                // Sign-extend 16-bit products to 32-bit and sum
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
            mac_valid <= 0;
        end
    end


    // Output Assembly (INT32)
    integer oi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_data_reg   <= 0;
            out_valid_reg  <= 0;
            out_last_reg   <= 0;
            last_beat_sent <= 0;
        end else if (state == S_IDLE) begin
            out_valid_reg  <= 0;
            out_last_reg   <= 0;
            last_beat_sent <= 0;
        end else begin
            // Default: hold output if not consumed
            if (output_handshake) begin
                out_valid_reg <= 0;
                // Track when last beat is consumed
                if (out_last_reg) last_beat_sent <= 1;
            end

            // New MAC result available
            if (mac_valid) begin
                // Pack 8 x INT32 into 256-bit output
                for (oi = 0; oi < LANES; oi = oi + 1) begin
                    out_data_reg[oi*ACC_WIDTH+:ACC_WIDTH] <= mac_result[oi];
                end
                out_valid_reg <= 1;
                out_last_reg  <= mac_last;
            end
        end
    end

    // Done Signal
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) done <= 0;
        else if (state == S_DONE) done <= 1;
        else done <= 0;
    end

endmodule
