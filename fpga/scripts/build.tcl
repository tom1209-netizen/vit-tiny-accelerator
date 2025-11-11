# derive project-relative directories from this script location
set script_dir   [file dirname [file normalize [info script]]]
set fpga_dir     [file normalize [file join $script_dir ".."]]
set project_root [file normalize [file join $fpga_dir ".."]]
set rtl_dir      [file join $fpga_dir "rtl"]
set constraints_dir [file join $fpga_dir "constraints"]
set build_dir    [file join $fpga_dir "build"]

file mkdir $build_dir

# design / board settings
# Temporarily place holder that use Khang GEMM module
set top_module   "gemm_core_top"
set fpga_part    "xc7z020clg400-1"
set bitstream    [file join $build_dir "${top_module}.bit"]
set constraint_file [file join $constraints_dir "arty_z7.xdc"]

# RTL sources in dependency-friendly order
set rtl_files [list \
    [file join $rtl_dir "gemm" "processing_element.v"] \
    [file join $rtl_dir "gemm" "systolic_array.v"] \
    [file join $rtl_dir "gemm" "input_buffer_controller.v"] \
    [file join $rtl_dir "gemm" "output_collector.v"] \
    [file join $rtl_dir "gemm" "gemm_core_top.v"] \
]

# Begin synthesis flow
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

# Run synthesis, implementation, and bitstream generation
synth_design -top $top_module -part $fpga_part
opt_design
place_design
route_design

# Generate the bitstream
write_bitstream -force $bitstream
