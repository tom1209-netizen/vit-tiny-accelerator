module processing_element #(
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH = 32
) (
    input  wire                         clk,
    input  wire                         rst_n,
    
    // 'A' data path (horizontal)
    input  wire signed [DATA_WIDTH-1:0] a_in,
    input  wire                         a_valid_in,
    output reg  signed [DATA_WIDTH-1:0] a_out,
    output reg                          a_valid_out,

    // 'B' data path (vertical)
    input  wire signed [DATA_WIDTH-1:0] b_in,
    input  wire                         b_valid_in,
    output reg  signed [DATA_WIDTH-1:0] b_out,
    output reg                          b_valid_out,
    
    input  wire                         clear_acc,
    
    output reg  signed [ACC_WIDTH-1:0]  acc_out
);
    
    reg signed [ACC_WIDTH-1:0] accumulator;
    
    wire signed [ACC_WIDTH-1:0] product;
    wire signed [ACC_WIDTH-1:0] next_acc;
    
    // Calculate product and next accumulator value combinationally
    assign product = a_in * b_in;
    assign next_acc = accumulator + product;
    
    // Accumulator logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accumulator <= {ACC_WIDTH{1'b0}};
        end else begin
            if (clear_acc) begin
                accumulator <= {ACC_WIDTH{1'b0}};
            // Only accumulate when BOTH inputs are valid
            end else if (a_valid_in && b_valid_in) begin
                accumulator <= next_acc;
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
    // This gives a known, registered output value
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out <= {ACC_WIDTH{1'b0}};
        end else begin
            acc_out <= accumulator;
        end
    end
    
endmodule