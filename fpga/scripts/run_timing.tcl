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
set top_module      "riscv_core"
set fpga_part       "xc7z020clg400-1"
set constraint_file [file join $constraints_dir "arty_z7.xdc"]

# Reports
set synth_log       [file join $build_dir "synth.log"]
set impl_log        [file join $build_dir "impl.log"]
set timing_rpt      [file join $build_dir "post_route_timing.rpt"]
set fmax_report     [file join $build_dir "fmax_report.txt"]

# Source Files
set rtl_files [list \
    "$rtl_dir/cpu_core/if/pc_reg.v" \
    "$rtl_dir/cpu_core/if/if_stage.v" \
    "$rtl_dir/cpu_core/if/if_id_reg.v" \
    "$rtl_dir/cpu_core/id/imm_gen.v" \
    "$rtl_dir/cpu_core/id/control.v" \
    "$rtl_dir/cpu_core/id/reg_file.v" \
    "$rtl_dir/cpu_core/id/id_ex_reg.v" \
    "$rtl_dir/cpu_core/id/id_stage.v" \
    "$rtl_dir/cpu_core/ex/divider_16stage.v" \
    "$rtl_dir/cpu_core/ex/divu_iter.v" \
    "$rtl_dir/cpu_core/ex/mul_div.v" \
    "$rtl_dir/cpu_core/ex/kogge_stone_adder.v" \
    "$rtl_dir/cpu_core/ex/alu.v" \
    "$rtl_dir/cpu_core/ex/scoreboard.v" \
    "$rtl_dir/cpu_core/ex/ex_mem_reg.v" \
    "$rtl_dir/cpu_core/ex/ex_stage.v" \
    "$rtl_dir/cpu_core/mem/mem_stage.v" \
    "$rtl_dir/cpu_core/mem/mem_wb_reg.v" \
    "$rtl_dir/cpu_core/wb/wb_stage.v" \
    "$rtl_dir/memory/instr_mem.v" \
    "$rtl_dir/memory/data_mem.v" \
    "$rtl_dir/csr_file.v" \
    "$rtl_dir/hazard_unit.v" \
    "$rtl_dir/riscv_core.v" \
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

# Synthesis
puts "Starting Synthesis..."
synth_design -top $top_module -part $fpga_part
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
    set clk_period [get_property PERIOD [get_clocks sys_clk_pin]]
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
