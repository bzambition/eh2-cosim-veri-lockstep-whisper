# EH2 Core UVM - Local Development Makefile
#
# Convenience targets for working within dv/uvm/core_eh2.
# Delegates to the top-level Makefile for actual simulation.
#
# Usage:
#   make help       - Show available targets
#   make compile    - Compile the testbench
#   make smoke      - Run smoke test
#   make run        - Run a single test (TEST=, SEED=)
#   make cov        - Collect coverage
#   make signoff    - Run sign-off gate
#   make lint       - Run lint checks on UVM sources
#   make clean      - Clean build artifacts

SHELL := /bin/bash

# Project root (relative to this Makefile)
PROJ_ROOT := ../../..
TB_DIR    := dv/uvm/core_eh2

# Pass-through variables
CONFIG     ?= default
SEED       ?= 1
TEST       ?= riscv_arithmetic_basic_test
SIMULATOR   ?= vcs
BINARY      ?=
WAVES       ?= 0
COV         ?= 0
ITERATIONS  ?= 1
PARALLEL    ?= 1
RTL_TEST    ?= core_eh2_base_test
VERBOSITY   ?= UVM_MEDIUM
SIGNOFF_ITERATIONS ?=
LEC_BLOCKLEVEL ?= 0
LEC_SUMMARY_PATH ?= syn/build/lec_summary.txt

# Coverage compile options are owned by the top-level Makefile and
# rtl_simulation.yaml; R2-B requires FSM extraction through -cm_fsmcfg.

.PHONY: help compile run gen smoke nightly weekly signoff signoff_quick cov clean lint

help:
	@echo "EH2 Core UVM - Local Development"
	@echo "================================="
	@echo ""
	@echo "Build:"
	@echo "  compile     - Compile RTL testbench (SIMULATOR=vcs|xlm)"
	@echo ""
	@echo "Test:"
	@echo "  smoke       - Quick smoke test"
	@echo "  run         - Run single test (TEST=, SEED=)"
	@echo "  nightly     - Nightly regression"
	@echo "  weekly      - Weekly regression"
	@echo "  signoff     - Full sign-off gate"
	@echo "  signoff_quick - Quick sign-off gate"
	@echo "  gen         - Generate riscv-dv instructions (TEST=)"
	@echo ""
	@echo "Utility:"
	@echo "  cov         - Collect and merge coverage"
	@echo "  lint        - Check UVM source syntax"
	@echo "  clean       - Clean build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  TEST, SEED, SIMULATOR, CONFIG, BINARY, WAVES, COV"

compile:
	cd $(PROJ_ROOT) && $(MAKE) compile SIMULATOR=$(SIMULATOR) CONFIG=$(CONFIG)

run: compile
	cd $(PROJ_ROOT) && $(MAKE) run TEST=$(TEST) SEED=$(SEED) \
	  SIMULATOR=$(SIMULATOR) BINARY=$(BINARY) WAVES=$(WAVES) COV=$(COV) \
	  RTL_TEST=$(RTL_TEST) VERBOSITY=$(VERBOSITY)

gen:
	cd $(PROJ_ROOT) && $(MAKE) gen TEST=$(TEST) SEED=$(SEED) \
	  ITERATIONS=$(ITERATIONS)

smoke:
	cd $(PROJ_ROOT) && $(MAKE) smoke SIMULATOR=$(SIMULATOR)

nightly:
	cd $(PROJ_ROOT) && $(MAKE) nightly SIMULATOR=$(SIMULATOR) PARALLEL=$(PARALLEL)

weekly:
	cd $(PROJ_ROOT) && $(MAKE) weekly SIMULATOR=$(SIMULATOR) PARALLEL=$(PARALLEL)

signoff:
	cd $(PROJ_ROOT) && $(MAKE) signoff SIMULATOR=$(SIMULATOR) PARALLEL=$(PARALLEL) \
	  SIGNOFF_ITERATIONS=$(SIGNOFF_ITERATIONS) COV=$(COV) WAVES=$(WAVES) \
	  LEC_BLOCKLEVEL=$(LEC_BLOCKLEVEL) LEC_SUMMARY_PATH=$(LEC_SUMMARY_PATH)

signoff_quick:
	cd $(PROJ_ROOT) && $(MAKE) signoff_quick SIMULATOR=$(SIMULATOR) PARALLEL=$(PARALLEL)

cov:
	cd $(PROJ_ROOT) && $(MAKE) cov SIMULATOR=$(SIMULATOR)

clean:
	cd $(PROJ_ROOT) && $(MAKE) clean

# Quick syntax check - compile UVM sources only (no RTL)
# Useful for catching SV syntax errors without full compilation
lint:
	@echo "=== Linting UVM sources ==="
	@# List all .sv files in the UVM tree
	@find . -name "*.sv" -o -name "*.svh" | sort
	@echo ""
	@echo "Total UVM source files: $$(find . -name '*.sv' -o -name '*.svh' | wc -l)"
	@echo ""
	@echo "Note: Full syntax validation requires a simulator license."
	@echo "Use 'make compile' for actual compilation."
