# SPDX-License-Identifier: Apache-2.0
# Makefile for EH2 cosim assembly tests
#
# Usage:
#   make all           - Build all tests
#   make cosim_smoke   - Build smoke test
#   make cosim_alu     - Build ALU test
#   make clean         - Clean build artifacts

RISCV_PREFIX ?= riscv32-unknown-elf-
CC      = $(RISCV_PREFIX)gcc
OBJCOPY = $(RISCV_PREFIX)objcopy
OBJDUMP = $(RISCV_PREFIX)objdump

ARCH    = rv32imac
ABI     = ilp32
LINKER  = cosim_link.ld

CFLAGS  = -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding
LDFLAGS = -T $(LINKER) -nostdlib

OUT_DIR = hex

.PHONY: all clean

all: $(OUT_DIR)/cosim_smoke.hex $(OUT_DIR)/cosim_alu.hex $(OUT_DIR)/cosim_load_store.hex $(OUT_DIR)/cosim_dual_issue.hex
	@echo "=== All tests built ==="

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

$(OUT_DIR)/cosim_smoke.elf: cosim_smoke.S $(LINKER) | $(OUT_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ cosim_smoke.S

$(OUT_DIR)/cosim_alu.elf: cosim_alu.S $(LINKER) | $(OUT_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ cosim_alu.S

$(OUT_DIR)/cosim_load_store.elf: cosim_load_store.S $(LINKER) | $(OUT_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ cosim_load_store.S

$(OUT_DIR)/cosim_dual_issue.elf: cosim_dual_issue.S $(LINKER) | $(OUT_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ cosim_dual_issue.S

$(OUT_DIR)/%.hex: $(OUT_DIR)/%.elf
	$(OBJDUMP) -d $< > $(basename $@).dis
	$(OBJCOPY) -O verilog $< $@

clean:
	rm -rf $(OUT_DIR)/*.elf $(OUT_DIR)/*.hex $(OUT_DIR)/*.dis
