`timescale 1ns / 1ps

module depthwise_conv_unit #(
    parameter DATA_WIDTH   = 8,    // Element width (INT8)
    parameter LANES        = 8,    // Parallel channels per beat
    parameter INPUT_WIDTH  = 64,   // 8 * 8 = 64 bits (input)
    parameter OUTPUT_WIDTH = 64,   // AXI output width (must divide LANES*ACC_WIDTH)
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
    input  wire                   axis_kernel_in_tlast,
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
    // Local Parameters
    localparam KERNEL_SIZE = 9;
    localparam KERNEL_PACK_WIDTH = KERNEL_SIZE * INPUT_WIDTH;
    localparam MAX_CHAN_BEATS = MAX_CHANNELS / LANES;
    localparam SHIFT_DEPTH = 2 * MAX_CHAN_BEATS + 1;
    localparam MAC_WIDTH = LANES * ACC_WIDTH;
    localparam OUT_SLICES = MAC_WIDTH / OUTPUT_WIDTH;
    localparam OUT_SLICE_W = (OUT_SLICES <= 1) ? 1 : $clog2(OUT_SLICES);
    localparam OUT_FIFO_DEPTH = 16;
    localparam OUT_FIFO_PTR_W = (OUT_FIFO_DEPTH <= 1) ? 1 : $clog2(OUT_FIFO_DEPTH);
    localparam OUT_FIFO_CNT_W = $clog2(OUT_FIFO_DEPTH + 1);
    localparam PENDING_W = $clog2(OUT_FIFO_DEPTH + KERNEL_SIZE + 1);
    localparam IN_FIFO_DEPTH = MAX_WIDTH * MAX_CHAN_BEATS;
    localparam IN_FIFO_PTR_W = (IN_FIFO_DEPTH <= 1) ? 1 : $clog2(IN_FIFO_DEPTH);
    localparam IN_FIFO_CNT_W = $clog2(IN_FIFO_DEPTH + 1);


    // FSM States
    localparam [1:0] S_IDLE = 2'd0, S_LOAD_KERNEL = 2'd1, S_PROCESS = 2'd2, S_DONE = 2'd3;

    reg [1:0] state, next_state;


    // Configuration Registers
    reg [15:0] num_rows;
    reg [15:0] num_cols;
    reg [15:0] num_chan_beats;


    // Input stream tracking
    reg [15:0] in_row, in_col, in_chan_beat;
    reg [15:0] in_beat_in_row;
    reg [ 1:0] in_row_mod3;

    // Output stream tracking
    reg [15:0] out_row, out_col, out_chan_beat;
    reg issued_last;

    // Read/issue pipeline state
    reg [15:0] rd_row, rd_col, rd_chan_beat;
    reg [1:0] rd_row_mod3;
    reg [15:0] rd_beat_in_row;
    reg pad_active;
    reg [15:0] pad_chan_beat;
    reg prefetch_active;
    reg [15:0] prefetch_count;
    reg shift_bank_sel;
    reg issue_bank_sel_d;
    reg prefetch_bank_sel_d;
    reg prefetch_bank_sel_dd;


    // Handshaking
    wire input_handshake = axis_data_in_tvalid && axis_data_in_tready;
    reg input_stream_done;


    // Input FIFO (decouple AXIS input from line buffer writes)
    (* ram_style = "block" *)
    reg [INPUT_WIDTH-1:0] in_fifo_mem[0:IN_FIFO_DEPTH-1];
    reg [IN_FIFO_PTR_W-1:0] in_fifo_wr_ptr;
    reg [IN_FIFO_PTR_W-1:0] in_fifo_rd_ptr;
    reg [IN_FIFO_CNT_W-1:0] in_fifo_count;
    reg [INPUT_WIDTH-1:0] in_fifo_rd_data_q;
    reg in_fifo_pop_q;

    wire in_fifo_full = (in_fifo_count == IN_FIFO_DEPTH);
    wire in_fifo_empty = (in_fifo_count == 0);
    wire in_fifo_push = input_handshake;
    wire in_fifo_pop_req;


    // Kernel Buffer Instance
    wire kernel_load_done;
    wire [KERNEL_PACK_WIDTH-1:0] kernel_pack;
    wire [3:0] kernel_chan_group_rd = out_chan_beat[3:0];

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
        .axis_kernel_tlast (axis_kernel_in_tlast),
        .axis_kernel_tready(axis_kernel_in_tready),
        .chan_group        (kernel_chan_group_rd),
        .kernel_pack       (kernel_pack)
    );


    // Line Buffer Instance
    reg [15:0] lb_rd_addr;
    wire [INPUT_WIDTH-1:0] lb_rd_data_0, lb_rd_data_1, lb_rd_data_2, lb_rd_data_3;

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
        .wr_en         (in_fifo_pop_q),
        .wr_row_sel    (in_row_mod3),
        .wr_addr       (in_beat_in_row),
        .wr_data       (in_fifo_rd_data_q),
        .rd_addr       (lb_rd_addr),
        .rd_data_0     (lb_rd_data_0),
        .rd_data_1     (lb_rd_data_1),
        .rd_data_2     (lb_rd_data_2),
        .rd_data_3     (lb_rd_data_3)
    );


    // MAC Unit Instance
    wire                         mac_busy;
    wire                         mac_result_valid;
    wire                         mac_result_last;
    wire [        MAC_WIDTH-1:0] mac_result_pack;

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


    // Output Serializer + FIFO
    reg [MAC_WIDTH-1:0] out_fifo_data[0:OUT_FIFO_DEPTH-1];
    reg out_fifo_last[0:OUT_FIFO_DEPTH-1];
    reg [OUT_FIFO_PTR_W-1:0] out_fifo_wr_ptr;
    reg [OUT_FIFO_PTR_W-1:0] out_fifo_rd_ptr;
    reg [OUT_FIFO_CNT_W-1:0] out_fifo_count;

    reg [MAC_WIDTH-1:0] ser_buf;
    reg ser_buf_valid;
    reg ser_buf_last;
    reg [OUT_SLICE_W-1:0] ser_slice_idx;

    reg [PENDING_W-1:0] in_flight;
    reg last_beat_sent;

    localparam ISSUE_PIPE_DEPTH = 4;
    localparam ISSUE_PIPE_W = (ISSUE_PIPE_DEPTH <= 1) ? 1 : $clog2(ISSUE_PIPE_DEPTH + 1);
    reg [ISSUE_PIPE_W-1:0] issue_pipe_count;
    wire issue_pipe_push;
    wire issue_pipe_pop;

    wire fifo_empty = (out_fifo_count == 0);
    wire fifo_full = (out_fifo_count == OUT_FIFO_DEPTH);
    wire [PENDING_W:0] pending_count = in_flight + out_fifo_count + issue_pipe_count;
    wire fifo_has_space = (pending_count < OUT_FIFO_DEPTH);

    wire [OUTPUT_WIDTH-1:0] ser_slice = ser_buf[ser_slice_idx*OUTPUT_WIDTH+:OUTPUT_WIDTH];

    assign axis_data_out_tdata = ser_slice;
    assign axis_data_out_tvalid = ser_buf_valid;
    assign axis_data_out_tlast = ser_buf_valid && ser_buf_last && (ser_slice_idx == OUT_SLICES - 1);


    // Flow Control Logic
    wire input_within_safe_row = (in_row <= rd_row + 2);

    assign axis_data_in_tready = (state == S_PROCESS) && !in_fifo_full && !input_stream_done;


    // Output Beat Status
    wire is_last_output_row = (out_row == num_rows - 1);
    wire is_last_output_col = (out_col == num_cols - 1);
    wire is_last_chan_beat = (out_chan_beat == num_chan_beats - 1);
    wire is_last_output_beat = is_last_output_row && is_last_output_col && is_last_chan_beat;

    wire is_top_row = (out_row == 0);
    wire is_bottom_row = (out_row == num_rows - 1);
    wire is_left_col = (out_col == 0);
    wire is_right_col = (out_col == num_cols - 1);


    // Row indices in circular buffer
    wire [1:0] row_center_idx = rd_row_mod3;
    wire [1:0] row_above_idx = (rd_row == 0) ? 2'd0 :
                               (rd_row_mod3 == 2'd0) ? 2'd3 : rd_row_mod3 - 1;
    wire [1:0] row_below_idx = (rd_row >= num_rows - 1) ? 2'd0 :
                               (rd_row_mod3 == 2'd3) ? 2'd0 : rd_row_mod3 + 1;


    // FSM State Register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else state <= next_state;
    end


    // FSM Next State Logic
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
            end
            S_DONE:  next_state = S_IDLE;
            default: next_state = S_IDLE;
        endcase
    end


    // Configuration Capture
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            num_rows       <= 16'd0;
            num_cols       <= 16'd0;
            num_chan_beats <= 16'd0;
        end else if (state == S_IDLE && start) begin
            num_rows       <= cfg_height;
            num_cols       <= cfg_width;
            num_chan_beats <= cfg_channels >> 3;
        end
    end


    // Input Tracking
    always @(posedge clk) begin
        if (!rst_n) begin
            in_row            <= 16'd0;
            in_col            <= 16'd0;
            in_chan_beat      <= 16'd0;
            in_beat_in_row    <= 16'd0;
            in_row_mod3       <= 2'd0;
            input_stream_done <= 1'b0;
        end else if (state == S_IDLE) begin
            in_row            <= 16'd0;
            in_col            <= 16'd0;
            in_chan_beat      <= 16'd0;
            in_beat_in_row    <= 16'd0;
            in_row_mod3       <= 2'd0;
            input_stream_done <= 1'b0;
        end else if (in_fifo_pop_q) begin
            if (in_chan_beat == num_chan_beats - 1) begin
                in_chan_beat <= 16'd0;
                if (in_col == num_cols - 1) begin
                    in_col         <= 16'd0;
                    in_row         <= in_row + 1;
                    in_beat_in_row <= 16'd0;
                    in_row_mod3    <= (in_row_mod3 == 2'd3) ? 2'd0 : in_row_mod3 + 1;
                end else begin
                    in_col         <= in_col + 1;
                    in_beat_in_row <= in_beat_in_row + 1;
                end
            end else begin
                in_chan_beat   <= in_chan_beat + 1;
                in_beat_in_row <= in_beat_in_row + 1;
            end
        end
        if (input_handshake && axis_data_in_tlast) begin
            input_stream_done <= 1'b1;
        end
    end


    // Input FIFO write/read
    assign in_fifo_pop_req = (state == S_PROCESS) && input_within_safe_row && !in_fifo_empty;
    always @(posedge clk) begin
        if (!rst_n) begin
            in_fifo_wr_ptr    <= {IN_FIFO_PTR_W{1'b0}};
            in_fifo_rd_ptr    <= {IN_FIFO_PTR_W{1'b0}};
            in_fifo_count     <= {IN_FIFO_CNT_W{1'b0}};
            in_fifo_rd_data_q <= {INPUT_WIDTH{1'b0}};
            in_fifo_pop_q     <= 1'b0;
        end else begin
            if (state == S_IDLE) begin
                in_fifo_wr_ptr    <= {IN_FIFO_PTR_W{1'b0}};
                in_fifo_rd_ptr    <= {IN_FIFO_PTR_W{1'b0}};
                in_fifo_count     <= {IN_FIFO_CNT_W{1'b0}};
                in_fifo_rd_data_q <= {INPUT_WIDTH{1'b0}};
                in_fifo_pop_q     <= 1'b0;
            end else begin
                in_fifo_pop_q <= in_fifo_pop_req;
                if (in_fifo_pop_req) begin
                    in_fifo_rd_data_q <= in_fifo_mem[in_fifo_rd_ptr];
                end

                if (in_fifo_push) begin
                    in_fifo_mem[in_fifo_wr_ptr] <= axis_data_in_tdata;
                    if (in_fifo_wr_ptr == IN_FIFO_DEPTH - 1)
                        in_fifo_wr_ptr <= {IN_FIFO_PTR_W{1'b0}};
                    else in_fifo_wr_ptr <= in_fifo_wr_ptr + 1'b1;
                end

                if (in_fifo_pop_req) begin
                    if (in_fifo_rd_ptr == IN_FIFO_DEPTH - 1)
                        in_fifo_rd_ptr <= {IN_FIFO_PTR_W{1'b0}};
                    else in_fifo_rd_ptr <= in_fifo_rd_ptr + 1'b1;
                end

                case ({
                    in_fifo_push, in_fifo_pop_req
                })
                    2'b10:   in_fifo_count <= in_fifo_count + 1'b1;
                    2'b01:   in_fifo_count <= in_fifo_count - 1'b1;
                    default: in_fifo_count <= in_fifo_count;
                endcase
            end
        end
    end


    // Read Pipeline Control

    wire row_current_ready = (in_row > rd_row) ||
                             (in_row == rd_row && in_beat_in_row > rd_beat_in_row);

    wire row_below_ready = (rd_row >= num_rows - 1) ||
                           (in_row > rd_row + 1) ||
                           (in_row == rd_row + 1 && in_beat_in_row > rd_beat_in_row);

    wire [15:0] next_row = rd_row + 1;
    wire [1:0] next_row_mod3 = (rd_row_mod3 == 2'd3) ? 2'd0 : rd_row_mod3 + 1;
    wire [1:0] row_above_idx_next = rd_row_mod3;
    wire [1:0] row_center_idx_next = next_row_mod3;
    wire [1:0] row_below_idx_next = (next_row >= num_rows - 1) ? 2'd0 :
                                    (next_row_mod3 == 2'd3) ? 2'd0 : next_row_mod3 + 1;

    wire row_current_ready_next = (in_row > rd_row + 1) ||
                                  (in_row == rd_row + 1 && in_beat_in_row > pad_chan_beat);
    wire row_below_ready_next = (next_row >= num_rows - 1) ||
                                (in_row > rd_row + 2) ||
                                (in_row == rd_row + 2 && in_beat_in_row > pad_chan_beat);
    wire prefetch_possible = (rd_row < num_rows - 1) &&
                             row_current_ready_next &&
                             row_below_ready_next;

    wire can_issue_real = (state == S_PROCESS) && !pad_active && !issued_last &&
                          (rd_row < num_rows) &&
                          row_current_ready && row_below_ready &&
                          fifo_has_space;

    wire rd_issue_c = can_issue_real && (rd_col < num_cols);

    wire pad_issue_c = (state == S_PROCESS) && pad_active && !issued_last && fifo_has_space;
    wire prefetch_fire_c = pad_issue_c && prefetch_active && prefetch_possible;

    reg rd_issue_q;
    reg pad_issue_q;
    reg prefetch_fire_q;

    wire rd_issue_exec = rd_issue_q && (rd_col < num_cols) && !pad_active;
    wire pad_issue_exec = pad_issue_q && pad_active;
    wire prefetch_fire_exec = prefetch_fire_q && pad_issue_exec;

    wire [15:0] prefetch_count_next = prefetch_count + (prefetch_fire_exec ? 16'd1 : 16'd0);
    wire prefetch_full = (prefetch_count_next == num_chan_beats);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_issue_q      <= 1'b0;
            pad_issue_q     <= 1'b0;
            prefetch_fire_q <= 1'b0;
        end else if (state != S_PROCESS) begin
            rd_issue_q      <= 1'b0;
            pad_issue_q     <= 1'b0;
            prefetch_fire_q <= 1'b0;
        end else begin
            rd_issue_q      <= rd_issue_c;
            pad_issue_q     <= pad_issue_c;
            prefetch_fire_q <= prefetch_fire_c;
        end
    end


    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_row          <= 16'd0;
            rd_row_mod3     <= 2'd0;
            rd_col          <= 16'd0;
            rd_chan_beat    <= 16'd0;
            rd_beat_in_row  <= 16'd0;
            pad_active      <= 1'b0;
            pad_chan_beat   <= 16'd0;
            prefetch_active <= 1'b0;
            prefetch_count  <= 16'd0;
        end else if (state == S_IDLE) begin
            rd_row          <= 16'd0;
            rd_row_mod3     <= 2'd0;
            rd_col          <= 16'd0;
            rd_chan_beat    <= 16'd0;
            rd_beat_in_row  <= 16'd0;
            pad_active      <= 1'b0;
            pad_chan_beat   <= 16'd0;
            prefetch_active <= 1'b0;
            prefetch_count  <= 16'd0;
        end else if (state == S_PROCESS) begin
            if (rd_issue_exec) begin
                if (rd_chan_beat == num_chan_beats - 1) begin
                    rd_chan_beat <= 16'd0;
                    if (rd_col == num_cols - 1) begin
                        rd_col          <= num_cols;
                        pad_active      <= 1'b1;
                        pad_chan_beat   <= 16'd0;
                        prefetch_active <= (rd_row < num_rows - 1);
                        prefetch_count  <= 16'd0;
                    end else begin
                        rd_col <= rd_col + 1;
                    end
                end else begin
                    rd_chan_beat <= rd_chan_beat + 1;
                end
                rd_beat_in_row <= rd_beat_in_row + 1;
            end else if (pad_issue_exec) begin
                if (prefetch_fire_exec) begin
                    prefetch_count <= prefetch_count_next;
                end
                if (pad_chan_beat == num_chan_beats - 1) begin
                    pad_active      <= 1'b0;
                    pad_chan_beat   <= 16'd0;
                    rd_col          <= 16'd0;
                    rd_chan_beat    <= 16'd0;
                    rd_beat_in_row  <= 16'd0;
                    rd_row          <= rd_row + 1;
                    rd_row_mod3     <= (rd_row_mod3 == 2'd3) ? 2'd0 : rd_row_mod3 + 1;
                    prefetch_active <= 1'b0;
                end else begin
                    pad_chan_beat <= pad_chan_beat + 1;
                end
            end
        end
    end


    // Output Position Tracking
    wire window_push;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_row       <= 16'd0;
            out_col       <= 16'd0;
            out_chan_beat <= 16'd0;
            issued_last   <= 1'b0;
        end else begin
            if (state == S_IDLE) begin
                out_row       <= 16'd0;
                out_col       <= 16'd0;
                out_chan_beat <= 16'd0;
                issued_last   <= 1'b0;
            end else if (window_push) begin
                if (is_last_output_beat) issued_last <= 1'b1;
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) shift_bank_sel <= 1'b0;
        else if (state == S_IDLE) shift_bank_sel <= 1'b0;
        else if (state == S_PROCESS && pad_issue_exec && (pad_chan_beat == num_chan_beats - 1))
            shift_bank_sel <= ~shift_bank_sel;
    end


    // Read Address Issue and Capture
    reg                   issue_d;
    reg                   rd_issue_d;
    reg                   pad_issue_d;
    reg                   issue_is_pad_d;
    reg [           15:0] issue_col_d;
    reg [           15:0] issue_col_q;
    reg [            1:0] row_above_idx_d;
    reg [            1:0] row_center_idx_d;
    reg [            1:0] row_below_idx_d;
    reg                   prefetch_fire_d;
    reg                   prefetch_fire_dd;
    reg [            1:0] row_above_idx_pref_d;
    reg [            1:0] row_center_idx_pref_d;
    reg [            1:0] row_below_idx_pref_d;
    reg                   issue_bank_sel_q;
    reg                   issue_dd;
    reg [           15:0] issue_col_dd;
    reg                   issue_bank_sel_dd;
    reg                   issue_ddd;
    reg [           15:0] issue_col_ddd;
    reg                   issue_bank_sel_ddd;
    reg                   prefetch_fire_ddd;
    reg                   prefetch_bank_sel_ddd;
    reg [INPUT_WIDTH-1:0] row_above_in_d1;
    reg [INPUT_WIDTH-1:0] row_center_in_d1;
    reg [INPUT_WIDTH-1:0] row_below_in_d1;
    reg [INPUT_WIDTH-1:0] row_above_in_d2;
    reg [INPUT_WIDTH-1:0] row_center_in_d2;
    reg [INPUT_WIDTH-1:0] row_below_in_d2;
    reg [INPUT_WIDTH-1:0] row_above_pref_d1;
    reg [INPUT_WIDTH-1:0] row_center_pref_d1;
    reg [INPUT_WIDTH-1:0] row_below_pref_d1;
    reg [INPUT_WIDTH-1:0] row_above_pref_d2;
    reg [INPUT_WIDTH-1:0] row_center_pref_d2;
    reg [INPUT_WIDTH-1:0] row_below_pref_d2;
    reg                   prefetch_clear_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_d               <= 1'b0;
            rd_issue_d            <= 1'b0;
            pad_issue_d           <= 1'b0;
            issue_is_pad_d        <= 1'b0;
            issue_col_d           <= 16'd0;
            issue_col_q           <= 16'd0;
            row_above_idx_d       <= 2'd0;
            row_center_idx_d      <= 2'd0;
            row_below_idx_d       <= 2'd0;
            prefetch_fire_d       <= 1'b0;
            prefetch_fire_dd      <= 1'b0;
            issue_bank_sel_d      <= 1'b0;
            issue_bank_sel_q      <= 1'b0;
            prefetch_bank_sel_d   <= 1'b0;
            prefetch_bank_sel_dd  <= 1'b0;
            row_above_idx_pref_d  <= 2'd0;
            row_center_idx_pref_d <= 2'd0;
            row_below_idx_pref_d  <= 2'd0;
            issue_dd              <= 1'b0;
            issue_col_dd          <= 16'd0;
            issue_bank_sel_dd     <= 1'b0;
            issue_ddd             <= 1'b0;
            issue_col_ddd         <= 16'd0;
            issue_bank_sel_ddd    <= 1'b0;
            prefetch_fire_ddd     <= 1'b0;
            prefetch_bank_sel_ddd <= 1'b0;
        end else begin
            rd_issue_d         <= rd_issue_exec;
            pad_issue_d        <= pad_issue_exec;
            issue_d            <= rd_issue_d || pad_issue_d;
            issue_is_pad_d     <= pad_issue_d;
            issue_col_d        <= issue_col_q;
            issue_bank_sel_d   <= issue_bank_sel_q;
            issue_dd           <= issue_d;
            issue_col_dd       <= issue_col_d;
            issue_bank_sel_dd  <= issue_bank_sel_d;
            issue_ddd          <= issue_dd;
            issue_col_ddd      <= issue_col_dd;
            issue_bank_sel_ddd <= issue_bank_sel_dd;
            if (rd_issue_exec || pad_issue_exec) begin
                issue_col_q <= pad_issue_exec ? num_cols : rd_col;
                issue_bank_sel_q <= shift_bank_sel;
            end
            if (rd_issue_exec) begin
                row_above_idx_d  <= row_above_idx;
                row_center_idx_d <= row_center_idx;
                row_below_idx_d  <= row_below_idx;
            end
            prefetch_fire_d   <= prefetch_fire_exec;
            prefetch_fire_dd  <= prefetch_fire_d;
            prefetch_fire_ddd <= prefetch_fire_dd;
            if (prefetch_fire_exec) prefetch_bank_sel_d <= ~shift_bank_sel;
            prefetch_bank_sel_dd  <= prefetch_bank_sel_d;
            prefetch_bank_sel_ddd <= prefetch_bank_sel_dd;
            if (prefetch_fire_exec) begin
                row_above_idx_pref_d  <= row_above_idx_next;
                row_center_idx_pref_d <= row_center_idx_next;
                row_below_idx_pref_d  <= row_below_idx_next;
            end
        end
    end

    always @(posedge clk) begin
        if (rd_issue_exec) begin
            lb_rd_addr <= rd_beat_in_row;
        end else if (prefetch_fire_exec) begin
            lb_rd_addr <= pad_chan_beat;
        end
    end


    // Window Data Shift Registers
    reg [INPUT_WIDTH-1:0] row_above_shift_a [0:SHIFT_DEPTH-1];
    reg [INPUT_WIDTH-1:0] row_center_shift_a[0:SHIFT_DEPTH-1];
    reg [INPUT_WIDTH-1:0] row_below_shift_a [0:SHIFT_DEPTH-1];
    reg [INPUT_WIDTH-1:0] row_above_shift_b [0:SHIFT_DEPTH-1];
    reg [INPUT_WIDTH-1:0] row_center_shift_b[0:SHIFT_DEPTH-1];
    reg [INPUT_WIDTH-1:0] row_below_shift_b [0:SHIFT_DEPTH-1];

    function [INPUT_WIDTH-1:0] select_row_data;
        input [1:0] row_idx;
        input [INPUT_WIDTH-1:0] data_0, data_1, data_2, data_3;
        begin
            case (row_idx)
                2'd0: select_row_data = data_0;
                2'd1: select_row_data = data_1;
                2'd2: select_row_data = data_2;
                default: select_row_data = data_3;
            endcase
        end
    endfunction

    wire [INPUT_WIDTH-1:0] row_above_data = select_row_data(
        row_above_idx_d, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2, lb_rd_data_3
    );
    wire [INPUT_WIDTH-1:0] row_center_data = select_row_data(
        row_center_idx_d, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2, lb_rd_data_3
    );
    wire [INPUT_WIDTH-1:0] row_below_data = select_row_data(
        row_below_idx_d, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2, lb_rd_data_3
    );
    wire [INPUT_WIDTH-1:0] row_above_pref_data = select_row_data(
        row_above_idx_pref_d, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2, lb_rd_data_3
    );
    wire [INPUT_WIDTH-1:0] row_center_pref_data = select_row_data(
        row_center_idx_pref_d, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2, lb_rd_data_3
    );
    wire [INPUT_WIDTH-1:0] row_below_pref_data = select_row_data(
        row_below_idx_pref_d, lb_rd_data_0, lb_rd_data_1, lb_rd_data_2, lb_rd_data_3
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_above_pref_d1  <= {INPUT_WIDTH{1'b0}};
            row_center_pref_d1 <= {INPUT_WIDTH{1'b0}};
            row_below_pref_d1  <= {INPUT_WIDTH{1'b0}};
            row_above_pref_d2  <= {INPUT_WIDTH{1'b0}};
            row_center_pref_d2 <= {INPUT_WIDTH{1'b0}};
            row_below_pref_d2  <= {INPUT_WIDTH{1'b0}};
        end else if (state == S_IDLE) begin
            row_above_pref_d1  <= {INPUT_WIDTH{1'b0}};
            row_center_pref_d1 <= {INPUT_WIDTH{1'b0}};
            row_below_pref_d1  <= {INPUT_WIDTH{1'b0}};
            row_above_pref_d2  <= {INPUT_WIDTH{1'b0}};
            row_center_pref_d2 <= {INPUT_WIDTH{1'b0}};
            row_below_pref_d2  <= {INPUT_WIDTH{1'b0}};
        end else begin
            row_above_pref_d1  <= row_above_pref_data;
            row_center_pref_d1 <= row_center_pref_data;
            row_below_pref_d1  <= row_below_pref_data;
            row_above_pref_d2  <= row_above_pref_d1;
            row_center_pref_d2 <= row_center_pref_d1;
            row_below_pref_d2  <= row_below_pref_d1;
        end
    end

    wire [INPUT_WIDTH-1:0] row_above_in = issue_is_pad_d ? {INPUT_WIDTH{1'b0}} : row_above_data;
    wire [INPUT_WIDTH-1:0] row_center_in = issue_is_pad_d ? {INPUT_WIDTH{1'b0}} : row_center_data;
    wire [INPUT_WIDTH-1:0] row_below_in = issue_is_pad_d ? {INPUT_WIDTH{1'b0}} : row_below_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_above_in_d1  <= {INPUT_WIDTH{1'b0}};
            row_center_in_d1 <= {INPUT_WIDTH{1'b0}};
            row_below_in_d1  <= {INPUT_WIDTH{1'b0}};
            row_above_in_d2  <= {INPUT_WIDTH{1'b0}};
            row_center_in_d2 <= {INPUT_WIDTH{1'b0}};
            row_below_in_d2  <= {INPUT_WIDTH{1'b0}};
        end else if (state == S_IDLE) begin
            row_above_in_d1  <= {INPUT_WIDTH{1'b0}};
            row_center_in_d1 <= {INPUT_WIDTH{1'b0}};
            row_below_in_d1  <= {INPUT_WIDTH{1'b0}};
            row_above_in_d2  <= {INPUT_WIDTH{1'b0}};
            row_center_in_d2 <= {INPUT_WIDTH{1'b0}};
            row_below_in_d2  <= {INPUT_WIDTH{1'b0}};
        end else begin
            row_above_in_d1  <= row_above_in;
            row_center_in_d1 <= row_center_in;
            row_below_in_d1  <= row_below_in;
            row_above_in_d2  <= row_above_in_d1;
            row_center_in_d2 <= row_center_in_d1;
            row_below_in_d2  <= row_below_in_d1;
        end
    end

    wire [15:0] center_idx = num_chan_beats;
    wire [15:0] left_idx = (num_chan_beats << 1);
    wire [15:0] center_idx_sel = center_idx - 16'd1;
    wire [15:0] left_idx_sel = left_idx - 16'd1;
    integer wi;
    wire prefetch_clear = rd_issue_exec &&
                          (rd_chan_beat == num_chan_beats - 1) &&
                          (rd_col == num_cols - 1);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prefetch_clear_q <= 1'b0;
        end else if (state == S_IDLE) begin
            prefetch_clear_q <= 1'b0;
        end else begin
            prefetch_clear_q <= prefetch_clear;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (wi = 0; wi < SHIFT_DEPTH; wi = wi + 1) begin
                row_above_shift_a[wi]  <= {INPUT_WIDTH{1'b0}};
                row_center_shift_a[wi] <= {INPUT_WIDTH{1'b0}};
                row_below_shift_a[wi]  <= {INPUT_WIDTH{1'b0}};
                row_above_shift_b[wi]  <= {INPUT_WIDTH{1'b0}};
                row_center_shift_b[wi] <= {INPUT_WIDTH{1'b0}};
                row_below_shift_b[wi]  <= {INPUT_WIDTH{1'b0}};
            end
        end else begin
            if (prefetch_clear_q) begin
                for (wi = 0; wi < SHIFT_DEPTH; wi = wi + 1) begin
                    if (shift_bank_sel) begin
                        row_above_shift_a[wi]  <= {INPUT_WIDTH{1'b0}};
                        row_center_shift_a[wi] <= {INPUT_WIDTH{1'b0}};
                        row_below_shift_a[wi]  <= {INPUT_WIDTH{1'b0}};
                    end else begin
                        row_above_shift_b[wi]  <= {INPUT_WIDTH{1'b0}};
                        row_center_shift_b[wi] <= {INPUT_WIDTH{1'b0}};
                        row_below_shift_b[wi]  <= {INPUT_WIDTH{1'b0}};
                    end
                end
            end

            if (state == S_IDLE) begin
                for (wi = 0; wi < SHIFT_DEPTH; wi = wi + 1) begin
                    row_above_shift_a[wi]  <= {INPUT_WIDTH{1'b0}};
                    row_center_shift_a[wi] <= {INPUT_WIDTH{1'b0}};
                    row_below_shift_a[wi]  <= {INPUT_WIDTH{1'b0}};
                    row_above_shift_b[wi]  <= {INPUT_WIDTH{1'b0}};
                    row_center_shift_b[wi] <= {INPUT_WIDTH{1'b0}};
                    row_below_shift_b[wi]  <= {INPUT_WIDTH{1'b0}};
                end
            end else begin
                if (issue_ddd) begin
                    for (wi = SHIFT_DEPTH - 1; wi > 0; wi = wi - 1) begin
                        if (issue_bank_sel_ddd) begin
                            row_above_shift_b[wi]  <= row_above_shift_b[wi-1];
                            row_center_shift_b[wi] <= row_center_shift_b[wi-1];
                            row_below_shift_b[wi]  <= row_below_shift_b[wi-1];
                        end else begin
                            row_above_shift_a[wi]  <= row_above_shift_a[wi-1];
                            row_center_shift_a[wi] <= row_center_shift_a[wi-1];
                            row_below_shift_a[wi]  <= row_below_shift_a[wi-1];
                        end
                    end
                    if (issue_bank_sel_ddd) begin
                        row_above_shift_b[0]  <= row_above_in_d2;
                        row_center_shift_b[0] <= row_center_in_d2;
                        row_below_shift_b[0]  <= row_below_in_d2;
                    end else begin
                        row_above_shift_a[0]  <= row_above_in_d2;
                        row_center_shift_a[0] <= row_center_in_d2;
                        row_below_shift_a[0]  <= row_below_in_d2;
                    end
                end
                if (prefetch_fire_ddd) begin
                    for (wi = SHIFT_DEPTH - 1; wi > 0; wi = wi - 1) begin
                        if (prefetch_bank_sel_ddd) begin
                            row_above_shift_b[wi]  <= row_above_shift_b[wi-1];
                            row_center_shift_b[wi] <= row_center_shift_b[wi-1];
                            row_below_shift_b[wi]  <= row_below_shift_b[wi-1];
                        end else begin
                            row_above_shift_a[wi]  <= row_above_shift_a[wi-1];
                            row_center_shift_a[wi] <= row_center_shift_a[wi-1];
                            row_below_shift_a[wi]  <= row_below_shift_a[wi-1];
                        end
                    end
                    if (prefetch_bank_sel_ddd) begin
                        row_above_shift_b[0]  <= row_above_pref_d2;
                        row_center_shift_b[0] <= row_center_pref_d2;
                        row_below_shift_b[0]  <= row_below_pref_d2;
                    end else begin
                        row_above_shift_a[0]  <= row_above_pref_d2;
                        row_center_shift_a[0] <= row_center_pref_d2;
                        row_below_shift_a[0]  <= row_below_pref_d2;
                    end
                end

            end
        end
    end


    // Window Assemble and MAC Input
    wire shift_bank_sel_win = issue_bank_sel_ddd;


    wire [INPUT_WIDTH-1:0] row_above_left = shift_bank_sel_win ?
                                            row_above_shift_b[left_idx_sel] :
                                            row_above_shift_a[left_idx_sel];
    wire [INPUT_WIDTH-1:0] row_above_ctr = shift_bank_sel_win ?
                                           row_above_shift_b[center_idx_sel] :
                                           row_above_shift_a[center_idx_sel];
    wire [INPUT_WIDTH-1:0] row_center_left = shift_bank_sel_win ?
                                             row_center_shift_b[left_idx_sel] :
                                             row_center_shift_a[left_idx_sel];
    wire [INPUT_WIDTH-1:0] row_center_ctr = shift_bank_sel_win ?
                                            row_center_shift_b[center_idx_sel] :
                                            row_center_shift_a[center_idx_sel];
    wire [INPUT_WIDTH-1:0] row_below_left = shift_bank_sel_win ?
                                            row_below_shift_b[left_idx_sel] :
                                            row_below_shift_a[left_idx_sel];
    wire [INPUT_WIDTH-1:0] row_below_ctr = shift_bank_sel_win ?
                                           row_below_shift_b[center_idx_sel] :
                                           row_below_shift_a[center_idx_sel];

    wire [INPUT_WIDTH-1:0] row0_left = (is_left_col || is_top_row) ? {INPUT_WIDTH{1'b0}} :
                                       row_above_left;
    wire [INPUT_WIDTH-1:0] row0_ctr = is_top_row ? {INPUT_WIDTH{1'b0}} : row_above_ctr;
    wire [INPUT_WIDTH-1:0] row0_right = (is_right_col || is_top_row) ? {INPUT_WIDTH{1'b0}} :
                                        row_above_in_d2;

    wire [INPUT_WIDTH-1:0] row1_left = is_left_col ? {INPUT_WIDTH{1'b0}} : row_center_left;
    wire [INPUT_WIDTH-1:0] row1_ctr = row_center_ctr;
    wire [INPUT_WIDTH-1:0] row1_right = is_right_col ? {INPUT_WIDTH{1'b0}} : row_center_in_d2;

    wire [INPUT_WIDTH-1:0] row2_left = (is_left_col || is_bottom_row) ? {INPUT_WIDTH{1'b0}} :
                                       row_below_left;
    wire [INPUT_WIDTH-1:0] row2_ctr = is_bottom_row ? {INPUT_WIDTH{1'b0}} : row_below_ctr;
    wire [INPUT_WIDTH-1:0] row2_right = (is_right_col || is_bottom_row) ? {INPUT_WIDTH{1'b0}} :
                                        row_below_in_d2;


    assign window_push = issue_ddd && (issue_col_ddd != 16'd0) && !issued_last;
    assign issue_pipe_push = !issued_last &&
                             ((rd_issue_exec && (rd_col != 16'd0)) || pad_issue_exec);
    assign issue_pipe_pop = window_push;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_data_valid <= 1'b0;
            mac_data_last  <= 1'b0;
            mac_win_pack   <= {KERNEL_PACK_WIDTH{1'b0}};
            mac_ker_pack   <= {KERNEL_PACK_WIDTH{1'b0}};
        end else begin
            mac_data_valid <= 1'b0;
            if (window_push) begin
                mac_data_valid <= 1'b1;
                mac_data_last <= is_last_output_beat;
                mac_win_pack[0*INPUT_WIDTH+:INPUT_WIDTH] <= row0_left;
                mac_win_pack[1*INPUT_WIDTH+:INPUT_WIDTH] <= row0_ctr;
                mac_win_pack[2*INPUT_WIDTH+:INPUT_WIDTH] <= row0_right;
                mac_win_pack[3*INPUT_WIDTH+:INPUT_WIDTH] <= row1_left;
                mac_win_pack[4*INPUT_WIDTH+:INPUT_WIDTH] <= row1_ctr;
                mac_win_pack[5*INPUT_WIDTH+:INPUT_WIDTH] <= row1_right;
                mac_win_pack[6*INPUT_WIDTH+:INPUT_WIDTH] <= row2_left;
                mac_win_pack[7*INPUT_WIDTH+:INPUT_WIDTH] <= row2_ctr;
                mac_win_pack[8*INPUT_WIDTH+:INPUT_WIDTH] <= row2_right;
                mac_ker_pack <= kernel_pack;
            end
        end
    end


    // Output FIFO (MAC results)
    wire fifo_push = mac_result_valid;
    wire ser_accept = ser_buf_valid && axis_data_out_tready;
    wire ser_done = ser_accept && (ser_slice_idx == OUT_SLICES - 1);
    wire ser_need_load = (!ser_buf_valid) || ser_done;
    wire fifo_pop = ser_need_load && !fifo_empty;

    wire fifo_push_allow = fifo_push && (!fifo_full || fifo_pop);

    integer fi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_fifo_wr_ptr <= {OUT_FIFO_PTR_W{1'b0}};
            out_fifo_rd_ptr <= {OUT_FIFO_PTR_W{1'b0}};
            out_fifo_count  <= {OUT_FIFO_CNT_W{1'b0}};
            for (fi = 0; fi < OUT_FIFO_DEPTH; fi = fi + 1) begin
                out_fifo_data[fi] <= {MAC_WIDTH{1'b0}};
                out_fifo_last[fi] <= 1'b0;
            end
        end else if (state == S_IDLE) begin
            out_fifo_wr_ptr <= {OUT_FIFO_PTR_W{1'b0}};
            out_fifo_rd_ptr <= {OUT_FIFO_PTR_W{1'b0}};
            out_fifo_count  <= {OUT_FIFO_CNT_W{1'b0}};
        end else begin
            if (fifo_push_allow) begin
                out_fifo_data[out_fifo_wr_ptr] <= mac_result_pack;
                out_fifo_last[out_fifo_wr_ptr] <= mac_result_last;
                out_fifo_wr_ptr <= out_fifo_wr_ptr + 1'b1;
            end

            if (fifo_pop) begin
                out_fifo_rd_ptr <= out_fifo_rd_ptr + 1'b1;
            end

            case ({
                fifo_push_allow, fifo_pop
            })
                2'b10:   out_fifo_count <= out_fifo_count + 1'b1;
                2'b01:   out_fifo_count <= out_fifo_count - 1'b1;
                default: out_fifo_count <= out_fifo_count;
            endcase
        end
    end

    // Output serializer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ser_buf        <= {MAC_WIDTH{1'b0}};
            ser_buf_valid  <= 1'b0;
            ser_buf_last   <= 1'b0;
            ser_slice_idx  <= {OUT_SLICE_W{1'b0}};
            last_beat_sent <= 1'b0;
        end else if (state == S_IDLE) begin
            ser_buf_valid  <= 1'b0;
            ser_buf_last   <= 1'b0;
            ser_slice_idx  <= {OUT_SLICE_W{1'b0}};
            last_beat_sent <= 1'b0;
        end else begin
            if (ser_need_load) begin
                if (!fifo_empty) begin
                    ser_buf       <= out_fifo_data[out_fifo_rd_ptr];
                    ser_buf_last  <= out_fifo_last[out_fifo_rd_ptr];
                    ser_buf_valid <= 1'b1;
                    ser_slice_idx <= {OUT_SLICE_W{1'b0}};
                end else begin
                    ser_buf_valid <= 1'b0;
                end
            end else if (ser_accept) begin
                ser_slice_idx <= ser_slice_idx + 1'b1;
            end

            if (ser_accept && axis_data_out_tlast) begin
                last_beat_sent <= 1'b1;
            end
        end
    end


    // In-flight window tracking (for FIFO space)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_flight <= {PENDING_W{1'b0}};
            issue_pipe_count <= {ISSUE_PIPE_W{1'b0}};
        end else if (state == S_IDLE) begin
            in_flight <= {PENDING_W{1'b0}};
            issue_pipe_count <= {ISSUE_PIPE_W{1'b0}};
        end else begin
            case ({
                window_push, mac_result_valid
            })
                2'b10:   in_flight <= in_flight + 1'b1;
                2'b01:   in_flight <= in_flight - 1'b1;
                default: in_flight <= in_flight;
            endcase

            case ({
                issue_pipe_push, issue_pipe_pop
            })
                2'b10:   issue_pipe_count <= issue_pipe_count + 1'b1;
                2'b01:   issue_pipe_count <= issue_pipe_count - 1'b1;
                default: issue_pipe_count <= issue_pipe_count;
            endcase
        end
    end


    // Done Signal
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) done <= 1'b0;
        else if (state == S_DONE && last_beat_sent) done <= 1'b1;
        else done <= 1'b0;
    end

endmodule
