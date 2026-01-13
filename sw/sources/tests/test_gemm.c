#include "xaxidma.h"
#include "xgpio.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xtmrctr.h"
#include <string.h>

// Device IDs - Update these to match your Block Design
#define DMA_A_DEVICE_ID XPAR_AXI_DMA_0_DEVICE_ID
#define DMA_B_DEVICE_ID XPAR_AXI_DMA_1_DEVICE_ID
#define DMA_OUT_DEVICE_ID                                                      \
  XPAR_AXI_DMA_2_DEVICE_ID // Or reuse DMA_0 write channel
#define GPIO_DEVICE_ID XPAR_AXI_GPIO_0_DEVICE_ID
#define TIMER_DEVICE_ID XPAR_AXI_TIMER_0_DEVICE_ID

#define GPIO_CTRL_CHANNEL 1
#define GPIO_STATUS_CHANNEL 2
#define TIMER_COUNTER_0 0

// Test Configuration
#define ARRAY_SIZE 8
#define DATA_WIDTH 8                                     // INT8
#define AXIS_DATA_WIDTH 64                               // 64 bits per beat
#define ELEMENTS_PER_BEAT (AXIS_DATA_WIDTH / DATA_WIDTH) // 8

// Wavefront scheduling: 2*N-1 beats = 15 beats for 8x8
#define WAVEFRONT_BEATS (2 * ARRAY_SIZE - 1)
#define INPUT_SIZE_BYTES (WAVEFRONT_BEATS * (AXIS_DATA_WIDTH / 8))

// Output: 8 rows, 4 beats per row (2x INT32 per beat) = 32 beats
#define OUTPUT_BEATS (ARRAY_SIZE * ARRAY_SIZE / 2)
#define OUTPUT_SIZE_BYTES (OUTPUT_BEATS * (AXIS_DATA_WIDTH / 8))

// Data Buffers (must be cache-aligned)
static u8 matrix_a[INPUT_SIZE_BYTES] __attribute__((aligned(64)));
static u8 matrix_b[INPUT_SIZE_BYTES] __attribute__((aligned(64)));
static u8 result_c[OUTPUT_SIZE_BYTES] __attribute__((aligned(64)));

// Driver Instances
static XAxiDma dma_a;
static XAxiDma dma_b;
static XAxiDma dma_out;
static XGpio gpio;
static XTmrCtr timer;

// Initialize Matrix with Ramp Pattern
static void init_matrix_ramp(s8 mat[ARRAY_SIZE][ARRAY_SIZE]) {
  for (int i = 0; i < ARRAY_SIZE; i++) {
    for (int j = 0; j < ARRAY_SIZE; j++) {
      mat[i][j] = (i + j) & 0x7F; // Ramp, avoid overflow
    }
  }
}

// Initialize Identity Matrix (scaled by factor)
static void init_matrix_identity(s8 mat[ARRAY_SIZE][ARRAY_SIZE], s8 scale) {
  memset(mat, 0, ARRAY_SIZE * ARRAY_SIZE);
  for (int i = 0; i < ARRAY_SIZE; i++) {
    mat[i][i] = scale;
  }
}

// Pack matrices into wavefront format for DMA
static void pack_wavefront(u8 *buffer, s8 mat[ARRAY_SIZE][ARRAY_SIZE]) {
  u8 *ptr = buffer;

  for (int cycle = 0; cycle < WAVEFRONT_BEATS; cycle++) {
    // Build one 64-bit beat
    for (int lane = 0; lane < ARRAY_SIZE; lane++) {
      int col = cycle - lane;
      if (col >= 0 && col < ARRAY_SIZE) {
        *ptr = mat[lane][col];
      } else {
        *ptr = 0; // Padding for out-of-range
      }
      ptr++;
    }
  }
}

// Initialize Hardware
static int init_hardware(void) {
  int status;
  XAxiDma_Config *cfg;

  // Init DMA A
  cfg = XAxiDma_LookupConfig(DMA_A_DEVICE_ID);
  if (!cfg)
    return XST_FAILURE;
  status = XAxiDma_CfgInitialize(&dma_a, cfg);
  if (status != XST_SUCCESS)
    return status;
  XAxiDma_IntrDisable(&dma_a, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);

  // Init DMA B
  cfg = XAxiDma_LookupConfig(DMA_B_DEVICE_ID);
  if (!cfg)
    return XST_FAILURE;
  status = XAxiDma_CfgInitialize(&dma_b, cfg);
  if (status != XST_SUCCESS)
    return status;
  XAxiDma_IntrDisable(&dma_b, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);

  // Init DMA Out (or reuse DMA_A write channel)
  cfg = XAxiDma_LookupConfig(DMA_OUT_DEVICE_ID);
  if (!cfg)
    return XST_FAILURE;
  status = XAxiDma_CfgInitialize(&dma_out, cfg);
  if (status != XST_SUCCESS)
    return status;
  XAxiDma_IntrDisable(&dma_out, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

  // Init GPIO
  status = XGpio_Initialize(&gpio, GPIO_DEVICE_ID);
  if (status != XST_SUCCESS)
    return status;
  XGpio_SetDataDirection(&gpio, GPIO_CTRL_CHANNEL, 0x00000000);   // Output
  XGpio_SetDataDirection(&gpio, GPIO_STATUS_CHANNEL, 0xFFFFFFFF); // Input

  // Init Timer
  status = XTmrCtr_Initialize(&timer, TIMER_DEVICE_ID);
  if (status != XST_SUCCESS)
    return status;
  XTmrCtr_SetOptions(&timer, TIMER_COUNTER_0, XTC_AUTO_RELOAD_OPTION);

  return XST_SUCCESS;
}

// Run GEMM Test and Measure Cycles
static u32 run_gemm_test(void) {
  // Flush caches
  Xil_DCacheFlushRange((UINTPTR)matrix_a, INPUT_SIZE_BYTES);
  Xil_DCacheFlushRange((UINTPTR)matrix_b, INPUT_SIZE_BYTES);
  Xil_DCacheInvalidateRange((UINTPTR)result_c, OUTPUT_SIZE_BYTES);

  // Setup DMAs (but don't block)
  XAxiDma_SimpleTransfer(&dma_a, (UINTPTR)matrix_a, INPUT_SIZE_BYTES,
                         XAXIDMA_DMA_TO_DEVICE);
  XAxiDma_SimpleTransfer(&dma_b, (UINTPTR)matrix_b, INPUT_SIZE_BYTES,
                         XAXIDMA_DMA_TO_DEVICE);
  XAxiDma_SimpleTransfer(&dma_out, (UINTPTR)result_c, OUTPUT_SIZE_BYTES,
                         XAXIDMA_DEVICE_TO_DMA);

  // Reset and start timer
  XTmrCtr_Reset(&timer, TIMER_COUNTER_0);
  XTmrCtr_Start(&timer, TIMER_COUNTER_0);
  u32 t_start = XTmrCtr_GetValue(&timer, TIMER_COUNTER_0);

  // Fire start_tile pulse via GPIO
  XGpio_DiscreteWrite(&gpio, GPIO_CTRL_CHANNEL, 0x1); // Set bit 0
  XGpio_DiscreteWrite(&gpio, GPIO_CTRL_CHANNEL, 0x0); // Clear (pulse)

  // Poll tile_done (bit 0 of status channel)
  while ((XGpio_DiscreteRead(&gpio, GPIO_STATUS_CHANNEL) & 0x1) == 0) {
    // Busy wait
  }

  // Stop timer
  u32 t_end = XTmrCtr_GetValue(&timer, TIMER_COUNTER_0);
  XTmrCtr_Stop(&timer, TIMER_COUNTER_0);

  // Wait for output DMA to complete
  while (XAxiDma_Busy(&dma_out, XAXIDMA_DEVICE_TO_DMA)) {
    // Busy wait
  }

  // Invalidate output cache
  Xil_DCacheInvalidateRange((UINTPTR)result_c, OUTPUT_SIZE_BYTES);

  return t_end - t_start;
}

// Main
int main(void) {
  xil_printf("\r\n=== GEMM Core Timing Test ===\r\n");

  // Initialize hardware
  if (init_hardware() != XST_SUCCESS) {
    xil_printf("ERROR: Hardware init failed\r\n");
    return XST_FAILURE;
  }
  xil_printf("Hardware initialized\r\n");

  // Prepare test data
  s8 A[ARRAY_SIZE][ARRAY_SIZE];
  s8 B[ARRAY_SIZE][ARRAY_SIZE];

  init_matrix_ramp(A);
  init_matrix_identity(B, 2); // 2*Identity

  pack_wavefront(matrix_a, A);
  pack_wavefront(matrix_b, B);

  xil_printf("Matrices prepared (A=ramp, B=2*I)\r\n");

  // Run test multiple times for averaging
  u32 total_cycles = 0;
  int num_runs = 10;

  for (int i = 0; i < num_runs; i++) {
    u32 cycles = run_gemm_test();
    xil_printf("Run %d: %lu cycles\r\n", i + 1, cycles);
    total_cycles += cycles;
  }

  u32 avg_cycles = total_cycles / num_runs;
  xil_printf("\r\n=== Results ===\r\n");
  xil_printf("Average cycles: %lu\r\n", avg_cycles);
  xil_printf("For 8x8 tile (64 outputs)\r\n");

  // Calculate throughput at 100MHz
  float time_us = avg_cycles * 0.01f; // At 100MHz, 1 cycle = 10ns
  xil_printf("Estimated time @ 100MHz: %.2f us\r\n", time_us);

  return XST_SUCCESS;
}
