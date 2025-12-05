`timescale 1ns / 1ps

module tb_relu_unit;

    parameter DATA_WIDTH = 64;
    parameter DATA_TYPE  = 8;
    parameter NUM_ELEMENTS = DATA_WIDTH / DATA_TYPE;

    reg                   aclk;
    reg                   aresetn;
    
    reg [DATA_WIDTH-1:0]  s_axis_tdata;
    reg                   s_axis_tvalid;
    reg                   s_axis_tlast;
    wire                  s_axis_tready;

    wire [DATA_WIDTH-1:0] m_axis_tdata;
    wire                  m_axis_tvalid;
    wire                  m_axis_tlast;
    reg                   m_axis_tready;

    // helper variables
    integer i, k;
    reg signed [DATA_TYPE-1:0] in_byte;
    reg signed [DATA_TYPE-1:0] out_byte;
    reg signed [DATA_TYPE-1:0] expected_byte;
    reg error_flag;

    relu_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .DATA_TYPE(DATA_TYPE)
    ) dut (
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tready(m_axis_tready)
    );

    initial begin
        aclk = 0;
        forever #5 aclk = ~aclk;
    end

    task verify_result;
        input [DATA_WIDTH-1:0] input_data;
        input [DATA_WIDTH-1:0] output_data;
        begin
            error_flag = 0;
            for (i = 0; i < NUM_ELEMENTS; i = i + 1) begin
                in_byte  = input_data[i*8 +: 8];
                out_byte = output_data[i*8 +: 8];
                
                expected_byte = (in_byte[7] == 1'b1) ? 0 : in_byte;

                if (out_byte !== expected_byte) begin
                    $display("[ERROR] Byte %0d: Input=%d, Output=%d, Expected=%d", 
                             i, in_byte, out_byte, expected_byte);
                    error_flag = 1;
                end
            end
            
            if (error_flag == 0) 
                $display("[PASS] Input Hex: %h -> Output Hex: %h", input_data, output_data);
        end
    endtask

    initial begin
        // --- INIT ---
        $display("=== START EXTENDED SIMULATION ===");
        s_axis_tvalid = 0;
        s_axis_tlast  = 0;
        s_axis_tdata  = 0;
        m_axis_tready = 1; 
        
        #20; 

        // ============================================================
        // TEST CASE 1: Corner Cases 
        // ============================================================
        $display("\n--- Test Case 1: Corner Cases ---");
        
        // Beat 1: 
        @(posedge aclk);
        s_axis_tvalid = 1;
        s_axis_tdata  = {8{8'sd0}};
        #1; verify_result(s_axis_tdata, m_axis_tdata);

        // Beat 2: 
        @(posedge aclk);
        s_axis_tdata  = {8{8'sd127}}; 
        #1; verify_result(s_axis_tdata, m_axis_tdata);

        // Beat 3: 
        @(posedge aclk);
        s_axis_tdata  = {8{-8'sd128}}; 
        #1; verify_result(s_axis_tdata, m_axis_tdata);

        // Beat 4: 
        @(posedge aclk);
        s_axis_tdata  = {8'sd1, -8'sd1, 8'sd1, -8'sd1, 8'sd1, -8'sd1, 8'sd1, -8'sd1}; 
        #1; verify_result(s_axis_tdata, m_axis_tdata);

        // ============================================================
        // TEST CASE 2: Random Stream 
        // ============================================================
        $display("\n--- Test Case 2: Random Stream (20 Beats) ---");
        
        for (k = 0; k < 20; k = k + 1) begin
            @(posedge aclk); 
            
            s_axis_tvalid = 1;
            
            
            s_axis_tdata = {$random, $random}; 
            
           
            s_axis_tlast = (k % 5 == 4) ? 1'b1 : 1'b0;

            
            #1; 
            verify_result(s_axis_tdata, m_axis_tdata);
        end

        @(posedge aclk);
        s_axis_tvalid = 0;
        s_axis_tlast  = 0;

        // ============================================================
        // TEST CASE 3: Back-pressure 
        // ============================================================
        $display("\n--- Test Case 3: Back-pressure Check ---");
        @(posedge aclk);
        s_axis_tvalid = 1;
        s_axis_tdata  = {64{1'b1}}; 
        m_axis_tready = 0;          

        #1; 
        if (s_axis_tready == 0) 
            $display("[PASS] Back-pressure propagated successfully.");
        else 
            $display("[FAIL] s_axis_tready is HIGH while m_axis_tready is LOW.");

  
        @(posedge aclk);
        m_axis_tready = 1;
        s_axis_tvalid = 0;

        #50;
        $display("\n=== SIMULATION FINISHED ===");
        $finish;
    end

endmodule