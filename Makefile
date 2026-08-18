# Cyclone V HMC DQS/DQ timing fault-injection testbench
#
# Validated with Icarus Verilog 12.0 (open source, installable via
# apt/brew) so the repo can be run without a commercial simulator
# license. See README for the SystemVerilog features that had to be
# avoided as a result.

IVERILOG = iverilog
VVP      = vvp
FLAGS    = -g2012 -gsupported-assertions

RTL = rtl/ddr3_behavioral_model.sv
TB  = tb/hmc_stimulus_driver.sv \
      tb/hmc_timing_assertions.sv \
      tb/hmc_scoreboard.sv \
      tb/tb_top.sv

OUT = build/tb.vvp

.PHONY: all run clean waves

all: $(OUT)

$(OUT): $(RTL) $(TB)
	@mkdir -p build
	$(IVERILOG) $(FLAGS) -o $(OUT) $(RTL) $(TB)

run: $(OUT)
	@cd build && $(VVP) tb.vvp

# Regenerate the checked-in sample log
log: $(OUT)
	@cd build && $(VVP) tb.vvp > ../docs/sample_run.log 2>&1
	@echo "wrote docs/sample_run.log"

waves: run
	@echo "VCD written to build/tb_top.vcd -- open with: gtkwave build/tb_top.vcd"

clean:
	rm -rf build
