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
    localparam integer COUNT_WIDTH = $clog2(ARRAY_SIZE + 1);
    localparam [COUNT_WIDTH-1:0] ONE = {{COUNT_WIDTH - 1{1'b0}}, 1'b1};
    localparam [COUNT_WIDTH-1:0] ARRAY_SIZE_COUNT = ARRAY_SIZE;

    reg signed  [  ACC_WIDTH-1:0] accumulator;
    reg         [COUNT_WIDTH-1:0] mac_count;

    wire signed [  ACC_WIDTH-1:0] product;
    wire signed [  ACC_WIDTH-1:0] next_acc;

    // Calculate product and next accumulator value combinationally
    assign product  = a_in * b_in;
    assign next_acc = accumulator + product;

    // Accumulator logic and completion tracking
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
            end else if (a_valid_in && b_valid_in) begin
                accumulator <= next_acc;
                if (!acc_done) begin
                    mac_count <= mac_count + ONE;
                    if (mac_count + ONE == ARRAY_SIZE_COUNT) acc_done <= 1'b1;
                end
            end
        end
    end

    // Pipelining logic for A and B paths
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= {DATA_WIDTH{1'b0}};
            b_out <= {DATA_WIDTH{1'b0}};
            a_valid_out <= 1'b0;
            b_valid_out <= 1'b0;
        end else begin
            // Pass 'A' data and valid to the right
            a_out <= a_in;
            a_valid_out <= a_valid_in;

            // Pass 'B' data and valid down
            b_out <= b_in;
            b_valid_out <= b_valid_in;
        end
    end

    // Accumulator output register
    // Make acc_out reflect the just-updated sum when a MAC happens.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out <= {ACC_WIDTH{1'b0}};
        end else if (clear_acc) begin
            acc_out <= {ACC_WIDTH{1'b0}};
        end else if (a_valid_in && b_valid_in) begin
            // Use next_acc so acc_out aligns with acc_done on the next cycle
            acc_out <= next_acc;
        end
        // else: hold previous acc_out
    end

endmodule
