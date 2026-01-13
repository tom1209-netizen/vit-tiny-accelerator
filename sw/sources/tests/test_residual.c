#include "xaxidma.h"
#include "xgpio.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xtmrctr.h"
#include <string.h>

// Device IDs
#define DMA_A_DEVICE_ID XPAR_AXI_DMA_0_DEVICE_ID
#define DMA_B_DEVICE_ID XPAR_AXI_DMA_1_DEVICE_ID
#define DMA_OUT_DEVICE_ID XPAR_AXI_DMA_2_DEVICE_ID
#define GPIO_DEVICE_ID XPAR_AXI_GPIO_0_DEVICE_ID
#define TIMER_DEVICE_ID XPAR_AXI_TIMER_0_DEVICE_ID

#define GPIO_STATUS_CHANNEL 2
#define TIMER_COUNTER_0 0

// Test Configuration
#define NUM_ELEMENTS 512    // Total INT8 elements
#define ELEMENTS_PER_BEAT 8 // 8 INT8 per 64-bit beat
#define NUM_BEATS (NUM_ELEMENTS / ELEMENTS_PER_BEAT)
#define SIZE_BYTES (NUM_BEATS * 8)

// Data Buffers
static s8 input_a[NUM_ELEMENTS] __attribute__((aligned(64)));
static s8 input_b[NUM_ELEMENTS] __attribute__((aligned(64)));
static s8 output[NUM_ELEMENTS] __attribute__((aligned(64)));

// Driver Instances
static XAxiDma dma_a;
static XAxiDma dma_b;
static XAxiDma dma_out;
static XGpio gpio;
static XTmrCtr timer;

// Saturating Add (reference)
static s8 sat_add(s8 a, s8 b) {
  int sum = (int)a + (int)b;
  if (sum > 127)
    return 127;
  if (sum < -128)
    return -128;
  return (s8)sum;
}

// Initialize Hardware
static int init_hardware(void) {
  int status;
  XAxiDma_Config *cfg;

  cfg = XAxiDma_LookupConfig(DMA_A_DEVICE_ID);
  if (!cfg)
    return XST_FAILURE;
  status = XAxiDma_CfgInitialize(&dma_a, cfg);
  if (status != XST_SUCCESS)
    return status;

  cfg = XAxiDma_LookupConfig(DMA_B_DEVICE_ID);
  if (!cfg)
    return XST_FAILURE;
  status = XAxiDma_CfgInitialize(&dma_b, cfg);
  if (status != XST_SUCCESS)
    return status;

  cfg = XAxiDma_LookupConfig(DMA_OUT_DEVICE_ID);
  if (!cfg)
    return XST_FAILURE;
  status = XAxiDma_CfgInitialize(&dma_out, cfg);
  if (status != XST_SUCCESS)
    return status;

  status = XGpio_Initialize(&gpio, GPIO_DEVICE_ID);
  if (status != XST_SUCCESS)
    return status;
  XGpio_SetDataDirection(&gpio, GPIO_STATUS_CHANNEL, 0xFFFFFFFF);

  status = XTmrCtr_Initialize(&timer, TIMER_DEVICE_ID);
  if (status != XST_SUCCESS)
    return status;
  XTmrCtr_SetOptions(&timer, TIMER_COUNTER_0, XTC_AUTO_RELOAD_OPTION);

  return XST_SUCCESS;
}

// Initialize Test Data
static void init_test_data(void) {
  for (int i = 0; i < NUM_ELEMENTS; i++) {
    input_a[i] = (s8)(i % 128);        // 0,1,2,...,127,0,1,...
    input_b[i] = (s8)(64 - (i % 128)); // Complementary pattern
  }
}

// Run Residual Test
static u32 run_residual_test(void) {
  Xil_DCacheFlushRange((UINTPTR)input_a, SIZE_BYTES);
  Xil_DCacheFlushRange((UINTPTR)input_b, SIZE_BYTES);
  Xil_DCacheInvalidateRange((UINTPTR)output, SIZE_BYTES);

  // For pure dataflow, timing starts when DMAs start
  XTmrCtr_Reset(&timer, TIMER_COUNTER_0);
  XTmrCtr_Start(&timer, TIMER_COUNTER_0);
  u32 t_start = XTmrCtr_GetValue(&timer, TIMER_COUNTER_0);

  // Start all transfers
  XAxiDma_SimpleTransfer(&dma_a, (UINTPTR)input_a, SIZE_BYTES,
                         XAXIDMA_DMA_TO_DEVICE);
  XAxiDma_SimpleTransfer(&dma_b, (UINTPTR)input_b, SIZE_BYTES,
                         XAXIDMA_DMA_TO_DEVICE);
  XAxiDma_SimpleTransfer(&dma_out, (UINTPTR)output, SIZE_BYTES,
                         XAXIDMA_DEVICE_TO_DMA);

  // Wait for output DMA to complete
  while (XAxiDma_Busy(&dma_out, XAXIDMA_DEVICE_TO_DMA))
    ;

  u32 t_end = XTmrCtr_GetValue(&timer, TIMER_COUNTER_0);
  XTmrCtr_Stop(&timer, TIMER_COUNTER_0);

  Xil_DCacheInvalidateRange((UINTPTR)output, SIZE_BYTES);

  return t_end - t_start;
}

// Verify Output
static int verify_output(void) {
  int errors = 0;
  for (int i = 0; i < NUM_ELEMENTS; i++) {
    s8 expected = sat_add(input_a[i], input_b[i]);
    if (output[i] != expected) {
      if (errors < 5) {
        xil_printf("Mismatch [%d]: got %d, exp %d\r\n", i, output[i], expected);
      }
      errors++;
    }
  }
  return errors;
}

// Main
int main(void) {
  xil_printf("\r\n=== Residual Add Timing Test ===\r\n");

  if (init_hardware() != XST_SUCCESS) {
    xil_printf("ERROR: Hardware init failed\r\n");
    return XST_FAILURE;
  }

  init_test_data();
  xil_printf("Data prepared: %d elements\r\n", NUM_ELEMENTS);

  u32 total_cycles = 0;
  int num_runs = 10;

  for (int i = 0; i < num_runs; i++) {
    u32 cycles = run_residual_test();
    xil_printf("Run %d: %lu cycles\r\n", i + 1, cycles);
    total_cycles += cycles;
  }

  xil_printf("\r\n=== Results ===\r\n");
  xil_printf("Elements: %d\r\n", NUM_ELEMENTS);
  xil_printf("Average cycles: %lu\r\n", total_cycles / num_runs);
  xil_printf("Throughput: %.2f elements/cycle\r\n",
             (float)NUM_ELEMENTS * num_runs / total_cycles);

  int errors = verify_output();
  xil_printf("Verification: %s (%d errors)\r\n", errors == 0 ? "PASS" : "FAIL",
             errors);

  return XST_SUCCESS;
}
