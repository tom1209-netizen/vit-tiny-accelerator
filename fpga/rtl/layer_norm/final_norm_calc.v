`timescale 1ns / 1ps

module final_norm_calc #(
    parameter DATA_WIDTH = 8,
    parameter PARALLEL_N = 8,
    parameter STAT_WIDTH = 32, // Input width remains standard
    parameter DO_REQUANTIZE = 1     
)(
    input  wire                   clk,
    input  wire                   aresetn,
    
    // Data Stream Input
    input  wire [PARALLEL_N*DATA_WIDTH-1:0] s_axis_data,
    input  wire                             s_axis_valid,
    input  wire                             s_axis_last, 
    output reg                              s_axis_ready, 
    
    // Parameters (Q16.16)
    input  wire signed [STAT_WIDTH-1:0]     mean_val,
    input  wire signed [STAT_WIDTH-1:0]     inv_sqrt_val,
    input  wire signed [STAT_WIDTH-1:0]     gamma_val,
    input  wire signed [STAT_WIDTH-1:0]     beta_val,
    input  wire                             params_valid,
    
    // Output Stream
    output reg [PARALLEL_N*(DO_REQUANTIZE ? 8 : 32)-1:0] m_axis_data,
    output reg                                           m_axis_valid,
    output reg                                           m_axis_last, 
    input  wire                                          m_axis_ready
);

    // =========================================================
    // OPTIMIZED PARAMETER STORAGE
    // =========================================================
    // We assume Gamma and Beta fit in Q8.16 (Range +/- 128)
    // This saves registers compared to full 32-bit storage.
    localparam STORE_W = 24; 
    
    reg signed [STORE_W-1:0] latched_beta;  // Q8.16
    reg signed [STORE_W-1:0] combined_scale; // Q8.16
    
    // Mean needs to stay full width or similar to ensure accurate subtraction
    // But input pixels are 8-bit (0-255). Mean is Q16.16.
    // Mean range is 0-255. Q8.16 is sufficient (Range +/- 128... wait).
    // 255 is 0x00FF. In Q16.16 it is 0x00FF0000.
    // Requires 8 integer bits. Q8.16 fits exactly (signed +/- 128). 
    // Wait, 255 overflows signed 8-bit integer part.
    // We need 9 integer bits for 255. Let's keep Mean at 32 bits to be safe/simple.
    reg signed [STAT_WIDTH-1:0] latched_mean;

    // Intermediate Full Multiplier Result
    reg signed [63:0] scale_mul_full_comb;
    
    always @(*) begin
        scale_mul_full_comb = inv_sqrt_val * gamma_val;
    end
    
    // =========================================================
    // FSM
    // =========================================================
    localparam IDLE = 0;
    localparam BUSY = 1;
    reg state;

    always @(posedge clk) begin
        if (!aresetn) begin
            state          <= IDLE;
            s_axis_ready   <= 0;
            latched_mean   <= 0;
            combined_scale <= 0;
            latched_beta   <= 0;
        end else begin
            case (state)
                IDLE: begin
                    s_axis_ready <= 0;
                    
                    if (params_valid) begin
                        latched_mean   <= mean_val;
                        
                        // Latch Scale: Result is Q32.32. We want Q8.16.
                        // Full: [63:0]. Q16.16 is [47:16].
                        // We want bottom 24 bits of the Q16.16 part?
                        // Or rather: We verify the range fits.
                        // We extract the Q16.16 portion and truncate to 24 bits.
                        // scale_mul_full_comb >>> 16 gives Q??.16 in LSBs.
                        // We take [23:0] of that.
                        // Checks: [47:16] is the 32-bit Q16.16.
                        // We take [39:16] (24 bits: 8 int, 16 frac).
                        combined_scale <= scale_mul_full_comb[39:16];
                        
                        // Latch Beta: Take [23:0] (Assuming Q8.16 fit)
                        latched_beta   <= beta_val[STORE_W-1:0];
                        
                        state        <= BUSY;
                        s_axis_ready <= 1; 
                    end
                end

                BUSY: begin
                    if (m_axis_ready) begin
                        s_axis_ready <= 1;
                        if (s_axis_valid && s_axis_ready && s_axis_last) begin
                            state        <= IDLE;
                            s_axis_ready <= 0;
                        end
                    end else begin
                        s_axis_ready <= 0; 
                    end
                end
            endcase
        end
    end

    // =========================================================
    // STAGE 1: SUBTRACT MEAN
    // =========================================================
    // Result is Q16.16 (32-bit) to maintain precision
    reg signed [31:0] st1_diff [0:PARALLEL_N-1];
    reg               st1_valid;
    reg               st1_last;
    
    integer i;
    always @(posedge clk) begin
        if (!aresetn) begin
            st1_valid <= 0;
            st1_last  <= 0;
        end else if (m_axis_ready) begin
            st1_valid <= s_axis_valid && s_axis_ready;
            st1_last  <= s_axis_last && s_axis_valid && s_axis_ready;
            
            if (s_axis_valid && s_axis_ready) begin
                for (i = 0; i < PARALLEL_N; i = i + 1) begin
                    // Input 8-bit -> Q16.16
                    st1_diff[i] <= ($signed(s_axis_data[i*8 +: 8]) <<< 16) - latched_mean;
                end
            end
        end
    end

    // =========================================================
    // STAGE 2: MULTIPLY BY SCALE (Optimized)
    // =========================================================
    reg signed [31:0] st2_norm_val [0:PARALLEL_N-1];
    reg               st2_valid;
    reg               st2_last;
    
    // Diff (32-bit) * Scale (24-bit) -> 56 bit result
    reg signed [55:0] mul_comb [0:PARALLEL_N-1];
    integer j;

    always @(*) begin
        for (j = 0; j < PARALLEL_N; j = j + 1) begin
            // Diff is Q16.16. Scale is Q8.16.
            // Result is Q24.32.
            mul_comb[j] = st1_diff[j] * combined_scale;
        end
    end

    always @(posedge clk) begin
        if (!aresetn) begin
            st2_valid <= 0;
            st2_last  <= 0;
        end else if (m_axis_ready) begin
            st2_valid <= st1_valid;
            st2_last  <= st1_last;
            
            if (st1_valid) begin
                for (j = 0; j < PARALLEL_N; j = j + 1) begin
                    // We want Q16.16 Output.
                    // Result has 32 fractional bits.
                    // We need bits [47:16] of a full Q32.32 product.
                    // Here we have Q24.32.
                    // The integer part starts at bit 32. 
                    // We want 16 fractional bits, so we drop the bottom 16 bits [15:0].
                    // We take [47:16].
                    // In our 56-bit result [55:0]:
                    // Bit 0 = 2^-32. Bit 16 = 2^-16. Bit 32 = 2^0.
                    // We want Q16.16. So we want bits starting from 16 up to 47.
                    st2_norm_val[j] <= mul_comb[j][47:16];
                end
            end
        end
    end

    // =========================================================
    // STAGE 3: ADD BETA & RE-QUANTIZE
    // =========================================================
    
    reg signed [31:0] final_val_q16     [0:PARALLEL_N-1];
    reg signed [31:0] final_int_rounded [0:PARALLEL_N-1];
    reg [7:0]         clamped_val       [0:PARALLEL_N-1];
    integer k;

    always @(*) begin
        for (k = 0; k < PARALLEL_N; k = k + 1) begin
            // Beta is Q8.16 (24-bit). Norm is Q16.16 (32-bit).
            // Sign extend Beta to 32-bit for addition
            final_val_q16[k] = st2_norm_val[k] + {{8{latched_beta[STORE_W-1]}}, latched_beta};

            final_int_rounded[k] = 0;
            clamped_val[k]       = 0;

            if (DO_REQUANTIZE) begin
                final_int_rounded[k] = (final_val_q16[k] + $signed(32'h8000)) >>> 16;
                
                if (final_int_rounded[k] > 127) clamped_val[k] = 8'd127;
                else if (final_int_rounded[k] < -128) clamped_val[k] = -8'd128;
                else clamped_val[k] = final_int_rounded[k][7:0];
            end
        end
    end

    integer m;
    always @(posedge clk) begin
        if (!aresetn) begin
            m_axis_valid <= 0;
            m_axis_last  <= 0;
            m_axis_data  <= 0;
        end else if (m_axis_ready) begin
            m_axis_valid <= st2_valid; 
            m_axis_last  <= st2_last; 
            
            if (st2_valid) begin
                for (m = 0; m < PARALLEL_N; m = m + 1) begin
                    if (DO_REQUANTIZE) begin
                        m_axis_data[m*8 +: 8] <= clamped_val[m];
                    end else begin
                        m_axis_data[m*32 +: 32] <= final_val_q16[m];
                    end
                end
            end
        end
    end

endmodule