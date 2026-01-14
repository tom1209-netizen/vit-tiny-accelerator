`timescale 1ns / 1ps

module avg_var_calc #(
    parameter SUM_WIDTH    = 18,     
    parameter SUM_SQ_WIDTH = 26,     
    parameter FIXED_WIDTH  = 32      
)(
    input  wire                   clk,
    input  wire                   aresetn,
    
    // [NEW] Packet Length Input (From Stats FIFO)
    input  wire [15:0]            pkt_len_in,

    input  wire signed [SUM_WIDTH-1:0]    sum_int,
    input  wire signed [SUM_SQ_WIDTH-1:0] sum_sq_int,
    input  wire                           stats_valid_in,

    output reg signed [FIXED_WIDTH-1:0] mean_out,
    output reg signed [FIXED_WIDTH-1:0] var_out,
    output reg                          calc_valid_out
);
    
    // =========================================================
    // LOOKUP LOGIC FOR 1/N
    // =========================================================
    reg signed [17:0] inv_n_val; // selected constant
    
    // TinyViT Constants (2^18 / N)
    localparam INV_80  = 18'd3277;
    localparam INV_128 = 18'd2048; // 262144 / 128
    localparam INV_160 = 18'd1638; // 262144 / 160 = 1638.4
    localparam INV_320 = 18'd819;  // 262144 / 320 = 819.2
    localparam INV_800 = 18'd328;  // 262144 / 800 = 327.68

    always @(*) begin
        case (pkt_len_in)
            16'd80 : inv_n_val = INV_80;
            16'd128: inv_n_val = INV_128;
            16'd160: inv_n_val = INV_160;
            16'd320: inv_n_val = INV_320;
            16'd800: inv_n_val = INV_800; // Supported large packet
            default: inv_n_val = INV_320; // Safe default
        endcase
    end

    // =========================================================
    // STAGE 0: INPUT PIPELINE & LATCH CONFIG
    // =========================================================
    reg signed [SUM_WIDTH-1:0]    sum_int_reg;
    reg signed [SUM_SQ_WIDTH-1:0] sum_sq_int_reg;
    reg signed [17:0]             inv_n_reg; 
    reg                           st0_valid;
    
    always @(posedge clk) begin
        if (!aresetn) begin
            sum_int_reg    <= 0;
            sum_sq_int_reg <= 0;
            inv_n_reg      <= 0;
            st0_valid      <= 0;
        end else begin
            sum_int_reg    <= sum_int;
            sum_sq_int_reg <= sum_sq_int;
            
            // Latch the Looked-up value when valid arrives
            if (stats_valid_in) begin
                inv_n_reg  <= inv_n_val; 
            end
            
            st0_valid      <= stats_valid_in;
        end
    end

    // =========================================================
    // STAGE 1: MULTIPLY BY 1/N
    // =========================================================
    reg signed [35:0] st1_mean_mult;
    reg signed [43:0] st1_avg_sq_mult; 
    reg               st1_valid;
    
    always @(posedge clk) begin
        if (!aresetn) begin
            st1_mean_mult   <= 0;
            st1_avg_sq_mult <= 0; 
            st1_valid       <= 0;
        end else begin
            st1_valid <= st0_valid;
            
            if (st0_valid) begin
                st1_mean_mult   <= sum_int_reg * inv_n_reg;
                st1_avg_sq_mult <= sum_sq_int_reg * inv_n_reg;
            end
        end
    end

    // ... [Stages 2, 3, 4, 5 remain EXACTLY the same] ...
    // Copy Stages 2-5 from previous versions
    
    // =========================================================
    // STAGE 2: DECOMPOSITION SETUP
    // =========================================================
    wire signed [31:0] w_mean_q16   = st1_mean_mult[33:2];
    wire signed [31:0] w_avg_sq_q16 = st1_avg_sq_mult[33:2];

    reg signed [15:0] st2_mean_H;
    reg signed [16:0] st2_mean_L;
    reg signed [31:0] st2_avg_sq_q16;
    reg signed [31:0] st2_mean_q16;
    reg               st2_valid;
    
    always @(posedge clk) begin
        if (!aresetn) begin
            st2_mean_H     <= 0;
            st2_mean_L     <= 0;
            st2_avg_sq_q16 <= 0; 
            st2_mean_q16   <= 0;
            st2_valid      <= 0;
        end else begin
            st2_valid <= st1_valid;
            if (st1_valid) begin
                st2_mean_H <= w_mean_q16[31:16];
                st2_mean_L <= {1'b0, w_mean_q16[15:0]};
                st2_avg_sq_q16 <= w_avg_sq_q16;
                st2_mean_q16   <= w_mean_q16;
            end
        end
    end

    // =========================================================
    // STAGE 3: PARTIAL SQUARING
    // =========================================================
    reg signed [31:0] st3_prod_H;
    reg signed [33:0] st3_prod_M;
    reg signed [33:0] st3_prod_L;
    reg signed [31:0] st3_avg_sq_q16;
    reg signed [31:0] st3_mean_q16;
    reg               st3_valid;
    
    always @(posedge clk) begin
        if (!aresetn) begin
            st3_prod_H <= 0;
            st3_prod_M <= 0; 
            st3_prod_L <= 0; 
            st3_valid  <= 0;
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
    // STAGE 4: SUMMATION
    // =========================================================
    reg signed [63:0] st4_mean_sq_full;
    reg signed [31:0] st4_avg_sq_q16;
    reg signed [31:0] st4_mean_q16;
    reg               st4_valid;
    
    always @(posedge clk) begin
        if (!aresetn) begin
            st4_mean_sq_full <= 0;
            st4_valid        <= 0;
        end else begin
            st4_valid <= st3_valid;
            if (st3_valid) begin
                st4_mean_sq_full <= (st3_prod_H <<< 32) + (st3_prod_M <<< 17) + st3_prod_L;
                st4_avg_sq_q16 <= st3_avg_sq_q16;
                st4_mean_q16   <= st3_mean_q16;
            end
        end
    end

    // =========================================================
    // STAGE 5: SUBTRACTION
    // =========================================================
    always @(posedge clk) begin
        if (!aresetn) begin
            mean_out <= 0;
            var_out  <= 0; 
            calc_valid_out <= 0;
        end else begin
            calc_valid_out <= st4_valid;
            if (st4_valid) begin
                mean_out <= st4_mean_q16;
                var_out  <= st4_avg_sq_q16 - st4_mean_sq_full[47:16];
            end
        end
    end

endmodule