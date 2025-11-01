# Vision Transformer (Tiny-ViT) Accelerator on Zynq-7000

## 1. Abstract

We implement a TinyViT-5M accelerator on Xilinx Zynq-7000 (Arty Z7) in pure Verilog. Target: **>=1 FPS** on 224×224 input with **INT8** weights/activations and **INT32** accumulation; accuracy within **1–2%** of an INT8 software baseline. Data moves via **AXI-HP + AXI DMA**; control via **AXI-Lite**.

## 2. System Overview

### 2.1 Goals & Metrics

- **Throughput:** >=1 FPS baseline; stretch 2–5 FPS on Z7-20.  
- **Accuracy:** <=2% drop vs. INT8 golden model.  
- **Implementation:** Verilog RTL

### 2.2 Hardware/Software Partition

- **PS (ARM):** config, DMA setup, I/O management, post-processing.  
- **PL:** compute kernels (GEMM, Softmax, GELU, Norm), buffers, control FSMs.  
- **Memory:** External DDR for images/weights/results.

### 2.3 Top-Level Architecture

![Top level diagram](./block_diagram/top.png)
*Figure 1: Top level diagram*

#### 2.3.1 Processing System (PS)

The PS runs the main control firmware on its ARM core. Its primary responsibilities include:

- **Memory Management:** Allocating and managing DDR memory buffers for input images, model weights, and output results.
- **Accelerator Control:** Programming the accelerator's control registers via the AXI-Lite interface to set parameters and start computation.
- **Data Movement:** Configuring AXI DMA transfer descriptors to move data between DDR and the PL.
- **Supervision:** Handling interrupts, monitoring for timeouts, and managing error recovery.
- **Post-processing:** Optionally performing final computations on the results, such as argmax to find the classification.

#### 2.3.2 Programmable Logic (PL)

The PL contains the custom hardware for the ViT computation.

- **ViT Accelerator Core:** A dedicated RTL module containing the compute engines (GEMM, Softmax, Norm, GELU), on-chip tile buffers, and control FSMs that orchestrate the layer computations.
- **AXI DMA Engine:** Provides high-bandwidth data transfer between the external DDR and the accelerator core over AXI-Stream interfaces.
  - **MM2S (Memory-to-Stream):** Reads input tokens and weights from DDR and streams them into the accelerator.
  - **S2MM (Stream-to-Memory):** Captures processed results from the accelerator and writes them back to DDR.

## 3. Global Design Constraints

### 3.1 Clocking & Reset

- Single PL clock domain (**aclk**).  
- **Initial Fmax:** 150 MHz; **Optimization target:** 180–200 MHz.  
- **aresetn:** active-low, synchronous; deterministic reset state.

### 3.2 Numerics & Data Representation

- **INT8** activations/weights (symmetric −128..127); **INT32** accumulators.  
- **Requantization:** `y_int8 = saturate(round((acc * M)/2^s) + zp)` (zp≈0).  
- **Scales:** per-channel (weights) + per-tensor (activations).

### 3.3 Interface Standards

- **AXI4-Stream:** default 128-bit (16×INT8), full tvalid/tready back-pressure, `tlast` on packet end.  
- **AXI4-Lite:** 32-bit CSRs, 32-bit aligned; W1C status flags.

## 4. Accelerator Architecture (PL)

![ViT PL Block Diagram](./block_diagram/vit_pl.png)
*Figure 2: ViT PL Block Diagram, you can look at more detailed version at [google drive](https://drive.google.com/file/d/162GrEpLs2getctECauzURsrsy7bRrSK8/view?usp=sharing)*

### 4.1 Module Inventory

- **axi_lite_regs** – CSR bank (config, status, perf counters).  
- **scheduler_tiler** – master FSM: tiling loops, op sequencing.
- **axi_dma_shim** – DMA command/stream bridge; sustains >= 80% bus bandwidth.  
- **gemm_core** – 8×8 INT8 MAC systolic array (INT32 accumulate).  
- **requant_unit** – INT32->INT8 conversion.
- **residual** - Adds two INT8 vectors, handling potential differences in quantization scales before saturation.
- **attention_block**, **mlp_block** – integrators that sequence shared kernels.

## 5. Functional Block Descriptions

### 5.1 `axi_lite_regs`

**Purpose:** Serves as the single memory-mapped interface between the Processing System (PS) and the Programmable Logic (PL) accelerator.

**Key Functionality:**

- PS-to-PL (Configuration): Receives configuration data from the ARM core via the AXI-Lite bus. It holds registers for base addresses (addr_a_base, addr_b_base, addr_c_base), layer parameters (tile_cfg, layer_cfg), and quantization values (requant_scale, requant_shift).
- PS-to-PL (Control): Provides control signals to the accelerator, most notably the start signal to begin computation, a soft_reset for the FSMs, and an irq_enable flag.
- PL-to-PS (Status): Receives status flags (status[2:0]) from the scheduler_tiler, allowing the PS to poll for accelerator state (e.g., idle, busy, done). This register bank is the central point for all software control and monitoring

### 5.2 `scheduler_tiler`

**Purpose:** Acts as the global sequencer and master controller for the entire accelerator. It orchestrates the full computation of a Transformer layer, issuing commands to all other blocks.

**Key Functionality:**

- **Top-Level Control:** Responds to the start signal from axi_lite_regs to begin its main FSM. It manages the overall operation sequence (e.g., Attention block, then MLP block).
- **DMA Coordination:** Issues high-level commands to the axi_dma_shim (e.g., dma_start_transfer, dma_ddr_addr, dma_length_bytes, dma_direction) to move data tiles from DDR into the PL or write results back. It waits for the dma_transfer_done signal before proceeding.
- **Compute Block Orchestration:** Controls the attention_block and mlp_block by asserting compute_start_op and setting the compute_op_select signal. It waits for their respective attn_block_op_done or mlp_block_op_done flags to synchronize operations.
- **Data Path Configuration:** Dynamically configures the accelerator's internal data path by driving the sel lines for all multiplexers (e.g., gemm_a_mux_sel, requant_in_sel, residual_b_mux_sel, dma_sel). This allows it to route data streams between the correct source and destination modules for each computational phase.
- **Status Reporting:** Provides its current state (status[2:0]) back to the axi_lite_regs for the PS to read.

### 5.3 `axi_dma_shim`

**Purpose:** configures AXI DMA (MM2S/S2MM), tiles streams, collects outputs to DDR.  
**Perf:** target >=80% of theoretical bus BW; randomized back-pressure loopback test.

### 5.4 `gemm_core`

**Purpose:** The primary compute engine of the accelerator, performing high-throughput tiled General Matrix Multiplication (GEMM) with INT8 inputs and INT32 accumulation.
**Key Functionality:**

- **Compute Kernel:** Implements the core $C_{int32} = A_{int8} \times B_{int8}$ operation as an 8x8 systolic array.
- **Handshake:** Receives a start_tile pulse from the gemm_start_mux to begin computation on a new tile.
- **Data Inputs:** Consumes two parallel AXI-Streams: axis_gemm_a (from gemm_a_mux) and axis_gemm_b (from gemm_b_mux). These streams carry the packed INT8 data for the A and B matrices.
- **Data Output:** Produces an AXI-Stream (axis_0) containing the INT32 accumulator results, which is fed to the requant_in_mux.
- **Synchronization:** Asserts tile_done to the gemm_done_demux once it has finished processing the current tile, signaling it is ready for new data.

### 5.5 `requant_unit`

**Purpose:** Converts the 32-bit integer accumulator values from the gemm_core back into 8-bit integers.

**Key Functionality:**

- **Data Input:** Receives an AXI-Stream (axis_in) from the requant_in_mux. This stream can be either INT32 data from the gemm_core or INT8 data from the residual block.
- **Quantization:** When processing INT32 data, it applies the per-tensor or per-channel requantization formula (acc * M >> s) + zp using the scale (M) and shift (s) values provided by the scheduler_tiler (via axi_lite_regs).
- **Saturation:** Saturates the result to the valid INT8 range (e.g., -128 to 127).
- **Data Output:** Emits the final AXI-Stream (axis_out) of requantized INT8 data to the requant_out_demux.

### 5.6 `residual`

**Purpose:** Performs the element-wise addition required for skip connections ($X_{out} = \text{Layer}(X_{in}) + X_{in}$).

**Key Functionality:**

- **Data Inputs:** Receives two AXI-Streams, axis_residual_a and axis_residual_b, from their respective input multiplexers. These represent the two tensors to be added.
- **Element-wise Add:** Performs INT8 addition on the incoming streams. As noted in the report, this operation must handle potential mismatches in quantization scales between the two inputs before saturating the final result.
- **Data Output:** Produces an AXI-Stream (axis_1) containing the INT8 sum, which is routed to the requant_in_mux. This allows the result of the residual add to be passed through the requant_unit for a final normalization or scaling step before being written to DDR.

## 6. Attention Block

![Attention Block](./block_diagram/attention_block.png)

**Role:** orchestrates Q/K/V projections on shared `gemm_core`, computes QKᵀ -> Softmax -> Attn×V; owns tile buffers for Q/K/V and uses `norm_unit`, `softmax_unit`.

### 6.1 Interfaces

### 6.2 Phase map

| Phase   | DMA mode (`dma_mode`) | A-side (`axis_0`) | B-side (`axis_1`) | Requant-A usage |
|---|---|---|---|---|
| **Q-proj** | 0 = tokens | `norm_out` | `axis_wgt` (Wq) | `cap_en=1, cap=Q` |
| **K-proj** | 0 = tokens | `norm_out` | `axis_wgt` (Wk) | `cap_en=1, cap=K` |
| **V-proj** | 0 = tokens | `norm_out` | `axis_wgt` (Wv) | `cap_en=1, cap=V` |
| **QKᵀ** | (no DMA) | `Q_buf` | `Kᵀ` (from buf) | `sfm_en=1` -> **Softmax** |
| **Attn×V** | (no DMA) | `softmax_out` | `V` (from buf) | normal requant -> residual |

> Implementation note: Q/K/V projection phases stream **tokens (A)** against **weights (B)**; intermediate Q & K are captured into tile buffers. QKᵀ result goes through `softmax_unit`; the softmax output tiles multiply **V** to produce the head output (then residual path).  

### 6.3 Control FSM (summary)

1. **Normalize** tokens -> enable Q/K/V projections (three GEMM jobs).  
2. **Sync** when Q/K buffers ready -> schedule **QKᵀ** matmul; gate to Softmax.  
3. **Schedule** **Softmax×V** GEMM; write tiles to output/residual mux.  
4. **Assert** `attn_block_op_done`.

---

## 7. MLP Block

![MLP Block](./block_diagram/mlp_block.png)

Two GEMM stages with `gelu_pwl` between them, plus optional residual add. Uses weight buffer and tile buffer; orchestrated by local FSM and `scheduler_tiler`.

## 8. Dataflow & Pipeline

1. **DDR -> DMA (MM2S)** streams tokens/weights to tile buffers.  
2. **Scheduler** kicks **Attention** phases per §6.2, then **MLP**.  
3. **GEMM** outputs (INT32) -> **requant_unit** -> INT8.  
4. **Residual add** and write-back via **DMA (S2MM)** to DDR.  
5. **PS** reads logits, computes argmax.

## 9. Interfaces & Register Map (AXI-Lite)

| Offset | Register | Dir | Description |
|---:|---|---|---|
| 0x00 | CONTROL | R/W | `[0]=start, [1]=soft_reset, [2]=irq_enable` |
| 0x04 | STATUS | R | `[0]=done_tick, [1]=busy, [2]=error_flag` |
| 0x10 | TILE_CFG | R/W | M/N/K, strides |
| 0x20 | ADDR_A_BASE | R/W | DDR base for A |
| 0x24 | ADDR_B_BASE | R/W | DDR base for B |
| 0x28 | ADDR_C_BASE | R/W | DDR base for C |
| 0x40 | REQUANT_SCALE | R/W | integer `M` |
| 0x44 | REQUANT_SHIFT | R/W | shift `s` |
| 0x70 | LAYER_CFG | R/W | layer index, heads, d, tokens N |

---

## 10. Verification Plan

### 10.1 Unit Tests

- **gemm_core:** vector tests vs NumPy golden; stall + back-pressure.  
- **requant_unit:** exhaustive sweep for rounding/saturation edges.  
- **softmax_unit:** L1 error <=1.5% vs FP target; sum≈1.0 (quantized).  
- **elementwise_ops:** GELU <=2 LSB; Norm cosine sim >=0.995.

### 10.2 Integration Tests

- **attention_block / mlp_block:** end-to-end match vs PyTorch INT8 tensors within MSE tolerance.

### 10.3 System Tests

- DMA loopback; GEMM microbenchmark; PS<->PL regression.

## 12. Risks & Mitigations

- **DDR bandwidth bottleneck:** double-buffering, larger bursts, on-chip reuse.  
- **Timing closure @ 180–200 MHz:** extra pipelining, floorplanning, temp smaller PE array.  
- **Quantization accuracy:** per-channel scales, larger LUTs, post-quant calibration.

## 13. Tools & Environment

Vivado/Vitis 2024.x, Verilator/xsim, Python 3.10 reference model; Arty Z7-20 board; XDC constraints.

## Appendix A. Requantization Details

Derive `M,s,zp` from INT8 calibration; discuss per-channel vs per-tensor trade-offs.

## Appendix B. Signal Dictionary (excerpt)

- `axis_0`, `axis_1`: dual compute paths (A/B) from blocks.  
- `dma_mode`: 0=tokens, 1=weights.  
- `cap_en`: capture enable into phase buffer (Q/K/V).  
- `sfm_en`: route to softmax pipeline.
