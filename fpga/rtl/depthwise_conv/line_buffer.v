`timescale 1ns / 1ps

module line_buffer #(
    parameter DATA_WIDTH   = 8,
    parameter LANES        = 8,
    parameter INPUT_WIDTH  = 64,  // LANES * DATA_WIDTH
    parameter MAX_WIDTH    = 28,  // Maximum image width
    parameter MAX_CHANNELS = 128  // Maximum channels
) (
    input wire clk,
    input wire rst_n,

    // Configuration
    input wire [15:0] num_cols,       // Image width
    input wire [15:0] num_chan_beats, // Channel groups (channels / LANES)

    // Write interface (from input stream)
    input wire                   wr_en,
    input wire [            1:0] wr_row_sel,  // Which line buffer (0, 1, 2) based on row % 3
    input wire [           15:0] wr_addr,     // Beat address within row
    input wire [INPUT_WIDTH-1:0] wr_data,

    // Read interface (for window extraction)
    input  wire [           15:0] rd_addr,
    output wire [INPUT_WIDTH-1:0] rd_data_0,  // Line buffer 0 data
    output wire [INPUT_WIDTH-1:0] rd_data_1,  // Line buffer 1 data
    output wire [INPUT_WIDTH-1:0] rd_data_2   // Line buffer 2 data
);

    localparam MAX_BEATS_ROW = MAX_WIDTH * (MAX_CHANNELS / LANES);  // 28 * 16 = 448

    // =========================================================================
    // Line Buffers - 3 BRAMs
    // =========================================================================
    (* ram_style = "block" *) reg [INPUT_WIDTH-1:0] line_buf_0[0:MAX_BEATS_ROW-1];
    (* ram_style = "block" *) reg [INPUT_WIDTH-1:0] line_buf_1[0:MAX_BEATS_ROW-1];
    (* ram_style = "block" *) reg [INPUT_WIDTH-1:0] line_buf_2[0:MAX_BEATS_ROW-1];

    // Initialize to zero
    integer init_i;
    initial begin
        for (init_i = 0; init_i < MAX_BEATS_ROW; init_i = init_i + 1) begin
            line_buf_0[init_i] = {INPUT_WIDTH{1'b0}};
            line_buf_1[init_i] = {INPUT_WIDTH{1'b0}};
            line_buf_2[init_i] = {INPUT_WIDTH{1'b0}};
        end
    end

    // =========================================================================
    // Read Data Registers (1-cycle BRAM latency)
    // =========================================================================
    reg [INPUT_WIDTH-1:0] rd_data_0_r;
    reg [INPUT_WIDTH-1:0] rd_data_1_r;
    reg [INPUT_WIDTH-1:0] rd_data_2_r;

    // =========================================================================
    // Write Logic - select buffer based on row % 3
    // =========================================================================
    always @(posedge clk) begin
        if (wr_en) begin
            case (wr_row_sel)
                2'd0: line_buf_0[wr_addr] <= wr_data;
                2'd1: line_buf_1[wr_addr] <= wr_data;
                2'd2: line_buf_2[wr_addr] <= wr_data;
                default: ;  // Should not happen
            endcase
        end
    end

    // =========================================================================
    // Read Logic - synchronous read from all 3 buffers
    // =========================================================================
    always @(posedge clk) begin
        rd_data_0_r <= line_buf_0[rd_addr];
        rd_data_1_r <= line_buf_1[rd_addr];
        rd_data_2_r <= line_buf_2[rd_addr];
    end

    assign rd_data_0 = rd_data_0_r;
    assign rd_data_1 = rd_data_1_r;
    assign rd_data_2 = rd_data_2_r;

endmodule
