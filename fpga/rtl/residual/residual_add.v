`timescale 1ns / 1ps

module residual_add #(
    parameter integer DATA_WIDTH = 128,
    parameter integer ELEM_WIDTH = 8
) (
    input wire clk,
    input wire rst_n,

    // Stream A
    input  wire [DATA_WIDTH-1:0] s_axis_a_tdata,
    input  wire                  s_axis_a_tvalid,
    input  wire                  s_axis_a_tlast,
    output wire                  s_axis_a_tready,

    // Stream B
    input  wire [DATA_WIDTH-1:0] s_axis_b_tdata,
    input  wire                  s_axis_b_tvalid,
    input  wire                  s_axis_b_tlast,
    output wire                  s_axis_b_tready,

    // Result stream
    output reg  [DATA_WIDTH-1:0] m_axis_tdata,
    output reg                   m_axis_tvalid,
    output reg                   m_axis_tlast,
    input  wire                  m_axis_tready
);
    localparam integer LANES = DATA_WIDTH / ELEM_WIDTH;
    integer idx;

    // Output staging/backpressure: accept new inputs only when output stage is empty or being consumed
    wire ready_for_inputs = (!m_axis_tvalid) || m_axis_tready;

    // Lock-step join: only assert ready on a side if the other side is valid, so pairs are consumed together
    assign s_axis_a_tready = ready_for_inputs && s_axis_b_tvalid;
    assign s_axis_b_tready = ready_for_inputs && s_axis_a_tvalid;

    // Saturating add with proper sign extension and overflow detection
    function [ELEM_WIDTH-1:0] sat_add;
        input signed [ELEM_WIDTH-1:0] a;
        input signed [ELEM_WIDTH-1:0] b;
        reg signed [ELEM_WIDTH : 0] a_ext;
        reg signed [ELEM_WIDTH : 0] b_ext;
        reg signed [ELEM_WIDTH : 0] sum_ext;
        begin
            // Sign-extend operands to ELEM_WIDTH+1 and add
            a_ext   = {a[ELEM_WIDTH-1], a};
            b_ext   = {b[ELEM_WIDTH-1], b};
            sum_ext = a_ext + b_ext;

            // Overflow if MSB differs from next MSB after addition
            if (sum_ext[ELEM_WIDTH] != sum_ext[ELEM_WIDTH-1]) begin
                // Positive overflow -> clamp to +max, negative overflow -> clamp to -min
                if (sum_ext[ELEM_WIDTH] == 1'b0)
                    sat_add = {1'b0, {(ELEM_WIDTH - 1) {1'b1}}};  // 0 111..1
                else sat_add = {1'b1, {(ELEM_WIDTH - 1) {1'b0}}};  // 1 000..0
            end else begin
                sat_add = sum_ext[ELEM_WIDTH-1:0];
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= {DATA_WIDTH{1'b0}};
            m_axis_tlast  <= 1'b0;
        end else begin
            // Produce a result only when both inputs can be consumed together
            if (ready_for_inputs && s_axis_a_tvalid && s_axis_b_tvalid) begin
                for (idx = 0; idx < LANES; idx = idx + 1) begin
                    m_axis_tdata[idx*ELEM_WIDTH+:ELEM_WIDTH] <= sat_add(
                        s_axis_a_tdata[idx*ELEM_WIDTH+:ELEM_WIDTH],
                        s_axis_b_tdata[idx*ELEM_WIDTH+:ELEM_WIDTH]
                    );
                end
                m_axis_tvalid <= 1'b1;

                // Enforce aligned frames: TLAST only when both inputs mark last
                m_axis_tlast  <= s_axis_a_tlast & s_axis_b_tlast;
            end else if (m_axis_tready) begin
                // Downstream consumed the staged output and no new pair this cycle
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
            end
        end
    end

endmodule
