#include "platform.h"

// External platform functions (from platform_init.c)
extern XAxiDma g_dma_a, g_dma_b, g_dma_out;
extern XGpio g_gpio;
extern XTmrCtr g_timer;
extern int platform_init_dual_dma(void);
extern void platform_reset_dmas(void);
extern void platform_cleanup(void);


// Test Configuration
#define ARRAY_SIZE 8
#define WAVEFRONT_BEATS (2 * ARRAY_SIZE - 1) // 15 beats
#define INPUT_SIZE_BYTES (WAVEFRONT_BEATS * 8)
#define OUTPUT_SIZE_BYTES (ARRAY_SIZE * 4 * 8) // 8 rows, 4 beats each


// Data Buffers (cache-aligned)
static u8 matrix_a[INPUT_SIZE_BYTES] __attribute__((aligned(64)));
static u8 matrix_b[INPUT_SIZE_BYTES] __attribute__((aligned(64)));
static u8 result_c[OUTPUT_SIZE_BYTES] __attribute__((aligned(64)));


// Initialize Test Data
static void init_test_data(void) {
  // Simple ramp pattern for A
  for (int beat = 0; beat < WAVEFRONT_BEATS; beat++) {
    for (int lane = 0; lane < 8; lane++) {
      matrix_a[beat * 8 + lane] = (beat + lane) & 0x7F;
    }
  }

  // Identity-like pattern for B (all 1s on diagonal-ish)
  memset(matrix_b, 0, INPUT_SIZE_BYTES);
  for (int beat = 0; beat < WAVEFRONT_BEATS; beat++) {
    for (int lane = 0; lane < 8; lane++) {
      if (beat == lane) {
        matrix_b[beat * 8 + lane] = 1;
      }
    }
  }

  memset(result_c, 0, OUTPUT_SIZE_BYTES);
}


// Run Single GEMM Test
static u32 run_gemm_test(void) {
  // Flush input caches
  cache_flush(matrix_a, INPUT_SIZE_BYTES);
  cache_flush(matrix_b, INPUT_SIZE_BYTES);
  cache_invalidate(result_c, OUTPUT_SIZE_BYTES);

  // Setup DMA transfers
  XAxiDma_SimpleTransfer(&g_dma_a, (UINTPTR)matrix_a, INPUT_SIZE_BYTES,
                         XAXIDMA_DMA_TO_DEVICE);
  XAxiDma_SimpleTransfer(&g_dma_b, (UINTPTR)matrix_b, INPUT_SIZE_BYTES,
                         XAXIDMA_DMA_TO_DEVICE);
  XAxiDma_SimpleTransfer(&g_dma_out, (UINTPTR)result_c, OUTPUT_SIZE_BYTES,
                         XAXIDMA_DEVICE_TO_DMA);

  // Start timer
  u32 t_start = timer_start(&g_timer);

  // Pulse start_tile (bit 0)
  gpio_pulse(&g_gpio, 0, 0x1);

  // Wait for tile_done (bit 0)
  wait_gpio_status(&g_gpio, 0x1, 100000000);

  // Stop timer
  u32 cycles = timer_stop(&g_timer, t_start);

  // Wait for output DMA
  while (XAxiDma_Busy(&g_dma_out, XAXIDMA_DEVICE_TO_DMA))
    ;

  // Invalidate output cache
  cache_invalidate(result_c, OUTPUT_SIZE_BYTES);

  return cycles;
}


// Main
int main(void) {
  print_test_header("GEMM Core Timing Test (Simple)");

  // Initialize platform
  if (platform_init_dual_dma() != XST_SUCCESS) {
    xil_printf("Platform init failed!\r\n");
    return -1;
  }

  // Prepare test data
  init_test_data();
  xil_printf("Test data prepared.\r\n");

  // Run multiple tests
  u32 total_cycles = 0;
  int num_runs = 5;

  xil_printf("\r\nRunning %d tests...\r\n", num_runs);
  for (int i = 0; i < num_runs; i++) {
    platform_reset_dmas();
    u32 cycles = run_gemm_test();
    xil_printf("  Run %d: %lu cycles\r\n", i + 1, cycles);
    total_cycles += cycles;
  }

  // Print results
  u32 avg = total_cycles / num_runs;
  xil_printf("\r\nResults:\r\n");
  print_result("  Average", avg);
  xil_printf("  Throughput: %.2f ops/cycle (64 MACs)\r\n", 64.0 / avg);

  platform_cleanup();
  return 0;
}
