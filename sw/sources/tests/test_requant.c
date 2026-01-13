#include "xaxidma.h"
#include "xgpio.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xtmrctr.h"
#include <string.h>

// Device IDs
#define DMA_SB_DEVICE_ID XPAR_AXI_DMA_0_DEVICE_ID
#define DMA_DATA_DEVICE_ID XPAR_AXI_DMA_1_DEVICE_ID
#define DMA_OUT_DEVICE_ID XPAR_AXI_DMA_2_DEVICE_ID
#define GPIO_DEVICE_ID XPAR_AXI_GPIO_0_DEVICE_ID
#define TIMER_DEVICE_ID XPAR_AXI_TIMER_0_DEVICE_ID

#define GPIO_CTRL_CHANNEL 1
#define GPIO_STATUS_CHANNEL 2
#define TIMER_COUNTER_0 0

// GPIO Control Bit Mapping
// [0]: cfg_mode_int32
// [1]: cfg_use_bias
// [6:2]: cfg_shift (5 bits)
// [7]: cfg_round_en
// [8]: cfg_sat_en
// [9]: cfg_proc_start (pulse)
// [10]: sb_load_start (pulse)
// [26:11]: sb_count / cfg_num_channels

// Test Configuration
#define NUM_CHANNELS 8
#define MODE_INT32 1 // 1=INT32 mode (2x per beat)
#define USE_BIAS 1
#define SHIFT_AMOUNT 0
#define ROUND_EN 1
#define SAT_EN 1

#define SB_SIZE_BYTES (NUM_CHANNELS * 8)    // 64-bit per channel
#define DATA_BEATS_INT32 (NUM_CHANNELS / 2) // 2 INT32 per 64-bit beat
#define DATA_SIZE_BYTES (DATA_BEATS_INT32 * 8)
#define OUTPUT_SIZE_BYTES 8 // 8 INT8 output

// Data Buffers
static u64 scale_bias[NUM_CHANNELS] __attribute__((aligned(64)));
static u64 input_data[DATA_BEATS_INT32] __attribute__((aligned(64)));
static u64 output_data[1] __attribute__((aligned(64)));

// Driver Instances
static XAxiDma dma_sb;
static XAxiDma dma_data;
static XAxiDma dma_out;
static XGpio gpio;
static XTmrCtr timer;

// Initialize Hardware
static int init_hardware(void) {
  int status;
  XAxiDma_Config *cfg;

  cfg = XAxiDma_LookupConfig(DMA_SB_DEVICE_ID);
  status = XAxiDma_CfgInitialize(&dma_sb, cfg);
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

// Initialize Scale/Bias Table (scale=1.0 in Q31, bias=channel_idx)
static void init_scale_bias(void) {
  for (int i = 0; i < NUM_CHANNELS; i++) {
    u32 scale_q31 = 0x40000000; // 1.0 in Q31
    u32 bias = i;               // bias = channel index
    scale_bias[i] = ((u64)scale_q31 << 32) | bias;
  }
}

// Initialize Input Data (INT32 values)
static void init_input_data(void) {
  s32 *ptr = (s32 *)input_data;
  for (int i = 0; i < NUM_CHANNELS; i++) {
    ptr[i] = i * 10; // 0, 10, 20, 30, ...
  }
}

// Build GPIO Control Word
static u32 build_ctrl(int mode_int32, int use_bias, int shift, int round_en,
                      int sat_en, int proc_start, int sb_load, int count) {
  return (mode_int32 & 1) | ((use_bias & 1) << 1) | ((shift & 0x1F) << 2) |
         ((round_en & 1) << 7) | ((sat_en & 1) << 8) | ((proc_start & 1) << 9) |
         ((sb_load & 1) << 10) | ((count & 0xFFFF) << 11);
}

// Run Requant Test
static u32 run_requant_test(void) {
  Xil_DCacheFlushRange((UINTPTR)scale_bias, SB_SIZE_BYTES);
  Xil_DCacheFlushRange((UINTPTR)input_data, DATA_SIZE_BYTES);
  Xil_DCacheInvalidateRange((UINTPTR)output_data, OUTPUT_SIZE_BYTES);

  // Base config (no pulses yet)
  u32 ctrl_base = build_ctrl(MODE_INT32, USE_BIAS, SHIFT_AMOUNT, ROUND_EN,
                             SAT_EN, 0, 0, NUM_CHANNELS);
  XGpio_DiscreteWrite(&gpio, GPIO_CTRL_CHANNEL, ctrl_base);

  // Phase 1: Load scale/bias table
  XAxiDma_SimpleTransfer(&dma_sb, (UINTPTR)scale_bias, SB_SIZE_BYTES,
                         XAXIDMA_DMA_TO_DEVICE);

  // Pulse sb_load_start
  u32 ctrl_sb = build_ctrl(MODE_INT32, USE_BIAS, SHIFT_AMOUNT, ROUND_EN, SAT_EN,
                           0, 1, NUM_CHANNELS);
  XGpio_DiscreteWrite(&gpio, GPIO_CTRL_CHANNEL, ctrl_sb);
  XGpio_DiscreteWrite(&gpio, GPIO_CTRL_CHANNEL, ctrl_base);

  // Wait for sb_load_done
  while ((XGpio_DiscreteRead(&gpio, GPIO_STATUS_CHANNEL) & 0x1) == 0)
    ;
  xil_printf("Scale/bias loaded\r\n");

  // Phase 2: Process data
  XAxiDma_SimpleTransfer(&dma_data, (UINTPTR)input_data, DATA_SIZE_BYTES,
                         XAXIDMA_DMA_TO_DEVICE);
  XAxiDma_SimpleTransfer(&dma_out, (UINTPTR)output_data, OUTPUT_SIZE_BYTES,
                         XAXIDMA_DEVICE_TO_DMA);

  // Start timer and pulse proc_start
  XTmrCtr_Reset(&timer, TIMER_COUNTER_0);
  XTmrCtr_Start(&timer, TIMER_COUNTER_0);
  u32 t_start = XTmrCtr_GetValue(&timer, TIMER_COUNTER_0);

  u32 ctrl_proc = build_ctrl(MODE_INT32, USE_BIAS, SHIFT_AMOUNT, ROUND_EN,
                             SAT_EN, 1, 0, NUM_CHANNELS);
  XGpio_DiscreteWrite(&gpio, GPIO_CTRL_CHANNEL, ctrl_proc);
  XGpio_DiscreteWrite(&gpio, GPIO_CTRL_CHANNEL, ctrl_base);

  // Wait for output DMA
  while (XAxiDma_Busy(&dma_out, XAXIDMA_DEVICE_TO_DMA))
    ;

  u32 t_end = XTmrCtr_GetValue(&timer, TIMER_COUNTER_0);
  XTmrCtr_Stop(&timer, TIMER_COUNTER_0);

  Xil_DCacheInvalidateRange((UINTPTR)output_data, OUTPUT_SIZE_BYTES);

  return t_end - t_start;
}

// Main
int main(void) {
  xil_printf("\r\n=== Requant Unit Timing Test ===\r\n");

  if (init_hardware() != XST_SUCCESS) {
    xil_printf("ERROR: Hardware init failed\r\n");
    return XST_FAILURE;
  }

  init_scale_bias();
  init_input_data();
  xil_printf("Config: %d channels, mode=%s, shift=%d\r\n", NUM_CHANNELS,
             MODE_INT32 ? "INT32" : "INT8", SHIFT_AMOUNT);

  u32 total_cycles = 0;
  int num_runs = 10;

  for (int i = 0; i < num_runs; i++) {
    u32 cycles = run_requant_test();
    xil_printf("Run %d: %lu cycles\r\n", i + 1, cycles);
    total_cycles += cycles;
  }

  xil_printf("\r\n=== Results ===\r\n");
  xil_printf("Channels: %d\r\n", NUM_CHANNELS);
  xil_printf("Average processing cycles: %lu\r\n", total_cycles / num_runs);

  // Print output
  xil_printf("Output: ");
  u8 *out = (u8 *)output_data;
  for (int i = 0; i < 8; i++) {
    xil_printf("%d ", out[i]);
  }
  xil_printf("\r\n");

  return XST_SUCCESS;
}
