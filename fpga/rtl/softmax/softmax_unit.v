`timescale 1ns / 1ps

module softmax_unit #(
    parameter integer AXIS_DATA_WIDTH = 64,
    parameter integer DATA_WIDTH      = 8,
    parameter integer EXP_WIDTH       = 20,
    parameter integer SUM_WIDTH       = 32,
    parameter integer RECIP_WIDTH     = 16,
    parameter integer FIFO_DEPTH      = 256,
    parameter         EXP_INIT_FILE   = "lut/exp_table_q4_16.hex",
    parameter         RECIP_INIT_FILE = "lut/recip_lut.hex"
) (
    input wire clk,
    input wire rst_n,

    // Control
    input  wire        start,
    input  wire [31:0] num_tokens,
    output reg         done,

    // AXI4-Stream input (INT8 logits, 8 lanes)
    input  wire [AXIS_DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                       s_axis_tvalid,
    input  wire                       s_axis_tlast,
    output wire                       s_axis_tready,

    // AXI4-Stream output (UINT8 probabilities, 8 lanes)
    output wire [AXIS_DATA_WIDTH-1:0] m_axis_tdata,
    output wire                       m_axis_tvalid,
    output wire                       m_axis_tlast,
    input  wire                       m_axis_tready
);
    localparam integer LANES = AXIS_DATA_WIDTH / DATA_WIDTH;  // = 8
    localparam integer FIFO_WIDTH = LANES * EXP_WIDTH;  // = 160

    // 5-state FSM with S_FIND_MAX for numerical stability
    localparam [2:0] S_IDLE       = 3'd0,
                     S_FIND_MAX   = 3'd1,
                     S_ACCUMULATE = 3'd2,
                     S_CALC_RECIP = 3'd3,
                     S_NORMALIZE  = 3'd4;

    reg [2:0] state, next_state;

    // Counters and accumulators
    // NOTE: Counter width reduced from 32 to 12 bits (max 4096 tokens) for timing
    localparam COUNTER_WIDTH = 12;  // Supports up to 4096 tokens

    reg        [      SUM_WIDTH-1:0] global_sum;
    reg        [  COUNTER_WIDTH-1:0] tokens_accepted;  // Count up during S_FIND_MAX
    reg        [  COUNTER_WIDTH-1:0] tokens_processed;  // Count up during S_ACCUMULATE
    reg        [  COUNTER_WIDTH-1:0] tokens_remaining;  // Count DOWN during S_NORMALIZE

    // Max value for numerical stability (signed)
    reg signed [     DATA_WIDTH-1:0] global_max;

    // Pipeline the per-beat max to break the input->global_max critical path.
    reg signed [     DATA_WIDTH-1:0] beat_max_r;
    reg                              beat_max_valid;

    // MSR results latched for pass 2
    reg        [    RECIP_WIDTH-1:0] msr_mult_r;
    reg        [                4:0] msr_shift_r;

    // Exp pipeline valid (aligns FIFO read -> exp_rom -> accumulate/write)
    reg                              exp_out_valid_d1;
    reg                              exp_out_valid_d2;

    // =========================================================================
    // INPUT FIFO - buffer raw inputs during S_FIND_MAX for reuse in S_ACCUMULATE
    // =========================================================================
    wire       [AXIS_DATA_WIDTH-1:0] input_fifo_dout;
    wire input_fifo_full, input_fifo_empty;
    wire input_fifo_wr_en;
    wire input_fifo_rd_en;
    wire input_fifo_clr = (state == S_IDLE) && start;

    softmax_fifo #(
        .WIDTH(AXIS_DATA_WIDTH),
        .DEPTH(FIFO_DEPTH)
    ) u_input_fifo (
        .clk  (clk),
        .rst_n(rst_n),
        .clr  (input_fifo_clr),
        .wr_en(input_fifo_wr_en),
        .din  (s_axis_tdata),
        .rd_en(input_fifo_rd_en),
        .dout (input_fifo_dout),
        .full (input_fifo_full),
        .empty(input_fifo_empty)
    );

    // Accept AXI input when in S_FIND_MAX state, valid data, and FIFO not full
    // (Declared early because needed by pipelined max tree)
    wire accept_axi_input = (state == S_FIND_MAX) && s_axis_tvalid && s_axis_tready;

    // =========================================================================
    // MAX-FINDING TREE (8 lanes -> 1 max value) - 2-STAGE PIPELINED
    // =========================================================================
    // Stage 1: 8 inputs -> 4 intermediate max values (combinational)
    // Stage 2: 4 -> 2 -> 1 max value (combinational after register)
    //
    // This breaks the input->beat_max_r critical path by adding an intermediate
    // register stage, trading 1 cycle latency for improved Fmax.
    // =========================================================================
    wire signed [DATA_WIDTH-1:0] lane_in[0:LANES-1];
    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl = gl + 1) begin : unpack_lanes
            assign lane_in[gl] = s_axis_tdata[gl*DATA_WIDTH+:DATA_WIDTH];
        end
    endgenerate

    // Stage 1: 8 -> 4 reduction (combinational)
    wire signed [DATA_WIDTH-1:0] max_01 = (lane_in[0] > lane_in[1]) ? lane_in[0] : lane_in[1];
    wire signed [DATA_WIDTH-1:0] max_23 = (lane_in[2] > lane_in[3]) ? lane_in[2] : lane_in[3];
    wire signed [DATA_WIDTH-1:0] max_45 = (lane_in[4] > lane_in[5]) ? lane_in[4] : lane_in[5];
    wire signed [DATA_WIDTH-1:0] max_67 = (lane_in[6] > lane_in[7]) ? lane_in[6] : lane_in[7];

    // Pipeline registers for Stage 1 results
    reg signed [DATA_WIDTH-1:0] max_01_r, max_23_r, max_45_r, max_67_r;
    reg max_stage1_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            max_01_r <= {DATA_WIDTH{1'b0}};
            max_23_r <= {DATA_WIDTH{1'b0}};
            max_45_r <= {DATA_WIDTH{1'b0}};
            max_67_r <= {DATA_WIDTH{1'b0}};
            max_stage1_valid <= 1'b0;
        end else if (state == S_IDLE) begin
            max_stage1_valid <= 1'b0;
        end else if (accept_axi_input) begin
            // Capture Stage 1 results when input is accepted
            max_01_r <= max_01;
            max_23_r <= max_23;
            max_45_r <= max_45;
            max_67_r <= max_67;
            max_stage1_valid <= 1'b1;
        end else begin
            max_stage1_valid <= 1'b0;
        end
    end

    // Stage 2: 4 -> 1 reduction (combinational from registered values)
    wire signed [DATA_WIDTH-1:0] max_0123 = (max_01_r > max_23_r) ? max_01_r : max_23_r;
    wire signed [DATA_WIDTH-1:0] max_4567 = (max_45_r > max_67_r) ? max_45_r : max_67_r;
    wire signed [DATA_WIDTH-1:0] beat_max = (max_0123 > max_4567) ? max_0123 : max_4567;

    // =========================================================================
    // EXP ROM with max-subtracted addressing
    // =========================================================================
    wire [EXP_WIDTH-1:0] exp_out[0:LANES-1];
    wire signed [DATA_WIDTH-1:0] shifted_lane[0:LANES-1];

    // Register to hold input_fifo data for exp_rom (stable during ROM latency)
    reg [AXIS_DATA_WIDTH-1:0] input_fifo_data_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_fifo_data_reg <= {AXIS_DATA_WIDTH{1'b0}};
        end else if (input_fifo_rd_en) begin
            // Capture input_fifo_dout when read is triggered
            input_fifo_data_reg <= input_fifo_dout;
        end
    end

    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : gen_exp_rom
            // Subtract global_max for numerical stability
            // Use registered data instead of combinational fifo output
            wire signed [DATA_WIDTH-1:0] fifo_lane = input_fifo_data_reg[g*DATA_WIDTH+:DATA_WIDTH];
            assign shifted_lane[g] = fifo_lane - global_max;

            exp_rom #(
                .ADDR_WIDTH(8),
                .DATA_WIDTH(EXP_WIDTH),
                .INIT_FILE (EXP_INIT_FILE)
            ) u_exp_rom (
                .clk (clk),
                .addr(shifted_lane[g]),  // Now always <= 0
                .dout(exp_out[g])
            );
        end
    endgenerate

    // Sum of 8 exp results (combinational) - PIPELINED for timing
    reg [SUM_WIDTH-1:0] exp_sum;
    integer i;
    always @(*) begin
        exp_sum = {SUM_WIDTH{1'b0}};
        for (i = 0; i < LANES; i = i + 1) begin
            exp_sum = exp_sum + {{(SUM_WIDTH - EXP_WIDTH) {1'b0}}, exp_out[i]};
        end
    end

    // Pipeline register for exp_sum to break accumulator critical path
    reg  [ SUM_WIDTH-1:0] exp_sum_r;
    reg                   exp_sum_valid;

    // =========================================================================
    // EXP FIFO - buffer exp results between passes
    // =========================================================================
    reg  [FIFO_WIDTH-1:0] fifo_din_reg;
    reg                   fifo_wr_en_reg;
    wire [FIFO_WIDTH-1:0] fifo_dout;
    wire fifo_full, fifo_empty;
    wire fifo_rd_en;
    wire fifo_clr = (state == S_IDLE) && start;

    integer p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_din_reg   <= {FIFO_WIDTH{1'b0}};
            fifo_wr_en_reg <= 1'b0;
        end else if (state == S_IDLE) begin
            fifo_din_reg   <= {FIFO_WIDTH{1'b0}};
            fifo_wr_en_reg <= 1'b0;
        end else if (state == S_ACCUMULATE && exp_out_valid_d2 && !fifo_full) begin
            // Only write to exp_fifo during S_ACCUMULATE to prevent stale X writes
            for (p = 0; p < LANES; p = p + 1) fifo_din_reg[p*EXP_WIDTH+:EXP_WIDTH] <= exp_out[p];
            fifo_wr_en_reg <= 1'b1;
        end else begin
            fifo_wr_en_reg <= 1'b0;
        end
    end

    softmax_fifo #(
        .WIDTH(FIFO_WIDTH),
        .DEPTH(FIFO_DEPTH)
    ) u_exp_fifo (
        .clk  (clk),
        .rst_n(rst_n),
        .clr  (fifo_clr),
        .wr_en(fifo_wr_en_reg),
        .din  (fifo_din_reg),
        .rd_en(fifo_rd_en),
        .dout (fifo_dout),
        .full (fifo_full),
        .empty(fifo_empty)
    );

    // =========================================================================
    // MSR unit (reciprocal approximation) - PIPELINED (2 cycles)
    // =========================================================================
    wire [RECIP_WIDTH-1:0] msr_mult;
    wire [4:0] msr_shift;
    wire msr_valid;
    reg msr_start;

    msr_unit #(
        .SUM_WIDTH  (SUM_WIDTH),
        .RECIP_WIDTH(RECIP_WIDTH),
        .LUT_ADDR_W (6),
        .INIT_FILE  (RECIP_INIT_FILE)
    ) u_msr (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (msr_start),
        .sum_in     (global_sum),
        .valid      (msr_valid),
        .recip_out  (msr_mult),
        .shift_alpha(msr_shift)
    );

    // =========================================================================
    // Normalization datapath - 3-STAGE PIPELINE
    // =========================================================================
    // Stage 0: FIFO read → exp_pop_r (register DSP input for timing)
    // Stage 1: exp_pop_r × msr_mult_r → prod_reg
    // Stage 2: shift/saturate → out_data_r
    // =========================================================================
    wire [EXP_WIDTH-1:0] exp_pop[0:LANES-1];
    genvar u;
    generate
        for (u = 0; u < LANES; u = u + 1) begin : unpack_fifo_out
            assign exp_pop[u] = fifo_dout[u*EXP_WIDTH+:EXP_WIDTH];
        end
    endgenerate

    // Stage 0 registers: capture FIFO output to break FIFO→DSP critical path
    reg     [      EXP_WIDTH-1:0] exp_pop_r     [0:LANES-1];
    reg                           exp_pop_valid;

    // Stage 1: Multiply pipeline
    reg     [               35:0] prod_reg      [0:LANES-1];
    reg                           prod_valid;

    // Shift + saturate
    reg     [AXIS_DATA_WIDTH-1:0] shift_data;
    reg     [               47:0] shift_tmp;
    integer                       k;
    always @(*) begin
        shift_data = {AXIS_DATA_WIDTH{1'b0}};
        for (k = 0; k < LANES; k = k + 1) begin
            shift_tmp = (prod_reg[k] >> msr_shift_r) >> 7;
            if (shift_tmp > 48'd255) shift_data[k*DATA_WIDTH+:DATA_WIDTH] = 8'hFF;
            else shift_data[k*DATA_WIDTH+:DATA_WIDTH] = shift_tmp[7:0];
        end
    end

    // Output holding register
    reg [AXIS_DATA_WIDTH-1:0] out_data_r;
    reg out_valid_r;
    reg out_last_r;

    wire handshake_out = out_valid_r && m_axis_tready;
    wire out_ready_for_new = (!out_valid_r) || handshake_out;
    // can_pop_fifo: Pop FIFO when S_NORMALIZE, FIFO not empty, and exp_pop_r stage is empty (can receive)
    wire can_pop_fifo = (state == S_NORMALIZE) && !fifo_empty && !exp_pop_valid;

    // Pre-computed and registered last signal (A1/A4: pipeline the compare)
    // last_for_output_r is set when tokens_remaining will become <= LANES after current output
    reg last_for_output_r;
    wire is_last_beat = (tokens_remaining <= LANES);  // Simple compare, no adder chain

    assign m_axis_tdata = out_data_r;
    assign m_axis_tvalid = out_valid_r;
    assign m_axis_tlast = out_last_r;

    // Input ready only during S_FIND_MAX
    assign s_axis_tready = (state == S_FIND_MAX) && !input_fifo_full && (tokens_accepted < num_tokens);

    assign fifo_rd_en = can_pop_fifo;

    // =========================================================================
    // Control logic for input FIFO read during S_ACCUMULATE
    // =========================================================================
    wire accept_input_fifo = (state == S_ACCUMULATE) && !input_fifo_empty && !fifo_full;
    assign input_fifo_rd_en = accept_input_fifo;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exp_out_valid_d1 <= 1'b0;
            exp_out_valid_d2 <= 1'b0;
        end else if (state != S_ACCUMULATE) begin
            exp_out_valid_d1 <= 1'b0;
            exp_out_valid_d2 <= 1'b0;
        end else begin
            exp_out_valid_d1 <= input_fifo_rd_en;
            exp_out_valid_d2 <= exp_out_valid_d1;
        end
    end

    // =========================================================================
    // MSR Start Pulse Generation (triggers on entry to S_CALC_RECIP)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msr_start <= 1'b0;
        end else begin
            // Pulse msr_start when transitioning from S_ACCUMULATE to S_CALC_RECIP
            msr_start <= (state == S_ACCUMULATE) && (next_state == S_CALC_RECIP);
        end
    end

    // =========================================================================
    // State Machine
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (start) begin
                    if (num_tokens != 0) next_state = S_FIND_MAX;
                    else next_state = S_IDLE;
                end
            end
            S_FIND_MAX: begin
                // Transition when all tokens accepted AND max pipeline has drained.
                // Wait for beat_max_valid to go low after processing the last beat.
                if (tokens_accepted >= num_tokens && !max_stage1_valid && !beat_max_valid)
                    next_state = S_ACCUMULATE;
            end
            S_ACCUMULATE: begin
                // Wait for all tokens processed AND exp_sum pipeline drained
                if (tokens_processed >= num_tokens && !exp_sum_valid) next_state = S_CALC_RECIP;
            end
            S_CALC_RECIP: begin
                // Wait for pipelined MSR to produce valid output (2 cycles after start)
                if (msr_valid) next_state = S_NORMALIZE;
            end
            S_NORMALIZE: begin
                if (handshake_out && out_last_r) next_state = S_IDLE;
            end
            default: next_state = S_IDLE;
        endcase
    end

    // =========================================================================
    // Datapath Logic
    // =========================================================================
    assign input_fifo_wr_en = accept_axi_input;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            global_sum        <= {SUM_WIDTH{1'b0}};
            global_max        <= 8'h80;  // -128 (minimum signed value)
            beat_max_r        <= {DATA_WIDTH{1'b0}};
            beat_max_valid    <= 1'b0;
            tokens_accepted   <= {COUNTER_WIDTH{1'b0}};
            tokens_processed  <= {COUNTER_WIDTH{1'b0}};
            tokens_remaining  <= {COUNTER_WIDTH{1'b0}};
            last_for_output_r <= 1'b0;
            msr_mult_r        <= {RECIP_WIDTH{1'b0}};
            msr_shift_r       <= 5'd0;
            prod_valid        <= 1'b0;
            exp_pop_valid     <= 1'b0;
            exp_sum_r         <= {SUM_WIDTH{1'b0}};
            exp_sum_valid     <= 1'b0;
            out_data_r        <= {AXIS_DATA_WIDTH{1'b0}};
            out_valid_r       <= 1'b0;
            out_last_r        <= 1'b0;
            done              <= 1'b0;
            // Initialize pipeline registers to prevent X propagation
            for (k = 0; k < LANES; k = k + 1) begin
                prod_reg[k]  <= 36'd0;
                exp_pop_r[k] <= {EXP_WIDTH{1'b0}};
            end
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    global_sum        <= {SUM_WIDTH{1'b0}};
                    global_max        <= 8'h80;  // Reset to minimum
                    beat_max_r        <= {DATA_WIDTH{1'b0}};
                    beat_max_valid    <= 1'b0;
                    tokens_accepted   <= {COUNTER_WIDTH{1'b0}};
                    tokens_processed  <= {COUNTER_WIDTH{1'b0}};
                    tokens_remaining  <= num_tokens[COUNTER_WIDTH-1:0];  // Init down-counter
                    last_for_output_r <= 1'b0;
                    out_valid_r       <= 1'b0;
                    out_last_r        <= 1'b0;
                    prod_valid        <= 1'b0;
                    if (start && num_tokens == 0) begin
                        done <= 1'b1;
                    end
                end

                S_FIND_MAX: begin
                    // Update global_max using the previous cycle's beat_max.
                    if (beat_max_valid) begin
                        if (beat_max_r > global_max) begin
                            global_max <= beat_max_r;
                        end
                    end

                    // Count tokens when AXI input is accepted (Stage 0)
                    if (accept_axi_input) begin
                        tokens_accepted <= tokens_accepted + LANES;
                    end

                    // Capture beat_max when Stage 1 results are valid (1 cycle after input)
                    if (max_stage1_valid) begin
                        beat_max_r <= beat_max;
                    end
                    beat_max_valid <= max_stage1_valid;
                end

                S_ACCUMULATE: begin
                    // Stage 1: Register exp_sum when data is valid from exp_rom
                    if (exp_out_valid_d2) begin
                        exp_sum_r     <= exp_sum;
                        exp_sum_valid <= 1'b1;
                    end else begin
                        exp_sum_valid <= 1'b0;
                    end

                    // Stage 2: Add registered exp_sum to global_sum (pipelined)
                    if (exp_sum_valid) begin
                        global_sum       <= global_sum + exp_sum_r;
                        tokens_processed <= tokens_processed + LANES;
                    end
                end

                S_CALC_RECIP: begin
                    // Trigger MSR on first cycle of this state
                    // msr_start is set below based on state transition detection

                    // Capture MSR outputs when valid (after 2-cycle pipeline)
                    if (msr_valid) begin
                        msr_mult_r  <= msr_mult;
                        msr_shift_r <= msr_shift;
                    end

                    // Initialize for S_NORMALIZE (tokens_remaining already set in S_IDLE)
                    out_valid_r <= 1'b0;
                    out_last_r  <= 1'b0;
                    prod_valid  <= 1'b0;
                end

                S_NORMALIZE: begin
                    // Stage 0: FIFO → exp_pop_r (register to break critical path)
                    // Pop FIFO when exp_pop_r is empty or being consumed by Stage 1
                    if (can_pop_fifo) begin
                        for (k = 0; k < LANES; k = k + 1) exp_pop_r[k] <= exp_pop[k];
                        exp_pop_valid <= 1'b1;
                    end else if (exp_pop_valid && !prod_valid) begin
                        // exp_pop_r consumed by Stage 1, clear valid
                        exp_pop_valid <= 1'b0;
                    end

                    // Stage 1: exp_pop_r × msr_mult_r → prod_reg
                    // Move data when prod_reg is empty (can receive)
                    if (exp_pop_valid && !prod_valid) begin
                        for (k = 0; k < LANES; k = k + 1) prod_reg[k] <= exp_pop_r[k] * msr_mult_r;
                        prod_valid <= 1'b1;
                    end

                    // Stage 2: prod_reg → shift/saturate → out_data_r
                    // Move data when output is ready (empty or being consumed)
                    if (prod_valid && out_ready_for_new) begin
                        out_data_r <= shift_data;
                        out_valid_r <= 1'b1;
                        out_last_r <= is_last_beat;  // Use simple compare
                        prod_valid <= 1'b0;  // Clear after consumption
                        // Pre-compute next last signal (A4: pipeline compare)
                        last_for_output_r <= (tokens_remaining <= (LANES + LANES));
                    end else if (handshake_out) begin
                        // Output consumed but no new data
                        out_valid_r <= 1'b0;
                        out_last_r  <= 1'b0;
                    end

                    // Decrement tokens_remaining on handshake (A2: down-counter)
                    if (handshake_out) begin
                        tokens_remaining <= tokens_remaining - LANES;
                        if (out_last_r) begin
                            done        <= 1'b1;
                            out_valid_r <= 1'b0;
                            out_last_r  <= 1'b0;
                        end
                    end
                end
            endcase
        end
    end

endmodule
