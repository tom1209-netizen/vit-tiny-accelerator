`timescale 1ns / 1ps

module axis_central_interconnect_system #(
    parameter DATA_WIDTH = 64,
    parameter S_COUNT    = 5 + 1, 
    parameter M_COUNT    = 7,
    parameter SEL_WIDTH  = $clog2(S_COUNT)
)(
    input  wire                   clk,
    input  wire                   rst, // Active High System Reset

    // =========================================================================
    // EXTERNAL INTERFACES (DMA / GEMM)
    // =========================================================================
    // Source 0: Data coming INTO the system (e.g., from DMA Read)
    input  wire [DATA_WIDTH-1:0]   s_axis_ext_tdata,
    input  wire                    s_axis_ext_tvalid,
    output wire                    s_axis_ext_tready,
    input  wire                    s_axis_ext_tlast,
    input  wire [DATA_WIDTH/8-1:0] s_axis_ext_tkeep,

    // Destination 3: Data going OUT of the system (e.g., to GEMM or DMA Write)
    output wire [DATA_WIDTH-1:0]   m_axis_ext_tdata,
    output wire                    m_axis_ext_tvalid,
    input  wire                    m_axis_ext_tready,
    output wire                    m_axis_ext_tlast,
    output wire [DATA_WIDTH/8-1:0] m_axis_ext_tkeep,

    // =========================================================================
    // CONTROL CONFIGURATION
    // =========================================================================
    // Routing Controls (Scheduler drives these)
    input  wire [SEL_WIDTH-1:0]    sel_ext,
    input  wire [SEL_WIDTH-1:0]    sel_norm,
    input  wire [SEL_WIDTH-1:0]    sel_relu,
    input  wire [SEL_WIDTH-1:0]    sel_gemm_a, 
    input  wire [SEL_WIDTH-1:0]    sel_gemm_b, 
    input  wire [SEL_WIDTH-1:0]    sel_resid_a, 
    input  wire [SEL_WIDTH-1:0]    sel_resid_b, 
    
    // Layer Norm Config
    input  wire [31:0]             cfg_ln_gamma,
    input  wire [31:0]             cfg_ln_beta,
    
    // GEMM control
    input  wire start_tile,
    output wire tile_done
);

    // =========================================================================
    // 1. MAPPING DEFINITIONS
    // =========================================================================
    // Define the slot indices for the Interconnect
    
    // SOURCES (Inputs to Interconnect)
    localparam SRC_IDX_DUMMY = 0;
    localparam SRC_IDX_EXT   = 1;
    localparam SRC_IDX_NORM  = 2;
    localparam SRC_IDX_RELU  = 3;
    localparam SRC_IDX_GEMM  = 4;
    localparam SRC_IDX_RESID = 5; 

    // DESTINATIONS (Outputs from Interconnect)
    localparam DST_IDX_EXT     = 0;
    localparam DST_IDX_NORM    = 1;
    localparam DST_IDX_RELU    = 2;
    localparam DST_IDX_GEMM_A  = 3; 
    localparam DST_IDX_GEMM_B  = 4;
    localparam DST_IDX_RESID_A = 5; 
    localparam DST_IDX_RESID_B = 6;     

    // Reset conversion (LayerNorm is Active Low)
    wire aresetn = ~rst;
    wire [DATA_WIDTH/8-1:0] keep_all_ones = {DATA_WIDTH/8{1'b1}};

    // =========================================================================
    // 2. INTERNAL SIGNALS (MODULE IO)
    // =========================================================================
    
    // Layer Norm Signals
    wire [DATA_WIDTH-1:0] ln_s_tdata, ln_m_tdata;
    wire ln_s_tvalid, ln_s_tready, ln_s_tlast;
    wire ln_m_tvalid, ln_m_tready, ln_m_tlast;

    // ReLU Signals
    wire [DATA_WIDTH-1:0] relu_s_tdata, relu_m_tdata;
    wire relu_s_tvalid, relu_s_tready, relu_s_tlast;
    wire relu_m_tvalid, relu_m_tready, relu_m_tlast;
    
    // GEMM Signals
    wire [DATA_WIDTH-1:0] gemm_a_s_tdata, gemm_b_s_tdata, gemm_c_m_tdata;
    wire gemm_a_s_tvalid, gemm_a_s_tready, gemm_a_s_tlast;
    wire gemm_b_s_tvalid, gemm_b_s_tready, gemm_b_s_tlast;
    wire gemm_c_m_tvalid, gemm_c_m_tready, gemm_c_m_tlast;
    
    // Residual Signals
    wire [DATA_WIDTH-1:0] resid_a_s_tdata, resid_b_s_tdata, resid_c_m_tdata;
    wire resid_a_s_tvalid, resid_a_s_tready, resid_a_s_tlast;
    wire resid_b_s_tvalid, resid_b_s_tready, resid_b_s_tlast;
    wire resid_c_m_tvalid, resid_c_m_tready, resid_c_m_tlast;
    
    // =========================================================================
    // 3. INTERCONNECT AGGREGATION ARRAYS
    // =========================================================================
    // These wires hold the concatenated signals for the generic interconnect ports
    
    wire [S_COUNT*DATA_WIDTH-1:0]    ic_s_tdata;
    wire [S_COUNT-1:0]               ic_s_tvalid;
    wire [S_COUNT-1:0]               ic_s_tready;
    wire [S_COUNT-1:0]               ic_s_tlast;
    wire [S_COUNT*DATA_WIDTH/8-1:0]  ic_s_tkeep;

    wire [M_COUNT*DATA_WIDTH-1:0]    ic_m_tdata;
    wire [M_COUNT-1:0]               ic_m_tvalid;
    wire [M_COUNT-1:0]               ic_m_tready;
    wire [M_COUNT-1:0]               ic_m_tlast;
    wire [M_COUNT*DATA_WIDTH/8-1:0]  ic_m_tkeep; // Norm/ReLU ignore this

    // -------------------------------------------------------------------------
    // PACKING: Modules -> Interconnect Inputs (SOURCES)
    // -------------------------------------------------------------------------
    // Order: {Src3, Src2, Src1, Src0}
    
    assign ic_s_tdata = {
        resid_c_m_tdata,
        gemm_c_m_tdata,
        relu_m_tdata,       
        ln_m_tdata,        
        s_axis_ext_tdata, 
        {64{1'b0}}
    };

    assign ic_s_tvalid = {
        resid_c_m_tvalid,
        gemm_c_m_tvalid,
        relu_m_tvalid,     
        ln_m_tvalid,        
        s_axis_ext_tvalid,
        1'b0   
    };

    assign ic_s_tlast = {
        resid_c_m_tlast,
        gemm_c_m_tlast,
        relu_m_tlast,       
        ln_m_tlast,        
        s_axis_ext_tlast,   
        1'b0
    };

    assign ic_s_tkeep = {
        keep_all_ones,
        keep_all_ones,      
        keep_all_ones,     
        keep_all_ones,      
        s_axis_ext_tkeep,    
        8'd0
    };

    // Unpacking Ready Signals
    assign s_axis_ext_tready = ic_s_tready[SRC_IDX_EXT];
    assign ln_m_tready       = ic_s_tready[SRC_IDX_NORM];
    assign relu_m_tready     = ic_s_tready[SRC_IDX_RELU];
    assign gemm_c_m_tready   = ic_s_tready[SRC_IDX_GEMM];
    assign resid_c_m_tready  = ic_s_tready[SRC_IDX_RESID];

    // -------------------------------------------------------------------------
    // UNPACKING: Interconnect Outputs -> Modules (DESTINATIONS)
    // -------------------------------------------------------------------------
    
    // Dest 0: External Output
    assign m_axis_ext_tdata  = ic_m_tdata[DST_IDX_EXT*DATA_WIDTH +: DATA_WIDTH];
    assign m_axis_ext_tvalid = ic_m_tvalid[DST_IDX_EXT];
    assign m_axis_ext_tlast  = ic_m_tlast[DST_IDX_EXT];
    assign m_axis_ext_tkeep  = ic_m_tkeep[DST_IDX_EXT*(DATA_WIDTH/8) +: DATA_WIDTH/8];
    assign ic_m_tready[DST_IDX_EXT] = m_axis_ext_tready;
    
    // Dest 1: Layer Norm Input
    assign ln_s_tdata   = ic_m_tdata[DST_IDX_NORM*DATA_WIDTH +: DATA_WIDTH];
    assign ln_s_tvalid  = ic_m_tvalid[DST_IDX_NORM];
    assign ln_s_tlast   = ic_m_tlast[DST_IDX_NORM];
    assign ic_m_tready[DST_IDX_NORM] = ln_s_tready;

    // Dest 2: ReLU Input
    assign relu_s_tdata  = ic_m_tdata[DST_IDX_RELU*DATA_WIDTH +: DATA_WIDTH];
    assign relu_s_tvalid = ic_m_tvalid[DST_IDX_RELU];
    assign relu_s_tlast  = ic_m_tlast[DST_IDX_RELU];
    assign ic_m_tready[DST_IDX_RELU] = relu_s_tready;
    
    // Dest 3: GEMM_A Input
    assign gemm_a_s_tdata = ic_m_tdata[DST_IDX_GEMM_A*DATA_WIDTH +: DATA_WIDTH];
    assign gemm_a_s_tvalid = ic_m_tvalid[DST_IDX_GEMM_A];
    assign gemm_a_s_tlast = ic_m_tlast[DST_IDX_GEMM_A];
    assign ic_m_tready[DST_IDX_GEMM_A] = gemm_a_s_tready;
    
    // Dest 3: GEMM_B Input
    assign gemm_b_s_tdata = ic_m_tdata[DST_IDX_GEMM_B*DATA_WIDTH +: DATA_WIDTH];
    assign gemm_b_s_tvalid = ic_m_tvalid[DST_IDX_GEMM_B];
    assign gemm_b_s_tlast = ic_m_tlast[DST_IDX_GEMM_B];
    assign ic_m_tready[DST_IDX_GEMM_B] = gemm_b_s_tready;
    
     // Dest 4: RESID_A Input
    assign resid_a_s_tdata = ic_m_tdata[DST_IDX_RESID_A*DATA_WIDTH +: DATA_WIDTH];
    assign resid_a_s_tvalid = ic_m_tvalid[DST_IDX_RESID_A];
    assign resid_a_s_tlast = ic_m_tlast[DST_IDX_RESID_A];
    assign ic_m_tready[DST_IDX_RESID_A] = resid_a_s_tready;
    
    // Dest 5: RESID_B Input
    assign resid_b_s_tdata = ic_m_tdata[DST_IDX_RESID_B*DATA_WIDTH +: DATA_WIDTH];
    assign resid_b_s_tvalid = ic_m_tvalid[DST_IDX_RESID_B];
    assign resid_b_s_tlast = ic_m_tlast[DST_IDX_RESID_B];
    assign ic_m_tready[DST_IDX_RESID_B] = resid_b_s_tready;
    
    // =========================================================================
    // 4. MODULE INSTANTIATION
    // =========================================================================

    // ---------------------------------------------------------
    // A. CENTRAL INTERCONNECT
    // ---------------------------------------------------------
    // Note: Assuming the interconnect has been updated to accept 'sel_relu'
    // or mapped appropriately.
    axis_central_interconnect #(
        .S_COUNT(S_COUNT),
        .M_COUNT(M_COUNT),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_interconnect (
        .clk(clk),
        .rst(rst),
        
        // Aggregated Source Ports
        .s_axis_tdata(ic_s_tdata),
        .s_axis_tvalid(ic_s_tvalid),
        .s_axis_tready(ic_s_tready),
        .s_axis_tlast(ic_s_tlast),
        

        // Aggregated Destination Ports
        .m_axis_tdata(ic_m_tdata),
        .m_axis_tvalid(ic_m_tvalid),
        .m_axis_tready(ic_m_tready),
        .m_axis_tlast(ic_m_tlast),
        .m_axis_tkeep(ic_m_tkeep),

        // Controls
        .sel_ext(sel_ext),
        .sel_norm(sel_norm),
        .sel_relu(sel_relu),
        .sel_gemm_a(sel_gemm_a),   
        .sel_gemm_b(sel_gemm_b),
        .sel_resid_a(sel_resid_a),   
        .sel_resid_b(sel_resid_b)        
    );

    // ---------------------------------------------------------
    // 1. LAYER NORM
    // ---------------------------------------------------------
    layer_norm #(
        .BEAT_WIDTH(DATA_WIDTH), // Ensure widths match (64)
        .PARALLEL_N(8),          // 64 bits / 8 bits per elem = 8
        .FIFO_DEPTH(512)
    ) u_layer_norm (
        .clk(clk),
        .aresetn(aresetn),       // Inverted rst

        // Input from Interconnect Dest 1
        .s_axis_tdata(ln_s_tdata),
        .s_axis_tvalid(ln_s_tvalid),
        .s_axis_tlast(ln_s_tlast),
        .s_axis_tready(ln_s_tready),

        // Config
        .cfg_gamma(cfg_ln_gamma),
        .cfg_beta(cfg_ln_beta),

        // Output to Interconnect Src 1
        .m_axis_tdata(ln_m_tdata),
        .m_axis_tvalid(ln_m_tvalid),
        .m_axis_tlast(ln_m_tlast),
        .m_axis_tready(ln_m_tready)
    );

    // ---------------------------------------------------------
    // 2. RELU
    // ---------------------------------------------------------
    relu #(
        .DATA_WIDTH(DATA_WIDTH),
        .DATA_TYPE(8)            // 8-bit quantization
    ) u_relu (
        // Input from Interconnect Dest 2
        .s_axis_tdata(relu_s_tdata),
        .s_axis_tvalid(relu_s_tvalid),
        .s_axis_tlast(relu_s_tlast),
        .s_axis_tready(relu_s_tready),

        // Output to Interconnect Src 2
        .m_axis_tdata(relu_m_tdata),
        .m_axis_tvalid(relu_m_tvalid),
        .m_axis_tlast(relu_m_tlast),
        .m_axis_tready(relu_m_tready)
    );
    
    // ---------------------------------------------------------
    // 3. GEMM
    // ---------------------------------------------------------
    gemm_core_top #(
        .AXIS_DATA_WIDTH(64),
        .DATA_WIDTH(8),
        .ACC_WIDTH(32),
        .ARRAY_SIZE(8)
    ) u_gemm (
        .aclk(clk),
        .aresetn(aresetn),
        
        .start_tile(start_tile),
        .tile_done(tile_done),
        // Input from Interconnect Dest 3
        .s_axis_a_tdata(gemm_a_s_tdata),
        .s_axis_a_tvalid(gemm_a_s_tvalid),
        .s_axis_a_tlast(gemm_a_s_tlast),
        .s_axis_a_tready(gemm_a_s_tready),
        
        // Input from Interconnect Dest 4
        .s_axis_b_tdata(gemm_b_s_tdata),
        .s_axis_b_tvalid(gemm_b_s_tvalid),
        .s_axis_b_tlast(gemm_b_s_tlast),
        .s_axis_b_tready(gemm_b_s_tready),
        
        // Output to Interconenct Src 3
        .m_axis_out_tdata(gemm_c_m_tdata),
        .m_axis_out_tvalid(gemm_c_m_tvalid),
        .m_axis_out_tlast(gemm_c_m_tlast),
        .m_axis_out_tready(gemm_c_m_tready)
    );
    
    residual_add #(
        .DATA_WIDTH(DATA_WIDTH),
        .ELEM_WIDTH(8)
    ) u_resid (
        .clk(clk),
        .rst_n(aresetn),
        // Input from Interconnect Dest 5
        .s_axis_a_tdata(resid_a_s_tdata),
        .s_axis_a_tvalid(resid_a_s_tvalid),
        .s_axis_a_tlast(resid_a_s_tlast),
        .s_axis_a_tready(resid_a_s_tready),
        
        // Input from Interconnect Dest 6
        .s_axis_b_tdata(resid_b_s_tdata),
        .s_axis_b_tvalid(resid_b_s_tvalid),
        .s_axis_b_tlast(resid_b_s_tlast),
        .s_axis_b_tready(resid_b_s_tready),
        
        // Output to Interconnect Src 4
        .m_axis_tdata(resid_c_m_tdata),
        .m_axis_tvalid(resid_c_m_tvalid),
        .m_axis_tlast(resid_c_m_tlast),
        .m_axis_tready(resid_c_m_tready)  
 
 
    );
endmodule