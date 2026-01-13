#include "xaxidma.h"
#include "xgpio.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xtmrctr.h"
#include <string.h>


// Device IDs - Update to match your Block Design
#define DMA_DEVICE_ID XPAR_AXI_DMA_0_DEVICE_ID
#define GPIO_DEVICE_ID XPAR_AXI_GPIO_0_DEVICE_ID
#define TIMER_DEVICE_ID XPAR_AXI_TIMER_0_DEVICE_ID

#define GPIO_CTRL_CHANNEL 1
#define GPIO_STATUS_CHANNEL 2
#define TIMER_COUNTER_0 0


// Test Configuration
#define NUM_TOKENS 64     // Number of tokens to process
#define TOKENS_PER_BEAT 8 // 8 INT8 values per 64-bit beat
#define NUM_INPUT_BEATS (NUM_TOKENS / TOKENS_PER_BEAT)
#define INPUT_SIZE_BYTES (NUM_INPUT_BEATS * 8)
#define OUTPUT_SIZE_BYTES INPUT_SIZE_BYTES


// Data Buffers
static u8 input_data[INPUT_SIZE_BYTES] __attribute__((aligned(64)));
static u8 output_data[OUTPUT_SIZE_BYTES] __attribute__((aligned(64)));


// Driver Instances
static XAxiDma dma;
static XGpio gpio;
static XTmrCtr timer;


// Initialize Hardware
static int init_hardware(void) {
  int status;
  XAxiDma_Config *cfg;

  // Init DMA
  cfg = XAxiDma_LookupConfig(DMA_DEVICE_ID);
  if (!cfg)
    return XST_FAILURE;
  status = XAxiDma_CfgInitialize(&dma, cfg);
  if (status != XST_SUCCESS)
    return status;
  XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
  XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

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


// Initialize Input Data (attention logits in -16 to +15 range)
static void init_input_data(void) {
  s8 *ptr = (s8 *)input_data;
  for (int i = 0; i < NUM_TOKENS; i++) {
    // Create pattern: mostly negative with a peak at position NUM_TOKENS/2
    if (i == NUM_TOKENS / 2) {
      ptr[i] = 15; // Max attention here
    } else {
      ptr[i] = -8 + (i % 16); // Background noise
    }
  }
}


// Run Softmax Test and Measure Cycles
static u32 run_softmax_test(u32 num_tokens) {
  // Flush caches
  Xil_DCacheFlushRange((UINTPTR)input_data, INPUT_SIZE_BYTES);
  Xil_DCacheInvalidateRange((UINTPTR)output_data, OUTPUT_SIZE_BYTES);

  // Setup DMAs
  XAxiDma_SimpleTransfer(&dma, (UINTPTR)input_data, INPUT_SIZE_BYTES,
                         XAXIDMA_DMA_TO_DEVICE);
  XAxiDma_SimpleTransfer(&dma, (UINTPTR)output_data, OUTPUT_SIZE_BYTES,
                         XAXIDMA_DEVICE_TO_DMA);

  // Prepare GPIO control word:
  // [0]: start, [12:1]: num_tokens
  u32 ctrl = ((num_tokens & 0xFFF) << 1);

  // Reset and start timer
  XTmrCtr_Reset(&timer, TIMER_COUNTER_0);
  XTmrCtr_Start(&timer, TIMER_COUNTER_0);
  u32 t_start = XTmrCtr_GetValue(&timer, TIMER_COUNTER_0);

  // Set config then pulse start
  XGpio_DiscreteWrite(&gpio, GPIO_CTRL_CHANNEL, ctrl);
  XGpio_DiscreteWrite(&gpio, GPIO_CTRL_CHANNEL, ctrl | 0x1); // Start pulse
  XGpio_DiscreteWrite(&gpio, GPIO_CTRL_CHANNEL, ctrl);       // Clear start

  // Poll done (bit 0 of status)
  while ((XGpio_DiscreteRead(&gpio, GPIO_STATUS_CHANNEL) & 0x1) == 0) {
    // Busy wait
  }

  // Stop timer
  u32 t_end = XTmrCtr_GetValue(&timer, TIMER_COUNTER_0);
  XTmrCtr_Stop(&timer, TIMER_COUNTER_0);

  // Wait for DMA
  while (XAxiDma_Busy(&dma, XAXIDMA_DEVICE_TO_DMA))
    ;

  Xil_DCacheInvalidateRange((UINTPTR)output_data, OUTPUT_SIZE_BYTES);

  return t_end - t_start;
}


// Verify Output (probabilities should sum to ~255)
static int verify_output(void) {
  u32 sum = 0;
  for (int i = 0; i < NUM_TOKENS; i++) {
    sum += output_data[i];
  }
  xil_printf("Output sum: %lu (expected ~255)\r\n", sum);
  return (sum >= 250 && sum <= 260) ? 1 : 0;
}


// Main
int main(void) {
  xil_printf("\r\n=== Softmax Unit Timing Test ===\r\n");

  if (init_hardware() != XST_SUCCESS) {
    xil_printf("ERROR: Hardware init failed\r\n");
    return XST_FAILURE;
  }
  xil_printf("Hardware initialized\r\n");

  init_input_data();
  xil_printf("Input prepared: %d tokens\r\n", NUM_TOKENS);

  // Run tests
  u32 total_cycles = 0;
  int num_runs = 10;

  for (int i = 0; i < num_runs; i++) {
    u32 cycles = run_softmax_test(NUM_TOKENS);
    xil_printf("Run %d: %lu cycles\r\n", i + 1, cycles);
    total_cycles += cycles;
  }

  u32 avg_cycles = total_cycles / num_runs;
  xil_printf("\r\n=== Results ===\r\n");
  xil_printf("Tokens: %d\r\n", NUM_TOKENS);
  xil_printf("Average cycles: %lu\r\n", avg_cycles);

  // Verify last run
  if (verify_output()) {
    xil_printf("Verification: PASS\r\n");
  } else {
    xil_printf("Verification: FAIL\r\n");
  }

  return XST_SUCCESS;
}
