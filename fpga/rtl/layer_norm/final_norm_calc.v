`timescale 1ns / 1ps

module final_norm_calc #(
    parameter DATA_WIDTH = 8,
    parameter PARALLEL_N = 8,
    parameter STAT_WIDTH = 32, 
    parameter DO_REQUANTIZE = 1     
)(
    input  wire                   clk,
    input  wire                   aresetn,
    
    // Data Stream 
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
    // PARAMETER STORAGE & FSM
    // =========================================================
    localparam STORE_W = 24;
    reg signed [STORE_W-1:0] latched_beta;   // Q8.16
    reg signed [STORE_W-1:0] combined_scale; // Q8.16
    reg signed [STAT_WIDTH-1:0] latched_mean;

    // PIPELINE REGISTERS FOR CALC
    reg signed [STAT_WIDTH-1:0] r_inv_sqrt;
    reg signed [STAT_WIDTH-1:0] r_gamma;
    
    (* use_dsp = "yes" *) 
    reg signed [63:0] r_mul_full;

    localparam IDLE       = 0;
    localparam WAIT_MUL   = 1; 
    localparam WAIT_SCALE = 2;
    localparam BUSY       = 3;
    reg [1:0] state;

    always @(posedge clk) begin
        if (!aresetn) begin
            state          <= IDLE;
            s_axis_ready   <= 0;
            latched_mean   <= 0;
            combined_scale <= 0;
            latched_beta   <= 0;
            r_inv_sqrt     <= 0;
            r_gamma        <= 0;
            r_mul_full     <= 0;
        end else begin
            case (state)
                IDLE: begin
                    s_axis_ready <= 0;
                    if (params_valid) begin
                        latched_mean <= mean_val;
                        latched_beta <= beta_val[STORE_W-1:0];
                        r_inv_sqrt   <= inv_sqrt_val;
                        r_gamma      <= gamma_val;
                        state        <= WAIT_MUL;
                    end
                end

                WAIT_MUL: begin
                    r_mul_full <= r_inv_sqrt * r_gamma;
                    state      <= WAIT_SCALE;
                end
                
                WAIT_SCALE: begin
                    combined_scale <= r_mul_full[39:16];
                    state          <= BUSY;
                    s_axis_ready   <= 1; 
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
    // STAGE 0: INPUT ISOLATION
    // =========================================================
    reg [PARALLEL_N*DATA_WIDTH-1:0] st0_data;
    reg                             st0_valid;
    reg                             st0_last;

    always @(posedge clk) begin
        if (!aresetn) begin
            st0_valid <= 0;
            st0_last  <= 0;
            st0_data  <= 0;
        end else if (m_axis_ready) begin
            st0_valid <= s_axis_valid && s_axis_ready;
            st0_last  <= s_axis_last && s_axis_valid && s_axis_ready;
            st0_data  <= s_axis_data; 
        end
    end

    // =========================================================
    // STAGE 1: SUBTRACT MEAN
    // =========================================================
    reg signed [31:0] st1_diff [0:PARALLEL_N-1];
    reg               st1_valid;
    reg               st1_last;
    
    integer i;
    always @(posedge clk) begin
        if (!aresetn) begin
            st1_valid <= 0;
            st1_last  <= 0;
        end else if (m_axis_ready) begin
            st1_valid <= st0_valid;
            st1_last  <= st0_last;
            
            if (st0_valid) begin
                for (i = 0; i < PARALLEL_N; i = i + 1) begin
                    st1_diff[i] <= ($signed(st0_data[i*8 +: 8]) <<< 16) - latched_mean;
                end
            end
        end
    end

    // =========================================================
    // STAGE 2: SPLIT MULTIPLICATION (PARALLEL DSPs)
    // =========================================================
    // We split the 32-bit 'st1_diff' into High (15 bits) and Low (17 bits).
    // This allows using 2 parallel DSPs (25x18) instead of one deep cascade.
    // X (32b) = X_hi(15b) << 17 | X_lo(17b)
    
    reg signed [39:0] st2_prod_hi [0:PARALLEL_N-1]; // Result of 15b * 24b
    reg signed [41:0] st2_prod_lo [0:PARALLEL_N-1]; // Result of 17b * 24b
    reg               st2_valid;
    reg               st2_last;
    
    integer j;
    reg signed [14:0] A_hi;
    reg signed [17:0] A_lo; // Treated as positive in logic, but needs care
    
    always @(posedge clk) begin
        if (!aresetn) begin
            st2_valid <= 0;
            st2_last  <= 0;
        end else if (m_axis_ready) begin
            st2_valid <= st1_valid;
            st2_last  <= st1_last;
            
            if (st1_valid) begin
                for (j = 0; j < PARALLEL_N; j = j + 1) begin
                    // Split st1_diff[31:0]
                    // High part: bits [31:17] (15 bits signed)
                    // Low part:  bits [16:0]  (17 bits unsigned/positive)
                    
                    // DSP 1: Signed * Signed
                    st2_prod_hi[j] <= $signed(st1_diff[j][31:17]) * combined_scale;
                    
                    // DSP 2: Unsigned * Signed. 
                    // To force strict DSP mapping, we treat the 17 bits as a positive signed number.
                    // We prepend a 0 bit to make it an 18-bit positive signed number.
                    st2_prod_lo[j] <= $signed({1'b0, st1_diff[j][16:0]}) * combined_scale;
                end
            end
        end
    end

    // =========================================================
    // STAGE 3: SUM PARTIAL PRODUCTS
    // =========================================================
    // Recombine: (Hi * Scale) << 17 + (Lo * Scale)
    
    reg signed [31:0] st3_norm_val [0:PARALLEL_N-1];
    reg               st3_valid;
    reg               st3_last;
    reg signed [55:0] full_sum_temp;
    integer k;

    always @(posedge clk) begin
        if (!aresetn) begin
            st3_valid <= 0;
            st3_last  <= 0;
        end else if (m_axis_ready) begin
            st3_valid <= st2_valid;
            st3_last  <= st2_last;

            if (st2_valid) begin
                for (k = 0; k < PARALLEL_N; k = k + 1) begin
                    // Shift high part by 17 and add low part
                    full_sum_temp = (st2_prod_hi[k] <<< 17) + st2_prod_lo[k];
                    
                    // Extract result (match previous Q format logic)
                    st3_norm_val[k] <= full_sum_temp[47:16];
                end
            end
        end
    end

    // =========================================================
    // STAGE 4: ADD BETA & PREPARE ROUNDING
    // =========================================================
    reg signed [31:0] st4_val_w_offset [0:PARALLEL_N-1];
    reg               st4_valid;
    reg               st4_last;
    integer l;
    
    always @(posedge clk) begin
        if (!aresetn) begin
            st4_valid <= 0;
            st4_last  <= 0;
        end else if (m_axis_ready) begin
            st4_valid <= st3_valid;
            st4_last  <= st3_last;

            if (st3_valid) begin
                for (l = 0; l < PARALLEL_N; l = l + 1) begin
                     if (DO_REQUANTIZE) begin
                         st4_val_w_offset[l] <= st3_norm_val[l] + {{8{latched_beta[STORE_W-1]}}, latched_beta} + 32'sh0000_8000;
                     end else begin
                         st4_val_w_offset[l] <= st3_norm_val[l] + {{8{latched_beta[STORE_W-1]}}, latched_beta};
                     end
                end
            end
        end
    end

    // =========================================================
    // STAGE 5: SHIFT & CLAMP (OUTPUT STAGE)
    // =========================================================
    reg signed [31:0] final_int_shifted;
    reg [7:0]         clamped_val_temp;
    integer m;
    
    always @(posedge clk) begin
        if (!aresetn) begin
            m_axis_valid <= 0;
            m_axis_last  <= 0;
            m_axis_data  <= 0;
        end else if (m_axis_ready) begin
            m_axis_valid <= st4_valid;
            m_axis_last  <= st4_last; 
            
            if (st4_valid) begin
                for (m = 0; m < PARALLEL_N; m = m + 1) begin
                    if (DO_REQUANTIZE) begin
                        final_int_shifted = st4_val_w_offset[m] >>> 16;
                        if (final_int_shifted > 127) 
                            clamped_val_temp = 8'd127;
                        else if (final_int_shifted < -128) 
                            clamped_val_temp = -8'd128;
                        else 
                            clamped_val_temp = final_int_shifted[7:0];
                        
                        m_axis_data[m*8 +: 8] <= clamped_val_temp;
                    end else begin
                        m_axis_data[m*32 +: 32] <= st4_val_w_offset[m];
                    end
                end
            end
        end
    end

endmodule