`timescale 1ns / 1ps

module layer_norm #(
    parameter DATA_WIDTH   = 8,    // Pixel Data Width (int8)
    parameter PARALLEL_N   = 8,    // Pixels per clock
    parameter BEAT_WIDTH   = 64,   // 8 * 8
    parameter FIFO_DEPTH   = 512,  // Max Sequence Length
    
    // Internal Precision
    parameter STAT_WIDTH   = 32,   // Q16.16
    parameter SUM_WIDTH    = 18,   
    parameter SUM_SQ_WIDTH = 24,
    parameter M_BITS       = 12    // Peano LUT Bits
)(
    input  wire                   clk,
    input  wire                   aresetn,

    // --- Input Stream ---
    input  wire [BEAT_WIDTH-1:0]  s_axis_tdata,
    input  wire                   s_axis_tvalid,
    input  wire                   s_axis_tlast,
    output wire                   s_axis_tready,
    
    // --- Parameters (Gamma/Beta) ---
    input  wire signed [STAT_WIDTH-1:0] cfg_gamma,
    input  wire signed [STAT_WIDTH-1:0] cfg_beta,

    // --- Output Stream ---
    output wire [BEAT_WIDTH-1:0]  m_axis_tdata,
    output wire                   m_axis_tvalid,
    output wire                   m_axis_tlast,
    input  wire                   m_axis_tready
);

    // =========================================================
    // 1. SIGNAL DECLARATIONS
    // =========================================================
    
    // Splitter Signals
    wire stats_fifo_wready;
    wire data_fifo_wready;
    wire input_handshake;
    
    // Stats Path Interconnects
    wire [BEAT_WIDTH-1:0] sf_data;
    wire                  sf_valid, sf_last, sf_ready;
    
    wire signed [SUM_WIDTH-1:0]    acc_sum;
    wire signed [SUM_SQ_WIDTH-1:0] acc_sum_sq;
    wire                           acc_valid, acc_in_ready;
    
    wire signed [SUM_WIDTH-1:0]    buff_sum;
    wire signed [SUM_SQ_WIDTH-1:0] buff_sum_sq;
    wire                           buff_valid, buff_read_en;
    
    wire signed [STAT_WIDTH-1:0]   calc_mean, calc_var;
    wire                           calc_valid;
    
    wire signed [STAT_WIDTH-1:0]   peano_inv_sqrt;
    wire                           peano_valid;
    
    // Data Path Interconnects
    wire [BEAT_WIDTH-1:0] df_data;
    wire                  df_valid, df_last, df_read_en;
    
    // Synchronization
    reg signed [STAT_WIDTH-1:0]    delayed_mean [0:1]; // 2-cycle delay
    
    // Final Norm Interconnects
    wire [BEAT_WIDTH-1:0] fn_data;
    wire                  fn_valid, fn_last, fn_ready;

    // =========================================================
    // 2. INPUT SPLITTER (Write to 2 FIFOs)
    // =========================================================
    // Stall input if EITHER FIFO is full to maintain synchronization
    assign s_axis_tready = stats_fifo_wready && data_fifo_wready;
    assign input_handshake = s_axis_tvalid && s_axis_tready;

    // =========================================================
    // 3. FIFO 1: STATS PATH (Input -> Accumulator)
    // =========================================================
    beat_fifo #(
        .DATA_WIDTH(BEAT_WIDTH), .DEPTH(FIFO_DEPTH), .RAM_STYLE("block")
    ) u_stats_beat_fifo (
        .clk(clk), .aresetn(aresetn),
        // Write
        .s_axis_tdata(s_axis_tdata), .s_axis_tlast(s_axis_tlast), 
        .s_axis_tvalid(input_handshake), .s_axis_tready(stats_fifo_wready),
        // Read (To Accumulator)
        .m_axis_tdata(sf_data), .m_axis_tlast(sf_last),
        .m_axis_tvalid(sf_valid), .m_axis_tready(sf_ready),
        .fifo_count()
    );

    // =========================================================
    // 4. FIFO 2: DATA PATH (Input -> Final Norm)
    // =========================================================
    beat_fifo #(
        .DATA_WIDTH(BEAT_WIDTH), .DEPTH(FIFO_DEPTH), .RAM_STYLE("block")
    ) u_data_beat_fifo (
        .clk(clk), .aresetn(aresetn),
        // Write
        .s_axis_tdata(s_axis_tdata), .s_axis_tlast(s_axis_tlast), 
        .s_axis_tvalid(input_handshake), .s_axis_tready(data_fifo_wready),
        // Read (To Final Norm)
        .m_axis_tdata(df_data), .m_axis_tlast(df_last),
        .m_axis_tvalid(df_valid), .m_axis_tready(df_read_en), // Controlled by Final Norm
        .fifo_count()
    );

    // =========================================================
    // 5. STATISTICS CALCULATION CHAIN
    // =========================================================
    
    // 5.1 Accumulator
    // Read from Stats FIFO as soon as data is available
    assign sf_ready = sf_valid && acc_in_ready; 

    accumulator #(
        .BEAT_WIDTH(BEAT_WIDTH), .NUM_ELEMS(PARALLEL_N), .ELEM_WIDTH(8),
        .SUM_WIDTH(SUM_WIDTH), .SUM_SQ_WIDTH(SUM_SQ_WIDTH)
    ) u_accumulator (
        .clk(clk), .aresetn(aresetn),
        .s_axis_tdata(sf_data), .s_axis_tvalid(sf_valid), .s_axis_tlast(sf_last), 
        .s_axis_tready(acc_in_ready),
        .sum_out_int(acc_sum), .sum_sq_out_int(acc_sum_sq), .stats_valid(acc_valid)
    );

    // 5.2 Stats Buffer FIFO (Between Acc and Calc)
    stats_fifo #(
        .SUM_WIDTH(SUM_WIDTH), .SUM_SQ_WIDTH(SUM_SQ_WIDTH), .DEPTH(16)
    ) u_stats_buffer (
        .clk(clk), .aresetn(aresetn),
        .s_sum_int(acc_sum), .s_sum_sq_int(acc_sum_sq), .s_valid(acc_valid), .s_ready(),
        .m_sum_int(buff_sum), .m_sum_sq_int(buff_sum_sq), .m_valid(buff_valid), .m_ready(buff_read_en)
    );
    assign buff_read_en = 1'b1; // Auto drain to Calculator

    // 5.3 Average & Variance Calculator
    avg_var_calc #(
        .SUM_WIDTH(SUM_WIDTH), .SUM_SQ_WIDTH(SUM_SQ_WIDTH), .FIXED_WIDTH(STAT_WIDTH)
    ) u_avg_var (
        .clk(clk), .aresetn(aresetn),
        .sum_int(buff_sum), .sum_sq_int(buff_sum_sq), .stats_valid_in(buff_valid),
        .mean_out(calc_mean), .var_out(calc_var), .calc_valid_out(calc_valid)
    );

    // 5.4 Reciprocal Square Root (Peano)
    recip_sqrt #(
        .DATA_WIDTH(STAT_WIDTH), .M_BITS(M_BITS), .OUT_WIDTH(STAT_WIDTH), .FRAC_BITS(16)
    ) u_recip_sqrt (
        .clk(clk), .aresetn(aresetn),
        .i_var(calc_var), .i_var_tvalid(calc_valid), .o_var_tready(),
        .o_recip_sqrt(peano_inv_sqrt), .o_recip_sqrt_tvalid(peano_valid), .i_recip_sqrt_tready(1'b1)
    );

    // =========================================================
    // 6. SYNCHRONIZATION & MERGE
    // =========================================================
    
    // Delay Mean by 2 cycles to match Recip Sqrt latency
    always @(posedge clk) begin
        if (!aresetn) begin
            delayed_mean[0] <= 0; delayed_mean[1] <= 0;
        end else begin
            delayed_mean[0] <= calc_mean;
            delayed_mean[1] <= delayed_mean[0];
        end
    end

    // Final Norm Calculation
    final_norm_calc #(
        .DATA_WIDTH(DATA_WIDTH), .PARALLEL_N(PARALLEL_N), .STAT_WIDTH(STAT_WIDTH), .DO_REQUANTIZE(1)
    ) u_final_norm (
        .clk(clk), .aresetn(aresetn),
        
        // Data Input (From Data Beat FIFO)
        .s_axis_data(df_data), 
        .s_axis_valid(df_valid), 
        .s_axis_last(df_last), 
        .s_axis_ready(df_read_en), // Controlled by Final Norm FSM
        
        // Parameters (From Stats Chain)
        .mean_val(delayed_mean[1]), 
        .inv_sqrt_val(peano_inv_sqrt),
        .gamma_val(cfg_gamma), 
        .beta_val(cfg_beta),
        .params_valid(peano_valid),
        
        // Intermediate Output
        .m_axis_data(fn_data), 
        .m_axis_valid(fn_valid), 
        .m_axis_last(fn_last), 
        .m_axis_ready(fn_ready)
    );

    // =========================================================
    // 7. OUTPUT FIFO (Buffer)
    // =========================================================
    beat_fifo #(
        .DATA_WIDTH(BEAT_WIDTH), .DEPTH(FIFO_DEPTH), .RAM_STYLE("block")
    ) u_output_fifo (
        .clk(clk), .aresetn(aresetn),
        // Write (From Final Norm)
        .s_axis_tdata(fn_data), .s_axis_tlast(fn_last), 
        .s_axis_tvalid(fn_valid), .s_axis_tready(fn_ready),
        // Read (To Top-Level Output)
        .m_axis_tdata(m_axis_tdata), .m_axis_tlast(m_axis_tlast),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .fifo_count()
    );

endmodule