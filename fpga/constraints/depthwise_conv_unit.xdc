## Out-of-Context timing constraints for depthwise_conv_unit standalone timing analysis
## Target: Arty Z7-20 (xc7z020clg400-1)
## Mode: Out-of-Context (OOC) - no physical pin constraints
##
## This is directly analogous to softmax_unit.xdc for consistent timing methodology.

## Clock constraint - 200 MHz (5ns period) target
create_clock -period 5.000 -name clk -waveform {0.000 2.500} [get_ports clk]

## Asynchronous reset - treat rst_n as asynchronous
set_false_path -from [get_ports rst_n]

## Set input/output delays relative to clock for proper timing analysis
## These are virtual delays for internal timing path analysis
## (Do not set IOSTANDARD for OOC synthesis - causes IO count issues)
