# derive project-relative directories from this script location
set script_dir       [file dirname [file normalize [info script]]]
set fpga_dir         [file normalize [file join $script_dir ".."]]
set project_root     [file normalize [file join $fpga_dir ".."]]
set rtl_dir          [file join $fpga_dir "rtl"]
set constraints_dir  [file join $fpga_dir "constraints"]
set build_dir        [file join $fpga_dir "build"]

file mkdir $build_dir

# Design / board settings
set top_module      "softmax_unit"
set fpga_part       "xc7z020clg400-1"
set constraint_file [file join $constraints_dir "arty_z7.xdc"]

set synth_dcp       [file join $build_dir "${top_module}_synth.dcp"]
set timing_rpt      [file join $build_dir "${top_module}_synth_timing.rpt"]
set datasheet_rpt   [file join $build_dir "${top_module}_datasheet_timing.rpt"]
set fmax_report     [file join $build_dir "${top_module}_fmax.txt"]

# RTL sources in dependency-friendly order
set rtl_files [list \
    [file join $rtl_dir "softmax" "exp_rom.v"] \
    [file join $rtl_dir "softmax" "msr_unit.v"] \
    [file join $rtl_dir "softmax" "softmax_fifo.v"] \
    [file join $rtl_dir "softmax" "softmax_unit.v"] \
]

# Read RTL
foreach rtl_file $rtl_files {
    if {![file exists $rtl_file]} {
        error "Missing RTL source: $rtl_file"
    }
    read_verilog $rtl_file
}

# Read constraints
if {![file exists $constraint_file]} {
    error "Missing constraint file: $constraint_file"
}
read_xdc $constraint_file

# Run synthesis only
synth_design -top $top_module -part $fpga_part
write_checkpoint -force $synth_dcp

# Dump timing/frequency reports
report_timing_summary -file $timing_rpt -no_detailed_paths
report_timing_summary -datasheet -file $datasheet_rpt

set worst_path [lindex [get_timing_paths -delay_type max -setup -max_paths 1 -nworst 1] 0]
if {$worst_path eq ""} {
    error "Unable to extract timing path information for Fmax calculation."
}

set datapath_delay [get_property DATAPATH_DELAY $worst_path]
if {$datapath_delay <= 0} {
    set fmax_msg "Unable to compute Fmax: reported datapath delay is non-positive."
} else {
    set fmax_mhz [expr {1000.0 / $datapath_delay}]
    set fmax_msg [format "Estimated Fmax (worst setup path): %.2f MHz (datapath delay = %.3f ns)" $fmax_mhz $datapath_delay]
}

puts $fmax_msg
set fp [open $fmax_report "w"]
puts $fp $fmax_msg
close $fp
