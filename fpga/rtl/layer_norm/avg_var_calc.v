`timescale 1ns / 1ps

module avg_var_calc #(
    parameter SUM_WIDTH    = 18,     
    parameter SUM_SQ_WIDTH = 24,     
    parameter FIXED_WIDTH  = 32      
)(
    input  wire                   clk,
    input  wire                   aresetn,

    input  wire signed [SUM_WIDTH-1:0]    sum_int,
    input  wire signed [SUM_SQ_WIDTH-1:0] sum_sq_int,
    input  wire                           stats_valid_in,

    output reg signed [FIXED_WIDTH-1:0] mean_out,
    output reg signed [FIXED_WIDTH-1:0] var_out,
    output reg                          calc_valid_out
);

    localparam signed [17:0] INV_N_SHORT = 18'd819; // 1/320 * 2^18

    // =========================================================
    // STAGE 1: MULTIPLY BY 1/N
    // =========================================================
    reg signed [35:0] st1_mean_mult;   
    reg signed [41:0] st1_avg_sq_mult; 
    reg               st1_valid;

    always @(posedge clk) begin
        if (!aresetn) begin
            st1_mean_mult <= 0; st1_avg_sq_mult <= 0; st1_valid <= 0;
        end else begin
            st1_valid <= stats_valid_in;
            if (stats_valid_in) begin
                st1_mean_mult   <= sum_int * INV_N_SHORT;
                st1_avg_sq_mult <= sum_sq_int * INV_N_SHORT;
            end
        end
    end

    // =========================================================
    // STAGE 2: DECOMPOSITION SETUP
    // =========================================================
    // Prepare 32-bit Mean for splitting.
    // Extract Q16.16 Mean from Stage 1 (Shift >> 2 to convert Q.18 to Q.16)
    wire signed [31:0] w_mean_q16   = st1_mean_mult[33:2];
    wire signed [31:0] w_avg_sq_q16 = st1_avg_sq_mult[33:2];

    reg signed [15:0] st2_mean_H;     // Top 16 bits
    reg signed [16:0] st2_mean_L;     // Bottom 16 bits (treated as pos signed)
    reg signed [31:0] st2_avg_sq_q16;
    reg signed [31:0] st2_mean_q16;   // For passthrough
    reg               st2_valid;

    always @(posedge clk) begin
        if (!aresetn) begin
            st2_mean_H <= 0; st2_mean_L <= 0;
            st2_avg_sq_q16 <= 0; st2_mean_q16 <= 0; st2_valid <= 0;
        end else begin
            st2_valid <= st1_valid;
            if (st1_valid) begin
                st2_mean_H <= w_mean_q16[31:16];
                // Force Low part to be positive signed for DSP logic
                st2_mean_L <= {1'b0, w_mean_q16[15:0]};
                
                st2_avg_sq_q16 <= w_avg_sq_q16;
                st2_mean_q16   <= w_mean_q16;
            end
        end
    end

    // =========================================================
    // STAGE 3: PARTIAL SQUARING (Multiplication)
    // =========================================================
    // (H*2^16 + L)^2 = H^2*2^32 + 2HL*2^16 + L^2
    // Calc terms: P_H = H*H, P_M = H*L, P_L = L*L
    
    reg signed [31:0] st3_prod_H; // 16x16 signed
    reg signed [33:0] st3_prod_M; // 16s x 17s
    reg signed [33:0] st3_prod_L; // 17s x 17s (effectively unsigned output)
    
    reg signed [31:0] st3_avg_sq_q16;
    reg signed [31:0] st3_mean_q16;
    reg               st3_valid;

    always @(posedge clk) begin
        if (!aresetn) begin
            st3_prod_H <= 0; st3_prod_M <= 0; st3_prod_L <= 0; st3_valid <= 0;
        end else begin
            st3_valid <= st2_valid;
            if (st2_valid) begin
                st3_prod_H <= st2_mean_H * st2_mean_H;
                st3_prod_M <= st2_mean_H * st2_mean_L;
                st3_prod_L <= st2_mean_L * st2_mean_L;
                
                st3_avg_sq_q16 <= st2_avg_sq_q16;
                st3_mean_q16   <= st2_mean_q16;
            end
        end
    end

    // =========================================================
    // STAGE 4: SUMMATION (Reconstruction)
    // =========================================================
    // Mean_Sq = (H^2 << 32) + (2*HL << 16) + L^2
    
    reg signed [63:0] st4_mean_sq_full;
    reg signed [31:0] st4_avg_sq_q16;
    reg signed [31:0] st4_mean_q16;
    reg               st4_valid;

    always @(posedge clk) begin
        if (!aresetn) begin
            st4_mean_sq_full <= 0; st4_valid <= 0;
        end else begin
            st4_valid <= st3_valid;
            if (st3_valid) begin
                // Reconstruct:
                // Term 1: prod_H << 32
                // Term 2: prod_M * 2 << 16 = prod_M << 17
                // Term 3: prod_L
                st4_mean_sq_full <= (st3_prod_H <<< 32) + (st3_prod_M <<< 17) + st3_prod_L;
                
                st4_avg_sq_q16 <= st3_avg_sq_q16;
                st4_mean_q16   <= st3_mean_q16;
            end
        end
    end

    // =========================================================
    // STAGE 5: SUBTRACTION (Variance Output)
    // =========================================================
    // Var = Avg(x^2) - Mean^2
    
    always @(posedge clk) begin
        if (!aresetn) begin
            mean_out <= 0; var_out <= 0; calc_valid_out <= 0;
        end else begin
            calc_valid_out <= st4_valid;
            if (st4_valid) begin
                mean_out <= st4_mean_q16;
                
                // Variance: Avg_Sq - Mean_Sq[47:16]
                var_out  <= st4_avg_sq_q16 - st4_mean_sq_full[47:16];
            end
        end
    end

endmodule