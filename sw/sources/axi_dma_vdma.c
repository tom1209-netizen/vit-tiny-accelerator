#include "xparameters.h"
#include "xgpio.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "sleep.h"
#include "xaxivdma.h"

#include "axi_dma_vdma.h"
#include "images_raw.h"
#include "font8x8_basic.h"


XGpio GpioOut;
XGpio GpioIn;
XGpio GpioAxis; // for axis source gpio
XAxiVdma_DmaSetup ReadCfg;


void debug_gpio_status() {
    u32 addr = XGpio_DiscreteRead(&GpioOut, GPIO_ADDR_CHANNEL);
    u32 len_ctrl = XGpio_DiscreteRead(&GpioOut, GPIO_LEN_CHANNEL);
    u32 status = XGpio_DiscreteRead(&GpioIn, GPIO_STATUS_CHANNEL);
    
    xil_printf("Debug: Addr=0x%08X, LenCtrl=0x%08X, Status=0x%08X\r\n", 
               addr, len_ctrl, status);
}

// Activate dma_start_transfer
void dma_start_transfer(u32 addr, u32 length_bytes, u8 direction) {
    u32 control_value;
    
    // 1. Set address
    XGpio_DiscreteWrite(&GpioOut, GPIO_ADDR_CHANNEL, addr);
    
    // 2. Set length + direction
    control_value = (length_bytes << 2) | (direction << LENGTH_DIR_BIT);
    XGpio_DiscreteWrite(&GpioOut, GPIO_LEN_CHANNEL, control_value);
    
    // 3. Create start pulse (set bit start)
    control_value |= (1 << LENGTH_START_BIT);
    XGpio_DiscreteWrite(&GpioOut, GPIO_LEN_CHANNEL, control_value);
    
    
    // 4. Hold start for some cycles
    usleep(1000); 
    
    // 5. Clear start bit
    control_value &= ~(1 << LENGTH_START_BIT);
    XGpio_DiscreteWrite(&GpioOut, GPIO_LEN_CHANNEL, control_value);
}

void start_axis_source()
{
    XGpio_DiscreteWrite(&GpioAxis, GPIO_AXIS_LENGTH_CHANNEL, TEST_PKT_LEN_BYTES);
    XGpio_DiscreteWrite(&GpioAxis, GPIO_AXIS_START_CHANNEL, 1);
    usleep(1000); 
    XGpio_DiscreteWrite(&GpioAxis, GPIO_AXIS_START_CHANNEL, 0);

}

// Function to wait for dma_transfer_done
int dma_wait_for_completion(int timeout_ms) {
    int timeout = 0;
    while (timeout < timeout_ms) {
        if (XGpio_DiscreteRead(&GpioIn, GPIO_STATUS_CHANNEL) & 0x1) {
            return 1; // Done
        }
        usleep(1000); // 1ms
        timeout++;
    }
    return 0; // Timeout
}

/*********************************************************************
 * Test 1: MM2S (Memory → Stream)
 * Require: s_axis_tready = 1 
 ********************************************************************/
int test_mm2s()
{
    xil_printf("\r\n--- Test MM2S (Mem → Stream) ---\r\n");

    u8 *TxBuffer = (u8 *)TX_BUFFER_BASE;

    Xil_DCacheFlushRange((UINTPTR)TxBuffer, FRAME_SIZE); 

    xil_printf("Start MM2S: addr=0x%08X, len=%d bytes\r\n",
               (unsigned)TxBuffer, TEST_PKT_LEN_BYTES);

    dma_start_transfer((u32)TxBuffer, TEST_PKT_LEN_BYTES, 1); // 1 = MM2S

    if (!dma_wait_for_completion(5000)) {  // 5s
        xil_printf("MM2S timeout (check stream sink / tready)\r\n");
        return XST_FAILURE;
    }

    xil_printf("MM2S completed (dma_transfer_done=1)\r\n");
    return XST_SUCCESS;
}

/*********************************************************************
 * Test 2: S2MM (Stream → Memory)
 * Require: AXIS source send TEST_PKT_LEN_BYTES to S2MM
 ********************************************************************/
int test_s2mm()
{
    xil_printf("\r\n--- Test S2MM (Stream → Mem) ---\r\n");

    u8 *RxBuffer = (u8 *)RX_BUFFER_BASE;

    // Clear buffer before receiving
    for (int i = 0; i < TEST_PKT_LEN_BYTES; ++i) {
        RxBuffer[i] = 0x00;
    }
    Xil_DCacheFlushRange((UINTPTR)RxBuffer, TEST_PKT_LEN_BYTES);

    xil_printf("Start S2MM: addr=0x%08X, len=%d bytes\r\n",
               (unsigned)RxBuffer, TEST_PKT_LEN_BYTES);

    dma_start_transfer((u32)RxBuffer, TEST_PKT_LEN_BYTES, 0); // 0 = S2MM
    // usleep(1);
    start_axis_source();

    if (!dma_wait_for_completion(5000)) {  // 5s
        xil_printf("S2MM timeout (check AXIS source)\r\n");
        debug_gpio_status();
        return XST_FAILURE;
    }

    xil_printf("S2MM completed, reading back buffer...\r\n");

    // invalidate cache to read new data from DDR
    Xil_DCacheInvalidateRange((UINTPTR)RxBuffer, TEST_PKT_LEN_BYTES);

    // print test packet bytes
    for (int i = 0; i < TEST_PKT_LEN_BYTES; ++i) {
        xil_printf("0x%02X ", RxBuffer[i]);
        if ((i + 1) % 8 == 0) xil_printf("\r\n");
    }
    xil_printf("\r\n");

    return XST_SUCCESS;
}

int ReadSetup(XAxiVdma *InstancePtr)
{
    int Status;

    ReadCfg.VertSizeInput = V_RES_LINES;
    ReadCfg.HoriSizeInput = H_STRIDE;
    ReadCfg.Stride        = H_STRIDE;
    ReadCfg.FrameDelay = 0;
    
    ReadCfg.EnableCircularBuf = 0;  // 0 = Park Mode, 1 = Circular Mode
    
    ReadCfg.EnableSync = 1;
    ReadCfg.PointNum = 0;
    ReadCfg.EnableFrameCounter = 0;
    
    // Choose Frame to Park
    ReadCfg.FixedFrameStoreAddr = 0; // Park at Index 0

    Status = XAxiVdma_DmaConfig(InstancePtr, XAXIVDMA_READ, &ReadCfg);
    if (Status != XST_SUCCESS) return XST_FAILURE;

    // Assign the DDR address for the parking frame store
    ReadCfg.FrameStoreStartAddr[0] = DDR_BASE_HDMI;
    
    
    Status = XAxiVdma_DmaSetBufferAddr(InstancePtr, XAXIVDMA_READ, ReadCfg.FrameStoreStartAddr);
    if (Status != XST_SUCCESS) return XST_FAILURE;

    return XST_SUCCESS;
}

int StartTransfer(XAxiVdma *InstancePtr)
{
    int Status;
    Status = XAxiVdma_DmaStart(InstancePtr, XAXIVDMA_READ);

    Status = XAxiVdma_StartParking(InstancePtr, 0, XAXIVDMA_READ);

    return Status;
}

/*****************************************************************************/
/* Clear screen, Resize image and put into the address space, Flush Cache */
void Resize_Load_Image_To_DDR()
{
    u32 *frame_buffer = (u32 *)DDR_BASE_HDMI;
    
    // 1. Clear screen
    memset((void*)frame_buffer, 0, FRAME_SIZE);

    // 2. Coordinate to store image in the 720p
    int start_x = IMG_POS_X;
    int start_y = IMG_POS_Y;
    
    
    if (start_x < 0) start_x = 0;
    if (start_y < 0) start_y = 0;

    // 3. Resize each pixel into Frame Buffer
    
    // Read original image data (width and height are first 2 elements)
    int src_w = (int)img_raw_data[0];
    int src_h = (int)img_raw_data[1];
    const u32 *src_pixels = &img_raw_data[2]; // the pixel data of original image
    
    float x_ratio = (float)src_w / TARGET_WIDTH; 
    float y_ratio = (float)src_h / TARGET_HEIGHT; 

    xil_printf("Resizing & Drawing to DDR at IMG_POS_X and IMG_POS_Y\r\n");

    int y, x;
    for (y = 0; y < TARGET_HEIGHT; y++) {
        for (x = 0; x < TARGET_WIDTH; x++) {
            // Only take pixels from some coordinate of the original image
            int src_x = (int)(x * x_ratio);
            int src_y = (int)(y * y_ratio);
            if (src_x >= src_w) src_x = src_w - 1;
            if (src_y >= src_h) src_y = src_h - 1;
            
            u32 pixel_val = src_pixels[src_y * src_w + src_x];

            // Coordinate in the 720p screen (DDR)
            int dest_idx = (start_y + y) * H_RES_PIXELS + (start_x + x);
            
            frame_buffer[dest_idx] = pixel_val;
        }
    }

    // Flush Cache
    Xil_DCacheFlushRange(DDR_BASE_HDMI, FRAME_SIZE);
    xil_printf("Done. Image ready in DDR.\r\n");
}


void Update_Classification_From_Memory()
{
    // 1. Invalidate Cache the DDR_BASE_TEST_FROM_VIT (to ensure reading the newest data from RAM)
    char *text_ptr = (char *)DDR_BASE_TEXT_FROM_VIT;
    text_ptr = "Dog: 98%";
    Xil_DCacheInvalidateRange((UINTPTR)DDR_BASE_TEXT_FROM_VIT, 64);
    
    // 2. Read the string
    xil_printf("Read from Memory: %s\r\n", text_ptr); // Debug xem đọc được gì
    
    // 3. Draw the string to HDMI Buffer
    u32 *hdmi_buffer = (u32 *)DDR_BASE_HDMI;
    DrawString(hdmi_buffer, TEXT_POS_X, TEXT_POS_Y, text_ptr, TEXT_COLOR, 4);
    
    // 4. Flush HDMI Buffer
    Xil_DCacheFlushRange(DDR_BASE_HDMI, FRAME_SIZE);
}


void DrawChar(u32 *frame, int x, int y, char c, u32 color, int scale) {
    if (c < 0 || c > 127) return;
    const u8 *glyph = font8x8_basic[(int)c];
    for (int row = 0; row < 8; row++) {
        for (int col = 0; col < 8; col++) {
            if (glyph[row] & (1 << (7-col))) {
                for (int dy = 0; dy < scale; dy++) {
                    for (int dx = 0; dx < scale; dx++) {
                        int px = x + (col * scale) + dx;
                        int py = y + (row * scale) + dy;
                        if (px < H_RES_PIXELS && py < V_RES_LINES) frame[py * H_RES_PIXELS + px] = color;
                    }
                }
            }
        }
    }
}

void DrawString(u32 *frame, int x, int y, const char *str, u32 color, int scale) {
    while (*str) {
        DrawChar(frame, x, y, *str, color, scale);
        x += (8 * scale); 
        str++;
    }
}