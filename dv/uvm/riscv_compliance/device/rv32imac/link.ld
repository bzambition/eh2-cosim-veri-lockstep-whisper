/* SPDX-License-Identifier: BSD-3-Clause */
/* EH2 RISC-V Compliance Linker Script — RV32IMAC (issue 57) */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ram (rwx) : ORIGIN = 0x80000000, LENGTH = 0x04000000
}

SECTIONS
{
    .text : {
        *(.text.init)
        *(.text)
        *(.text.*)
    } > ram

    .rodata : {
        *(.rodata)
        *(.rodata.*)
    } > ram

    .data : {
        *(.data)
        *(.data.*)
    } > ram

    .bss : {
        *(.bss)
        *(.bss.*)
    } > ram

    .tohost : {
        *(.tohost)
    } > ram
}
