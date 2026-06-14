/* SPDX-License-Identifier: Apache-2.0 */
/* Linker script for EH2 cosim assembly tests */
/* All code and data in external memory starting at 0x80000000 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
    . = 0x80000000;
    .text : {
        *(.text.init)
        *(.text*)
    }
    .data : ALIGN(4) {
        *(.data*)
        *(.rodata*)
        *(.sdata*)
    }
    .bss : ALIGN(4) {
        *(.bss*)
        *(.sbss*)
    }
    . = ALIGN(16);
    _stack_top = .;
}
