`timescale 1ns / 1ps

module debug_top (
    input wire clk
);

    // Parameters
    parameter AXIS_DATA_WIDTH = 64;
    parameter DATA_WIDTH = 8;
    parameter EXP_WIDTH = 20;
    parameter SUM_WIDTH = 32;
    parameter RECIP_WIDTH = 16;
    parameter FIFO_DEPTH = 256;

    // LUT file paths (relative to synthesis directory)
    parameter EXP_INIT_FILE = "../../rtl/softmax/lut/exp_table_q4_16.hex";
    parameter RECIP_INIT_FILE = "../../rtl/softmax/lut/recip_lut.hex";

    // Signals
    wire [AXIS_DATA_WIDTH-1:0] s_axis_tdata;
    wire                       s_axis_tvalid;
    wire                       s_axis_tlast;
    wire                       s_axis_tready;

    wire [AXIS_DATA_WIDTH-1:0] m_axis_tdata;
    wire                       m_axis_tvalid;
    wire                       m_axis_tlast;
    wire                       m_axis_tready;

    wire                       start;
    wire [               31:0] num_tokens;
    wire                       done;

    // VIO Signals
    wire                       vio_start;
    wire                       vio_reset_n;
    wire [                7:0] vio_num_tokens;
    wire                       vio_bp_enable;
    wire [                7:0] vio_bp_threshold;

    //-------------------------------------------------------------------------
    // 1. VIO (Virtual Input/Output)
    //-------------------------------------------------------------------------
    // Configure in IP Catalog:
    // - Output Probe Count: 5
    //   - PROBE_OUT0: Width 1 (reset_n) - Set Initial Value to 0x1
    //   - PROBE_OUT1: Width 1 (start_trigger)
    //   - PROBE_OUT2: Width 8 (num_tokens) - Set Initial Value to 0x10 (16 tokens)
    //   - PROBE_OUT3: Width 1 (bp_enable) - Set Initial Value to 0x0
    //   - PROBE_OUT4: Width 8 (bp_threshold) - Set Initial Value to 0x80
    vio_0 my_vio (
        .clk       (clk),
        .probe_out0(vio_reset_n),
        .probe_out1(vio_start),
        .probe_out2(vio_num_tokens),
        .probe_out3(vio_bp_enable),
        .probe_out4(vio_bp_threshold)
    );

    //-------------------------------------------------------------------------
    // 2. Stimulus Generator
    //-------------------------------------------------------------------------
    softmax_axis_stimulus #(
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
        .DATA_WIDTH     (DATA_WIDTH)
    ) source_inst (
        .clk           (clk),
        .rst_n         (vio_reset_n),
        .start_trigger (vio_start),
        .cfg_num_tokens(vio_num_tokens),

        .start     (start),
        .num_tokens(num_tokens),
        .done      (done),

        .m_axis_tdata (s_axis_tdata),
        .m_axis_tvalid(s_axis_tvalid),
        .m_axis_tlast (s_axis_tlast),
        .m_axis_tready(s_axis_tready)
    );

    //-------------------------------------------------------------------------
    // 3. DUT (Softmax Unit)
    //-------------------------------------------------------------------------
    softmax_unit #(
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
        .DATA_WIDTH     (DATA_WIDTH),
        .EXP_WIDTH      (EXP_WIDTH),
        .SUM_WIDTH      (SUM_WIDTH),
        .RECIP_WIDTH    (RECIP_WIDTH),
        .FIFO_DEPTH     (FIFO_DEPTH),
        .EXP_INIT_FILE  (EXP_INIT_FILE),
        .RECIP_INIT_FILE(RECIP_INIT_FILE)
    ) dut_inst (
        .clk  (clk),
        .rst_n(vio_reset_n),

        .start     (start),
        .num_tokens(num_tokens),
        .done      (done),

        .s_axis_tdata (s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast (s_axis_tlast),
        .s_axis_tready(s_axis_tready),

        .m_axis_tdata (m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast (m_axis_tlast),
        .m_axis_tready(m_axis_tready)
    );

    // Simple backpressure generator (LFSR-based)
    reg [7:0] bp_lfsr;
    always @(posedge clk or negedge vio_reset_n) begin
        if (!vio_reset_n) begin
            bp_lfsr <= 8'h1;
        end else begin
            bp_lfsr <= {bp_lfsr[6:0], bp_lfsr[7] ^ bp_lfsr[5]};
        end
    end

    wire bp_ready = (bp_lfsr < vio_bp_threshold);
    assign m_axis_tready = vio_bp_enable ? bp_ready : 1'b1;

    //-------------------------------------------------------------------------
    // 4. ILA (Integrated Logic Analyzer)
    //-------------------------------------------------------------------------
    // Configure in IP Catalog:
    // - Monitor Type: Native
    // - Probe Count: 15
    //   - Probe 0: s_axis_tdata (64 bit) - INT8 logits input
    //   - Probe 1: s_axis_tvalid (1 bit)
    //   - Probe 2: s_axis_tlast (1 bit)
    //   - Probe 3: s_axis_tready (1 bit)
    //   - Probe 4: m_axis_tdata (64 bit) - UINT8 probabilities output
    //   - Probe 5: m_axis_tvalid (1 bit)
    //   - Probe 6: m_axis_tlast (1 bit)
    //   - Probe 7: m_axis_tready (1 bit)
    //   - Probe 8: start (1 bit)
    //   - Probe 9: done (1 bit)
    //   - Probe 10: num_tokens (32 bit)
    //   - Probe 11: vio_start (1 bit) - for trigger
    //   - Probe 12: vio_reset_n (1 bit)
    //   - Probe 13: vio_bp_enable (1 bit)
    //   - Probe 14: vio_bp_threshold (8 bit)
    ila_0 my_ila (
        .clk   (clk),
        .probe0(s_axis_tdata),
        .probe1(s_axis_tvalid),
        .probe2(s_axis_tlast),
        .probe3(s_axis_tready),
        .probe4(m_axis_tdata),
        .probe5(m_axis_tvalid),
        .probe6(m_axis_tlast),
        .probe7(m_axis_tready),
        .probe8(start),
        .probe9(done),
        .probe10(num_tokens),
        .probe11(vio_start),
        .probe12(vio_reset_n),
        .probe13(vio_bp_enable),
        .probe14(vio_bp_threshold)
    );

endmodule
