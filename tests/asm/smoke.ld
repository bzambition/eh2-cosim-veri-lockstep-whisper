OUTPUT_FORMAT("elf32-littleriscv")
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    BOOT (rxai!rw) : ORIGIN = 0x80000000, LENGTH = 4K
    RAM (wxa!ri)   : ORIGIN = 0x80001000, LENGTH = 60K
}

SECTIONS
{
    .text : {
        *(.text*)
    } > BOOT

    .data : {
        *(.data*)
        *(.sdata*)
        *(.rodata*)
    } > RAM

    .bss : {
        *(.bss*)
        *(.sbss*)
    } > RAM

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
