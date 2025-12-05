`timescale 1ns / 1ps

module beat_fifo #(
    parameter DATA_WIDTH = 64,    // PARALLEL_N * 8 bits (e.g., 8 * 8 = 64)
    parameter DEPTH      = 512,   // Must be >= Max Sequence Length (N) of your ViT
    parameter RAM_STYLE  = "block" // "block" for BRAM, "distributed" for LUTRAM
)(
    input  wire                   clk,
    input  wire                   aresetn,

    // Write Interface (From Input Stream)
    input  wire [DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire                   s_axis_tlast,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,

    // Read Interface (To Final Norm Module)
    output wire [DATA_WIDTH-1:0]  m_axis_tdata,
    output wire                   m_axis_tlast,
    output wire                   m_axis_tvalid,
    input  wire                   m_axis_tready,

    // Status (Optional debug)
    output reg [$clog2(DEPTH):0]  fifo_count
);

    // =========================================================
    // PARAMETERS & SIGNALS
    // =========================================================
    localparam ADDR_WIDTH = $clog2(DEPTH);

    // Memory Array (Inferred as BRAM or LUTRAM based on parameter)
    (* ram_style = RAM_STYLE *)
    reg [DATA_WIDTH:0] mem [0:DEPTH-1]; // +1 bit for tlast storage

    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;
    
    wire full;
    wire empty;

    // =========================================================
    // POINTER LOGIC
    // =========================================================
    
    // Full/Empty Status
    // Note: This logic assumes DEPTH is a power of 2 for simple wrapping
    // If DEPTH is not power of 2, modulus operator is needed, but power of 2 is standard for FPGA.
    assign full  = (fifo_count == DEPTH);
    assign empty = (fifo_count == 0);

    // AXI Handshakes
    assign s_axis_tready = !full;
    assign m_axis_tvalid = !empty;

    // Combined Data + TLast for storage
    wire [DATA_WIDTH:0] write_packet;
    assign write_packet = {s_axis_tlast, s_axis_tdata};

    // Combined Data + TLast for readout
    wire [DATA_WIDTH:0] read_packet;
    
    // =========================================================
    // SYNCHRONOUS PROCESS
    // =========================================================
    always @(posedge clk) begin
        if (!aresetn) begin
            wr_ptr     <= 0;
            rd_ptr     <= 0;
            fifo_count <= 0;
        end else begin
            // --- WRITE OPERATION ---
            if (s_axis_tvalid && s_axis_tready) begin
                mem[wr_ptr] <= write_packet;
                wr_ptr      <= wr_ptr + 1; // Auto-wraps if ADDR_WIDTH matches depth
            end

            // --- READ OPERATION ---
            if (m_axis_tvalid && m_axis_tready) begin
                rd_ptr <= rd_ptr + 1;      // Auto-wraps
            end

            // --- COUNT UPDATE ---
            if ((s_axis_tvalid && s_axis_tready) && !(m_axis_tvalid && m_axis_tready)) begin
                fifo_count <= fifo_count + 1;
            end else if (!(s_axis_tvalid && s_axis_tready) && (m_axis_tvalid && m_axis_tready)) begin
                fifo_count <= fifo_count - 1;
            end
            // If both happen, count stays same
        end
    end

    // =========================================================
    // READ LOGIC (Distributed RAM / Low Latency Style)
    // =========================================================
    // Note: For pure Block RAM inference at high frequencies (>300MHz), 
    // an output register stage (latency 1 or 2) is often added.
    // For 125MHz on Arty Z7, this simple read-assignment works well 
    // and simplifies the "valid" logic control.
    
    assign read_packet = mem[rd_ptr];
    
    assign m_axis_tdata = read_packet[DATA_WIDTH-1:0];
    assign m_axis_tlast = read_packet[DATA_WIDTH];

endmodule