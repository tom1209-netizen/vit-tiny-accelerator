`timescale 1ns / 1ps

module stats_fifo #(
    parameter SUM_WIDTH    = 18,
    parameter SUM_SQ_WIDTH = 24,
    parameter DEPTH        = 32
)(
    input  wire                   clk,
    input  wire                   aresetn,

    // Write Interface (From Accumulator)
    input  wire [SUM_WIDTH-1:0]    s_sum_int,
    input  wire [SUM_SQ_WIDTH-1:0] s_sum_sq_int,
    input  wire                    s_valid,
    output wire                    s_ready, // Full signal (optional check)

    // Read Interface (To Avg/Var Calc)
    output wire [SUM_WIDTH-1:0]    m_sum_int,
    output wire [SUM_SQ_WIDTH-1:0] m_sum_sq_int,
    output wire                    m_valid,
    input  wire                    m_ready  // Read Enable
);

    localparam TOTAL_WIDTH = SUM_WIDTH + SUM_SQ_WIDTH;
    
    // Memory
    reg [TOTAL_WIDTH-1:0] mem [0:DEPTH-1];
    reg [$clog2(DEPTH)-1:0] wr_ptr;
    reg [$clog2(DEPTH)-1:0] rd_ptr;
    reg [$clog2(DEPTH):0]   count;

    // Packing
    wire [TOTAL_WIDTH-1:0] write_data;
    assign write_data = {s_sum_sq_int, s_sum_int};

    // Unpacking
    assign {m_sum_sq_int, m_sum_int} = mem[rd_ptr];

    // Status
    assign s_ready = (count < DEPTH);
    assign m_valid = (count > 0);

    // Khởi tạo memory khi reset
    integer idx;
    always @(posedge clk) begin
        if (!aresetn) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            count  <= 0;
            // Reset tất cả các ô nhớ về 0
            for (idx = 0; idx < DEPTH; idx = idx + 1) begin
                mem[idx] <= 0;
            end
        end else begin
            // Write
            if (s_valid && s_ready) begin
                mem[wr_ptr] <= write_data;
                wr_ptr      <= (wr_ptr == DEPTH-1) ? 0 : wr_ptr + 1;
            end

            // Read
            if (m_valid && m_ready) begin
                rd_ptr      <= (rd_ptr == DEPTH-1) ? 0 : rd_ptr + 1;
            end

            // Count Update
            if ((s_valid && s_ready) && !(m_valid && m_ready))
                count <= count + 1;
            else if (!(s_valid && s_ready) && (m_valid && m_ready))
                count <= count - 1;
        end
    end

endmodule