build:
	vivado -mode batch -source build.tcl

program_board:
	vivado -mode batch -source program_board.tcl

timing_gemm:
	vivado -mode batch -source run_timing_gemm.tcl

timing_softmax:
	vivado -mode batch -source run_timing_softmax.tcl

timing_depthwise_conv:
	vivado -mode batch -source run_timing_depthwise_conv.tcl

timing_residual_add:
	vivado -mode batch -source run_timing_residual_add.tcl

xsim:
	vivado -mode batch -source run_xsim.tcl

clean:
	rm -rf ../Xil
	rm -rf .hw
	rm -rf .run
	rm -rf .cache
	rm -rf .settings
	rm -rf *.jou
	rm -rf *.log
	rm -rf ../build
	rm -rf .Xil
	rm -rf *.pb
	rm -rf xsim.dir
	rm -rf webtalk*

help:
	@echo ""
	@echo "****************************************************"
	@echo "******* ViT Tiny FPGA Build System Makefile ********"
	@echo "****************************************************"
	@echo "** make build           : build the FPGA bitstream"
	@echo "** make timing_{module} : Run Synthesis & Implementation and report Fmax for module"
	@echo "** make xsim            : Run Vivado simulation with UNISIM (DSP48E1)"
	@echo "** make program_board   : program the FPGA board"
	@echo "** make clean           : clean all generated files"
	@echo "****************************************************"
