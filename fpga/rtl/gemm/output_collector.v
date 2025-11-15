module output_collector #(
    parameter ACC_WIDTH       = 32,
    parameter ARRAY_SIZE      = 8,
    parameter AXIS_DATA_WIDTH = 64,
    parameter VALUES_PER_BEAT = 2    // 64 bits / 32 bits = 2 INT32s
) (
    input wire clk,
    input wire rst_n,

    // Flattened input from systolic array (64 signals)
    input wire signed [ACC_WIDTH-1:0] acc_in_0_0,
    input wire signed [ACC_WIDTH-1:0] acc_in_0_1,
    input wire signed [ACC_WIDTH-1:0] acc_in_0_2,
    input wire signed [ACC_WIDTH-1:0] acc_in_0_3,
    input wire signed [ACC_WIDTH-1:0] acc_in_0_4,
    input wire signed [ACC_WIDTH-1:0] acc_in_0_5,
    input wire signed [ACC_WIDTH-1:0] acc_in_0_6,
    input wire signed [ACC_WIDTH-1:0] acc_in_0_7,

    input wire signed [ACC_WIDTH-1:0] acc_in_1_0,
    input wire signed [ACC_WIDTH-1:0] acc_in_1_1,
    input wire signed [ACC_WIDTH-1:0] acc_in_1_2,
    input wire signed [ACC_WIDTH-1:0] acc_in_1_3,
    input wire signed [ACC_WIDTH-1:0] acc_in_1_4,
    input wire signed [ACC_WIDTH-1:0] acc_in_1_5,
    input wire signed [ACC_WIDTH-1:0] acc_in_1_6,
    input wire signed [ACC_WIDTH-1:0] acc_in_1_7,

    input wire signed [ACC_WIDTH-1:0] acc_in_2_0,
    input wire signed [ACC_WIDTH-1:0] acc_in_2_1,
    input wire signed [ACC_WIDTH-1:0] acc_in_2_2,
    input wire signed [ACC_WIDTH-1:0] acc_in_2_3,
    input wire signed [ACC_WIDTH-1:0] acc_in_2_4,
    input wire signed [ACC_WIDTH-1:0] acc_in_2_5,
    input wire signed [ACC_WIDTH-1:0] acc_in_2_6,
    input wire signed [ACC_WIDTH-1:0] acc_in_2_7,

    input wire signed [ACC_WIDTH-1:0] acc_in_3_0,
    input wire signed [ACC_WIDTH-1:0] acc_in_3_1,
    input wire signed [ACC_WIDTH-1:0] acc_in_3_2,
    input wire signed [ACC_WIDTH-1:0] acc_in_3_3,
    input wire signed [ACC_WIDTH-1:0] acc_in_3_4,
    input wire signed [ACC_WIDTH-1:0] acc_in_3_5,
    input wire signed [ACC_WIDTH-1:0] acc_in_3_6,
    input wire signed [ACC_WIDTH-1:0] acc_in_3_7,

    input wire signed [ACC_WIDTH-1:0] acc_in_4_0,
    input wire signed [ACC_WIDTH-1:0] acc_in_4_1,
    input wire signed [ACC_WIDTH-1:0] acc_in_4_2,
    input wire signed [ACC_WIDTH-1:0] acc_in_4_3,
    input wire signed [ACC_WIDTH-1:0] acc_in_4_4,
    input wire signed [ACC_WIDTH-1:0] acc_in_4_5,
    input wire signed [ACC_WIDTH-1:0] acc_in_4_6,
    input wire signed [ACC_WIDTH-1:0] acc_in_4_7,

    input wire signed [ACC_WIDTH-1:0] acc_in_5_0,
    input wire signed [ACC_WIDTH-1:0] acc_in_5_1,
    input wire signed [ACC_WIDTH-1:0] acc_in_5_2,
    input wire signed [ACC_WIDTH-1:0] acc_in_5_3,
    input wire signed [ACC_WIDTH-1:0] acc_in_5_4,
    input wire signed [ACC_WIDTH-1:0] acc_in_5_5,
    input wire signed [ACC_WIDTH-1:0] acc_in_5_6,
    input wire signed [ACC_WIDTH-1:0] acc_in_5_7,

    input wire signed [ACC_WIDTH-1:0] acc_in_6_0,
    input wire signed [ACC_WIDTH-1:0] acc_in_6_1,
    input wire signed [ACC_WIDTH-1:0] acc_in_6_2,
    input wire signed [ACC_WIDTH-1:0] acc_in_6_3,
    input wire signed [ACC_WIDTH-1:0] acc_in_6_4,
    input wire signed [ACC_WIDTH-1:0] acc_in_6_5,
    input wire signed [ACC_WIDTH-1:0] acc_in_6_6,
    input wire signed [ACC_WIDTH-1:0] acc_in_6_7,

    input wire signed [ACC_WIDTH-1:0] acc_in_7_0,
    input wire signed [ACC_WIDTH-1:0] acc_in_7_1,
    input wire signed [ACC_WIDTH-1:0] acc_in_7_2,
    input wire signed [ACC_WIDTH-1:0] acc_in_7_3,
    input wire signed [ACC_WIDTH-1:0] acc_in_7_4,
    input wire signed [ACC_WIDTH-1:0] acc_in_7_5,
    input wire signed [ACC_WIDTH-1:0] acc_in_7_6,
    input wire signed [ACC_WIDTH-1:0] acc_in_7_7,

    input wire acc_done_0_0,
    input wire acc_done_0_1,
    input wire acc_done_0_2,
    input wire acc_done_0_3,
    input wire acc_done_0_4,
    input wire acc_done_0_5,
    input wire acc_done_0_6,
    input wire acc_done_0_7,

    input wire acc_done_1_0,
    input wire acc_done_1_1,
    input wire acc_done_1_2,
    input wire acc_done_1_3,
    input wire acc_done_1_4,
    input wire acc_done_1_5,
    input wire acc_done_1_6,
    input wire acc_done_1_7,

    input wire acc_done_2_0,
    input wire acc_done_2_1,
    input wire acc_done_2_2,
    input wire acc_done_2_3,
    input wire acc_done_2_4,
    input wire acc_done_2_5,
    input wire acc_done_2_6,
    input wire acc_done_2_7,

    input wire acc_done_3_0,
    input wire acc_done_3_1,
    input wire acc_done_3_2,
    input wire acc_done_3_3,
    input wire acc_done_3_4,
    input wire acc_done_3_5,
    input wire acc_done_3_6,
    input wire acc_done_3_7,

    input wire acc_done_4_0,
    input wire acc_done_4_1,
    input wire acc_done_4_2,
    input wire acc_done_4_3,
    input wire acc_done_4_4,
    input wire acc_done_4_5,
    input wire acc_done_4_6,
    input wire acc_done_4_7,

    input wire acc_done_5_0,
    input wire acc_done_5_1,
    input wire acc_done_5_2,
    input wire acc_done_5_3,
    input wire acc_done_5_4,
    input wire acc_done_5_5,
    input wire acc_done_5_6,
    input wire acc_done_5_7,

    input wire acc_done_6_0,
    input wire acc_done_6_1,
    input wire acc_done_6_2,
    input wire acc_done_6_3,
    input wire acc_done_6_4,
    input wire acc_done_6_5,
    input wire acc_done_6_6,
    input wire acc_done_6_7,

    input wire acc_done_7_0,
    input wire acc_done_7_1,
    input wire acc_done_7_2,
    input wire acc_done_7_3,
    input wire acc_done_7_4,
    input wire acc_done_7_5,
    input wire acc_done_7_6,
    input wire acc_done_7_7,

    input wire start_output,

    // AXI-Stream output
    output reg  [AXIS_DATA_WIDTH-1:0] m_axis_tdata,
    output reg                        m_axis_tvalid,
    output reg                        m_axis_tlast,
    input  wire                       m_axis_tready,

    // Status
    output reg done
);

    reg [3:0] row_idx;
    reg [3:0] col_idx;
    reg       active;

    // Function to select a value by (row, col)
    function [ACC_WIDTH-1:0] get_acc;
        input [3:0] r;
        input [3:0] c;
        begin
            case (r)
                4'd0:
                case (c)
                    4'd0: get_acc = acc_in_0_0;
                    4'd1: get_acc = acc_in_0_1;
                    4'd2: get_acc = acc_in_0_2;
                    4'd3: get_acc = acc_in_0_3;
                    4'd4: get_acc = acc_in_0_4;
                    4'd5: get_acc = acc_in_0_5;
                    4'd6: get_acc = acc_in_0_6;
                    4'd7: get_acc = acc_in_0_7;
                    default: get_acc = {ACC_WIDTH{1'b0}};
                endcase
                4'd1:
                case (c)
                    4'd0: get_acc = acc_in_1_0;
                    4'd1: get_acc = acc_in_1_1;
                    4'd2: get_acc = acc_in_1_2;
                    4'd3: get_acc = acc_in_1_3;
                    4'd4: get_acc = acc_in_1_4;
                    4'd5: get_acc = acc_in_1_5;
                    4'd6: get_acc = acc_in_1_6;
                    4'd7: get_acc = acc_in_1_7;
                    default: get_acc = {ACC_WIDTH{1'b0}};
                endcase
                4'd2:
                case (c)
                    4'd0: get_acc = acc_in_2_0;
                    4'd1: get_acc = acc_in_2_1;
                    4'd2: get_acc = acc_in_2_2;
                    4'd3: get_acc = acc_in_2_3;
                    4'd4: get_acc = acc_in_2_4;
                    4'd5: get_acc = acc_in_2_5;
                    4'd6: get_acc = acc_in_2_6;
                    4'd7: get_acc = acc_in_2_7;
                    default: get_acc = {ACC_WIDTH{1'b0}};
                endcase
                4'd3:
                case (c)
                    4'd0: get_acc = acc_in_3_0;
                    4'd1: get_acc = acc_in_3_1;
                    4'd2: get_acc = acc_in_3_2;
                    4'd3: get_acc = acc_in_3_3;
                    4'd4: get_acc = acc_in_3_4;
                    4'd5: get_acc = acc_in_3_5;
                    4'd6: get_acc = acc_in_3_6;
                    4'd7: get_acc = acc_in_3_7;
                    default: get_acc = {ACC_WIDTH{1'b0}};
                endcase
                4'd4:
                case (c)
                    4'd0: get_acc = acc_in_4_0;
                    4'd1: get_acc = acc_in_4_1;
                    4'd2: get_acc = acc_in_4_2;
                    4'd3: get_acc = acc_in_4_3;
                    4'd4: get_acc = acc_in_4_4;
                    4'd5: get_acc = acc_in_4_5;
                    4'd6: get_acc = acc_in_4_6;
                    4'd7: get_acc = acc_in_4_7;
                    default: get_acc = {ACC_WIDTH{1'b0}};
                endcase
                4'd5:
                case (c)
                    4'd0: get_acc = acc_in_5_0;
                    4'd1: get_acc = acc_in_5_1;
                    4'd2: get_acc = acc_in_5_2;
                    4'd3: get_acc = acc_in_5_3;
                    4'd4: get_acc = acc_in_5_4;
                    4'd5: get_acc = acc_in_5_5;
                    4'd6: get_acc = acc_in_5_6;
                    4'd7: get_acc = acc_in_5_7;
                    default: get_acc = {ACC_WIDTH{1'b0}};
                endcase
                4'd6:
                case (c)
                    4'd0: get_acc = acc_in_6_0;
                    4'd1: get_acc = acc_in_6_1;
                    4'd2: get_acc = acc_in_6_2;
                    4'd3: get_acc = acc_in_6_3;
                    4'd4: get_acc = acc_in_6_4;
                    4'd5: get_acc = acc_in_6_5;
                    4'd6: get_acc = acc_in_6_6;
                    4'd7: get_acc = acc_in_6_7;
                    default: get_acc = {ACC_WIDTH{1'b0}};
                endcase
                4'd7:
                case (c)
                    4'd0: get_acc = acc_in_7_0;
                    4'd1: get_acc = acc_in_7_1;
                    4'd2: get_acc = acc_in_7_2;
                    4'd3: get_acc = acc_in_7_3;
                    4'd4: get_acc = acc_in_7_4;
                    4'd5: get_acc = acc_in_7_5;
                    4'd6: get_acc = acc_in_7_6;
                    4'd7: get_acc = acc_in_7_7;
                    default: get_acc = {ACC_WIDTH{1'b0}};
                endcase
                default: get_acc = {ACC_WIDTH{1'b0}};
            endcase
        end
    endfunction

    function cell_ready;
        input [3:0] r;
        input [3:0] c;
        begin
            case (r)
                4'd0:
                case (c)
                    4'd0: cell_ready = acc_done_0_0;
                    4'd1: cell_ready = acc_done_0_1;
                    4'd2: cell_ready = acc_done_0_2;
                    4'd3: cell_ready = acc_done_0_3;
                    4'd4: cell_ready = acc_done_0_4;
                    4'd5: cell_ready = acc_done_0_5;
                    4'd6: cell_ready = acc_done_0_6;
                    4'd7: cell_ready = acc_done_0_7;
                    default: cell_ready = 1'b0;
                endcase
                4'd1:
                case (c)
                    4'd0: cell_ready = acc_done_1_0;
                    4'd1: cell_ready = acc_done_1_1;
                    4'd2: cell_ready = acc_done_1_2;
                    4'd3: cell_ready = acc_done_1_3;
                    4'd4: cell_ready = acc_done_1_4;
                    4'd5: cell_ready = acc_done_1_5;
                    4'd6: cell_ready = acc_done_1_6;
                    4'd7: cell_ready = acc_done_1_7;
                    default: cell_ready = 1'b0;
                endcase
                4'd2:
                case (c)
                    4'd0: cell_ready = acc_done_2_0;
                    4'd1: cell_ready = acc_done_2_1;
                    4'd2: cell_ready = acc_done_2_2;
                    4'd3: cell_ready = acc_done_2_3;
                    4'd4: cell_ready = acc_done_2_4;
                    4'd5: cell_ready = acc_done_2_5;
                    4'd6: cell_ready = acc_done_2_6;
                    4'd7: cell_ready = acc_done_2_7;
                    default: cell_ready = 1'b0;
                endcase
                4'd3:
                case (c)
                    4'd0: cell_ready = acc_done_3_0;
                    4'd1: cell_ready = acc_done_3_1;
                    4'd2: cell_ready = acc_done_3_2;
                    4'd3: cell_ready = acc_done_3_3;
                    4'd4: cell_ready = acc_done_3_4;
                    4'd5: cell_ready = acc_done_3_5;
                    4'd6: cell_ready = acc_done_3_6;
                    4'd7: cell_ready = acc_done_3_7;
                    default: cell_ready = 1'b0;
                endcase
                4'd4:
                case (c)
                    4'd0: cell_ready = acc_done_4_0;
                    4'd1: cell_ready = acc_done_4_1;
                    4'd2: cell_ready = acc_done_4_2;
                    4'd3: cell_ready = acc_done_4_3;
                    4'd4: cell_ready = acc_done_4_4;
                    4'd5: cell_ready = acc_done_4_5;
                    4'd6: cell_ready = acc_done_4_6;
                    4'd7: cell_ready = acc_done_4_7;
                    default: cell_ready = 1'b0;
                endcase
                4'd5:
                case (c)
                    4'd0: cell_ready = acc_done_5_0;
                    4'd1: cell_ready = acc_done_5_1;
                    4'd2: cell_ready = acc_done_5_2;
                    4'd3: cell_ready = acc_done_5_3;
                    4'd4: cell_ready = acc_done_5_4;
                    4'd5: cell_ready = acc_done_5_5;
                    4'd6: cell_ready = acc_done_5_6;
                    4'd7: cell_ready = acc_done_5_7;
                    default: cell_ready = 1'b0;
                endcase
                4'd6:
                case (c)
                    4'd0: cell_ready = acc_done_6_0;
                    4'd1: cell_ready = acc_done_6_1;
                    4'd2: cell_ready = acc_done_6_2;
                    4'd3: cell_ready = acc_done_6_3;
                    4'd4: cell_ready = acc_done_6_4;
                    4'd5: cell_ready = acc_done_6_5;
                    4'd6: cell_ready = acc_done_6_6;
                    4'd7: cell_ready = acc_done_6_7;
                    default: cell_ready = 1'b0;
                endcase
                4'd7:
                case (c)
                    4'd0: cell_ready = acc_done_7_0;
                    4'd1: cell_ready = acc_done_7_1;
                    4'd2: cell_ready = acc_done_7_2;
                    4'd3: cell_ready = acc_done_7_3;
                    4'd4: cell_ready = acc_done_7_4;
                    4'd5: cell_ready = acc_done_7_5;
                    4'd6: cell_ready = acc_done_7_6;
                    4'd7: cell_ready = acc_done_7_7;
                    default: cell_ready = 1'b0;
                endcase
                default: cell_ready = 1'b0;
            endcase
        end
    endfunction

    function beat_ready;
        input [3:0] r;
        input [3:0] c;
        integer offset;
        begin
            beat_ready = 1'b1;
            for (offset = 0; offset < VALUES_PER_BEAT; offset = offset + 1) begin
                if (c + offset < ARRAY_SIZE) beat_ready = beat_ready & cell_ready(r, c + offset);
            end
        end
    endfunction

    // Stream state machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tdata  <= {AXIS_DATA_WIDTH{1'b0}};
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            row_idx       <= 4'd0;
            col_idx       <= 4'd0;
            active        <= 1'b0;
            done          <= 1'b0;
        end else begin
            if (start_output && !active) begin
                active  <= 1'b1;
                row_idx <= 4'd0;
                col_idx <= 4'd0;
                done    <= 1'b0;
            end

            if (active) begin
                // Issue next beat when either idle or accepted
                if (!m_axis_tvalid || m_axis_tready) begin
                    if (row_idx < ARRAY_SIZE && col_idx < ARRAY_SIZE) begin
                        if (beat_ready(row_idx, col_idx)) begin
                            // Pack VALUES_PER_BEAT accumulators into 64-bit stream
                            m_axis_tdata[31:0] <= get_acc(row_idx, col_idx);
                            if (col_idx + 1 < ARRAY_SIZE)
                                m_axis_tdata[63:32] <= get_acc(row_idx, col_idx + 1);
                            else m_axis_tdata[63:32] <= {ACC_WIDTH{1'b0}};

                            m_axis_tvalid <= 1'b1;

                            // TLAST on final beat
                            if (row_idx == ARRAY_SIZE-1 && col_idx + VALUES_PER_BEAT >= ARRAY_SIZE) begin
                                m_axis_tlast <= 1'b1;
                                done         <= 1'b1;
                                active       <= 1'b0;
                            end else begin
                                m_axis_tlast <= 1'b0;
                            end

                            // Advance indices by VALUES_PER_BEAT
                            if (col_idx + VALUES_PER_BEAT >= ARRAY_SIZE) begin
                                col_idx <= 4'd0;
                                row_idx <= row_idx + 4'd1;
                            end else begin
                                col_idx <= col_idx + VALUES_PER_BEAT;
                            end
                        end else begin
                            m_axis_tvalid <= 1'b0;
                            m_axis_tlast  <= 1'b0;
                        end
                    end else begin
                        m_axis_tvalid <= 1'b0;
                        m_axis_tlast  <= 1'b0;
                    end
                end
            end else begin
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
            end
        end
    end

endmodule
