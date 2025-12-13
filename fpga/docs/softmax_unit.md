# Softmax Unit Documentation

This document describes the hardware softmax implementation located under `fpga/rtl/softmax`. It covers the algorithm design, fixed-point representation, I/O interfaces, internal pipeline, and resource usage.

## Module Overview

The softmax unit computes the softmax function over a sequence of tokens using a **three-pass algorithm** with max-subtraction for numerical stability:

```
softmax(x_i) = exp(x_i - max(x)) / Σ exp(x_j - max(x))
```

### Three-Pass Algorithm

| Pass | State | Description |
|------|-------|-------------|
| **Pass 0** | `S_FIND_MAX` | Stream logits, find global max, buffer raw inputs |
| **Pass 1** | `S_ACCUMULATE` | Compute exp(x - max), sum all exp values, buffer in FIFO |
| **Pass 2** | `S_NORMALIZE` | Compute 1/sum via MSR, multiply buffered exp values |

This approach provides:
- **Numerical stability**: Max-subtraction ensures exp inputs are ≤ 0
- **No division hardware**: Multiply-shift-round (MSR) approximation
- **Efficient streaming**: 8 elements processed per cycle

## Block Diagram

> [!NOTE]
> I will add in later

## Parameterization

| Parameter | Default | Description |
|-----------|---------|-------------|
| `AXIS_DATA_WIDTH` | 64 | AXI-Stream data width (8 lanes × 8 bits) |
| `DATA_WIDTH` | 8 | Input/output element width (INT8/UINT8) |
| `EXP_WIDTH` | 20 | Exponential LUT output width (Q4.16 fixed-point) |
| `SUM_WIDTH` | 32 | Accumulator width for exp sum |
| `RECIP_WIDTH` | 16 | Reciprocal approximation width (Q1.15) |
| `FIFO_DEPTH` | 256 | Maximum tokens (256 × 8 = 2048 elements) |
| `EXP_INIT_FILE` | `lut/exp_table_q4_16.hex` | Exponential LUT file |
| `RECIP_INIT_FILE` | `lut/recip_lut.hex` | Reciprocal LUT file |

## State Machine

The softmax unit implements a **5-state FSM** with max-subtraction:

> [!NOTE]
> I will add in later

| State | Duration | Description |
|-------|----------|-------------|
| `S_IDLE` | - | Wait for `start` pulse |
| `S_FIND_MAX` | N/8 cycles | Accept inputs, find max, buffer to input_fifo |
| `S_ACCUMULATE` | N/8 cycles | Read input_fifo, compute exp(x-max), accumulate |
| `S_CALC_RECIP` | 1 cycle | MSR computes reciprocal approximation |
| `S_NORMALIZE` | N/8 cycles | Pop exp_fifo, multiply, output results |


## Internal Blocks

### 1. Exponential ROM (`exp_rom.v`)

Converts signed INT8 logits to fixed-point exponential values.

```
Input:  INT8 [-128, +127] representing logit value
Output: Q4.16 unsigned fixed-point exp(x)
```

**Implementation:**
- 256-entry ROM (2^8 addresses)
- 20-bit output width (Q4.16 format)
- Synchronous read (1-cycle latency)
- Pre-computed values from `lut/exp_table_q4_16.hex`

**Fixed-Point Format:**
```
Q4.16: 4 integer bits + 16 fractional bits
Range: 0.0 to 15.9999... (sufficient for exp(-127) to exp(127))
```

### 2. Multiply-Shift-Round Unit (`msr_unit.v`)

Computes an approximation of `1/global_sum` without division hardware.

**Algorithm:**
1. Find leading-one position (priority encoder)
2. Normalize sum by right-shifting to get 6-bit mantissa
3. Use mantissa as LUT index to get reciprocal approximation
4. Output shift amount to denormalize the product later

```
Input:  global_sum (32-bit)
Output: recip_out (Q1.15 reciprocal multiplier)
        shift_alpha (5-bit shift amount for post-multiply)
```

**LUT Details:**
- 64 entries (6-bit address)
- 16-bit output (Q1.15 format)
- Pre-computed from `lut/recip_lut.hex`

### 3. Softmax FIFO (`softmax_fifo.v`)

Buffers exp() results from Pass 1 for use in Pass 2.

| Parameter | Value | Description |
|-----------|-------|-------------|
| `WIDTH` | 160 bits | 8 lanes × 20 bits/lane |
| `DEPTH` | 256 entries | Supports up to 2048 tokens |

**Features:**
- Synchronous clear (`clr` signal)
- Full/empty status flags
- Read-through (combinational output)

### 4. Normalization Datapath

Two-stage pipeline in S_NORMALIZE:

```
Stage A: exp_pop × msr_mult_r → prod_reg (36-bit)
Stage B: (prod_reg >> msr_shift_r >> 7) → saturate → UINT8 output
```

## Fixed-Point Number Formats

| Value | Format | Bits | Range |
|-------|--------|------|-------|
| Input logit | INT8 | 8 | -128 to +127 |
| exp(logit) | Q4.16 | 20 | 0.0 to ~15.99 |
| global_sum | Q20.12 | 32 | Accumulated sum |
| Reciprocal | Q1.15 | 16 | 0.0 to ~1.99 |
| Product | Q5.31 | 36 | exp × recip |
| Output | UINT8 | 8 | 0 to 255 (0.0 to 1.0) |

## Pipeline Latency

| Phase | Latency (cycles) | Notes |
|-------|------------------|-------|
| Input to exp_out | 1 | ROM read latency |
| exp_out to FIFO write | 1 | Registration |
| CALC_RECIP | 1 | MSR combinational |
| FIFO pop to output | 2 | Multiply + shift/sat |
| **Total Pass 1** | N/8 + 2 | N = number of tokens |
| **Total Pass 2** | N/8 + 2 | |

**Example:** For 2048 tokens:
- Pass 1: 256 + 2 = 258 cycles
- Pass 2: 256 + 2 = 258 cycles
- Total: ~516 cycles

## Usage Example

```verilog
// Instantiation
softmax_unit #(
    .AXIS_DATA_WIDTH(64),
    .DATA_WIDTH(8),
    .EXP_WIDTH(20),
    .SUM_WIDTH(32),
    .RECIP_WIDTH(16),
    .FIFO_DEPTH(256),
    .EXP_INIT_FILE("lut/exp_table_q4_16.hex"),
    .RECIP_INIT_FILE("lut/recip_lut.hex")
) u_softmax (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .num_tokens(32'd2048),  // Must be multiple of 8
    .done(done),
    .s_axis_tdata(logits_data),
    .s_axis_tvalid(logits_valid),
    .s_axis_tlast(logits_last),
    .s_axis_tready(logits_ready),
    .m_axis_tdata(probs_data),
    .m_axis_tvalid(probs_valid),
    .m_axis_tlast(probs_last),
    .m_axis_tready(probs_ready)
);
```

## Resource Estimation

| Resource | Estimated Usage | Notes |
|----------|-----------------|-------|
| LUTs | ~500-800 | FSM, datapath, control |
| FFs | ~400-600 | Pipeline registers, counters |
| BRAMs | 2-3 | exp_rom (8×256×20) + FIFO + recip_lut |
| DSPs | 8 | Multipliers in normalization (1 per lane) |

## Design Considerations

### Numerical Stability

Unlike traditional softmax that subtracts max(x) for stability, this implementation:
- Uses saturating arithmetic at output stage
- Exp LUT handles the full INT8 range directly
- Output clamps to [0, 255] (UINT8)

### Throughput

- **Input:** 8 elements per cycle (64 bits / 8 bits)
- **Output:** 8 elements per cycle
- **Latency:** 2× (N/8) cycles for N tokens (two passes)

### Supported Token Counts

- Minimum: 8 (one beat)
- Maximum: 2048 (256 × 8, limited by FIFO_DEPTH)
- Requirement: Must be multiple of 8

## LUT Generation

The `lut/lut_generator.py` script generates the lookup tables:

```bash
cd fpga/rtl/softmax/lut
python lut_generator.py
```

This produces:
- `exp_table_q4_16.hex` - 256-entry exp(x) table
- `recip_lut.hex` - 64-entry 1/x approximation table

## Testing Methodology

The softmax unit is verified using a comprehensive Verilog testbench located at `fpga/tb/softmax/tb_softmax_unit.v`.

### Test Structure

```
fpga/
├── tb/softmax/
│   └── tb_softmax_unit.v          # Main testbench
└── sim/
    └── Makefile                    # Simulation runner (QuestaSim)
```

### Running Tests

```bash
cd fpga/sim
make clean && make all
```

### Test Cases

The testbench includes **8 distribution tests** plus **corner case tests**:

| Test | Distribution Type | Input Pattern | Expected Behavior |
|------|-------------------|---------------|-------------------|
| 1 | **Normal** | [12, 5, -3, 8, -7, 3, 10, 0] | Token 0 dominates (~89%) |
| 2 | **One-Hot** | [-10, -10, -10, 50, -10, -10, -10, -10] | Token 3 gets 100% (255) |
| 3 | **Two Competing** | [-10, 30, -10, 30, -10, -10, -10, -10] | Tokens 1,3 split 50/50 (128 each) |
| 4 | **All Same** | [10, 10, 10, 10, 10, 10, 10, 10] | Uniform 12.5% each (32) |
| 5 | **All Negative** | [-5, -10, -15, -3, -20, -8, -12, -7] | Max-subtraction handles correctly |
| 6 | **Bimodal** | [-20, -25, -22, -18, 20, 25, 22, 18] | High group dominates |
| 7 | **High Variance** | [-100, 50, -80, 30, -60, 10, -40, 70] | Largest value dominates |
| 8 | **Low Variance** | [0, 1, 2, 3, 1, 0, 2, 1] | Smooth distribution |
| 9 | **Corner Cases** | Various edge cases | Boundary conditions |

### Verification Approach

1. **Golden Model Comparison**: Each test computes expected output using a software model with the same max-subtraction algorithm
2. **Tolerance Check**: Allows ±1 difference for fixed-point approximation errors  
3. **X Value Detection**: Uses `$isunknown()` to detect and fail tests with undefined outputs
4. **AXI-Stream Protocol**: Verifies `tvalid`, `tready`, `tlast` handshaking

### Testbench Key Functions

| Function | Description |
|----------|-------------|
| `reset_dut()` | Applies reset and initializes all signals |
| `generate_test_vector()` | Creates random INT8 test inputs |
| `compute_expected_output()` | Software golden model with max-subtraction |
| `drive_input_stream()` | Sends test data via AXI-Stream slave interface |
| `monitor_output_stream()` | Captures output and compares against expected |
| `run_distribution_test()` | Runs a single 8-token distribution test |
| `run_corner_cases()` | Tests boundary conditions |

### Software Golden Model

The testbench implements the same algorithm as hardware for verification:

```verilog
// 1. Find global max
global_max = input_logits[0];
for (i = 1; i < num_tokens; i = i + 1)
    if (input_logits[i] > global_max) global_max = input_logits[i];

// 2. Compute exp(x - max) and sum
for (i = 0; i < num_tokens; i = i + 1) begin
    shifted = input_logits[i] - global_max;  // Always <= 0
    exp_val = exp_rom[shifted & 8'hFF];      // LUT lookup
    exp_sum = exp_sum + exp_val;
end

// 3. Normalize to UINT8
for (i = 0; i < num_tokens; i = i + 1)
    expected_output[i] = (exp_val[i] * 255) / exp_sum;
```
