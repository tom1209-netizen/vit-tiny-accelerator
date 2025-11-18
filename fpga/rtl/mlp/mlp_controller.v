module mlp_controller #(
    parameter CFG_WIDTH = 32
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // Configuration inputs
    input  wire [CFG_WIDTH-1:0]   layer_cfg,
    input  wire [CFG_WIDTH-1:0]   tile_cfg,

    // Enable outputs for submodules
    output reg                    enable_norm,
    output reg                    enable_gelu,
    output reg                    enable_weight_buf
);

    // Extract bit fields
    wire [3:0] layer_role       = layer_cfg[23:20];  // Layer role
    wire [2:0] tile_opclass     = tile_cfg[30:28];   // Operation phase

    // Control logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable_norm       <= 1'b0;
            enable_gelu       <= 1'b0;
            enable_weight_buf <= 1'b0;
        end else begin
            // Default: disable all
            enable_norm       <= 1'b0;
            enable_gelu       <= 1'b0;
            enable_weight_buf <= 1'b0;

            // Check if this layer is an MLP block (layer_cfg[23:20] == 4'b0011)
            if (layer_role == 4'b0011) begin
                case (tile_opclass)
                    3'b011: begin  // MLP FC1
                        enable_weight_buf <= 1'b1;  // load weights
                        enable_norm       <= 1'b1;  // run normalization
                        enable_gelu       <= 1'b0;  // disable GeLU at this phase
                    end
                    3'b100: begin  // MLP FC2
                        enable_weight_buf <= 1'b1;  // still load weights
                        enable_norm       <= 1'b0;  // disable Norm
                        enable_gelu       <= 1'b1;  // enable GeLU activation
                    end
                    default: begin
                        enable_weight_buf <= 1'b0;
                        enable_norm       <= 1'b0;
                        enable_gelu       <= 1'b0;
                    end
                endcase
            end
        end
    end

endmodule
