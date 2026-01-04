| **Document Information** |                                               |
| ------------------------ | --------------------------------------------- |
| **Module Name**          | layer_norm                                    |
| **Version**              | 1.0                                           |
| **Design Status**        | In development                                |
| **Last Updated**         | January 02 2026                               |
| **Source Location**      | `fpga/rtl/layer_norm/`                        |
| **Testbench**            | `fpga/tb/layer_norm/tb_layer_norm_piplined.v` |
| **Author**               | Nguyen Bui Tuan Anh                           |
## 1. Overview

### 1.1 Purpose

The `layer_norm` module implements a hardware-accelerated Layer Normalization operation, a critical component in Vision Transformers (ViT) and BERT-like architectures. It stabilizes the hidden state dynamics by normalizing input vectors across the feature dimension.

### 1.2 Functional Description

For an input vector $x$ of size $N$, the module computes:

$$y = \frac{x - \mu}{\sqrt{\sigma^2}} \cdot \gamma + \beta$$

Where:

- $\mu = \frac{1}{N}\sum_{i=1}^N x_i$ (Mean)
    
- $\sigma^2 = \frac{1}{N}\sum_{i=1}^N x_i^2 - \mu^2$ (Variance)
    
- $\gamma, \beta$ are learnable affine parameters provided via configuration ports.
    

The module operates on streaming data, buffering the input packet while simultaneously calculating statistics, ensuring high throughput with deterministic latency.

### 1.3 Design Philosophy

The architecture adopts a "Store-and-Forward" strategy with a parallel statistics engine:

- **Dual-Path Processing**: Input data is split into a **Data Beat Path** (FIFO buffered) and a **Statistics Path** (Accumulator/ALU).
    
- **Packet-Based Synchronization**: Statistics ($\mu, \frac{1}{\sqrt{\sigma^2}}$) are computed per packet (beat sequence) and synchronized with the delayed data stream via a Parameter FIFO.
    
- **Pipelined Math**: Complex operations like Inverse Square Root utilize a Peano-curve based approximation with LUTs and Newton-Raphson refinement steps to avoid high-latency dividers.
    
- **Re-quantization**: The final stage optionally re-quantizes the 32-bit internal precision back to 8-bit output, ensuring to be in the range of [-128, 127] to match downstream systolic array requirements.

## 2. Features Summary

| **Feature**            | **Specification**                                                 |
| ---------------------- | ----------------------------------------------------------------- |
| **Input Precision**    | 8 x 8 bit (64-bit beat)                                           |
| **Internal Precision** | 32-bit Fixed Point (Q16.16)                                       |
| **Output Precision**   | Configurable: 8-bit (Re-quantized)                                |
| **Throughput**         | 1 Beat per Clock (after latency)                                  |
| **Packet Support**     | Dynamic lengths (128, 160, 320, 800 supported, can be configured) |
| **Interface**          | AXI4-Stream (Data), Wire (Config)                                 |
| **Backpressure**       | Full backpressure on all AXI-Stream ports                         |
| **Math Engine**        | DSP-accelerated Sum, SumSq, and Scaling                           |
| **Synchronization**    | Auto-alignment of config parameters ($\gamma, \beta$) with data   |