`timescale 1ns / 1ps

module tb_central_interconnect_system;

    // =========================================================================
    // PARAMETERS & SIGNALS
    // =========================================================================
    parameter DATA_WIDTH = 64;
    parameter CLK_PERIOD = 10; // 100 MHz
    
    // Indices based on S_COUNT = 6 (0=Dummy, 1=Ext, 2=Norm, 3=ReLU, 4=GEMM, 5=Resid)
    localparam SRC_NULL  = 3'd0;
    localparam SRC_EXT   = 3'd1;
    localparam SRC_NORM  = 3'd2;
    localparam SRC_RELU  = 3'd3;
    localparam SRC_GEMM  = 3'd4;
    localparam SRC_RESID = 3'd5;

    reg clk;
    reg rst;

    // External Interface
    reg  [DATA_WIDTH-1:0]   s_axis_ext_tdata;
    reg                     s_axis_ext_tvalid;
    wire                    s_axis_ext_tready;
    reg                     s_axis_ext_tlast;
    reg  [DATA_WIDTH/8-1:0] s_axis_ext_tkeep;

    wire [DATA_WIDTH-1:0]   m_axis_ext_tdata;
    wire                    m_axis_ext_tvalid;
    reg                     m_axis_ext_tready;
    wire                    m_axis_ext_tlast;
    wire [DATA_WIDTH/8-1:0] m_axis_ext_tkeep;

    // Control / Select Signals
    reg [2:0] sel_ext;
    reg [2:0] sel_norm;
    reg [2:0] sel_relu;
    reg [2:0] sel_gemm_a;
    reg [2:0] sel_gemm_b;
    reg [2:0] sel_resid_a;
    reg [2:0] sel_resid_b;

    // Config & Sidebands
    reg [31:0] cfg_ln_gamma;
    reg [31:0] cfg_ln_beta;
    reg start_tile;
    wire tile_done;

    // =========================================================================
    // DUT INSTANTIATION
    // =========================================================================
    axis_central_interconnect_system #(
        .DATA_WIDTH(DATA_WIDTH),
        .S_COUNT(6) // 5 + 1 Dummy
    ) dut (
        .clk(clk),
        .rst(rst),
        .s_axis_ext_tdata(s_axis_ext_tdata),
        .s_axis_ext_tvalid(s_axis_ext_tvalid),
        .s_axis_ext_tready(s_axis_ext_tready),
        .s_axis_ext_tlast(s_axis_ext_tlast),
        .s_axis_ext_tkeep(s_axis_ext_tkeep),
        .m_axis_ext_tdata(m_axis_ext_tdata),
        .m_axis_ext_tvalid(m_axis_ext_tvalid),
        .m_axis_ext_tready(m_axis_ext_tready),
        .m_axis_ext_tlast(m_axis_ext_tlast),
        .m_axis_ext_tkeep(m_axis_ext_tkeep),
        
        // Routing Controls
        .sel_ext(sel_ext),
        .sel_norm(sel_norm),
        .sel_relu(sel_relu),
        .sel_gemm_a(sel_gemm_a),
        .sel_gemm_b(sel_gemm_b),
        .sel_resid_a(sel_resid_a),
        .sel_resid_b(sel_resid_b),

        .cfg_ln_gamma(cfg_ln_gamma),
        .cfg_ln_beta(cfg_ln_beta),
        .start_tile(start_tile),
        .tile_done(tile_done)
    );

    // Clock Gen
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // =========================================================================
    // MAIN TEST SEQUENCE
    // =========================================================================
    initial begin
        // 1. Initialize
        rst = 1;
        s_axis_ext_tvalid = 0;
        s_axis_ext_tdata  = 0;
        s_axis_ext_tlast  = 0;
        s_axis_ext_tkeep  = {DATA_WIDTH/8{1'b1}};
        m_axis_ext_tready = 0;
        start_tile = 0;

        // 2. CONFIGURE ROUTING (DIAMOND TOPOLOGY)
        // ------------------------------------------------------------
        // Path A (Fast): Ext -> Resid A
        sel_resid_a = SRC_EXT; 
        
        // Path B (Slow): Ext -> Norm -> Resid B
        sel_norm    = SRC_EXT;    // Norm inputs from Ext
        sel_resid_b = SRC_NORM;   // Resid B inputs from Norm Output
        
        // Output: Resid -> Ext Output
        sel_ext     = SRC_RESID;

        // Disable unused modules (Point to Dummy/Null Source)
        sel_relu    = SRC_NULL;
        sel_gemm_a  = SRC_NULL;
        sel_gemm_b  = SRC_NULL;
        // ------------------------------------------------------------

        // Layer Norm Config (Identity for easy checking: Gamma=1, Beta=0)
        // Assuming 16.16 fixed point or similar. Adjust as per your LayerNorm IP.
        cfg_ln_gamma = 32'h00010000; 
        cfg_ln_beta  = 32'h00000000;

        // 3. Reset
        #(CLK_PERIOD*10);
        rst = 0;
        #(CLK_PERIOD*10);

        $display("Ref: Starting Diamond Topology Test...");
        
        // 4. Enable Output Sink
        m_axis_ext_tready = 1;

        // 5. Send Frame
        // Sending 8 words. 
        // Logic check: Resid Output = Input + Norm(Input)
        send_frame(8);

        // 6. Wait for completion
        wait(m_axis_ext_tlast);
        @(posedge clk);
        wait(!m_axis_ext_tvalid);
        
        #(CLK_PERIOD*20);
        $display("Ref: Test Completed.");
        $finish;
    end

    // Task: Send Frame
    task send_frame(input integer length);
        integer i;
        begin
            $display("Ref: Sending Frame of length %0d...", length);
            for (i = 0; i < length; i = i + 1) begin
                
                // DATA GENERATION
                s_axis_ext_tvalid <= 1'b1;
                // Simple pattern: 10, 20, 30...
                s_axis_ext_tdata  <= (i + 1) * 10; 
                s_axis_ext_tlast  <= (i == length - 1);

                // BACKPRESSURE HANDLING
                // We must hold the data stable until 'ready' is high.
                // In this test, 'ready' SHOULD toggle/stall because Resid B
                // waits for Layer Norm latency.
                @(posedge clk);
                while (!s_axis_ext_tready)
                    @(posedge clk);
               
                
                // If we are here, handshake occurred.
            end

            s_axis_ext_tvalid <= 0;
            s_axis_ext_tlast  <= 0;
            $display("Ref: Frame Sent.");
        end
    endtask

endmodule