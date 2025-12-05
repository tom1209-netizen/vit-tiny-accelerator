`timescale 1ns / 1ps

module relu_unit #(
    parameter DATA_WIDTH = 64, // Độ rộng bus dữ liệu
    parameter DATA_TYPE  = 8   // Độ rộng của mỗi phần tử (int8)
)(
    // Slave Interface (Nhận dữ liệu từ Requant)
    input  wire [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                  s_axis_tvalid,
    input  wire                  s_axis_tlast,
    output wire                  s_axis_tready,

    // Master Interface (Gửi dữ liệu đã xử lý đi tiếp)
    output wire [DATA_WIDTH-1:0] m_axis_tdata,
    output wire                  m_axis_tvalid,
    output wire                  m_axis_tlast,
    input  wire                  m_axis_tready
);

    // Tính số lượng phần tử trong một gói (64 / 8 = 8 phần tử)
    localparam NUM_ELEMENTS = DATA_WIDTH / DATA_TYPE;    
    //-------------------------------------------------------------------------
    // PROCESS
    //-------------------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < NUM_ELEMENTS; i = i + 1) begin : relu_calc_loop
            assign m_axis_tdata[(i*DATA_TYPE) +: DATA_TYPE] = (s_axis_tdata[(i+1)*DATA_TYPE-1] == 1'b1) ? {DATA_TYPE{1'b0}} : s_axis_tdata[(i*DATA_TYPE) +: DATA_TYPE];
        end
    endgenerate
    
    // Valid output chỉ bật khi có Valid input
    assign m_axis_tvalid = s_axis_tvalid;

    // Tlast output giữ nguyên theo input (đánh dấu gói cuối cùng)
    assign m_axis_tlast  = s_axis_tlast;

    // Ready input được nối thông với Ready của module phía sau (Back-pressure)
    // Nghĩa là: Nếu module sau sẵn sàng nhận (m_ready=1), thì module này cũng sẵn sàng nhận (s_ready=1).
    assign s_axis_tready = m_axis_tready;

endmodule