// SPDX-License-Identifier: BSD-3-Clause
// EH2 RISC-V Compliance Startup Code — RV32IMAC (issue 57)
//
// Sets up trap handler, clears BSS, calls compliance test main,
// writes result to mailbox.

.section .text.init
.globl _start

_start:
    // Set up trap handler for compliance (direct mode)
    la      t0, trap_handler
    csrw    mtvec, t0

    // Clear BSS
    la      t0, _bss_start
    la      t1, _bss_end
1:  bge     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b

2:  // Call compliance test main
    call    main

    // Write result to mailbox (0xD0580000)
    li      t0, 0xD0580000
    // Return value from main: 0 = PASS, non-zero = FAIL
    li      t1, 0xFF
    beqz    a0, 3f
    li      t1, 0x01
3:  sw      t1, 0(t0)

4:  j       4b

// Trap handler — report unexpected trap as FAIL
trap_handler:
    li      t0, 0xD0580000
    li      t1, 0x03   // compliance trap = fail code 3
    sw      t1, 0(t0)
    j       trap_handler

// BSS markers
.section .bss
.align 4
_bss_start:
    .zero 1024
_bss_end:
