`timescale 1ns / 1ps

module accumulator #(
    parameter BEAT_WIDTH = 64,      
    parameter NUM_ELEMS  = 8,
    parameter ELEM_WIDTH = 8,
    parameter SUM_WIDTH  = 18,      
    parameter SUM_SQ_WIDTH = 26     
)(
    input  wire                   clk,
    input  wire                   aresetn,
    
    input  wire [BEAT_WIDTH-1:0]  s_axis_tdata,
    input  wire                   s_axis_tvalid,
    input  wire                   s_axis_tlast,
    output wire                   s_axis_tready,

    output reg signed [SUM_WIDTH-1:0]    sum_out_int,
    output reg signed [SUM_SQ_WIDTH-1:0] sum_sq_out_int,
    // [NEW] Output the count of elements
    output reg [15:0]                    count_out, 
    output reg                           stats_valid
);
    assign s_axis_tready = 1'b1; 

    // =========================================================================
    // STAGE 0: INPUT PIPELINE
    // =========================================================================
    reg [BEAT_WIDTH-1:0] r_tdata;
    reg                  r_tvalid;
    reg                  r_tlast;
    always @(posedge clk) begin
        if (!aresetn) begin
            r_tvalid <= 0;
            r_tlast  <= 0;
            r_tdata  <= 0;
        end else begin
            r_tvalid <= s_axis_tvalid;
            r_tlast  <= s_axis_tlast;
            r_tdata  <= s_axis_tdata;
        end
    end

    wire signed [ELEM_WIDTH-1:0] el [0:NUM_ELEMS-1];
    genvar i;
    generate
        for (i = 0; i < NUM_ELEMS; i = i + 1) begin
            assign el[i] = r_tdata[(i+1)*ELEM_WIDTH-1 : i*ELEM_WIDTH];
        end
    endgenerate

    // =========================================================================
    // STAGE 1: SQUARING (DSP)
    // =========================================================================
    (* use_dsp = "yes" *) 
    reg signed [2*ELEM_WIDTH-1:0] st1_sq [0:NUM_ELEMS-1];
    reg signed [ELEM_WIDTH-1:0]   st1_val [0:NUM_ELEMS-1];
    reg                           st1_valid, st1_last;
    integer j;
    
    always @(posedge clk) begin
        if (!aresetn) begin
            st1_valid <= 0;
            st1_last <= 0;
            for (j=0; j<NUM_ELEMS; j=j+1) begin
                st1_sq[j]  <= 0;
                st1_val[j] <= 0;
            end
        end else begin
            st1_valid <= r_tvalid;
            st1_last  <= r_tlast;
            if (r_tvalid) begin
                for (j=0; j<NUM_ELEMS; j=j+1) begin
                    st1_sq[j]  <= el[j] * el[j];
                    st1_val[j] <= el[j];
                end
            end
        end
    end

    // =========================================================================
    // STAGE 2: PAIRWISE SUM
    // =========================================================================
    reg signed [ELEM_WIDTH:0]     st2_pair_sum [0:3];
    reg signed [2*ELEM_WIDTH:0]   st2_pair_sq_sum [0:3]; 
    reg                           st2_valid, st2_last;
    always @(posedge clk) begin
        if (!aresetn) begin
            st2_valid <= 0;
            st2_last <= 0;
        end else begin
            st2_valid <= st1_valid;
            st2_last  <= st1_last;
            if (st1_valid) begin
                st2_pair_sum[0]    <= st1_val[0] + st1_val[1];
                st2_pair_sq_sum[0] <= st1_sq[0]  + st1_sq[1];
                st2_pair_sum[1]    <= st1_val[2] + st1_val[3];
                st2_pair_sq_sum[1] <= st1_sq[2]  + st1_sq[3];
                st2_pair_sum[2]    <= st1_val[4] + st1_val[5];
                st2_pair_sq_sum[2] <= st1_sq[4]  + st1_sq[5];
                st2_pair_sum[3]    <= st1_val[6] + st1_val[7];
                st2_pair_sq_sum[3] <= st1_sq[6]  + st1_sq[7];
            end
        end
    end

    // =========================================================================
    // STAGE 3: QUAD SUM
    // =========================================================================
    reg signed [ELEM_WIDTH+1:0]   st3_quad_sum [0:1];
    reg signed [2*ELEM_WIDTH+1:0]   st3_quad_sq_sum [0:1];
    reg                           st3_valid, st3_last;
    always @(posedge clk) begin
        if (!aresetn) begin
            st3_valid <= 0;
            st3_last <= 0;
        end else begin
            st3_valid <= st2_valid;
            st3_last  <= st2_last;
            if (st2_valid) begin
                st3_quad_sum[0]    <= st2_pair_sum[0] + st2_pair_sum[1];
                st3_quad_sq_sum[0] <= st2_pair_sq_sum[0] + st2_pair_sq_sum[1];
                st3_quad_sum[1]    <= st2_pair_sum[2] + st2_pair_sum[3];
                st3_quad_sq_sum[1] <= st2_pair_sq_sum[2] + st2_pair_sq_sum[3];
            end
        end
    end

    // =========================================================================
    // STAGE 4: FINAL BEAT SUM
    // =========================================================================
    reg signed [15:0] st4_beat_sum;
    reg signed [19:0] st4_beat_sum_sq;
    reg               st4_valid, st4_last;
    always @(posedge clk) begin
        if (!aresetn) begin
            st4_valid <= 0;
            st4_last <= 0;
        end else begin
            st4_valid <= st3_valid;
            st4_last  <= st3_last;
            if (st3_valid) begin
                st4_beat_sum    <= st3_quad_sum[0] + st3_quad_sum[1];
                st4_beat_sum_sq <= st3_quad_sq_sum[0] + st3_quad_sq_sum[1];
            end
        end
    end

    // =========================================================================
    // STAGE 5: ACCUMULATION & ELEMENT COUNTING
    // =========================================================================
    reg signed [SUM_WIDTH-1:0]    acc_sum;
    reg signed [SUM_SQ_WIDTH-1:0] acc_sum_sq;
    reg [15:0]                    current_count; // [NEW] Internal Counter

    always @(posedge clk) begin
        if (!aresetn) begin
            acc_sum     <= 0;
            acc_sum_sq  <= 0;
            current_count <= 0;
            
            sum_out_int <= 0; 
            sum_sq_out_int <= 0; 
            count_out   <= 0;
            stats_valid <= 0;
        end else begin
            stats_valid <= 0;
            
            if (st4_valid) begin
                if (st4_last) begin
                    // Final Output
                    sum_out_int    <= acc_sum + st4_beat_sum;
                    sum_sq_out_int <= acc_sum_sq + st4_beat_sum_sq;
                    // [NEW] Output Total Count
                    count_out      <= current_count + NUM_ELEMS; 
                    stats_valid    <= 1;
                    
                    // Reset
                    acc_sum       <= 0;
                    acc_sum_sq    <= 0;
                    current_count <= 0;
                end else begin
                    // Accumulate
                    acc_sum       <= acc_sum + st4_beat_sum;
                    acc_sum_sq    <= acc_sum_sq + st4_beat_sum_sq;
                    // [NEW] Increment Count
                    current_count <= current_count + NUM_ELEMS;
                end
            end
        end
    end

endmodule