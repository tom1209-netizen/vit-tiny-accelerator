`timescale 1ns / 1ps
module recip_sqrt #(
    parameter DATA_WIDTH = 32,
    parameter M_BITS     = 12,
    parameter OUT_WIDTH  = 32,
    parameter FRAC_BITS  = 16 
)(
    input  wire                  clk,
    input  wire                  aresetn,
    
    input  wire [DATA_WIDTH-1:0] i_var, 
    input  wire                  i_var_tvalid,
    output wire                  o_var_tready,

    output reg  [OUT_WIDTH-1:0]  o_recip_sqrt, 
    output reg                   o_recip_sqrt_tvalid,
    input  wire                  i_recip_sqrt_tready
);

    // =========================================================================
    // LUT DEFINITION
    // =========================================================================
    (* rom_style = "block" *)
    reg [OUT_WIDTH-1:0] lut_2_pow_v [0:(1<<M_BITS)-1];
    initial begin
        $readmemh("lut_pow2.hex", lut_2_pow_v);
    end

    localparam K_WIDTH = $clog2(DATA_WIDTH); // 5
    localparam MAX_OUTPUT = 32'h7FFFFFFF;

    assign o_var_tready = 1'b1;

    // =========================================================================
    // STAGE 1: LEADING ONE DETECTION (LOD)
    // =========================================================================
    reg [K_WIDTH-1:0]    st1_k;
    reg [DATA_WIDTH-1:0] st1_var_d;
    reg                  st1_valid;
    reg                  st1_zero;
    reg [K_WIDTH-1:0]    lod_comb;
    integer i;
    
    always @(*) begin
        lod_comb = 0;
        for (i = 0; i < DATA_WIDTH; i = i + 1) begin
            if (i_var[i]) lod_comb = i[K_WIDTH-1:0];
        end
    end

    always @(posedge clk) begin
        if (!aresetn) begin
            st1_valid <= 0;
            st1_zero  <= 0;
            st1_k     <= 0;
            st1_var_d <= 0;
        end else begin
            st1_valid <= i_var_tvalid;
            st1_zero  <= (i_var == 0);
            
            if (i_var_tvalid) begin
                st1_k     <= lod_comb;
                st1_var_d <= i_var;
            end
        end
    end

    // =========================================================================
    // STAGE 2: NORMALIZATION (BARREL SHIFTER)
    // =========================================================================
    reg [M_BITS-1:0]     st2_mantissa;
    reg [K_WIDTH-1:0]    st2_k;
    reg                  st2_valid;
    reg                  st2_zero;

    always @(posedge clk) begin
        if (!aresetn) begin
            st2_valid    <= 0;
            st2_zero     <= 0;
            st2_mantissa <= 0;
            st2_k        <= 0;
        end else begin
            st2_valid <= st1_valid;
            st2_zero  <= st1_zero;
            
            if (st1_valid) begin
                st2_k <= st1_k;
                st2_mantissa <= (st1_var_d << ((DATA_WIDTH - 1) - st1_k)) >> (DATA_WIDTH - 1 - M_BITS);
            end
        end
    end

    // =========================================================================
    // STAGE 3: PEANO ARITHMETIC
    // =========================================================================
    reg signed [K_WIDTH:0] st3_u;
    reg [M_BITS-1:0]       st3_addr;
    reg                    st3_valid;
    reg                    st3_zero;

    wire signed [K_WIDTH:0] k_real_exponent; 
    assign k_real_exponent = $signed({1'b0, st2_k}) - $signed(FRAC_BITS);

    wire signed [31:0] combined_val;
    wire signed [31:0] neg_halved;
    assign combined_val = (k_real_exponent <<< M_BITS) | {20'd0, st2_mantissa};
    assign neg_halved   = (-combined_val) >>> 1;

    always @(posedge clk) begin
        if (!aresetn) begin
            st3_valid <= 0;
            st3_zero  <= 0;
            st3_u     <= 0;
            st3_addr  <= 0;
        end else begin
            st3_valid <= st2_valid;
            st3_zero  <= st2_zero;
            
            if (st2_valid) begin
                st3_u    <= neg_halved >>> M_BITS;
                st3_addr <= neg_halved[M_BITS-1:0];
            end
        end
    end

    // =========================================================================
    // STAGE 4: MEMORY READ (BRAM)
    // =========================================================================
    reg [OUT_WIDTH-1:0]     st4_lut_val;
    reg signed [K_WIDTH:0]  st4_u;
    reg                     st4_valid;
    reg                     st4_zero;

    always @(posedge clk) begin
        if (!aresetn) begin
            st4_valid   <= 0;
            st4_zero    <= 0;
            st4_lut_val <= 0;
            st4_u       <= 0;
        end else begin
            st4_valid <= st3_valid;
            st4_zero  <= st3_zero;
            
            if (st3_valid) begin
                st4_lut_val <= lut_2_pow_v[st3_addr];
                st4_u       <= st3_u;
            end
        end
    end

    // =========================================================================
    // STAGE 5: BUFFER & PRE-CALC SHIFT (NEW STAGE)
    // =========================================================================
    // Isolate BRAM Read from Shifter Logic
    reg [OUT_WIDTH-1:0] st5_lut_val;
    reg signed [31:0]   st5_diff_shift; // Pre-calculated shift amount
    reg                 st5_valid;
    reg                 st5_zero;

    always @(posedge clk) begin
        if (!aresetn) begin
            st5_valid      <= 0;
            st5_zero       <= 0;
            st5_lut_val    <= 0;
            st5_diff_shift <= 0;
        end else begin
            st5_valid <= st4_valid;
            st5_zero  <= st4_zero;

            if (st4_valid) begin
                st5_lut_val    <= st4_lut_val;
                // Move the subtraction here (logic after register is fast)
                st5_diff_shift <= st4_u - (30 - FRAC_BITS);
            end
        end
    end

    // =========================================================================
    // STAGE 6: FINAL SCALING (OUTPUT)
    // =========================================================================
    // Now the shifter inputs are fully registered
    reg [OUT_WIDTH-1:0] st6_result;
    
    always @(*) begin
        if (st5_diff_shift >= 0)
            st6_result = st5_lut_val << st5_diff_shift;
        else
            st6_result = st5_lut_val >> (-st5_diff_shift);
    end

    always @(posedge clk) begin
        if (!aresetn) begin
            o_recip_sqrt_tvalid <= 0;
            o_recip_sqrt        <= 0;
        end else begin
            o_recip_sqrt_tvalid <= st5_valid;
            if (st5_valid) begin
                if (st5_zero) 
                    o_recip_sqrt <= MAX_OUTPUT;
                else 
                    o_recip_sqrt <= st6_result;
            end
        end
    end

endmodule