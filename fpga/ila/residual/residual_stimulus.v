`timescale 1ns / 1ps

module residual_axis_stimulus #(
    parameter DATA_WIDTH = 64,
    parameter ELEM_WIDTH = 8
) (
    input wire clk,
    input wire rst_n,
    input wire start_trigger,

    // Stream A output
    output reg  [DATA_WIDTH-1:0] m_axis_a_tdata,
    output reg                   m_axis_a_tvalid,
    output reg                   m_axis_a_tlast,
    input  wire                  m_axis_a_tready,

    // Stream B output
    output reg  [DATA_WIDTH-1:0] m_axis_b_tdata,
    output reg                   m_axis_b_tvalid,
    output reg                   m_axis_b_tlast,
    input  wire                  m_axis_b_tready
);

    localparam LANES = DATA_WIDTH / ELEM_WIDTH;  // 8 lanes
    localparam BURST_LEN = 10;

    reg [3:0] beat_count;

    localparam IDLE = 2'd0;
    localparam RUN = 2'd1;
    localparam DONE = 2'd2;
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

    // Data patterns exercising saturation and normal addition
    always @(*) begin
        m_axis_a_tdata = {DATA_WIDTH{1'b0}};
        m_axis_b_tdata = {DATA_WIDTH{1'b0}};

        if (state == RUN) begin
            case (beat_count)
                // Basic addition
                4'd0: begin
                    m_axis_a_tdata = {8{8'd10}};  // All 10
                    m_axis_b_tdata = {8{8'd20}};  // All 20, result = 30
                end
                4'd1: begin
                    m_axis_a_tdata = {8{8'hF0}};  // All -16
                    m_axis_b_tdata = {8{8'd16}};  // All 16, result = 0
                end
                // Positive saturation
                4'd2: begin
                    m_axis_a_tdata = {8{8'd120}};  // 120
                    m_axis_b_tdata = {8{8'd120}};  // 120, result = 127 (saturated)
                end
                4'd3: begin
                    m_axis_a_tdata = {8{8'd127}};  // Max positive
                    m_axis_b_tdata = {8{8'd1}};  // +1, result = 127 (saturated)
                end
                // Negative saturation
                4'd4: begin
                    m_axis_a_tdata = {8{-8'sd100}};  // -100
                    m_axis_b_tdata = {8{-8'sd60}};  // -60, result = -128 (saturated)
                end
                4'd5: begin
                    m_axis_a_tdata = {8{8'h80}};  // -128
                    m_axis_b_tdata = {8{8'hFF}};  // -1, result = -128 (saturated)
                end
                // Mixed patterns
                4'd6: begin
                    m_axis_a_tdata = 64'h7F_80_7F_80_7F_80_7F_80;  // +127, -128 alternating
                    m_axis_b_tdata = 64'h01_FF_01_FF_01_FF_01_FF;  // +1, -1 alternating
                end
                4'd7: begin
                    m_axis_a_tdata = 64'h00_01_02_03_04_05_06_07;  // Ramp
                    m_axis_b_tdata = 64'h07_06_05_04_03_02_01_00;  // Reverse ramp = 7 each
                end
                // Zero cases
                4'd8: begin
                    m_axis_a_tdata = {8{8'd0}};
                    m_axis_b_tdata = {8{8'd0}};
                end
                4'd9: begin
                    m_axis_a_tdata = {8{8'd50}};
                    m_axis_b_tdata = {8{-8'sd50}};  // Result = 0
                end
                default: begin
                    m_axis_a_tdata = {DATA_WIDTH{1'b0}};
                    m_axis_b_tdata = {DATA_WIDTH{1'b0}};
                end
            endcase
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
            beat_count      <= 4'd0;
        end else begin
            case (state)
                IDLE: begin
                    m_axis_a_tvalid <= 1'b0;
                    m_axis_b_tvalid <= 1'b0;
                    m_axis_a_tlast  <= 1'b0;
                    m_axis_b_tlast  <= 1'b0;
                    beat_count      <= 4'd0;

                    if (start_trigger_edge) begin
                        state           <= RUN;
                        m_axis_a_tvalid <= 1'b1;
                        m_axis_b_tvalid <= 1'b1;
                    end
                end

                RUN: begin
                    // TLAST on final beat
                    m_axis_a_tlast <= (beat_count == BURST_LEN - 1);
                    m_axis_b_tlast <= (beat_count == BURST_LEN - 1);

                    // Both streams must handshake together
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
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
