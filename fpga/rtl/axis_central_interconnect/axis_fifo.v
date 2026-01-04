/*
 * AXI4-Stream FIFO
 * simple synchronous FIFO with tkeep/tlast support
 */
module axis_fifo #
(
    parameter DATA_WIDTH = 64,
    parameter DEPTH = 64  // Depth of buffer (e.g. 64 beats)
)
(
    input  wire                   clk,
    input  wire                   rst,

    // Slave Port (Input)
    input  wire [DATA_WIDTH-1:0]   s_axis_tdata,
    input  wire                    s_axis_tvalid,
    output wire                    s_axis_tready,
    input  wire                    s_axis_tlast,
    input  wire [DATA_WIDTH/8-1:0] s_axis_tkeep,

    // Master Port (Output)
    output wire [DATA_WIDTH-1:0]   m_axis_tdata,
    output wire                    m_axis_tvalid,
    input  wire                    m_axis_tready,
    output wire                    m_axis_tlast,
    output wire [DATA_WIDTH/8-1:0] m_axis_tkeep
);

    localparam KEEP_WIDTH = DATA_WIDTH/8;
    // Total width to store: Data + Keep + Last
    localparam FIFO_WIDTH = DATA_WIDTH + KEEP_WIDTH + 1;
    localparam PTR_WIDTH  = $clog2(DEPTH);

    reg [FIFO_WIDTH-1:0] mem [0:DEPTH-1];
    reg [PTR_WIDTH-1:0]  wr_ptr = 0;
    reg [PTR_WIDTH-1:0]  rd_ptr = 0;
    reg [$clog2(DEPTH+1)-1:0] count = 0;

    // Pack/Unpack signals
    wire [FIFO_WIDTH-1:0] s_packed = {s_axis_tlast, s_axis_tkeep, s_axis_tdata};
    wire [FIFO_WIDTH-1:0] m_packed;

    assign {m_axis_tlast, m_axis_tkeep, m_axis_tdata} = m_packed;

    // Full/Empty flags
    wire full  = (count == DEPTH);
    wire empty = (count == 0);

    // Ready logic
    assign s_axis_tready = !full;
    assign m_axis_tvalid = !empty;

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            count  <= 0;
        end else begin
            // Write
            if (s_axis_tvalid && s_axis_tready) begin
                mem[wr_ptr] <= s_packed;
                wr_ptr <= (wr_ptr == DEPTH-1) ? 0 : wr_ptr + 1;
            end

            // Read
            if (m_axis_tvalid && m_axis_tready) begin
                rd_ptr <= (rd_ptr == DEPTH-1) ? 0 : rd_ptr + 1;
            end

            // Count Update
            if ((s_axis_tvalid && s_axis_tready) && !(m_axis_tvalid && m_axis_tready))
                count <= count + 1;
            else if (!(s_axis_tvalid && s_axis_tready) && (m_axis_tvalid && m_axis_tready))
                count <= count - 1;
        end
    end
    
    // Asynchronous Read (First-Word-Fall-Through effect for simplicity, 
    // real HW might use synchronous read for timing, but this works for behavioral/RTL)
    assign m_packed = mem[rd_ptr];

endmodule