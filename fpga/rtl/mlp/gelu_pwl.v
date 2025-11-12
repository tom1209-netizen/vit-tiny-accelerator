//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/28/2025 12:04:15 AM
// Design Name: 
// Module Name: gelu_pwl
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


// Note: // Note: Initially, we considered using the GeLU activation function and even explored a hybrid GeLU approach 
// that utilized a second-order linear approximation for more accurate calculations. However, we ultimately 
// decided to use ReLU because it provides a simpler, more efficient computation with minimal hardware overhead 
// while still offering satisfactory performance for the model. Additionally, the rounding errors associated with 
// GeLU approximations were found to be less impactful than expected, making ReLU a suitable choice for this design.

// ============================================================================
// Simplified ReLU INT8 version
//   y = 0     , x < 0
//   y = x     , x >= 0
// Parameters are in fixed-point Q(COEF_FRAC).
// ============================================================================

`timescale 1ns / 1ps

module gelu_pwl #(
    parameter integer DATA_WIDTH = 64   // 8 lanes x 8-bit
)(
    input  wire                  aclk,
    input  wire                  aresetn,

    // AXI4-Stream input
    input  wire [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                  s_axis_tvalid,
    input  wire                  s_axis_tlast,
    output reg                   s_axis_tready,

    // AXI4-Stream output
    output reg  [DATA_WIDTH-1:0] m_axis_tdata,
    output reg                   m_axis_tvalid,
    output reg                   m_axis_tlast,
    input  wire                  m_axis_tready
);

    localparam LANES = DATA_WIDTH / 8;  // Updated for 64 bits stream

    // --- ReLU for INT8 ---
    function signed [7:0] relu_lane(input signed [7:0] x);
        begin
            // Nếu x là số âm (bit MSB = 1), set về 0, nếu không giữ nguyên giá trị
            if (x[7] == 1'b1)  // Kiểm tra bit dấu
                relu_lane = 8'd0;  // Nếu số âm, set về 0
            else
                relu_lane = x;  // Nếu số dương, giữ nguyên giá trị
        end
    endfunction

    // --- Unpack / compute / pack per lane ---
    integer i;
    reg signed [7:0] in_lane [0:LANES-1];  // 8 lanes for INT8
    reg signed [7:0] out_lane[0:LANES-1];  // Processed results per lane
    reg [DATA_WIDTH-1:0] output_stream;       // Final 64-bit output stream

    always @* begin
        for (i = 0; i < LANES; i = i+1) begin
            // Unpack each 8-bit INT8 from the input 64-bit stream
            in_lane[i] = s_axis_tdata[8*i +: 8];  
            // Apply GELU (ReLU) logic for INT8
            out_lane[i] = relu_lane(in_lane[i]);   // Apply ReLU (negative values -> 0)
            // Pack the processed INT8 results back into a 64-bit stream
            output_stream[8*i +: 8] = out_lane[i];    // Concatenate to form the final output
        end
    end

    // --- AXI handshake ---
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= 0;
            m_axis_tlast  <= 0;
            s_axis_tready <= 1'b0;
        end else begin
            s_axis_tready <= (!m_axis_tvalid || m_axis_tready);

            if (s_axis_tvalid && s_axis_tready) begin
                m_axis_tdata  <= output_stream;
                m_axis_tvalid <= 1'b1;
                m_axis_tlast  <= s_axis_tlast;
            end else if (m_axis_tvalid && m_axis_tready) begin
                m_axis_tvalid <= 1'b0;
            end
        end
    end

endmodule
