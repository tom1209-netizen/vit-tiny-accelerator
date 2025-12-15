# Depthwise 3x3 Convolution Unit Documentation

This document describes the hardware depthwise 3x3 convolution implementation located at `fpga/rtl/depthwise_conv/depthwise_conv_unit.v`. It covers the algorithm design, architecture, I/O interfaces, internal pipeline, and testing methodology.

## Why Depthwise Convolution Needs a Dedicated Unit

### The GEMM Utilization Problem

Standard GEMM operates on dense matrices where every output depends on all inputs. Depthwise convolution is inherently sparse - each output channel depends on only ONE input channel:

| Operation                     | Weight Matrix        | 8×8 Systolic Utilization   |
| ----------------------------- | -------------------- | -------------------------- |
| Standard Conv (3×3, Cin→Cout) | Dense (Cout × 9×Cin) | 100%                       |
| FC / Linear                   | Dense (Dout × Din)   | 100%                       |
| **Depthwise Conv (3×3)**      | Diagonal (C × 9)     | **12.5% (1/8 PEs active)** |

Mapping depthwise to an 8×8 systolic array wastes 87.5% of compute resources. A dedicated unit with 8 parallel MAC units is much more efficient.

### Where This Sits In TinyViT

Depthwise 3×3 convolution appears in two places:

1. **MBConv Blocks (Stage 1)**: Mobile Inverted Bottleneck with depthwise separable conv

    - Channel dimensions: 64, 128 (after expansion)
    - Spatial size: 56×56, 28×28

2. **LocalConv (Stages 2-4)**: Applied after attention to refine local features
    - Applied within each window (7×7 or 14×14)
    - Maintains spatial structure

## Module Overview

The depthwise convolution unit applies a separate 3×3 filter to each input channel independently:

for each channel $c$:

```math
\text{output}[row, col, c] = \sum_{i=-1}^{1} \sum_{j=-1}^{1} \left( \text{input}[row+i, col+j, c] \times \text{kernel}[c, i, j] \right)
```

### Key Features

-   **8-lane parallel processing** (matches AXI-Stream bus width)
-   **BRAM-based line buffers** with sequential 3-cycle window fetch (left→center→right)
-   **Register-based kernel storage** to avoid BRAM fragmentation
-   **Zero padding** for image borders
-   **Pipelined datapath** with proper BRAM read latency handling
-   **Outputs raw INT32** (requantization handled by external `requant_unit`)

## Block Diagram

> [!NOTE]
> Placeholder - diagram will be added later

## Parameterization

| Parameter      | Default | Description                                |
| -------------- | ------- | ------------------------------------------ |
| `DATA_WIDTH`   | 8       | Input/output element width (INT8)          |
| `LANES`        | 8       | Parallel channels per beat                 |
| `INPUT_WIDTH`  | 64      | Input AXI-Stream data width (8 × 8 bits)   |
| `OUTPUT_WIDTH` | 256     | Output AXI-Stream data width (8 × 32 bits) |
| `MAX_WIDTH`    | 28      | Maximum image width (columns)              |
| `MAX_CHANNELS` | 128     | Maximum channels supported                 |
| `ACC_WIDTH`    | 32      | Accumulator width (INT32)                  |

### Parameter Sizing for BRAM Efficiency

The line buffer depth is calculated as:

```
MAX_BEATS_ROW = MAX_WIDTH × (MAX_CHANNELS / LANES)
```

For the default parameters: `28 × 16 = 448 beats/row`

Each line buffer stores `448 × 64 = 28,672 bits`, which fits in a single RAMB36. With 3 line buffers, total BRAM usage is **3 RAMB36** (2.14% of xc7z020).

> **Design Trade-off**: The kernel storage uses `(* ram_style = "registers" *)` instead of BRAM because the 576-bit wide packed format (9 × 64-bit coefficients per channel group) causes severe BRAM fragmentation. Register-based storage is efficient for the small kernel memory (~1KB for 16 channel groups).

## Interfaces (Ports)

### Control

| Port           | Dir | Width | Description                                       |
| -------------- | --- | ----- | ------------------------------------------------- |
| `start`        | in  | 1     | Pulse to begin a new convolution (latches config) |
| `cfg_height`   | in  | 16    | Image height (rows)                               |
| `cfg_width`    | in  | 16    | Image width (columns)                             |
| `cfg_channels` | in  | 16    | Total channels (must be multiple of 8)            |
| `done`         | out | 1     | Pulses when convolution complete                  |

### AXI-Stream Kernel Input (`axis_kernel_in_*`)

| Port                    | Dir | Width | Description                                  |
| ----------------------- | --- | ----- | -------------------------------------------- |
| `axis_kernel_in_tdata`  | in  | 64    | Packed INT8 kernel coefficients (8 per beat) |
| `axis_kernel_in_tvalid` | in  | 1     | Kernel input valid                           |
| `axis_kernel_in_tready` | out | 1     | Ready (only in `S_LOAD_KERNEL`)              |

**Kernel Loading Format:**

Kernels are loaded sequentially: for each channel group (8 channels), stream 9 beats containing the 3×3 coefficients:

```
Beat 0: kernel[chan_group, pos 0, lanes 0-7]  (top-left)
Beat 1: kernel[chan_group, pos 1, lanes 0-7]  (top-center)
...
Beat 8: kernel[chan_group, pos 8, lanes 0-7]  (bottom-right)
```

Total kernel beats = (num_channels / 8) × 9

### AXI-Stream Data Input (`axis_data_in_*`)

| Port                  | Dir | Width | Description                                         |
| --------------------- | --- | ----- | --------------------------------------------------- |
| `axis_data_in_tdata`  | in  | 64    | Packed INT8 input pixels (8 channels per beat)      |
| `axis_data_in_tvalid` | in  | 1     | Input valid                                         |
| `axis_data_in_tlast`  | in  | 1     | Last beat of input (optional, uses cfg for control) |
| `axis_data_in_tready` | out | 1     | Ready (during `S_PROCESS`)                          |

### AXI-Stream Data Output (`axis_data_out_*`)

| Port                   | Dir | Width | Description                               |
| ---------------------- | --- | ----- | ----------------------------------------- |
| `axis_data_out_tdata`  | out | 256   | Packed INT32 accumulators (8 per beat)    |
| `axis_data_out_tvalid` | out | 1     | Output valid                              |
| `axis_data_out_tlast`  | out | 1     | Last beat of output                       |
| `axis_data_out_tready` | in  | 1     | Downstream ready (backpressure supported) |

## Data Layout

### Input Format

Data is streamed **row-by-row**, with channels grouped into beats:

```text
For image H×W×C:

Row 0:
  Pixel (0,0): Beat 0 = channels[0:7], Beat 1 = channels[8:15], ...
  Pixel (0,1): Beat N = channels[0:7], ...
  ...
Row 1:
  Pixel (1,0): ...
  ...
```

Total input beats = H × W × (C / 8)

### Output Format

Same layout as input, but each element is INT32:

```text
axis_data_out_tdata[31:0]   = output[row, col, chan+0]  (INT32)
axis_data_out_tdata[63:32]  = output[row, col, chan+1]  (INT32)
...
axis_data_out_tdata[255:224] = output[row, col, chan+7] (INT32)
```

## State Machine

The depthwise conv unit implements an **8-state FSM** with sequential BRAM fetch stages:

| State           | Value | Description                                    |
| --------------- | ----- | ---------------------------------------------- |
| `S_IDLE`        | 0     | Wait for `start` pulse; latch configuration    |
| `S_LOAD_KERNEL` | 1     | Load all kernel weights sequentially           |
| `S_PROCESS`     | 2     | Check data availability, initiate window fetch |
| `S_FETCH_LEFT`  | 3     | Issue BRAM read for left column                |
| `S_FETCH_CTR`   | 4     | Capture left column, issue center read         |
| `S_FETCH_RIGHT` | 5     | Capture center column, issue right read        |
| `S_FETCH_DONE`  | 6     | Capture right column, trigger MAC pipeline     |
| `S_DONE`        | 7     | Assert `done` signal                           |

### State Transitions

```mermaid
stateDiagram-v2
    direction TB
    [*] --> S_IDLE
    S_IDLE --> S_LOAD_KERNEL: start
    S_LOAD_KERNEL --> S_PROCESS: all kernels loaded
    S_PROCESS --> S_FETCH_LEFT: data available
    S_FETCH_LEFT --> S_FETCH_CTR: 1 cycle
    S_FETCH_CTR --> S_FETCH_RIGHT: capture LEFT
    S_FETCH_RIGHT --> S_FETCH_DONE: capture CENTER
    S_FETCH_DONE --> S_PROCESS: capture RIGHT, MAC trigger
    S_PROCESS --> S_DONE: all outputs sent
    S_DONE --> S_IDLE: done
```

### Sequential BRAM Fetch Pipeline

The 3-cycle fetch sequence handles BRAM read latency:

| Cycle | State         | BRAM Address  | Data Captured |
| ----- | ------------- | ------------- | ------------- |
| 0     | S_FETCH_LEFT  | `beat_left`   | -             |
| 1     | S_FETCH_CTR   | `beat_center` | LEFT column   |
| 2     | S_FETCH_RIGHT | `beat_right`  | CENTER column |
| 3     | S_FETCH_DONE  | -             | RIGHT column  |

This sequential approach uses only **3 single-port BRAMs** instead of 9 multi-port memories, reducing LUTRAM usage to zero.

## Internal Architecture

### 1. Line Buffers (BRAM-Based)

Three rows of the input image are stored in **true dual-port BRAMs** configured as circular buffers:

```verilog
(* ram_style = "block" *) reg [INPUT_WIDTH-1:0] line_buf_0 [0:MAX_BEATS_ROW-1];
(* ram_style = "block" *) reg [INPUT_WIDTH-1:0] line_buf_1 [0:MAX_BEATS_ROW-1];
(* ram_style = "block" *) reg [INPUT_WIDTH-1:0] line_buf_2 [0:MAX_BEATS_ROW-1];
```

-   **Port A**: Write from input stream (during S_PROCESS/S_FETCH states)
-   **Port B**: Read for window extraction (sequential left/center/right)
-   Circular buffer indexing: `line_buf[in_row % 3]` stores current row

### 2. Kernel Storage (Register-Based)

Kernel weights are stored in registers to avoid BRAM fragmentation:

```verilog
(* ram_style = "registers" *)
reg [KERNEL_PACK_WIDTH-1:0] kernel_mem [0:(MAX_CHANNELS/LANES)-1];
```

Each entry holds 9 × 64-bit = 576 bits (all 3×3 coefficients for 8 channels). This format enables single-cycle kernel access during MAC operations.

### 3. Flow Control

The circular buffer requires careful flow control to prevent overwrites:

```verilog
wire input_not_too_far = (in_row <= out_row + 1);
```

With 3 line buffers, processing row R needs rows R-1 (above), R (center), and R+1 (below). Row R+2 would overwrite R-1, so input must stay **at most 1 row ahead** of output.

### 4. Window Extraction

For each output pixel at (out_row, out_col), extract a 3×3 window across 3 fetch cycles:

| Fetch Cycle   | Column        | Captured In        |
| ------------- | ------------- | ------------------ |
| S_FETCH_CTR   | Left (col-1)  | `win_word_row*[0]` |
| S_FETCH_RIGHT | Center (col)  | `win_word_row*[1]` |
| S_FETCH_DONE  | Right (col+1) | `win_word_row*[2]` |

Border handling applies zero padding:

-   Top row (`out_row == 0`): Zero the "above" row
-   Bottom row (`out_row == H-1`): Zero the "below" row
-   Left column (`out_col == 0`): Zero the left column
-   Right column (`out_col == W-1`): Zero the right column

### 5. MAC Pipeline

Two-stage pipelined computation triggered after window capture:

**Stage 1: Multiplication**

```text
prod[0] = win_row0[0] * kernel[0]  // top-left
prod[1] = win_row0[1] * kernel[1]  // top-center
prod[2] = win_row0[2] * kernel[2]  // top-right
prod[3] = win_row1[0] * kernel[3]  // mid-left
prod[4] = win_row1[1] * kernel[4]  // center (main)
prod[5] = win_row1[2] * kernel[5]  // mid-right
prod[6] = win_row2[0] * kernel[6]  // bot-left
prod[7] = win_row2[1] * kernel[7]  // bot-center
prod[8] = win_row2[2] * kernel[8]  // bot-right
```

**Stage 2: Adder Tree**

```math
\text{mac\_result} = \sum_{i=0}^{8} \text{prod}[i]
```

## Pipeline Latency

| Phase                     | Latency (cycles) | Notes                               |
| ------------------------- | ---------------- | ----------------------------------- |
| Kernel loading            | (C/8) × 9        | Sequential kernel stream            |
| Window fetch              | 4                | S_FETCH_LEFT → S_FETCH_DONE         |
| Multiply                  | 1                | 9 parallel multiplications per lane |
| Adder tree                | 1                | 9 → 1 reduction per lane            |
| **Total per output beat** | 6                | Window fetch + MAC pipeline         |

**Example:** For 28×28×128 input:

-   Kernel loading: 16 × 9 = 144 cycles
-   Processing: 28 × 28 × 16 × 6 = 75,264 cycles (with fetch overhead)
-   Effective throughput: ~1 output beat per 6 cycles

> **Trade-off**: The 4-cycle window fetch (vs 1-cycle in LUTRAM design) reduces throughput but eliminates LUTRAM over-utilization.

## Resource Utilization (Post-Route, xc7z020)

| Resource          | Usage | Available | Util%     |
| ----------------- | ----- | --------- | --------- |
| **LUT as Logic**  | 7,248 | 53,200    | 13.62%    |
| **LUT as Memory** | 0     | 17,400    | **0.00%** |
| **Registers**     | 8,479 | 106,400   | 7.97%     |
| **BRAM (RAMB36)** | 3     | 140       | 2.14%     |
| **DSP48E1**       | 2     | 220       | 0.91%     |
| **Slice**         | 3,768 | 13,300    | 28.33%    |

### Key Resource Notes

-   **LUTRAM = 0**: Critical improvement from original design (was 126% over-utilized)
-   **3 RAMB36**: One per line buffer, efficient 448×64 configuration
-   **8,479 registers**: Includes kernel storage (576 bits × 16 groups = 9,216 bits)
-   **Fmax**: ~73 MHz (out-of-context, can be improved with additional pipelining)

## Usage Example

```verilog
// Instantiation
depthwise_conv_unit #(
    .DATA_WIDTH(8),
    .LANES(8),
    .INPUT_WIDTH(64),
    .OUTPUT_WIDTH(256),
    .MAX_WIDTH(28),
    .MAX_CHANNELS(128),
    .ACC_WIDTH(32)
) u_depthwise_conv (
    .clk(clk),
    .rst_n(rst_n),

    // Control
    .start(start),
    .done(done),
    .cfg_height(16'd28),
    .cfg_width(16'd28),
    .cfg_channels(16'd128),

    // Kernel input
    .axis_kernel_in_tdata(kernel_data),
    .axis_kernel_in_tvalid(kernel_valid),
    .axis_kernel_in_tready(kernel_ready),

    // Data input
    .axis_data_in_tdata(input_data),
    .axis_data_in_tvalid(input_valid),
    .axis_data_in_tlast(input_last),
    .axis_data_in_tready(input_ready),

    // Data output (INT32 → external requant)
    .axis_data_out_tdata(output_data),
    .axis_data_out_tvalid(output_valid),
    .axis_data_out_tlast(output_last),
    .axis_data_out_tready(output_ready)
);
```

## Integration with Central Interconnect

The depthwise conv unit integrates into the accelerator as follows:

```mermaid
graph LR
    %% Define nodes with multi-line labels to include data types
    BB_IN["Buffer Bank<br>(INT8)"]
    DCU["depthwise_conv_unit<br>(INT32 out)"]
    RQU["requant_unit<br>(INT8)"]
    BB_OUT["Buffer Bank"]

    %% Define data flow connections
    BB_IN --> DCU
    DCU --> RQU
    RQU --> BB_OUT
```

The scheduler:

1. Loads kernel weights via `axis_kernel_in`
2. Configures dimensions
3. Asserts `start`
4. Streams input from buffer bank
5. Routes INT32 output to `requant_unit`
6. Waits for `done`

## Testing Methodology

See the testbench at `fpga/tb/depthwise_conv/tb_depthwise_conv_unit.v`.

### Test Cases

| Test | Dimensions | Description                    |
| ---- | ---------- | ------------------------------ |
| 1    | 4×4×8      | Simple case with random kernel |
| 2    | 4×4×16     | Two channel groups             |
| 3    | 4×4×8      | All-ones kernel (sum filter)   |
| 4    | 4×4×32     | Four channel groups            |
| 5    | 4×4×16     | Edge case verification         |
| 6    | 7×7×64     | Larger spatial size            |

### Verification Results

All 6 tests pass with exact match to golden reference:

```
PASSED: All 128 elements match (Test 1)
PASSED: All 512 elements match (Test 2)
PASSED: All 128 elements match (Test 3)
PASSED: All 1024 elements match (Test 4)
PASSED: All 512 elements match (Test 5)
PASSED: All 3136 elements match (Test 6)
SUMMARY: 6/6 tests passed - ALL TESTS PASSED!
```

### Verification Approach

1. **Golden Model**: Verilog `expected_out` computed in testbench with same fixed-point arithmetic
2. **Tolerance**: Exact match (no approximation in depthwise conv)
3. **Border Check**: Verify padding produces correct corner/edge results
4. **Streaming**: Verify AXI-Stream protocol compliance with backpressure

## Design History

### Original Issue

The initial design used 9 parallel line buffers (one per 3×3 window position) to enable single-cycle window extraction. This required:

-   9 × (MAX_WIDTH × MAX_CHANNELS/8) × 64-bit memories
-   With MAX_WIDTH=64, MAX_CHANNELS=512: 9 × 4096 × 64 = 2.25 Mbit

This exceeded BRAM capacity and fell back to **LUTRAM**, consuming 22,016 LUTRAM sites (126% of available 17,400).

### Solution: Sequential BRAM Fetch

The redesigned architecture uses:

1. **3 line buffers** (one per circular buffer row) instead of 9
2. **Sequential 4-cycle window fetch** (left→center→right columns)
3. **Register-based kernel storage** to avoid BRAM width fragmentation

Trade-off: 4 extra cycles per output window, but **zero LUTRAM usage** and successful placement.

## Timing Optimizations

The original design achieved only **73.28 MHz** (WNS: -8.647 ns) against a 200 MHz target. Through systematic critical path analysis and pipelining, the design was improved to **156.25 MHz** - a **2.13x improvement**.

### Summary of Optimizations

| Optimization                     | Before     | After      | Improvement |
| -------------------------------- | ---------- | ---------- | ----------- |
| Initial baseline                 | 73.28 MHz  | -          | -           |
| Pipelined `needed_beat`          | 73.28 MHz  | 79.62 MHz  | +6.34 MHz   |
| Eliminated kernel division       | 79.62 MHz  | 101.08 MHz | +21.46 MHz  |
| Pre-computed `out_row_mod3`      | 101.08 MHz | 103.46 MHz | +2.38 MHz   |
| Pre-computed `out_beat_in_row`   | 103.46 MHz | 106.11 MHz | +2.65 MHz   |
| Pre-computed `in_row_mod3`       | 106.11 MHz | 114.14 MHz | +8.03 MHz   |
| Two-stage `needed_beat` pipeline | 114.14 MHz | 150.29 MHz | +36.15 MHz  |
| Registered beat addresses        | 150.29 MHz | 150.76 MHz | +0.47 MHz   |
| Pre-computed edge flags          | 150.76 MHz | 156.25 MHz | +5.49 MHz   |

### Detailed Optimizations

#### 1. Pipelined `needed_beat` Computation

**Problem**: The `needed_beat` calculation (`out_col * num_chan_beats + out_chan_beat`) went through a DSP48 multiplier in a combinational path (~13.6 ns delay).

**Solution**: Added a 2-stage pipeline:

-   Stage 1: Register the DSP multiplication result
-   Added `pipeline_valid` signal to handle pipeline warmup after position changes

```verilog
// Before: Combinational
wire [31:0] needed_beat = out_col * num_chan_beats + out_chan_beat;

// After: Registered with pipeline guard
reg [31:0] needed_beat_r;
reg pipeline_valid;
```

#### 2. Eliminated Kernel Loading Division

**Problem**: The kernel write address computation used `kernel_load_cnt / KERNEL_SIZE` (division by 9), creating a 13-LUT decode chain.

**Solution**: Replaced division with explicit counters:

-   Added `kernel_chan_group` counter (0 to 15)
-   Added `kernel_coeff_idx` counter (0 to 8)
-   Added 2-stage pipeline for kernel memory writes

```verilog
// Before: Division
kernel_mem[kernel_load_cnt / KERNEL_SIZE][...] <= ...

// After: Explicit counters
reg [3:0] kernel_coeff_idx;   // 0-8
reg [3:0] kernel_chan_group;  // 0-15
```

#### 3. Pre-computed Modulo-3 Values

**Problem**: The circular buffer indices used `out_row % 3` and `in_row % 3`, which synthesize to 6-level CARRY4 chains.

**Solution**: Maintain pre-computed registers that update with simple increment logic:

```verilog
// out_row_mod3 tracks out_row % 3
reg [1:0] out_row_mod3;

// Update with simple 0→1→2→0 logic
if (out_row_mod3 == 2'd2)
    out_row_mod3 <= 2'd0;
else
    out_row_mod3 <= out_row_mod3 + 1;
```

#### 4. Pre-computed Beat Address Counter

**Problem**: The beat address computation `out_col * num_chan_beats + out_chan_beat` required a multiplication in the critical path.

**Solution**: Replace with a simple counter that tracks the same value:

```verilog
// out_beat_in_row = out_col * num_chan_beats + out_chan_beat
reg [15:0] out_beat_in_row;

// Increments each fetch, resets at row boundary
if (end_of_row)
    out_beat_in_row <= 16'd0;
else
    out_beat_in_row <= out_beat_in_row + 1;
```

#### 5. Two-stage `needed_beat` Pipeline

**Problem**: The `is_last_output_col` comparison (16-bit equality check) created a 6-level CARRY4 chain feeding into the DSP input mux.

**Solution**: Split into two pipeline stages:

-   Stage 1: Compute `(out_col + 1) * num_chan_beats` unconditionally through DSP
-   Stage 2: Apply correction based on delayed `is_last_output_col` flag

```verilog
// Stage 1: DSP computation (no comparison in path)
reg [31:0] next_col_beat_r;
reg is_last_output_col_d;

always @(posedge clk) begin
    next_col_beat_r <= (out_col + 1) * num_chan_beats;
    is_last_output_col_d <= is_last_output_col;
end

// Stage 2: Correction using delayed flag
always @(posedge clk) begin
    if (is_last_output_col_d)
        needed_beat_r <= next_col_beat_r - num_chan_beats_d + out_chan_beat_d;
    else
        needed_beat_r <= next_col_beat_r + out_chan_beat_d;
end
```

#### 6. Pre-computed Edge Flags

**Problem**: Row and column boundary checks (`out_col == 0`, `out_col == num_cols - 1`, etc.) are 16-bit comparisons creating carry chains in multiple paths.

**Solution**: Maintain registered flags that update when position changes:

```verilog
reg is_first_col_reg;   // = (out_col == 0)
reg is_last_col_reg;    // = (out_col == num_cols - 1)
reg is_first_row_reg;   // = (out_row == 0)
reg is_last_row_reg;    // = (out_row == num_rows - 1)

// Update on position change
if (moving_to_next_col) begin
    is_first_col_reg <= 1'b0;
    is_last_col_reg <= (out_col == num_cols - 2);
end
```

### Remaining Critical Path

After all optimizations, the critical path is in the **MAC (multiply-accumulate) datapath**:

-   8-bit × 8-bit signed multiplications (LUT-based)
-   9-product adder tree for 3×3 convolution
-   Path delay: ~6.4 ns (156 MHz)

To reach 200 MHz would require:

1. Using DSP48 primitives for multiplications
2. Additional pipeline stages in the MAC computation
3. Restructuring the 9-product adder tree

### Key Timing Principles Applied

1. **Replace expensive operations with counters**: Modulo, division, and multiplication can often be replaced with simple counters that track the same value through increment/reset logic.

2. **Pre-compute and register comparison results**: Wide comparisons (16-bit equality checks) create carry chains. Register the results and use delayed flags where semantic allows.

3. **Pipeline DSP48 paths**: DSP48 multipliers have significant setup time requirements. Break combinational paths before DSP inputs.

4. **Use 2-stage pipelines for complex decisions**: When a comparison affects DSP operand selection, compute both possibilities in Stage 1 and select in Stage 2 using the registered comparison result.
