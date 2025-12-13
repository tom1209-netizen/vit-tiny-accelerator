# Softmax Unit Documentation

This document describes the hardware softmax implementation located under `fpga/rtl/softmax`. It covers the algorithm design, fixed-point representation, I/O interfaces, internal pipeline, and resource usage.

## Where This Sits In TinyViT

In TinyViT window attention, softmax is applied over the **key dimension** for each query:

- Stage 1 & 3 window: `7×7 = 49` tokens (per head, per query row)
- Stage 2 window: `14×14 = 196` tokens (per head, per query row)

In hardware, `softmax_unit` is invoked **per query-row** of the attention-score matrix (e.g. for a `49×49` score tile, it runs 49 times). Because the datapath is `8 lanes/beat`, query rows are padded to a multiple of 8 tokens:

- 49 → 56 tokens (7 beats)
- 196 → 200 tokens (25 beats)

Padding tokens represent “masked” keys and should be driven with a low logit so their probability is ~0.

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

High-level datapath (one “transaction” = one softmax vector):

> [!NOTE]
> I will add later

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

## Interfaces (Ports)

### Control

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `start` | in | 1 | Pulse in `S_IDLE` to begin a new softmax transaction (also clears FIFOs). |
| `num_tokens` | in | 32 | Number of tokens in this softmax vector (must be multiple of 8 in current flow). |
| `done` | out | 1 | Pulses when the final output beat is accepted. |

### AXI4-Stream Input (`s_axis_*`)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `s_axis_tdata` | in | `AXIS_DATA_WIDTH` | Packed INT8 logits, `LANES = AXIS_DATA_WIDTH/DATA_WIDTH` lanes (default 8). Lane `i` is `s_axis_tdata[i*DATA_WIDTH +: DATA_WIDTH]`. |
| `s_axis_tvalid` | in | 1 | Input valid. |
| `s_axis_tready` | out | 1 | Input ready (asserted only in `S_FIND_MAX` while accepting beats). |
| `s_axis_tlast` | in | 1 | Present for AXI compliance; not used for control (the design uses `num_tokens`). |

### AXI4-Stream Output (`m_axis_*`)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `m_axis_tdata` | out | `AXIS_DATA_WIDTH` | Packed UINT8 probabilities (0..255), `LANES = AXIS_DATA_WIDTH/DATA_WIDTH` lanes (default 8). Lane `i` is `m_axis_tdata[i*DATA_WIDTH +: DATA_WIDTH]`. |
| `m_axis_tvalid` | out | 1 | Output valid. |
| `m_axis_tready` | in | 1 | Output ready (backpressure supported). |
| `m_axis_tlast` | out | 1 | Asserted on the final output beat for this transaction. |

## State Machine

The softmax unit implements a **5-state FSM** with max-subtraction:

| State | Duration | Description |
|-------|----------|-------------|
| `S_IDLE` | - | Wait for `start` pulse |
| `S_FIND_MAX` | N/8 cycles | Accept inputs, find max, buffer to input_fifo |
| `S_ACCUMULATE` | N/8 cycles | Read input_fifo, compute exp(x-max), accumulate |
| `S_CALC_RECIP` | 1 cycle | MSR computes reciprocal approximation |
| `S_NORMALIZE` | N/8 cycles | Pop exp_fifo, multiply, output results |

### Transaction Rules

- `start` is sampled in `S_IDLE`; a `start` pulse clears internal FIFOs and begins a new softmax transaction.
- `num_tokens` defines the vector length; the current RTL assumes **beat-aligned** token counts (multiple of 8). In the accelerator flow, attention rows are padded accordingly (49→56, 196→200).
- `s_axis_tlast` is not used for control; completion is determined from `num_tokens`.
- `done` asserts when the **final output beat** is accepted (`m_axis_tvalid && m_axis_tready && m_axis_tlast`).

### Per-State Behavior (Detailed)

- `S_IDLE`: clears counters/flags; waits for `start`.
- `S_FIND_MAX`: accepts `LANES` logits per beat, updates `global_max` (max-reduction tree), and writes each beat into `input_fifo`.
- `S_ACCUMULATE`: reads beats back from `input_fifo`, computes `exp(x - global_max)` via `exp_rom`, accumulates `global_sum`, and writes the per-lane exp values into `exp_fifo` for the final pass.
- `S_CALC_RECIP`: computes `msr_mult_r` and `msr_shift_r` from `global_sum` using `msr_unit`.
- `S_NORMALIZE`: pops `exp_fifo` only when the output register is free (backpressure-safe), computes `(exp * msr_mult_r) >> msr_shift_r >> 7`, saturates to `8'hFF`, and streams results to `m_axis_*` with `m_axis_tlast` on the final beat.

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
Range: 0.0 to 15.9999... (more than enough since exp(x-max) is in [0, 1])
```

**Important:** in `softmax_unit`, the ROM is addressed with the **max-subtracted** value `(x - global_max)`, so the intended operating region is `<= 0` (exp outputs in `[0, 1]`).

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

The output scale is **0..255**, representing an approximate probability (`p ≈ out/255`).

## Fixed-Point Number Formats

| Value | Format | Bits | Range |
|-------|--------|------|-------|
| Input logit | INT8 | 8 | -128 to +127 |
| exp(logit) | Q4.16 | 20 | 0.0 to ~15.99 |
| global_sum | Q?.16 (sum of Q4.16) | 32 | Depends on token count |
| Reciprocal | Q1.15 | 16 | 0.0 to ~1.99 |
| Product | Q5.31 | 36 | exp × recip |
| Output | UINT8 | 8 | 0 to 255 (0.0 to 1.0) |

For TinyViT attention rows, `exp(x-max) ≤ 1`, so `Σ exp ≤ num_tokens`. With `num_tokens ≤ 2048`, `global_sum` fits comfortably in 32 bits.

## Pipeline Latency

| Phase | Latency (cycles) | Notes |
|-------|------------------|-------|
| Input to exp_out | 1 | ROM read latency |
| FIFO read to exp_out valid | 2 | input_fifo capture + ROM latency |
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

This design implements the standard stability trick `x := x - max(x)` before exp.

**Note on dynamic range:** the subtract `(x - global_max)` is currently done in `DATA_WIDTH` (8-bit signed). If inputs span a very wide range (e.g. `global_max≈127`, `x≈-128`), the 8-bit subtract can wrap. In the intended accelerator flow, attention logits are requantized into a small INT8 range and padding logits are chosen so the subtract remains in-range.

### Throughput

- **Input:** 8 elements per cycle (64 bits / 8 bits)
- **Output:** 8 elements per cycle
- **Latency:** 2× (N/8) cycles for N tokens (two passes)

### Supported Token Counts

- Minimum: 8 (one beat)
- Maximum: 2048 (256 × 8, limited by FIFO_DEPTH)
- Requirement: Must be multiple of 8

## Timing Optimization

This section documents the timing analysis methodology and optimizations applied to achieve higher Fmax targets.

### Timing Analysis Methodology

The softmax unit uses **Out-of-Context (OOC)** synthesis for timing analysis, consistent with the GEMM core methodology. This enables accurate internal timing characterization without I/O routing constraints.

**Key Files:**

| File | Purpose |
|------|---------|
| `constraints/softmax_unit.xdc` | OOC timing constraints (200MHz target) |
| `scripts/run_timing_softmax.tcl` | Vivado batch timing script |

**Running Timing Analysis:**

```bash
cd fpga
vivado -mode batch -source scripts/run_timing_softmax.tcl
# Results written to build/softmax_post_route_fmax.txt
```

**Fmax Calculation:**

```
Effective Period = Clock Period - WNS (Worst Negative Slack)
Fmax = 1000 / Effective Period  (in MHz)
```

### Optimization 1: Pipelined Max-Finding Tree

**Problem:** The original 8-way max reduction tree created a long combinational path from input to `beat_max_r` register with 10 logic levels (4 CARRY4 + 6 LUTs), resulting in a data path delay of ~7.8ns.

**Original Critical Path:**
```
s_axis_tdata → lane unpack → max_01/23/45/67 → max_0123/4567 → beat_max → beat_max_r
                              (8→4 compare)     (4→2 compare)  (2→1 compare)
```

**Solution:** Split the tree into a 2-stage pipeline with intermediate registers after the 8→4 reduction.

**Pipelined Implementation:**

```verilog
// Stage 1: 8 → 4 reduction (combinational)
wire signed [DATA_WIDTH-1:0] max_01 = (lane_in[0] > lane_in[1]) ? lane_in[0] : lane_in[1];
wire signed [DATA_WIDTH-1:0] max_23 = (lane_in[2] > lane_in[3]) ? lane_in[2] : lane_in[3];
wire signed [DATA_WIDTH-1:0] max_45 = (lane_in[4] > lane_in[5]) ? lane_in[4] : lane_in[5];
wire signed [DATA_WIDTH-1:0] max_67 = (lane_in[6] > lane_in[7]) ? lane_in[6] : lane_in[7];

// Pipeline registers for Stage 1 results
reg signed [DATA_WIDTH-1:0] max_01_r, max_23_r, max_45_r, max_67_r;
reg max_stage1_valid;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        max_01_r <= 0; max_23_r <= 0; max_45_r <= 0; max_67_r <= 0;
        max_stage1_valid <= 1'b0;
    end else if (accept_axi_input) begin
        max_01_r <= max_01; max_23_r <= max_23;
        max_45_r <= max_45; max_67_r <= max_67;
        max_stage1_valid <= 1'b1;
    end else begin
        max_stage1_valid <= 1'b0;
    end
end

// Stage 2: 4 → 1 reduction (from registered values)
wire signed [DATA_WIDTH-1:0] max_0123 = (max_01_r > max_23_r) ? max_01_r : max_23_r;
wire signed [DATA_WIDTH-1:0] max_4567 = (max_45_r > max_67_r) ? max_45_r : max_67_r;
wire signed [DATA_WIDTH-1:0] beat_max = (max_0123 > max_4567) ? max_0123 : max_4567;
```

**State Machine Update:**

The S_FIND_MAX→S_ACCUMULATE transition now waits for the pipeline to drain:

```verilog
S_FIND_MAX: begin
    // Wait for pipeline to drain before transitioning
    if (tokens_accepted >= num_tokens && !max_stage1_valid && !beat_max_valid)
        next_state = S_ACCUMULATE;
end
```

**Results:**

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| WNS | -2.898 ns | -2.142 ns | +0.756 ns |
| Fmax | 126.61 MHz | 140.02 MHz | +13.4 MHz |
| Latency | N/8 cycles | N/8 + 1 cycle | +1 cycle |

**Trade-off:** The optimization adds 1 extra cycle to the S_FIND_MAX phase.

### Remaining Critical Paths

After the max tree optimization, two other paths limit further Fmax improvement:

**1. ExpFIFO → DSP48 Path** (-2.142 ns worst)

```
u_exp_fifo/rptr_reg → RAMD64E (distributed RAM) → LUT6 mux → DSP48E1/A[]
```

- Root cause: Distributed RAM has combinational read output
- DSP48 A-port has ~3.7ns setup time, leaving only ~1.3ns for FIFO + routing
- **Potential fix:** Enable DSP input registers (AREG/BREG) or convert FIFO to BRAM

**2. global_sum → msr_mult_r Path** (-2.138 ns)

```
global_sum_reg → priority encoder (LUT chain) → LUT lookup → msr_mult_r_reg
```

- Root cause: `msr_unit.v` priority encoder is fully combinational (32-bit scan)
- 8 logic levels through LUT chain
- **Potential fix:** Pipeline the MSR unit into 2 stages

### Future Optimization Options

| Option | Description | Latency Impact | Expected Gain |
|--------|-------------|----------------|---------------|
| **DSP Registers** | Enable AREG/BREG on DSP48 multipliers | +1 cycle in S_NORMALIZE | ~2 ns |
| **Pipeline MSR** | Split priority encoder + LUT lookup | +1 cycle in transition | ~2 ns |
| **BRAM FIFOs** | Convert distributed RAM to BRAM | Minimal (implicit register) | ~0.5-1 ns |

Combined, these could push Fmax to ~200MHz with +2-3 cycles total latency increase.

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
make -C fpga/sim clean build run TB_NAME=tb_softmax_unit
```

### Test Cases

The testbench exercises both:

- **Single-beat correctness** (8-token vectors) with hand-computable distributions.
- **TinyViT-realistic attention rows** (49/196 valid tokens padded to 56/200) with patterns that mimic relative-position bias and sparsity.

All expected outputs are computed by a **hardware-matching golden model** inside the testbench using the *same LUT files* (`$readmemh`).

#### A. 8-token distribution tests (1 beat)

| Test | Distribution Type | Input Pattern | Expected Behavior |
|------|-------------------|---------------|-------------------|
| 1 | **Normal** | [12, 5, -3, 8, -7, 3, 10, 0] | Token 0 dominates (~89%) |
| 2 | **One-Hot** | [-10, -10, -10, 50, -10, -10, -10, -10] | Token 3 gets 100% (255) |
| 3 | **Two Competing** | [-10, 30, -10, 30, -10, -10, -10, -10] | Tokens 1,3 split 50/50 (128 each) |
| 4 | **All Same** | [10, 10, 10, 10, 10, 10, 10, 10] | Uniform 12.5% each (32) |
| 5 | **All Negative** | [-5, -10, -15, -3, -20, -8, -12, -7] | Max-subtraction handles correctly |
| 6 | **Bimodal** | [-20, -25, -22, -18, 20, 25, 22, 18] | High group dominates |
| 7 | **High Variance** | [-60, 50, -40, 30, -20, 10, 0, 60] | Largest value dominates |
| 8 | **Low Variance** | [0, 1, 2, 3, 1, 0, 2, 1] | Smooth distribution |

#### B. Corner-case smoke tests

These are quick “doesn’t hang” checks (not full golden comparisons):

- Single token transaction (exercise `start`/FSM behavior)
- All-zero logits (flat distribution)
- Max-ish logits (saturation/path sanity)

#### C. TinyViT window-size attention tests (IDs 9–16)

These run the softmax on **padded attention rows**:

- `Stage 1/3`: 49 valid tokens padded to 56
- `Stage 2`: 196 valid tokens padded to 200

Each test samples **three query rows** (`query_idx` = 0, mid, last) to mimic per-query invocation.

| Test ID | Window | `num_tokens` | Valid | Pattern |
|---------|--------|--------------|-------|---------|
| 9 | 7×7 (Stage 1/3) | 56 | 49 | Self-focus |
| 10 | 7×7 (Stage 1/3) | 56 | 49 | Local attention |
| 11 | 7×7 (Stage 1/3) | 56 | 49 | Sparse peak |
| 12 | 7×7 (Stage 1/3) | 56 | 49 | Uniform |
| 13 | 14×14 (Stage 2) | 200 | 196 | Self-focus |
| 14 | 14×14 (Stage 2) | 200 | 196 | Local attention |
| 15 | 14×14 (Stage 2) | 200 | 196 | Sparse peak |
| 16 | 14×14 (Stage 2) | 200 | 196 | Uniform |

Pattern types:

- **Self-focus**: peak at the query’s own position, falloff with 2D distance
- **Local attention**: smooth distance falloff (relative-position bias-like)
- **Sparse peak**: one dominant key token + weak neighbors
- **Uniform**: all valid logits equal

#### D. Scaled distribution tests (IDs 17–19)

These repeat an 8-token base pattern across a full row (56 or 200 tokens) and pad the remainder with `PADDING_VALUE` to validate:

- correct accumulation over large `num_tokens`
- correct handling of padded lanes (probability near 0)
- stable behavior across beat boundaries

| Test ID | Description | `num_tokens` | Valid | Base pattern |
|---------|-------------|--------------|-------|--------------|
| 17 | One-hot @ Stage 1/3 | 56 | 49 | Test 2 |
| 18 | Bimodal @ Stage 2 | 200 | 196 | Test 6 |
| 19 | High variance @ Stage 1/3 | 56 | 49 | Test 7 |

### Verification Approach

1. **Golden Model Comparison**: Each test computes expected output using a software model with the same max-subtraction algorithm
2. **Tolerance Check**: Allows ±1 difference for fixed-point approximation errors  
3. **X/Z Detection**: Uses a portable reduction-XOR check (`^token === 1'bx`) to fail on unknown outputs
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
| `generate_vit_attention_pattern()` | Generates TinyViT-like attention score rows (2D window distance patterns + padding) |
| `run_vit_stage_test()` | Runs padded-window tests (56/200 tokens), sampling multiple query rows |
| `run_scaled_distribution_test()` | Scales 8-token patterns to 56/200 token rows + padding |

### Software Golden Model

The testbench matches the RTL datapath, including the LUT-based reciprocal approximation:

```verilog
// 1) Find global max
global_max = -128;
for (i = 0; i < num_tokens; i = i + 1)
  if ($signed(input_logits[i]) > global_max) global_max = $signed(input_logits[i]);

// 2) Compute sum of exp(x-max) using exp_rom LUT
fixed_sum = 0;
for (i = 0; i < num_tokens; i = i + 1) begin
  shifted = $signed(input_logits[i]) - global_max;
  idx = (shifted < 0) ? (shifted + 256) : shifted;
  fixed_exp[i] = exp_rom[idx];
  fixed_sum = fixed_sum + fixed_exp[i];
end

// 3) MSR reciprocal approximation (matches msr_unit)
shift_amount = leading_one_pos(fixed_sum) > 5 ? (leading_one_pos(fixed_sum) - 5) : 0;
lut_index = fixed_sum >> shift_amount;  // clamp to 0..63
recip_val = recip_lut[lut_index];

// 4) Normalize each exp to UINT8 (matches softmax_unit shift path)
for (i = 0; i < num_tokens; i = i + 1) begin
  prod = fixed_exp[i] * recip_val;
  scaled = (prod >> shift_amount) >> 7;
  expected_output[i] = (scaled > 255) ? 255 : scaled[7:0];
end
```
