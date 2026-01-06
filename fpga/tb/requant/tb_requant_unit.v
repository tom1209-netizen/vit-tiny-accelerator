`timescale 1ns / 1ps

module tb_requant_unit;
    localparam DATA_WIDTH = 64;
    localparam ACC_WIDTH = 32;
    localparam LANES_INT8 = 8;
    localparam MAX_CHANNELS = 64;
    localparam CLK_PERIOD = 10;
    localparam integer MAX_CYCLES = 20000;

    // Clock / reset
    reg                      clk;
    reg                      rst_n;

    // Control/config
    reg                      cfg_mode_int32;
    reg                      cfg_use_bias;
    reg     [           4:0] cfg_shift;
    reg                      cfg_round_en;
    reg                      cfg_sat_en;
    reg     [          15:0] cfg_num_channels;
    reg     [          15:0] cfg_chan_base;
    reg                      cfg_proc_start;

    // Scale/bias load
    reg                      sb_load_start;
    reg     [          15:0] sb_count;
    wire                     sb_load_done;
    reg     [DATA_WIDTH-1:0] s_axis_sb_tdata;
    reg                      s_axis_sb_tvalid;
    wire                     s_axis_sb_tready;
    reg                      s_axis_sb_tlast;

    // AXI input
    reg     [DATA_WIDTH-1:0] s_axis_tdata;
    reg                      s_axis_tvalid;
    wire                     s_axis_tready;
    reg                      s_axis_tlast;

    // AXI output
    wire    [DATA_WIDTH-1:0] m_axis_tdata;
    wire                     m_axis_tvalid;
    reg                      m_axis_tready;
    wire                     m_axis_tlast;

    integer                  cycles;
    integer                  errors;

    // DUT
    requant_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .LANES_INT8(LANES_INT8),
        .MAX_CHANNELS(MAX_CHANNELS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_mode_int32(cfg_mode_int32),
        .cfg_use_bias(cfg_use_bias),
        .cfg_shift(cfg_shift),
        .cfg_round_en(cfg_round_en),
        .cfg_sat_en(cfg_sat_en),
        .cfg_num_channels(cfg_num_channels),
        .cfg_chan_base(cfg_chan_base),
        .cfg_proc_start(cfg_proc_start),
        .sb_load_start(sb_load_start),
        .sb_count(sb_count),
        .sb_load_done(sb_load_done),
        .s_axis_sb_tdata(s_axis_sb_tdata),
        .s_axis_sb_tvalid(s_axis_sb_tvalid),
        .s_axis_sb_tready(s_axis_sb_tready),
        .s_axis_sb_tlast(s_axis_sb_tlast),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast)
    );

    // Clock
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // Watchdog
    initial cycles = 0;
    always @(posedge clk) cycles = cycles + 1;
    always @(posedge clk) begin
        if (cycles == MAX_CYCLES) begin
            $display("TIMEOUT at cycle %0d", cycles);
            $finish;
        end
    end

    // Scoreboard
    reg     [DATA_WIDTH-1:0] exp_data       [          0:1023];
    reg                      exp_last       [          0:1023];
    integer                  exp_head;
    integer                  exp_tail;

    // Scale/bias tables for expected calc
    integer                  scale_q31      [0:MAX_CHANNELS-1];
    integer                  bias_q31       [0:MAX_CHANNELS-1];

    // Expected packer state (Mode A)
    reg     [DATA_WIDTH-1:0] exp_pack_buf;
    integer                  exp_pack_count;
    reg                      exp_pack_last;
    integer                  exp_chan_ptr;

    // Backpressure toggle
    reg                      bp_enable;
    reg     [           2:0] bp_cnt;

    // Round-to-nearest-even (signed)
    function signed [63:0] round_shift_rne64_tb;
        input signed [63:0] val;
        input [4:0] shift;
        reg signed [63:0] abs_val;
        reg signed [63:0] base;
        reg        [63:0] rem;
        reg        [63:0] half;
        begin
            if (shift == 0) begin
                round_shift_rne64_tb = val;
            end else begin
                abs_val = (val < 0) ? -val : val;
                base    = abs_val >>> shift;
                rem     = abs_val & ((64'd1 << shift) - 1'd1);
                half    = 64'd1 << (shift - 1'd1);
                if ((rem > half) || ((rem == half) && base[0])) begin
                    base = base + 1'd1;
                end
                round_shift_rne64_tb = (val < 0) ? -base : base;
            end
        end
    endfunction

    function signed [7:0] calc_requant;
        input signed [31:0] acc;
        input signed [31:0] scale_q;
        input signed [31:0] bias;
        input [4:0] shift;
        input round_en;
        input sat_en;
        reg signed [63:0] prod;
        reg signed [63:0] aligned;
        reg signed [63:0] scaled;
        begin
            prod    = (acc + bias) * scale_q;
            aligned = prod >>> 31;
            if (round_en) scaled = round_shift_rne64_tb(aligned, shift);
            else scaled = aligned >>> shift;

            if (sat_en) begin
                if (scaled > 127) calc_requant = 8'sd127;
                else if (scaled < -128) calc_requant = -8'sd128;
                else calc_requant = scaled[7:0];
            end else begin
                calc_requant = scaled[7:0];
            end
        end
    endfunction

    task enqueue_expected;
        input [DATA_WIDTH-1:0] data;
        input last;
        begin
            exp_data[exp_tail] = data;
            exp_last[exp_tail] = last;
            exp_tail = exp_tail + 1;
        end
    endtask

    task reset_dut;
        begin
            rst_n = 1'b0;
            cfg_mode_int32 = 1'b0;
            cfg_use_bias = 1'b0;
            cfg_shift = 5'd0;
            cfg_round_en = 1'b0;
            cfg_sat_en = 1'b1;
            cfg_num_channels = 16'd0;
            cfg_chan_base = 16'd0;
            cfg_proc_start = 1'b0;

            sb_load_start = 1'b0;
            sb_count = 16'd0;
            s_axis_sb_tdata = 64'd0;
            s_axis_sb_tvalid = 1'b0;
            s_axis_sb_tlast = 1'b0;

            s_axis_tdata = 64'd0;
            s_axis_tvalid = 1'b0;
            s_axis_tlast = 1'b0;

            m_axis_tready = 1'b1;
            bp_enable = 1'b0;
            bp_cnt = 0;

            exp_head = 0;
            exp_tail = 0;
            exp_pack_buf = 64'd0;
            exp_pack_count = 0;
            exp_pack_last = 1'b0;
            exp_chan_ptr = 0;

            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task load_scale_table;
        input integer count;
        integer i;
        begin
            sb_count = count[15:0];
            sb_load_start = 1'b1;
            @(posedge clk);
            sb_load_start = 1'b0;

            for (i = 0; i < count; i = i + 1) begin
                // Drive on negedge to avoid race with DUT sampling on posedge.
                @(negedge clk);
                s_axis_sb_tdata  = {scale_q31[i], bias_q31[i]};
                s_axis_sb_tvalid = 1'b1;
                s_axis_sb_tlast  = (i == count - 1);
                while (!s_axis_sb_tready) @(posedge clk);
                @(posedge clk);
                s_axis_sb_tvalid = 1'b0;
                s_axis_sb_tlast  = 1'b0;
            end

            while (!sb_load_done) @(posedge clk);
            @(posedge clk);

        end
    endtask

    task drive_int32_beat;
        input signed [31:0] a;
        input signed [31:0] b;
        input last;
        reg signed [7:0] q0;
        reg signed [7:0] q1;
        begin
            // Expected
            q0 = calc_requant(
                a,
                scale_q31[exp_chan_ptr],
                bias_q31[exp_chan_ptr],
                cfg_shift,
                cfg_round_en,
                cfg_sat_en
            );
            q1 = calc_requant(
                b,
                scale_q31[exp_chan_ptr+1],
                bias_q31[exp_chan_ptr+1],
                cfg_shift,
                cfg_round_en,
                cfg_sat_en
            );
            exp_pack_buf[exp_pack_count*8+:8] = q0;
            exp_pack_buf[(exp_pack_count+1)*8+:8] = q1;
            exp_pack_count = exp_pack_count + 2;
            exp_pack_last = exp_pack_last | last;

            if (exp_pack_count == 8) begin
                enqueue_expected(exp_pack_buf, exp_pack_last);
                exp_pack_buf   = 64'd0;
                exp_pack_count = 0;
                exp_pack_last  = 1'b0;
            end

            if (last) exp_chan_ptr = 0;
            else exp_chan_ptr = exp_chan_ptr + 2;

            // Drive input
            s_axis_tdata  = {b, a};
            s_axis_tlast  = last;
            s_axis_tvalid = 1'b1;
            while (!s_axis_tready) @(posedge clk);
            @(posedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tlast  = 1'b0;
            s_axis_tdata  = 64'd0;
        end
    endtask

    task drive_int8_beat;
        input signed [7:0] v0;
        input signed [7:0] v1;
        input signed [7:0] v2;
        input signed [7:0] v3;
        input signed [7:0] v4;
        input signed [7:0] v5;
        input signed [7:0] v6;
        input signed [7:0] v7;
        input last;
        reg [DATA_WIDTH-1:0] out_pack;
        begin
            out_pack[7:0] =
                calc_requant(v0, scale_q31[0], bias_q31[0], cfg_shift, cfg_round_en, cfg_sat_en);
            out_pack[15:8] =
                calc_requant(v1, scale_q31[1], bias_q31[1], cfg_shift, cfg_round_en, cfg_sat_en);
            out_pack[23:16] =
                calc_requant(v2, scale_q31[2], bias_q31[2], cfg_shift, cfg_round_en, cfg_sat_en);
            out_pack[31:24] =
                calc_requant(v3, scale_q31[3], bias_q31[3], cfg_shift, cfg_round_en, cfg_sat_en);
            out_pack[39:32] =
                calc_requant(v4, scale_q31[4], bias_q31[4], cfg_shift, cfg_round_en, cfg_sat_en);
            out_pack[47:40] =
                calc_requant(v5, scale_q31[5], bias_q31[5], cfg_shift, cfg_round_en, cfg_sat_en);
            out_pack[55:48] =
                calc_requant(v6, scale_q31[6], bias_q31[6], cfg_shift, cfg_round_en, cfg_sat_en);
            out_pack[63:56] =
                calc_requant(v7, scale_q31[7], bias_q31[7], cfg_shift, cfg_round_en, cfg_sat_en);

            enqueue_expected(out_pack, last);

            s_axis_tdata  = {v7, v6, v5, v4, v3, v2, v1, v0};
            s_axis_tlast  = last;
            s_axis_tvalid = 1'b1;
            while (!s_axis_tready) @(posedge clk);
            @(posedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tlast  = 1'b0;
            s_axis_tdata  = 64'd0;
        end
    endtask

    task wait_for_scoreboard_empty;
        integer guard;
        begin
            guard = 0;
            while (exp_head != exp_tail && guard < 2000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (guard >= 2000) begin
                $display("Scoreboard timeout.");
                errors = errors + 1;
            end
        end
    endtask

    // Backpressure generator
    always @(posedge clk) begin
        if (!rst_n) begin
            bp_cnt <= 0;
            m_axis_tready <= 1'b1;
        end else if (bp_enable) begin
            bp_cnt <= bp_cnt + 1'b1;
            case (bp_cnt)
                3'd0, 3'd1: m_axis_tready <= 1'b1;
                3'd2, 3'd3, 3'd4: m_axis_tready <= 1'b0;
                default: m_axis_tready <= 1'b1;
            endcase
        end else begin
            m_axis_tready <= 1'b1;
            bp_cnt <= 0;
        end
    end

    // Scoreboard check
    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            if (exp_head >= exp_tail) begin
                $display("Unexpected output beat at %0t", $time);
                errors = errors + 1;
            end else begin
                if (m_axis_tdata !== exp_data[exp_head]) begin
                    $display("Mismatch data exp=%h got=%h at %0t", exp_data[exp_head],
                             m_axis_tdata, $time);
                    errors = errors + 1;
                end
                if (m_axis_tlast !== exp_last[exp_head]) begin
                    $display("Mismatch last exp=%b got=%b at %0t", exp_last[exp_head],
                             m_axis_tlast, $time);
                    errors = errors + 1;
                end
                exp_head = exp_head + 1;
            end
        end
    end

    initial begin
        errors = 0;
        reset_dut();

        // Test 1: Mode A basic + packing + TLAST
        $display("TEST 1: Mode A basic");
        cfg_mode_int32   = 1'b1;
        cfg_use_bias     = 1'b1;
        cfg_shift        = 5'd1;
        cfg_round_en     = 1'b1;
        cfg_sat_en       = 1'b1;
        cfg_num_channels = 16'd8;
        cfg_chan_base    = 16'd0;

        scale_q31[0]     = 32'sh40000000;
        bias_q31[0]      = 0;
        scale_q31[1]     = 32'sh60000000;
        bias_q31[1]      = 1;
        scale_q31[2]     = 32'sh20000000;
        bias_q31[2]      = -2;
        scale_q31[3]     = 32'sh7fffffff;
        bias_q31[3]      = 3;
        scale_q31[4]     = 32'sh30000000;
        bias_q31[4]      = 0;
        scale_q31[5]     = 32'sh10000000;
        bias_q31[5]      = 0;
        scale_q31[6]     = 32'sh50000000;
        bias_q31[6]      = -1;
        scale_q31[7]     = 32'sh70000000;
        bias_q31[7]      = 2;

        load_scale_table(8);
        cfg_proc_start = 1'b1;
        @(posedge clk);
        cfg_proc_start = 1'b0;
        exp_chan_ptr   = 0;

        drive_int32_beat(10, -10, 0);
        drive_int32_beat(20, -20, 0);
        drive_int32_beat(30, -30, 0);
        drive_int32_beat(40, -40, 1);
        wait_for_scoreboard_empty();

        // Test 2: Mode B rounding (RNE ties)
        $display("TEST 2: Mode B rounding");
        cfg_mode_int32   = 1'b0;
        cfg_use_bias     = 1'b0;
        cfg_shift        = 5'd1;
        cfg_round_en     = 1'b1;
        cfg_sat_en       = 1'b1;
        cfg_num_channels = 16'd8;
        cfg_chan_base    = 16'd0;

        scale_q31[0]     = 32'sh40000000;
        bias_q31[0]      = 0;
        scale_q31[1]     = 32'sh40000000;
        bias_q31[1]      = 0;
        scale_q31[2]     = 32'sh40000000;
        bias_q31[2]      = 0;
        scale_q31[3]     = 32'sh40000000;
        bias_q31[3]      = 0;
        scale_q31[4]     = 32'sh40000000;
        bias_q31[4]      = 0;
        scale_q31[5]     = 32'sh40000000;
        bias_q31[5]      = 0;
        scale_q31[6]     = 32'sh40000000;
        bias_q31[6]      = 0;
        scale_q31[7]     = 32'sh40000000;
        bias_q31[7]      = 0;

        load_scale_table(8);
        cfg_proc_start = 1'b1;
        @(posedge clk);
        cfg_proc_start = 1'b0;
        drive_int8_beat(1, 7, -1, -7, 3, -3, 5, -5, 1'b1);
        wait_for_scoreboard_empty();

        // Test 3: Saturation
        $display("TEST 3: Saturation");
        cfg_mode_int32   = 1'b0;
        cfg_use_bias     = 1'b0;
        cfg_shift        = 5'd0;
        cfg_round_en     = 1'b0;
        cfg_sat_en       = 1'b1;
        cfg_num_channels = 16'd8;
        cfg_chan_base    = 16'd0;

        scale_q31[0]     = 32'sh7fffffff;
        bias_q31[0]      = 0;
        scale_q31[1]     = 32'sh7fffffff;
        bias_q31[1]      = 0;
        scale_q31[2]     = 32'sh7fffffff;
        bias_q31[2]      = 0;
        scale_q31[3]     = 32'sh7fffffff;
        bias_q31[3]      = 0;
        scale_q31[4]     = 32'sh7fffffff;
        bias_q31[4]      = 0;
        scale_q31[5]     = 32'sh7fffffff;
        bias_q31[5]      = 0;
        scale_q31[6]     = 32'sh7fffffff;
        bias_q31[6]      = 0;
        scale_q31[7]     = 32'sh7fffffff;
        bias_q31[7]      = 0;

        load_scale_table(8);
        cfg_proc_start = 1'b1;
        @(posedge clk);
        cfg_proc_start = 1'b0;
        drive_int8_beat(8'sd100, -8'sd100, 8'sd127, -8'sd128, 8'sd120, -8'sd120, 8'sd50, -8'sd50,
                        1'b1);
        wait_for_scoreboard_empty();

        // Test 4: Backpressure + packing
        $display("TEST 4: Backpressure");
        cfg_mode_int32   = 1'b1;
        cfg_use_bias     = 1'b0;
        cfg_shift        = 5'd0;
        cfg_round_en     = 1'b0;
        cfg_sat_en       = 1'b1;
        cfg_num_channels = 16'd8;
        cfg_chan_base    = 16'd0;

        scale_q31[0]     = 32'sh40000000;
        bias_q31[0]      = 0;
        scale_q31[1]     = 32'sh40000000;
        bias_q31[1]      = 0;
        scale_q31[2]     = 32'sh40000000;
        bias_q31[2]      = 0;
        scale_q31[3]     = 32'sh40000000;
        bias_q31[3]      = 0;
        scale_q31[4]     = 32'sh40000000;
        bias_q31[4]      = 0;
        scale_q31[5]     = 32'sh40000000;
        bias_q31[5]      = 0;
        scale_q31[6]     = 32'sh40000000;
        bias_q31[6]      = 0;
        scale_q31[7]     = 32'sh40000000;
        bias_q31[7]      = 0;

        load_scale_table(8);
        cfg_proc_start = 1'b1;
        @(posedge clk);
        cfg_proc_start = 1'b0;
        bp_enable = 1'b1;

        drive_int32_beat(1, 2, 0);
        drive_int32_beat(3, 4, 0);
        drive_int32_beat(5, 6, 0);
        drive_int32_beat(7, 8, 1);

        wait_for_scoreboard_empty();
        bp_enable = 1'b0;

        // Done
        if (errors == 0) $display("ALL TESTS PASSED");
        else $display("TESTS FAILED: %0d errors", errors);
        $finish;
    end

endmodule
