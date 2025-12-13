module processing_element #(
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32,
    parameter ARRAY_SIZE = 8
) (
    input wire clk,
    input wire rst_n,

    // 'A' data path (horizontal)
    input  wire signed [DATA_WIDTH-1:0] a_in,
    input  wire                         a_valid_in,
    output reg signed  [DATA_WIDTH-1:0] a_out,
    output reg                          a_valid_out,

    // 'B' data path (vertical)
    input  wire signed [DATA_WIDTH-1:0] b_in,
    input  wire                         b_valid_in,
    output reg signed  [DATA_WIDTH-1:0] b_out,
    output reg                          b_valid_out,

    input wire clear_acc,

    output reg signed [ACC_WIDTH-1:0] acc_out,
    output reg                        acc_done
);
    // =========================================================================
    // 2-STAGE MAC PIPELINE for High-Frequency Operation (~196 MHz)
    // 
    // This design breaks the MAC path into two stages:
    //   Stage 1: Multiply -> product registered in product_r
    //   Stage 2: Accumulate -> product_r added to accumulator
    //
    // See fpga/docs/gemm_core.md for detailed timing analysis.
    // =========================================================================

    localparam integer COUNT_WIDTH = $clog2(ARRAY_SIZE + 1);
    localparam [COUNT_WIDTH-1:0] ONE = {{COUNT_WIDTH - 1{1'b0}}, 1'b1};
    localparam [COUNT_WIDTH-1:0] ARRAY_SIZE_COUNT = ARRAY_SIZE;

    reg signed [ACC_WIDTH-1:0] accumulator;
    reg [COUNT_WIDTH-1:0] mac_count;

    // Stage 1: Multiply with pipeline register (DSP48E1 inference)
    (* use_dsp = "yes" *)
    wire signed [ACC_WIDTH-1:0] product;
    assign product = a_in * b_in;

    reg signed [ACC_WIDTH-1:0] product_r;
    reg                        mac_valid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            product_r   <= {ACC_WIDTH{1'b0}};
            mac_valid_r <= 1'b0;
        end else begin
            product_r   <= product;
            mac_valid_r <= (a_valid_in && b_valid_in) && !clear_acc;
        end
    end

    // Stage 2: Accumulator
    wire signed [ACC_WIDTH-1:0] next_acc;
    assign next_acc = accumulator + product_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accumulator <= {ACC_WIDTH{1'b0}};
            mac_count   <= {COUNT_WIDTH{1'b0}};
            acc_done    <= 1'b0;
        end else begin
            if (clear_acc) begin
                accumulator <= {ACC_WIDTH{1'b0}};
                mac_count   <= {COUNT_WIDTH{1'b0}};
                acc_done    <= 1'b0;
            end else if (mac_valid_r) begin
                accumulator <= next_acc;
                if (!acc_done) begin
                    mac_count <= mac_count + ONE;
                    if (mac_count + ONE == ARRAY_SIZE_COUNT) acc_done <= 1'b1;
                end
            end
        end
    end

    // Inter-PE Data Propagation (1 cycle delay)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out       <= {DATA_WIDTH{1'b0}};
            b_out       <= {DATA_WIDTH{1'b0}};
            a_valid_out <= 1'b0;
            b_valid_out <= 1'b0;
        end else begin
            a_out       <= a_in;
            a_valid_out <= a_valid_in;
            b_out       <= b_in;
            b_valid_out <= b_valid_in;
        end
    end

    // Accumulator Output
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out <= {ACC_WIDTH{1'b0}};
        end else if (clear_acc) begin
            acc_out <= {ACC_WIDTH{1'b0}};
        end else if (mac_valid_r) begin
            acc_out <= next_acc;
        end
    end

endmodule
