module tb;

reg clk;
reg rst_n;

reg [11:0] awaddr;
reg awvalid;
wire awready;

reg [31:0] wdata;
reg [3:0] wstrb;
reg wvalid;
wire wready;

wire [1:0] bresp;
wire bvalid;
reg bready;

reg [11:0] araddr;
reg arvalid;
wire arready;

wire [31:0] rdata;
wire [1:0] rresp;
wire rvalid;
reg rready;

wire wr_en;
wire rd_en;

wire [31:0] reg_rdata;

axi_lite dut (
    .clk(clk),
    .rst_n(rst_n),

    .awaddr(awaddr),
    .awvalid(awvalid),
    .awready(awready),

    .wdata(wdata), 
    .wstrb(wstrb),
    .wvalid(wvalid),
    .wready(wready),

    .bresp(bresp),
    .bvalid(bvalid),
    .bready(bready),

    .araddr(araddr),
    .arvalid(arvalid),
    .arready(arready),

    .rdata(rdata),
    .rresp(rresp),
    .rvalid(rvalid),
    .rready(rready),

    .reg_rdata(reg_rdata),
    .wr_en(wr_en),
    .rd_en(rd_en)
);

axi_lite_reg reg_dut (
    .clk(clk),
    .rst_n(rst_n),
    .wr_en(wr_en),
    .rd_en(rd_en),

    .awaddr(awaddr),
    .wdata(wdata),
    .wstrb(wstrb),
    
    .araddr(araddr),
    .rdata(reg_rdata),

    .start(),
    .soft_reset(),
    .irq_enabled(),

    .status(3'b000),

    .addr_a_base(),
    .addr_b_base(),
    .addr_c_base(),

    .requant_scale(),
    .requant_shift(),

    .tile_cfg(),
    .layer_cfg()
);

integer pass, fail;
integer strb_c, resp_c;
integer xav, xwv, xrv;

parameter addr_control = 12'h00;
parameter addr_status = 12'h04;
parameter addr_tile = 12'h10;
parameter addr_a = 12'h20;
parameter addr_b = 12'h24;
parameter addr_c = 12'h28;
parameter addr_scale = 12'h40;
parameter addr_shift = 12'h44;
parameter addr_layer = 12'h70;

task wr (input [11:0] addr, input [31:0] data);
    begin
        @(posedge clk);
        #1;
        awaddr = addr;
        awvalid = 1& !xav;
        wdata = data;
        wvalid = 1  & !xwv;
        bready = 1;
        #1 wr_p (addr, data);

        if (xav || xwv) begin
            @(posedge clk);
            #1;
            wr_sig_c (0);

            @(posedge clk);
            #1;
            awaddr = 0;
            awvalid = 0;
            wdata = 0;
            wvalid = 0;
            wr_sig_c(1);
            if (resp_c) wr_c (2'b11);
            else wr_c (2'b00);

            @(posedge clk);
            #1 bready = 0;

        end else begin
            wait (awready && wready);
            @(posedge clk);
            #1;
            awaddr = 0;
            awvalid = 0;
            wdata = 0;
            wvalid = 0;
            if (resp_c) wr_c (2'b11);
            else wr_c (2'b00);

            @(posedge clk);
            #1 bready = 0;
        end
    end
endtask

task rd (input [11:0] addr, input [31:0] data);
    begin
        @(posedge clk);
        #1;
        araddr = addr;
        arvalid = 1 & !xrv;
        rready = 1;
        #1;
        rd_p (addr);
        

        if (xrv) begin
            @(posedge clk);
            #1;
            rd_sig_c (0);

            @(posedge clk);
            #1;
            araddr = 0;
            arvalid = 0;
            rd_sig_c (1);

            @(posedge clk);
            #1 rready = 0;

        end else begin
            wait (arready);
            @(posedge clk);
            #1;
            araddr = 0;
            arvalid = 0;
            if (resp_c) rd_c (data, 2'b11);
            else rd_c (data, 2'b00);

            @(posedge clk);
            #1;
            rready = 0;
        end
    end
endtask

task divi;
    $display ("--------------------------------------------------------------------------");
endtask

task msg (input [600:0] txt);
    begin
        divi();
        $display ("%0s", txt);
        divi();
    end
endtask 

//write print
task wr_p (input [11:0] addr, input [31:0] data);
    if (strb_c) 
        $display ("WRITE -- Time = %0t | AWADDR = 12'h%3h, WDATA = 32'h%8h, WSTRB = 4'b%4b", $time, addr, data, wstrb);
    else
        $display ("WRITE -- Time = %0t | AWADDR = 12'h%3h, WDATA = 32'h%8h", $time, addr, data);
endtask

task wr_c (input [1:0] resp);
    begin
        $display ("[OUTPUT] Time = %0t | BRESP = 2'b%2b", $time, bresp);
        $display ("[EXPECT] Time = %0t | BRESP = 2'b%2b", $time, resp);
        
        if (bresp === resp) begin
            $display ("======> PASSED");
            pass = pass + 1;
        end else begin
            $display ("======> FAILED");
            fail = fail + 1;
        end
    end
endtask

task rd_p (input [11:0] addr);
    $display ("READ  -- Time = %0t | ARADDR = 12'h%3h", $time, addr);
endtask

task rd_c (input [31:0] data, input [1:0] resp);
    begin
        $display ("[OUTPUT] Time = %0t | RDATA = 32'h%8h, RRESP = 2'b%2b", $time, rdata, rresp);
        $display ("[EXPECT] Time = %0t | RDATA = 32'h%8h, RRESP = 2'b%2b", $time, data, resp);
        
        if ((rdata === data) && (rresp === resp)) begin
            $display ("======> PASSED");
            pass = pass + 1;
        end else begin
            $display ("======> FAILED");
            fail = fail + 1;
        end
    end
endtask

task wr_sig_c (input x);
    begin
        if (x == 0) begin
            $display ("[OUTPUT] Time = %0t | WR_EN = %b", $time, wr_en);
            $display ("[EXPECT] Time = %0t | WR_EN = %b", $time, 1'b0);
            if (wr_en === 1'b0) begin
                $display ("======> PASSED");
                pass = pass + 1;
            end else begin
                $display ("======> FAILED");
                fail = fail + 1;
            end
        end else begin
            $display ("[OUTPUT] Time = %0t | BVALID = %b, BRESP = 2'b%2b", $time, bvalid, bresp);
            $display ("[EXPECT] Time = %0t | BVALID = %b, BRESP = 2'b%2b", $time, 1'b0, 2'b00);
            if (bvalid === 1'b0 && bresp === 2'b00) begin
                $display ("======> PASSED");
                pass = pass + 1;
            end else begin
                $display ("======> FAILED");
                fail = fail + 1;
            end
        end
    end
endtask

task rd_sig_c (input x);
    begin
        if (x == 0) begin
            $display ("[OUTPUT] Time = %0t | RD_EN = %b", $time, rd_en);
            $display ("[EXPECT] Time = %0t | RD_EN = %b", $time, 1'b0);
            if (rd_en === 1'b0) begin
                $display ("======> PASSED");
                pass = pass + 1;
            end else begin
                $display ("======> FAILED");
                fail = fail + 1;
            end
        end else begin
            $display ("[OUTPUT] Time = %0t | RVALID = %b, RRESP = 2'b%2b", $time, rvalid, rresp);
            $display ("[EXPECT] Time = %0t | RVALID = %b, RRESP = 2'b%2b", $time, 1'b0, 2'b00);
            if (rvalid === 1'b0 && rresp === 2'b00) begin
                $display ("======> PASSED");
                pass = pass + 1;
            end else begin
                $display ("======> FAILED");
                fail = fail + 1;
            end
        end
    end
endtask

task rd_all (input [31:0] data0, input [31:0] data1, input [31:0] data2, input [31:0] data3, input [31:0] data4, input [31:0] data5, input [31:0] data6, input [31:0] data7, input [31:0] data8);
    begin
        rd (addr_control, data0);
        rd (addr_status, data1);
        rd (addr_tile, data2);
        rd (addr_a, data3);
        rd (addr_b, data4);
        rd (addr_c, data5);
        rd (addr_scale, data6);
        rd (addr_shift, data7);
        rd (addr_layer, data8);
    end
endtask

initial begin
    clk = 0;
    forever #10 clk = ~clk;
end

initial begin
    rst_n = 0;
    awaddr = 0;
    awvalid = 0;
    wdata = 0;
    wvalid = 0;
    bready = 0;
    wstrb = 4'hF;
    strb_c = 0;
    resp_c = 0;
    
    araddr = 0;
    arvalid = 0;
    rready = 0;

    xav = 0;
    xwv = 0;
    xrv = 0;

    pass = 0;
    fail = 0;
    #100;

    @(posedge clk);
    rst_n = 1;

    msg ("TEST 1: INITIAL VALUES CHECK");
    rd_all (32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0);

    msg ("TEST 2: ONE-HOT CHECK");
    wr (addr_control, 32'h1111_1111);
    wr (addr_status, 32'h2222_2222);
    wr (addr_tile, 32'h3333_3333);
    wr (addr_a, 32'h4444_4444);
    wr (addr_b, 32'h5555_5555);
    wr (addr_c, 32'h6666_6666);
    wr (addr_scale, 32'h7777_7777);
    wr (addr_shift, 32'h8888_8888);
    wr (addr_layer, 32'h9999_9999);
    rd_all (32'h1, 32'h0, 32'h3333_3333, 32'h4444_4444, 32'h5555_5555, 32'h6666_6666, 32'h7777_7777, 32'h0000_0008, 32'h1999_9999);

    msg ("TEST 3: READ/WRITE CHECK");
    msg ("\t1. CONTROL REGISTER");
    wr (addr_control, 32'h0);
    rd (addr_control, 32'h0);
    wr (addr_control, 32'hFFFF_FFFF);
    rd (addr_control, 32'h0000_0007);
    wr (addr_control, 32'haaaa_aaaa);
    rd (addr_control, 32'h0000_0002);
    wr (addr_control, 32'h5555_5555);
    rd (addr_control, 32'h0000_0005);
    wr (addr_control, 32'ha5a5_a5a5);
    rd (addr_control, 32'h0000_0005);
    wr (addr_control, 32'h5a5a_5a5a);
    rd (addr_control, 32'h0000_0002);

    msg ("\t2. STATUS REGISTER");
    wr (addr_status, 32'h0);
    rd (addr_status, 32'h0);
    wr (addr_status, 32'hFFFF_FFFF);
    rd (addr_status, 32'h0);
    wr (addr_status, 32'haaaa_aaaa);
    rd (addr_status, 32'h0);
    wr (addr_status, 32'h5555_5555);
    rd (addr_status, 32'h0);
    wr (addr_status, 32'ha5a5_a5a5);
    rd (addr_status, 32'h0);
    wr (addr_status, 32'h5a5a_5a5a);
    rd (addr_status, 32'h0);
    
    msg ("\t3. TILE CONFIGURATION REGISTER");
    wr (addr_tile, 32'h0);
    rd (addr_tile, 32'h0);
    wr (addr_tile, 32'hFFFF_FFFF);
    rd (addr_tile, 32'hFFFF_FFFF);
    wr (addr_tile, 32'haaaa_aaaa);
    rd (addr_tile, 32'haaaa_aaaa);
    wr (addr_tile, 32'h5555_5555);
    rd (addr_tile, 32'h5555_5555);
    wr (addr_tile, 32'ha5a5_a5a5);
    rd (addr_tile, 32'ha5a5_a5a5);
    wr (addr_tile, 32'h5a5a_5a5a);
    rd (addr_tile, 32'h5a5a_5a5a);

    msg ("\t4. BASE ADDRESS REGISTER A");
    wr (addr_a, 32'h0);
    rd (addr_a, 32'h0);
    wr (addr_a, 32'hFFFF_FFFF);
    rd (addr_a, 32'hFFFF_FFFF);
    wr (addr_a, 32'haaaa_aaaa);
    rd (addr_a, 32'haaaa_aaaa);
    wr (addr_a, 32'h5555_5555);
    rd (addr_a, 32'h5555_5555);
    wr (addr_a, 32'ha5a5_a5a5);
    rd (addr_a, 32'ha5a5_a5a5);
    wr (addr_a, 32'h5a5a_5a5a);
    rd (addr_a, 32'h5a5a_5a5a);

    msg ("\t5. BASE ADDRESS REGISTER B");
    wr (addr_b, 32'h0);
    rd (addr_b, 32'h0);
    wr (addr_b, 32'hFFFF_FFFF);
    rd (addr_b, 32'hFFFF_FFFF);
    wr (addr_b, 32'haaaa_aaaa);
    rd (addr_b, 32'haaaa_aaaa);
    wr (addr_b, 32'h5555_5555);
    rd (addr_b, 32'h5555_5555);
    wr (addr_b, 32'ha5a5_a5a5);
    rd (addr_b, 32'ha5a5_a5a5);
    wr (addr_b, 32'h5a5a_5a5a);
    rd (addr_b, 32'h5a5a_5a5a);

    msg ("\t6. BASE ADDRESS REGISTER C");
    wr (addr_c, 32'h0);
    rd (addr_c, 32'h0);
    wr (addr_c, 32'hFFFF_FFFF);
    rd (addr_c, 32'hFFFF_FFFF);
    wr (addr_c, 32'haaaa_aaaa);
    rd (addr_c, 32'haaaa_aaaa);
    wr (addr_c, 32'h5555_5555);
    rd (addr_c, 32'h5555_5555);
    wr (addr_c, 32'ha5a5_a5a5);
    rd (addr_c, 32'ha5a5_a5a5);
    wr (addr_c, 32'h5a5a_5a5a);
    rd (addr_c, 32'h5a5a_5a5a);

    msg ("\t7. REQUANT SCALE REGISTER");
    wr (addr_scale, 32'h0);
    rd (addr_scale, 32'h0);
    wr (addr_scale, 32'hFFFF_FFFF);
    rd (addr_scale, 32'hFFFF_FFFF);
    wr (addr_scale, 32'haaaa_aaaa);
    rd (addr_scale, 32'haaaa_aaaa);
    wr (addr_scale, 32'h5555_5555);
    rd (addr_scale, 32'h5555_5555);
    wr (addr_scale, 32'ha5a5_a5a5);
    rd (addr_scale, 32'ha5a5_a5a5);
    wr (addr_scale, 32'h5a5a_5a5a);
    rd (addr_scale, 32'h5a5a_5a5a);

    msg ("\t8. REQUANT SHIFT REGISTER");
    wr (addr_shift, 32'h0);
    rd (addr_shift, 32'h0);
    wr (addr_shift, 32'hFFFF_FFFF);
    rd (addr_shift, 32'h0000_007F);
    wr (addr_shift, 32'haaaa_aaaa);
    rd (addr_shift, 32'h0000_002a);
    wr (addr_shift, 32'h5555_5555);
    rd (addr_shift, 32'h0000_0055);
    wr (addr_shift, 32'ha5a5_a5a5);
    rd (addr_shift, 32'h0000_0025);
    wr (addr_shift, 32'h5a5a_5a5a);
    rd (addr_shift, 32'h0000_005a);

    msg ("\t9. LAYER CONFIGURATION REGISTER");
    wr (addr_layer, 32'h0);
    rd (addr_layer, 32'h0);
    wr (addr_layer, 32'hFFFF_FFFF);
    rd (addr_layer, 32'h3FFF_FFFF);
    wr (addr_layer, 32'haaaa_aaaa);
    rd (addr_layer, 32'h2aaa_aaaa);
    wr (addr_layer, 32'h5555_5555);
    rd (addr_layer, 32'h1555_5555);
    wr (addr_layer, 32'ha5a5_a5a5);
    rd (addr_layer, 32'h25a5_a5a5);
    wr (addr_layer, 32'h5a5a_5a5a);
    rd (addr_layer, 32'h1a5a_5a5a);

    msg ("TEST 4: RESET CHECK");
    $display ("Reseting...");
    @(posedge clk);
    #1 rst_n = 0;
    $display ("Releasing reset...");
    @(posedge clk);
    #1 rst_n = 1;
    rd_all (32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0, 32'h0);

    msg ("TEST 5: WSTRB CHECK");
    strb_c = 1;
    msg ("\t1. WRITE WITH WSTRB = 4'b0001");
    wstrb = 4'b0001;
    wr (addr_control, 32'hffff_ffff);
    wr (addr_status, 32'h2222_2222);
    wr (addr_tile, 32'h3333_3333);
    wr (addr_a, 32'h4444_4444);
    wr (addr_b, 32'h5555_5555);
    wr (addr_c, 32'h6666_6666);
    wr (addr_scale, 32'h7777_7777);
    wr (addr_shift, 32'h8888_8888);
    wr (addr_layer, 32'h9999_9999);
    rd_all (32'h7, 32'h0, 32'h0000_0033, 32'h0000_0044, 32'h0000_0055, 32'h0000_0066, 32'h0000_0077, 32'h8, 32'h0000_0099);
    
    msg ("\t2. WRITE WITH WSTRB = 4'b0010");
    wstrb = 4'b0010;
    wr (addr_control, 32'hffff_ffff);
    wr (addr_status, 32'h2222_2200);
    wr (addr_tile, 32'h3333_3300);
    wr (addr_a, 32'h4444_4400);
    wr (addr_b, 32'h5555_5500);
    wr (addr_c, 32'h6666_6600);
    wr (addr_scale, 32'h7777_7700);
    wr (addr_shift, 32'h8888_8800);
    wr (addr_layer, 32'h9999_9900);
    rd_all (32'h7, 32'h0, 32'h0000_3333, 32'h0000_4444, 32'h0000_5555, 32'h0000_6666, 32'h0000_7777, 32'h8, 32'h0000_9999);

    msg ("\t3. WRITE WITH WSTRB = 4'b0100");
    wstrb = 4'b0100;
    wr (addr_control, 32'hffff_ffff);
    wr (addr_status, 32'h2222_0000);
    wr (addr_tile, 32'h3333_0000);
    wr (addr_a, 32'h4444_0000);
    wr (addr_b, 32'h5555_0000);
    wr (addr_c, 32'h6666_0000);
    wr (addr_scale, 32'h7777_0000);
    wr (addr_shift, 32'h8888_0000);
    wr (addr_layer, 32'h9999_0000);
    rd_all (32'h7, 32'h0, 32'h0033_3333, 32'h0044_4444, 32'h0055_5555, 32'h0066_6666, 32'h0077_7777, 32'h8, 32'h0099_9999);

    msg ("\t4. WRITE WITH WSTRB = 4'b1000");
    wstrb = 4'b1000;
    wr (addr_control, 32'hffff_ffff);
    wr (addr_status, 32'h2200_2222);
    wr (addr_tile, 32'h3300_3333);
    wr (addr_a, 32'h4400_4444);
    wr (addr_b, 32'h5500_5555);
    wr (addr_c, 32'h6600_6666);
    wr (addr_scale, 32'h7700_7777);
    wr (addr_shift, 32'h8800_8888);
    wr (addr_layer, 32'h9900_9999);
    rd_all (32'h7, 32'h0, 32'h3333_3333, 32'h4444_4444, 32'h5555_5555, 32'h6666_6666, 32'h7777_7777, 32'h8, 32'h1999_9999);

    msg ("\t5. WRITE WITH WSTRB = 4'b0011");
    wstrb = 4'b0011;
    wr (addr_control, 32'hcccc_cccc);
    wr (addr_status, 32'h8888_8888);
    wr (addr_tile, 32'h7777_7777);
    wr (addr_a, 32'h6666_6666);
    wr (addr_b, 32'h4444_4444);
    wr (addr_c, 32'h3333_3333);
    wr (addr_scale, 32'h2222_2222);
    wr (addr_shift, 32'h1111_1111);
    wr (addr_layer, 32'hffff_ffff);
    rd_all (32'h4, 32'h0, 32'h3333_7777, 32'h4444_6666, 32'h5555_4444, 32'h6666_3333, 32'h7777_2222, 32'h0000_0011, 32'h1999_ffff);

    msg ("\t6. WRITE WITH WSTRB = 4'b1100");
    wstrb = 4'b1100;
    wr (addr_control, 32'hcccc_cc00);
    wr (addr_status, 32'h8888_0001);
    wr (addr_tile, 32'h7777_0000);
    wr (addr_a, 32'h6666_0000);
    wr (addr_b, 32'h4444_0000);
    wr (addr_c, 32'h3333_0000);
    wr (addr_scale, 32'h2222_0000);
    wr (addr_shift, 32'h1111_0000);
    wr (addr_layer, 32'hffff_0000);
    rd_all (32'h4, 32'h0, 32'h7777_7777, 32'h6666_6666, 32'h4444_4444, 32'h3333_3333, 32'h2222_2222, 32'h0000_0011, 32'h3fff_ffff);

    msg ("\t7. WRITE WITH WSTRB = 4'b0101");
    wstrb = 4'b0101;
    wr (addr_control, 32'haaaa_aaaa);
    wr (addr_status, 32'hbbbb_bbbb);
    wr (addr_tile, 32'hcccc_cccc);
    wr (addr_a, 32'hdddd_dddd);
    wr (addr_b, 32'heeee_eeee);
    wr (addr_c, 32'hffff_ffff);
    wr (addr_scale, 32'h9999_9999);
    wr (addr_shift, 32'h8888_8888);
    wr (addr_layer, 32'h7777_7777);
    rd_all (32'h2, 32'h0, 32'h77cc_77cc, 32'h66dd_66dd, 32'h44ee_44ee, 32'h33ff_33ff, 32'h2299_2299, 32'h0000_0008, 32'h3f77_ff77);

    msg ("\t8. WRITE WITH WSTRB = 4'b1010");
    wstrb = 4'b1010;
    wr (addr_control, 32'haa00_aa01);
    wr (addr_status, 32'hbb00_bb00);
    wr (addr_tile, 32'hcc00_cc00);
    wr (addr_a, 32'hdd00_dd00);
    wr (addr_b, 32'hee00_ee00);
    wr (addr_c, 32'hff00_ff00);
    wr (addr_scale, 32'h9900_9900);
    wr (addr_shift, 32'h8800_8800);
    wr (addr_layer, 32'h7700_7700);
    rd_all (32'h2, 32'h0, 32'hcccc_cccc, 32'hdddd_dddd, 32'heeee_eeee, 32'hffff_ffff, 32'h9999_9999, 32'h0000_0008, 32'h3777_7777);

    msg ("TEST 6: RESERVED ADDRESSES CHECK");
    strb_c = 0;
    wstrb = 4'hF;
    resp_c = 1;
    wr (12'h08, 32'hffff_ffff);
    rd (12'h08, 32'h0);
    wr (12'h14, 32'hffff_ffff);
    rd (12'h14, 32'h0);
    wr (12'h1C, 32'hffff_ffff);
    rd (12'h1C, 32'h0);
    wr (12'h2C, 32'hffff_ffff);
    rd (12'h2C, 32'h0);
    wr (12'h30, 32'hffff_ffff);
    rd (12'h30, 32'h0);
    wr (12'h34, 32'hffff_ffff);
    rd (12'h34, 32'h0);
    wr (12'h38, 32'hffff_ffff);
    rd (12'h38, 32'h0);
    wr (12'h3C, 32'hffff_ffff);
    rd (12'h3C, 32'h0);
    wr (12'h48, 32'hffff_ffff);
    rd (12'h48, 32'h0);
    wr (12'h4C, 32'hffff_ffff);
    rd (12'h4C, 32'h0);
    wr (12'h50, 32'hffff_ffff);
    rd (12'h50, 32'h0);
    wr (12'h54, 32'hffff_ffff);
    rd (12'h54, 32'h0);
    wr (12'h58, 32'hffff_ffff);
    rd (12'h58, 32'h0);
    wr (12'h5C, 32'hffff_ffff);
    rd (12'h5C, 32'h0);
    wr (12'h60, 32'hffff_ffff);
    rd (12'h60, 32'h0);
    wr (12'h64, 32'hffff_ffff);
    rd (12'h64, 32'h0);
    wr (12'h68, 32'hffff_ffff);
    rd (12'h68, 32'h0);
    wr (12'h6C, 32'hffff_ffff);
    rd (12'h6C, 32'h0);
    wr (12'h74, 32'hffff_ffff);
    rd (12'h74, 32'h0);
    wr (12'h78, 32'hffff_ffff);
    rd (12'h78, 32'h0);
    wr (12'h99, 32'hffff_ffff);
    rd (12'h99, 32'h0);
    wr (12'hFFF, 32'hffff_ffff);
    rd (12'hFFF, 32'h0);
    wr (12'hABC, 32'hffff_ffff);
    rd (12'hABC, 32'h0);
    wr (12'hDEF, 32'hffff_ffff);
    rd (12'hDEF, 32'h0);

    msg ("TEST 7: NO AWVALID/WVALID CHECK");
    resp_c = 0;
    $display ("Reseting...");
    @(posedge clk);
    #1 rst_n = 0;
    $display ("Releasing reset...");
    @(posedge clk);
    #1 rst_n = 1;

    msg ("\t1. NO AWVALID");
    xav = 1;
    wr (addr_a, 32'h1234_5678);
    wr (addr_b, 32'h9ABC_DEF0);
    wr (addr_c, 32'hFEDC_BA98);
    rd (addr_a, 32'h0);
    rd (addr_b, 32'h0);
    rd (addr_c, 32'h0);
    xav = 0;

    msg ("\t2. NO WVALID");
    xwv = 1;
    wr (addr_a, 32'h1234_5678);
    wr (addr_b, 32'h9ABC_DEF0);
    wr (addr_c, 32'hFEDC_BA98);
    rd (addr_a, 32'h0);
    rd (addr_b, 32'h0);
    rd (addr_c, 32'h0);

    msg ("\t3. NO WVALID & AWVALID");
    xav = 1;
    wr (addr_a, 32'h1234_5678);
    wr (addr_b, 32'h9ABC_DEF0);
    wr (addr_c, 32'hFEDC_BA98);
    rd (addr_a, 32'h0);
    rd (addr_b, 32'h0);
    rd (addr_c, 32'h0);
    xav = 0;
    xwv = 0;

    msg ("TEST 8: NO ARVALID");
    $display ("Reseting...");
    @(posedge clk);
    #1 rst_n = 0;
    $display ("Releasing reset...");
    @(posedge clk);
    #1 rst_n = 1;

    xrv = 1;
    wr (addr_a, 32'h1234_5678);
    wr (addr_b, 32'h9ABC_DEF0);
    wr (addr_c, 32'hFEDC_BA98);
    rd (addr_a, 32'h0);
    rd (addr_b, 32'h0);
    rd (addr_c, 32'h0);
    xrv = 0;
    rd (addr_a, 32'h1234_5678);
    rd (addr_b, 32'h9ABC_DEF0);
    rd (addr_c, 32'hFEDC_BA98);

    msg ("SUMMARY");
    $display ("TOTAL TESTS : %0d", pass + fail);
    $display ("TOTAL PASSED: %0d", pass);
    $display ("TOTAL FAILED: %0d", fail);
    
    if (fail == 0)
        $display ("======> ALL TESTS PASSED");
    else if (pass == 0)
        $display ("======> ALL TESTS FAILED");
    else
        $display ("======> SOME TESTS FAILED");
    
    #100;
    $finish;
end
endmodule