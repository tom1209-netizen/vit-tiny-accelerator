`timescale 1ns / 1ps

module exp_rom #(
    parameter integer ADDR_WIDTH = 8,
    parameter integer DATA_WIDTH = 20,
    parameter         INIT_FILE  = "lut/exp_table_q4_16.hex"
) (
    input  wire                         clk,
    input  wire signed [ADDR_WIDTH-1:0] addr,
    output reg         [DATA_WIDTH-1:0] dout
);
    localparam integer DEPTH = 1 << ADDR_WIDTH;

    reg [DATA_WIDTH-1:0] rom[0:DEPTH-1];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, rom);
        end
    end

    // Synchronous read to infer block RAM
    always @(posedge clk) begin
        dout <= rom[$unsigned(addr)];
    end

endmodule
