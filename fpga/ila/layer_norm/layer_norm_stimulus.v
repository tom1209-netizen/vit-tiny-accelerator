`timescale 1ns / 1ps

module layer_norm_stimulus #(
    parameter DATA_WIDTH = 64,
    parameter STAT_WIDTH = 32
) (
    input wire clk,
    input wire rst_n,
    input wire start_trigger,
    
    output wire [STAT_WIDTH-1:0] cfg_gamma,
    output wire [STAT_WIDTH-1:0] cfg_beta,

    output reg  [DATA_WIDTH-1:0] m_axis_tdata,   // Changed to reg for always @(*)
    output reg                   m_axis_tvalid,
    output reg                   m_axis_tlast,   // Changed to reg for always @(*)
    input  wire                  m_axis_tready
);

    reg [3:0] beat_count;
    localparam BURST_LEN = 10;

    localparam IDLE = 0;
    localparam RUN = 1;
    reg  state;

    // Trigger Edge Detection
    wire start_trigger_edge;
    reg start_d1, start_d2;
    assign start_trigger_edge = start_d1 && ~start_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_d1 <= 0;
            start_d2 <= 0;
        end else begin
            start_d1 <= start_trigger;
            start_d2 <= start_d1;
        end
    end

    //-------------------------------------------------------------------------
    // 1. COMBINATIONAL DATA PATH 
    //-------------------------------------------------------------------------
    // Logic updates IMMEDIATELY when beat_count changes
    assign cfg_gamma = 32'd2 << 16;
    assign cfg_beta = 2'd1 << 16;
    always @(*) begin
        // Default values to prevent latches
        m_axis_tdata = {DATA_WIDTH{1'b0}};
        

        if (state == RUN) begin
            // Data Pattern
            case (beat_count)
                0: m_axis_tdata = {8{8'h05}};  // All 5
                1: m_axis_tdata = {8{8'hF0}};  // All -16
                2: m_axis_tdata = 64'hF0_05_F0_05_F0_05_F0_05;  // Alternating
                3: m_axis_tdata = 64'h80_7F_80_7F_80_7F_80_7F;  
                4: m_axis_tdata = 64'h12_34_56_78_9a_bc_de_f0;
                5: m_axis_tdata = 64'hf0_de_bc_9a_78_56_34_12;
                6: m_axis_tdata = 64'h00_01_02_03_04_05_06_07;
                7: m_axis_tdata = 64'h10_20_30_40_50_60_70_80;
                8: m_axis_tdata = 64'h36_36_36_36_36_36_36_36;
                9: m_axis_tdata = 64'hFF_FF_FF_FF_FF_FF_FF_FF;

                default: m_axis_tdata = 64'h0;
            endcase

            
        end
    end

    //-------------------------------------------------------------------------
    // 2. SEQUENTIAL CONTROL PATH (State & Counter)
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            m_axis_tvalid <= 1'b0;
            beat_count    <= 0;
        end else begin
            case (state)
                IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    beat_count    <= 0;

                    if (start_trigger_edge) begin
                        state         <= RUN;
                        m_axis_tvalid <= 1'b1;  // Assert valid immediately for next cycle
                    end
                end

                RUN: begin
                    m_axis_tlast <= (beat_count == BURST_LEN - 2);  
                    // Handshake Logic
                    if (m_axis_tready && m_axis_tvalid) begin
                        // Check if this is the LAST beat
                        if (beat_count == BURST_LEN - 1) begin
                            state         <= IDLE;
                            m_axis_tvalid <= 1'b0;
                            beat_count    <= 0;
                        end else begin
                            // Not the last beat, just increment
                            beat_count <= beat_count + 1;
                        end
                    end
                end
            endcase
        end
    end

endmodule
