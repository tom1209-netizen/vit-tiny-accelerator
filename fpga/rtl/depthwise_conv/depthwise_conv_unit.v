`timescale 1ns / 1ps

module depthwise_conv_unit #(
    parameter DATA_WIDTH   = 8,    // Element width (INT8)
    parameter LANES        = 8,    // Parallel channels per beat
    parameter INPUT_WIDTH  = 64,   // 8 * 8 = 64 bits (input)
    parameter OUTPUT_WIDTH = 256,  // 8 * 32 = 256 bits (INT32 output)
    parameter MAX_WIDTH    = 28,   // Maximum image width (columns)
    parameter MAX_CHANNELS = 128,  // Maximum channels
    parameter ACC_WIDTH    = 32    // Accumulator width (INT32)
) (
    input wire clk,
    input wire rst_n,

    // Control interface
    input  wire        start,
    output reg         done,
    input  wire [15:0] cfg_height,
    input  wire [15:0] cfg_width,
    input  wire [15:0] cfg_channels,

    // Kernel weights input
    input  wire [INPUT_WIDTH-1:0] axis_kernel_in_tdata,
    input  wire                   axis_kernel_in_tvalid,
    output wire                   axis_kernel_in_tready,

    // Feature map input
    input  wire [INPUT_WIDTH-1:0] axis_data_in_tdata,
    input  wire                   axis_data_in_tvalid,
    input  wire                   axis_data_in_tlast,
    output wire                   axis_data_in_tready,

    // Feature map output
    output wire [OUTPUT_WIDTH-1:0] axis_data_out_tdata,
    output wire                    axis_data_out_tvalid,
    output wire                    axis_data_out_tlast,
    input  wire                    axis_data_out_tready
);

    // =========================================================================
    // Local Parameters
    // =========================================================================
    localparam KERNEL_SIZE = 9;
    localparam KERNEL_PACK_WIDTH = KERNEL_SIZE * INPUT_WIDTH;

    // =========================================================================
    // FSM States
    // =========================================================================
    localparam [3:0] S_IDLE        = 4'd0,
                     S_LOAD_KERNEL = 4'd1,
                     S_PROCESS     = 4'd2,
                     S_FETCH_LEFT  = 4'd3,
                     S_FETCH_CTR   = 4'd4,
                     S_FETCH_RIGHT = 4'd5,
                     S_FETCH_DONE  = 4'd6,
                     S_DONE        = 4'd7;

    reg [3:0] state, next_state;

    // =========================================================================
    // Configuration Registers
    // =========================================================================
    reg [15:0] num_rows;
    reg [15:0] num_cols;
    reg [15:0] num_chan_beats;
    reg [31:0] total_output_beats;

    // =========================================================================
    // Input/Output Tracking
    // =========================================================================
    reg [15:0] in_row, in_col, in_chan_beat;
    reg [15:0] in_beat_in_row;
    reg [ 1:0] in_row_mod3;

    reg [15:0] out_row, out_col, out_chan_beat;
    reg [31:0] out_beat_cnt;
    reg        processing_enabled;
    reg [ 1:0] out_row_mod3;
    reg [15:0] out_beat_in_row;

    // Pre-computed edge flags
    reg is_first_col_reg, is_last_col_reg;
    reg is_first_row_reg, is_last_row_reg;

    // Pre-computed row comparison flags
    reg                          in_row_gt_out_row_plus1;
    reg                          in_row_eq_out_row_plus1;
    reg                          in_row_gt_out_row;
    reg                          in_row_eq_out_row;

    // =========================================================================
    // Handshaking
    // =========================================================================
    wire                         kernel_handshake = axis_kernel_in_tvalid && axis_kernel_in_tready;
    wire                         input_handshake = axis_data_in_tvalid && axis_data_in_tready;
    wire                         output_handshake = axis_data_out_tvalid && axis_data_out_tready;

    // =========================================================================
    // Kernel Buffer Instance
    // =========================================================================
    wire                         kernel_load_done;
    wire [KERNEL_PACK_WIDTH-1:0] kernel_pack;
    reg  [                  3:0] kernel_chan_group_rd;

    kernel_buffer #(
        .DATA_WIDTH  (DATA_WIDTH),
        .LANES       (LANES),
        .INPUT_WIDTH (INPUT_WIDTH),
        .MAX_CHANNELS(MAX_CHANNELS),
        .KERNEL_SIZE (KERNEL_SIZE)
    ) u_kernel_buffer (
        .clk               (clk),
        .rst_n             (rst_n),
        .load_enable       (state == S_LOAD_KERNEL),
        .num_chan_beats    (num_chan_beats),
        .load_done         (kernel_load_done),
        .axis_kernel_tdata (axis_kernel_in_tdata),
        .axis_kernel_tvalid(axis_kernel_in_tvalid),
        .axis_kernel_tready(axis_kernel_in_tready),
        .chan_group        (kernel_chan_group_rd),
        .kernel_pack       (kernel_pack)
    );

    // =========================================================================
    // Line Buffer Instance
    // =========================================================================
    reg [15:0] lb_rd_addr;
    wire [INPUT_WIDTH-1:0] lb_rd_data_0, lb_rd_data_1, lb_rd_data_2;

    line_buffer #(
        .DATA_WIDTH  (DATA_WIDTH),
        .LANES       (LANES),
        .INPUT_WIDTH (INPUT_WIDTH),
        .MAX_WIDTH   (MAX_WIDTH),
        .MAX_CHANNELS(MAX_CHANNELS)
    ) u_line_buffer (
        .clk           (clk),
        .rst_n         (rst_n),
        .num_cols      (num_cols),
        .num_chan_beats(num_chan_beats),
        .wr_en         (input_handshake),
        .wr_row_sel    (in_row_mod3),
        .wr_addr       (in_beat_in_row),
        .wr_data       (axis_data_in_tdata),
        .rd_addr       (lb_rd_addr),
        .rd_data_0     (lb_rd_data_0),
        .rd_data_1     (lb_rd_data_1),
        .rd_data_2     (lb_rd_data_2)
    );

    // =========================================================================
    // MAC Unit Instance
    // =========================================================================
    wire                         mac_busy;
    wire                         mac_result_valid;
    wire                         mac_result_last;
    wire [     OUTPUT_WIDTH-1:0] mac_result_pack;

    reg                          mac_data_valid;
    reg                          mac_data_last;
    reg  [KERNEL_PACK_WIDTH-1:0] mac_win_pack;
    reg  [KERNEL_PACK_WIDTH-1:0] mac_ker_pack;

    mac_unit #(
        .DATA_WIDTH (DATA_WIDTH),
        .LANES      (LANES),
        .ACC_WIDTH  (ACC_WIDTH),
        .KERNEL_SIZE(KERNEL_SIZE)
    ) u_mac (
        .clk         (clk),
        .rst_n       (rst_n),
        .data_valid  (mac_data_valid),
        .data_last   (mac_data_last),
        .win_pack    (mac_win_pack),
        .ker_pack    (mac_ker_pack),
        .busy        (mac_busy),
        .result_valid(mac_result_valid),
        .result_last (mac_result_last),
        .result_pack (mac_result_pack)
    );

    // =========================================================================
    // Output Registers
    // =========================================================================
    reg [OUTPUT_WIDTH-1:0] out_data_reg;
    reg out_valid_reg;
    reg out_last_reg;
    reg last_beat_sent;
    reg last_fetch_initiated;

    assign axis_data_out_tdata  = out_data_reg;
    assign axis_data_out_tvalid = out_valid_reg;
    assign axis_data_out_tlast  = out_last_reg;

    // =========================================================================
    // Flow Control Logic
    // =========================================================================
    wire in_fetch_states = (state == S_FETCH_LEFT) || (state == S_FETCH_CTR) || (state == S_FETCH_RIGHT);
    wire input_within_safe_row = (in_row <= out_row + 1);

    assign axis_data_in_tready = ((state == S_PROCESS) || in_fetch_states) && 
                                  (!out_valid_reg || output_handshake) &&
                                  input_within_safe_row;

    // =========================================================================
    // Data Availability Logic (Pipelined)
    // =========================================================================
    wire is_last_output_row = is_last_row_reg;
    wire is_last_output_col = (out_col == num_cols - 1);
    wire is_last_chan_beat = (out_chan_beat == num_chan_beats - 1);
    wire is_last_output_beat = is_last_output_row && is_last_output_col && is_last_chan_beat;

    // Stage 0: Pre-pipeline DSP inputs
    reg [15:0] next_col_pre;
    reg [15:0] num_chan_beats_pre;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            next_col_pre       <= 16'd0;
            num_chan_beats_pre <= 16'd0;
        end else begin
            next_col_pre       <= out_col + 1;
            num_chan_beats_pre <= num_chan_beats;
        end
    end

    // Stage 1: DSP multiply
    reg [31:0] next_col_beat_r;
    reg        is_last_output_col_d;
    reg [15:0] num_chan_beats_d;
    reg [15:0] out_chan_beat_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            next_col_beat_r      <= 32'd0;
            is_last_output_col_d <= 1'b0;
            num_chan_beats_d     <= 16'd0;
            out_chan_beat_d      <= 16'd0;
        end else begin
            next_col_beat_r      <= next_col_pre * num_chan_beats_pre;
            is_last_output_col_d <= is_last_output_col;
            num_chan_beats_d     <= num_chan_beats;
            out_chan_beat_d      <= out_chan_beat;
        end
    end

    // Stage 2: Apply adjustment
    reg [31:0] needed_beat_r;
    reg        is_last_output_row_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            needed_beat_r        <= 32'd0;
            is_last_output_row_r <= 1'b0;
        end else begin
            is_last_output_row_r <= is_last_output_row;
            if (is_last_output_col_d)
                needed_beat_r <= next_col_beat_r - num_chan_beats_d + out_chan_beat_d;
            else needed_beat_r <= next_col_beat_r + out_chan_beat_d;
        end
    end

    // Pipeline countdown
    reg [1:0] pipeline_countdown;
    wire in_row_will_change = input_handshake && 
                              (in_chan_beat == num_chan_beats - 1) && 
                              (in_col == num_cols - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipeline_countdown <= 2'd0;
        end else if (state == S_FETCH_DONE) begin
            pipeline_countdown <= 2'd2;
        end else if (in_row_will_change && pipeline_countdown < 2'd1) begin
            pipeline_countdown <= 2'd1;
        end else if (pipeline_countdown != 2'd0) begin
            pipeline_countdown <= pipeline_countdown - 1'd1;
        end
    end

    wire pipeline_valid = (pipeline_countdown == 2'd0);

    wire has_row_below_data = is_last_output_row ||
                              in_row_gt_out_row_plus1 ||
                              (in_row_eq_out_row_plus1 && in_beat_in_row > needed_beat_r[15:0]);

    wire has_current_row_data = in_row_gt_out_row ||
                                (in_row_eq_out_row && in_beat_in_row > needed_beat_r[15:0]);

    wire can_start_fetch = processing_enabled && pipeline_valid &&
                           has_row_below_data && has_current_row_data && 
                           (!out_valid_reg || output_handshake) &&
                           !mac_busy;

    // =========================================================================
    // Beat Address Computation
    // =========================================================================
    wire [15:0] beat_center = out_beat_in_row;
    wire [15:0] beat_left_normal = out_beat_in_row - num_chan_beats;
    wire [15:0] beat_right_normal = out_beat_in_row + num_chan_beats;
    wire [15:0] beat_left = is_first_col_reg ? out_beat_in_row : beat_left_normal;
    wire [15:0] beat_right = is_last_col_reg ? out_beat_in_row : beat_right_normal;

    // Row indices in circular buffer
    wire [1:0] row_center_idx = out_row_mod3;
    wire [1:0] row_above_idx = (out_row == 0) ? 2'd0 : 
                               (out_row_mod3 == 2'd0) ? 2'd2 : out_row_mod3 - 1;
    wire [1:0] row_below_idx = (out_row == num_rows - 1) ? 2'd0 :
                               (out_row_mod3 == 2'd2) ? 2'd0 : out_row_mod3 + 1;

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
                if (kernel_load_done) next_state = S_PROCESS;
            end
            S_PROCESS: begin
                if (last_beat_sent) next_state = S_DONE;
                else if (can_start_fetch && !last_fetch_initiated) next_state = S_FETCH_LEFT;
            end
            S_FETCH_LEFT:  next_state = S_FETCH_CTR;
            S_FETCH_CTR:   next_state = S_FETCH_RIGHT;
            S_FETCH_RIGHT: next_state = S_FETCH_DONE;
            S_FETCH_DONE:  next_state = S_PROCESS;
            S_DONE:        next_state = S_IDLE;
            default:       next_state = S_IDLE;
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
        end else if (state == S_IDLE && start) begin
            num_rows           <= cfg_height;
            num_cols           <= cfg_width;
            num_chan_beats     <= cfg_channels >> 3;
            total_output_beats <= cfg_height * cfg_width * (cfg_channels >> 3);
        end
    end

    // =========================================================================
    // Input Tracking
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

    // =========================================================================
    // Pre-computed Row Comparison Flags
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_row_gt_out_row_plus1 <= 1'b0;
            in_row_eq_out_row_plus1 <= 1'b0;
            in_row_gt_out_row       <= 1'b0;
            in_row_eq_out_row       <= 1'b1;
        end else begin
            in_row_gt_out_row_plus1 <= (in_row > out_row + 1);
            in_row_eq_out_row_plus1 <= (in_row == out_row + 1);
            in_row_gt_out_row       <= (in_row > out_row);
            in_row_eq_out_row       <= (in_row == out_row);
        end
    end

    // =========================================================================
    // Output Position Tracking
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
            is_first_col_reg   <= 1'b1;
            is_last_col_reg    <= 1'b0;
            is_first_row_reg   <= 1'b1;
            is_last_row_reg    <= 1'b0;
        end else if (state == S_IDLE) begin
            out_row            <= 16'd0;
            out_col            <= 16'd0;
            out_chan_beat      <= 16'd0;
            out_beat_cnt       <= 32'd0;
            processing_enabled <= 1'b0;
            out_row_mod3       <= 2'd0;
            out_beat_in_row    <= 16'd0;
            is_first_col_reg   <= 1'b1;
            is_last_col_reg    <= (num_cols == 16'd1);
            is_first_row_reg   <= 1'b1;
            is_last_row_reg    <= (num_rows == 16'd1);
        end else begin
            if (in_row >= 1 || (in_row == 0 && in_col > 0)) processing_enabled <= 1'b1;
            if (output_handshake && out_valid_reg) out_beat_cnt <= out_beat_cnt + 1;

            if (state == S_FETCH_DONE) begin
                if (out_chan_beat == num_chan_beats - 1) begin
                    out_chan_beat <= 16'd0;
                    if (out_col == num_cols - 1) begin
                        out_col          <= 16'd0;
                        out_row          <= out_row + 1;
                        out_beat_in_row  <= 16'd0;
                        out_row_mod3     <= (out_row_mod3 == 2'd2) ? 2'd0 : out_row_mod3 + 1;
                        is_first_col_reg <= 1'b1;
                        is_last_col_reg  <= (num_cols == 16'd1);
                        is_first_row_reg <= 1'b0;
                        is_last_row_reg  <= (out_row == num_rows - 2);
                    end else begin
                        out_col          <= out_col + 1;
                        out_beat_in_row  <= out_beat_in_row + 1;
                        is_first_col_reg <= 1'b0;
                        is_last_col_reg  <= (out_col == num_cols - 2);
                    end
                end else begin
                    out_chan_beat   <= out_chan_beat + 1;
                    out_beat_in_row <= out_beat_in_row + 1;
                end
            end
        end
    end

    // =========================================================================
    // Window Fetch Metadata
    // =========================================================================
    reg [15:0] fetch_chan_beat;
    reg        fetch_is_last;
    reg is_top_row_r, is_bottom_row_r, is_left_col_r, is_right_col_r;
    reg [1:0] row_above_idx_r, row_center_idx_r, row_below_idx_r;
    reg [15:0] beat_left_r, beat_center_r, beat_right_r;

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

    // Update kernel read address
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            kernel_chan_group_rd <= 4'd0;
        end else if (state == S_PROCESS && next_state == S_FETCH_LEFT) begin
            kernel_chan_group_rd <= out_chan_beat[3:0];
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
            S_FETCH_LEFT: lb_rd_addr <= beat_center_r;
            S_FETCH_CTR: lb_rd_addr <= beat_right_r;
            default: ;
        endcase
    end

    // =========================================================================
    // Window Data Capture and Border Padding
    // =========================================================================
    reg [INPUT_WIDTH-1:0] win_word_row0[0:2];
    reg [INPUT_WIDTH-1:0] win_word_row1[0:2];
    reg [INPUT_WIDTH-1:0] win_word_row2[0:2];

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

    wire [INPUT_WIDTH-1:0] row_above_data = select_row_data(
        row_above_idx_r, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2
    );
    wire [INPUT_WIDTH-1:0] row_center_data = select_row_data(
        row_center_idx_r, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2
    );
    wire [INPUT_WIDTH-1:0] row_below_data = select_row_data(
        row_below_idx_r, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2
    );

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
                    // Left column data ready
                    win_word_row0[0] <= is_left_col_r ? {INPUT_WIDTH{1'b0}} : 
                                       (is_top_row_r ? {INPUT_WIDTH{1'b0}} : row_above_data);
                    win_word_row1[0] <= is_left_col_r ? {INPUT_WIDTH{1'b0}} : row_center_data;
                    win_word_row2[0] <= is_left_col_r ? {INPUT_WIDTH{1'b0}} : 
                                       (is_bottom_row_r ? {INPUT_WIDTH{1'b0}} : row_below_data);
                end
                S_FETCH_RIGHT: begin
                    // Center column data ready
                    win_word_row0[1] <= is_top_row_r ? {INPUT_WIDTH{1'b0}} : row_above_data;
                    win_word_row1[1] <= row_center_data;
                    win_word_row2[1] <= is_bottom_row_r ? {INPUT_WIDTH{1'b0}} : row_below_data;
                end
                S_FETCH_DONE: begin
                    // Right column data ready
                    win_word_row0[2] <= is_right_col_r ? {INPUT_WIDTH{1'b0}} : 
                                       (is_top_row_r ? {INPUT_WIDTH{1'b0}} : row_above_data);
                    win_word_row1[2] <= is_right_col_r ? {INPUT_WIDTH{1'b0}} : row_center_data;
                    win_word_row2[2] <= is_right_col_r ? {INPUT_WIDTH{1'b0}} : 
                                       (is_bottom_row_r ? {INPUT_WIDTH{1'b0}} : row_below_data);
                end
            endcase
        end
    end

    // =========================================================================
    // Prepare MAC Input Data - Pack window and kernel into flat vectors
    // Need to delay by one cycle after S_FETCH_DONE so win_word[2] is stable
    // =========================================================================
    reg mac_prepare;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_prepare <= 1'b0;
        end else begin
            mac_prepare <= (state == S_FETCH_DONE);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_data_valid <= 1'b0;
            mac_data_last  <= 1'b0;
            mac_win_pack   <= {KERNEL_PACK_WIDTH{1'b0}};
            mac_ker_pack   <= {KERNEL_PACK_WIDTH{1'b0}};
        end else if (mac_prepare) begin
            // Now win_word[2] has been captured in the previous cycle
            mac_data_valid <= 1'b1;
            mac_data_last <= fetch_is_last;
            // Pack window: position 0-8, each position is 64-bit (8 lanes x 8 bits)
            // Layout: [pos0_lane0..7][pos1_lane0..7]...[pos8_lane0..7]
            mac_win_pack[0*INPUT_WIDTH+:INPUT_WIDTH] <= win_word_row0[0];  // pos 0 (top-left)
            mac_win_pack[1*INPUT_WIDTH+:INPUT_WIDTH] <= win_word_row0[1];  // pos 1 (top-center)
            mac_win_pack[2*INPUT_WIDTH+:INPUT_WIDTH] <= win_word_row0[2];  // pos 2 (top-right)
            mac_win_pack[3*INPUT_WIDTH+:INPUT_WIDTH] <= win_word_row1[0];  // pos 3 (mid-left)
            mac_win_pack[4*INPUT_WIDTH+:INPUT_WIDTH] <= win_word_row1[1];  // pos 4 (mid-center)
            mac_win_pack[5*INPUT_WIDTH+:INPUT_WIDTH] <= win_word_row1[2];  // pos 5 (mid-right)
            mac_win_pack[6*INPUT_WIDTH+:INPUT_WIDTH] <= win_word_row2[0];  // pos 6 (bot-left)
            mac_win_pack[7*INPUT_WIDTH+:INPUT_WIDTH] <= win_word_row2[1];  // pos 7 (bot-center)
            mac_win_pack[8*INPUT_WIDTH+:INPUT_WIDTH] <= win_word_row2[2];  // pos 8 (bot-right)
            // Kernel is already packed
            mac_ker_pack <= kernel_pack;
        end else begin
            mac_data_valid <= 1'b0;
        end
    end

    // =========================================================================
    // Output Assembly
    // =========================================================================
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
            if (mac_result_valid) begin
                out_data_reg  <= mac_result_pack;
                out_valid_reg <= 1'b1;
                out_last_reg  <= mac_result_last;
            end
        end
    end

    // =========================================================================
    // Done Signal
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) done <= 1'b0;
        else if (state == S_DONE && last_beat_sent) done <= 1'b1;
        else done <= 1'b0;
    end

endmodule
