build:
	vivado -mode batch -source build.tcl

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
	@echo "** make program_board : program the FPGA board"
	@echo "** make clean         : clean all generated files"
	@echo "************************************************"