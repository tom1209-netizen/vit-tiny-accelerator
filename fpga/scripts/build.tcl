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
    "$rtl_dir/cpu_core/wb/wb_arbiter.v" \
    "$rtl_dir/memory/instr_mem.v" \
    "$rtl_dir/memory/data_mem.v" \
    "$rtl_dir/csr_file.v" \
    "$rtl_dir/hazard_unit.v" \
    "$rtl_dir/riscv_core.v" \
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
