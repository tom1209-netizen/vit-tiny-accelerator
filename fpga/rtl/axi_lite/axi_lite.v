module axi_lite (
    input wire clk,
    input wire rst_n,

    input wire [11:0] awaddr,
    input wire awvalid,
    output wire awready,

    input wire [31:0] wdata, 
    input wire [3:0] wstrb,
    input wire wvalid,
    output wire wready,

    output reg [1:0] bresp,
    output reg bvalid,
    input wire bready,

    input wire [11:0] araddr,
    input wire arvalid,
    output wire arready,

    output reg [31:0] rdata,
    output reg [1:0] rresp,
    output reg rvalid,
    input wire rready,

    output wire wr_en,
    output wire rd_en,

    input wire [31:0] reg_rdata
);

//AWREADY
reg aw_handshake_done, w_handshake_done;
assign awready = !aw_handshake_done && !bvalid;
assign wready  = !w_handshake_done && !bvalid;


always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        aw_handshake_done <= 1'b0;
    end else begin
        if (awvalid && awready) begin
            aw_handshake_done <= 1'b1;
        end else if (bready && bvalid)
            aw_handshake_done <= 1'b0;
    end
end

//WREADY
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        w_handshake_done <= 1'b0;
    end else begin
        if (wvalid && wready) begin
            w_handshake_done <= 1'b1;
        end else if (bready && bvalid)
            w_handshake_done <= 1'b0;
    end
end

//BVALID
wire bvalid_next;
assign bvalid_next = wr_en ? 1'b1 : (bready & bvalid) ? 1'b0 : bvalid;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        bvalid <= 1'b0;
    else
        bvalid <= bvalid_next;
end

//BRESP
wire valid_waddr;
assign valid_waddr = (awaddr == 12'h0 || awaddr == 12'h4 || awaddr == 12'h10 || awaddr == 12'h20 || awaddr == 12'h24 || awaddr == 12'h28 || awaddr == 12'h40 || awaddr == 12'h44 || awaddr == 12'h70);

wire [1:0] bresp_next;
assign bresp_next = wr_en ? (valid_waddr ? 2'b00 : 2'b11) : bresp;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        bresp <= 2'b00  ;
    else
        bresp <= bresp_next;
end

//WR_EN
assign wr_en = (awvalid & awready) & (wvalid & wready);

////////////////////////////////////////////////////////////////////

//ARREADY
reg ar_handshake_done;
assign arready = !ar_handshake_done && !rvalid;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ar_handshake_done <= 1'b0;
    end else begin
        if (arvalid && arready) begin
            ar_handshake_done <= 1'b1;
        end else if (rready && rvalid)
            ar_handshake_done <= 1'b0;
    end
end

//RVALID
wire rvalid_next;
assign rvalid_next = rd_en ? 1'b1 : (rready & rvalid) ? 1'b0 : rvalid;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) 
        rvalid <= 1'b0;
    else
        rvalid <= rvalid_next;
end

//RDATA
wire [31:0] rdata_next;
assign rdata_next = rd_en ? reg_rdata : rdata;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        rdata <= 32'h0;
    else
        rdata <= rdata_next;
end

//RRESP
wire valid_raddr;
assign valid_raddr = (araddr == 12'h0 || araddr == 12'h4 || araddr == 12'h10 || araddr == 12'h20 || araddr == 12'h24 || araddr == 12'h28 || araddr == 12'h40 || araddr == 12'h44 || araddr == 12'h70);

wire [1:0] rresp_next;
assign rresp_next = rd_en ? (valid_raddr ? 2'b00 : 2'b11) : rresp;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        rresp <= 2'b00;
    else
        rresp <= rresp_next;
end

//RD_EN
assign rd_en = arvalid & arready;
endmodule