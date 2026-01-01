module input_buffer_controller #(
    parameter DATA_WIDTH      = 8,
    parameter ARRAY_SIZE      = 8,
    parameter AXIS_DATA_WIDTH = 64
) (
    input wire clk,
    input wire rst_n,

    // AXI-Stream input
    input  wire [AXIS_DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                       s_axis_tvalid,
    input  wire                       s_axis_tlast,
    output wire                       s_axis_tready,

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
    input wire enable,
    input wire stream_reset
);
    // One-beat holding register (skid) with safe simultaneous accept+present
    reg [AXIS_DATA_WIDTH-1:0] hold_data;
    reg hold_valid;

    reg stream_done;

    // Combinational control from current state
    wire hold_valid_effective = stream_reset ? 1'b0 : hold_valid;
    wire stream_done_effective = stream_reset ? 1'b0 : stream_done;
    wire present = enable && hold_valid_effective;  // will present this cycle
    wire ready_next = enable && (!hold_valid_effective || present) && !stream_done_effective;
    wire accept = s_axis_tvalid && s_axis_tready;  // handshake this cycle

    assign s_axis_tready = ready_next;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_valid  <= 1'b0;
            hold_data   <= {AXIS_DATA_WIDTH{1'b0}};
            stream_done <= 1'b0;

            data_out_0  <= {DATA_WIDTH{1'b0}};
            data_out_1  <= {DATA_WIDTH{1'b0}};
            data_out_2  <= {DATA_WIDTH{1'b0}};
            data_out_3  <= {DATA_WIDTH{1'b0}};
            data_out_4  <= {DATA_WIDTH{1'b0}};
            data_out_5  <= {DATA_WIDTH{1'b0}};
            data_out_6  <= {DATA_WIDTH{1'b0}};
            data_out_7  <= {DATA_WIDTH{1'b0}};
            data_valid  <= 1'b0;
        end else begin
            // Default
            data_valid <= 1'b0;

            // Present currently held beat
            if (present) begin
                data_out_0 <= hold_data[0*DATA_WIDTH+:DATA_WIDTH];
                data_out_1 <= hold_data[1*DATA_WIDTH+:DATA_WIDTH];
                data_out_2 <= hold_data[2*DATA_WIDTH+:DATA_WIDTH];
                data_out_3 <= hold_data[3*DATA_WIDTH+:DATA_WIDTH];
                data_out_4 <= hold_data[4*DATA_WIDTH+:DATA_WIDTH];
                data_out_5 <= hold_data[5*DATA_WIDTH+:DATA_WIDTH];
                data_out_6 <= hold_data[6*DATA_WIDTH+:DATA_WIDTH];
                data_out_7 <= hold_data[7*DATA_WIDTH+:DATA_WIDTH];
                data_valid <= 1'b1;
            end

            // Capture new beat on handshake 
            if (accept) begin
                hold_data <= s_axis_tdata;
            end

            // Update valid flag safely
            if (stream_reset) begin
                hold_valid <= accept;
            end else begin
                hold_valid <= (hold_valid && !present) || accept;
            end

            if (stream_reset) begin
                stream_done <= accept && s_axis_tlast;
            end else if (accept && s_axis_tlast) begin
                stream_done <= 1'b1;
            end
        end
    end

endmodule
