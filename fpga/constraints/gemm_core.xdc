## Timing constraints for GEMM Core standalone timing analysis
## Targeting Arty Z7-20 (xc7z020clg400-1)
## Running in Out-of-Context (OOC) mode - no physical pin constraints

## Clock constraint - 200 MHz (5ns period) for high-frequency GEMM core
## GEMM core uses 'aclk' as clock port name (AXI convention)
create_clock -period 5.000 -name aclk -waveform {0.000 2.500} [get_ports aclk]

## Set all I/O as virtual (no physical pin assignments for timing-only analysis)
set_property IOSTANDARD LVCMOS33 [get_ports *]

## Asynchronous reset - treat aresetn as asynchronous
set_false_path -from [get_ports aresetn]

## Set input/output delays relative to clock for proper timing analysis
## These are virtual delays for internal timing path analysis
set_input_delay -clock aclk 1.0 [all_inputs]
set_output_delay -clock aclk 1.0 [all_outputs]
