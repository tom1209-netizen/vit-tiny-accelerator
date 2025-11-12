//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/07/2025 09:25:24 AM
// Design Name: 
// Module Name: tb_gelu_pwl
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

module tb_gelu_pwl;

    // Parameters
    parameter integer DATA_WIDTH = 64;  // 8 lanes x 8-bit

    // Testbench Signals
    reg                      aclk;
    reg                      aresetn;

    // AXI4-Stream interface
    reg  [DATA_WIDTH-1:0]    s_axis_tdata;
    reg                      s_axis_tvalid;
    reg                      s_axis_tlast;
    wire                     s_axis_tready;

    wire [DATA_WIDTH-1:0]    m_axis_tdata;
    wire                     m_axis_tvalid;
    wire                     m_axis_tlast;
    reg                      m_axis_tready;

    // Instantiate the gelu_pwl module
    gelu_pwl #(
        .DATA_WIDTH(DATA_WIDTH)
    ) uut (
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

    // Task to pretty print test result
    task automatic print_result;
        input integer id;
        input [63:0] input_val;
        input [63:0] expected_val;
        input [63:0] output_val;
        begin
            $display("\n============================================================");
            $display(" Test Case %0d", id);
            $display("------------------------------------------------------------");
            $display("  Input     : %h", input_val);
            $display("  Expected  : %h", expected_val);
            $display("  Output    : %h", output_val);
            if (output_val === expected_val)
                $display("  Result    : PASSED");
            else
                $display("  Result    : FAILED");
            $display("============================================================\n");
        end
    endtask
    
    // Task for running a single test case
    task automatic run_test_case;
        input integer test_case_id;
        input [63:0] input_data;
        input [63:0] expected_output;
        begin
            #20;
            aresetn = 1'b1;
            m_axis_tready = 1'b1;
            
            #10 s_axis_tdata = input_data;
            s_axis_tvalid = 1'b1;
            s_axis_tlast  = 1'b1;
            wait(s_axis_tready); 
            #10 s_axis_tvalid = 0;  // Stop sending data
            
            wait(m_axis_tvalid);   // Wait for output to be valid
            #5 print_result(test_case_id, input_data, expected_output, m_axis_tdata);
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

        // Reset
        #10;
        aresetn = 1'b1;
        m_axis_tready = 1'b1;
        
        // ---- Run Test Cases ----
        run_test_case(1,    64'hffffffffffffffff,   64'h0000000000000000);  // Test Case 1: -1
        run_test_case(2,    64'h8000000000000000,   64'h0000000000000000);  // Test Case 2: -128
        run_test_case(3,    64'h0000000000000001,   64'h0000000000000001);  // Test Case 3: +1
        run_test_case(4,    64'h7f00000000000000,   64'h7f00000000000000);  // Test Case 4: +127
        run_test_case(5,    64'h8000250001002005,   64'h0000250001002005);  // Test Case 5: mix values
        run_test_case(6,    64'h7f00110004002005,   64'h7f00110004002005);  // Test Case 6: all positives
        run_test_case(7,    64'h7f0085009500FA00,   64'h7f00000000000000);  // Test Case 7: mix positives and negatives
        run_test_case(8,    64'hA500110044008899,   64'h0000110044000000);  // Test Case 8: mix values
        run_test_case(9,    64'h0809008000FF00A9,   64'h0809000000000000);  // Test Case 9: some negatives
        run_test_case(10,   64'hFF00FF00FF00FF00,   64'h0000000000000000);  // Test Case 10: alternating negatives

        // Done
        #10 $display("\nAll test cases completed.\n");
        #10 $finish;
    end

    // Monitor live output
    always @(posedge aclk) begin
        if (m_axis_tvalid && m_axis_tready)
            $display(">> Output Data: %h (Last=%b)", m_axis_tdata, m_axis_tlast);
    end

endmodule

