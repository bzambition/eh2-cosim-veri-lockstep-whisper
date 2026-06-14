// SPDX-License-Identifier: Apache-2.0
// Minimal NOP test
// Boot address: 0x8000_0000

.section .text
.globl _start
_start:
    nop
    nop
    nop
    nop
    // Write 0xFF (PASS) to mailbox
    lui   a0, 0xD0580      // a0 = 0xD0580000
    li    a1, 0xFF
    sb    a1, 0(a0)
    // Loop forever
1:  j     1b
