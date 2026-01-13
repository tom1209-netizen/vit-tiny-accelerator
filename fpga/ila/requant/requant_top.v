`timescale 1ns / 1ps

module debug_top (
    input wire clk
);

    // Parameters
    parameter DATA_WIDTH = 64;
    parameter ACC_WIDTH = 32;
    parameter LANES_INT8 = 8;
    parameter MAX_CHANNELS = 64;

    // Signals
    wire [DATA_WIDTH-1:0] s_axis_sb_tdata;
    wire                  s_axis_sb_tvalid;
    wire                  s_axis_sb_tlast;
    wire                  s_axis_sb_tready;

    wire                  sb_load_start;
    wire [          15:0] sb_count;
    wire                  sb_load_done;

    wire [DATA_WIDTH-1:0] s_axis_tdata;
    wire                  s_axis_tvalid;
    wire                  s_axis_tlast;
    wire                  s_axis_tready;

    wire [DATA_WIDTH-1:0] m_axis_tdata;
    wire                  m_axis_tvalid;
    wire                  m_axis_tlast;
    wire                  m_axis_tready;

    wire                  cfg_proc_start;
    wire [          15:0] cfg_num_channels;
    wire [          15:0] cfg_chan_base;

    // VIO Signals
    wire                  vio_start;
    wire                  vio_reset_n;
    wire                  vio_mode_int32;
    wire                  vio_use_bias;
    wire [           4:0] vio_shift;
    wire                  vio_round_en;
    wire                  vio_sat_en;

    //-------------------------------------------------------------------------
    // 1. VIO (Virtual Input/Output)
    //-------------------------------------------------------------------------
    // Configure in IP Catalog:
    // - Output Probe Count: 7
    //   - PROBE_OUT0: Width 1 (reset_n) - Initial 0x1
    //   - PROBE_OUT1: Width 1 (start_trigger)
    //   - PROBE_OUT2: Width 1 (mode_int32) - Initial 0x1 (INT32 mode)
    //   - PROBE_OUT3: Width 1 (use_bias) - Initial 0x1
    //   - PROBE_OUT4: Width 5 (shift) - Initial 0x00
    //   - PROBE_OUT5: Width 1 (round_en) - Initial 0x1
    //   - PROBE_OUT6: Width 1 (sat_en) - Initial 0x1
    vio_0 my_vio (
        .clk       (clk),
        .probe_out0(vio_reset_n),
        .probe_out1(vio_start),
        .probe_out2(vio_mode_int32),
        .probe_out3(vio_use_bias),
        .probe_out4(vio_shift),
        .probe_out5(vio_round_en),
        .probe_out6(vio_sat_en)
    );

    //-------------------------------------------------------------------------
    // 2. Stimulus Generator
    //-------------------------------------------------------------------------
    requant_axis_stimulus #(
        .DATA_WIDTH  (DATA_WIDTH),
        .ACC_WIDTH   (ACC_WIDTH),
        .MAX_CHANNELS(MAX_CHANNELS)
    ) source_inst (
        .clk           (clk),
        .rst_n         (vio_reset_n),
        .start_trigger (vio_start),
        .cfg_mode_int32(vio_mode_int32),
        .cfg_use_bias  (vio_use_bias),
        .cfg_shift     (vio_shift),

        // Scale/Bias load
        .m_axis_sb_tdata (s_axis_sb_tdata),
        .m_axis_sb_tvalid(s_axis_sb_tvalid),
        .m_axis_sb_tlast (s_axis_sb_tlast),
        .m_axis_sb_tready(s_axis_sb_tready),
        .sb_load_start   (sb_load_start),
        .sb_count        (sb_count),
        .sb_load_done    (sb_load_done),
        .cfg_proc_start  (cfg_proc_start),
        .cfg_num_channels(cfg_num_channels),
        .cfg_chan_base   (cfg_chan_base),

        // Data stream
        .m_axis_tdata (s_axis_tdata),
        .m_axis_tvalid(s_axis_tvalid),
        .m_axis_tlast (s_axis_tlast),
        .m_axis_tready(s_axis_tready)
    );

    //-------------------------------------------------------------------------
    // 3. DUT (Requant Unit)
    //-------------------------------------------------------------------------
    requant_unit #(
        .DATA_WIDTH  (DATA_WIDTH),
        .ACC_WIDTH   (ACC_WIDTH),
        .LANES_INT8  (LANES_INT8),
        .MAX_CHANNELS(MAX_CHANNELS)
    ) dut_inst (
        .clk  (clk),
        .rst_n(vio_reset_n),

        // Config
        .cfg_mode_int32  (vio_mode_int32),
        .cfg_use_bias    (vio_use_bias),
        .cfg_shift       (vio_shift),
        .cfg_round_en    (vio_round_en),
        .cfg_sat_en      (vio_sat_en),
        .cfg_num_channels(cfg_num_channels),
        .cfg_chan_base   (cfg_chan_base),
        .cfg_proc_start  (cfg_proc_start),

        // Scale/Bias load
        .sb_load_start   (sb_load_start),
        .sb_count        (sb_count),
        .sb_load_done    (sb_load_done),
        .s_axis_sb_tdata (s_axis_sb_tdata),
        .s_axis_sb_tvalid(s_axis_sb_tvalid),
        .s_axis_sb_tready(s_axis_sb_tready),
        .s_axis_sb_tlast (s_axis_sb_tlast),

        // Data input
        .s_axis_tdata (s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast (s_axis_tlast),

        // Data output
        .m_axis_tdata (m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast (m_axis_tlast)
    );

    // Perfect sink - always ready
    assign m_axis_tready = 1'b1;

    //-------------------------------------------------------------------------
    // 4. ILA (Integrated Logic Analyzer)
    //-------------------------------------------------------------------------
    // Configure in IP Catalog:
    // - Monitor Type: Native
    // - Probe Count: 12
    //   - Probe 0: s_axis_sb_tdata (64 bit) - scale/bias load
    //   - Probe 1: s_axis_sb_tvalid (1 bit)
    //   - Probe 2: sb_load_done (1 bit)
    //   - Probe 3: s_axis_tdata (64 bit) - INT32/INT8 input
    //   - Probe 4: s_axis_tvalid (1 bit)
    //   - Probe 5: s_axis_tready (1 bit)
    //   - Probe 6: m_axis_tdata (64 bit) - INT8 output
    //   - Probe 7: m_axis_tvalid (1 bit)
    //   - Probe 8: m_axis_tlast (1 bit)
    //   - Probe 9: cfg_proc_start (1 bit)
    //   - Probe 10: vio_mode_int32 (1 bit)
    //   - Probe 11: vio_start (1 bit) - for trigger
    ila_0 my_ila (
        .clk    (clk),
        .probe0 (s_axis_sb_tdata),
        .probe1 (s_axis_sb_tvalid),
        .probe2 (sb_load_done),
        .probe3 (s_axis_tdata),
        .probe4 (s_axis_tvalid),
        .probe5 (s_axis_tready),
        .probe6 (m_axis_tdata),
        .probe7 (m_axis_tvalid),
        .probe8 (m_axis_tlast),
        .probe9 (cfg_proc_start),
        .probe10(vio_mode_int32),
        .probe11(vio_start)
    );

endmodule
