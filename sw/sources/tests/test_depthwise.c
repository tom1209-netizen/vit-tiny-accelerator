#include "xaxidma.h"
#include "xgpio.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xtmrctr.h"
#include <string.h>

// Device IDs
#define DMA_KERNEL_DEVICE_ID XPAR_AXI_DMA_0_DEVICE_ID
#define DMA_DATA_DEVICE_ID XPAR_AXI_DMA_1_DEVICE_ID
#define DMA_OUT_DEVICE_ID XPAR_AXI_DMA_2_DEVICE_ID
#define GPIO_DEVICE_ID XPAR_AXI_GPIO_0_DEVICE_ID
#define TIMER_DEVICE_ID XPAR_AXI_TIMER_0_DEVICE_ID

#define GPIO_CTRL_CHANNEL 1
#define GPIO_STATUS_CHANNEL 2
#define TIMER_COUNTER_0 0

// GPIO Control Bit Mapping
// [0]: start (pulse)
// [8:1]: cfg_height
// [16:9]: cfg_width
// [24:17]: cfg_channels

// Test Configuration
#define TEST_HEIGHT 8
#define TEST_WIDTH 8
#define TEST_CHANNELS 8 // Must be multiple of LANES (8)
#define KERNEL_SIZE 9   // 3x3

#define LANES 8
#define CHAN_BEATS (TEST_CHANNELS / LANES) // 1

// Kernel: 9 beats per channel group (3x3 weights)
#define KERNEL_BEATS (KERNEL_SIZE * CHAN_BEATS)
#define KERNEL_BYTES (KERNEL_BEATS * 8)

// Data: height * width * chan_beats
#define DATA_BEATS (TEST_HEIGHT * TEST_WIDTH * CHAN_BEATS)
#define DATA_BYTES (DATA_BEATS * 8)

// Output: same as data (same-size convolution)
// But output is INT32 per channel, so 4x larger per element
// Actually output is OUTPUT_WIDTH bits packed
#define OUTPUT_BYTES (TEST_HEIGHT * TEST_WIDTH * TEST_CHANNELS * 4) // INT32

// Data Buffers
static u8 kernel_data[KERNEL_BYTES] __attribute__((aligned(64)));
static u8 input_data[DATA_BYTES] __attribute__((aligned(64)));
static u8 output_data[OUTPUT_BYTES] __attribute__((aligned(64)));

// Driver Instances
static XAxiDma dma_kernel;
static XAxiDma dma_data;
static XAxiDma dma_out;
static XGpio gpio;
static XTmrCtr timer;

// Initialize Hardware
static int init_hardware(void) {
  int status;
  XAxiDma_Config *cfg;

  cfg = XAxiDma_LookupConfig(DMA_KERNEL_DEVICE_ID);
  status = XAxiDma_CfgInitialize(&dma_kernel, cfg);
  if (status != XST_SUCCESS)
    return status;

  cfg = XAxiDma_LookupConfig(DMA_DATA_DEVICE_ID);
  status = XAxiDma_CfgInitialize(&dma_data, cfg);
  if (status != XST_SUCCESS)
    return status;

  cfg = XAxiDma_LookupConfig(DMA_OUT_DEVICE_ID);
  status = XAxiDma_CfgInitialize(&dma_out, cfg);
  if (status != XST_SUCCESS)
    return status;

  status = XGpio_Initialize(&gpio, GPIO_DEVICE_ID);
  if (status != XST_SUCCESS)
    return status;
  XGpio_SetDataDirection(&gpio, GPIO_CTRL_CHANNEL, 0x00000000);
  XGpio_SetDataDirection(&gpio, GPIO_STATUS_CHANNEL, 0xFFFFFFFF);

  status = XTmrCtr_Initialize(&timer, TIMER_DEVICE_ID);
  if (status != XST_SUCCESS)
    return status;

  return XST_SUCCESS;
}

// Initialize Kernel (all-ones for easy verification)
static void init_kernel(void) {
  // All kernel weights = 1
  // Each beat contains 8 lanes of the same kernel position
  memset(kernel_data, 1, KERNEL_BYTES);
}

// Initialize Input Data (ramp pattern)
static void init_input_data(void) {
  s8 *ptr = (s8 *)input_data;
  for (int i = 0; i < DATA_BEATS * 8; i++) {
    ptr[i] = (i / 8) % 16; // Value = (position) mod 16
  }
}

// Build GPIO Control Word

static u32 build_ctrl(int start, int height, int width, int channels) {
  return (start & 1) | ((height & 0xFF) << 1) | ((width & 0xFF) << 9) |
         ((channels & 0xFF) << 17);
}

// Run Depthwise Test
static u32 run_depthwise_test(void) {
  Xil_DCacheFlushRange((UINTPTR)kernel_data, KERNEL_BYTES);
  Xil_DCacheFlushRange((UINTPTR)input_data, DATA_BYTES);
  Xil_DCacheInvalidateRange((UINTPTR)output_data, OUTPUT_BYTES);

  // Set configuration (no start yet)
  u32 ctrl_base = build_ctrl(0, TEST_HEIGHT, TEST_WIDTH, TEST_CHANNELS);
  XGpio_DiscreteWrite(&gpio, GPIO_CTRL_CHANNEL, ctrl_base);

  // Phase 1: Load kernels (before start pulse)
  XAxiDma_SimpleTransfer(&dma_kernel, (UINTPTR)kernel_data, KERNEL_BYTES,
                         XAXIDMA_DMA_TO_DEVICE);
  while (XAxiDma_Busy(&dma_kernel, XAXIDMA_DMA_TO_DEVICE))
    ;
  xil_printf("Kernels loaded\r\n");

  // Phase 2: Start timer and pulse start
  XAxiDma_SimpleTransfer(&dma_data, (UINTPTR)input_data, DATA_BYTES,
                         XAXIDMA_DMA_TO_DEVICE);
  XAxiDma_SimpleTransfer(&dma_out, (UINTPTR)output_data, OUTPUT_BYTES,
                         XAXIDMA_DEVICE_TO_DMA);

  XTmrCtr_Reset(&timer, TIMER_COUNTER_0);
  XTmrCtr_Start(&timer, TIMER_COUNTER_0);
  u32 t_start = XTmrCtr_GetValue(&timer, TIMER_COUNTER_0);

  // Pulse start
  u32 ctrl_start = build_ctrl(1, TEST_HEIGHT, TEST_WIDTH, TEST_CHANNELS);
  XGpio_DiscreteWrite(&gpio, GPIO_CTRL_CHANNEL, ctrl_start);
  XGpio_DiscreteWrite(&gpio, GPIO_CTRL_CHANNEL, ctrl_base);

  // Wait for done
  while ((XGpio_DiscreteRead(&gpio, GPIO_STATUS_CHANNEL) & 0x1) == 0)
    ;

  u32 t_end = XTmrCtr_GetValue(&timer, TIMER_COUNTER_0);
  XTmrCtr_Stop(&timer, TIMER_COUNTER_0);

  // Wait for output DMA
  while (XAxiDma_Busy(&dma_out, XAXIDMA_DEVICE_TO_DMA))
    ;

  Xil_DCacheInvalidateRange((UINTPTR)output_data, OUTPUT_BYTES);

  return t_end - t_start;
}

// Main
int main(void) {
  xil_printf("\r\n=== Depthwise Conv Timing Test ===\r\n");

  if (init_hardware() != XST_SUCCESS) {
    xil_printf("ERROR: Hardware init failed\r\n");
    return XST_FAILURE;
  }

  init_kernel();
  init_input_data();
  xil_printf("Config: %dx%dx%d\r\n", TEST_HEIGHT, TEST_WIDTH, TEST_CHANNELS);

  u32 total_cycles = 0;
  int num_runs = 10;

  for (int i = 0; i < num_runs; i++) {
    u32 cycles = run_depthwise_test();
    xil_printf("Run %d: %lu cycles\r\n", i + 1, cycles);
    total_cycles += cycles;
  }

  u32 avg_cycles = total_cycles / num_runs;
  int total_outputs = TEST_HEIGHT * TEST_WIDTH * TEST_CHANNELS;

  xil_printf("\r\n=== Results ===\r\n");
  xil_printf("Feature map: %dx%dx%d\r\n", TEST_HEIGHT, TEST_WIDTH,
             TEST_CHANNELS);
  xil_printf("Total outputs: %d\r\n", total_outputs);
  xil_printf("Average cycles: %lu\r\n", avg_cycles);
  xil_printf("Throughput: %.2f outputs/cycle\r\n",
             (float)total_outputs / avg_cycles);

  return XST_SUCCESS;
}
