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

    reg [7:0] beat_count;
    reg [7:0] num_beats;

    localparam IDLE = 3'd0;
    localparam START_PULSE = 3'd1;
    localparam STREAM = 3'd2;
    localparam WAIT_DONE = 3'd3;
    localparam FINISHED = 3'd4;
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

    // Generate attention-logit-like patterns (INT8: -16 to +15 range)
    // This range is typical for requantized attention scores
    always @(*) begin
        m_axis_tdata = {AXIS_DATA_WIDTH{1'b0}};

        if (state == STREAM) begin
            case (beat_count[2:0])
                // Pattern 1: Gradient from -8 to +7
                3'd0: m_axis_tdata = 64'hF8_F9_FA_FB_FC_FD_FE_FF;  // -8 to -1
                3'd1: m_axis_tdata = 64'h00_01_02_03_04_05_06_07;  // 0 to +7
                // Pattern 2: Peak in center (simulates attention focus)
                3'd2: m_axis_tdata = 64'hF0_F0_F0_0F_0F_F0_F0_F0;  // -16, peak at +15
                3'd3: m_axis_tdata = 64'h00_00_00_0F_00_00_00_00;  // Single attention peak
                // Pattern 3: Uniform (flat attention)
                3'd4: m_axis_tdata = 64'h00_00_00_00_00_00_00_00;  // All zeros
                3'd5: m_axis_tdata = 64'h05_05_05_05_05_05_05_05;  // All +5
                // Pattern 4: Alternating
                3'd6: m_axis_tdata = 64'hF0_0F_F0_0F_F0_0F_F0_0F;  // -16, +15 alternating
                3'd7: m_axis_tdata = 64'h00_FF_00_FF_00_FF_00_FF;  // 0, -1 alternating
            endcase
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
        end else begin
            start <= 1'b0;  // Single-cycle pulse

            case (state)
                IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    beat_count    <= 8'd0;

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
                    state <= STREAM;
                    m_axis_tvalid <= 1'b1;
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
