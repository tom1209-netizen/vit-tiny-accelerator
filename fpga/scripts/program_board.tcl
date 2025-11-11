# Open the hardware manager and connect to the FPGA board
open_hw_manager
connect_hw_server
current_hw_target
open_hw_target

# Set the bitstream file to program
# Change this path if your bitstream is located elsewhere
set bitstream "fpga/build/gemm_core_top.bit"

#  Program the FPGA with the generated bitstream
set_property PROGRAM.FILE $bitstream [current_hw_device]
program_hw_devices [current_hw_device]