`timescale 1ns / 1ps

module debug_top (
    input wire clk
);

    // Parameters
    parameter DATA_WIDTH = 8;
    parameter LANES = 8;
    parameter INPUT_WIDTH = 64;
    parameter OUTPUT_WIDTH = 64;
    parameter MAX_WIDTH = 28;
    parameter MAX_CHANNELS = 128;
    parameter ACC_WIDTH = 32;

    // Signals
    wire [ INPUT_WIDTH-1:0] axis_kernel_in_tdata;
    wire                    axis_kernel_in_tvalid;
    wire                    axis_kernel_in_tlast;
    wire                    axis_kernel_in_tready;

    wire [ INPUT_WIDTH-1:0] axis_data_in_tdata;
    wire                    axis_data_in_tvalid;
    wire                    axis_data_in_tlast;
    wire                    axis_data_in_tready;

    wire [OUTPUT_WIDTH-1:0] axis_data_out_tdata;
    wire                    axis_data_out_tvalid;
    wire                    axis_data_out_tlast;
    wire                    axis_data_out_tready;

    wire                    start;
    wire [            15:0] cfg_height;
    wire [            15:0] cfg_width;
    wire [            15:0] cfg_channels;
    wire                    done;

    // VIO Signals
    wire                    vio_start;
    wire                    vio_reset_n;
    wire [             7:0] vio_height;
    wire [             7:0] vio_width;
    wire [             7:0] vio_channels;

    //-------------------------------------------------------------------------
    // 1. VIO (Virtual Input/Output)
    //-------------------------------------------------------------------------
    // Configure in IP Catalog:
    // - Output Probe Count: 5
    //   - PROBE_OUT0: Width 1 (reset_n) - Initial 0x1
    //   - PROBE_OUT1: Width 1 (start_trigger)
    //   - PROBE_OUT2: Width 8 (height) - Initial 0x04
    //   - PROBE_OUT3: Width 8 (width) - Initial 0x04
    //   - PROBE_OUT4: Width 8 (channels) - Initial 0x08
    vio_0 my_vio (
        .clk       (clk),
        .probe_out0(vio_reset_n),
        .probe_out1(vio_start),
        .probe_out2(vio_height),
        .probe_out3(vio_width),
        .probe_out4(vio_channels)
    );

    //-------------------------------------------------------------------------
    // 2. Stimulus Generator
    //-------------------------------------------------------------------------
    depthwise_axis_stimulus #(
        .DATA_WIDTH  (DATA_WIDTH),
        .LANES       (LANES),
        .INPUT_WIDTH (INPUT_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH)
    ) source_inst (
        .clk            (clk),
        .rst_n          (vio_reset_n),
        .start_trigger  (vio_start),
        .cfg_height_in  (vio_height),
        .cfg_width_in   (vio_width),
        .cfg_channels_in(vio_channels),

        .start       (start),
        .cfg_height  (cfg_height),
        .cfg_width   (cfg_width),
        .cfg_channels(cfg_channels),
        .done        (done),

        .m_axis_kernel_tdata (axis_kernel_in_tdata),
        .m_axis_kernel_tvalid(axis_kernel_in_tvalid),
        .m_axis_kernel_tlast (axis_kernel_in_tlast),
        .m_axis_kernel_tready(axis_kernel_in_tready),

        .m_axis_data_tdata (axis_data_in_tdata),
        .m_axis_data_tvalid(axis_data_in_tvalid),
        .m_axis_data_tlast (axis_data_in_tlast),
        .m_axis_data_tready(axis_data_in_tready)
    );

    //-------------------------------------------------------------------------
    // 3. DUT (Depthwise Convolution Unit)
    //-------------------------------------------------------------------------
    depthwise_conv_unit #(
        .DATA_WIDTH  (DATA_WIDTH),
        .LANES       (LANES),
        .INPUT_WIDTH (INPUT_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .MAX_WIDTH   (MAX_WIDTH),
        .MAX_CHANNELS(MAX_CHANNELS),
        .ACC_WIDTH   (ACC_WIDTH)
    ) dut_inst (
        .clk  (clk),
        .rst_n(vio_reset_n),

        .start       (start),
        .done        (done),
        .cfg_height  (cfg_height),
        .cfg_width   (cfg_width),
        .cfg_channels(cfg_channels),

        .axis_kernel_in_tdata (axis_kernel_in_tdata),
        .axis_kernel_in_tvalid(axis_kernel_in_tvalid),
        .axis_kernel_in_tlast (axis_kernel_in_tlast),
        .axis_kernel_in_tready(axis_kernel_in_tready),

        .axis_data_in_tdata (axis_data_in_tdata),
        .axis_data_in_tvalid(axis_data_in_tvalid),
        .axis_data_in_tlast (axis_data_in_tlast),
        .axis_data_in_tready(axis_data_in_tready),

        .axis_data_out_tdata (axis_data_out_tdata),
        .axis_data_out_tvalid(axis_data_out_tvalid),
        .axis_data_out_tlast (axis_data_out_tlast),
        .axis_data_out_tready(axis_data_out_tready)
    );

    // Perfect sink - always ready
    assign axis_data_out_tready = 1'b1;

    //-------------------------------------------------------------------------
    // 4. ILA (Integrated Logic Analyzer)
    //-------------------------------------------------------------------------
    // Configure in IP Catalog:
    // - Monitor Type: Native
    // - Probe Count: 14
    //   - Probe 0: axis_kernel_in_tdata (64 bit)
    //   - Probe 1: axis_kernel_in_tvalid (1 bit)
    //   - Probe 2: axis_kernel_in_tlast (1 bit)
    //   - Probe 3: axis_data_in_tdata (64 bit)
    //   - Probe 4: axis_data_in_tvalid (1 bit)
    //   - Probe 5: axis_data_in_tready (1 bit)
    //   - Probe 6: axis_data_out_tdata (64 bit) - INT32 conv output
    //   - Probe 7: axis_data_out_tvalid (1 bit)
    //   - Probe 8: axis_data_out_tlast (1 bit)
    //   - Probe 9: start (1 bit)
    //   - Probe 10: done (1 bit)
    //   - Probe 11: cfg_height (16 bit)
    //   - Probe 12: cfg_width (16 bit)
    //   - Probe 13: vio_start (1 bit) - for trigger
    ila_0 my_ila (
        .clk    (clk),
        .probe0 (axis_kernel_in_tdata),
        .probe1 (axis_kernel_in_tvalid),
        .probe2 (axis_kernel_in_tlast),
        .probe3 (axis_data_in_tdata),
        .probe4 (axis_data_in_tvalid),
        .probe5 (axis_data_in_tready),
        .probe6 (axis_data_out_tdata),
        .probe7 (axis_data_out_tvalid),
        .probe8 (axis_data_out_tlast),
        .probe9 (start),
        .probe10(done),
        .probe11(cfg_height),
        .probe12(cfg_width),
        .probe13(vio_start)
    );

endmodule
