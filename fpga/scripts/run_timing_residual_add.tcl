# =============================================================================
# Residual Add Unit - Out-of-Context Timing Analysis Script
# Target: Arty Z7-20 (xc7z020clg400-1) @ 200 MHz
# =============================================================================

set script_dir      [file dirname [file normalize [info script]]]
set fpga_dir        [file normalize [file join $script_dir ".."]]
set rtl_dir         [file join $fpga_dir "rtl"]
set constraints_dir [file join $fpga_dir "constraints"]
set build_dir       [file join $fpga_dir "build"]

set_param general.maxThreads 8
set_msg_config -severity INFO -suppress

file mkdir $build_dir

# Direct OOC synthesis on residual_add (no wrapper needed)
set top_module      "residual_add"
set fpga_part       "xc7z020clg400-1"
set constraint_file [file join $constraints_dir "residual_add.xdc"]
set clock_name      "clk"

# Report output files
set synth_dcp       [file join $build_dir "residual_add_post_synth.dcp"]
set impl_dcp        [file join $build_dir "residual_add_post_route.dcp"]
set post_synth_rpt  [file join $build_dir "residual_add_post_synth_timing.rpt"]
set post_route_sum  [file join $build_dir "residual_add_post_route_timing_summary.rpt"]
set post_route_set  [file join $build_dir "residual_add_post_route_setup.rpt"]
set post_route_hold [file join $build_dir "residual_add_post_route_hold.rpt"]
set util_rpt        [file join $build_dir "residual_add_post_route_util.rpt"]
set fmax_report     [file join $build_dir "residual_add_post_route_fmax.txt"]

# RTL source files
set rtl_files [list \
    [file join $rtl_dir "residual" "residual_add.v"] \
]

foreach rtl_file $rtl_files {
    if {![file exists $rtl_file]} {
        error "Missing RTL source: $rtl_file"
    }
    read_verilog $rtl_file
}

if {![file exists $constraint_file]} {
    error "Missing constraint file: $constraint_file"
}
read_xdc $constraint_file

# =============================================================================
# Synthesis (Out-of-Context mode)
# =============================================================================
puts "Starting synthesis (Out-of-Context) for $top_module..."
synth_design -top $top_module -part $fpga_part -mode out_of_context
write_checkpoint -force $synth_dcp
report_timing_summary -file $post_synth_rpt

# =============================================================================
# Implementation
# =============================================================================
puts "Starting implementation for $top_module..."
opt_design
place_design
phys_opt_design -directive AggressiveExplore
route_design
phys_opt_design -directive AggressiveExplore
write_checkpoint -force $impl_dcp

# =============================================================================
# Reports
# =============================================================================
report_utilization -file $util_rpt
report_timing_summary -file $post_route_sum

puts "Generating detailed timing reports..."
report_timing -delay_type max -max_paths 10 -nworst 1 \
    -sort_by group \
    -input_pins \
    -path_type full_clock_expanded \
    -file $post_route_set

report_timing -delay_type min -max_paths 10 -nworst 1 \
    -sort_by group \
    -input_pins \
    -path_type full_clock_expanded \
    -file $post_route_hold

# =============================================================================
# Fmax Calculation
# =============================================================================
set worst_path_ops [get_timing_paths -setup -nworst 1]

if {[llength $worst_path_ops] == 0} {
    puts "WARNING: No timing paths found!"
    set wns 0
    set clk_period 5.0
} else {
    set worst_path [lindex $worst_path_ops 0]
    set wns [get_property SLACK $worst_path]
    set clk_period [get_property PERIOD [get_clocks $clock_name]]
}

set effective_period [expr {$clk_period - $wns}]
set fmax_mhz [expr {1000.0 / $effective_period}]

# Write Fmax report
set fp [open $fmax_report "w"]
puts $fp "================================================================"
puts $fp " Residual Add Timing Analysis (Out-of-Context)"
puts $fp "================================================================"
puts $fp [format "Clock:               %s" $clock_name]
puts $fp [format "Target Clock Period: %.3f ns (%.1f MHz)" $clk_period [expr {1000.0 / $clk_period}]]
puts $fp [format "WNS (Setup):         %.3f ns" $wns]
puts $fp [format "Effective Min Period: %.3f ns" $effective_period]
puts $fp [format "Estimated Fmax:      %.2f MHz" $fmax_mhz]
puts $fp "================================================================"
if {$wns < 0} {
    puts $fp "STATUS: TIMING VIOLATED - Design does not meet target frequency"
} else {
    puts $fp "STATUS: TIMING MET - Design meets target frequency"
}
close $fp

# Console output
puts "================================================================"
puts " TIMING ANALYSIS RESULTS"
puts "================================================================"
puts [format " Target:              %.1f MHz (%.3f ns)" [expr {1000.0 / $clk_period}] $clk_period]
puts [format " WNS (Setup Slack):   %.3f ns" $wns]
puts [format " Effective Period:    %.3f ns" $effective_period]
puts [format " Estimated Fmax:      %.2f MHz" $fmax_mhz]
puts "================================================================"
if {$wns < 0} {
    puts " STATUS: TIMING VIOLATED"
} else {
    puts " STATUS: TIMING MET"
}
puts ""
puts "Reports written to: $build_dir"
