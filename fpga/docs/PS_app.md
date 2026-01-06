# ZYNQ7 PS Application Documentation: ViT Accelerator Control

## 1. System Overview

This application runs on the ARM Cortex-A9 (PS) of the Zynq-7000 SoC. It manages the data flow for a Vision Transformer (ViT) hardware accelerator and handles the visual output via HDMI. The system operates using two distinct data paths:

1. **The DMA Path (Control & Compute):**
    
    - **Purpose:** Moves data between DDR memory and the PL (Programmable Logic) accelerators.
        
    - **Mechanism:** The PS uses **AXI GPIO** peripherals to send command signals (Address, Length, Direction, Start) to a custom hardware module called `axi_dma_shim`. This shim translates these GPIO signals into AXI4-Lite commands to control the standard **AXI DMA** core.
        
2. **The VDMA Path (Display):**
    
    - **Purpose:** Continuously reads a frame buffer from DDR memory to drive an HDMI display.
        
    - **Mechanism:** The PS configures the **AXI VDMA** core to read from a specific memory region (`DDR_BASE_HDMI`) where the application draws the resized input image and classification results.
        

---

## 2. Memory Map & Configuration (`axi_dma_vdma.h`)

This header defines the hardware addresses, memory layout, and system constants.

### Hardware Addresses

- **`GPIO_OUT_BASEADDR` / `GPIO_IN_BASEADDR`**: Base addresses for the AXI GPIO instances used to communicate with the `axi_dma_shim`.
    
- **`DDR_BASE_HDMI`**: The start address of the 720p frame buffer. Data written here appears on the screen.
    
- **`DDR_BASE_IMG_INPUT`**: The specific offset within the HDMI frame buffer where the 224x224 ViT input image is drawn.
    
- **`TX_BUFFER_BASE` / `RX_BUFFER_BASE`**: Dedicated DDR spaces for DMA transfer testing.
    

### Display Constants

- **Resolution:** 1280x720 (720p).
    
- **`H_STRIDE`**: The number of bytes in one horizontal line ($1280 \times 4$ bytes).
    
- **`TARGET_WIDTH` / `HEIGHT`**: 224x224 (The standard input size for Vision Transformers).
    

---

## 3. Function Descriptions (`axi_dma_vdma.c`)

### A. GPIO & DMA Control Functions

These functions manage the `axi_dma_shim` to initiate data transfers.

**1. `debug_gpio_status()`**

- **Purpose:** Reads the current state of the GPIO registers for debugging.
    
- **Operation:** Reads the address, control signals (length/direction), and status bits from the GPIO peripherals and prints them to the UART console.
    

**2. `dma_start_transfer(u32 addr, u32 length_bytes, u8 direction)`**

- **Purpose:** Initiates a DMA transaction by signaling the PL shim.
    
- **Parameters:**
    
    - `addr`: Source/Destination address in DDR.
        
    - `length_bytes`: Size of the transfer.
        
    - `direction`: `1` for MM2S (Memory to Stream), `0` for S2MM (Stream to Memory).
        
- **Operation:**
    
    1. Writes the `addr` to `GPIO_ADDR_CHANNEL`.
        
    2. Packs `length` and `direction` into a single 32-bit word.
        
    3. Sets the **Start Bit** (bit 0) high to generate a rising edge pulse.
        
    4. Waits 1000us (using `usleep`) to ensure the hardware catches the signal.
        
    5. Clears the Start Bit to complete the handshake.
        

**3. `dma_wait_for_completion(int timeout_ms)`**

- **Purpose:** Polling loop that waits for the hardware to signal that a transfer is finished.
    
- **Operation:** Monitors the `GPIO_STATUS_CHANNEL` (Input GPIO). If bit 0 goes high, it returns success (`1`). If the `timeout_ms` expires, it returns failure (`0`).
    

**4. `test_mm2s()`**

- **Purpose:** Verifies the Memory-to-Stream path.
    
- **Operation:**
    
    - Flushes the Data Cache (`Xil_DCacheFlushRange`) to ensure data in `TX_BUFFER_BASE` is written to physical RAM.
        
    - Calls `dma_start_transfer` with direction `1`.
        
    - Waits for completion. This confirms the DMA can read from DDR and send data to the PL stream.
        

**5. `test_s2mm()`**

- **Purpose:** Verifies the Stream-to-Memory path.
    
- **Operation:**
    
    - Clears the receive buffer (`RX_BUFFER_BASE`) to 0x00.
        
    - Calls `dma_start_transfer` with direction `0`.
        
    - Waits for completion.
        
    - Invalidates the Data Cache (`Xil_DCacheInvalidateRange`) to force the CPU to fetch new data from physical RAM (not the stale cache).
        
    - Prints the received data to verify integrity.
        

---

### B. VDMA Configuration Functions

These functions configure the video pipeline to display the frame buffer.

**1. `ReadSetup(XAxiVdma *InstancePtr)`**

- **Purpose:** Configures the VDMA hardware parameters for reading video data.
    
- **Operation:**
    
    - Sets vertical size (`720`) and horizontal stride (`1280 * 4 bytes`).
        
    - Disables "Circular Buffer" mode, enabling **Park Mode**. This forces the VDMA to repeatedly read the same single frame buffer, which is simpler for static UI/image display.
        
    - Sets the buffer address to `DDR_BASE_HDMI`.
        

**2. `StartTransfer(XAxiVdma *InstancePtr)`**

- **Purpose:** Activates the VDMA core.
    
- **Operation:** Calls Xilinx driver functions `XAxiVdma_DmaStart` to enable the hardware and `XAxiVdma_StartParking` to lock it to the first frame buffer index (0).
    

---

### C. Image Processing & Graphics (OSD)

These functions handle creating the visual output in the DDR buffer.

**1. `Resize_Load_Image_To_DDR()`**

- **Purpose:** Prepares the HDMI display buffer by clearing it and drawing a resized version of the source image.
    
- **Operation:**
    
    - **Clear:** Uses `memset` to zero out the entire 720p frame (black screen).
        
    - **Scaling:** Calculates ratio factors (`x_ratio`, `y_ratio`) to map the source image (from `img_raw_data`) to the 224x224 target size.
        
    - **Nearest Neighbor Interpolation:** Loops through the 224x224 target grid, picks the corresponding pixel from the source, and writes it to the `DDR_BASE_HDMI` buffer at the specific `IMG_POS_X/Y` offsets.
        
    - **Cache Flush:** Calls `Xil_DCacheFlushRange` to ensure the drawn image exists in physical RAM for the VDMA to read.
        

**2. `Update_Classification_From_Memory()`**

- **Purpose:** Displays the classification result (text) on the screen.
    
- **Operation:**
    
    - **Invalidate:** Ensures the PS reads the latest classification result from `DDR_BASE_TEXT_FROM_VIT` (where the ViT hardware or another process might write results).
        
    - **Draw:** Uses `DrawString` to render the text (e.g., "Dog: 99%") into the frame buffer.
        
    - **Flush:** Flushes cache again to make the text visible on HDMI.
        
    - _Note: The code currently has a hardcoded string override `text_ptr = "Dog: 99%";` for testing purposes._
        

**3. `DrawChar(...)` and `DrawString(...)`**

- **Purpose:** Renders text onto the video buffer.
    
- **Operation:**
    
    - Reads a bitmap font (`font8x8_basic`).
        
    - Checks bits in the font glyph; if a bit is 1, it writes the `color` pixel to the frame buffer.
        
    - Supports a `scale` factor to make text larger (e.g., scale 4 turns an 8x8 character into 32x32 pixels).
        

---

## 4. Main Execution Flow (`main.c`)

The `main()` function orchestrates the initialization sequence:

1. **Image & UI Prep:**
    
    - Calls `Resize_Load_Image_To_DDR()` to clear the screen and place the resized 224x224 image in the center.
        
    - Calls `Update_Classification_From_Memory()` to draw the initial text overlay.
        
2. **VDMA Initialization:**
    
    - Initializes the VDMA driver.
        
    - Configures it for 720p reading (`ReadSetup`).
        
    - Starts the VDMA (`StartTransfer`), causing the image in DDR to appear on the HDMI monitor.
        
3. **GPIO Initialization:**
    
    - Initializes `GpioOut` (for address/length/control) and `GpioIn` (for status).
        
    - Sets data direction registers (Output for control, Input for status).
        
4. **DMA Logic Test:**
    
    - Runs `test_mm2s()` to send data from DDR to the PL accelerator.
        
    - _(Optional)_ `test_s2mm()` is currently commented out but would verify data returning from PL to DDR.
        
5. **Idle Loop:**
    
    - Enters `while(1)`. The CPU is now idle, but the **VDMA hardware continues running independently**, fetching data from DDR and refreshing the HDMI display at 60Hz.