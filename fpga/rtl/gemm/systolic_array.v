module systolic_array #(
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32,
    parameter ARRAY_SIZE = 8
) (
    input wire clk,
    input wire rst_n,

    // Flattened A inputs (8 rows)
    input wire signed [DATA_WIDTH-1:0] a_in_0,
    input wire signed [DATA_WIDTH-1:0] a_in_1,
    input wire signed [DATA_WIDTH-1:0] a_in_2,
    input wire signed [DATA_WIDTH-1:0] a_in_3,
    input wire signed [DATA_WIDTH-1:0] a_in_4,
    input wire signed [DATA_WIDTH-1:0] a_in_5,
    input wire signed [DATA_WIDTH-1:0] a_in_6,
    input wire signed [DATA_WIDTH-1:0] a_in_7,

    input wire a_valid_in_0,
    input wire a_valid_in_1,
    input wire a_valid_in_2,
    input wire a_valid_in_3,
    input wire a_valid_in_4,
    input wire a_valid_in_5,
    input wire a_valid_in_6,
    input wire a_valid_in_7,

    // Flattened B inputs (8 columns)
    input wire signed [DATA_WIDTH-1:0] b_in_0,
    input wire signed [DATA_WIDTH-1:0] b_in_1,
    input wire signed [DATA_WIDTH-1:0] b_in_2,
    input wire signed [DATA_WIDTH-1:0] b_in_3,
    input wire signed [DATA_WIDTH-1:0] b_in_4,
    input wire signed [DATA_WIDTH-1:0] b_in_5,
    input wire signed [DATA_WIDTH-1:0] b_in_6,
    input wire signed [DATA_WIDTH-1:0] b_in_7,

    input wire b_valid_in_0,
    input wire b_valid_in_1,
    input wire b_valid_in_2,
    input wire b_valid_in_3,
    input wire b_valid_in_4,
    input wire b_valid_in_5,
    input wire b_valid_in_6,
    input wire b_valid_in_7,

    input wire clear_acc,

    // Flattened accumulator outputs (64 values)
    output wire signed [ACC_WIDTH-1:0] acc_out_0_0,
    output wire signed [ACC_WIDTH-1:0] acc_out_0_1,
    output wire signed [ACC_WIDTH-1:0] acc_out_0_2,
    output wire signed [ACC_WIDTH-1:0] acc_out_0_3,
    output wire signed [ACC_WIDTH-1:0] acc_out_0_4,
    output wire signed [ACC_WIDTH-1:0] acc_out_0_5,
    output wire signed [ACC_WIDTH-1:0] acc_out_0_6,
    output wire signed [ACC_WIDTH-1:0] acc_out_0_7,

    output wire signed [ACC_WIDTH-1:0] acc_out_1_0,
    output wire signed [ACC_WIDTH-1:0] acc_out_1_1,
    output wire signed [ACC_WIDTH-1:0] acc_out_1_2,
    output wire signed [ACC_WIDTH-1:0] acc_out_1_3,
    output wire signed [ACC_WIDTH-1:0] acc_out_1_4,
    output wire signed [ACC_WIDTH-1:0] acc_out_1_5,
    output wire signed [ACC_WIDTH-1:0] acc_out_1_6,
    output wire signed [ACC_WIDTH-1:0] acc_out_1_7,

    output wire signed [ACC_WIDTH-1:0] acc_out_2_0,
    output wire signed [ACC_WIDTH-1:0] acc_out_2_1,
    output wire signed [ACC_WIDTH-1:0] acc_out_2_2,
    output wire signed [ACC_WIDTH-1:0] acc_out_2_3,
    output wire signed [ACC_WIDTH-1:0] acc_out_2_4,
    output wire signed [ACC_WIDTH-1:0] acc_out_2_5,
    output wire signed [ACC_WIDTH-1:0] acc_out_2_6,
    output wire signed [ACC_WIDTH-1:0] acc_out_2_7,

    output wire signed [ACC_WIDTH-1:0] acc_out_3_0,
    output wire signed [ACC_WIDTH-1:0] acc_out_3_1,
    output wire signed [ACC_WIDTH-1:0] acc_out_3_2,
    output wire signed [ACC_WIDTH-1:0] acc_out_3_3,
    output wire signed [ACC_WIDTH-1:0] acc_out_3_4,
    output wire signed [ACC_WIDTH-1:0] acc_out_3_5,
    output wire signed [ACC_WIDTH-1:0] acc_out_3_6,
    output wire signed [ACC_WIDTH-1:0] acc_out_3_7,

    output wire signed [ACC_WIDTH-1:0] acc_out_4_0,
    output wire signed [ACC_WIDTH-1:0] acc_out_4_1,
    output wire signed [ACC_WIDTH-1:0] acc_out_4_2,
    output wire signed [ACC_WIDTH-1:0] acc_out_4_3,
    output wire signed [ACC_WIDTH-1:0] acc_out_4_4,
    output wire signed [ACC_WIDTH-1:0] acc_out_4_5,
    output wire signed [ACC_WIDTH-1:0] acc_out_4_6,
    output wire signed [ACC_WIDTH-1:0] acc_out_4_7,

    output wire signed [ACC_WIDTH-1:0] acc_out_5_0,
    output wire signed [ACC_WIDTH-1:0] acc_out_5_1,
    output wire signed [ACC_WIDTH-1:0] acc_out_5_2,
    output wire signed [ACC_WIDTH-1:0] acc_out_5_3,
    output wire signed [ACC_WIDTH-1:0] acc_out_5_4,
    output wire signed [ACC_WIDTH-1:0] acc_out_5_5,
    output wire signed [ACC_WIDTH-1:0] acc_out_5_6,
    output wire signed [ACC_WIDTH-1:0] acc_out_5_7,

    output wire signed [ACC_WIDTH-1:0] acc_out_6_0,
    output wire signed [ACC_WIDTH-1:0] acc_out_6_1,
    output wire signed [ACC_WIDTH-1:0] acc_out_6_2,
    output wire signed [ACC_WIDTH-1:0] acc_out_6_3,
    output wire signed [ACC_WIDTH-1:0] acc_out_6_4,
    output wire signed [ACC_WIDTH-1:0] acc_out_6_5,
    output wire signed [ACC_WIDTH-1:0] acc_out_6_6,
    output wire signed [ACC_WIDTH-1:0] acc_out_6_7,

    output wire signed [ACC_WIDTH-1:0] acc_out_7_0,
    output wire signed [ACC_WIDTH-1:0] acc_out_7_1,
    output wire signed [ACC_WIDTH-1:0] acc_out_7_2,
    output wire signed [ACC_WIDTH-1:0] acc_out_7_3,
    output wire signed [ACC_WIDTH-1:0] acc_out_7_4,
    output wire signed [ACC_WIDTH-1:0] acc_out_7_5,
    output wire signed [ACC_WIDTH-1:0] acc_out_7_6,
    output wire signed [ACC_WIDTH-1:0] acc_out_7_7,

    output wire array_active
);

    // Internal wires - using arrays internally is OK
    wire signed [DATA_WIDTH-1:0] a_wire      [0:ARRAY_SIZE-1][  0:ARRAY_SIZE];
    wire                         a_valid_wire[0:ARRAY_SIZE-1][  0:ARRAY_SIZE];
    wire signed [DATA_WIDTH-1:0] b_wire      [  0:ARRAY_SIZE][0:ARRAY_SIZE-1];
    wire                         b_valid_wire[  0:ARRAY_SIZE][0:ARRAY_SIZE-1];
    wire signed [ ACC_WIDTH-1:0] acc_wire    [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire                         mac_active  [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    // Connect inputs to internal wires
    assign a_wire[0][0] = a_in_0;
    assign a_valid_wire[0][0] = a_valid_in_0;
    assign a_wire[1][0] = a_in_1;
    assign a_valid_wire[1][0] = a_valid_in_1;
    assign a_wire[2][0] = a_in_2;
    assign a_valid_wire[2][0] = a_valid_in_2;
    assign a_wire[3][0] = a_in_3;
    assign a_valid_wire[3][0] = a_valid_in_3;
    assign a_wire[4][0] = a_in_4;
    assign a_valid_wire[4][0] = a_valid_in_4;
    assign a_wire[5][0] = a_in_5;
    assign a_valid_wire[5][0] = a_valid_in_5;
    assign a_wire[6][0] = a_in_6;
    assign a_valid_wire[6][0] = a_valid_in_6;
    assign a_wire[7][0] = a_in_7;
    assign a_valid_wire[7][0] = a_valid_in_7;

    assign b_wire[0][0] = b_in_0;
    assign b_valid_wire[0][0] = b_valid_in_0;
    assign b_wire[0][1] = b_in_1;
    assign b_valid_wire[0][1] = b_valid_in_1;
    assign b_wire[0][2] = b_in_2;
    assign b_valid_wire[0][2] = b_valid_in_2;
    assign b_wire[0][3] = b_in_3;
    assign b_valid_wire[0][3] = b_valid_in_3;
    assign b_wire[0][4] = b_in_4;
    assign b_valid_wire[0][4] = b_valid_in_4;
    assign b_wire[0][5] = b_in_5;
    assign b_valid_wire[0][5] = b_valid_in_5;
    assign b_wire[0][6] = b_in_6;
    assign b_valid_wire[0][6] = b_valid_in_6;
    assign b_wire[0][7] = b_in_7;
    assign b_valid_wire[0][7] = b_valid_in_7;

    // Connect outputs from internal wires
    assign acc_out_0_0 = acc_wire[0][0];
    assign acc_out_0_1 = acc_wire[0][1];
    assign acc_out_0_2 = acc_wire[0][2];
    assign acc_out_0_3 = acc_wire[0][3];
    assign acc_out_0_4 = acc_wire[0][4];
    assign acc_out_0_5 = acc_wire[0][5];
    assign acc_out_0_6 = acc_wire[0][6];
    assign acc_out_0_7 = acc_wire[0][7];

    assign acc_out_1_0 = acc_wire[1][0];
    assign acc_out_1_1 = acc_wire[1][1];
    assign acc_out_1_2 = acc_wire[1][2];
    assign acc_out_1_3 = acc_wire[1][3];
    assign acc_out_1_4 = acc_wire[1][4];
    assign acc_out_1_5 = acc_wire[1][5];
    assign acc_out_1_6 = acc_wire[1][6];
    assign acc_out_1_7 = acc_wire[1][7];

    assign acc_out_2_0 = acc_wire[2][0];
    assign acc_out_2_1 = acc_wire[2][1];
    assign acc_out_2_2 = acc_wire[2][2];
    assign acc_out_2_3 = acc_wire[2][3];
    assign acc_out_2_4 = acc_wire[2][4];
    assign acc_out_2_5 = acc_wire[2][5];
    assign acc_out_2_6 = acc_wire[2][6];
    assign acc_out_2_7 = acc_wire[2][7];

    assign acc_out_3_0 = acc_wire[3][0];
    assign acc_out_3_1 = acc_wire[3][1];
    assign acc_out_3_2 = acc_wire[3][2];
    assign acc_out_3_3 = acc_wire[3][3];
    assign acc_out_3_4 = acc_wire[3][4];
    assign acc_out_3_5 = acc_wire[3][5];
    assign acc_out_3_6 = acc_wire[3][6];
    assign acc_out_3_7 = acc_wire[3][7];

    assign acc_out_4_0 = acc_wire[4][0];
    assign acc_out_4_1 = acc_wire[4][1];
    assign acc_out_4_2 = acc_wire[4][2];
    assign acc_out_4_3 = acc_wire[4][3];
    assign acc_out_4_4 = acc_wire[4][4];
    assign acc_out_4_5 = acc_wire[4][5];
    assign acc_out_4_6 = acc_wire[4][6];
    assign acc_out_4_7 = acc_wire[4][7];

    assign acc_out_5_0 = acc_wire[5][0];
    assign acc_out_5_1 = acc_wire[5][1];
    assign acc_out_5_2 = acc_wire[5][2];
    assign acc_out_5_3 = acc_wire[5][3];
    assign acc_out_5_4 = acc_wire[5][4];
    assign acc_out_5_5 = acc_wire[5][5];
    assign acc_out_5_6 = acc_wire[5][6];
    assign acc_out_5_7 = acc_wire[5][7];

    assign acc_out_6_0 = acc_wire[6][0];
    assign acc_out_6_1 = acc_wire[6][1];
    assign acc_out_6_2 = acc_wire[6][2];
    assign acc_out_6_3 = acc_wire[6][3];
    assign acc_out_6_4 = acc_wire[6][4];
    assign acc_out_6_5 = acc_wire[6][5];
    assign acc_out_6_6 = acc_wire[6][6];
    assign acc_out_6_7 = acc_wire[6][7];

    assign acc_out_7_0 = acc_wire[7][0];
    assign acc_out_7_1 = acc_wire[7][1];
    assign acc_out_7_2 = acc_wire[7][2];
    assign acc_out_7_3 = acc_wire[7][3];
    assign acc_out_7_4 = acc_wire[7][4];
    assign acc_out_7_5 = acc_wire[7][5];
    assign acc_out_7_6 = acc_wire[7][6];
    assign acc_out_7_7 = acc_wire[7][7];

    // Generate 64 PEs (8x8 grid)
    genvar row, col;
    generate
        for (row = 0; row < ARRAY_SIZE; row = row + 1) begin : pe_row
            for (col = 0; col < ARRAY_SIZE; col = col + 1) begin : pe_col

                processing_element #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACC_WIDTH (ACC_WIDTH)
                ) pe_inst (
                    .clk  (clk),
                    .rst_n(rst_n),

                    // 'A' path connections
                    .a_in(a_wire[row][col]),
                    .a_valid_in(a_valid_wire[row][col]),
                    .a_out(a_wire[row][col+1]),
                    .a_valid_out(a_valid_wire[row][col+1]),

                    // 'B' path connections
                    .b_in(b_wire[row][col]),
                    .b_valid_in(b_valid_wire[row][col]),
                    .b_out(b_wire[row+1][col]),
                    .b_valid_out(b_valid_wire[row+1][col]),

                    .clear_acc(clear_acc),
                    .acc_out  (acc_wire[row][col])
                );

                assign mac_active[row][col] = a_valid_wire[row][col] && b_valid_wire[row][col];

            end
        end
    endgenerate

    // Collapse all PE valid overlaps to a single activity indicator so top-level
    // logic knows when MACs are still in flight.
    integer r, c;
    reg array_active_r;
    always @(*) begin
        array_active_r = 1'b0;
        for (r = 0; r < ARRAY_SIZE; r = r + 1) begin
            for (c = 0; c < ARRAY_SIZE; c = c + 1) begin
                array_active_r = array_active_r | mac_active[r][c];
            end
        end
    end

    assign array_active = array_active_r;

endmodule
