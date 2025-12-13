`timescale 1ns / 1ps

module softmax_fifo #(
    parameter integer WIDTH = 160,
    parameter integer DEPTH = 256
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             clr,
    input  wire             wr_en,
    input  wire [WIDTH-1:0] din,
    input  wire             rd_en,
    output wire [WIDTH-1:0] dout,
    output wire             full,
    output wire             empty
);
    localparam integer PTR_W = $clog2(DEPTH);

    reg [WIDTH-1:0] mem[0:DEPTH-1];
    reg [PTR_W:0] count;
    reg [PTR_W-1:0] wptr;
    reg [PTR_W-1:0] rptr;

    // Helper signals for readability
    wire valid_write = wr_en && !full;
    wire valid_read = rd_en && !empty;

    assign full  = (count == DEPTH);
    assign empty = (count == 0);
    assign dout  = mem[rptr];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= {(PTR_W + 1) {1'b0}};
            wptr  <= {PTR_W{1'b0}};
            rptr  <= {PTR_W{1'b0}};
        end else if (clr) begin
            count <= {(PTR_W + 1) {1'b0}};
            wptr  <= {PTR_W{1'b0}};
            rptr  <= {PTR_W{1'b0}};
        end else begin
            // write path
            if (valid_write) begin
                mem[wptr] <= din;
                wptr      <= wptr + 1'b1;
            end

            // read path
            if (valid_read) begin
                rptr <= rptr + 1'b1;
            end

            // count update
            if (valid_write && !valid_read) count <= count + 1'b1;
            else if (!valid_write && valid_read) count <= count - 1'b1;
        end
    end
endmodule
