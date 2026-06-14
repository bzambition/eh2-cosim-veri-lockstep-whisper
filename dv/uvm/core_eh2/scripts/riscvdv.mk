# SPDX-License-Identifier: Apache-2.0
# EH2 riscv-dv Makefile fragment
#
# Provides targets for building and running the riscv-dv random instruction
# generator, and compiling generated assembly into test binaries.
#
# Included by the top-level wrapper.mk

###############################################################################

CORE-CONFIG-STAMP = $(METADATA-DIR)/core.config.stamp
core_config: $(CORE-CONFIG-STAMP)
core-config-var-deps := EH2_CONFIG

INSTR-GEN-BUILD-STAMP = $(METADATA-DIR)/instr.gen.build.stamp
instr_gen_build: $(METADATA-DIR)/instr.gen.build.stamp
instr-gen-build-var-deps := SIMULATOR SIGNATURE_ADDR

instr_gen_run: $(riscvdv-test-asms)

riscvdv-test-asms +=
riscvdv-test-bins +=

###############################################################################
# Build the Random Instruction Generator
#

ig-build-vars-path := $(BUILD-DIR)/.instr_gen.vars.mk
-include $(ig-build-vars-path)
instr-gen-build-vars-prereq = \
  $(call vars-prereq, \
     gen, \
     building instruction generator, \
     $(instr-gen-build-var-deps))

$(METADATA-DIR)/instr.gen.build.stamp: \
  $(instr-gen-build-vars-prereq) $(riscv-dv-files) $(CORE-CONFIG-STAMP) \
  scripts/build_instr_gen.py \
  | $(BUILD-DIR)
	@echo Building randomized test generator
	$(verb)env PYTHONPATH=$(PYTHONPATH) \
	  scripts/build_instr_gen.py \
	    --dir-metadata $(METADATA-DIR)
	$(call dump-vars,$(ig-build-vars-path),gen,$(instr-gen-build-var-deps))
	@touch $@

###############################################################################
# Run the random instruction generator
#

$(riscvdv-test-asms): $(TESTS-DIR)/%/$(asm-stem): \
  $(INSTR-GEN-BUILD-STAMP) $(TESTLIST) scripts/run_instr_gen.py
	@echo Running randomized test generator to create assembly file $@
	$(verb)env PYTHONPATH=$(PYTHONPATH) \
	scripts/run_instr_gen.py \
	  --dir-metadata $(METADATA-DIR) \
	  --test-dot-seed $*
