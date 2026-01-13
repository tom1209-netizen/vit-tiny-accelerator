#include "platform.h"

// Global Driver Instances
XAxiDma g_dma_a;   // DMA for input A (or single input)
XAxiDma g_dma_b;   // DMA for input B (dual-input modules)
XAxiDma g_dma_out; // DMA for output
XGpio g_gpio;      // GPIO for control/status
XTmrCtr g_timer;   // Timer for measurement

// Initialization Flags
static int dma_a_initialized = 0;
static int dma_b_initialized = 0;
static int dma_out_initialized = 0;
static int gpio_initialized = 0;
static int timer_initialized = 0;

// Platform Initialization Functions
/**
 * Initialize single-DMA platform (Softmax)
 * - 1 DMA with both MM2S and S2MM
 * - GPIO
 * - Timer
 */
int platform_init_single_dma(void) {
  int status;

  xil_printf("Initializing platform (single DMA mode)...\r\n");

  // Initialize DMA A as primary (both directions)
  if (!dma_a_initialized) {
    status = init_dma(&g_dma_a, DMA_DEVICE_ID);
    CHECK_STATUS(status, "DMA init");
    dma_a_initialized = 1;
    xil_printf("  DMA initialized (ID=%d)\r\n", DMA_DEVICE_ID);
  }

  // Initialize GPIO
  if (!gpio_initialized) {
    status = init_gpio(&g_gpio, GPIO_DEVICE_ID);
    CHECK_STATUS(status, "GPIO init");
    gpio_initialized = 1;
    xil_printf("  GPIO initialized (ID=%d)\r\n", GPIO_DEVICE_ID);
  }

  // Initialize Timer
  if (!timer_initialized) {
    status = init_timer(&g_timer, TIMER_DEVICE_ID);
    CHECK_STATUS(status, "Timer init");
    timer_initialized = 1;
    xil_printf("  Timer initialized (ID=%d)\r\n", TIMER_DEVICE_ID);
  }

  xil_printf("Platform ready.\r\n");
  return XST_SUCCESS;
}

/**
 * Initialize dual-DMA platform (GEMM, Residual)
 * - 2 DMAs for input (MM2S only)
 * - 1 DMA for output (S2MM only, or reuse DMA_A)
 * - GPIO
 * - Timer
 */
int platform_init_dual_dma(void) {
  int status;

  xil_printf("Initializing platform (dual DMA mode)...\r\n");

  // Initialize DMA A (input A)
  if (!dma_a_initialized) {
    status = init_dma(&g_dma_a, DMA_A_DEVICE_ID);
    CHECK_STATUS(status, "DMA A init");
    dma_a_initialized = 1;
    xil_printf("  DMA A initialized (ID=%d)\r\n", DMA_A_DEVICE_ID);
  }

  // Initialize DMA B (input B)
  if (!dma_b_initialized) {
    status = init_dma(&g_dma_b, DMA_B_DEVICE_ID);
    CHECK_STATUS(status, "DMA B init");
    dma_b_initialized = 1;
    xil_printf("  DMA B initialized (ID=%d)\r\n", DMA_B_DEVICE_ID);
  }

  // Initialize DMA Out
  if (!dma_out_initialized) {
    status = init_dma(&g_dma_out, DMA_OUT_DEVICE_ID);
    CHECK_STATUS(status, "DMA Out init");
    dma_out_initialized = 1;
    xil_printf("  DMA Out initialized (ID=%d)\r\n", DMA_OUT_DEVICE_ID);
  }

  // Initialize GPIO
  if (!gpio_initialized) {
    status = init_gpio(&g_gpio, GPIO_DEVICE_ID);
    CHECK_STATUS(status, "GPIO init");
    gpio_initialized = 1;
    xil_printf("  GPIO initialized (ID=%d)\r\n", GPIO_DEVICE_ID);
  }

  // Initialize Timer
  if (!timer_initialized) {
    status = init_timer(&g_timer, TIMER_DEVICE_ID);
    CHECK_STATUS(status, "Timer init");
    timer_initialized = 1;
    xil_printf("  Timer initialized (ID=%d)\r\n", TIMER_DEVICE_ID);
  }

  xil_printf("Platform ready.\r\n");
  return XST_SUCCESS;
}

/**
 * Reset all DMAs (call before each test run)
 */
void platform_reset_dmas(void) {
  if (dma_a_initialized) {
    XAxiDma_Reset(&g_dma_a);
    while (!XAxiDma_ResetIsDone(&g_dma_a))
      ;
  }
  if (dma_b_initialized) {
    XAxiDma_Reset(&g_dma_b);
    while (!XAxiDma_ResetIsDone(&g_dma_b))
      ;
  }
  if (dma_out_initialized) {
    XAxiDma_Reset(&g_dma_out);
    while (!XAxiDma_ResetIsDone(&g_dma_out))
      ;
  }
}

/**
 * Clear GPIO control output
 */
void platform_clear_gpio(void) {
  if (gpio_initialized) {
    XGpio_DiscreteWrite(&g_gpio, GPIO_CTRL_CHANNEL, 0);
  }
}

// Transfer Wrapper Functions (use global instances)
int platform_dma_send_a(void *buffer, u32 size) {
  cache_flush(buffer, size);
  return XAxiDma_SimpleTransfer(&g_dma_a, (UINTPTR)buffer, size,
                                XAXIDMA_DMA_TO_DEVICE);
}

int platform_dma_send_b(void *buffer, u32 size) {
  cache_flush(buffer, size);
  return XAxiDma_SimpleTransfer(&g_dma_b, (UINTPTR)buffer, size,
                                XAXIDMA_DMA_TO_DEVICE);
}

int platform_dma_recv(void *buffer, u32 size) {
  cache_invalidate(buffer, size);
  return XAxiDma_SimpleTransfer(&g_dma_out, (UINTPTR)buffer, size,
                                XAXIDMA_DEVICE_TO_DMA);
}

int platform_dma_wait_send_a(void) {
  return wait_dma_complete(&g_dma_a, XAXIDMA_DMA_TO_DEVICE, 10000000);
}

int platform_dma_wait_send_b(void) {
  return wait_dma_complete(&g_dma_b, XAXIDMA_DMA_TO_DEVICE, 10000000);
}

int platform_dma_wait_recv(void) {
  return wait_dma_complete(&g_dma_out, XAXIDMA_DEVICE_TO_DMA, 10000000);
}

// GPIO Wrapper Functions
void platform_gpio_write(u32 value) {
  XGpio_DiscreteWrite(&g_gpio, GPIO_CTRL_CHANNEL, value);
}

u32 platform_gpio_read(void) {
  return XGpio_DiscreteRead(&g_gpio, GPIO_STATUS_CHANNEL);
}

void platform_gpio_pulse(u32 base_val, u32 bit_mask) {
  gpio_pulse(&g_gpio, base_val, bit_mask);
}

int platform_wait_done(u32 bit_mask) {
  return wait_gpio_status(&g_gpio, bit_mask, 100000000);
}

// Timer Wrapper Functions
u32 platform_timer_start(void) { return timer_start(&g_timer); }

u32 platform_timer_stop(u32 t_start) { return timer_stop(&g_timer, t_start); }

// Cleanup
void platform_cleanup(void) {
  platform_clear_gpio();
  xil_printf("Platform cleanup complete.\r\n");
}
