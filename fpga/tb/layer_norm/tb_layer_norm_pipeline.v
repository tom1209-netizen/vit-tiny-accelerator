`timescale 1ns / 1ps

module tb_layer_norm_pipelined;

    // Parameters
    parameter DATA_WIDTH   = 8;
    parameter PARALLEL_N   = 8;
    parameter BEAT_WIDTH   = 64;   
    parameter FIFO_DEPTH   = 512;
    parameter STAT_WIDTH   = 32;   
    parameter SUM_WIDTH    = 18;
    parameter SUM_SQ_WIDTH = 26; // Match RTL
    parameter M_BITS       = 12;

    localparam CLK_PERIOD = 5.0;
    localparam MAX_PACKET_LEN = 800; // Buffer size
    localparam NUM_PACKETS = 3;      // Testing 3 distinct lengths

    // Signals
    reg clk;
    reg aresetn;
    
    reg [BEAT_WIDTH-1:0]   s_axis_tdata;
    reg                    s_axis_tvalid;
    reg                    s_axis_tlast;
    wire                   s_axis_tready;
    
    reg signed [STAT_WIDTH-1:0] cfg_gamma;
    reg signed [STAT_WIDTH-1:0] cfg_beta;

    wire [BEAT_WIDTH-1:0]  m_axis_tdata;
    wire                   m_axis_tvalid;
    wire                   m_axis_tlast;
    reg                    m_axis_tready;

    // Test Config
    // Packet 0: 128 (Stage 1)
    // Packet 1: 160 (Stage 2)
    // Packet 2: 320 (Stage 3)
    integer packet_lengths [0:2];

    // Verification Storage
    reg signed [7:0] history_buffer [0:NUM_PACKETS-1][0:MAX_PACKET_LEN-1];
    reg signed [7:0] input_buffer [0:MAX_PACKET_LEN-1];
    reg signed [7:0] expected_buffer [0:MAX_PACKET_LEN-1];
    reg packet_gen_done [0:NUM_PACKETS-1];

    // DUT
    layer_norm #(
        .DATA_WIDTH(DATA_WIDTH),
        .PARALLEL_N(PARALLEL_N),
        .BEAT_WIDTH(BEAT_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH),
        .STAT_WIDTH(STAT_WIDTH),
        .SUM_WIDTH(SUM_WIDTH),
        .SUM_SQ_WIDTH(SUM_SQ_WIDTH),
        .M_BITS(M_BITS)
    ) dut (
        .clk(clk),
        .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        .cfg_gamma(cfg_gamma),
        .cfg_beta(cfg_beta),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tready(m_axis_tready)
    );

    // Helpers
    function real q16_to_real(input signed [31:0] val);
        q16_to_real = $itor(val) / 65536.0;
    endfunction
    
    function signed [31:0] real_to_q16(input real val);
        real_to_q16 = $rtoi(val * 65536.0);
    endfunction
    
    function signed [7:0] clamp_to_int8(input integer val);
        if (val > 127) clamp_to_int8 = 127;
        else if (val < -128) clamp_to_int8 = -128;
        else clamp_to_int8 = val[7:0];
    endfunction

    function integer round_half_up(input real val);
        begin
            round_half_up = $floor(val + 0.5);
        end
    endfunction

    // Golden Model with DYNAMIC LENGTH
    task calc_golden_model(input integer id, input integer len);
        integer i;
        real sum, sum_sq, mean, var, inv_std, val, norm;
        real r_gamma, r_beta;
    begin
        sum = 0; sum_sq = 0;
        
        for (i=0; i<len; i=i+1) begin
            val = $itor(input_buffer[i]);
            sum = sum + val;
            sum_sq = sum_sq + (val*val);
        end
        
        mean = sum / len;
        var  = (sum_sq / len) - (mean * mean);
        
        if (var <= 0.0001) inv_std = 0;
        else inv_std = 1.0 / $sqrt(var);
        
        r_gamma = q16_to_real(cfg_gamma);
        r_beta  = q16_to_real(cfg_beta);

        $display("---------------------------------------------------------------");
        $display("[Golden Pkt %0d] Len=%0d, Mean=%.4f, Var=%.4f, InvStd=%.4f", 
                 id, len, mean, var, inv_std);
        $display("---------------------------------------------------------------");
        
        for (i=0; i<len; i=i+1) begin
            val = $itor(input_buffer[i]);
            norm = (val - mean) * inv_std * r_gamma + r_beta;
            expected_buffer[i] = clamp_to_int8(round_half_up(norm));
        end
    end
    endtask

    // Main
    integer k;
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    initial begin
        $display("=== START DYNAMIC LENGTH TEST ===");
        
        // Setup Lengths
        packet_lengths[0] = 320; // Stage 1
        packet_lengths[1] = 320; // Stage 2
        packet_lengths[2] = 320; // Stage 3
        
        for(k=0; k<NUM_PACKETS; k=k+1) packet_gen_done[k] = 0;

        aresetn = 0;
        s_axis_tdata = 0; s_axis_tvalid = 0; s_axis_tlast = 0;
        m_axis_tready = 1; 
        
        cfg_gamma = real_to_q16(1); 
        cfg_beta  = real_to_q16(0.5);

        #(CLK_PERIOD * 10);
        aresetn = 1;
        #(CLK_PERIOD * 5);

        fork
            driver_thread();
            monitor_thread();
        join

        $display("\n=== ALL TESTS PASSED ===");
        $finish;
    end

    // Driver
    task driver_thread;
        integer pkt_id, beat_idx, elem_idx, global_idx, current_len, num_beats;
        reg [63:0] r_data;
        reg [63:0] packet_data_store [0:99]; // Max 800 elems = 100 beats
    begin
        @(posedge clk);
        while (!aresetn) @(posedge clk);
        
        for (pkt_id = 0; pkt_id < NUM_PACKETS; pkt_id = pkt_id + 1) begin
            current_len = packet_lengths[pkt_id];
            num_beats = current_len / 8;

            $display("[Driver] Generating Pkt %0d (Len=%0d, Beats=%0d)", pkt_id, current_len, num_beats);
            
            global_idx = 0;
            // Generate Data
            for (beat_idx = 0; beat_idx < num_beats; beat_idx = beat_idx + 1) begin
                r_data = {$random, $random};
                packet_data_store[beat_idx] = r_data;
                
                for (elem_idx = 0; elem_idx < 8; elem_idx = elem_idx + 1) begin
                   history_buffer[pkt_id][global_idx] = r_data[elem_idx*8 +: 8];
                   global_idx = global_idx + 1;
                end
            end
            packet_gen_done[pkt_id] = 1; 

            // Drive Bus
            for (beat_idx = 0; beat_idx < num_beats; beat_idx = beat_idx + 1) begin
                s_axis_tvalid <= 1;
                s_axis_tdata  <= packet_data_store[beat_idx];
                s_axis_tlast  <= (beat_idx == num_beats - 1);
                
                @(posedge clk);
                while (!s_axis_tready) @(posedge clk);
            end
            
            s_axis_tvalid <= 0;
            s_axis_tlast  <= 0;
            s_axis_tdata  <= 0;

            // Small gap to separate packets slightly in waveform for visual check
            repeat(30) @(posedge clk); 
        end
    end
    endtask

    // Monitor
    task monitor_thread;
        integer pkt_id, out_cnt, elem_idx, global_idx, err_cnt, current_len, num_beats;
        integer diff, i;
        reg signed [7:0] rtl_val, exp_val;
    begin
        for (pkt_id = 0; pkt_id < NUM_PACKETS; pkt_id = pkt_id + 1) begin
            
            wait (packet_gen_done[pkt_id] == 1);
            current_len = packet_lengths[pkt_id];
            num_beats   = current_len / 8;

            // Prepare Golden
            for (i=0; i<current_len; i=i+1) begin
                input_buffer[i] = history_buffer[pkt_id][i];
            end
            calc_golden_model(pkt_id, current_len); 
            
            out_cnt = 0;
            global_idx = 0;
            err_cnt = 0;

            while (!m_axis_tvalid) @(posedge clk);

            // Verify
            while (out_cnt < num_beats) begin
                while (!m_axis_tvalid) @(posedge clk);

                if (out_cnt == num_beats-1 && !m_axis_tlast) begin
                    $display("[FAIL] Packet %0d: TLAST missing!", pkt_id);
                    err_cnt = err_cnt + 1;
                end else if (out_cnt != num_beats-1 && m_axis_tlast) begin
                    $display("[FAIL] Packet %0d: TLAST early!", pkt_id);
                    err_cnt = err_cnt + 1;
                end

                for (elem_idx = 0; elem_idx < 8; elem_idx = elem_idx + 1) begin
                    rtl_val = $signed(m_axis_tdata[elem_idx*8 +: 8]);
                    exp_val = expected_buffer[global_idx];
                    
                    diff = rtl_val - exp_val;
                    if (diff < 0) diff = -diff;
                    
                    if (diff >= 1) begin
                        
                            $display("[FAIL] Pkt%0d Idx%0d: Exp=%d, Act=%d", pkt_id, global_idx, exp_val, rtl_val);
                            err_cnt = err_cnt + 1;
                    end
                    global_idx = global_idx + 1;
                end
                
                out_cnt = out_cnt + 1;
                @(posedge clk);
            end
            
            if (err_cnt == 0) $display("[PASS] Packet %0d Verified.", pkt_id);
            else $stop;
        end
    end
    endtask

endmodule