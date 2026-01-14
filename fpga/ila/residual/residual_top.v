`timescale 1ns / 1ps

module residual_top (
    input wire clk
);

    // Parameters
    parameter DATA_WIDTH = 64;
    parameter ELEM_WIDTH = 8;

    // Signals
    wire [DATA_WIDTH-1:0] s_axis_a_tdata, s_axis_b_tdata;
    wire s_axis_a_tvalid, s_axis_b_tvalid;
    wire s_axis_a_tlast, s_axis_b_tlast;
    wire s_axis_a_tready, s_axis_b_tready;

    wire [DATA_WIDTH-1:0] m_axis_tdata;
    wire                  m_axis_tvalid;
    wire                  m_axis_tlast;
    wire                  m_axis_tready;

    // VIO Signals
    wire                  vio_start;
    wire                  vio_reset_n;

    //-------------------------------------------------------------------------
    // 1. VIO (Virtual Input/Output)
    //-------------------------------------------------------------------------
    // Configure in IP Catalog:
    // - Output Probe Count: 2
    //   - PROBE_OUT0: Width 1 (reset_n) - Set Initial Value to 0x1
    //   - PROBE_OUT1: Width 1 (start_trigger)
    vio_0 my_vio (
        .clk       (clk),
        .probe_out0(vio_reset_n),
        .probe_out1(vio_start)
    );

    //-------------------------------------------------------------------------
    // 2. Stimulus Generator
    //-------------------------------------------------------------------------
    residual_axis_stimulus #(
        .DATA_WIDTH(DATA_WIDTH),
        .ELEM_WIDTH(ELEM_WIDTH)
    ) source_inst (
        .clk          (clk),
        .rst_n        (vio_reset_n),
        .start_trigger(vio_start),

        .m_axis_a_tdata (s_axis_a_tdata),
        .m_axis_a_tvalid(s_axis_a_tvalid),
        .m_axis_a_tlast (s_axis_a_tlast),
        .m_axis_a_tready(s_axis_a_tready),

        .m_axis_b_tdata (s_axis_b_tdata),
        .m_axis_b_tvalid(s_axis_b_tvalid),
        .m_axis_b_tlast (s_axis_b_tlast),
        .m_axis_b_tready(s_axis_b_tready)
    );

    //-------------------------------------------------------------------------
    // 3. DUT (Residual Add)
    //-------------------------------------------------------------------------
    residual_add #(
        .DATA_WIDTH(DATA_WIDTH),
        .ELEM_WIDTH(ELEM_WIDTH)
    ) dut_inst (
        .clk  (clk),
        .rst_n(vio_reset_n),

        .s_axis_a_tdata (s_axis_a_tdata),
        .s_axis_a_tvalid(s_axis_a_tvalid),
        .s_axis_a_tlast (s_axis_a_tlast),
        .s_axis_a_tready(s_axis_a_tready),

        .s_axis_b_tdata (s_axis_b_tdata),
        .s_axis_b_tvalid(s_axis_b_tvalid),
        .s_axis_b_tlast (s_axis_b_tlast),
        .s_axis_b_tready(s_axis_b_tready),

        .m_axis_tdata (m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast (m_axis_tlast),
        .m_axis_tready(m_axis_tready)
    );

    // Perfect sink - always ready
    assign m_axis_tready = 1'b1;

    //-------------------------------------------------------------------------
    // 4. ILA (Integrated Logic Analyzer)
    //-------------------------------------------------------------------------
    // Configure in IP Catalog:
    // - Monitor Type: Native
    // - Probe Count: 10
    //   - Probe 0: s_axis_a_tdata (64 bit)
    //   - Probe 1: s_axis_a_tvalid (1 bit)
    //   - Probe 2: s_axis_a_tready (1 bit)
    //   - Probe 3: s_axis_b_tdata (64 bit)
    //   - Probe 4: s_axis_b_tvalid (1 bit)
    //   - Probe 5: m_axis_tdata (64 bit) - saturated sum
    //   - Probe 6: m_axis_tvalid (1 bit)
    //   - Probe 7: m_axis_tlast (1 bit)
    //   - Probe 8: m_axis_tready (1 bit)
    //   - Probe 9: vio_start (1 bit) - for trigger
    ila_0 my_ila (
        .clk   (clk),
        
        .probe0(s_axis_a_tdata),
        .probe1(s_axis_a_tvalid),
        .probe2(s_axis_a_tlast),
        .probe3(s_axis_a_tready),
        
        .probe4(s_axis_b_tdata),
        .probe5(s_axis_b_tvalid),
        .probe6(s_axis_b_tlast),
        .probe7(s_axis_b_tready),
        
        .probe8(m_axis_tdata),
        .probe9(m_axis_tvalid),
        .probe10(m_axis_tlast),
        .probe11(m_axis_tready)
        
    );

endmodule
