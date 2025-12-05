module axi_lite_reg (
    input wire clk,
    input wire rst_n,
    input wire wr_en,
    input wire rd_en,

    input wire [11:0] awaddr,
    input wire [31:0] wdata,
    input wire [3:0] wstrb,
    
    input wire [11:0] araddr,
    output reg [31:0] rdata,

    output reg start,
    output reg soft_reset,
    output reg irq_enabled,

    input wire [2:0] status,

    output reg [31:0] addr_a_base,
    output reg [31:0] addr_b_base,
    output reg [31:0] addr_c_base,

    output reg [31:0] requant_scale,
    output wire [31:0] requant_shift,

    output reg [31:0] tile_cfg,
    output wire [31:0] layer_cfg
);

parameter addr_control = 12'h00;
parameter addr_status = 12'h04;
parameter addr_tile = 12'h10;
parameter addr_a = 12'h20;
parameter addr_b = 12'h24;
parameter addr_c = 12'h28;
parameter addr_scale = 12'h40;
parameter addr_shift = 12'h44;
parameter addr_layer = 12'h70;

//WSTRB
wire [31:0] mask, wdata_mask;
assign mask = { {8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}} };
assign wdata_mask = wdata & mask;

//CONTROL
wire control_sel;
wire start_next, soft_rst_next, irq_en_next;

assign control_sel = (awaddr == addr_control) & wr_en & wstrb[0];
assign start_next = control_sel ? wdata[0] : start;
assign soft_rst_next = control_sel ? wdata[1] : soft_reset;
assign irq_en_next = control_sel ? wdata[2] : irq_enabled;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        start <= 1'b0;
        soft_reset <= 1'b0;
        irq_enabled <= 1'b0;
    end else begin
        start <= start_next;
        soft_reset <= soft_rst_next;
        irq_enabled <= irq_en_next;
    end
end

//STATUS
/* wire status_sel, err_next, done_next;
assign status_sel = (awaddr == addr_status) & wr_en & wstrb[0];
assign done_next = (status_sel & status[0] & wdata[0]) ? 1'b0 : status[0];
assign err_next = (status_sel & status[2] & wdata[2]) ? 1'b0 : status[2]; */

//?????? consider put this in scheduler_tiler
/*always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        status[0] <= 1'b0;
        status[2] <= 1'b0;
    end else begin
        status[0] <= done_next;
        status[2] <= err_next;
    end
end
*/

//TILE_CFG
wire tile_sel;
wire [31:0] tile_next;
assign tile_sel = (awaddr == addr_tile) & wr_en;
assign tile_next = tile_sel ? ((tile_cfg & ~mask) | wdata_mask) : tile_cfg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tile_cfg <= 32'b0;
    end else begin
        tile_cfg <= tile_next;
    end
end

//ADDR_A_BASE, ADDR_B_BASE, ADDR_C_BASE
wire a_sel, b_sel, c_sel;
wire [31:0] a_next, b_next, c_next;

assign a_sel = (awaddr == addr_a) & wr_en;
assign b_sel = (awaddr == addr_b) & wr_en;
assign c_sel = (awaddr == addr_c) & wr_en;

assign a_next = a_sel ? ((addr_a_base & ~mask) | wdata_mask) : addr_a_base;
assign b_next = b_sel ? ((addr_b_base & ~mask) | wdata_mask) : addr_b_base;
assign c_next = c_sel ? ((addr_c_base & ~mask) | wdata_mask) : addr_c_base;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        addr_a_base <= 32'b0;
        addr_b_base <= 32'b0;
        addr_c_base <= 32'b0;
    end else begin
        addr_a_base <= a_next;
        addr_b_base <= b_next;
        addr_c_base <= c_next;
    end
end

//REQUANT_SCALE
wire scale_sel;
wire [31:0] scale_next;
assign scale_sel = (awaddr == addr_scale) & wr_en;
assign scale_next = scale_sel ? ((requant_scale & ~mask) | wdata_mask) : requant_scale;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        requant_scale <= 32'b0;
    end else begin
        requant_scale <= scale_next;
    end
end

//REQUANT_SHIFT
wire shift_sel;
wire [31:0] shift_next;
reg [31:0] requant_shift_temp;
assign shift_sel = (awaddr == addr_shift) & wr_en;
assign shift_next = shift_sel ? ((requant_shift_temp & ~mask) | wdata_mask) : requant_shift_temp;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        requant_shift_temp <= 32'b0;
    end else begin
        requant_shift_temp <= shift_next;
    end
end
assign requant_shift = {25'b0, requant_shift_temp[6:0]};

//LAYER_CFG
wire layer_sel;
wire [31:0] layer_next;
reg [31:0] layer_cfg_temp;
assign layer_sel = (awaddr == addr_layer) & wr_en;
assign layer_next = layer_sel ? ((layer_cfg_temp & ~mask) | wdata_mask) : layer_cfg_temp;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) 
        layer_cfg_temp <= 32'b0;
    else 
        layer_cfg_temp <= layer_next;
end
assign layer_cfg = {2'b0, layer_cfg_temp[29:0]};

//READ DATA
always @(*) begin
    case (araddr)
        addr_control: rdata = {29'b0, irq_enabled, soft_reset, start};
        addr_status:  rdata = {29'b0, status[2], status[1], status[0]};
        addr_tile:    rdata = tile_cfg;
        addr_a:       rdata = addr_a_base;
        addr_b:       rdata = addr_b_base;
        addr_c:       rdata = addr_c_base;
        addr_scale:   rdata = requant_scale;
        addr_shift:   rdata = requant_shift;
        addr_layer:   rdata = layer_cfg;
        default:      rdata = 32'b0;
    endcase
end
endmodule