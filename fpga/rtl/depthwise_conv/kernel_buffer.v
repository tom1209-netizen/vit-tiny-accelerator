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
    output wire                   axis_kernel_tready,

    // Kernel lookup interface
    input wire [3:0] chan_group,  // Which channel group (0 to MAX_CHANNELS/LANES-1)
    output wire [KERNEL_SIZE*INPUT_WIDTH-1:0] kernel_pack  // 9 x 64-bit packed kernel
);

    localparam KERNEL_PACK_WIDTH = KERNEL_SIZE * INPUT_WIDTH;  // 576 bits
    localparam NUM_GROUPS = MAX_CHANNELS / LANES;  // 16 groups for 128 channels

    // =========================================================================
    // Kernel Weight Storage - packed registers
    // =========================================================================
    (* ram_style = "registers" *)
    reg [KERNEL_PACK_WIDTH-1:0] kernel_mem[0:NUM_GROUPS-1];

    // Initialize to zero
    integer init_i;
    initial begin
        for (init_i = 0; init_i < NUM_GROUPS; init_i = init_i + 1)
        kernel_mem[init_i] = {KERNEL_PACK_WIDTH{1'b0}};
    end

    // =========================================================================
    // Loading State Machine
    // =========================================================================
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

    assign axis_kernel_tready = load_enable;

    // Stage 1: Address and counter computation
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_cnt           <= 16'd0;
            coeff_idx          <= 4'd0;
            chan_group_wr      <= 4'd0;
            total_kernel_beats <= 16'd0;
            load_almost_done   <= 1'b0;
            load_done          <= 1'b0;
        end else if (!load_enable) begin
            // Reset counters when not loading (but don't compute total_kernel_beats here
            // as num_chan_beats may not be stable yet)
            load_cnt         <= 16'd0;
            coeff_idx        <= 4'd0;
            chan_group_wr    <= 4'd0;
            load_almost_done <= 1'b0;
            load_done        <= 1'b0;
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
            kernel_mem[chan_group_d][coeff_idx_d*INPUT_WIDTH+:INPUT_WIDTH] <= data_d;
        end
    end

    // =========================================================================
    // Kernel Lookup - combinational read
    // =========================================================================
    assign kernel_pack = kernel_mem[chan_group];

endmodule
