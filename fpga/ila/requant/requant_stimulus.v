`timescale 1ns / 1ps

module requant_axis_stimulus #(
    parameter DATA_WIDTH   = 64,
    parameter ACC_WIDTH    = 32,
    parameter MAX_CHANNELS = 64
) (
    input wire clk,
    input wire rst_n,
    input wire start_trigger,

    // Config (directly connected to VIO for flexibility)
    input wire       cfg_mode_int32,
    input wire       cfg_use_bias,
    input wire [4:0] cfg_shift,

    // Scale/Bias load stream
    output reg  [DATA_WIDTH-1:0] m_axis_sb_tdata,
    output reg                   m_axis_sb_tvalid,
    output reg                   m_axis_sb_tlast,
    input  wire                  m_axis_sb_tready,

    // Control outputs
    output reg         sb_load_start,
    output reg  [15:0] sb_count,
    input  wire        sb_load_done,
    output reg         cfg_proc_start,
    output reg  [15:0] cfg_num_channels,
    output reg  [15:0] cfg_chan_base,

    // Data stream
    output reg  [DATA_WIDTH-1:0] m_axis_tdata,
    output reg                   m_axis_tvalid,
    output reg                   m_axis_tlast,
    input  wire                  m_axis_tready
);

    localparam NUM_CHANNELS = 8;  // Simple: 8 channels, 4 INT32 beats or 1 INT8 beat
    localparam BURST_LEN_INT32 = 4;  // 2 INT32 per beat, 8 channels = 4 beats
    localparam BURST_LEN_INT8 = 1;  // 8 INT8 per beat

    reg [3:0] beat_count;
    reg [3:0] sb_beat_count;

    localparam IDLE = 3'd0;
    localparam LOAD_SB = 3'd1;
    localparam WAIT_SB = 3'd2;
    localparam PROC_START = 3'd3;
    localparam STREAM = 3'd4;
    localparam DONE = 3'd5;
    reg [2:0] state;

    // Edge detection
    wire start_trigger_edge;
    reg start_d1, start_d2;
    assign start_trigger_edge = start_d1 && ~start_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_d1 <= 0;
            start_d2 <= 0;
        end else begin
            start_d1 <= start_trigger;
            start_d2 <= start_d1;
        end
    end

    // Scale/Bias patterns: [63:32]=scale_q31, [31:0]=bias_int32
    // Using simple scale=1.0 (0x40000000 in Q31) and small biases
    always @(*) begin
        m_axis_sb_tdata = {DATA_WIDTH{1'b0}};

        if (state == LOAD_SB) begin
            case (sb_beat_count)
                // Channel 0-7 scale/bias
                4'd0: m_axis_sb_tdata = {32'h40000000, 32'h00000000};  // scale=1.0, bias=0
                4'd1: m_axis_sb_tdata = {32'h40000000, 32'h00000001};  // scale=1.0, bias=1
                4'd2: m_axis_sb_tdata = {32'h40000000, 32'h00000002};  // scale=1.0, bias=2
                4'd3: m_axis_sb_tdata = {32'h40000000, 32'h00000003};  // scale=1.0, bias=3
                4'd4: m_axis_sb_tdata = {32'h40000000, 32'h00000004};  // scale=1.0, bias=4
                4'd5: m_axis_sb_tdata = {32'h40000000, 32'h00000005};  // scale=1.0, bias=5
                4'd6: m_axis_sb_tdata = {32'h40000000, 32'h00000006};  // scale=1.0, bias=6
                4'd7: m_axis_sb_tdata = {32'h40000000, 32'h00000007};  // scale=1.0, bias=7
                default: m_axis_sb_tdata = {DATA_WIDTH{1'b0}};
            endcase
        end
    end

    // Data patterns (INT32 mode: 2 x INT32 per beat)
    always @(*) begin
        m_axis_tdata = {DATA_WIDTH{1'b0}};

        if (state == STREAM) begin
            if (cfg_mode_int32) begin
                // INT32 mode: 2 accumulators per beat
                case (beat_count)
                    4'd0: m_axis_tdata = {32'd100, 32'd50};     // ch0=50, ch1=100
                    4'd1: m_axis_tdata = {32'd200, 32'd150};    // ch2=150, ch3=200
                    4'd2: m_axis_tdata = {32'hFFFFFF00, 32'd0}; // ch4=0, ch5=-256
                    4'd3: m_axis_tdata = {32'd1000, 32'd500};   // ch6=500, ch7=1000
                    default: m_axis_tdata = {DATA_WIDTH{1'b0}};
                endcase
            end else begin
                // INT8 mode: 8 channels per beat
                m_axis_tdata = 64'h08_07_06_05_04_03_02_01;  // 1,2,3,4,5,6,7,8
            end
        end
    end

    wire [3:0] burst_len = cfg_mode_int32 ? BURST_LEN_INT32 : BURST_LEN_INT8;

    // State machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= IDLE;
            m_axis_sb_tvalid <= 1'b0;
            m_axis_sb_tlast  <= 1'b0;
            m_axis_tvalid    <= 1'b0;
            m_axis_tlast     <= 1'b0;
            sb_load_start    <= 1'b0;
            sb_count         <= 16'd0;
            cfg_proc_start   <= 1'b0;
            cfg_num_channels <= 16'd0;
            cfg_chan_base    <= 16'd0;
            beat_count       <= 4'd0;
            sb_beat_count    <= 4'd0;
        end else begin
            sb_load_start  <= 1'b0;
            cfg_proc_start <= 1'b0;

            case (state)
                IDLE: begin
                    m_axis_sb_tvalid <= 1'b0;
                    m_axis_tvalid    <= 1'b0;
                    beat_count       <= 4'd0;
                    sb_beat_count    <= 4'd0;

                    if (start_trigger_edge) begin
                        state         <= LOAD_SB;
                        sb_load_start <= 1'b1;
                        sb_count      <= NUM_CHANNELS;
                    end
                end

                LOAD_SB: begin
                    m_axis_sb_tvalid <= 1'b1;
                    m_axis_sb_tlast  <= (sb_beat_count == NUM_CHANNELS - 1);

                    if (m_axis_sb_tready && m_axis_sb_tvalid) begin
                        if (sb_beat_count == NUM_CHANNELS - 1) begin
                            state            <= WAIT_SB;
                            m_axis_sb_tvalid <= 1'b0;
                            m_axis_sb_tlast  <= 1'b0;
                        end else begin
                            sb_beat_count <= sb_beat_count + 1;
                        end
                    end
                end

                WAIT_SB: begin
                    if (sb_load_done) begin
                        state            <= PROC_START;
                        cfg_num_channels <= NUM_CHANNELS;
                        cfg_chan_base    <= 16'd0;
                    end
                end

                PROC_START: begin
                    cfg_proc_start <= 1'b1;
                    state          <= STREAM;
                    m_axis_tvalid  <= 1'b1;
                end

                STREAM: begin
                    m_axis_tlast <= (beat_count == burst_len - 1);

                    if (m_axis_tready && m_axis_tvalid) begin
                        if (beat_count == burst_len - 1) begin
                            state         <= DONE;
                            m_axis_tvalid <= 1'b0;
                            m_axis_tlast  <= 1'b0;
                        end else begin
                            beat_count <= beat_count + 1;
                        end
                    end
                end

                DONE: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
