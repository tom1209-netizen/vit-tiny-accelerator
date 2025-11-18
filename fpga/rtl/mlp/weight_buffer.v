module weight_buffer #(
    parameter AXIS_DATA_WIDTH = 64   // Width of AXI4-Stream data
)(
    input wire clk,                    // Clock signal
    input wire rst_n,                  // Reset signal (active low)
    
    // AXI4-Stream input (for receiving weight data)
    input wire [AXIS_DATA_WIDTH-1:0] s_axis_tdata,   // Input data (weight)
    input wire s_axis_tvalid,                       // Input data valid
    input wire s_axis_tlast,                        // Input data last signal
    output wire s_axis_tready,                      // Input ready signal

    // AXI4-Stream output (for sending weight data)
    output reg [AXIS_DATA_WIDTH-1:0] m_axis_tdata,  // Output data (weight)
    output reg m_axis_tvalid,                       // Output data valid
    output reg m_axis_tlast,                        // Output data last signal
    input wire m_axis_tready,                       // Output ready signal

    // Control signal to enable processing
    input wire enable
);

    // Internal signal to store weight data
    reg [AXIS_DATA_WIDTH-1:0] weight_buffer;       // Weight buffer to hold data
    reg weight_valid;                              // Indicates whether weight data is valid

    // Handle receiving data from AXI Stream and storing it in weight buffer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_buffer <= {AXIS_DATA_WIDTH{1'b0}}; // Reset weight buffer
            weight_valid <= 1'b0;                     // Reset validity flag
        end else if (s_axis_tvalid && s_axis_tready) begin
            weight_buffer <= s_axis_tdata;            // Store incoming weight data
            weight_valid <= 1'b1;                     // Mark weight data as valid
        end
    end

    // Assign AXI4-Stream output signals based on stored weight data
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tdata <= {AXIS_DATA_WIDTH{1'b0}}; // Clear output data
            m_axis_tvalid <= 1'b0;                    // Clear valid flag
            m_axis_tlast <= 1'b0;                      // Clear last flag
        end else if (enable && weight_valid && m_axis_tready) begin
            m_axis_tdata <= weight_buffer;            // Send stored weight data
            m_axis_tvalid <= 1'b1;                    // Set valid flag to indicate data is valid
            m_axis_tlast <= s_axis_tlast;             // Propagate last signal from input
        end else begin
            m_axis_tvalid <= 1'b0;                    // Reset valid flag when not ready
        end
    end

    // Handle AXI4-Stream handshake
    assign s_axis_tready = !weight_valid || m_axis_tready;  // Only accept new data when the buffer is empty or the output is ready

endmodule
