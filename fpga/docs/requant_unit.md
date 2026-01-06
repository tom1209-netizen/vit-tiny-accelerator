# Requantization Unit – INT32 to INT8 Per-Channel Quantizer

| **Document Information** |                                     |
| ------------------------ | ----------------------------------- |
| **Module Name**          | `requant_unit`                      |
| **Version**              | 1.0                                 |
| **Design Status**        | In development                      |
| **Last Updated**         | January 06 2026                     |
| **Source Location**      | `fpga/rtl/requant/`                 |
| **Testbench**            | `fpga/tb/requant/tb_requant_unit.v` |
| **Author**               | Le Phuc Khang                       |

## Table of Contents

1. [Overview](#1-overview)
2. [Features Summary](#2-features-summary)
3. [Theory of Operation](#3-theory-of-operation)
4. [Module Architecture](#4-module-architecture)
5. [Parameters](#5-parameters)
6. [Interface Specification](#6-interface-specification)
7. [Data Formats](#7-data-formats)
8. [Processing Modes](#8-processing-modes)
9. [Pipeline Architecture](#9-pipeline-architecture)
10. [Resource Utilization](#10-resource-utilization)
11. [Verification](#11-verification)
12. [Design Constraints](#12-design-constraints)
13. [Known Limitations](#13-known-limitations)
14. [Revision History](#14-revision-history)

## 1. Overview

### 1.1 Purpose

The `requant_unit` module implements per-channel requantization for converting wide accumulator outputs (INT32) back to INT8 format. It is a critical component in the TinyViT-5M accelerator's quantized inference pipeline, bridging the output of compute units (GEMM core, depthwise convolution) with downstream INT8 processing stages.

### 1.2 Functional Description

Requantization converts the INT32 MAC accumulator results back to INT8 using per-channel Q1.31 fixed-point scale factors and optional bias addition. For each output channel `c`, the operation computes:

$$
\text{out}[c] = \text{clamp}\left(\text{round}\left(\frac{(\text{acc}[c] + \text{bias}[c]) \times \text{scale\_q31}[c]}{2^{31}} \div 2^{\text{shift}}\right), -128, 127\right)
$$

Where:

- `acc[c]` is the INT32 accumulator value from upstream compute
- `bias[c]` is the optional per-channel INT32 bias
- `scale_q31[c]` is the per-channel Q1.31 fixed-point scale factor
- `shift` is a configurable right-shift amount (0–31)
- The output is saturated to the INT8 range [-128, 127]

### 1.3 Design Philosophy

The requantization unit follows these design principles:

- **Per-Channel Scales**: Supports different scale factors for each output channel, critical for maintaining quantization accuracy in deep networks
- **Streaming Architecture**: Full AXI-Stream compliance for seamless integration with upstream compute units
- **Dual Mode Operation**: Handles both INT32-packed (2×INT32 per beat) and INT8-packed (8×INT8 per beat) input formats
- **Q1.31 Fixed-Point Scales**: Uses Q1.31 format for high-precision scale representation without floating-point hardware
- **Round-to-Nearest-Even**: Implements banker's rounding to minimize quantization bias

## 2. Features Summary

| Feature                  | Specification                               |
| ------------------------ | ------------------------------------------- |
| **Input Precision**      | INT32 (Mode A) or INT8 (Mode B)             |
| **Output Precision**     | Signed INT8                                 |
| **Scale Format**         | Q1.31 signed fixed-point per-channel        |
| **Bias Support**         | Optional per-channel INT32 bias             |
| **Max Channels**         | Configurable (default: 512)                 |
| **Parallel Lanes**       | 8 INT8 outputs per beat                     |
| **Rounding Mode**        | Round-to-nearest-even (banker's rounding)   |
| **Saturation**           | Configurable, clamps to [-128, 127]         |
| **AXI-Stream Interface** | Slave input, master output, scale/bias load |
| **Backpressure Support** | Full backpressure via output FIFO           |
| **Throughput**           | 1 beat/cycle (after scale table load)       |

## 3. Theory of Operation

### 3.1 Quantization Background

In quantized neural network inference, operations like GEMM and depthwise convolution are performed in INT8 arithmetic, but accumulation produces INT32 results due to the product width. Requantization scales these INT32 accumulators back to INT8 for the next layer.

The mathematical relationship is:

$$
y_{\text{real}} = s_a \cdot s_w \cdot y_{\text{int32}}
$$

To convert to the next layer's INT8 representation:

$$
y_{\text{int8}} = \text{round}\left(\frac{y_{\text{real}}}{s_{\text{out}}}\right) = \text{round}\left(\frac{s_a \cdot s_w}{s_{\text{out}}} \cdot y_{\text{int32}}\right)
$$

The combined scale factor $\frac{s_a \cdot s_w}{s_{\text{out}}}$ is precomputed and stored in Q1.31 fixed-point format.

### 3.2 Q1.31 Fixed-Point Scale Representation

The Q1.31 format represents values in the range $(-1, 1)$ with 31 fractional bits:

$$
\text{real\_value} = \frac{\text{scale\_q31}}{2^{31}}
$$

This allows representing scale factors with high precision. For networks where the scale factor exceeds 1.0, a dynamic shift mechanism extends the representable range:

$$
\text{real\_value} = \frac{\text{scale\_q31}}{2^{31+\text{shift}}}
$$

### 3.3 Processing Flow

```text
IDLE -> LOAD_SCALES -> PROCESS -> (repeat per frame)
```

1. **Scale/Bias Loading**: Pre-load per-channel scale and bias values via dedicated AXI-Stream interface
2. **Processing**: Stream input data, apply per-channel requantization, output packed INT8 results
3. **Packing (Mode A only)**: For INT32 input mode, pack 4 input beats (8×INT8) into 1 output beat

### 3.4 Rounding Implementation

The module implements round-to-nearest-even (banker's rounding) to minimize systematic bias:

```text
For positive values:
  - If remainder > 0.5: round up
  - If remainder < 0.5: round down
  - If remainder == 0.5: round to nearest even (LSB = 0)

For negative values:
  - Apply same logic to absolute value, then negate
```

This rounding mode ensures that ties (exactly 0.5) alternate between rounding up and down, preventing accumulation of rounding errors.

## 4. Module Architecture

### 4.1 Block Diagram



### 4.2 Internal Components

```text
requant_unit (top-level)
│
├── Scale/Bias Memory
│   └── sb_mem[512×64-bit]      # Per-channel scale_q31 + bias storage
│
├── Scale/Bias Loader
│   ├── sb_load_active          # Loading FSM
│   ├── sb_wr_idx               # Write address counter
│   └── sb_load_done            # Completion flag
│
├── Channel Index Logic
│   ├── chan_ptr                # Current channel pointer
│   └── ch_idx32_0/1, ch_idx8[] # Per-lane channel indices
│
├── Requantization Lanes (×8)
│   ├── requant_lane()          # Combinational requant function
│   └── round_shift_rne64()     # Round-to-nearest-even function
│
├── Mode A Packer (INT32→INT8)
│   ├── pack_buf                # 64-bit accumulation buffer
│   ├── pack_count              # Bytes collected (0,2,4,6)
│   └── pack_last               # Deferred TLAST
│
└── Output FIFO
    ├── out_fifo_data[2]        # 2-entry buffer
    ├── out_fifo_count          # Occupancy counter
    └── rptr/wptr               # Read/write pointers
```

## 5. Parameters

### 5.1 Top-Level Parameters

| Parameter      | Default | Range   | Description                           |
| -------------- | ------- | ------- | ------------------------------------- |
| `DATA_WIDTH`   | 64      | 64      | AXI-Stream data bus width             |
| `ACC_WIDTH`    | 32      | 32      | Accumulator (input element) bit-width |
| `LANES_INT8`   | 8       | 8       | Number of INT8 output lanes per beat  |
| `MAX_CHANNELS` | 512     | 64–1024 | Maximum supported channels            |

### 5.2 Derived Parameters (Computed Internally)

| Parameter               | Formula                | Default | Description                 |
| ----------------------- | ---------------------- | ------- | --------------------------- |
| `SCALE_BIAS_W`          | 64 (constant)          | 64      | Scale/bias entry width      |
| `VALUES_PER_INT32_BEAT` | DATA_WIDTH / ACC_WIDTH | 2       | INT32 values per input beat |
| `VALUES_PER_INT8_BEAT`  | LANES_INT8             | 8       | INT8 values per output beat |

### 5.3 Configuration Signals

| Signal             | Width | Description                                    |
| ------------------ | ----- | ---------------------------------------------- |
| `cfg_mode_int32`   | 1     | 1: INT32 input mode, 0: INT8 input mode        |
| `cfg_use_bias`     | 1     | 1: Add bias before scaling, 0: Skip bias       |
| `cfg_shift`        | 5     | Right-shift amount after scaling (0–31)        |
| `cfg_round_en`     | 1     | 1: Enable round-to-nearest-even, 0: Truncate   |
| `cfg_sat_en`       | 1     | 1: Enable saturation to [-128,127], 0: Wrap    |
| `cfg_num_channels` | 16    | Number of channels to process                  |
| `cfg_chan_base`    | 16    | Base channel index (for multi-tile processing) |
| `cfg_proc_start`   | 1     | Pulse to reset channel pointer and start       |

## 6. Interface Specification

### 6.1 Port List

#### Clock and Reset

| Port    | Direction | Width | Description                            |
| ------- | --------- | ----- | -------------------------------------- |
| `clk`   | Input     | 1     | System clock (positive-edge triggered) |
| `rst_n` | Input     | 1     | Active-low asynchronous reset          |

#### Scale/Bias Table Load (AXI-Stream Slave)

| Port               | Direction | Width | Description                                |
| ------------------ | --------- | ----- | ------------------------------------------ |
| `sb_load_start`    | Input     | 1     | Pulse to begin scale/bias loading          |
| `sb_count`         | Input     | 16    | Number of entries to load                  |
| `sb_load_done`     | Output    | 1     | Pulses when loading completes              |
| `s_axis_sb_tdata`  | Input     | 64    | Scale/bias data [63:32]=scale, [31:0]=bias |
| `s_axis_sb_tvalid` | Input     | 1     | Data valid indicator                       |
| `s_axis_sb_tready` | Output    | 1     | Ready to accept data                       |
| `s_axis_sb_tlast`  | Input     | 1     | End of scale/bias stream                   |

#### Data Input (AXI-Stream Slave)

| Port            | Direction | Width | Description                    |
| --------------- | --------- | ----- | ------------------------------ |
| `s_axis_tdata`  | Input     | 64    | Input data (2×INT32 or 8×INT8) |
| `s_axis_tvalid` | Input     | 1     | Data valid indicator           |
| `s_axis_tready` | Output    | 1     | Ready to accept data           |
| `s_axis_tlast`  | Input     | 1     | End of input frame             |

#### Data Output (AXI-Stream Master)

| Port            | Direction | Width | Description                |
| --------------- | --------- | ----- | -------------------------- |
| `m_axis_tdata`  | Output    | 64    | Output data (8×INT8)       |
| `m_axis_tvalid` | Output    | 1     | Data valid indicator       |
| `m_axis_tready` | Input     | 1     | Downstream ready to accept |
| `m_axis_tlast`  | Output    | 1     | End of output frame        |

### 6.2 AXI-Stream Compliance

All AXI-Stream interfaces comply with ARM AMBA 4 AXI-Stream Protocol Specification:

- **Handshake Protocol**: Transfer occurs when both `TVALID` and `TREADY` are high on clock edge
- **TVALID Assertion**: Once asserted, remains high until handshake completes
- **TLAST Semantics**: Marks the final beat of a processing frame

## 7. Data Formats

### 7.1 Scale/Bias Table Format

Each 64-bit entry in the scale/bias table:

```text
  [63:32] = scale_q31  (Q1.31 signed fixed-point scale factor)
  [31: 0] = bias_int32 (INT32 bias value, added before scaling)
```

The table is loaded sequentially, one entry per channel:

```text
Entry 0: channel 0 scale/bias
Entry 1: channel 1 scale/bias
...
Entry N-1: channel N-1 scale/bias
```

### 7.2 Mode A Input Format (INT32)

When `cfg_mode_int32 = 1`, input data contains 2 INT32 values per 64-bit beat:

```text
  [63:32] = acc32_1  (signed INT32 accumulator for channel c+1)
  [31: 0] = acc32_0  (signed INT32 accumulator for channel c)
```

Four input beats (8 channels) are packed into one output beat (8×INT8):

```text
Input beat 0: ch[0], ch[1] → output bytes [0], [1]
Input beat 1: ch[2], ch[3] → output bytes [2], [3]
Input beat 2: ch[4], ch[5] → output bytes [4], [5]
Input beat 3: ch[6], ch[7] → output bytes [6], [7]
→ Output beat: 8×INT8 packed
```

### 7.3 Mode B Input Format (INT8)

When `cfg_mode_int32 = 0`, input data contains 8 INT8 values per beat:

```text
  [63:56] = lane[7]  (signed INT8)
  [55:48] = lane[6]
  ...
  [ 7: 0] = lane[0]
```

Each input beat produces one output beat directly (1:1 ratio).

### 7.4 Output Format

Output is always 8×INT8 packed per beat:

```text
  [63:56] = out[7]   (signed INT8, channels c+7)
  [55:48] = out[6]
  ...
  [ 7: 0] = out[0]   (signed INT8, channel c)
```

## 8. Processing Modes

### 8.1 Mode A: INT32 to INT8 with Packing

Used for converting GEMM/Conv output (2×INT32 per beat) to INT8:

```text
┌─────────────┐     ┌─────────────┐
│ Input Beat 0│     │             │
│ [acc1,acc0] │────►│             │
├─────────────┤     │   Packer    │     ┌─────────────┐
│ Input Beat 1│────►│   Buffer    │────►│ Output Beat │
│ [acc3,acc2] │     │  (8 bytes)  │     │  8×INT8     │
├─────────────┤     │             │     └─────────────┘
│ Input Beat 2│────►│             │
│ [acc5,acc4] │     │             │
├─────────────┤     └─────────────┘
│ Input Beat 3│
│ [acc7,acc6] │
└─────────────┘
```

**Packing Logic**:

- `pack_count` tracks bytes collected (0, 2, 4, 6)
- When `pack_count == 6`, next input completes the packer and emits output
- `pack_last` accumulates TLAST from any input in the pack group

### 8.2 Mode B: INT8 to INT8 (Per-Channel Rescale)

Used for applying per-channel scales to 8×INT8 input (e.g., after activation functions):

```text
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ Input Beat  │────►│  Requant    │────►│ Output Beat │
│  8×INT8     │     │  (×8 lanes) │     │  8×INT8     │
└─────────────┘     └─────────────┘     └─────────────┘
```

Direct 1:1 throughput with no packing delay.

## 9. Pipeline Architecture

### 9.1 Processing Pipeline

| Stage | Name              | Latency  | Description                            |
| ----- | ----------------- | -------- | -------------------------------------- |
| 1     | Scale/Bias Lookup | 0 cycles | Async read from sb_mem (combinational) |
| 2     | Requantization    | 0 cycles | Combinational multiply-shift-round-sat |
| 3     | Packing (Mode A)  | Variable | Accumulate 4 beats before output       |
| 4     | Output FIFO       | 1 cycle  | Buffer for backpressure handling       |

**Total Combinational Latency**: Input to requant_lane output is fully combinational

### 9.2 Requantization Lane Pipeline

Each lane performs the following operations combinationally:

```text
1. Bias Addition:     biased = acc + bias
2. Multiplication:    prod = biased × scale_q31  (64-bit result)
3. Alignment:         aligned = prod >>> 31      (Q31 to integer)
4. Shift:             shifted = round_shift(aligned, cfg_shift)
5. Saturation:        result = clamp(shifted, -128, 127)
```

### 9.3 Round-to-Nearest-Even Algorithm

```verilog
function round_shift_rne64(val, shift):
    if (shift == 0):
        return val

    abs_val = (val < 0) ? -val : val
    base = abs_val >>> shift
    rem = abs_val & ((1 << shift) - 1)
    half = 1 << (shift - 1)

    // Round up if:
    //   - Remainder > half, OR
    //   - Remainder == half AND base is odd (round to even)
    if (rem > half || (rem == half && base[0])):
        base = base + 1

    return (val < 0) ? -base : base
```

### 9.4 Throughput Analysis

| Mode   | Input Beats | Output Beats | Effective Ratio |
| ------ | ----------- | ------------ | --------------- |
| Mode A | 4           | 1            | 4:1 (packing)   |
| Mode B | 1           | 1            | 1:1 (direct)    |

**Backpressure Handling**:

- 2-entry output FIFO absorbs output stalls
- Input is stalled when FIFO is full and packer would produce output

## 10. Resource Utilization

### 10.1 Estimated Resource Usage

**Target Device**: Xilinx Zynq-7020 (xc7z020clg400-1)

| Resource            | Estimated | Notes                           |
| ------------------- | --------- | ------------------------------- |
| **Slice LUTs**      | ~2,500    | Dominated by multipliers        |
| **Slice Registers** | ~500      | Control FSM, FIFO, packer       |
| **Block RAM**       | 1         | 512×64-bit scale/bias table     |
| **DSP Slices**      | 0–16      | Optional DSP inference for mult |

### 10.2 Resource Breakdown by Component

| Component             | LUTs (est.) | Registers | BRAM | Notes                    |
| --------------------- | ----------- | --------- | ---- | ------------------------ |
| sb_mem (512×64)       | 100         | 0         | 1    | Single-port BRAM         |
| 8× requant_lane       | 2,000       | 0         | 0    | 64-bit multiply per lane |
| Packer logic          | 150         | 100       | 0    | shift/mux for packing    |
| Output FIFO           | 100         | 200       | 0    | 2×64-bit entries         |
| Control/channel track | 150         | 200       | 0    | FSM, counters            |

## 11. Verification

### 11.1 Testbench Overview

**Location**: `fpga/tb/requant/tb_requant_unit.v`

The testbench provides comprehensive functional verification:

| Test Case | Mode | Features Tested                   |
| --------- | ---- | --------------------------------- |
| Test 1    | A    | Basic INT32→INT8, packing, TLAST  |
| Test 2    | B    | INT8→INT8, RNE rounding on ties   |
| Test 3    | B    | Saturation at ±127/128 boundaries |
| Test 4    | A    | Backpressure handling with toggle |

### 11.2 Verification Methodology

1. **Golden Reference**: Software `calc_requant` function matches RTL exactly
2. **Scoreboard**: Expected outputs queued, compared against actual output beats
3. **RNE Verification**: Special patterns with 0.5 ties verify even rounding
4. **Saturation Verification**: Extreme values confirm clipping to [-128, 127]
5. **Backpressure**: Random `m_axis_tready` toggling verifies flow control

### 11.3 Running Simulations

```bash
# Using project Makefile
cd fpga/sim
make all TESTNAME=tb_requant_unit

# View waveforms
make wave TESTNAME=tb_requant_unit
```

### 11.4 Expected Output

```text
TEST 1: Mode A basic
TEST 2: Mode B rounding
TEST 3: Saturation
TEST 4: Backpressure
ALL TESTS PASSED
```

### 11.5 Scale Table Generation

The `emit_requant_table.py` tool generates scale/bias tables from the quantization metadata:

```bash
python -m models.tools.emit_requant_table \
  --scales-json checkpoints/int8_5m/scales.json \
  --layer "stages.0.blocks.0.conv1" \
  --input-scale 0.02 \
  --out-dir fpga/data
```

This produces:

- `*_requant.bin`: Binary scale/bias table for DMA loading
- `*_requant.json`: Metadata including layer info, shift amount, scale range

## 12. Design Constraints

### 12.1 Timing Constraints (XDC)

```tcl
## Clock constraint - 200 MHz target
create_clock -period 5.000 -name clk -waveform {0.000 2.500} [get_ports clk]

## Asynchronous reset
set_false_path -from [get_ports rst_n]
```

### 12.2 Critical Path Considerations

The critical path is typically through the requantization lane:

1. 64-bit signed multiply (acc × scale_q31)
2. Round-to-nearest-even logic
3. Saturation comparators

**Optimization Strategies**:

- Use DSP48E1 for 32×32 multiplies
- Pipeline the multiply-shift-round path if Fmax is insufficient
- Register the scale/bias memory output for timing closure

## 13. Known Limitations

### 13.1 Functional Limitations

| Limitation                 | Impact                                  | Workaround                      |
| -------------------------- | --------------------------------------- | ------------------------------- |
| Fixed 64-bit data width    | Cannot process wider accumulator widths | Use multiple passes             |
| 512 channel limit          | Models with >512 channels need splits   | Increase MAX_CHANNELS parameter |
| Async scale memory read    | May limit Fmax                          | Add pipeline register if needed |
| Single shift for all lanes | All channels use same shift             | Precompute scaled Q1.31 values  |

### 13.2 Precision Limitations

| Issue                       | Impact                               | Mitigation                    |
| --------------------------- | ------------------------------------ | ----------------------------- |
| Q1.31 scale range < 1.0     | Cannot represent scales ≥ 1.0        | Use shift parameter to adjust |
| 64-bit intermediate product | Very large accumulators may overflow | Ensure input range is bounded |

## 14. Revision History

| Version | Date            | Author        | Changes                             |
| ------- | --------------- | ------------- | ----------------------------------- |
| 1.0     | January 06 2026 | Le Phuc Khang | Initial comprehensive documentation |

---

## Appendix A: Quick Reference Card

### A.1 Port Summary

```verilog
requant_unit #(
    .DATA_WIDTH   (64),     // 64-bit AXI-Stream
    .ACC_WIDTH    (32),     // INT32 accumulators
    .LANES_INT8   (8),      // 8 output lanes
    .MAX_CHANNELS (512)     // Max 512 channels
) u_requant (
    .clk                (clk),
    .rst_n              (rst_n),
    // Configuration
    .cfg_mode_int32     (mode_int32),
    .cfg_use_bias       (use_bias),
    .cfg_shift          (shift),
    .cfg_round_en       (round_en),
    .cfg_sat_en         (sat_en),
    .cfg_num_channels   (num_channels),
    .cfg_chan_base      (chan_base),
    .cfg_proc_start     (proc_start),
    // Scale/Bias Load
    .sb_load_start      (sb_load_start),
    .sb_count           (sb_count),
    .sb_load_done       (sb_load_done),
    .s_axis_sb_tdata    (sb_tdata),
    .s_axis_sb_tvalid   (sb_tvalid),
    .s_axis_sb_tready   (sb_tready),
    .s_axis_sb_tlast    (sb_tlast),
    // Data Input
    .s_axis_tdata       (in_tdata),
    .s_axis_tvalid      (in_tvalid),
    .s_axis_tready      (in_tready),
    .s_axis_tlast       (in_tlast),
    // Data Output
    .m_axis_tdata       (out_tdata),
    .m_axis_tvalid      (out_tvalid),
    .m_axis_tready      (out_tready),
    .m_axis_tlast       (out_tlast)
);
```

### A.2 Typical Configuration Values

| Use Case                  | cfg_mode_int32 | cfg_shift | cfg_use_bias |
| ------------------------- | -------------- | --------- | ------------ |
| After GEMM (linear layer) | 1              | 0–4       | 1            |
| After Depthwise Conv      | 1              | 0–4       | 1            |
| After GELU/Activation     | 0              | 0–2       | 0            |
| BatchNorm rescale         | 0              | 0         | 1            |

### A.3 Scale Table Entry Layout

```text
┌────────────────────────────────────┬────────────────────────────────────┐
│           scale_q31 [63:32]        │           bias_int32 [31:0]        │
│         (Q1.31 signed fixed)       │            (signed INT32)          │
└────────────────────────────────────┴────────────────────────────────────┘
                                  64 bits
```
