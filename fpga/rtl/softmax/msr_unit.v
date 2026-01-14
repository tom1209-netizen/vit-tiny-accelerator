`timescale 1ns / 1ps

// =============================================================================
// Pipelined Multiply-Shift-Round (MSR) Unit
// =============================================================================
// Computes an approximation of 1/sum_in without division hardware.
//
// PIPELINE STAGES (2 cycles total):
//   Cycle 1: Priority encoder finds MSB position → register intermediate values
//   Cycle 2: LUT lookup with registered shift → output valid
//
// Protocol:
//   - Assert 'start' for 1 cycle when sum_in is valid
//   - 'valid' asserts 2 cycles later with recip_out and shift_alpha
// =============================================================================
module msr_unit #(
    parameter integer SUM_WIDTH   = 32,
    parameter integer RECIP_WIDTH = 16,
    parameter integer LUT_ADDR_W  = 6,                   // 64-entry LUT
    parameter         INIT_FILE   = "recip_lut.mem"
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   start,       // Pulse to begin computation
    input  wire [  SUM_WIDTH-1:0] sum_in,
    output reg                    valid,       // Output valid (2 cycles after start)
    output reg  [RECIP_WIDTH-1:0] recip_out,
    output reg  [            4:0] shift_alpha
);
    localparam integer LUT_DEPTH = 1 << LUT_ADDR_W;

    // Reciprocal LUT (initialized from file)
    reg [RECIP_WIDTH-1:0] recip_lut[0:LUT_DEPTH-1];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, recip_lut);
        end
    end

    // =========================================================================
    // Stage 1: Priority Encoder (Combinational)
    // =========================================================================
    integer idx;
    reg [5:0] leading_one_pos;

    always @(*) begin : find_msb
        leading_one_pos = 0;
        for (idx = SUM_WIDTH - 1; idx >= 0; idx = idx - 1) begin
            if (sum_in[idx]) begin
                leading_one_pos = idx[5:0];
                disable find_msb;
            end
        end
    end

    wire [4:0] calc_shift = (leading_one_pos > (LUT_ADDR_W-1)) ?
                             (leading_one_pos - (LUT_ADDR_W-1)) : 5'd0;

    // =========================================================================
    // Pipeline Registers (Stage 1 → Stage 2)
    // =========================================================================
    reg stage1_valid;
    reg [SUM_WIDTH-1:0] sum_in_r;
    reg [4:0] calc_shift_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage1_valid <= 1'b0;
            sum_in_r     <= {SUM_WIDTH{1'b0}};
            calc_shift_r <= 5'd0;
        end else begin
            stage1_valid <= start;
            if (start) begin
                sum_in_r     <= sum_in;
                calc_shift_r <= calc_shift;
            end
        end
    end

    // =========================================================================
    // Stage 2: LUT Lookup (from registered values)
    // =========================================================================
    wire [LUT_ADDR_W-1:0] lut_index = (sum_in_r >> calc_shift_r);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid       <= 1'b0;
            recip_out   <= {RECIP_WIDTH{1'b0}};
            shift_alpha <= 5'd0;
        end else begin
            valid <= stage1_valid;
            if (stage1_valid) begin
                recip_out   <= recip_lut[lut_index];
                shift_alpha <= calc_shift_r;
            end
        end
    end

endmodule
