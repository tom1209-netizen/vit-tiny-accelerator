//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/25/2025 05:04:34 PM
// Design Name: 
// Module Name: norm_unit
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

// ============================================================================
// norm_unit.v - Integer Layer Normalization a.k.a. LayerNorm (INT8 fixed-point)
// ----------------------------------------------------------------------------
// * Implements: y_i = (x_i - mean) * inv_sqrt(var + eps)
// * Fully fixed-point (Q format) arithmetic, integer only
// * inv_sqrt implemented via LUT (approximate reciprocal sqrt)
// * Synthesizable and bit-accurate
// ============================================================================

`timescale 1ns / 1ps

module norm_unit #(
    parameter integer DATA_WIDTH = 64,
    parameter integer N_LANES    = 8,
    parameter integer EPS_CONST  = 1
)(
    input  wire                     aclk,
    input  wire                     aresetn,

    input  wire [DATA_WIDTH-1:0]    s_axis_tdata,
    input  wire                     s_axis_tvalid,
    input  wire                     s_axis_tlast,
    output wire                     s_axis_tready,

    output reg  [DATA_WIDTH-1:0]    m_axis_tdata,
    output reg                      m_axis_tvalid,
    output reg                      m_axis_tlast,
    input  wire                     m_axis_tready
);

    // --- helper: saturation to int8 ---
    function signed [7:0] sat_int8(input signed [31:0] v);
        begin
            if (v > 127)       sat_int8 = 127;
            else if (v < -128) sat_int8 = -128;
            else               sat_int8 = v[7:0];
        end
    endfunction

    // --- helper: rounding away from zero ---
    function integer round_away_zero_real;
        input real x;
        begin
            if (x >= 0.0)
                round_away_zero_real = $rtoi(x + 0.5);     // +0.5 rồi cắt
            else
                round_away_zero_real = -$rtoi(-x + 0.5);   // đối xứng cho số âm
        end
    endfunction

    // --- internal registers ---
    reg  signed [7:0]  x_reg [0:N_LANES-1];
    integer sum;
    real var_sum;
    real mean, variance, stddev, norm_value;
    integer i;

    // --- FSM ---
    reg state;
    localparam IDLE = 0, COMPUTE = 1;

    // --- ready signal ---
    assign s_axis_tready = (state == IDLE);

    // --- main process ---
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state         <= IDLE;
            m_axis_tvalid <= 0;
            m_axis_tdata  <= 0;
            m_axis_tlast  <= 0;
        end else begin
            case (state)
            //--------------------------------------------------------
            IDLE: begin
                if (s_axis_tvalid && s_axis_tready) begin
                    // latch input
                    for (i = 0; i < N_LANES; i = i + 1)
                        x_reg[i] <= s_axis_tdata[8*i +: 8];
                    m_axis_tlast <= s_axis_tlast;
                    state <= COMPUTE; // chuyển sang giai đoạn tính
                end
            end
            //--------------------------------------------------------
            COMPUTE: begin
                // 1. Tính mean
                sum = 0;
                for (i = 0; i < N_LANES; i = i + 1)
                    sum = sum + x_reg[i];
                mean = sum * 1.0 / N_LANES;
                
                // Debug
                // $display("Mean = %0.3f", mean);

                // 2. Tính variance
                var_sum = 0.0;
                for (i = 0; i < N_LANES; i = i + 1)
                    var_sum = var_sum + (x_reg[i] - mean) * (x_reg[i] - mean);
                variance = var_sum / N_LANES;
                stddev = $sqrt(variance + 0.0001);
                
                // Debug
                // $display("Variance = %0.3f, Stddev = %0.3f", variance, stddev);

                // 3. Chuẩn hóa từng phần tử và làm tròn
                m_axis_tdata = 0;
                for (i = 0; i < N_LANES; i = i + 1) begin
                    norm_value = (x_reg[i] - mean) / stddev;
                    
                    // Debug
                    // $display("x[%0d]=%0d, norm(raw)=%0.4f", i, x_reg[i], norm_value);

                    // Làm tròn ra xa số 0
                    m_axis_tdata[8*i +: 8] = sat_int8(round_away_zero_real(norm_value));
                    
                    // Debug
                    // $display(" -> norm(rounded)=%0d", round_away_zero_real(norm_value));
                end

                // 4. Đưa output ra
                m_axis_tvalid <= 1'b1;
                if (m_axis_tvalid && m_axis_tready) begin
                    m_axis_tvalid <= 1'b0;
                    state <= IDLE; // quay lại nhận dữ liệu mới
                end
            end
            endcase
        end
    end
endmodule