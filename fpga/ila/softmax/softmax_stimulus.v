`timescale 1ns / 1ps

module softmax_axis_stimulus #(
    parameter AXIS_DATA_WIDTH = 64,
    parameter DATA_WIDTH      = 8
) (
    input wire       clk,
    input wire       rst_n,
    input wire       start_trigger,
    input wire [7:0] cfg_num_tokens, // Up to 256 tokens

    // Control outputs
    output reg         start,
    output reg  [31:0] num_tokens,
    input  wire        done,

    // AXI-Stream output
    output reg  [AXIS_DATA_WIDTH-1:0] m_axis_tdata,
    output reg                        m_axis_tvalid,
    output reg                        m_axis_tlast,
    input  wire                       m_axis_tready
);

    localparam LANES = AXIS_DATA_WIDTH / DATA_WIDTH;  // 8 tokens per beat
    localparam START_DELAY_CYCLES = 3;

    reg [7:0] beat_count;
    reg [7:0] num_beats;
    reg [7:0] start_delay_cnt;
    reg [31:0] tokens_sent;
    integer lane;

    localparam IDLE = 3'd0;
    localparam START_PULSE = 3'd1;
    localparam PRE_STREAM = 3'd2;
    localparam STREAM = 3'd3;
    localparam WAIT_DONE = 3'd4;
    localparam FINISHED = 3'd5;
    reg [2:0] state;

    // Edge detection
    wire start_trigger_edge;
    reg start_d1, start_d2;
    assign start_trigger_edge = start_d1 && ~start_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_d1 <= 0;
            start_d2 <= 0;
        end else begin
            start_d1 <= start_trigger;
            start_d2 <= start_d1;
        end
    end

    function [7:0] pattern_val;
        input [2:0] sel;
        begin
            case (sel)
                3'd0: pattern_val = 8'hF8;  // -8
                3'd1: pattern_val = 8'h00;  // 0
                3'd2: pattern_val = 8'h07;  // +7
                3'd3: pattern_val = 8'hF0;  // -16
                3'd4: pattern_val = 8'h0F;  // +15
                3'd5: pattern_val = 8'h05;  // +5
                3'd6: pattern_val = 8'hFF;  // -1
                3'd7: pattern_val = 8'h01;  // +1
                default: pattern_val = 8'h00;
            endcase
        end
    endfunction

    // Generate attention-logit-like patterns (INT8: -16 to +15 range)
    // This range is typical for requantized attention scores
    always @(*) begin
        m_axis_tdata = {AXIS_DATA_WIDTH{1'b0}};

        if (state == STREAM) begin
            for (lane = 0; lane < LANES; lane = lane + 1) begin
                if (tokens_sent + lane < num_tokens) begin
                    m_axis_tdata[lane*DATA_WIDTH +: DATA_WIDTH] =
                        pattern_val((tokens_sent + lane) & 3'b111);
                end
            end
        end
    end

    // State machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            start         <= 1'b0;
            num_tokens    <= 32'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            beat_count    <= 8'd0;
            num_beats     <= 8'd0;
            start_delay_cnt <= 8'd0;
            tokens_sent   <= 32'd0;
        end else begin
            start <= 1'b0;  // Single-cycle pulse

            case (state)
                IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    beat_count    <= 8'd0;
                    start_delay_cnt <= 8'd0;
                    tokens_sent <= 32'd0;

                    if (start_trigger_edge) begin
                        // Calculate number of beats (round up to nearest 8 tokens)
                        num_tokens <= {24'd0, cfg_num_tokens};
                        num_beats  <= (cfg_num_tokens + LANES - 1) / LANES;
                        state      <= START_PULSE;
                    end
                end

                START_PULSE: begin
                    // Assert start for one cycle before streaming
                    start <= 1'b1;
                    start_delay_cnt <= START_DELAY_CYCLES[7:0];
                    if (num_beats == 0) begin
                        state <= WAIT_DONE;
                    end else begin
                        state <= PRE_STREAM;
                    end
                end

                PRE_STREAM: begin
                    if (start_delay_cnt == 0) begin
                        state <= STREAM;
                        m_axis_tvalid <= 1'b1;
                    end else begin
                        start_delay_cnt <= start_delay_cnt - 1;
                    end
                end

                STREAM: begin
                    m_axis_tlast <= (beat_count == num_beats - 1);

                    if (m_axis_tready && m_axis_tvalid) begin
                        if (beat_count == num_beats - 1) begin
                            state         <= WAIT_DONE;
                            m_axis_tvalid <= 1'b0;
                            m_axis_tlast  <= 1'b0;
                        end else begin
                            beat_count <= beat_count + 1;
                        end
                        tokens_sent <= tokens_sent + LANES;
                    end
                end

                WAIT_DONE: begin
                    // Wait for softmax to complete all passes
                    if (done) begin
                        state <= FINISHED;
                    end
                end

                FINISHED: begin
                    // Allow retriggering
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
