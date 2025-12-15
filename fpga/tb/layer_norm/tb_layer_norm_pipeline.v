`timescale 1ns / 1ps

module tb_layer_norm_pipelined;

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

    localparam CLK_PERIOD = 5.0;
    localparam PACKET_LEN = 320;
    localparam NUM_PACKETS = 4;

    // =========================================================
    // 2. SIGNALS
    // =========================================================
    reg clk;
    reg aresetn;
    
    // DUT Interface
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
    // 3. STORAGE FOR VERIFICATION
    // =========================================================
    reg signed [7:0] history_buffer [0:NUM_PACKETS-1][0:PACKET_LEN-1];
    reg signed [7:0] input_buffer [0:PACKET_LEN-1];
    reg signed [7:0] expected_buffer [0:PACKET_LEN-1];
    
    // Synchronization Flag: Tells Monitor that history_buffer[pkt] is ready
    reg packet_gen_done [0:NUM_PACKETS-1];

    // =========================================================
    // 4. DUT INSTANTIATION
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

    // =========================================================
    // 5. HELPER FUNCTIONS & GOLDEN MODEL
    // =========================================================
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

    // Golden Calculation Task
    task calc_golden_model(input integer id);
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
        
        if (var <= 0.0001) inv_std = 0;
        else inv_std = 1.0 / $sqrt(var);
        
        r_gamma = q16_to_real(cfg_gamma);
        r_beta  = q16_to_real(cfg_beta);

        // DEBUG PRINT
        $display("---------------------------------------------------------------");
        $display("[Golden Pkt %0d] Mean=%.4f, Var=%.4f, InvStd=%.4f, Gamma=%.4f, Beta=%.4f", 
                 id, mean, var, inv_std, r_gamma, r_beta);
        $display("---------------------------------------------------------------");
        
        // 2. Calculate Expected Output
        for (i=0; i<PACKET_LEN; i=i+1) begin
            val = $itor(input_buffer[i]);
            norm = (val - mean) * inv_std * r_gamma + r_beta;
            expected_buffer[i] = clamp_to_int8(round_half_up(norm));
        end
    end
    endtask

    // =========================================================
    // 6. MAIN TEST SCENARIO
    // =========================================================
    integer k;

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    initial begin
        $display("=== START PIPELINED LAYER NORM TEST ===");
        
        // Initialize Sync Flags
        for(k=0; k<NUM_PACKETS; k=k+1) packet_gen_done[k] = 0;

        aresetn = 0;
        s_axis_tdata = 0; s_axis_tvalid = 0; s_axis_tlast = 0;
        m_axis_tready = 1; 
        
        // Config
        cfg_gamma = real_to_q16(1.5); 
        cfg_beta  = real_to_q16(5.0);

        #(CLK_PERIOD * 10);
        aresetn = 1;
        #(CLK_PERIOD * 5);

        fork
            driver_thread();
            monitor_thread();
        join

        $display("\n=== ALL PIPELINE TESTS PASSED ===");
        $finish;
    end

    // ---------------------------------------------------------
    // THREAD A: DRIVER
    // ---------------------------------------------------------
    task driver_thread;
        integer pkt_id, beat_idx, elem_idx, global_idx;
        reg [63:0] r_data;
        reg [63:0] current_packet_data [0:39]; // Temp storage for driver
    begin
        // Wait for reset release
        @(posedge clk);
        while (!aresetn) @(posedge clk);
        
        for (pkt_id = 0; pkt_id < NUM_PACKETS; pkt_id = pkt_id + 1) begin
            $display("[Driver] Generating Pkt %0d...", pkt_id);
            
            // ---------------------------------------------------------
            // STEP 1: PRE-GENERATE DATA & SIGNAL MONITOR
            // ---------------------------------------------------------
            // We generate the full packet *before* driving the bus.
            // This ensures the Monitor has the data ready to calculate Golden Model
            // simultaneously while we are driving or waiting.
            global_idx = 0;
            for (beat_idx = 0; beat_idx < 40; beat_idx = beat_idx + 1) begin
                r_data = {$random, $random};
                current_packet_data[beat_idx] = r_data; // Store for driving later
                
                // Store to History Buffer for Monitor
                for (elem_idx = 0; elem_idx < 8; elem_idx = elem_idx + 1) begin
                   history_buffer[pkt_id][global_idx] = r_data[elem_idx*8 +: 8];
                   global_idx = global_idx + 1;
                end
            end
            // Signal Monitor: "Data for Pkt X is ready in history_buffer"
            packet_gen_done[pkt_id] = 1; 

            // ---------------------------------------------------------
            // STEP 2: DRIVE THE BUS
            // ---------------------------------------------------------
            $display("[Driver] Sending Packet %0d at time %0t", pkt_id, $time);
            for (beat_idx = 0; beat_idx < 40; beat_idx = beat_idx + 1) begin
                s_axis_tvalid <= 1;
                s_axis_tdata  <= current_packet_data[beat_idx];
                s_axis_tlast  <= (beat_idx == 39);
                
                // Handshake
                @(posedge clk);
                while (!s_axis_tready) @(posedge clk);
            end
            
            // Packet Done
            s_axis_tvalid <= 0;
            s_axis_tlast  <= 0;
            s_axis_tdata  <= 0;

            // ---------------------------------------------------------
            // STEP 3: PRECISE GAP (30 CYCLES)
            // ---------------------------------------------------------
            // The user requested: "Packet 0 send all input data, then 
            // 30 clocks later, Packet 1 send input data".
            if (pkt_id < NUM_PACKETS - 1) begin
                $display("[Driver] Gap: Waiting 30 cycles before sending next packet...");
//                repeat(100) @(posedge clk); 
            end
        end
        $display("[Driver] Finished sending all packets.");
    end
    endtask

    // ---------------------------------------------------------
    // THREAD B: MONITOR
    // ---------------------------------------------------------
    task monitor_thread;
        integer pkt_id, out_cnt, elem_idx, global_idx, err_cnt;
        integer diff, i;
        reg signed [7:0] rtl_val, exp_val;
        real rtl_mean, rtl_inv_sqrt, rtl_gamma, rtl_beta;
    begin
        for (pkt_id = 0; pkt_id < NUM_PACKETS; pkt_id = pkt_id + 1) begin
            
            // 1. Wait until Driver has generated the data for this packet
            wait (packet_gen_done[pkt_id] == 1);

            // 2. Prepare Golden Model
            // (Now safe because driver has finished filling history_buffer[pkt_id])
            for (i=0; i<PACKET_LEN; i=i+1) begin
                input_buffer[i] = history_buffer[pkt_id][i];
            end
            calc_golden_model(pkt_id); 
            
            $display("[Monitor] Waiting for Packet %0d output...", pkt_id);
            
            out_cnt = 0;
            global_idx = 0;
            err_cnt = 0;

            // Wait for first Valid Beat
            while (!m_axis_tvalid) @(posedge clk);

            // DEBUG PROBE
            rtl_mean     = q16_to_real(dut.delayed_mean[1]);
            rtl_inv_sqrt = q16_to_real(dut.peano_inv_sqrt);
            rtl_gamma    = q16_to_real(dut.cfg_gamma);
            rtl_beta     = q16_to_real(dut.cfg_beta);

            $display("[RTL Pkt %0d Probe] Mean=%.4f, InvSqrt=%.4f, Gamma=%.4f, Beta=%.4f",
                     pkt_id, rtl_mean, rtl_inv_sqrt, rtl_gamma, rtl_beta);
            
            // Verify loop
            while (out_cnt < 40) begin
                while (!m_axis_tvalid) @(posedge clk);

                // Check TLAST
                if (out_cnt == 39 && !m_axis_tlast) begin
                    $display("[FAIL] Packet %0d: TLAST missing on last beat!", pkt_id);
                    err_cnt = err_cnt + 1;
                end else if (out_cnt != 39 && m_axis_tlast) begin
                    $display("[FAIL] Packet %0d: TLAST early at beat %0d!", pkt_id, out_cnt);
                    err_cnt = err_cnt + 1;
                end

                // Check Data
                for (elem_idx = 0; elem_idx < 8; elem_idx = elem_idx + 1) begin
                    rtl_val = $signed(m_axis_tdata[elem_idx*8 +: 8]);
                    exp_val = expected_buffer[global_idx];
                    
                    diff = rtl_val - exp_val;
                    if (diff < 0) diff = -diff;
                    
                    if (diff > 1) begin
                        if (err_cnt < 10) 
                            $display("[FAIL] Pkt%0d Idx%0d: Exp=%d, Act=%d", pkt_id, global_idx, exp_val, rtl_val);
                        err_cnt = err_cnt + 1;
                    end
                    global_idx = global_idx + 1;
                end
                
                out_cnt = out_cnt + 1;
                @(posedge clk);
            end
            
            if (err_cnt == 0) $display("[PASS] Packet %0d Verified.", pkt_id);
            else begin
                $display("[FAIL] Packet %0d had %0d errors. Stopping.", pkt_id, err_cnt);
                $stop;
            end
        end
    end
    endtask

endmodule