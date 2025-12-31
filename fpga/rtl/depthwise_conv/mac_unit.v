`timescale 1ns / 1ps

module mac_unit #(
    parameter DATA_WIDTH  = 8,
    parameter LANES       = 8,
    parameter ACC_WIDTH   = 32,
    parameter KERNEL_SIZE = 9
) (
    input wire clk,
    input wire rst_n,

    // Input interface - packed arrays for portability
    input wire                                    data_valid,  // Window/kernel data ready
    input wire                                    data_last,   // Last beat flag
    input wire [KERNEL_SIZE*LANES*DATA_WIDTH-1:0] win_pack,    // 9 positions x 8 lanes x 8 bits
    input wire [KERNEL_SIZE*LANES*DATA_WIDTH-1:0] ker_pack,    // Same packing

    // Status
    output reg busy,  // Pipeline always ready (legacy signal)

    // Output interface - packed for portability
    output reg                       result_valid,
    output reg                       result_last,
    output reg [LANES*ACC_WIDTH-1:0] result_pack    // 8 lanes x 32 bits
);

    localparam KERNEL_PACK_WIDTH = KERNEL_SIZE * LANES * DATA_WIDTH;
    localparam PROD_WIDTH        = 2 * DATA_WIDTH;

    // Helper: Extract signed byte from packed data
    // Position p (0-8), lane l (0-7)
    function signed [DATA_WIDTH-1:0] extract_byte;
        input [KERNEL_PACK_WIDTH-1:0] pack;
        input [3:0] pos;
        input [3:0] lane;
        begin
            extract_byte = $signed(pack[pos*LANES*DATA_WIDTH+lane*DATA_WIDTH+:DATA_WIDTH]);
        end
    endfunction

    // Fully pipelined MAC (II=1). Each stage accumulates one kernel position.
    reg        [KERNEL_PACK_WIDTH-1:0] win_pipe   [0:KERNEL_SIZE-1];
    reg        [KERNEL_PACK_WIDTH-1:0] ker_pipe   [0:KERNEL_SIZE-1];
    reg        [      KERNEL_SIZE-1:0] valid_pipe;
    reg        [      KERNEL_SIZE-1:0] last_pipe;
    reg signed [  LANES*ACC_WIDTH-1:0] sum_pipe   [0:KERNEL_SIZE-1];

    // Multiply grid (stage x lane).
    wire signed [LANES*PROD_WIDTH-1:0] mult_stage [0:KERNEL_SIZE-1];

    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl = gl + 1) begin : gen_mult_stage0
            localparam [3:0] LANE = gl;
            wire signed [DATA_WIDTH-1:0] w;
            wire signed [DATA_WIDTH-1:0] k;
            (* use_dsp = "yes" *) wire signed [PROD_WIDTH-1:0] prod;
            assign w = extract_byte(win_pack, 4'd0, LANE);
            assign k = extract_byte(ker_pack, 4'd0, LANE);
            assign prod = w * k;
            assign mult_stage[0][gl*PROD_WIDTH+:PROD_WIDTH] = prod;
        end
    endgenerate

    genvar gs;
    generate
        for (gs = 1; gs < KERNEL_SIZE; gs = gs + 1) begin : gen_mult_stagen
            for (gl = 0; gl < LANES; gl = gl + 1) begin : gen_mult_lanen
                localparam [3:0] POS  = gs;
                localparam [3:0] LANE = gl;
                wire signed [DATA_WIDTH-1:0] w;
                wire signed [DATA_WIDTH-1:0] k;
                (* use_dsp = "yes" *) wire signed [PROD_WIDTH-1:0] prod;
                assign w = extract_byte(win_pipe[gs-1], POS, LANE);
                assign k = extract_byte(ker_pipe[gs-1], POS, LANE);
                assign prod = w * k;
                assign mult_stage[gs][gl*PROD_WIDTH+:PROD_WIDTH] = prod;
            end
        end
    endgenerate

    integer                            si;
    integer                            li;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy         <= 1'b0;
            result_valid <= 1'b0;
            result_last  <= 1'b0;
            result_pack  <= {(LANES * ACC_WIDTH) {1'b0}};
            valid_pipe   <= {KERNEL_SIZE{1'b0}};
            last_pipe    <= {KERNEL_SIZE{1'b0}};
            for (si = 0; si < KERNEL_SIZE; si = si + 1) begin
                win_pipe[si] <= {KERNEL_PACK_WIDTH{1'b0}};
                ker_pipe[si] <= {KERNEL_PACK_WIDTH{1'b0}};
                sum_pipe[si] <= {(LANES * ACC_WIDTH) {1'b0}};
            end
        end else begin
            busy <= 1'b0;

            // Stage 0: capture inputs and compute first product
            win_pipe[0] <= win_pack;
            ker_pipe[0] <= ker_pack;
            valid_pipe[0] <= data_valid;
            last_pipe[0] <= data_last;
            for (li = 0; li < LANES; li = li + 1) begin
                if (data_valid)
                    sum_pipe[0][li*ACC_WIDTH+:ACC_WIDTH] <= {{(ACC_WIDTH - PROD_WIDTH)
                        {mult_stage[0][li*PROD_WIDTH+PROD_WIDTH-1]}}, mult_stage[0][li*PROD_WIDTH+:PROD_WIDTH]};
                else sum_pipe[0][li*ACC_WIDTH+:ACC_WIDTH] <= {ACC_WIDTH{1'b0}};
            end

            // Stages 1..KERNEL_SIZE-1: accumulate remaining positions
            for (si = 1; si < KERNEL_SIZE; si = si + 1) begin
                win_pipe[si]   <= win_pipe[si-1];
                ker_pipe[si]   <= ker_pipe[si-1];
                valid_pipe[si] <= valid_pipe[si-1];
                last_pipe[si]  <= last_pipe[si-1];
                for (li = 0; li < LANES; li = li + 1) begin
                    if (valid_pipe[si-1])
                        sum_pipe[si][li*ACC_WIDTH+:ACC_WIDTH] <= $signed(
                            sum_pipe[si-1][li*ACC_WIDTH+:ACC_WIDTH]
                        ) + $signed({{(ACC_WIDTH - PROD_WIDTH)
                            {mult_stage[si][li*PROD_WIDTH+PROD_WIDTH-1]}}, mult_stage[si][li*PROD_WIDTH+:PROD_WIDTH]});
                    else sum_pipe[si][li*ACC_WIDTH+:ACC_WIDTH] <= {ACC_WIDTH{1'b0}};
                end
            end

            // Output stage
            result_valid <= valid_pipe[KERNEL_SIZE-1];
            result_last  <= last_pipe[KERNEL_SIZE-1];
            if (valid_pipe[KERNEL_SIZE-1]) begin
                for (li = 0; li < LANES; li = li + 1) begin
                    result_pack[li*ACC_WIDTH+:ACC_WIDTH] <= sum_pipe[KERNEL_SIZE-1][li*ACC_WIDTH+:ACC_WIDTH];
                end
            end else begin
                result_pack <= {(LANES * ACC_WIDTH) {1'b0}};
            end
        end
    end

endmodule
