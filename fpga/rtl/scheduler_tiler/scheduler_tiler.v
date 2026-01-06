`timescale 1ns / 1ps
module scheduler_tiler #(
    parameter ADDR_WIDTH = 16
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire soft_reset,
    input  wire irq_enable
    output reg  [2:0] status,
    
    // Configuration inputs
    input  wire [31:0] tile_cfg,
    input  wire [31:0] layer_cfg,
    input  wire [31:0] addr_a_base,
    input  wire [31:0] addr_b_base,
    input  wire [31:0] addr_c_base,
    
    // DMA interface
    output reg         dma_start,
    output reg  [31:0] dma_addr,
    output reg  [31:0] dma_len,
    output reg         dma_dir,
    input  wire        dma_done,
    input  wire        shim_valid_out,
    
    // Memory interface
    output reg                    wr_en,
    output reg  [ADDR_WIDTH-1:0]  wr_addr,
    output reg                    rd_en,
    output reg  [ADDR_WIDTH-1:0]  rd_addr,
    
    // GEMM interface
    output reg  gemm_start,
    input  wire gemm_done,
    
    // Convolution interface
    output reg  conv_start,
    input  wire conv_done,
    output reg  [15:0] conv_height,
    output reg  [15:0] conv_width,
    
    // Control signals
    output wire [2:0] op_class_out,
    output reg        compute_data_valid,
    output reg        add_en,
    
    // Requant interface
    input  wire [31:0] requant_scale,
    input  wire [31:0] requant_shift,
    input  wire        requant_valid,
);

    // Status flags
    localparam STAT_IDLE  = 3'b000; // Idle/Ready
    localparam STAT_DONE  = 3'b001; // Bit 0: Done
    localparam STAT_BUSY  = 3'b010; // Bit 1: Busy
    localparam STAT_ERROR = 3'b100; // Bit 2: Error

    // FSM state
    localparam S_IDLE         = 0;
    localparam S_LOAD_WEIGHT  = 1;
    localparam S_LOAD_INPUT   = 2;
    localparam S_COMPUTE      = 3;
    localparam S_STORE_OUTPUT = 4;
    localparam S_DONE         = 5;
    
    // Memory address
    localparam PING_ADDR    = 0;
    localparam PONG_ADDR    = 25600;
    localparam WEIGHT_ADDR  = 51200;
    localparam SCRATCH_ADDR = 57344;
    localparam SCRATCH_OFF  = 61440;
    
    localparam OFFSET_Q     = 0;
    localparam OFFSET_SCORE = 12288;
    
    // Tile offsets
    localparam TILE_OFFSET_S1      = 16'd6272;
    localparam TILE_OFFSET_S2      = 16'd784;
    localparam TILE_OFFSET_S3      = 16'd3920;
    localparam TILE_OFFSET_S4      = 16'd1960;
    localparam CLASSIFIER_TILE_OFFSET = 16'd64;

    // Data length
    localparam LEN_WEIGHT = 24576;
    localparam LEN_INPUT  = 150528;
    localparam LEN_OUTPUT = 50000;
    
    // Block role
    localparam ROLE_CONV  = 4'd1;
    localparam ROLE_CLASS = 4'd5; 

    // Operation opcodes
    localparam OP_QKV     = 3'b000;
    localparam OP_SCORE   = 3'b001;
    localparam OP_SOFTMAX = 3'b010;
    localparam OP_CONTEXT = 3'b011;
    localparam OP_MLP1    = 3'b100;
    localparam OP_MLP2    = 3'b101;
    localparam OP_PROJ    = 3'b110;
    localparam OP_EXPAND  = 3'b111;
    
    localparam OP_GAP     = 3'b000;
    localparam OP_NORM    = 3'b001;
    localparam OP_CLASS   = 3'b010;

    // Internal registers
    reg        buf_sel;
    reg        op_started;
    reg [3:0]  state;
    reg [3:0]  next_state;
    reg [3:0]  tiling_idx;
    reg [3:0]  active_stage;
    reg [3:0]  internal_block_cnt;
    reg [3:0]  saved_tile_idx;
    reg [11:0] inner_loop_cnt;
    reg [5:0]  add_counter;
    reg [31:0] r_layer_cfg;
    reg [31:0] r_tile_cfg;
    reg [31:0] r_addr_a_base;
    reg [31:0] r_addr_b_base;
    reg [31:0] r_addr_c_base;
    reg [15:0] ptr_wr;
    reg [15:0] ptr_rd;

    // Wire declarations
    wire [3:0]  stage_id     = r_layer_cfg[27:24];
    wire [3:0]  block_role   = r_layer_cfg[23:20];
    wire [2:0]  op_class     = r_tile_cfg[30:28];
    wire [3:0]  new_stage    = layer_cfg[27:24];
    wire        is_writeback = (r_layer_cfg[29:28] == 2'b01);
    wire        is_depthwise = (block_role == ROLE_CONV);
    wire [15:0] base_addr_wr;
    wire [15:0] base_addr_rd;
    wire [3:0]  max_tiles;
    wire [5:0]  max_add_loop;
    wire [11:0] current_burst_limit;

    assign op_class_out         = op_class;
    assign max_add_loop         = get_add_loop(stage_id, block_role, internal_block_cnt);
    assign base_addr_wr         = get_write_base(buf_sel, active_stage, op_class, block_role, tiling_idx);
    assign base_addr_rd         = get_read_base(buf_sel, active_stage, op_class, block_role, tiling_idx);
    assign current_burst_limit  = get_burst_limit(stage_id, block_role, op_class);
    assign max_tiles            = get_max_tiles(stage_id, op_class, block_role);

    // Helper functions
    function [15:0] get_tile_offset (input [3:0] stage, input [3:0] t_idx);
        begin
            case (stage)
                4'd1: get_tile_offset = t_idx * TILE_OFFSET_S1;
                4'd2: get_tile_offset = t_idx * TILE_OFFSET_S2;
                4'd3: get_tile_offset = t_idx * TILE_OFFSET_S3; 
                4'd4: get_tile_offset = t_idx * TILE_OFFSET_S4;
                4'd5: get_tile_offset = t_idx * CLASSIFIER_TILE_OFFSET; 
                default: get_tile_offset = 0;
            endcase
        end
    endfunction

    function [15:0] get_resolution (input [3:0] stage);
        case(stage)
            4'd1:    get_resolution = 56;
            4'd2:    get_resolution = 28;
            4'd3:    get_resolution = 14;
            4'd4:    get_resolution = 7;
            4'd5:    get_resolution = 1;
            default: get_resolution = 56;
        endcase
    endfunction

    function [3:0] get_max_tiles (input [3:0] stage, input [2:0] op, input [3:0] role);
        case (stage)
            4'd1: begin
                get_max_tiles = 4'd3;
            end
            
            4'd2: begin
                if (op == OP_EXPAND || (role == ROLE_CONV && op == 3'b000))
                    get_max_tiles = 0;
                else
                    get_max_tiles = 15;
            end
            
            4'd3: begin
                get_max_tiles = 0;
            end
            
            4'd4: begin
                get_max_tiles = 0;
            end
            
            4'd5: begin
                if (role == ROLE_CLASS && op == OP_CLASS)
                    get_max_tiles = 15;
                else
                    get_max_tiles = 0;
            end
            
            default: begin
                get_max_tiles = 0;
            end
        endcase
    endfunction

    function [5:0] get_add_loop (input [3:0] stage, input [3:0] role, input [3:0] block_cnt);
        if (stage == 0 && role != ROLE_CONV)
            get_add_loop = (block_cnt == 0) ? 6'd3 : 6'd35;
        else
            get_add_loop = 6'd0;
    endfunction
    
    function [11:0] get_burst_limit (input [3:0] stage, input [3:0] role, input [2:0] op);
        get_burst_limit = 12'd0;
    endfunction

    // Read base address
    function [15:0] get_read_base (input sel, input [3:0] stage, input [2:0] op, input [3:0] role, input [3:0] t_idx);
        reg [15:0] base_in;
        reg [15:0] base_out;
        reg [15:0] current_offset;
        begin
            base_in        = sel ? PING_ADDR : PONG_ADDR;
            base_out       = sel ? PONG_ADDR : PING_ADDR;
            current_offset = get_tile_offset(stage, t_idx);
            
            if (stage == 5) begin
                case (op)
                    OP_GAP: begin
                        get_read_base = base_in;
                    end
                    // [FIX] Thay BASE_A -> PING_ADDR
                    OP_NORM: begin
                        get_read_base = PING_ADDR;
                    end
                    OP_CLASS: begin
                        get_read_base = PING_ADDR;
                    end
                    default: begin
                        get_read_base = base_in;
                    end
                endcase
            end else if (stage == 1) begin
                if (role == ROLE_CONV)
                    get_read_base = SCRATCH_ADDR;
                else if (op == OP_EXPAND)
                    get_read_base = base_in + current_offset;
                else if (op == OP_PROJ)
                    get_read_base = SCRATCH_OFF;
                else
                    get_read_base = base_in;
            end else begin
                if (op == OP_EXPAND) begin
                    get_read_base = base_in;
                end else if (role == ROLE_CONV) begin
                    if (t_idx == 0 && op == 3'b000)
                        get_read_base = SCRATCH_ADDR;
                    else
                        get_read_base = base_out + current_offset;
                end else begin
                    case (op)
                        OP_QKV: begin
                            get_read_base = base_in + current_offset;
                        end
                        OP_SCORE: begin
                            get_read_base = base_out + OFFSET_Q + current_offset;
                        end
                        OP_SOFTMAX: begin
                            get_read_base = base_out + OFFSET_SCORE + current_offset;
                        end
                        OP_CONTEXT: begin
                            get_read_base = base_out + OFFSET_SCORE + current_offset;
                        end
                        OP_PROJ: begin
                            get_read_base = base_out + OFFSET_Q + current_offset;
                        end
                        OP_MLP1: begin
                            get_read_base = base_out + current_offset;
                        end
                        OP_MLP2: begin
                            get_read_base = SCRATCH_ADDR;
                        end
                        default: begin
                            get_read_base = base_in;
                        end
                    endcase
                end
            end
        end
    endfunction

    // Write base address
    function [15:0] get_write_base (input sel, input [3:0] stage, input [2:0] op, input [3:0] role, input [3:0] t_idx);
        reg [15:0] base_out;
        reg [15:0] current_offset;
        begin
            base_out       = (sel == 0) ? PONG_ADDR : PING_ADDR;
            current_offset = get_tile_offset(stage, t_idx);
            
            if (stage == 5) begin
                case (op)
                    OP_GAP: begin
                        get_write_base = PING_ADDR;
                    end
                    OP_NORM: begin
                        get_write_base = PING_ADDR;
                    end
                    OP_CLASS: begin
                        get_write_base = PONG_ADDR + current_offset;
                    end
                    default: begin
                        get_write_base = PING_ADDR;
                    end
                endcase
            end else if (stage == 1) begin
                if (role == ROLE_CONV)
                    get_write_base = SCRATCH_OFF;
                else if (op == OP_EXPAND)
                    get_write_base = SCRATCH_ADDR;
                else if (op == OP_PROJ)
                    get_write_base = base_out + current_offset;
                else
                    get_write_base = base_out;
            end else begin
                if (op == OP_EXPAND) begin
                    get_write_base = SCRATCH_ADDR;
                end else if (role == ROLE_CONV) begin
                    if (t_idx == 0 && op == 3'b000)
                        get_write_base = SCRATCH_OFF;
                    else
                        get_write_base = base_out + current_offset;
                end else begin
                    case (op)
                        OP_QKV: begin
                            get_write_base = base_out + OFFSET_Q + current_offset;
                        end
                        OP_SCORE: begin
                            get_write_base = base_out + OFFSET_SCORE + current_offset;
                        end
                        OP_SOFTMAX: begin
                            get_write_base = base_out + OFFSET_SCORE + current_offset;
                        end
                        OP_CONTEXT: begin
                            get_write_base = base_out + OFFSET_Q + current_offset;
                        end
                        OP_PROJ: begin
                            get_write_base = base_out + current_offset;
                        end
                        OP_MLP1: begin
                            get_write_base = SCRATCH_ADDR;
                        end
                        OP_MLP2: begin
                            get_write_base = base_out + current_offset;
                        end
                        default: begin
                            get_write_base = base_out;
                        end
                    endcase
                end
            end
        end
    endfunction

    // FSM - State Register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= S_IDLE;
            internal_block_cnt <= 0;
            active_stage       <= 4'hF;
            tiling_idx         <= 0;
            add_counter        <= 0;
            buf_sel            <= 0;
            op_started         <= 0;
            r_layer_cfg        <= 0;
            r_tile_cfg         <= 0;
            ptr_wr             <= 0;
            ptr_rd             <= 0;
            inner_loop_cnt     <= 0;
            saved_tile_idx     <= 0;
            r_addr_a_base      <= 0;
            r_addr_b_base      <= 0;
            r_addr_c_base      <= 0;
            conv_height        <= 0;
            conv_width         <= 0;
        end else if (soft_reset) begin
            state              <= S_IDLE;
            internal_block_cnt <= 0;
            active_stage       <= 4'hF;
            op_started         <= 0;
            buf_sel            <= 0;
        end else begin
            state <= next_state;

            if (next_state == S_DONE && state != S_DONE) begin
                if (stage_id == 1 && op_class == OP_PROJ)
                    buf_sel <= ~buf_sel;
                else if (stage_id >= 2 && stage_id < 5 && op_class == OP_MLP2)
                    buf_sel <= ~buf_sel;
                else if (stage_id != 1 && stage_id < 2)
                    buf_sel <= ~buf_sel;
                
                if (stage_id == 0 && internal_block_cnt == 1) begin
                    internal_block_cnt <= 0;
                    saved_tile_idx     <= saved_tile_idx + 1;
                end else begin
                    internal_block_cnt <= internal_block_cnt + 1;
                end
            end
            
            if (state == S_IDLE && start) begin
                r_tile_cfg    <= tile_cfg;
                r_layer_cfg   <= layer_cfg;
                r_addr_a_base <= addr_a_base;
                r_addr_b_base <= addr_b_base;
                r_addr_c_base <= addr_c_base;
                conv_height   <= get_resolution(layer_cfg[27:24]);
                conv_width    <= get_resolution(layer_cfg[27:24]);
                
                if (new_stage != active_stage) begin
                    internal_block_cnt <= 0;
                    active_stage       <= new_stage;
                    saved_tile_idx     <= 0;
                end
                
                add_counter <= 0;
                op_started  <= 0;
                tiling_idx  <= (stage_id == 0) ? saved_tile_idx : 0;
            end
            
            if (state == S_COMPUTE) begin
                if (gemm_start || conv_start)
                    op_started <= 1;
                    
                if ((is_depthwise && conv_done) || (!is_depthwise && gemm_done)) begin
                    op_started <= 0;
                    
                    if (add_counter < max_add_loop) begin
                        add_counter <= add_counter + 1;
                    end else begin
                        add_counter <= 0;
                        
                        if (tiling_idx < max_tiles)
                            tiling_idx <= tiling_idx + 1;
                        else
                            tiling_idx <= 0;
                    end
                end
            end
        end
    end
    
    // FSM - Combinational Logic
    always @(*) begin
        next_state = state;
        dma_start  = 0;
        dma_dir    = 0;
        gemm_start = 0;
        conv_start = 0;
        status     = 1;
        add_en     = 0;
        dma_len    = 0;
        dma_addr   = 0;
        status     = STAT_BUSY;
        
        case (state)
            S_IDLE: begin
                status = STAT_IDLE;
                if (start)
                    next_state = S_LOAD_WEIGHT;
            end
            
            S_LOAD_WEIGHT: begin
                dma_start = 1;
                dma_addr  = r_addr_b_base;
                dma_len   = LEN_WEIGHT;
                
                if (dma_done)
                    next_state = (internal_block_cnt == 0) ? S_LOAD_INPUT : S_COMPUTE;
            end
            
            S_LOAD_INPUT: begin
                dma_start = 1;
                dma_addr  = r_addr_a_base;
                dma_len   = LEN_INPUT;
                
                if (dma_done)
                    next_state = S_COMPUTE;
            end
            
            S_COMPUTE: begin
                if (is_depthwise) begin
                    conv_start = !op_started;
                    
                    if (conv_done) begin
                        if (add_counter < max_add_loop)
                            next_state = S_COMPUTE;
                        else if (tiling_idx == max_tiles)
                            next_state = is_writeback ? S_STORE_OUTPUT : S_DONE;
                        else
                            next_state = S_COMPUTE;
                    end
                end else begin
                    gemm_start = !op_started;
                    
                    if (gemm_done) begin
                        if (add_counter < max_add_loop)
                            next_state = S_COMPUTE;
                        else if (tiling_idx == max_tiles)
                            next_state = is_writeback ? S_STORE_OUTPUT : S_DONE;
                        else
                            next_state = S_COMPUTE;
                    end
                end
            end
            
            S_STORE_OUTPUT: begin
                if (is_writeback) begin
                    dma_start = 1;
                    dma_addr  = r_addr_c_base;
                    dma_dir   = 1;
                    dma_len   = LEN_OUTPUT;
                    
                    if (dma_done)
                        next_state = S_DONE;
                end
            end
            
            S_DONE: begin
                status = STAT_DONE;
                if (!start)
                    next_state = S_IDLE;
            end

            default: begin
                status = STAT_ERROR;
                next_state = S_IDLE;
            end
        endcase
    end
    
    // Address generation - Write pointer
    always @(posedge clk) begin
        if (state == S_LOAD_WEIGHT) begin
            if (dma_start)
                ptr_wr <= WEIGHT_ADDR;
            else if (shim_valid_out)
                ptr_wr <= ptr_wr + 1;
        end else if (state == S_LOAD_INPUT) begin
            if (dma_start) begin
                if (stage_id == 1)
                    ptr_wr <= SCRATCH_ADDR;
                else
                    ptr_wr <= PING_ADDR;
            end else if (shim_valid_out) begin
                ptr_wr <= ptr_wr + 1;
            end
        end else if (state == S_COMPUTE) begin
            if (gemm_start || conv_start)
                ptr_wr <= base_addr_wr;
            else if (requant_valid)
                ptr_wr <= ptr_wr + 1;
        end
    end
    
    // Address generation - Read pointer
    always @(posedge clk) begin
        if (state == S_COMPUTE) begin
            if (gemm_start || conv_start)
                ptr_rd <= 0;
            else if (rd_en)
                ptr_rd <= ptr_rd + 1;
            else
                ptr_rd <= 0;
                
            if (!rst_n)
                compute_data_valid <= 0;
            else
                compute_data_valid <= rd_en;
        end
    end
    
    // Memory control signals
    always @(*) begin
        wr_en   = 0;
        wr_addr = ptr_wr;
        rd_addr = base_addr_rd;
        
        if (state == S_LOAD_WEIGHT || state == S_LOAD_INPUT)
            wr_en = shim_valid_out;
        else if (state == S_COMPUTE)
            wr_en = requant_valid;
    end
endmodule