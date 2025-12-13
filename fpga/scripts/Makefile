build:
	vivado -mode batch -source build.tcl

program_board:
	vivado -mode batch -source program_board.tcl

timing:
	vivado -mode batch -source run_timing.tcl

timing_softmax:
	vivado -mode batch -source run_timing_softmax.tcl

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
	@echo "**************************************************"
	@echo "******* ViT Tiny FPGA Build System Makefile ********"
	@echo "**************************************************"
	@echo "** make build         : build the FPGA bitstream"
	@echo "** make timing        : Run Synthesis & Implementation and report Fmax"
	@echo "** make xsim          : Run Vivado simulation with UNISIM (DSP48E1)"
	@echo "** make program_board : program the FPGA board"
	@echo "** make clean         : clean all generated files"
	@echo "**************************************************"
