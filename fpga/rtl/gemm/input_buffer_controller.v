module input_buffer_controller #(
    parameter DATA_WIDTH = 8,
    parameter ARRAY_SIZE = 8,
    parameter AXIS_DATA_WIDTH = 64
) (
    input wire clk,
    input wire rst_n,

    // AXI-Stream input
    input  wire [AXIS_DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                       s_axis_tvalid,
    input  wire                       s_axis_tlast,
    output reg                        s_axis_tready,

    // Flattened output to systolic array (8 signals)
    output reg signed [DATA_WIDTH-1:0] data_out_0,
    output reg signed [DATA_WIDTH-1:0] data_out_1,
    output reg signed [DATA_WIDTH-1:0] data_out_2,
    output reg signed [DATA_WIDTH-1:0] data_out_3,
    output reg signed [DATA_WIDTH-1:0] data_out_4,
    output reg signed [DATA_WIDTH-1:0] data_out_5,
    output reg signed [DATA_WIDTH-1:0] data_out_6,
    output reg signed [DATA_WIDTH-1:0] data_out_7,
    output reg                         data_valid,

    // Control
    input wire enable
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out_0 <= {DATA_WIDTH{1'b0}};
            data_out_1 <= {DATA_WIDTH{1'b0}};
            data_out_2 <= {DATA_WIDTH{1'b0}};
            data_out_3 <= {DATA_WIDTH{1'b0}};
            data_out_4 <= {DATA_WIDTH{1'b0}};
            data_out_5 <= {DATA_WIDTH{1'b0}};
            data_out_6 <= {DATA_WIDTH{1'b0}};
            data_out_7 <= {DATA_WIDTH{1'b0}};
            data_valid <= 1'b0;
            s_axis_tready <= 1'b0;
        end else begin
            if (enable) begin
                s_axis_tready <= 1'b1;

                if (s_axis_tvalid && s_axis_tready) begin
                    // Unpack 8 INT8 values from 64-bit stream
                    data_out_0 <= s_axis_tdata[0*DATA_WIDTH+:DATA_WIDTH];
                    data_out_1 <= s_axis_tdata[1*DATA_WIDTH+:DATA_WIDTH];
                    data_out_2 <= s_axis_tdata[2*DATA_WIDTH+:DATA_WIDTH];
                    data_out_3 <= s_axis_tdata[3*DATA_WIDTH+:DATA_WIDTH];
                    data_out_4 <= s_axis_tdata[4*DATA_WIDTH+:DATA_WIDTH];
                    data_out_5 <= s_axis_tdata[5*DATA_WIDTH+:DATA_WIDTH];
                    data_out_6 <= s_axis_tdata[6*DATA_WIDTH+:DATA_WIDTH];
                    data_out_7 <= s_axis_tdata[7*DATA_WIDTH+:DATA_WIDTH];
                    data_valid <= 1'b1;
                end else begin
                    data_valid <= 1'b0;
                end
            end else begin
                s_axis_tready <= 1'b0;
                data_valid <= 1'b0;
            end
        end
    end

endmodule
