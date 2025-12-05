`timescale 1ns / 1ps

module tb_layer_norm_top;

    // =========================================================
    // 1. PARAMETERS
    // =========================================================
    parameter DATA_WIDTH   = 8;
    parameter PARALLEL_N   = 8;
    parameter BEAT_WIDTH   = 64;   // 8 * 8
    parameter FIFO_DEPTH   = 512;
    parameter STAT_WIDTH   = 32;   // Q16.16
    parameter SUM_WIDTH    = 18;
    parameter SUM_SQ_WIDTH = 24;
    parameter M_BITS       = 12;

    localparam CLK_PERIOD = 8.0;

    reg clk;
    reg aresetn;

    // --- DUT Interface Signals ---
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

    // =========================================================
    // 2. DUT INSTANTIATION
    // =========================================================
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
        
        // Input Stream
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        
        // Parameters
        .cfg_gamma(cfg_gamma),
        .cfg_beta(cfg_beta),
        
        // Output Stream
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tready(m_axis_tready)
    );

    // =========================================================
    // 3. GOLDEN MODEL RESOURCES
    // =========================================================
    localparam PACKET_LEN = 320; 
    reg signed [7:0] input_buffer [0:PACKET_LEN-1];
    reg signed [7:0] expected_buffer [0:PACKET_LEN-1];
    
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

    function integer round_half_away_from_zero(input real val);
        real abs_val;
        integer abs_rounded;
    begin
        // 1. Get Absolute value
        abs_val = (val < 0) ? -val : val;
        
        // 2. Round Magnitude (Standard floor(x+0.5))
        abs_rounded = $floor(abs_val + 0.5);
        
        // 3. Restore Sign
        round_half_away_from_zero = (val < 0) ? -abs_rounded : abs_rounded;
    end
    endfunction

    // Golden Calculation Task
    task calc_golden_model;
        integer i;
        real sum, sum_sq, mean, var, inv_std, val, norm;
        real r_gamma, r_beta;
        begin
            sum = 0; sum_sq = 0;
            // 1. Calculate Stats
            for (i=0; i<PACKET_LEN; i=i+1) begin
                val = $itor(input_buffer[i]);
                sum = sum + val;
                sum_sq = sum_sq + (val*val);
            end
            
            mean = sum / PACKET_LEN;
            var  = (sum_sq / PACKET_LEN) - (mean * mean);
            
            if (var == 0) inv_std = 0;
            else inv_std = 1.0 / $sqrt(var);
            
            r_gamma = q16_to_real(cfg_gamma);
            r_beta  = q16_to_real(cfg_beta);
            
            $display("[Golden] Mean=%.4f, Var=%.4f, InvStd=%.4f", mean, var, inv_std);
            
            // 2. Calculate Expected Output
            for (i=0; i<PACKET_LEN; i=i+1) begin
                val = $itor(input_buffer[i]);
                norm = (val - mean) * inv_std * r_gamma + r_beta;
                expected_buffer[i] = clamp_to_int8(round_half_away_from_zero(norm));
            end
        end
    endtask

    // =========================================================
    // 4. MAIN TEST SCENARIO
    // =========================================================
    integer beat_idx, elem_idx, global_idx;
    integer err_cnt, out_cnt;
    integer pkt_id;
    reg [63:0] r_data;
    reg signed [7:0] rtl_val, exp_val;
    integer diff;

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    initial begin
        $display("=== START LAYER NORM TOP LEVEL TEST ===");
        
        // Initialize Signals
        aresetn = 0;
        s_axis_tdata = 0; s_axis_tvalid = 0; s_axis_tlast = 0;
        m_axis_tready = 1; // Always ready to receive output
        
        #(CLK_PERIOD * 10);
        aresetn = 1;
        #(CLK_PERIOD * 5);
        
        // --- Loop through Test Cases ---
        for (pkt_id = 0; pkt_id < 4; pkt_id = pkt_id + 1) begin
            // 1. Set Configuration
            case (pkt_id)
                0: begin cfg_gamma = real_to_q16(1.0); cfg_beta = real_to_q16(0.0);   end 
                1: begin cfg_gamma = real_to_q16(0.5); cfg_beta = real_to_q16(10.0);  end 
                2: begin cfg_gamma = real_to_q16(-1.0); cfg_beta = real_to_q16(5.0);  end 
                3: begin cfg_gamma = real_to_q16(2.0); cfg_beta = real_to_q16(-20.0); end 
            endcase
            
            $display("\n[Time %0t] Processing Packet %0d", $time, pkt_id);
            global_idx = 0;
            
            // 2. DRIVER
            // Sync to clock edge before starting (No #1 delay)
            @(posedge clk);
            
            for (beat_idx = 0; beat_idx < 40; ) begin
                // Only generate new data if we are advancing (or first iter)
                if (beat_idx == 0 || s_axis_tready) begin
                    r_data = {$random, $random};
                    
                    // Store for Golden Model
                    for (elem_idx = 0; elem_idx < 8; elem_idx = elem_idx + 1) begin
                        input_buffer[global_idx] = r_data[elem_idx*8 +: 8];
                        global_idx = global_idx + 1;
                    end
                    
                    // Drive Signals using NBA (updates at end of this time slot)
                    s_axis_tdata  <= r_data;
                    s_axis_tvalid <= 1;
                    s_axis_tlast  <= (beat_idx == 39);
                end
                
                // Wait for next edge (DUT samples here)
                @(posedge clk);
                
                // Check if the drive from *previous* cycle was accepted
                // (Sampling the 'ready' that was valid at this rising edge)
                if (s_axis_tready) begin
                     beat_idx = beat_idx + 1;
                end
                // If not ready, loop repeats, keeping tvalid/tdata/tlast stable
            end
            
            // Packet Done: Drop Valid (NBA)
            s_axis_tvalid <= 0;
            s_axis_tlast  <= 0;
            
            $display("[Time %0t] Data Sent. Waiting for Output...", $time);
            calc_golden_model();
            
            // 3. MONITOR
            out_cnt = 0;
            global_idx = 0;
            err_cnt = 0;
            
            fork : verify_packet
                begin
                    while (out_cnt < 40) begin
                        // Wait for Valid Output
                        while (!m_axis_tvalid) @(posedge clk);
                        
                        // Check TLAST on final beat
                        if (out_cnt == 39 && !m_axis_tlast) begin
                            $display("[FAIL] TLAST missing on final beat!");
                            err_cnt = err_cnt + 1;
                        end else if (out_cnt != 39 && m_axis_tlast) begin
                            $display("[FAIL] TLAST asserted too early at beat %0d!", out_cnt);
                            err_cnt = err_cnt + 1;
                        end
                        
                        // Check Data
                        for (elem_idx = 0; elem_idx < 8; elem_idx = elem_idx + 1) begin
                            rtl_val = $signed(m_axis_tdata[elem_idx*8 +: 8]);
                            exp_val = expected_buffer[global_idx];
                            
                            diff = rtl_val - exp_val;
                            if (diff < 0) diff = -diff;
                            
                            // Tolerance Check (Allow +/- 1 error)
                            if (diff > 1) begin 
//                                if (err_cnt < 10) 
                                    $display("[FAIL] Idx%0d: Exp=%d, Act=%d (Diff=%d)", global_idx, exp_val, rtl_val, diff);
                                err_cnt = err_cnt + 1;
                            end
                            global_idx = global_idx + 1;
                        end
                        
                        out_cnt = out_cnt + 1;
                        @(posedge clk);
                    end
                    disable verify_packet;
                end
                
                // Timeout Watchdog
                begin
                    #(CLK_PERIOD * 3000);
                    $display("[FAIL] Timeout waiting for output on Packet %0d!", pkt_id);
                    $finish;
                end
            join
            
            if (err_cnt == 0) $display("[PASS] Packet %0d OK.", pkt_id);
            else $display("[FAIL] Packet %0d Failed with %0d errors.", pkt_id, err_cnt);
            
            // Gap between packets
            #(CLK_PERIOD * 50);
        end
        
        $display("\n===========================================================");
        $display(" FINAL RESULT: ALL TESTS FINISHED");
        $display("===========================================================");
        $finish;
    end

endmodule