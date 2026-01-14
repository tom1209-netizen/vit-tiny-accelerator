`timescale 1 ns / 1 ps

module axis_source #(
    parameter DATA_WIDTH = 64
)(
    input  wire                     clk,
    input  wire                     resetn,

    // friendly control from PS / GPIO
    input  wire                     start,          // 
    input  wire [29:0]              length_bytes,   // 

    output reg                      busy,
    output reg                      done,

    // AXI4-Stream master -> DMA S2MM
    output reg  [DATA_WIDTH-1:0]    m_axis_tdata,
    output reg  [DATA_WIDTH/8-1:0]  m_axis_tkeep,
    output reg                      m_axis_tlast,
    output reg                      m_axis_tvalid,
    input  wire                     m_axis_tready
);

    //  DATA_WIDTH = 64 => 4 byte/beat
    localparam BYTES_PER_BEAT = DATA_WIDTH/8;

    // state machine
    localparam ST_IDLE = 2'd0;
    localparam ST_SEND = 2'd1;
    localparam ST_DONE = 2'd2;

    reg [1:0] state;

    reg [29:0] total_beats;
    reg [29:0] word_cnt;

    // edge detect cho start
    reg start_d1, start_d2;
    wire start_pulse = start_d1 & ~start_d2;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            start_d1 <= 1'b0;
            start_d2 <= 1'b0;
        end else begin
            start_d1 <= start;
            start_d2 <= start_d1;
        end
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state        <= ST_IDLE;
            m_axis_tdata <= {DATA_WIDTH{1'b0}};
            m_axis_tkeep <= {DATA_WIDTH/8{1'b0}};
            m_axis_tlast <= 1'b0;
            m_axis_tvalid<= 1'b0;
            busy         <= 1'b0;
            done         <= 1'b0;
            total_beats  <= 0;
            word_cnt     <= 0;
        end else begin
            case (state)
                //--------------------------------------------------
                ST_IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    busy          <= 1'b0;
                    done          <= 1'b0;

                    if (start_pulse && (length_bytes != 0)) begin
                        // ceil(length_bytes / BYTES_PER_WORD)
                        total_beats <= (length_bytes + (BYTES_PER_BEAT-1)) >> 3; 
                        word_cnt    <= 0;
                        m_axis_tdata<= 64'b0;
                        m_axis_tkeep<= {DATA_WIDTH/8{1'b1}};
                        m_axis_tvalid <= 1'b1;
                        busy          <= 1'b1;
                        state         <= ST_SEND;
                    end
                end
                //--------------------------------------------------
                ST_SEND: begin
                    if (m_axis_tvalid && m_axis_tready) begin
                        // 
                        if (word_cnt == total_beats - 2) begin
                            m_axis_tlast <= 1'b1;
                        end else begin
                            m_axis_tlast <= 1'b0;
                        end

                        
                        m_axis_tdata <= m_axis_tdata + 1;

                        
                        word_cnt <= word_cnt + 1;

                        
                        if (word_cnt == total_beats - 1) begin
                            m_axis_tvalid <= 1'b0; 
                            m_axis_tlast  <= 1'b0;
                            busy          <= 1'b0;
                            done          <= 1'b1;
                            state         <= ST_DONE;
                        end
                    end
                end
                //--------------------------------------------------
                ST_DONE: begin
                    // 
                    if (start_pulse) begin
                        done <= 1'b0;
                        state <= ST_IDLE;
                    end
                end
                //--------------------------------------------------
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
