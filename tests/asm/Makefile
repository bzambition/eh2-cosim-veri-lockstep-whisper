# tests/asm/Makefile
# ------------------------------------------------------------
# 顶层独立汇编测试（smoke.S / nop.S）的编译规则
#
# 用途：
#   这些 .hex 是 README quickstart 和 sign-off smoke stage 的
#   直接输入（--binary tests/asm/smoke.hex），过去没有重建钩子，
#   一旦被 clean 删掉就会导致 smoke 跑空 cycle timeout。
#
# 用法：
#   make            构建所有 hex（smoke.hex / nop.hex）
#   make clean      清理 *.elf / *.hex / *.dis 及 hex/ 子目录
# ------------------------------------------------------------

RISCV_PREFIX ?= riscv32-unknown-elf-
CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump

ARCH    ?= rv32imac
ABI     ?= ilp32
LINKER  := smoke.ld

CFLAGS  := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding
LDFLAGS := -T $(LINKER) -nostdlib

SRCS    := smoke.S nop.S
HEXES   := $(SRCS:.S=.hex)
ELFS    := $(SRCS:.S=.elf)

.PHONY: all clean
all: $(HEXES) $(ELFS)
	@echo "[tests/asm] built: $(HEXES)"

.SECONDARY: $(ELFS)

%.elf: %.S $(LINKER)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

%.hex: %.elf
	$(OBJDUMP) -d $< > $*.dis
	$(OBJCOPY) -O verilog $< $@

clean:
	@rm -f *.elf *.hex *.dis
	@rm -rf hex
	@echo "[tests/asm] cleaned"
