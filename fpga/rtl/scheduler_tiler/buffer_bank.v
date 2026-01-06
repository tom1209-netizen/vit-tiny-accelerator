module buffer_bank #(
    parameter DATA_WIDTH = 64,  // 8 pixel x 8 bit (Packed)
    parameter ADDR_WIDTH = 16,  // 2^16 = 65,536 words (8 bytes/word)
    parameter RAM_DEPTH = 65536 // Total 512KB
)(
    input wire clk,
    // Port A: Write only (For DMA Shim or Requant Unit)
    input wire wr_en,
    input wire [ADDR_WIDTH-1:0] wr_addr,
    input wire [DATA_WIDTH-1:0] wr_data,
    // Port B: Read only (For GEMM, Conv, or DMA S2MM)
    input wire rd_en,
    input wire [ADDR_WIDTH-1:0] rd_addr,
    output reg [DATA_WIDTH-1:0] rd_data
);

    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] ram [0:RAM_DEPTH-1];

    always @(posedge clk) begin
        if (wr_en) begin
            ram[wr_addr] <= wr_data;
        end

        if (rd_en) begin
            rd_data <= ram[rd_addr];
        end
    end
    
    integer i;
    initial begin
        for (i = 0; i < RAM_DEPTH; i = i + 1) begin
            ram[i] = {DATA_WIDTH{1'b0}};
        end
    end
endmodule