`timescale 1ns / 1ps

module msr_unit #(
    parameter integer SUM_WIDTH   = 32,
    parameter integer RECIP_WIDTH = 16,
    parameter integer LUT_ADDR_W  = 6,                   // 64-entry LUT
    parameter         INIT_FILE   = "lut/recip_lut.hex"
) (
    input  wire [  SUM_WIDTH-1:0] sum_in,
    output reg  [RECIP_WIDTH-1:0] recip_out,
    output reg  [            4:0] shift_alpha
);
    localparam integer LUT_DEPTH = 1 << LUT_ADDR_W;

    reg [RECIP_WIDTH-1:0] recip_lut[0:LUT_DEPTH-1];

    integer idx;
    reg [5:0] leading_one_pos;

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, recip_lut);
        end
    end

    // Priority encoder to find MSB position
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

    wire [LUT_ADDR_W-1:0] lut_index = (sum_in >> calc_shift);

    always @(*) begin
        shift_alpha = calc_shift;
        recip_out   = recip_lut[lut_index];
    end

endmodule
