`timescale 1ns / 1ps

module gemm_axis_stimulus #(
    parameter DATA_WIDTH      = 8,
    parameter ARRAY_SIZE      = 8,
    parameter AXIS_DATA_WIDTH = 64
) (
    input wire clk,
    input wire rst_n,
    input wire start_trigger,

    // Matrix A output
    output reg  [AXIS_DATA_WIDTH-1:0] m_axis_a_tdata,
    output reg                        m_axis_a_tvalid,
    output reg                        m_axis_a_tlast,
    input  wire                       m_axis_a_tready,

    // Matrix B output
    output reg  [AXIS_DATA_WIDTH-1:0] m_axis_b_tdata,
    output reg                        m_axis_b_tvalid,
    output reg                        m_axis_b_tlast,
    input  wire                       m_axis_b_tready,

    // Control output
    output reg start_tile
);

    // Wavefront scheduling requires 2*ARRAY_SIZE - 1 = 15 beats
    localparam BURST_LEN = 2 * ARRAY_SIZE - 1;  // 15 beats

    // Matrix storage (8x8 INT8)
    reg signed [DATA_WIDTH-1:0] A[0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    reg signed [DATA_WIDTH-1:0] B[0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    reg [4:0] beat_count;

    localparam IDLE = 2'd0;
    localparam START = 2'd1;
    localparam RUN = 2'd2;
    localparam DONE = 2'd3;
    reg [1:0] state;

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

    // Initialize matrices with simple patterns
    // A = additive ramp, B = 2*Identity
    // Result C = A * (2*I) = 2*A (easy to verify!)
    integer i, j;
    initial begin
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
            for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                A[i][j] = (i + j) & 8'h7F;  // Ramp: 0..14, avoid overflow
                B[i][j] = (i == j) ? 8'd2 : 8'd0;  // 2*Identity
            end
        end
    end

    // Build wavefront beats combinationally
    reg [AXIS_DATA_WIDTH-1:0] a_beat_data, b_beat_data;
    integer lane, col;

    always @(*) begin
        a_beat_data = {AXIS_DATA_WIDTH{1'b0}};
        b_beat_data = {AXIS_DATA_WIDTH{1'b0}};

        if (state == RUN) begin
            // Wavefront scheduling: diagonal traversal
            for (lane = 0; lane < ARRAY_SIZE; lane = lane + 1) begin
                col = beat_count - lane;
                if (col >= 0 && col < ARRAY_SIZE) begin
                    // A[lane][col] for lane's position
                    a_beat_data[lane*DATA_WIDTH+:DATA_WIDTH] = A[lane][col];
                    // B[col][lane] for column-major access
                    b_beat_data[lane*DATA_WIDTH+:DATA_WIDTH] = B[col][lane];
                end
            end
        end
    end

    // State machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= IDLE;
            m_axis_a_tvalid <= 1'b0;
            m_axis_b_tvalid <= 1'b0;
            m_axis_a_tlast  <= 1'b0;
            m_axis_b_tlast  <= 1'b0;
            m_axis_a_tdata  <= {AXIS_DATA_WIDTH{1'b0}};
            m_axis_b_tdata  <= {AXIS_DATA_WIDTH{1'b0}};
            start_tile      <= 1'b0;
            beat_count      <= 5'd0;
        end else begin
            start_tile <= 1'b0;  // Single-cycle pulse

            case (state)
                IDLE: begin
                    m_axis_a_tvalid <= 1'b0;
                    m_axis_b_tvalid <= 1'b0;
                    beat_count      <= 5'd0;

                    if (start_trigger_edge) begin
                        state      <= START;
                        start_tile <= 1'b1;  // Pulse to DUT
                    end
                end

                START: begin
                    // Wait one cycle for DUT to be ready
                    state           <= RUN;
                    m_axis_a_tvalid <= 1'b1;
                    m_axis_b_tvalid <= 1'b1;
                    m_axis_a_tdata  <= a_beat_data;
                    m_axis_b_tdata  <= b_beat_data;
                end

                RUN: begin
                    m_axis_a_tdata <= a_beat_data;
                    m_axis_b_tdata <= b_beat_data;

                    // TLAST on final beat
                    m_axis_a_tlast <= (beat_count == BURST_LEN - 1);
                    m_axis_b_tlast <= (beat_count == BURST_LEN - 1);

                    // Handshake
                    if (m_axis_a_tready && m_axis_b_tready && m_axis_a_tvalid) begin
                        if (beat_count == BURST_LEN - 1) begin
                            state           <= DONE;
                            m_axis_a_tvalid <= 1'b0;
                            m_axis_b_tvalid <= 1'b0;
                            m_axis_a_tlast  <= 1'b0;
                            m_axis_b_tlast  <= 1'b0;
                        end else begin
                            beat_count <= beat_count + 1;
                        end
                    end
                end

                DONE: begin
                    // Wait for retriggering
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
