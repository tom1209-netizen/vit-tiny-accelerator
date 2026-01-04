`timescale 1ns / 1ps

module axis_central_interconnect #
(
    parameter S_COUNT = 6,      // 5 Sources + 1 Dummy
    parameter M_COUNT = 7,      // 7 Destinations
    parameter DATA_WIDTH = 64,
    parameter FIFO_DEPTH = 64   // Size of buffer for each output
)
(
    input  wire                             clk,
    input  wire                             rst,

    // SOURCE INPUTS
    input  wire [S_COUNT*DATA_WIDTH-1:0]    s_axis_tdata,
    input  wire [S_COUNT-1:0]               s_axis_tvalid,
    output wire [S_COUNT-1:0]               s_axis_tready,
    input  wire [S_COUNT-1:0]               s_axis_tlast,

    // DESTINATION OUTPUTS
    output wire [M_COUNT*DATA_WIDTH-1:0]    m_axis_tdata,
    output wire [M_COUNT-1:0]               m_axis_tvalid,
    input  wire [M_COUNT-1:0]               m_axis_tready,
    output wire [M_COUNT-1:0]               m_axis_tlast,
    output wire [M_COUNT*DATA_WIDTH/8-1:0]  m_axis_tkeep,

    // CONTROLS
    input  wire [$clog2(S_COUNT)-1:0]       sel_ext,
    input  wire [$clog2(S_COUNT)-1:0]       sel_norm,
    input  wire [$clog2(S_COUNT)-1:0]       sel_relu, 
    input  wire [$clog2(S_COUNT)-1:0]       sel_gemm_a,
    input  wire [$clog2(S_COUNT)-1:0]       sel_gemm_b,
    input  wire [$clog2(S_COUNT)-1:0]       sel_resid_a,
    input  wire [$clog2(S_COUNT)-1:0]       sel_resid_b
);

    // [1] MAPPING CONFIGURATION
    localparam IDX_EXT       = 0;
    localparam IDX_NORM      = 1;
    localparam IDX_RELU      = 2;
    localparam IDX_GEMM_A    = 3;
    localparam IDX_GEMM_B    = 4;
    localparam IDX_RESID_A   = 5;
    localparam IDX_RESID_B   = 6;

    localparam SEL_WIDTH = $clog2(S_COUNT) > 0 ? $clog2(S_COUNT) : 1;

    wire [SEL_WIDTH-1:0] selects [M_COUNT-1:0];
    assign selects[IDX_EXT]     = sel_ext;
    assign selects[IDX_NORM]    = sel_norm;
    assign selects[IDX_RELU]    = sel_relu;
    assign selects[IDX_GEMM_A]  = sel_gemm_a;
    assign selects[IDX_GEMM_B]  = sel_gemm_b;
    assign selects[IDX_RESID_A] = sel_resid_a;
    assign selects[IDX_RESID_B] = sel_resid_b;

    // [2] AGGREGATE ARRAY
    wire [S_COUNT-1:0] mux_ready_agg [M_COUNT-1:0];

    // [3] GENERATE MUX + FIFO PAIRS
    genvar m;
    generate
        for (m = 0; m < M_COUNT; m = m + 1) begin : dest_channels
            
            // Internal wires between Static Mux and FIFO
            wire [DATA_WIDTH-1:0]   int_tdata;
            wire                    int_tvalid;
            wire                    int_tready; // Driven by FIFO Full/Empty
            wire                    int_tlast;
            wire [DATA_WIDTH/8-1:0] int_tkeep;

            // A. STATIC MUX (Selects Input)
            axis_mux_static #(
                .S_COUNT(S_COUNT),
                .DATA_WIDTH(DATA_WIDTH)
            ) mux_inst (
                .clk(clk),
                .rst(rst),
                
                // From Top Level Sources
                .s_axis_tdata(s_axis_tdata),
                .s_axis_tvalid(s_axis_tvalid),
                .s_axis_tready(mux_ready_agg[m]), // Ready signal going back to Source
                .s_axis_tlast(s_axis_tlast),
                .s_axis_tkeep({(S_COUNT*DATA_WIDTH/8){1'b1}}), // Assuming full keep for mux logic

                // To Internal FIFO
                .m_axis_tdata(int_tdata),
                .m_axis_tvalid(int_tvalid),
                .m_axis_tready(int_tready),       // Listens to FIFO
                .m_axis_tlast(int_tlast),
                .m_axis_tkeep(int_tkeep),

                .enable(1'b1),
                .select(selects[m]) 
            );

            // B. OUTPUT FIFO (Decouples Timing)
            axis_fifo #(
                .DATA_WIDTH(DATA_WIDTH),
                .DEPTH(FIFO_DEPTH)
            ) fifo_inst (
                .clk(clk),
                .rst(rst),

                // Slave (From Mux)
                .s_axis_tdata(int_tdata),
                .s_axis_tvalid(int_tvalid),
                .s_axis_tready(int_tready), // Tells Mux (and Source) to stop if Full
                .s_axis_tlast(int_tlast),
                .s_axis_tkeep(int_tkeep),

                // Master (To Destination Module)
                .m_axis_tdata(m_axis_tdata[m*DATA_WIDTH +: DATA_WIDTH]),
                .m_axis_tvalid(m_axis_tvalid[m]),
                .m_axis_tready(m_axis_tready[m]),
                .m_axis_tlast(m_axis_tlast[m]),
                .m_axis_tkeep(m_axis_tkeep[m*(DATA_WIDTH/8) +: DATA_WIDTH/8])
            );
        end
    endgenerate

    // [4] READY AGGREGATION (Unchanged Logic)
    // The source ready is still an AND of all destinations selecting it.
    // BUT now, the destination 'ready' comes from the FIFO, so it is high 
    // as long as the FIFO isn't full.
    integer i, j;
    reg [S_COUNT-1:0] s_ready_comb;
    reg combined_ready;
    reg is_selected;

    always @* begin
        s_ready_comb = {S_COUNT{1'b0}};

        for (j = 0; j < S_COUNT; j = j + 1) begin
            combined_ready = 1'b1; 
            is_selected    = 1'b0; 

            for (i = 0; i < M_COUNT; i = i + 1) begin
                if (selects[i] == j) begin
                    // mux_ready_agg is now driven by the FIFO's s_ready
                    combined_ready = combined_ready & mux_ready_agg[i][j];
                    is_selected    = 1'b1;
                end
            end
            s_ready_comb[j] = is_selected ? combined_ready : 1'b0;
        end
    end

    assign s_axis_tready = s_ready_comb;

endmodule