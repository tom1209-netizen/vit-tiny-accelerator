# ==============================================================================
# Vivado Simulation Script for GEMM Core
# 
# Uses xsim with UNISIM library for accurate DSP48E1 simulation
# Run with: make xsim (from fpga/scripts directory)
# ==============================================================================

# Configuration
set project_name "gemm_xsim"
set top_module "tb_gemm_core_top"
set rtl_dir "../rtl"
set tb_dir "../tb/gemm"
set build_dir "../build/xsim"

# FPGA Part (for correct primitive behavior)
set part "xc7z020clg400-1"

# Clean and create build directory
file delete -force $build_dir
file mkdir $build_dir

# Create project on disk (required for simulation)
create_project $project_name $build_dir -part $part -force

# Add RTL source files
add_files -fileset sim_1 [glob -nocomplain $rtl_dir/gemm/*.v]

# Add testbench files
add_files -fileset sim_1 [glob -nocomplain $tb_dir/*.v]

# Set top module for simulation
set_property top $top_module [get_filesets sim_1]

# Update compile order
update_compile_order -fileset sim_1

# Set simulation runtime
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

# Launch simulation
puts "=========================================="
puts " Launching Vivado Simulation (xsim)"
puts " Top Module: $top_module"
puts " Part: $part"
puts " Using Xilinx UNISIM Library"
puts "=========================================="

# Run behavioral simulation
launch_simulation -mode behavioral

# Run the simulation (already set to run all)
# run all

# Report results
puts ""
puts "=========================================="
puts " Simulation Complete"
puts "=========================================="

# Close simulation and project
close_sim
close_project

# Exit Vivado
quit

