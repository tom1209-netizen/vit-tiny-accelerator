`timescale 1ns / 1ps

module final_norm_calc #(
    parameter DATA_WIDTH = 8,
    parameter PARALLEL_N = 8,
    parameter STAT_WIDTH = 32, 
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
    localparam STORE_W = 24; 
    
    reg signed [STORE_W-1:0] latched_beta;   // Q8.16
    reg signed [STORE_W-1:0] combined_scale; // Q8.16
    reg signed [STAT_WIDTH-1:0] latched_mean;

    // PIPELINE REGISTERS
    reg signed [STAT_WIDTH-1:0] r_inv_sqrt;
    reg signed [STAT_WIDTH-1:0] r_gamma;
    
    // DSP Multiplier Output
    (* use_dsp = "yes" *) 
    reg signed [63:0] r_mul_full;

    // =========================================================
    // FSM
    // =========================================================
    localparam IDLE       = 0;
    localparam WAIT_MUL   = 1; 
    localparam WAIT_SCALE = 2; // NEW STATE: Wait for extraction
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
                        
                        // Stage 1: Latch Inputs
                        r_inv_sqrt <= inv_sqrt_val;
                        r_gamma    <= gamma_val;
                        
                        state <= WAIT_MUL;
                    end
                end

                WAIT_MUL: begin
                    // Stage 2: Multiply
                    r_mul_full <= r_inv_sqrt * r_gamma;
                    state <= WAIT_SCALE;
                end
                
                WAIT_SCALE: begin
                    // Stage 3: Extract (Now safe because r_mul_full is stable)
                    combined_scale <= r_mul_full[39:16]; 
                    
                    state        <= BUSY;
                    s_axis_ready <= 1;
                end

                BUSY: begin
                    // Processing Data
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
                    // Q16.16 Result
                    st1_diff[i] <= ($signed(s_axis_data[i*8 +: 8]) <<< 16) - latched_mean;
                end
            end
        end
    end

    // =========================================================
    // STAGE 2: MULTIPLY BY SCALE
    // =========================================================
    reg signed [31:0] st2_norm_val [0:PARALLEL_N-1];
    reg               st2_valid;
    reg               st2_last;
    
    reg signed [55:0] mul_comb [0:PARALLEL_N-1];
    integer j;

    always @(*) begin
        for (j = 0; j < PARALLEL_N; j = j + 1) begin
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
                    // Extract Q16.16 from Q24.32 result
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
            final_val_q16[k] = st2_norm_val[k] + {{8{latched_beta[STORE_W-1]}}, latched_beta};

            final_int_rounded[k] = 0;
            clamped_val[k]       = 0;

            if (DO_REQUANTIZE) begin
                // Round Half Up logic: floor(x + 0.5)
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