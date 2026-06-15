# SPDX-License-Identifier: Apache-2.0
# EH2 RISC-V Compliance Test Makefile (issue 57)
#
# Compiles riscv-compliance tests for EH2, runs them through simv,
# captures signatures, and compares byte-by-byte against reference outputs.
#
# Usage:
#   make compliance RISCV_ISA=rv32i          # Run all RV32I tests
#   make compliance RISCV_ISA=rv32im         # Run all RV32IM tests
#   make compliance RISCV_ISA=rv32imc        # Run all RV32IMC tests
#   make compliance-all                      # Run all supported suites
#   make compile-compliance-tb               # Compile the stand-alone compliance TB
#   make clean                               # Clean work directory
#
# Prerequisites:
#   - riscv32-unknown-elf-gcc in PATH
#   - compiled EH2 testbench from the top-level Makefile
#   - vendored riscv-tests or riscv-compliance framework at $(COMPLIANCE_FW)

SHELL := /bin/bash

EH2_ROOT        ?= $(realpath $(CURDIR)/../../..)
RISCV_TESTS_FW  ?= $(EH2_ROOT)/vendor/riscv-tests
RISCV_COMPLIANCE_FW ?= $(RISCV_TESTS_FW)
COMPLIANCE_FW   ?= $(RISCV_COMPLIANCE_FW)
COMPLIANCE_DIR  ?= $(CURDIR)
WORK_DIR        ?= $(COMPLIANCE_DIR)/work

RISCV_PREFIX    ?= riscv32-unknown-elf-
RISCV_ISA       ?= rv32i
RISCV_DEVICE    ?= rv32imac

# Supported compliance suites from the vendored riscv-tests source layout.
SUPPORTED_ISAS := rv32i rv32im rv32imc
KNOWN_FAIL_ISAS :=

# Device directory for a given ISA
DEVICE_DIR      = $(COMPLIANCE_DIR)/device/$(ISA)

# Simulator
SIMULATOR       ?= vcs
BUILD_DIR       ?= $(EH2_ROOT)/build/compile_$(SIMULATOR)
SIMV            ?= $(EH2_ROOT)/build/simv

# Python runner
RUNNER          := $(COMPLIANCE_DIR)/scripts/run_compliance.py
RUNNER_ENV      := RISCV_COMPLIANCE_FW="$(COMPLIANCE_FW)" \
                   RISCV_TESTS_FW="$(RISCV_TESTS_FW)" \
                   RISCV_PREFIX="$(RISCV_PREFIX)" \
                   NC_INSTALL="$(NC_INSTALL)"

#----------------------------------------------------------------------
# Top-level targets
#----------------------------------------------------------------------
.PHONY: compliance compliance-all compliance-compile clean \
        compile-compliance-tb list-tests

# Run compliance tests for a single ISA (delegates to Python runner)
compliance:
	@if [ -z "$(COMPLIANCE_FW)" ] || [ ! -d "$(COMPLIANCE_FW)" ]; then \
		echo "ERROR: COMPLIANCE_FW is not set or not a directory"; \
		echo "  Set RISCV_COMPLIANCE_FW or COMPLIANCE_FW in env.mk / make command"; \
		exit 1; \
	fi
	@if [ "$(SIMULATOR)" = "nc" ]; then \
		if [ ! -d "$(BUILD_DIR)/INCA_libs" ]; then \
			echo "ERROR: NC INCA_libs not found at $(BUILD_DIR)/INCA_libs"; \
			echo "  Build it: cd $(EH2_ROOT) && make compile SIMULATOR=nc"; \
			exit 1; \
		fi; \
	else \
		if [ ! -f "$(SIMV)" ]; then \
			echo "ERROR: simv not found at $(SIMV)"; \
			echo "  Build it: cd $(EH2_ROOT) && make compile SIMULATOR=$(SIMULATOR)"; \
			exit 1; \
		fi; \
	fi
	@echo "=== EH2 Compliance: $(RISCV_ISA) ==="
	$(RUNNER_ENV) python3 $(RUNNER) --isa $(RISCV_ISA) --simv $(SIMV) \
		--simulator $(SIMULATOR) --build-dir $(BUILD_DIR) \
		--output $(WORK_DIR)/$(RISCV_ISA) \
		$(if $(VERBOSE),--verbose,)

# Run all compliance suites
compliance-all:
	@failed=0; \
	for isa in $(SUPPORTED_ISAS); do \
		echo ""; \
		echo "========================================"; \
		echo "  $$isa"; \
		echo "========================================"; \
		$(MAKE) compliance RISCV_ISA=$$isa || failed=1; \
	done; \
	if [ $$failed -ne 0 ]; then \
		echo ""; \
		echo "Some suites had failures (check known-fail ISAs: $(KNOWN_FAIL_ISAS))"; \
	fi

# Compile tests only (no simulation)
compliance-compile:
	@if [ -z "$(COMPLIANCE_FW)" ] || [ ! -d "$(COMPLIANCE_FW)" ]; then \
		echo "ERROR: COMPLIANCE_FW is not set or not a directory"; \
		echo "  Set RISCV_COMPLIANCE_FW or COMPLIANCE_FW in env.mk / make command"; \
		exit 1; \
	fi
	$(RUNNER_ENV) python3 $(RUNNER) --isa $(RISCV_ISA) --dry-run

# List available tests for an ISA
list-tests:
	@if [ -z "$(COMPLIANCE_FW)" ] || [ ! -d "$(COMPLIANCE_FW)" ]; then \
		echo "ERROR: COMPLIANCE_FW is not set or not a directory"; \
		echo "  Set RISCV_COMPLIANCE_FW or COMPLIANCE_FW in env.mk / make command"; \
		exit 1; \
	fi
	$(RUNNER_ENV) python3 $(RUNNER) --isa $(RISCV_ISA) --list-tests

#----------------------------------------------------------------------
# Stand-alone compliance TB compilation (VCS)
#
# Compiles eh2_compliance_tb.sv into a dedicated simv_compliance binary.
# This TB has no UVM dependencies — pure EH2 wrapper + AXI memories +
# signature monitor.
#----------------------------------------------------------------------
COMPLIANCE_TB_DIR  := $(COMPLIANCE_DIR)/tb
COMPLIANCE_TB_TOP  := eh2_compliance_tb
COMPLIANCE_SIMV    := $(EH2_ROOT)/build/simv_compliance

# File lists from the core testbench (reuse RTL + shared)
RTL_F      := $(EH2_ROOT)/dv/uvm/core_eh2/eh2_rtl.f
SHARED_F   := $(EH2_ROOT)/dv/uvm/core_eh2/eh2_shared.f

compile-compliance-tb:
	@echo "=== Compiling stand-alone compliance TB (VCS) ==="
	@mkdir -p $(EH2_ROOT)/build
	cd $(EH2_ROOT) && vcs -full64 -assert svaext -sverilog \
		+error+500 \
		+define+GTLSIM \
		+define+RV_BUILD_AXI4 \
		rtl/snapshots/default/common_defines.vh \
		+incdir+rtl/snapshots/default \
		+incdir+dv/uvm/core_eh2/tb \
		+incdir+dv/uvm/core_eh2/common \
		-f $(RTL_F) \
		-f $(SHARED_F) \
		$(COMPLIANCE_TB_DIR)/eh2_compliance_tb.sv \
		-top $(COMPLIANCE_TB_TOP) \
		-o $(COMPLIANCE_SIMV) \
		-l $(EH2_ROOT)/build/compliance_tb_compile.log \
		-timescale=1ns/1ps
	@echo "=== Compliance TB compiled: $(COMPLIANCE_SIMV) ==="

# Old-style: compile a single test hex (for manual testing)
test-%.hex:
	$(RISCV_PREFIX)gcc -march=$(RISCV_ISA) -mabi=ilp32 -nostdlib -nostartfiles \
		-T$(COMPLIANCE_DIR)/device/$(RISCV_ISA)/link.ld \
		-I$(COMPLIANCE_DIR)/device/$(RISCV_ISA) \
		-I$(COMPLIANCE_FW)/riscv-test-env \
		-I$(COMPLIANCE_FW)/riscv-test-env/p \
		$(COMPLIANCE_DIR)/device/$(RISCV_ISA)/startup.S \
		$(COMPLIANCE_FW)/riscv-test-suite/$(RISCV_ISA)/src/$*.S \
		-o $*.elf
	$(RISCV_PREFIX)objcopy -O verilog $*.elf $@
	@echo "Generated $@"

#----------------------------------------------------------------------
# Clean
#----------------------------------------------------------------------
clean:
	rm -rf $(WORK_DIR)
	@echo "Cleaned $(WORK_DIR)"
