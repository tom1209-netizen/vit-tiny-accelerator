#ifndef PLATFORM_H
#define PLATFORM_H

#include "xaxidma.h"
#include "xgpio.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xtmrctr.h"
#include <string.h>

// Device IDs - Nho update nha tuan em

// Run "xsct" and "connect" to your board, then "ta 1" and "info" to find IDs
// Or check xparameters.h after generating BSP

// For single-DMA modules (Softmax)
#ifndef DMA_DEVICE_ID
#define DMA_DEVICE_ID XPAR_AXI_DMA_0_DEVICE_ID
#endif

// For dual-input modules (GEMM, Residual, Requant, Depthwise)
#ifndef DMA_A_DEVICE_ID
#define DMA_A_DEVICE_ID XPAR_AXI_DMA_0_DEVICE_ID
#endif
#ifndef DMA_B_DEVICE_ID
#define DMA_B_DEVICE_ID XPAR_AXI_DMA_1_DEVICE_ID
#endif
#ifndef DMA_OUT_DEVICE_ID
#define DMA_OUT_DEVICE_ID XPAR_AXI_DMA_2_DEVICE_ID
#endif

// GPIO and Timer (same for all tests)
#ifndef GPIO_DEVICE_ID
#define GPIO_DEVICE_ID XPAR_AXI_GPIO_0_DEVICE_ID
#endif
#ifndef TIMER_DEVICE_ID
#define TIMER_DEVICE_ID XPAR_AXI_TIMER_0_DEVICE_ID
#endif

// GPIO channel mapping
#define GPIO_CTRL_CHANNEL 1   // Output: control signals to DUT
#define GPIO_STATUS_CHANNEL 2 // Input: status signals from DUT

// Timer counter
#define TIMER_COUNTER_0 0

// Clock Configuration
#define PS_CLK_FREQ_HZ 100000000 // 100 MHz typical
#define NS_PER_CYCLE (1000000000.0 / PS_CLK_FREQ_HZ)

// Helper Macros
#define CYCLES_TO_US(cycles) ((cycles) * NS_PER_CYCLE / 1000.0)
#define CYCLES_TO_MS(cycles) ((cycles) * NS_PER_CYCLE / 1000000.0)

// Error Checking Macro
#define CHECK_STATUS(status, msg)                                              \
  do {                                                                         \
    if ((status) != XST_SUCCESS) {                                             \
      xil_printf("ERROR: %s (status=%d)\r\n", msg, status);                    \
      return XST_FAILURE;                                                      \
    }                                                                          \
  } while (0)

// DMA Helper Functions
/**
 * Initialize a single AXI DMA instance
 */
static inline int init_dma(XAxiDma *dma, u32 device_id) {
  XAxiDma_Config *cfg = XAxiDma_LookupConfig(device_id);
  if (!cfg) {
    xil_printf("ERROR: DMA config lookup failed (ID=%lu)\r\n", device_id);
    return XST_FAILURE;
  }

  int status = XAxiDma_CfgInitialize(dma, cfg);
  if (status != XST_SUCCESS) {
    xil_printf("ERROR: DMA init failed (ID=%lu)\r\n", device_id);
    return status;
  }

  // Disable interrupts (we use polling)
  XAxiDma_IntrDisable(dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
  XAxiDma_IntrDisable(dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

  return XST_SUCCESS;
}

/**
 * Wait for DMA transfer to complete with timeout
 */
static inline int wait_dma_complete(XAxiDma *dma, int direction,
                                    u32 timeout_cycles) {
  u32 count = 0;
  while (XAxiDma_Busy(dma, direction)) {
    count++;
    if (count > timeout_cycles) {
      xil_printf("ERROR: DMA timeout\r\n");
      return XST_FAILURE;
    }
  }
  return XST_SUCCESS;
}

// GPIO Helper Functions
/**
 * Initialize AXI GPIO with control output and status input channels
 */
static inline int init_gpio(XGpio *gpio, u32 device_id) {
  int status = XGpio_Initialize(gpio, device_id);
  if (status != XST_SUCCESS) {
    xil_printf("ERROR: GPIO init failed\r\n");
    return status;
  }

  // Channel 1: Output (control to DUT)
  XGpio_SetDataDirection(gpio, GPIO_CTRL_CHANNEL, 0x00000000);

  // Channel 2: Input (status from DUT)
  XGpio_SetDataDirection(gpio, GPIO_STATUS_CHANNEL, 0xFFFFFFFF);

  // Clear control output
  XGpio_DiscreteWrite(gpio, GPIO_CTRL_CHANNEL, 0);

  return XST_SUCCESS;
}

/**
 * Send a pulse on a GPIO bit (rising edge detection in wrapper)
 */
static inline void gpio_pulse(XGpio *gpio, u32 current_val, u32 bit_mask) {
  XGpio_DiscreteWrite(gpio, GPIO_CTRL_CHANNEL, current_val | bit_mask);
  XGpio_DiscreteWrite(gpio, GPIO_CTRL_CHANNEL, current_val);
}

/**
 * Wait for a status bit to be set
 */
static inline int wait_gpio_status(XGpio *gpio, u32 bit_mask,
                                   u32 timeout_cycles) {
  u32 count = 0;
  while ((XGpio_DiscreteRead(gpio, GPIO_STATUS_CHANNEL) & bit_mask) == 0) {
    count++;
    if (count > timeout_cycles) {
      xil_printf("ERROR: GPIO status timeout\r\n");
      return XST_FAILURE;
    }
  }
  return XST_SUCCESS;
}

// Timer Helper Functions
/**
 * Initialize AXI Timer
 */
static inline int init_timer(XTmrCtr *timer, u32 device_id) {
  int status = XTmrCtr_Initialize(timer, device_id);
  if (status != XST_SUCCESS) {
    xil_printf("ERROR: Timer init failed\r\n");
    return status;
  }

  // Set options: count up, no auto-reload
  XTmrCtr_SetOptions(timer, TIMER_COUNTER_0, 0);

  return XST_SUCCESS;
}

/**
 * Start timer and return start value
 */
static inline u32 timer_start(XTmrCtr *timer) {
  XTmrCtr_Reset(timer, TIMER_COUNTER_0);
  XTmrCtr_Start(timer, TIMER_COUNTER_0);
  return XTmrCtr_GetValue(timer, TIMER_COUNTER_0);
}

/**
 * Stop timer and return elapsed cycles
 */
static inline u32 timer_stop(XTmrCtr *timer, u32 t_start) {
  u32 t_end = XTmrCtr_GetValue(timer, TIMER_COUNTER_0);
  XTmrCtr_Stop(timer, TIMER_COUNTER_0);
  return t_end - t_start;
}

// Cache Helper Functions
/**
 * Flush data from cache to memory (before DMA read)
 */
static inline void cache_flush(void *addr, u32 size) {
  Xil_DCacheFlushRange((UINTPTR)addr, size);
}

/**
 * Invalidate cache (before reading DMA results)
 */
static inline void cache_invalidate(void *addr, u32 size) {
  Xil_DCacheInvalidateRange((UINTPTR)addr, size);
}

// Print Helpers
static inline void print_separator(void) {
  xil_printf("----------------------------------------\r\n");
}

static inline void print_test_header(const char *name) {
  xil_printf("\r\n");
  print_separator();
  xil_printf("  %s\r\n", name);
  print_separator();
}

static inline void print_result(const char *label, u32 cycles) {
  xil_printf("%s: %lu cycles (%.2f us @ 100MHz)\r\n", label, cycles,
             CYCLES_TO_US(cycles));
}

#endif // PLATFORM_H
