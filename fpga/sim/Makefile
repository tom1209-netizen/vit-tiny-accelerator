#Define variables
TESTNAME 	?= tb_norm_unit
TB_NAME 	?= tb_norm_unit
RADIX		?= hex
MEALY_FSM   ?= 0

#==============================

ARGS := $(MAKECMDGOALS)

# Insert new commands here if you want to add more make targets, use "\" to break lines
COMMANDS := all all_wave all_cov \
			build build_cov \
			run run_cov \
			wave \
			gen_cov gen_html \
			clean \
			fast \
			help

TEST_ARG := $(filter-out $(COMMANDS),$(ARGS))

ifneq ($(TEST_ARG),)
    TESTNAME := $(firstword $(TEST_ARG))
    TB_NAME  := $(firstword $(TEST_ARG))

    $(TEST_ARG):
		@:
endif

#==============================

all: build run

all_wave: build run wave

all_cov: build_cov run_cov

build:
	vlib work
	vmap work work
	vlog -f compile.f | tee compile.log

build_cov:
	vlib work
	vmap work work
	vlog +cover=bcesft -f compile.f

run:
	vsim -debugDB -l $(TESTNAME).log -voptargs=+acc -assertdebug -c $(TB_NAME) -do "log -r /*;run -all;" -GMEALY_FSM=$(MEALY_FSM)

run_cov:
	vsim -coverage -l $(TESTNAME).log -c $(TB_NAME) -voptargs="+cover=bcesft" -assertdebug -do "do exclude.do; coverage save -onexit $(TESTNAME).ucdb; log -r /*;run -all"

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

fast: 
	$(MAKE) clean
	clear
	$(MAKE) all_wave TESTNAME=$(TESTNAME) TB_NAME=$(TB_NAME) MEALY_FSM=$(MEALY_FSM)

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
	@echo "** make fast     : clean, build and run simulation with waveform"
	@echo "** make help     : print this help message"
	@echo "****************************************"
	@echo ""