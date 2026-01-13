`timescale 1ns / 1ps

module debug_top (
    input wire clk  // System clock (e.g., 100MHz or 125MHz on Arty)
    //    input wire reset_btn // Physical button on board (optional)
);

    // Signals
    wire [63:0] s_data, m_data;
    wire s_valid, m_valid;
    wire s_ready, m_ready;
    wire s_last, m_last;

    // VIO Signals
    wire vio_start;
    wire vio_reset_n;  // We can control reset via VIO too

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
    axis_stimulus #(
        .DATA_WIDTH(64)
    ) source_inst (
        .clk          (clk),
        .rst_n        (vio_reset_n),
        .start_trigger(vio_start),

        // Outputs to ReLU
        .m_axis_tdata (s_data),
        .m_axis_tvalid(s_valid),
        .m_axis_tlast (s_last),
        .m_axis_tready(s_ready)
    );

    //-------------------------------------------------------------------------
    // 3. DUT (Your ReLU Module)
    //-------------------------------------------------------------------------
    relu #(
        .DATA_WIDTH(64),
        .DATA_TYPE (8)
    ) dut_inst (
        .s_axis_tdata (s_data),
        .s_axis_tvalid(s_valid),
        .s_axis_tlast (s_last),
        .s_axis_tready(s_ready),

        .m_axis_tdata (m_data),
        .m_axis_tvalid(m_valid),
        .m_axis_tlast (m_last),
        .m_axis_tready(m_ready)
    );

    // Sink (Loopback ready)
    // We just act as a perfect sink that is always ready to accept data
    assign m_ready = 1'b1;

    //-------------------------------------------------------------------------
    // 4. ILA (Integrated Logic Analyzer)
    //-------------------------------------------------------------------------
    // Configure in IP Catalog:
    // - Monitor Type: Native
    // - Probe Count: 6
    //   - Probe 0: s_axis_tdata (64 bit)
    //   - Probe 1: s_axis_tvalid (1 bit)
    //   - Probe 2: s_axis_tready (1 bit)
    //   - Probe 3: m_axis_tdata (64 bit) - RESULT
    //   - Probe 4: m_axis_tvalid (1 bit)
    //   - Probe 5: m_axis_tlast (1 bit)
    ila_0 my_ila (
        .clk(clk),
        .probe0(s_data),
        .probe1(s_valid),
        .probe2(s_last),
        .probe3(s_ready),
        .probe4(m_data),
        .probe5(m_valid),
        .probe6(m_last),
        .probe7(m_ready)
    );

endmodule
