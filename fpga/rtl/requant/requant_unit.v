`timescale 1ns / 1ps

module requant_unit #(
    parameter DATA_WIDTH   = 64,
    parameter ACC_WIDTH    = 32,
    parameter LANES_INT8   = 8,
    parameter MAX_CHANNELS = 512
) (
    input wire clk,
    input wire rst_n,

    // Control/config
    input wire        cfg_mode_int32,    // 1: 2xINT32 -> pack to 8xINT8
    input wire        cfg_use_bias,
    input wire [ 4:0] cfg_shift,
    input wire        cfg_round_en,
    input wire        cfg_sat_en,
    input wire [15:0] cfg_num_channels,
    input wire [15:0] cfg_chan_base,
    input wire        cfg_proc_start,

    // Scale/bias table load (64-bit: [63:32]=scale_q31, [31:0]=bias_int32)
    input  wire                  sb_load_start,
    input  wire [          15:0] sb_count,
    output reg                   sb_load_done,
    input  wire [DATA_WIDTH-1:0] s_axis_sb_tdata,
    input  wire                  s_axis_sb_tvalid,
    output wire                  s_axis_sb_tready,
    input  wire                  s_axis_sb_tlast,

    // AXI-Stream input
    input  wire [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                  s_axis_tvalid,
    output wire                  s_axis_tready,
    input  wire                  s_axis_tlast,

    // AXI-Stream output
    output wire [DATA_WIDTH-1:0] m_axis_tdata,
    output wire                  m_axis_tvalid,
    input  wire                  m_axis_tready,
    output wire                  m_axis_tlast
);

    localparam SCALE_BIAS_W = 64;

    // Scale/Bias RAM (async read for simplicity; can be upgraded to sync BRAM)
    reg [SCALE_BIAS_W-1:0] sb_mem         [0:MAX_CHANNELS-1];

    reg                    sb_load_active;
    reg [            15:0] sb_wr_idx;

    assign s_axis_sb_tready = sb_load_active && (sb_wr_idx < sb_count);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sb_load_active <= 1'b0;
            sb_wr_idx      <= 16'd0;
            sb_load_done   <= 1'b0;
        end else begin
            sb_load_done <= 1'b0;

            if (sb_load_start) begin
                sb_load_active <= 1'b1;
                sb_wr_idx      <= 16'd0;
            end

            if (sb_load_active && s_axis_sb_tvalid && s_axis_sb_tready) begin
                if (sb_wr_idx < MAX_CHANNELS[15:0]) begin
                    sb_mem[sb_wr_idx] <= s_axis_sb_tdata;
                end
                sb_wr_idx <= sb_wr_idx + 1'b1;
                if (sb_wr_idx == (sb_count - 1'b1)) begin
                    sb_load_active <= 1'b0;
                    sb_load_done   <= 1'b1;
                end
            end

            // Optional: allow early termination on tlast
            if (sb_load_active && s_axis_sb_tvalid && s_axis_sb_tready && s_axis_sb_tlast) begin
                sb_load_active <= 1'b0;
                sb_load_done   <= 1'b1;
            end
        end
    end

    // Output FIFO (depth = 2)
    reg  [DATA_WIDTH-1:0] out_fifo_data                             [0:1];
    reg                   out_fifo_last                             [0:1];
    reg  [           1:0] out_fifo_count;
    reg                   out_fifo_rptr;
    reg                   out_fifo_wptr;

    wire                  out_fifo_empty = (out_fifo_count == 2'd0);
    wire                  out_pop = m_axis_tvalid && m_axis_tready;

    assign m_axis_tvalid = ~out_fifo_empty;
    assign m_axis_tdata  = out_fifo_data[out_fifo_rptr];
    assign m_axis_tlast  = out_fifo_last[out_fifo_rptr];

    // Mode A packer state (2xINT32 -> 8xINT8)
    reg [DATA_WIDTH-1:0] pack_buf;
    reg [           3:0] pack_count;  // number of bytes collected (0,2,4,6)
    reg                  pack_last;
    reg [           3:0] base_pack_count;
    reg                  base_pack_last;
    reg [          15:0] base_chan_ptr;
    reg                  start_pending;

    // Channel pointer
    reg [          15:0] chan_ptr;

    // Rounding helper (round-to-nearest-even, symmetric)
    function signed [63:0] round_shift_rne64;
        input signed [63:0] val;
        input [4:0] shift;
        reg signed [63:0] abs_val;
        reg signed [63:0] base;
        reg        [63:0] rem;
        reg        [63:0] half;
        begin
            if (shift == 0) begin
                round_shift_rne64 = val;
            end else begin
                abs_val = (val < 0) ? -val : val;
                base    = abs_val >>> shift;
                rem     = abs_val & ((64'd1 << shift) - 1'd1);
                half    = 64'd1 << (shift - 1'd1);

                if ((rem > half) || ((rem == half) && base[0])) begin
                    base = base + 1'd1;
                end

                round_shift_rne64 = (val < 0) ? -base : base;
            end
        end
    endfunction

    // Lane unpacking and requant combinational helpers
    function signed [7:0] requant_lane;
        input signed [31:0] acc;
        input signed [31:0] scale_q31;
        input signed [31:0] bias;
        input [4:0] shift;
        input round_en;
        input sat_en;
        reg signed [63:0] prod;
        reg signed [63:0] aligned;
        reg signed [63:0] scaled;
        begin
            prod    = (acc + bias) * $signed(scale_q31);
            aligned = prod >>> 31;

            if (round_en) begin
                scaled = round_shift_rne64(aligned, shift);
            end else begin
                scaled = aligned >>> shift;
            end

            if (sat_en) begin
                if (scaled > 127) requant_lane = 8'sd127;
                else if (scaled < -128) requant_lane = -8'sd128;
                else requant_lane = scaled[7:0];
            end else begin
                requant_lane = scaled[7:0];
            end
        end
    endfunction

    wire signed [ACC_WIDTH-1:0] acc32_0;
    wire signed [ACC_WIDTH-1:0] acc32_1;
    assign acc32_0 = s_axis_tdata[0+:ACC_WIDTH];
    assign acc32_1 = s_axis_tdata[ACC_WIDTH+:ACC_WIDTH];

    wire signed [7:0] acc8_lane[0:LANES_INT8-1];
    genvar g;
    generate
        for (g = 0; g < LANES_INT8; g = g + 1) begin : gen_acc8
            assign acc8_lane[g] = s_axis_tdata[g*8+:8];
        end
    endgenerate

    wire start_active = cfg_proc_start || start_pending;
    wire [15:0] chan_ptr_calc = start_active ? cfg_chan_base : chan_ptr;
    wire [15:0] chan_ptr_calc32 = start_active ? (cfg_chan_base - 16'd1) : chan_ptr;
    wire [15:0] ch_idx32_0;
    wire [15:0] ch_idx32_1;
    assign ch_idx32_0 = chan_ptr_calc32 + 16'd1;
    assign ch_idx32_1 = chan_ptr_calc32 + 16'd2;

    wire [15:0] ch_idx8[0:LANES_INT8-1];
    generate
        for (g = 0; g < LANES_INT8; g = g + 1) begin : gen_ch8
            assign ch_idx8[g] = chan_ptr_calc + g[15:0];
        end
    endgenerate

    wire [SCALE_BIAS_W-1:0] sb_entry32_0;
    wire [SCALE_BIAS_W-1:0] sb_entry32_1;
    wire [16:0] chan_limit = {1'b0, cfg_chan_base} + {1'b0, cfg_num_channels};
    wire ch32_valid0 = ({1'b0, ch_idx32_0} < chan_limit) && (ch_idx32_0 < MAX_CHANNELS[15:0]);
    wire ch32_valid1 = ({1'b0, ch_idx32_1} < chan_limit) && (ch_idx32_1 < MAX_CHANNELS[15:0]);
    assign sb_entry32_0 = ch32_valid0 ? sb_mem[ch_idx32_0] : {SCALE_BIAS_W{1'b0}};
    assign sb_entry32_1 = ch32_valid1 ? sb_mem[ch_idx32_1] : {SCALE_BIAS_W{1'b0}};

    wire [SCALE_BIAS_W-1:0] sb_entry8[0:LANES_INT8-1];
    generate
        for (g = 0; g < LANES_INT8; g = g + 1) begin : gen_sb8
            wire ch8_valid = ({1'b0, ch_idx8[g]} < chan_limit) && (ch_idx8[g] < MAX_CHANNELS[15:0]);
            assign sb_entry8[g] = ch8_valid ? sb_mem[ch_idx8[g]] : {SCALE_BIAS_W{1'b0}};
        end
    endgenerate

    wire signed [31:0] scale32_0;
    wire signed [31:0] scale32_1;
    wire signed [31:0] bias32_0;
    wire signed [31:0] bias32_1;
    assign scale32_0 = sb_entry32_0[63:32];
    assign scale32_1 = sb_entry32_1[63:32];
    assign bias32_0  = cfg_use_bias ? sb_entry32_0[31:0] : 32'sd0;
    assign bias32_1  = cfg_use_bias ? sb_entry32_1[31:0] : 32'sd0;

    wire signed [31:0] scale8[0:LANES_INT8-1];
    wire signed [31:0] bias8 [0:LANES_INT8-1];
    generate
        for (g = 0; g < LANES_INT8; g = g + 1) begin : gen_scale8
            assign scale8[g] = sb_entry8[g][63:32];
            assign bias8[g]  = cfg_use_bias ? sb_entry8[g][31:0] : 32'sd0;
        end
    endgenerate

    wire signed [7:0] out_q32_0;
    wire signed [7:0] out_q32_1;
    assign out_q32_0 = requant_lane(
        acc32_0, scale32_0, bias32_0, cfg_shift, cfg_round_en, cfg_sat_en
    );
    assign out_q32_1 = requant_lane(
        acc32_1, scale32_1, bias32_1, cfg_shift, cfg_round_en, cfg_sat_en
    );

    wire signed [7:0] out_q8[0:LANES_INT8-1];
    generate
        for (g = 0; g < LANES_INT8; g = g + 1) begin : gen_out8
            assign out_q8[g] = requant_lane(
                {
                    {24{acc8_lane[g][7]}}, acc8_lane[g]
                },
                scale8[g],
                bias8[g],
                cfg_shift,
                cfg_round_en,
                cfg_sat_en
            );
        end
    endgenerate

    wire [DATA_WIDTH-1:0] out_pack_int8;
    generate
        for (g = 0; g < LANES_INT8; g = g + 1) begin : gen_pack8
            assign out_pack_int8[g*8+:8] = out_q8[g];
        end
    endgenerate

    // Main processing
    reg [DATA_WIDTH-1:0] pack_buf_next;
    reg [3:0] pack_count_next;
    reg pack_last_next;
    reg [15:0] chan_ptr_next;

    reg push_out;
    reg [DATA_WIDTH-1:0] push_data;
    reg push_last;

    wire out_fifo_full_eff = (out_fifo_count == 2'd2) && !out_pop;
    wire can_accept_int32_eff = (pack_count < 4'd6) || (!out_fifo_full_eff && (pack_count == 4'd6));
    wire can_accept_int8_eff = ~out_fifo_full_eff;
    wire can_accept_eff = cfg_mode_int32 ? can_accept_int32_eff : can_accept_int8_eff;

    assign s_axis_tready = can_accept_eff;
    wire in_fire_eff = s_axis_tvalid && s_axis_tready;

    always @* begin
        pack_buf_next = pack_buf;
        pack_count_next = pack_count;
        pack_last_next = pack_last;
        chan_ptr_next = chan_ptr;

        push_out = 1'b0;
        push_data = {DATA_WIDTH{1'b0}};
        push_last = 1'b0;

        base_pack_count = start_active ? 4'd0 : pack_count;
        base_pack_last = start_active ? 1'b0 : pack_last;
        base_chan_ptr = cfg_mode_int32 ? chan_ptr_calc32 : chan_ptr_calc;

        if (in_fire_eff) begin
            if (s_axis_tlast) begin
                chan_ptr_next = cfg_mode_int32 ? (cfg_chan_base - 16'd1) : cfg_chan_base;
            end else begin
                chan_ptr_next = base_chan_ptr + (cfg_mode_int32 ? 16'd2 : 16'd8);
            end

            if (cfg_mode_int32) begin
                pack_buf_next[base_pack_count*8+:8] = out_q32_0;
                pack_buf_next[(base_pack_count+1'd1)*8+:8] = out_q32_1;
                pack_count_next = base_pack_count + 4'd2;
                pack_last_next = base_pack_last | s_axis_tlast;

                if (base_pack_count == 4'd6) begin
                    push_out = 1'b1;
                    push_data = pack_buf_next;
                    push_last = pack_last_next;
                    pack_count_next = 4'd0;
                    pack_last_next = 1'b0;
                end
            end else begin
                push_out  = 1'b1;
                push_data = out_pack_int8;
                push_last = s_axis_tlast;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_fifo_count <= 2'd0;
            out_fifo_rptr <= 1'b0;
            out_fifo_wptr <= 1'b0;

            pack_buf <= {DATA_WIDTH{1'b0}};
            pack_count <= 4'd0;
            pack_last <= 1'b0;

            chan_ptr <= 16'd0;
            start_pending <= 1'b0;
        end else begin
            start_pending <= (start_pending || cfg_proc_start) && !in_fire_eff;
            pack_buf <= pack_buf_next;
            pack_count <= pack_count_next;
            pack_last <= pack_last_next;
            chan_ptr <= chan_ptr_next;

            case ({
                push_out && !out_fifo_full_eff, out_pop
            })
                2'b10: begin
                    out_fifo_data[out_fifo_wptr] <= push_data;
                    out_fifo_last[out_fifo_wptr] <= push_last;
                    out_fifo_wptr <= ~out_fifo_wptr;
                    out_fifo_count <= out_fifo_count + 1'b1;
                end
                2'b01: begin
                    out_fifo_rptr  <= ~out_fifo_rptr;
                    out_fifo_count <= out_fifo_count - 1'b1;
                end
                2'b11: begin
                    out_fifo_data[out_fifo_wptr] <= push_data;
                    out_fifo_last[out_fifo_wptr] <= push_last;
                    out_fifo_wptr <= ~out_fifo_wptr;
                    out_fifo_rptr <= ~out_fifo_rptr;
                    // count unchanged
                end
                default: begin
                    // no-op
                end
            endcase
        end
    end

endmodule
