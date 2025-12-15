`timescale 1ns / 1ps

module mac_unit #(
    parameter DATA_WIDTH  = 8,
    parameter LANES       = 8,
    parameter ACC_WIDTH   = 32,
    parameter KERNEL_SIZE = 9
) (
    input wire clk,
    input wire rst_n,

    // Input interface - packed arrays for portability
    input wire data_valid,  // Window/kernel data ready
    input wire data_last,  // Last beat flag
    input wire [KERNEL_SIZE*LANES*DATA_WIDTH-1:0]  win_pack,   // 9 positions x 8 lanes x 8 bits = 576 bits
    input wire [KERNEL_SIZE*LANES*DATA_WIDTH-1:0] ker_pack,  // Same packing

    // Status
    output reg busy,  // MAC is processing

    // Output interface - packed for portability
    output reg                       result_valid,
    output reg                       result_last,
    output reg [LANES*ACC_WIDTH-1:0] result_pack    // 8 lanes x 32 bits = 256 bits
);

    // =========================================================================
    // MAC FSM States
    // =========================================================================
    localparam MAC_IDLE = 2'd0;
    localparam MAC_MULT = 2'd1;  // Multiply and accumulate positions 0-8
    localparam MAC_DONE = 2'd2;  // Output final result

    reg        [                             1:0] mac_state;
    reg        [                             3:0] mac_cnt;  // Position counter 0-8
    reg                                           last_saved;  // Saved last flag

    // =========================================================================
    // Captured Input Data - packed storage
    // =========================================================================
    reg        [KERNEL_SIZE*LANES*DATA_WIDTH-1:0] win_cap;
    reg        [KERNEL_SIZE*LANES*DATA_WIDTH-1:0] ker_cap;

    // Current operands for multiply
    reg signed [                  DATA_WIDTH-1:0] cur_win                          [0:LANES-1];
    reg signed [                  DATA_WIDTH-1:0] cur_ker                          [0:LANES-1];

    // Product register (DSP inference)
    (* use_dsp = "yes" *)reg signed [                2*DATA_WIDTH-1:0] prod                             [0:LANES-1];

    // Accumulator
    reg signed [                   ACC_WIDTH-1:0] mac_acc                          [0:LANES-1];

    // Pipeline flag
    reg                                           prod_done;

    // =========================================================================
    // Helper: Extract signed byte from packed data
    // Position p (0-8), lane l (0-7)
    // =========================================================================
    function signed [DATA_WIDTH-1:0] extract_byte;
        input [KERNEL_SIZE*LANES*DATA_WIDTH-1:0] pack;
        input [3:0] pos;
        input [3:0] lane;
        begin
            extract_byte = $signed(pack[pos*LANES*DATA_WIDTH+lane*DATA_WIDTH+:DATA_WIDTH]);
        end
    endfunction

    // =========================================================================
    // Capture input data on data_valid
    // =========================================================================
    always @(posedge clk) begin
        if (data_valid && !busy) begin
            win_cap <= win_pack;
            ker_cap <= ker_pack;
        end
    end

    // =========================================================================
    // MAC State Machine
    // =========================================================================
    integer mi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_state  <= MAC_IDLE;
            mac_cnt    <= 4'd0;
            busy       <= 1'b0;
            last_saved <= 1'b0;
            prod_done  <= 1'b0;
            for (mi = 0; mi < LANES; mi = mi + 1) begin
                cur_win[mi] <= {DATA_WIDTH{1'b0}};
                cur_ker[mi] <= {DATA_WIDTH{1'b0}};
                prod[mi]    <= {(2*DATA_WIDTH){1'b0}};
                mac_acc[mi] <= {ACC_WIDTH{1'b0}};
            end
        end else begin
            prod_done <= 1'b0;

            case (mac_state)
                MAC_IDLE: begin
                    if (data_valid) begin
                        mac_state  <= MAC_MULT;
                        mac_cnt    <= 4'd0;
                        busy       <= 1'b1;
                        last_saved <= data_last;
                        // Clear accumulator
                        for (mi = 0; mi < LANES; mi = mi + 1) begin
                            mac_acc[mi] <= {ACC_WIDTH{1'b0}};
                        end
                        // Load first position from input data (pos=0)
                        for (mi = 0; mi < LANES; mi = mi + 1) begin
                            cur_win[mi] <= extract_byte(win_pack, 4'd0, mi[3:0]);
                            cur_ker[mi] <= extract_byte(ker_pack, 4'd0, mi[3:0]);
                        end
                    end
                end

                MAC_MULT: begin
                    // Multiply current position
                    for (mi = 0; mi < LANES; mi = mi + 1) begin
                        prod[mi] <= cur_win[mi] * cur_ker[mi];
                    end

                    // Load next position or transition to DONE
                    if (mac_cnt < 4'd8) begin
                        mac_cnt <= mac_cnt + 1;
                        // Load next position (mac_cnt+1)
                        for (mi = 0; mi < LANES; mi = mi + 1) begin
                            cur_win[mi] <= extract_byte(win_cap, mac_cnt + 4'd1, mi[3:0]);
                            cur_ker[mi] <= extract_byte(ker_cap, mac_cnt + 4'd1, mi[3:0]);
                        end
                    end else begin
                        mac_state <= MAC_DONE;
                    end
                end

                MAC_DONE: begin
                    // Accumulate the last product
                    for (mi = 0; mi < LANES; mi = mi + 1) begin
                        mac_acc[mi] <= mac_acc[mi] + {{(ACC_WIDTH-2*DATA_WIDTH){prod[mi][2*DATA_WIDTH-1]}}, prod[mi]};
                    end
                    prod_done <= 1'b1;
                    busy      <= 1'b0;
                    mac_state <= MAC_IDLE;
                end
            endcase

            // Accumulate products (one cycle after multiply, for positions 1-8)
            if (mac_state == MAC_MULT && mac_cnt > 4'd0) begin
                for (mi = 0; mi < LANES; mi = mi + 1) begin
                    mac_acc[mi] <= mac_acc[mi] + {{(ACC_WIDTH-2*DATA_WIDTH){prod[mi][2*DATA_WIDTH-1]}}, prod[mi]};
                end
            end
        end
    end

    // =========================================================================
    // Output Result - pack into output bus
    // =========================================================================
    integer ri;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_valid <= 1'b0;
            result_last  <= 1'b0;
            result_pack  <= {(LANES * ACC_WIDTH) {1'b0}};
        end else if (prod_done) begin
            result_valid <= 1'b1;
            result_last  <= last_saved;
            for (ri = 0; ri < LANES; ri = ri + 1) begin
                result_pack[ri*ACC_WIDTH+:ACC_WIDTH] <= mac_acc[ri];
            end
        end else begin
            result_valid <= 1'b0;
            result_last  <= 1'b0;
        end
    end

endmodule
