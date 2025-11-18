// Disclaimer: We use ReLU for lower computational cost; GELU offers no significant performance gain.

module relu_unit #(
    parameter integer AXIS_DATA_WIDTH = 64,
    parameter integer DATA_WIDTH      = 8,
    parameter interger BEAT_PER_PACKET = 8
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // AXI4-Stream input
    input  wire [AXIS_DATA_WIDTH-1:0]   s_axis_tdata,
    input  wire                         s_axis_tvalid,
    input  wire                         s_axis_tlast,
    output reg                          s_axis_tready,

    // AXI4-Stream output
    output reg  [AXIS_DATA_WIDTH-1:0]   m_axis_tdata,
    output reg                          m_axis_tvalid,
    output reg                          m_axis_tlast,
    input  wire                         m_axis_tready
);
    localparam VALUES_PER_BEAT = AXIS_DATA_WIDTH / DATA_WIDTH;

    // ReLU for INT8
    function signed [DATA_WIDTH-1:0] relu_lane(input signed [DATA_WIDTH-1:0] x);
        begin
            if (x[DATA_WIDTH-1] == 1'b1) begin
                relu_lane = {DATA_WIDTH{1'b0}};
            end else begin
                relu_lane = x;
            end
        end
    endfunction

    integer i;
    reg signed  [DATA_WIDTH-1:0] input_array      [0:VALUES_PER_BEAT-1];
    reg signed  [DATA_WIDTH-1:0] output_array     [0:VALUES_PER_BEAT-1];
    reg         [AXIS_DATA_WIDTH-1:0] output_stream;

    always @(posedge clk) begin
        for (i = 0; i < VALUES_PER_BEAT; i = i+1) begin
            input_array[i] = s_axis_tdata[i*DATA_WIDTH +: DATA_WIDTH];
            output_array[i] = relu_lane(input_array[i]);
            output_stream[i*DATA_WIDTH +: DATA_WIDTH] = output_array[i];

            // output_stream[i*DATA_WIDTH +: DATA_WIDTH] = relu_lane(s_axis_tdata[i*DATA_WIDTH +: DATA_WIDTH]);
        end
    end

    // AXI handshake
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axis_tready <= 1'b0;

            m_axis_tdata  <= {AXIS_DATA_WIDTH{1'b0}};
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
        end else begin
            s_axis_tready <= (!m_axis_tvalid || m_axis_tready);

            if (s_axis_tvalid && s_axis_tready) begin
                m_axis_tdata  <= output_stream;
                m_axis_tvalid <= 1'b1;
                m_axis_tlast  <= s_axis_tlast;
            end else if (m_axis_tvalid && m_axis_tready) begin
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
                // hold data for master
                m_axis_tdata  <= output_stream;
            end
        end
    end

endmodule