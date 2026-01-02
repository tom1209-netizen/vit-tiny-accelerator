`timescale 1ns / 1ps

module srl_delay_tap #(
    parameter WIDTH = 64
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             en,
    input  wire [WIDTH-1:0] din,
    input  wire [      4:0] tap,
    output wire [WIDTH-1:0] dout
);
    wire [WIDTH-1:0] srl_q;

    genvar ui;
    generate
        for (ui = 0; ui < WIDTH; ui = ui + 1) begin : gen_srl_sim
            SRLC32E #(
                .INIT(32'h0)
            ) u_srl (
                .Q  (srl_q[ui]),
                .Q31(),
                .A  (tap),
                .CE (en),
                .CLK(clk),
                .D  (din[ui])
            );
        end
    endgenerate

    assign dout = srl_q;

endmodule
