# GEMM Core Documentation

This document describes the GEMM core located under `fpga/rtl/gemm`. It focuses on the tile-level AXI-Stream interfaces, the required wavefront-style input ordering, the produced output stream, and a high-level view of each RTL block.

## Block Purpose

`gemm_core_top` implements an `ARRAY_SIZE x ARRAY_SIZE` signed integer matrix multiplication (`C = A * B`) using a fully unrolled 2-D systolic array of processing elements (PEs). Each tile consumes the entirety of two matrices through AXI-Stream ports and emits the resulting matrix using another AXI-Stream port once the systolic pipeline finishes accumulating.

## Parameterization

- `DATA_WIDTH` – Bit width of `A`/`B` operands on each lane (8-bit signed by default).
- `ACC_WIDTH` – Bit width of the accumulators/outputs (32-bit signed by default).
- `ARRAY_SIZE` – Number of rows/columns (8, yielding a fixed 8x8 grid of PEs in the current RTL).
- `AXIS_DATA_WIDTH` – Bit width of each AXI-Stream beat (64 bits, matching 8 lanes × 8 bits).

These parameters are propagated to all submodules so the array can be resized as long as the stream width and lane packing are updated consistently.

## Control and Handshake Signals

- `aclk` / `aresetn` – Clock and active-low reset shared by all sub-blocks.
- `start_tile` – Pulse high for one cycle to clear accumulators and begin loading a new tile. Should only be asserted when no tile is active.
- `tile_done` – Pulses high when the output collector issues `TLAST` for the final beat of `C`.

The AXI-Stream ports use standard `TVALID/TREADY/TLAST` handshakes. The core is source-synchronous on transmit (`m_axis_out_*`) and sink-synchronous on receive (`s_axis_*`).

## Input Stream Requirements

Each AXI-Stream input beat is 64 bits and packs eight signed `DATA_WIDTH` values. Lane `i` (0 = LSB) corresponds to matrix row `i` for stream A and matrix column `i` for stream B. You must provide data in a wavefront/anti-diagonal schedule so that all rows/columns enter the systolic array in lock step.

### Wavefront Schedule

Let `cycle` be a zero-based counter that increments on every accepted beat. For an `ARRAY_SIZE` = 8 tile:

- **Stream A (rows propagated horizontally):**
  - Lane `i` carries `A[i][j]` where `j = cycle - i`.
  - If `j` falls outside `[0, ARRAY_SIZE-1]`, that lane must be padded with zero.
  - `TLAST` is asserted on the final cycle `cycle = 2*ARRAY_SIZE - 2`.

- **Stream B (columns propagated vertically):**
  - Lane `j` carries `B[i][j]` where `i = cycle - j`.
  - Lanes outside the current wavefront are zero padded.
  - `TLAST` matches stream A on the last cycle.

This pattern naturally walks the anti-diagonals of each matrix. A full `ARRAY_SIZE x ARRAY_SIZE` tile therefore requires exactly `2*ARRAY_SIZE - 1` beats per stream (15 beats for the default 8x8 design). The test bench `fpga/tb/gemm/tb_gemm_core_top.v` shows how to build each beat programmatically.

### Backpressure Behavior

Each stream feeds an `input_buffer_controller` that contains a one-beat skid buffer. The controller only asserts `TREADY` when the tile is enabled and the buffer can accept data. Once a beat is accepted, the controller presents the 8 unpacked lanes (`data_out_[0..7]`) simultaneously to the systolic array, asserting `data_valid` for that cycle. Because A lanes drive rows and B lanes drive columns, both `data_valid` pulses must align for the PEs to perform MAC operations.

## Output Stream Behavior

Outputs are produced right after the systolic pipeline is empty. Once both A and B streams have observed `TLAST`, the core simply waits until the array reports that no multiply-accumulate activity is in flight (`array_active = 0`) and then releases the output collector. This removes the old fixed `FLUSH_LATENCY` guard band and immediately starts draining the tile as soon as the bottom-right PE finishes its final accumulation.

The output collector scans the accumulated matrix `C` in row-major order and packs `VALUES_PER_BEAT = AXIS_DATA_WIDTH / ACC_WIDTH` results per beat (2 × 32-bit values for the default configuration):

- `m_axis_tdata[31:0]` carries `C[row][col]`.
- `m_axis_tdata[63:32]` carries `C[row][col+1]`, zero padded when the row has an odd number of elements.
- The collector advances `col` by 2 each handshake, wrapping to the next row when the row is exhausted.
- `TLAST` is asserted on the beat containing the last valid result (row = `ARRAY_SIZE-1`, `col >= ARRAY_SIZE-VALUES_PER_BEAT`).

`tile_done` reflects the final `TLAST`, enabling the host to latch the completion of the tile.

## Internal Block Overview

### 1. `input_buffer_controller`

- Provides the ready/valid handshake for both `s_axis_a` and `s_axis_b`.
- Captures each 64-bit beat into a holding register, unpacks it into eight signed `DATA_WIDTH` lanes, and asserts `data_valid` for exactly one cycle per beat.
- Acts as a timing-decoupling stage so AXI arrival jitter does not disturb the systolic array.

### 2. `processing_element`

- Each PE performs `acc_out <= acc_out + (a_in * b_in)` whenever both inputs are valid.
- `a_in` propagates to the right each cycle, `b_in` propagates downward, so every value participates in multiple MACs.
- `clear_acc` synchronous reset is driven by `start_tile` to zero all accumulators between tiles.

### 3. `systolic_array`

- 8×8 grid created with Verilog `generate` loops.
- Internal wiring arrays route `a` horizontally and `b` vertically, maintaining valid bits alongside data.
- Exposes all 64 accumulator taps (`acc_out_r_c`) so the collector can read them without additional buffering.
- Raises `array_active` whenever any PE sees valid A and B operands simultaneously, which lets the top level know exactly when the pipeline is empty.

### 4. Tile Control Logic (inside `gemm_core_top`)

- Monitors `TLAST` on both input streams (`a_last_handshake`, `b_last_handshake`).
- Arms an output-start request once both matrices are fully received and immediately fires a one-cycle `start_output` pulse when `array_active` drops to zero.
- Tracks whether output has started so that a new `start_tile` resets the finite-state machine cleanly.

### 5. `output_collector`

- Uses a simple FSM with `(row_idx, col_idx)` pointers and a helper function to address the flattened accumulator wires.
- Issues AXI beats whenever idle or the previous beat has been accepted. `m_axis_tvalid` remains deasserted during idle/flush periods.
- Drives `done` high alongside the final `TLAST`.

## Example Tile Sequence

1. Assert `start_tile` for one `aclk` cycle while both input streams are idle.
2. Beginning the next cycle, start driving the wavefront-formatted A and B streams. Keep `TVALID` asserted while data is available and monitor `TREADY` for backpressure.
3. Assert `TLAST` together on the final wavefront beat (`cycle = 2*ARRAY_SIZE - 2`).
4. After both `TLAST`s are acknowledged, the core watches `array_active` and fires the output collector as soon as the systolic wave has drained—typically ~`2*(ARRAY_SIZE-1)` cycles later.
5. Monitor `m_axis_out_tvalid`. Once asserted, accept every beat until `TLAST`. Each beat contains two 32-bit row-major results.
6. When `tile_done` pulses, the tile is complete and the core is ready for another `start_tile` once outputs have been consumed.

## Verification References

- `fpga/tb/gemm/tb_gemm_core_top.v` demonstrates the wavefront generator, handshake behavior, and end-to-end result checking for an 8×8 tile.
- Additional targeted benches (`fpga/tb/gemm/tb_input_buffer_controller.v`, etc.) can be used to understand individual modules in isolation.
