//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/09/2025 10:24:31 AM
// Design Name: 
// Module Name: tb_norm_unit
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps


module tb_norm_unit;

    // Parameters
    parameter integer DATA_WIDTH = 64;  // 8 lanes x 8-bit
    parameter integer N_LANES    = 8;    // DATA_WIDTH/8

    // DUT signals
    reg                      aclk;
    reg                      aresetn;

    reg  [DATA_WIDTH-1:0]    s_axis_tdata;
    reg                      s_axis_tvalid;
    reg                      s_axis_tlast;
    wire                     s_axis_tready;

    wire [DATA_WIDTH-1:0]    m_axis_tdata;
    wire                     m_axis_tvalid;
    wire                     m_axis_tlast;
    reg                      m_axis_tready;

    // Instantiate the DUT
    norm_unit uut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tready(m_axis_tready)
    );

    // Clock generation
    always begin
        aclk = 1'b0; #5;
        aclk = 1'b1; #5;
    end

    // Đặt ở đầu testbench, trước "initial begin"
    task run_test_case;
        input integer id;
        input [63:0] tdata_in;
        input [63:0] expected;
        begin
            #20;
            aresetn = 1'b1;
            m_axis_tready = 1'b1;
    
            #20;
            s_axis_tdata  = tdata_in;
            s_axis_tvalid = 1'b1;
            s_axis_tlast  = 1'b1;
    
            wait(s_axis_tready == 1'b1);
            #10 s_axis_tvalid = 1'b0;
    
            wait(m_axis_tvalid == 1'b1);
            #5;
            $display("\n============================================================");
            $display(" Test Case %0d", id);
            $display("------------------------------------------------------------");
            $display("  Input     : %h", tdata_in);
            $display("  Expected  : %h", expected);
            $display("  Output    : %h", m_axis_tdata);
            if (m_axis_tdata === expected)
                $display("  Result    : PASS");
            else
                $display("  Result    : FAIL");
            $display("============================================================\n");
        end
    endtask

    // Pretty print function
    task automatic print_case;
        input integer id;
        input [63:0] in_val;
        input [63:0] expected;
        input [63:0] out_val;
        begin
            $display("\n============================================================");
            $display(" Test Case %0d", id);
            $display("------------------------------------------------------------");
            $display("  Input     : %h", in_val);
            $display("  Expected  : %h", expected);
            $display("  Output    : %h", out_val);
            if (out_val === expected)
                $display("  Result    : PASS");
            else
                $display("  Result    : FAIL");
            $display("============================================================\n");
        end
    endtask

    // Stimulus
    initial begin
        // Initialize
        aresetn = 1'b0;
        s_axis_tdata = 0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        m_axis_tready = 0;

        // Reset first
        #20;
        aresetn = 1'b1;
        m_axis_tready = 1'b1; // Set m_axis_tready to 1 to receive data

        // how to use the testcase
        // run_test_case(N0 of testcase, input, expected output)
        run_test_case(1,     64'h0102030405060708,   64'hFEFFFF0000010102);
        run_test_case(2,     64'h7F00FF0001FE0008,   64'h0300000000000000);
        run_test_case(3,     64'h807F80807F80807F,   64'hFF01FFFF01FFFF01);
        run_test_case(4,     64'h0101010101010101,   64'h0000000000000000);
        run_test_case(5,     64'hFFFFFFFFFFFFFFFF,   64'h0000000000000000);
        run_test_case(6,     64'h0000000000000000,   64'h0000000000000000);
        run_test_case(7,     64'h0807060504030201,   64'h0201010000FFFFFE);
        run_test_case(8,     64'h0AF614EC1EE228D8,   64'h000001FF01FF01FF);
        run_test_case(9,     64'h645A50463C32281E,   64'h0201010000FFFFFE);
        run_test_case(10,    64'hCED8E2ECF6000A14,   64'hFEFFFF0000010102);
        run_test_case(11,    64'h0C0E10121416181A,   64'hFEFFFF0000010102);
        run_test_case(12,    64'h809CB0C4D8EC0014,   64'hFEFFFF0000010101);
        run_test_case(13,    64'h7F7F7E7D7C7B7A79,   64'h0101010000FFFFFE);
        run_test_case(14,    64'hFF01FF01FF01FF01,   64'hFF01FF01FF01FF01);
        run_test_case(15,    64'h0505050506060606,   64'hFFFFFFFF01010101);
        run_test_case(16,    64'h323C46505A646E78,   64'hFEFFFF0000010102);
        run_test_case(17,    64'hC0E0002040607F80,   64'hFFFF0000010101FE);
        run_test_case(18,    64'h7F00000000000080,   64'h02000000000000FE);
        run_test_case(19,    64'h0A141E28323C4650,   64'hFEFFFF0000010102);
        run_test_case(20,    64'h9CA6B0BAC4CED8E2,   64'hFEFFFF0000010102);

        // Done
        #30 $display("\nAll test cases completed.\n");
        $finish;
    end

    // Monitor output data
    always @(posedge aclk) begin
        if (m_axis_tvalid && m_axis_tready)
            $display(">> [%0t ns] Output Data: %h (Last=%b)", $time, m_axis_tdata, m_axis_tlast);
    end

endmodule

//        // TC backup
//        // ============================================================
//        // Test Case 1 : [1 2 3 4 5 6 7 8]
//        // Expected Output: FEFEFFFFFF010202
//        // ============================================================
        
//        #20;
//        aresetn = 1'b1;
//        m_axis_tready = 1'b1; // Set m_axis_tready to 1 to receive data

//        #10 s_axis_tdata = 64'h0102030405060708;
//        s_axis_tvalid = 1;
//        s_axis_tlast  = 1;
//        wait(s_axis_tready);  // Wait for ready signal
//        #10 s_axis_tvalid = 0;

//        wait(m_axis_tvalid);  // Wait for valid output
//        #5  print_case(1, s_axis_tdata, 64'hFEFFFF0000010102, m_axis_tdata);

//        // ============================================================
//        // Test Case 2 : [127 0 -1 0 1 -2 0 8]
//        // Expected Output: 0200000000000000
//        // ============================================================
        
//        #20;
//        aresetn = 1'b1;
//        m_axis_tready = 1'b1;
        
//        #20 s_axis_tdata = 64'h7F00FF000100FE00;
//        s_axis_tvalid = 1;
//        s_axis_tlast  = 1;
//        wait(s_axis_tready);
//        #10 s_axis_tvalid = 0;

//        wait(m_axis_tvalid == 1);
//        #5  print_case(2, s_axis_tdata, 64'h0300000000000000, m_axis_tdata);

//        // ============================================================
//        // Test Case 3 : [-128 127 -128 -128 127 -128 -128 127]
//        // Expected Output: FF01FFFF01FFFF01
//        // ============================================================
        
//        #20;
//        aresetn = 1'b1;
//        m_axis_tready = 1'b1;
        
//        #20 s_axis_tdata = 64'h807F80807F80807F;
//        s_axis_tvalid = 1;
//        s_axis_tlast  = 1;
//        wait(s_axis_tready);
//        #10 s_axis_tvalid = 0;

//        wait(m_axis_tvalid);
//        #5  print_case(3, s_axis_tdata, 64'hFF01FFFF01FFFF01, m_axis_tdata);

