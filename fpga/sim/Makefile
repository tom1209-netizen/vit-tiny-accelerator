#Define variables
TESTNAME 	?= tb_residual_add
TB_NAME 	?= tb_residual_add
RADIX		?= hex
MEALY_FSM   ?= 0
SIM_DEBUG   ?= 1
USE_UNISIM  ?= 1
XILINX_LIB_DIR ?= $(CURDIR)/xilinx_lib
XILINX_LIBS ?= unisim

VLOG_DEFINES := $(if $(SIM_DEBUG),+define+SIM_DEBUG,) $(if $(USE_UNISIM),+define+USE_UNISIM,)
VLOG_LIBS := $(if $(USE_UNISIM),$(foreach lib,$(XILINX_LIBS),-L $(lib)),)
VSIM_LIBS := $(if $(USE_UNISIM),$(foreach lib,$(XILINX_LIBS),-L $(lib)),)

#==============================

ARGS := $(MAKECMDGOALS)

# Insert new commands here if you want to add more make targets, use "\" to break lines
COMMANDS := all all_wave all_cov \
			build build_cov \
			run run_cov \
			wave \
			gen_cov gen_html \
			xilinx_libs check_xilinx_libs clean_libs \
			clean \
			help

TEST_ARG := $(filter-out $(COMMANDS),$(ARGS))

ifneq ($(TEST_ARG),)
    TESTNAME := $(firstword $(TEST_ARG))
    TB_NAME  := $(firstword $(TEST_ARG))

    $(TEST_ARG):
		@:
endif

#==============================

all: clean build run

all_wave: clean build run wave

all_cov: clean build_cov run_cov

build: $(if $(USE_UNISIM),check_xilinx_libs,)
	vlib work
	vmap work work
	@if [ "$(USE_UNISIM)" = "1" ]; then \
		for lib in $(XILINX_LIBS); do \
			vmap $$lib $(XILINX_LIB_DIR)/$$lib; \
		done; \
	fi
	vlog $(VLOG_DEFINES) $(VLOG_LIBS) -f compile.f | tee compile.log

build_cov: $(if $(USE_UNISIM),check_xilinx_libs,)
	vlib work
	vmap work work
	@if [ "$(USE_UNISIM)" = "1" ]; then \
		for lib in $(XILINX_LIBS); do \
			vmap $$lib $(XILINX_LIB_DIR)/$$lib; \
		done; \
	fi
	vlog +cover=bcesft $(VLOG_DEFINES) $(VLOG_LIBS) -f compile.f

run:
	vsim $(VSIM_LIBS) -debugDB -l $(TESTNAME).log -voptargs=+acc -assertdebug -c $(TB_NAME) -do "log -r /*;run -all;" -GMEALY_FSM=$(MEALY_FSM)

run_cov:
	vsim $(VSIM_LIBS) -coverage -l $(TESTNAME).log -c $(TB_NAME) -voptargs="+cover=bcesft" -assertdebug -do "do exclude.do; coverage save -onexit $(TESTNAME).ucdb; log -r /*;run -all"

wave:
	vsim -i -view vsim.wlf -do "add wave vsim:/$(TB_NAME)/*; radix -$(RADIX)" &

gen_cov:
	mkdir -p coverage
	vcover merge IP.ucdb *.ucdb
	vcover report IP.ucdb -output coverage/summary_report.txt
	vcover report -zeros -details -code bcesft -annotate -All -codeAll IP.ucdb -output coverage/detail_report.txt

gen_html:
	mkdir -p coverage
	vcover merge IP.ucdb *.ucdb
	vcover report -zeros -details -code bcesft -annotate -testhitdataAll -html IP.ucdb 

clean:
	rm -rf work
	rm -rf vsim.dbg
	rm -rf *.ini
	rm -rf *.log
	rm -rf *.wlf
	rm -rf transcript
	rm -rf *.ucdb

clean_libs:
	rm -rf $(XILINX_LIB_DIR)

xilinx_libs:
	mkdir -p $(XILINX_LIB_DIR)
	vlib $(XILINX_LIB_DIR)/unisim
	vmap unisim $(XILINX_LIB_DIR)/unisim
	vlog -work unisim $(XILINX_VIVADO)/data/verilog/src/unisims/*.v
	vlog -work unisim $(XILINX_VIVADO)/data/verilog/src/glbl.v

check_xilinx_libs:
	@for lib in $(XILINX_LIBS); do \
		if [ ! -d "$(XILINX_LIB_DIR)/$$lib" ]; then \
			echo "Missing Xilinx sim lib: $$lib"; \
			echo "Run: make xilinx_libs XILINX_LIB_DIR=$(XILINX_LIB_DIR)"; \
			exit 1; \
		fi; \
	done

help:
	@echo ""
	@echo "****************************************"
	@echo "** make clean    : clean all compiled data"
	@echo "** make build    : build the design"
	@echo "** make build_cov: build the design in coverage mode"
	@echo "** make run      : run simulation"
	@echo "** make run_cov  : run simulation in coverage mode"
	@echo "** make all      : build and run simulation"
	@echo "** make all_cov  : build and run simulation in coverage mode"
	@echo "** make wave     : open waveform"
	@echo "** make gen_cov  : merge, generate coverage data base and text coverage report"
	@echo "** make gen_cov  : merge, gemerate coverage data base and html coverage report"
	@echo "** make xilinx_libs   : build Xilinx UNISIM libraries for Questa"
	@echo "** make clean_libs    : remove precompiled Xilinx libraries"
	@echo "** make help     : print this help message"
	@echo "****************************************"
	@echo ""
