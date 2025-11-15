build:
	vivado -mode batch -source build.tcl

synth_fmax:
	vivado -mode batch -source synth_fmax.tcl

program_board:
	vivado -mode batch -source program_board.tcl

clean:
	rm -rf .Xil
	rm -rf .hw
	rm -rf .run
	rm -rf .cache
	rm -rf .settings
	rm -rf *.jou

help:
	@echo ""
	@echo "************************************************"
	@echo "** make build         : build the FPGA bitstream"
	@echo "** make synth_fmax    : synthesize + dump Fmax report"
	@echo "** make program_board : program the FPGA board"
	@echo "** make clean         : clean all generated files"
	@echo "************************************************"
