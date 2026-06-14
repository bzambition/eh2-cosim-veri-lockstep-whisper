/* SPDX-License-Identifier: Apache-2.0 */
/* EH2 Compliance Linker Script (issue 57) */

OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);  /* R+X */
    data PT_LOAD FLAGS(6);  /* R+W */
}

MEMORY
{
    ram (rwx) : ORIGIN = 0x80000000, LENGTH = 0x04000000
}

SECTIONS
{
    .text.init : {
        KEEP(*(.text.init))
    } > ram :text

    .text : {
        *(.text)
        *(.text.*)
    } > ram :text

    .rodata : {
        *(.rodata)
        *(.rodata.*)
    } > ram :text

    .data : {
        *(.data)
        *(.data.*)
    } > ram :data

    /* Compliance signature section.
     * begin_signature marks the start; test data follows via
     * RV_COMPLIANCE_DATA_BEGIN/END which sets end_signature. */
    .signature : {
        begin_signature = .;
    } > ram :data

    .bss : {
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        _bss_end = .;
    } > ram :data

    _end = .;
}