`timescale 1ns / 1ps

module kernel_buffer #(
    parameter DATA_WIDTH   = 8,
    parameter LANES        = 8,
    parameter INPUT_WIDTH  = 64,   // LANES * DATA_WIDTH
    parameter MAX_CHANNELS = 128,
    parameter KERNEL_SIZE  = 9     // 3x3 kernel
) (
    input wire clk,
    input wire rst_n,

    // Control
    input  wire        load_enable,     // High during kernel loading phase
    input  wire [15:0] num_chan_beats,  // Number of channel groups (cfg_channels / LANES)
    output reg         load_done,       // Pulses when all kernels loaded

    // AXI-Stream kernel input
    input  wire [INPUT_WIDTH-1:0] axis_kernel_tdata,
    input  wire                   axis_kernel_tvalid,
    input  wire                   axis_kernel_tlast,
    output wire                   axis_kernel_tready,

    // Kernel lookup interface
    input wire [3:0] chan_group,  // Which channel group (0 to MAX_CHANNELS/LANES-1)
    output wire [KERNEL_SIZE*INPUT_WIDTH-1:0] kernel_pack  // 9 x 64-bit packed kernel
);

    localparam KERNEL_PACK_WIDTH = KERNEL_SIZE * INPUT_WIDTH;  // 576 bits
    localparam NUM_GROUPS = MAX_CHANNELS / LANES;  // 16 groups for 128 channels

    // Kernel Weight Storage
    (* ram_style = "block" *) reg [INPUT_WIDTH-1:0] kernel_mem_0[0:NUM_GROUPS-1];
    (* ram_style = "block" *) reg [INPUT_WIDTH-1:0] kernel_mem_1[0:NUM_GROUPS-1];
    (* ram_style = "block" *) reg [INPUT_WIDTH-1:0] kernel_mem_2[0:NUM_GROUPS-1];
    (* ram_style = "block" *) reg [INPUT_WIDTH-1:0] kernel_mem_3[0:NUM_GROUPS-1];
    (* ram_style = "block" *) reg [INPUT_WIDTH-1:0] kernel_mem_4[0:NUM_GROUPS-1];
    (* ram_style = "block" *) reg [INPUT_WIDTH-1:0] kernel_mem_5[0:NUM_GROUPS-1];
    (* ram_style = "block" *) reg [INPUT_WIDTH-1:0] kernel_mem_6[0:NUM_GROUPS-1];
    (* ram_style = "block" *) reg [INPUT_WIDTH-1:0] kernel_mem_7[0:NUM_GROUPS-1];
    (* ram_style = "block" *) reg [INPUT_WIDTH-1:0] kernel_mem_8[0:NUM_GROUPS-1];

    // Initialize to zero
    integer init_i;
    initial begin
        for (init_i = 0; init_i < NUM_GROUPS; init_i = init_i + 1) begin
            kernel_mem_0[init_i] = {INPUT_WIDTH{1'b0}};
            kernel_mem_1[init_i] = {INPUT_WIDTH{1'b0}};
            kernel_mem_2[init_i] = {INPUT_WIDTH{1'b0}};
            kernel_mem_3[init_i] = {INPUT_WIDTH{1'b0}};
            kernel_mem_4[init_i] = {INPUT_WIDTH{1'b0}};
            kernel_mem_5[init_i] = {INPUT_WIDTH{1'b0}};
            kernel_mem_6[init_i] = {INPUT_WIDTH{1'b0}};
            kernel_mem_7[init_i] = {INPUT_WIDTH{1'b0}};
            kernel_mem_8[init_i] = {INPUT_WIDTH{1'b0}};
        end
    end

    // Loading State Machine
    reg  [           15:0] load_cnt;  // Total beats received
    reg  [            3:0] coeff_idx;  // Coefficient index within group (0-8)
    reg  [            3:0] chan_group_wr;  // Current channel group being written
    reg  [           15:0] total_kernel_beats;  // = num_chan_beats * 9

    // Pre-computed flag to avoid comparison in critical path
    reg                    load_almost_done;

    // Pipeline registers for timing closure
    reg                    wr_en_d;
    reg  [            3:0] coeff_idx_d;
    reg  [            3:0] chan_group_d;
    reg  [INPUT_WIDTH-1:0] data_d;

    wire                   handshake = axis_kernel_tvalid && axis_kernel_tready;
    reg                    kernel_stream_done;

    assign axis_kernel_tready = load_enable && !kernel_stream_done;

    // Stage 1: Address and counter computation
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_cnt           <= 16'd0;
            coeff_idx          <= 4'd0;
            chan_group_wr      <= 4'd0;
            total_kernel_beats <= 16'd0;
            load_almost_done   <= 1'b0;
            load_done          <= 1'b0;
            kernel_stream_done <= 1'b0;
        end else if (!load_enable) begin
            // Reset counters when not loading (but don't compute total_kernel_beats here
            // as num_chan_beats may not be stable yet)
            load_cnt           <= 16'd0;
            coeff_idx          <= 4'd0;
            chan_group_wr      <= 4'd0;
            load_almost_done   <= 1'b0;
            load_done          <= 1'b0;
            kernel_stream_done <= 1'b0;
        end else if (handshake) begin
            // Capture total_kernel_beats on first handshake (num_chan_beats is now stable)
            if (load_cnt == 0) begin
                total_kernel_beats <= num_chan_beats * KERNEL_SIZE;
            end

            load_cnt <= load_cnt + 1;

            // Pre-compute "almost done" for next cycle
            // Use captured or freshly computed value
            if (load_cnt == 0) begin
                // First beat - compare against freshly computed value
                load_almost_done <= (16'd0 == (num_chan_beats * KERNEL_SIZE) - 2);
            end else begin
                load_almost_done <= (load_cnt == total_kernel_beats - 2);
            end

            // Signal done on last beat
            load_done <= load_almost_done;
            if (axis_kernel_tlast) begin
                kernel_stream_done <= 1'b1;
            end

            // Update coefficient and group counters
            if (coeff_idx == KERNEL_SIZE - 1) begin
                coeff_idx     <= 4'd0;
                chan_group_wr <= chan_group_wr + 1;
            end else begin
                coeff_idx <= coeff_idx + 1;
            end
        end else begin
            load_done <= 1'b0;
        end
    end

    // Stage 2: Register write data
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_en_d      <= 1'b0;
            coeff_idx_d  <= 4'd0;
            chan_group_d <= 4'd0;
            data_d       <= {INPUT_WIDTH{1'b0}};
        end else begin
            wr_en_d      <= load_enable && handshake;
            coeff_idx_d  <= coeff_idx;
            chan_group_d <= chan_group_wr;
            data_d       <= axis_kernel_tdata;
        end
    end

    // Stage 3: Write to kernel memory
    always @(posedge clk) begin
        if (wr_en_d) begin
            case (coeff_idx_d)
                4'd0: kernel_mem_0[chan_group_d] <= data_d;
                4'd1: kernel_mem_1[chan_group_d] <= data_d;
                4'd2: kernel_mem_2[chan_group_d] <= data_d;
                4'd3: kernel_mem_3[chan_group_d] <= data_d;
                4'd4: kernel_mem_4[chan_group_d] <= data_d;
                4'd5: kernel_mem_5[chan_group_d] <= data_d;
                4'd6: kernel_mem_6[chan_group_d] <= data_d;
                4'd7: kernel_mem_7[chan_group_d] <= data_d;
                4'd8: kernel_mem_8[chan_group_d] <= data_d;
                default: ;
            endcase
        end
    end

    // Kernel Lookup - registered read (1-cycle)
    reg [INPUT_WIDTH-1:0] kernel_r0;
    reg [INPUT_WIDTH-1:0] kernel_r1;
    reg [INPUT_WIDTH-1:0] kernel_r2;
    reg [INPUT_WIDTH-1:0] kernel_r3;
    reg [INPUT_WIDTH-1:0] kernel_r4;
    reg [INPUT_WIDTH-1:0] kernel_r5;
    reg [INPUT_WIDTH-1:0] kernel_r6;
    reg [INPUT_WIDTH-1:0] kernel_r7;
    reg [INPUT_WIDTH-1:0] kernel_r8;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            kernel_r0 <= {INPUT_WIDTH{1'b0}};
            kernel_r1 <= {INPUT_WIDTH{1'b0}};
            kernel_r2 <= {INPUT_WIDTH{1'b0}};
            kernel_r3 <= {INPUT_WIDTH{1'b0}};
            kernel_r4 <= {INPUT_WIDTH{1'b0}};
            kernel_r5 <= {INPUT_WIDTH{1'b0}};
            kernel_r6 <= {INPUT_WIDTH{1'b0}};
            kernel_r7 <= {INPUT_WIDTH{1'b0}};
            kernel_r8 <= {INPUT_WIDTH{1'b0}};
        end else begin
            kernel_r0 <= kernel_mem_0[chan_group];
            kernel_r1 <= kernel_mem_1[chan_group];
            kernel_r2 <= kernel_mem_2[chan_group];
            kernel_r3 <= kernel_mem_3[chan_group];
            kernel_r4 <= kernel_mem_4[chan_group];
            kernel_r5 <= kernel_mem_5[chan_group];
            kernel_r6 <= kernel_mem_6[chan_group];
            kernel_r7 <= kernel_mem_7[chan_group];
            kernel_r8 <= kernel_mem_8[chan_group];
        end
    end

    assign kernel_pack = {
        kernel_r8,
        kernel_r7,
        kernel_r6,
        kernel_r5,
        kernel_r4,
        kernel_r3,
        kernel_r2,
        kernel_r1,
        kernel_r0
    };

endmodule
