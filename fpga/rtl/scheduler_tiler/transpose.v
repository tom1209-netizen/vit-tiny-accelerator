module transpose #(
    parameter INPUT_WIDTH = 8
    parameter OUTPUT_WIDTH = 64
)(
    input wire clk,
    input wire rst_n,
    // Input from Requant Unit (Row-wise)
    input wire [INPUT_WIDTH-1:0] data_in,
    input wire                  valid_in,
    // Output to Buffer Bank (Packed 64-bit)
    output reg [OUTPUT_WIDTH-1:0] data_out,
    output reg                   valid_out
);

    reg [INPUT_WIDTH-1:0] bank0 [0:7][0:7];
    reg [INPUT_WIDTH-1:0] bank1 [0:7][0:7];

    reg       wr_bank_sel; // 0: Write to Bank0, 1: Write to Bank1
    reg       rd_bank_sel; // 0: Read from Bank0, 1: Read from Bank1
    reg [5:0] wr_counter;  // Count 0 to 63 for input
    reg [2:0] rd_col_idx;  // Count output columns 0 to 7
    reg       rd_active;   // Reading state

    wire [2:0] wr_row = wr_counter[5:3]; // Row index = counter / 8
    wire [2:0] wr_col = wr_counter[2:0]; // Column index = counter % 8

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_bank_sel <= 0;
            wr_counter  <= 0;
            rd_active   <= 0;
            rd_bank_sel <= 0;
        end else begin
            if (valid_in) begin
                if (wr_bank_sel == 0) begin
                    bank0[wr_row][wr_col] <= data_in;
                end else begin
                    bank1[wr_row][wr_col] <= data_in;
                end

                if (wr_counter == 63) begin
                    wr_counter <= 0;
                    wr_bank_sel <= ~wr_bank_sel;
                    rd_active <= 1;
                    rd_bank_sel <= wr_bank_sel;
                end else begin
                    wr_counter <= wr_counter + 1;
                end
            end
        end
    end

    wire [63:0] pack_b0 = {
        bank0[7][rd_col_idx],
        bank0[6][rd_col_idx],
        bank0[5][rd_col_idx],
        bank0[4][rd_col_idx],
        bank0[3][rd_col_idx],
        bank0[2][rd_col_idx],
        bank0[1][rd_col_idx],
        bank0[0][rd_col_idx]
    };

    wire [63:0] pack_b1 = {
        bank1[7][rd_col_idx],
        bank1[6][rd_col_idx],
        bank1[5][rd_col_idx],
        bank1[4][rd_col_idx],
        bank1[3][rd_col_idx],
        bank1[2][rd_col_idx],
        bank1[1][rd_col_idx],
        bank1[0][rd_col_idx]
    };

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 0;
            rd_col_idx <= 0;
            data_out <= 0;
        end else begin
            if (rd_active) begin
                valid_out <= 1;
                
                if (rd_bank_sel == 0) begin
                    data_out <= pack_b0;
                end else begin
                    data_out <= pack_b1;
                end

                if (rd_col_idx == 7) begin
                    rd_active  <= 0;
                    rd_col_idx <= 0;
                end else begin
                    rd_col_idx <= rd_col_idx + 1;
                end
            end else begin
                valid_out <= 0;
            end
        end
    end
endmodule