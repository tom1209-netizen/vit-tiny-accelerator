# SCHEDULER TILER UNIT

| **Document Information** |                                                |
| ------------------------ | ---------------------------------------------- |
| **Module Name**          | `scheduler_tiler`                              |
| **Version**              | 1.0                                            |
| **Design Status**        | In development                                 |
| **Last Updated**         | January 06 2026                                |
| **Source Location**      | `fpga/rtl/scheduler_tiler/scheduler_tiler.v`   |
| **Author**               | Hoang Thuy Tram                                |

## Table of content

1. [Overview](#1-overview)
2. [Features Summary](#2-features-summary)
3. [Theory Of Operation](#3-theory-of-operation)
4. [Module Hierarchy](#4-module-hierarchy)
5. [Parameters](#5-parameters)
6. [Interface Specification](#6-interface-specification)
7. [Memory Map And Buffer Management](#7-memory-map-and-buffer-management)
8. [Finite State Machine (FSM)](#8-finite-state-machine-fsm)
9. [Hierarchical Loop Control Architecture](#9-hierarchical-loop-control-architecture)
10. [Tiling Strategies](#10-tiling-strategies)

## 1. Overview

### 1.1 Purpose

The `scheduler_tiler` acts a the central conductor of the TinyViT hardware accelerator. Its primary role is to offload the complex nested loops and data movement coordination from the CPU (PS). It autonomously manages the execution of entire layers by breaking down large tensors into manageable "tiles" that fit within the limited on-chip BRAM.

### 1.2 Functional Description

The unit performs three critical roles:

1. **Global Sequencing:** Controls the transition between loading weights/inputs, executing compute kernels (GEMM, Conv, Softmax, etc), and storing results back to DDR.
2. **Memory Management:** Implements a Ping-Pong buffering strategy across a 512KB unified BRAM to hide DMA latency and maximize throughput.
3. **Tiling:** Dynamically calculates addresses for strided convolutions and window-based attention without explicitly re-arranging data in off-chip memory.

### 1.3 Design Philosophy

TinyViT tensors (in this case, $224 \times 224 \times 3$) are too large for FPGA BRAM. Therefore, the architecture follows an adaptive memory-aware strategy to balance hardware complexity with the hybrid nature of TinyViT:

- **Tiling Duality:** The design strictly distinguishes between high-resolution and low-resolution stages. Stage 0 and Stage 1 (Convolutional) employ Vertical Strip Tiling to manage the large intermediate expansion tensors (~800 KB) within the 512 KB BRAM. Stage 2 to Stage 4 (Transformer) switch to Window-based Tiling to confine quadratic attention complexity locally.
- **Throughput Synergy:** To feed the Systolic Array (GEMM Core) efficiently, the scheduler requires data to be Spatially Packed (8 pixels of the same channel per word). This allows the $8 \times 8$ GEMM array to be fed with a simple linear read pointer while maintaining 100% compute utilization. Therefore, a dedicated `transpose` module is neccesary during the buffer-write phase.

## 2. Features Summary

| **Feature**         | **Specification**                                                          |
| ------------------- | -------------------------------------------------------------------------- |
| **FSM**             | 6 states                                                                   |
| **Tiling Support**  | Strip tiling and Windown-based tiling                                      |
| **Memory Strategy** | Ping-Pong (Data)                                                           |
| **Internal Buffer** | 512 KB (65,536 $\times$ 64-bit Words)                                      |
| **Compute Engines** | GEMM Core, Depthwise Conv, Softmax, LayerNorm, RELU, Residual Add, Requant |
| **Data Format**     | Spatial Packing (8-bytes per word)                                         |
| **Handshake**       | Full AXI-Stream Control on all compute paths                               |
| **Interrupts**      | Status-based IRQ generation on task completion                             |

## 3. Theory of Operation

### 3.1 The Need For Buffering And Tiling

The PS interacts with the PL via DDR memory. However, DDR bandwidth is insufficent for millions of MAC oprations required by TinyViT. The `buffer_bank` acts as a high-speed cache. Because the total feature map size (for example, Stage 1 expanded tensor $\approx$ 800 KB) exceeds the allocated BRAM (512 KB), the scheduler must tile the work:

1. Load a Tile of input and weights.
2. Compute the result on-chip.
3. Write back to DDR or store on the buffer for the next operation

### 3.2 Spatial Packing And Transpose Requirement

The GEMM Core requires 8 parallel pixels to enter the systolic array every cycle.

- **Standard DMA:** Fetches data in row-major or channel-last format. For linear format, it requires 8 clock cycles to gather 8 pixels for one MAC operation.
- **Spatial Packing:** Store 8 adjacent pixels of the same channel in one 64-bit BRAM word. The `transpose` module sits at the buffer I/O interface to perform bidirectional reformatting: (1) It rearranges incoming DMA streams into this spatial layout, enabling zero-latency GEMM core access via simple linear addressing, and (2) it converts computed results back to standard format before storing them in the buffer for subsequent operations.

## 4. Module Hierarchy

```Text
scheduler_tiler (top-level conductor)
│
├── Global FSM Controller   # Managing S_IDLE -> S_DONE transitions
│
├── Address Generation Unit (AGU)
│   ├── AGU_DMA             # DDR address calculation with strides
│   ├── AGU_BRAM_WR         # Write pointers for Buffer Bank
│   └── AGU_BRAM_RD         # Tiling-aware read pointers (Window/Strip)
│
├── Loop Controllers
│   ├── Tiling Loop         # Iterates through strips/windows
│   ├── Inner Compute Loop  # Manages GEMM accumulation depth
│   └── Add Counter         # For MBConv residual operations
│
├── Buffer Bank (Internal)  # 512KB BRAM (from buffer_bank.v)
│   └── Transpose Unit      # Rearranging data for spatial packing (from transpose.v)
│
└── Compute Dispatcher      # Handshaking with GEMM, Softmax, etc
```

## 5. Parameters

### 5.1 Status Encoding

| **Parameter** | **Value** | **Description**                  |
| ------------- | --------- | ---------------------------------|
| `STAT_IDLE`   | 3'b000    | Idle/Ready state                 |
| `STAT_DONE`   | 3'b001    | Operation complete (Bit 0)       |
| `STAT_BUSY`   | 3'b010    | Accelerator processing (Bit 1)   |
| `STAT_ERROR`  | 3'b100    | Error condition detected (Bit 2) |

### 5.2 FSM State Definitions

| **State**        | **Value** | **Description**                                |
| ---------------- | --------- | ---------------------------------------------- |
| `S_IDLE`         | 0         | Waiting for `start` signal                     |
| `S_LOAD_WEIGHT`  | 1         | Loading weights from DDR to BRAM               |
| `S_LOAD_INPUT`   | 2         | Loading input activations from DDR             |
| `S_COMPUTE`      | 3         | Executing compute kernels (GEMM, Conv, etc)    |
| `S_STORE_OUTPUT` | 4         | Writing results back to DDR or internal buffer |
| `S_DONE`         | 5         | Operation complete, ready for next task        |

### 5.3 Memory Region (Word Index)

| **Region**    | **Parameter**  | **Address (Words)** | **Size (KB)** | **Purpose**                                                     |
| ------------- | -------------- | ------------------- | ------------- | --------------------------------------------------------------- |
| **Region A**  | `PING_ADDR`    | 0                   | 200           | Ping buffer for feature maps (even layers / Stage 2 Scratchpad) |
| **Region B**  | `PONG_ADDR`    | 25,600              | 200           | Pong buffer for feature maps (odd layers)                       |
| **Region C**  | `WEIGHT_ADDR`  | 51,200              | 48            | Weight storage                                                  |
| **Region D1** | `SCRATCH_ADDR` | 57,344              | 32            | Scratch area for intermediate results (Q, K, V, Score matrices) |
| **Region D2** | `SCRATCH_OFF`  | 61,440              | 32            | Secondary scratch offset                                        |

The `buf_sel` register eliminates Read-After-Write hazards:

- **Phase N:** Read `Region A`, Write `Region B`.
- **Phase N + 1:** Read `Region B`, Write `Region A`.

**Memory Layout Note:**

- `OFFSET_Q = 0`: Base offset for Q matrix
- `OFFSET_SCORE = 12,288`: Offset for attention score matrix

### 5.4 Tile Offset Parameters

| **Parameter**            | **Value** | **Description**                                           |
| ------------------------ | --------- | --------------------------------------------------------- |
| `TILE_OFFSET_S1`         | 16'd6272  | Stage 1 tile stride ($56 \times 56 \rightarrow 4$ tiles)  |
| `TILE_OFFSET_S2`         | 16'd784   | Stage 2 tile stride ($28 \times 28 \rightarrow 16$ tiles) |
| `TILE_OFFSET_S3`         | 16'd3920  | Stage 3 tile stride ($14 \times 14 \rightarrow 1$ tile)   |
| `TILE_OFFSET_S4`         | 16'd1960  | Stage 4 tile stride ($7 \times 7 \rightarrow 1$ tile)     |
| `CLASSIFIER_TILE_OFFSET` | 16'd64    | Classifier head tile stride (16 tiles)                    |

### 5.5 DMA Transfer Lengths

| **Parameter** | **Value** | **Description**             |
| ------------- | --------- | --------------------------- |
| `LEN_WEIGHT`  | 24,576    | Weight buffer size in bytes |
| `LEN_INPUT`   | 150,528   | Input buffer size in bytes  |
| `LEN_OUTPUT`  | 50,000    | Output buffer size in bytes |

### 5.6 Block Role Definitions

| **Parameter** | **Value** | **Description**                        |
| ------------- | --------- | -------------------------------------- |
| `ROLE_CONV`   | 4'd1      | Convolutional block (MBConv/Depthwise) |
| `ROLE_CLASS`  | 4'd5      | Classifier head operations             |

### 5.7 Operation Opcodes

#### Transformer Block Operations

| **Opcode**   | **Value** | **Description**                     |
| ------------ | --------- | ----------------------------------- |
| `OP_QKV`     | 3'b000    | Generate Query, Key, Value matrices |
| `OP_SCORE`   | 3'b001    | Compute attention scores (Q × K^T)  |
| `OP_SOFTMAX` | 3'b010    | Apply softmax normalization         |
| `OP_CONTEXT` | 3'b011    | Compute context vectors (Score × V) |
| `OP_MLP1`    | 3'b100    | First MLP layer (expansion)         |
| `OP_MLP2`    | 3'b101    | Second MLP layer (projection)       |
| `OP_PROJ`    | 3'b110    | Projection layer                    |
| `OP_EXPAND`  | 3'b111    | Channel expansion (1×1 conv)        |

#### Classifier Head Operations

| **Opcode** | **Value** | **Description**             |
| ---------- | --------- | --------------------------- |
| `OP_GAP`   | 3'b000    | Global Average Pooling      |
| `OP_NORM`  | 3'b001    | Layer Normalization         |
| `OP_CLASS` | 3'b010    | Linear classification layer |

## 6. Interface Specification

| **Port**                        | **Direction** | **Width** | **Description**                       |
| ------------------------------- | ------------- | --------- | ------------------------------------- |
| **Global & Control Interface**  |               |           |                                       |
| `clk`                           | Input         | 1         | System clock                          |
| `rst_n`                         | Input         | 1         | Active-low asynchronous reset         |
| `start`                         | Input         | 1         | Start signal from CPU/AXI-Lite        |
| `soft_reset`                    | Input         | 1         | Soft reset for internal FSM           |
| `irq_enable`                    | Input         | 1         | Interrupt enable mask                 |
| `status`                        | Output        | 3         | [2] Error, [1] Busy, [0] Done         |
| **Configuration Inputs**        |               |           |                                       |
| `tile_cfg`                      | Input         | 32        | Tile configuration (M, N, K, strides) |
| `layer_cfg`                     | Input         | 32        | Layer config (stage, role, heads)     |
| `addr_a_base`                   | Input         | 32        | DDR base address for buffer A         |
| `addr_b_base`                   | Input         | 32        | DDR base address for buffer B         |
| `addr_c_base`                   | Input         | 32        | DDR base address for output C         |
| **DMA Interface**               |               |           |                                       |
| `dma_start`                     | Output        | 1         | Initiate DMA transfer                 |
| `dma_addr`                      | Output        | 32        | DDR address for DMA operation         |
| `dma_len`                       | Output        | 32        | Transfer length in bytes              |
| `dma_dir`                       | Output        | 1         | 0 = DDR -> BRAM, 1 = BRAM -> DDR      |
| `dma_done`                      | Input         | 1         | DMA completion signal                 |
| `shim_valid_out`                | Input         | 1         | DMA shim output valid indicator       |
| **Memory Interface**            |               |           |                                       |
| `wr_en`                         | Output        | 1         | BRAM write enable                     |
| `wr_addr`                       | Output        | ADDR_WIDTH| BRAM write address (default 16-bit)   |
| `rd_en`                         | Output        | 1         | BRAM read enable                      |
| `rd_addr`                       | Output        | ADDR_WIDTH| BRAM read address (default 16-bit)    |
| **GEMM Interface**              |               |           |                                       |
| `gemm_start`                    | Output        | 1         | Start systolic array computation      |
| `gemm_done`                     | Input         | 1         | GEMM completion signal                |
| **Convolution Interface**       |               |           |                                       |
| `conv_start`                    | Output        | 1         | Start depthwise convolution           |
| `conv_done`                     | Input         | 1         | Convolution completion signal         |
| `conv_height`                   | Output        | 16        | Convolution window height             |
| `conv_width`                    | Output        | 16        | Convolution window width              |
| **Control Signals**             |               |           |                                       |
| `op_class_out`                  | Output        | 3         | Operation class (QKV, MLP, etc)       |
| `compute_data_valid`            | Output        | 1         | Data valid signal to compute engines  |
| `add_en`                        | Output        | 1         | Enable residual add operation         |
| **Requant Interface**           |               |           |                                       |
| `requant_valid`                 | Input         | 1         | Requantization output valid           |
| `requant_scale`                 | Input         | 32        | Quantization multiplier               |
| `requant_shift`                 | Input         | 32        | Quantization shift amount             |

## 7. Memory Map And Buffer Management

### 7.1 Unified Buffer Partitioning

The scheduler manages a 512 KB unified memory space. To maximize performance, it employs a Ping-Pong strategy:

- While Region A (Ping) is being read as the input (for example, for a GEMM operation), Region B (Pong) acts as the write destination for the result.
- In the next sub-layer, the roles are swapped automatically by the `buf_sel` register.

### 7.2 Scratchpad (Region D) Allocation

Region D is used as a fast working set for Transformer attention. It avoids writing large, short-lived intermediate matrices (like the 56 x 56 Attention Score) back to DDR.

- **Stage 2 and 4:** Split into fixed partitions for Q, K, V matrices.
- **Stage 3:** Due to 14 x 14 window size, the scheduler dynamically reallocates Region A as the scratchpad to accommodate the larger tensor.

## 8. Finite State Machine (FSM)

The scheduler operates on a 6-stage master FSM:

1. **S_IDLE:** Resets all pointers. Waits for the `start` signal from AXI Lite.
2. **S_LOAD_WEIGHT**: Commands DMA to fetch weights into `Region C`.
3. **S_LOAD_INPUT**: (Only if necessary) Commands DMA to fetch input feature maps into `Region A`.
4. **S_COMPUTE:** The most complex state.
    - **Logic Branching:** It checks `block_role` and `op_class` to enable specific compute units (GEMM, DW-Conv, or Softmax).
    - **Loop Expiry:** Monitors `gemm_done` and `conv_done`. It only increments `tiling_idx` when the computation completes.
    - Generates BRAM read/write addresses.
    - Manages sub-loops (for example, `add_counter` for residual addition).
    - Loops until the current Tile/Window is complete.
5. **S_STORE_OUTPUT:** Commands DMA (S2MM) to write the final layer result from the buffer back to DDR.
6. **S_DONE:** Asserts `done` and waits for CPU acknowledgment.

| **Current State** | **Condition**    | **Next State**   | **Detailed Action**                                                               |
| ----------------- | ---------------- | ---------------- | --------------------------------------------------------------------------------- |
| `S_IDLE`          | `start == 1`     | `S_LOAD_WEIGHT`  | Latches `layer_cfg`, `tile_cfg` and DDR base addressses. Resets internal pointers |
| `S_LOAD_WEIGHT`   | `dma_done == 1`  | `S_LOAD_INPUT`   | Initiates MM2S DMA. Load Weights for calculation                                  |
| `S_LOAD_INPUT`    | `dma_done == 1`  | `S_COMPUTE`      | Loads input image or feature map. Only for the first layer or context swap        |
| `S_COMPUTE`       | `comp_done == 1` | `S_STORE_OUTPUT` | Master Execution. Drives `gemm_start`/`conv_start`. Manages nested tiling loops   |
| `S_STORE_OUTPUT`  | `dma_done == 1`  | `S_DONE`         | Initiates S2MM DMA to write results to DDR if `WRITE_POLICY` is set               |
| `S_DONE`          | `start == 0`     | `S_IDLE`         | Assert status[0] (Done tick). Waits for CPU handshake                             |

## 9. Hierarchical Loop Control Architecture

The `scheduler_tiler` decomposes TinyViT layers into a 5-level loop hierarchy:

| **Level** | **Loop Name**         | **Logic Controlled**                         | **Variable**         |
| --------- | --------------------- | -------------------------------------------- | -------------------- |
| **L1**    | Global Stage Loop     | Network execution flow (Stage 0 -> Stage 5 ) | `active_stage`       |
| **L2**    | Tiling Loop           | Spatial partitioning                         | `tiling_idx`         |
| **L3**    | Internal Block Loop   | Phases within a block                        | `internal_block_cnt` |
| **L4**    | Arithmetic Phase Loop | Accumulation and Residuals                   | `add_counter`        |
| **L5**    | BRAM Burst Loop       | Cycle-accurate word fetching (8-bytes/cycle) | `ptr_rd/ptr_wr`      |

## 10. Tiling Strategies

The scheduler employs two distinct tiling strategies to manage memory constraints across TinyViT's hybrid architecture:

### 10.1 Strip Tiling (Stage 0-1: Convolutional Layers)

**Challenge:** Stage 1 MBConv expansion creates $56 \times 56 \times 256$ tensors (~800 KB) exceeding 512 KB buffer capacity.

**Solution:** Divide spatial dimensions into 4 horizontal strips (14 rows each), processing MBConv pipeline sequentially per strip:

| **Strip** | **Row Range**       | **Pipeline**                                                                          | **Memory Footprint** |
| --------- | ------------------- | ------------------------------------------------------------------------------------- | -------------------- |
| 0-3       | $14 \times 56$ each | Expand ($64 \rightarrow 256$) → DW Conv $3 \times 3$ → Project ($256 \rightarrow 64$) | 200 KB per strip     |

**Transition to Transformer:** PatchMerging applies stride-2 downsample ($56 \times 56 \rightarrow 28 \times 28$) and writes to DDR, freeing Region A/B for attention scratchpad.

### 10.2 Window Tiling (Stage 2-4: Transformer Layers)

**Challenge:** Stage 2 has 784 tokens ($28 \times 28$). If computing **full self-attention** (every token attends to all tokens), the attention score matrix would be $784 \times 784 = 614{,}656$ elements. With 4 heads and INT8 quantization (1 byte/element), this requires $614{,}656 \times 4 \approx 2.4$ MB - far exceeding the 512 KB buffer.

**Solution:** Partition spatial grid into non-overlapping **local windows**, computing attention only within each window:

| **Stage** | **Resolution**       | **Window Size**      | **Number Of Windows** | **Heads** | **Scratchpad** |
| --------- | -------------------- | -------------------- | --------------------- | --------- | -------------- |
| **2**     | $28 \times 28$ (784) | $7 \times 7$ (49)    | 16                    | 4         | Region D       |
| **3**     | $14 \times 14$ (196) | $14 \times 14$ (196) | 1 (global)            | 5         | Region A       |
| **4**     | $7 \times 7$ (49)    | $7 \times 7$ (49)    | 1 (global)            | 10        | Region D       |

### 10.3 Address Generation Strategy

The scheduler implements **tile-aware address offsets** using `tiling_idx` counter.

**Tile Offset Computation (Per Stage):**

| **Stage** | **Tile Offset**                | **Formula**               | **Purpose**                     |
| --------- | ------------------------------ | ------------------------- | ------------------------------- |
| **0**     | 0                              | Fixed                     | Stem layer (no tiling)          |
| **1**     | `tiling_idx * 6272`            | 4 strips                  | MBConv strip tiling             |
| **2**     | `tiling_idx * 784`             | 16 windows                | Window attention (7×7 per tile) |
| **3**     | `tiling_idx * 3920`            | 1 window (global)         | Global attention (14×14)        |
| **4**     | `tiling_idx * 1960`            | 1 window (global)         | Global attention (7×7)          |
| **5**     | `tiling_idx * 64`              | 16 classifier head tiles  | FC layer tiling                 |

**Key Implementation Details:**

- **Dynamic Base Selection:** `get_read_base()` and `get_write_base()` functions switch between PING/PONG/SCRATCH regions based on `buf_sel`, `stage_id`, and `op_class`.
- **No Explicit Stride Logic:** Downsample stride-2 operations are handled by the Depthwise Conv unit, not AGU.
- **Scratchpad Reallocation:** For Stage 3 (14×14 window), attention matrices overflow Region D, so scheduler reuses PING_ADDR region during attention phases.
- **Per-Operation Offsets:** Transformer ops (QKV, SCORE, CONTEXT) use fixed offsets within scratchpad: `OFFSET_Q = 0`, `OFFSET_SCORE = 12288`.

All transitions use Ping-Pong buffering (`buf_sel` register) to eliminate pipeline stalls.
