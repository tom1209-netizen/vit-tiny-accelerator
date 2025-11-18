
module norm_unit #(
    parameter integer AXIS_DATA_WIDTH = 64,   // 8 lanes x INT8 per beat (default)
    parameter integer DATA_WIDTH      = 8,
    parameter integer BEAT_PER_PACKET = 8,    // configurable beats per packet
    parameter integer MAX_BEATS       = 16,   // sizing for internal regs
    parameter integer FBITS           = 16,   // Q16 fixed-point for mean/var
    parameter integer NR_ITER         = 1     // kept for compatibility (unused)
)(
    input  wire                          clk,
    input  wire                          rst_n,

    // AXI4-Stream slave (input)
    input  wire [AXIS_DATA_WIDTH-1:0]    s_axis_tdata,
    input  wire                          s_axis_tvalid,
    input  wire                          s_axis_tlast,
    output reg                           s_axis_tready,

    // AXI4-Stream master (output)
    output reg  [AXIS_DATA_WIDTH-1:0]    m_axis_tdata,
    output reg                           m_axis_tvalid,
    output reg                           m_axis_tlast,
    input  wire                          m_axis_tready,

    // Optional scaling (per-tensor). Tie gain=16'd256 (x1.0), offset=0, eps=1
    input  wire [15:0]                   gain_q8_8,   // Q8.8 gain after norm
    input  wire [7:0]                    offset_q0,   // add after scaling
    input  wire [15:0]                   epsilon_q0   // epsilon as Q0 -> +{16'd0,eps}
);

    // ----------------------------------------------------------------------
    // Derived constants
    // ----------------------------------------------------------------------
    localparam integer LANES = AXIS_DATA_WIDTH / DATA_WIDTH; // =8
    // 1/LANES in Q16 (rounded)
    localparam [31:0] RECIP_LANES_Q16 = (32'd65536 + (LANES >> 1)) / LANES;

    // ----------------------------------------------------------------------
    // Helper functions
    // ----------------------------------------------------------------------

    // Round-away-from-zero for a signed Q(FBITS) value carried in 48 bits.
    // Returns rounded integer (signed 32-bit).
    function signed [31:0] round_away_zero_q;
        input signed [47:0] val_q; // Q(FBITS)
        reg   signed [47:0] pos;
        begin
            if (val_q >= 0)
                round_away_zero_q = (val_q + (48'sd1 <<< (FBITS-1))) >>> FBITS;
            else begin
                pos = -val_q;
                round_away_zero_q = -((pos + (48'sd1 <<< (FBITS-1))) >>> FBITS);
            end
        end
    endfunction

    // Integer square root floor(sqrt(x)) for 32-bit unsigned x.
    // Simple binary search, synthesizable.
    function [15:0] isqrt32;
        input [31:0] x;
        integer i;
        reg [15:0] r;
        reg [31:0] r2;
        begin
            r = 16'd0;
            for (i = 15; i >= 0; i = i - 1) begin
                r  = r | (16'h1 << i);
                r2 = r * r;
                if (r2 > x)
                    r = r & ~(16'h1 << i);
            end
            isqrt32 = r;
        end
    endfunction

    // ----------------------------------------------------------------------
    // State: output holding regs + counters
    // ----------------------------------------------------------------------
    reg [15:0] beat_cnt;      // counts 0..BEAT_PER_PACKET-1 on input acceptance

    // Output holding registers (1-deep)
    reg [AXIS_DATA_WIDTH-1:0] out_data_r;
    reg                       out_valid_r;
    reg                       out_last_r;

    integer i;

    // per-beat data
    reg signed [7:0]  lane [0:LANES-1];
	reg signed [15:0] lane_ext;
    reg signed [19:0] sum_beat;
    reg signed [31:0] sumsq_beat;

    // mean/var temps (Q16)
    reg   signed [63:0] mean_prod;
    reg          [63:0] ex2_prod;
    reg   signed [31:0] mean_q16;
    reg          [31:0] ex2_q16;
    reg   signed [63:0] mean_sq64;
    reg          [31:0] mean_sq_q16;
    reg          [31:0] var_q16;
    reg          [31:0] var_eps_q16;

    // inv-std temps
    reg  [15:0] sqrt_var_q0;   // integer sqrt(var_eps_q16) in Q0
    reg  [15:0] invstd_q14;    // 1/sqrt(var) in Q14
    reg  [31:0] sqrt_tmp;      // 32-bit temp
    reg  [31:0] inv_tmp;       // 32-bit temp

    // normalized lanes
    reg [AXIS_DATA_WIDTH-1:0] packed;
    reg   signed [31:0] x_q16;
    reg   signed [47:0] diff_q16;
    reg   signed [47:0] mul_q30;
    reg   signed [31:0] norm_q16;
    reg   signed [47:0] norm_q48;
    reg   signed [31:0] y_int;
    reg   signed [31:0] y_scaled;
    reg   signed [8:0]  y_add;
    reg   signed [7:0]  y_sat;

	reg [15:0] invstd_local;
	reg [15:0] sqrt_local;


    // ----------------------------------------------------------------------
    // Main always block
    // ----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset
            s_axis_tready <= 1'b1;  // always ready in this version
            m_axis_tdata  <= {AXIS_DATA_WIDTH{1'b0}};
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;

            out_data_r    <= {AXIS_DATA_WIDTH{1'b0}};
            out_valid_r   <= 1'b0;
            out_last_r    <= 1'b0;

            beat_cnt      <= 16'd0;

            sqrt_var_q0   <= 16'd0;
            invstd_q14    <= 16'd0;
        end else begin
            // ------------------------------------------------------------------
            // OUTPUT side: drive from holding regs
            // ------------------------------------------------------------------
            m_axis_tdata  <= out_data_r;
            m_axis_tvalid <= out_valid_r;
            m_axis_tlast  <= out_last_r;

            // Always ready to accept new data (debug version)
            s_axis_tready <= 1'b1;

            // ------------------------------------------------------------------
            // MAIN: if input beat handshakes now, process this BEAT in one shot
            // ------------------------------------------------------------------
            if (s_axis_tvalid && s_axis_tready) begin
                // 1) Extract 8 lanes
                for (i = 0; i < LANES; i = i + 1)
                    lane[i] = $signed(s_axis_tdata[i*DATA_WIDTH +: DATA_WIDTH]);

                // 2) sum, sumsq over 8 lanes
                sum_beat   = 20'sd0;
                sumsq_beat = 32'd0;
                for (i = 0; i < LANES; i = i + 1) begin
                    sum_beat   = sum_beat + lane[i];
                    sumsq_beat = sumsq_beat + lane[i]*lane[i];

					// // đảm bảo nhân trên signed 16-bit
					// lane_ext   = lane[i];               // sign-extend 8 -> 16
        			// sumsq_beat = sumsq_beat + lane_ext * lane_ext;
                end

                // 3) mean/var (Q16), +epsilon (Q16)
                mean_prod  = $signed(sum_beat) * $signed(RECIP_LANES_Q16);
                ex2_prod   = sumsq_beat * RECIP_LANES_Q16;

                mean_q16   = mean_prod[31:0];     // Q16
                ex2_q16    = ex2_prod[31:0];      // Q16

                mean_sq64  = $signed(mean_q16) * $signed(mean_q16); // Q32
                mean_sq_q16= mean_sq64[47:16];

                if (ex2_q16 > mean_sq_q16)
                    var_q16  = ex2_q16 - mean_sq_q16;
                else
                    var_q16  = 32'd0;

                var_eps_q16 = var_q16 + {16'd0, epsilon_q0}; // Q16

                // 3b) Compute invstd_q14 = 1/sqrt(var_real) in Q14
                // var_eps_q16 is Q16: var_real = var_eps_q16 / 2^16
                // sqrt(var_real) = sqrt(var_eps_q16) / 2^8
                // => 1/sqrt(var_real) = 2^8 / sqrt(var_eps_q16)
                // => invstd_q14 = 2^14 * 2^8 / sqrt(var_eps_q16) = 2^22 / sqrt(var_eps_q16)

				if (var_eps_q16 == 32'd0) begin
					sqrt_tmp = 32'd1;          // tránh chia 0
					inv_tmp  = 32'd0;
				end else begin
					sqrt_tmp = {16'd0, isqrt32(var_eps_q16)};   // 32-bit
					inv_tmp  = 32'd4194304 / sqrt_tmp;          // 2^22
				end

				sqrt_local = sqrt_tmp[15:0];

				if (inv_tmp[31:16] != 0)
					invstd_local = 16'h7FFF;   // saturate nếu tràn
				else
					invstd_local = inv_tmp[15:0];

				// Lưu lại vào reg cho debug (1-cycle trễ cũng không sao)
				sqrt_var_q0 <= sqrt_local;
				invstd_q14  <= invstd_local;

				// 4) normalize mỗi lane, dùng invstd_local (KHÔNG dùng invstd_q14)
				packed = {AXIS_DATA_WIDTH{1'b0}};
				for (i = 0; i < LANES; i = i + 1) begin
					x_q16     = {{8{lane[i][7]}}, lane[i], 16'd0};   // Q16
					diff_q16  = $signed(x_q16) - $signed(mean_q16);  // Q16
					mul_q30   = $signed(diff_q16) * $signed({1'b0, invstd_local}); // Q16*Q14=Q30
					norm_q16  = mul_q30 >>> 14;                      // Q16

					// round-away-from-zero(Q16)
					norm_q48  = {{16{norm_q16[31]}}, norm_q16};      // 48b
					y_int     = round_away_zero_q(norm_q48);         // int

					// optional gain (Q8.8) + offset
					y_scaled  = (y_int * $signed({1'b0, gain_q8_8})) >>> 8;
					y_add     = y_scaled[8:0] + $signed({1'b0, offset_q0});

					// saturate INT8
					if      (y_add >  9'sd127)  y_sat = 8'sd127;
					else if (y_add < -9'sd128)  y_sat = -8'sd128;
					else                        y_sat = y_add[7:0];

					packed[i*DATA_WIDTH +: DATA_WIDTH] = y_sat[7:0];
                end

                // 5) push into 1-deep output register
                out_data_r  <= packed;
                out_valid_r <= 1'b1;
                out_last_r  <= (beat_cnt == (BEAT_PER_PACKET-1));

                // beat counter advances for next input beat
                if (beat_cnt == (BEAT_PER_PACKET-1))
                    beat_cnt <= 16'd0;
                else
                    beat_cnt <= beat_cnt + 16'd1;

                // (OPTIONAL) debug prints – bật lại nếu cần:
                $display("------------------------------------------------");
                $display("[%0t] BEAT %0d IN = %h", $time, beat_cnt, s_axis_tdata);
                $display("  sum_beat    = %0d", sum_beat);
                $display("  sumsq_beat  = %0d", sumsq_beat);
                $display("  mean_q16    = 0x%08h  (real %0f)", mean_q16,  $itor(mean_q16) / 65536.0);
                $display("  var_q16     = 0x%08h  (real %0f)", var_q16,   $itor(var_q16)  / 65536.0);

                $display("  var_eps_q16 = 0x%08h", var_eps_q16);
                $display("  sqrt_var_q0 = %0d", sqrt_var_q0);
                $display("  invstd_q14  = 0x%04h  (real %0f)", invstd_q14,
                         $itor(invstd_q14) / 16384.0);
				$display("  sqrt_local = %0d", sqrt_local);
				$display("  invstd_local  = 0x%04h  (real %0f)", invstd_local, $itor(invstd_local) / 16384.0);
                $display("  PACKED      = %h", packed);
            end

            // Nếu output đang valid và phía sau đã nhận (ready) và đây không phải beat cuối
            // thì clear out_valid_r để nhận beat mới.
            if (out_valid_r && out_last_r) begin
                out_valid_r <= 1'b0;
                out_last_r  <= 1'b0;
            end
        end
    end

endmodule