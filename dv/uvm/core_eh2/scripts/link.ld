
OUTPUT_FORMAT("elf32-littleriscv", "elf32-littleriscv", "elf32-littleriscv")
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    FLASH (rxai!w) : ORIGIN = 0x80000000, LENGTH = 64M
    RAM   (wxa!ri)  : ORIGIN = 0x81000000, LENGTH = 16M
}

PHDRS
{
    flash PT_LOAD;
    ram_init PT_LOAD;
}

SECTIONS
{
    .text.init ORIGIN(FLASH) : {
        *(.text.init)
    } > FLASH AT> FLASH : flash

    .text : ALIGN(16) {
        *(.text)
        *(.text.*)
    } > FLASH AT> FLASH : flash

    .data : ALIGN(16) {
        *(.data)
        *(.data.*)
    } > RAM AT> FLASH : ram_init

    .bss : ALIGN(16) {
        *(.bss)
        *(.bss.*)
        *(COMMON)
    } > RAM

    .tohost ALIGN(64) : {
        *(.tohost)
    } > RAM

    .signature ALIGN(64) : {
        *(.signature)
    } > RAM
}
