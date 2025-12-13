# Setup paths
set script_dir       [file dirname [file normalize [info script]]]
set project_root     [file dirname $script_dir]
set rtl_dir          [file join $project_root "rtl"]
set constraints_dir  [file join $project_root "constraints"]
set build_dir        [file join $project_root "build"]

# Param
set_param general.maxThreads 8
set_msg_config -severity INFO -suppress 

# Create build directory
file mkdir $build_dir

# Design settings
set top_module      "gemm_core_top"
set fpga_part       "xc7z020clg400-1"
set constraint_file [file join $constraints_dir "gemm_core.xdc"]

# Reports
set synth_log       [file join $build_dir "synth.log"]
set impl_log        [file join $build_dir "impl.log"]
set timing_rpt      [file join $build_dir "${top_module}_post_route_timing.rpt"]
set fmax_report     [file join $build_dir "${top_module}_fmax_report.txt"]

# Source Files - GEMM Core
set rtl_files [list \
    "$rtl_dir/gemm/processing_element.v" \
    "$rtl_dir/gemm/systolic_array.v" \
    "$rtl_dir/gemm/input_buffer_controller.v" \
    "$rtl_dir/gemm/output_collector.v" \
    "$rtl_dir/gemm/gemm_core_top.v" \
]

# Read Sources
foreach f $rtl_files {
    if {![file exists $f]} {
        error "File not found: $f"
    }
    read_verilog $f
}

# Include directory for `riscv_defines.vh` etc.
set_property include_dirs [file join $rtl_dir "defines"] [current_fileset]

# Read Constraints
read_xdc $constraint_file

# Synthesis (Out-of-Context mode for IP/module timing analysis)
puts "Starting Synthesis (Out-of-Context)..."
synth_design -top $top_module -part $fpga_part -mode out_of_context
write_checkpoint -force [file join $build_dir "post_synth.dcp"]
report_timing_summary -file [file join $build_dir "post_synth_timing.rpt"]

# Implementation
puts "Starting Implementation..."
opt_design
place_design
phys_opt_design -directive AggressiveExplore
route_design
# Run an additional phys_opt after routing (post-route physopt switch not available in this Vivado)
phys_opt_design -directive AggressiveExplore

write_checkpoint -force [file join $build_dir "post_route.dcp"]
report_timing_summary -file $timing_rpt

# Calculate Fmax from Worst Negative Slack (WNS)
set worst_path_ops [get_timing_paths -setup -nworst 1]

if {[llength $worst_path_ops] == 0} {
    puts "No timing paths found!"
    set wns 0
    set clk_period 8.0
} else {
    set worst_path [lindex $worst_path_ops 0]
    set wns [get_property SLACK $worst_path]
    # Use the known clock name from XDC
    set clk_period [get_property PERIOD [get_clocks aclk]]
}

# Calculate Fmax
# Effective Period = Constraint_Period - WNS
set effective_period [expr $clk_period - $wns]
set fmax_mhz [expr 1000.0 / $effective_period]

puts "----------------------------------------------------------------"
puts " Timing Report Summary"
puts "----------------------------------------------------------------"
puts [format " Clock Period:        %.3f ns" $clk_period]
puts [format " Worst Negative Slack: %.3f ns" $wns]
puts [format " Effective Min Period: %.3f ns" $effective_period]
puts [format " Estimated Fmax:       %.2f MHz" $fmax_mhz]
puts "----------------------------------------------------------------"

# Write Fmax to file
set fp [open $fmax_report "w"]
puts $fp [format "Fmax: %.2f MHz" $fmax_mhz]
puts $fp [format "WNS:  %.3f ns" $wns]
close $fp

# Detailed Timing Reports (Setup & Hold) matching Vivado IDE format
puts "Generating Detailed Setup Report..."
report_timing -delay_type max -max_paths 10 -nworst 1 \
    -sort_by group \
    -input_pins \
    -path_type full_clock_expanded \
    -file [file join $build_dir "post_route_setup.rpt"]

puts "Generating Detailed Hold Report..."
report_timing -delay_type min -max_paths 10 -nworst 1 \
    -sort_by group \
    -input_pins \
    -path_type full_clock_expanded \
    -file [file join $build_dir "post_route_hold.rpt"]

puts "Detailed timing reports generated in $build_dir"
