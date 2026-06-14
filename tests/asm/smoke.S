// SPDX-License-Identifier: Apache-2.0
// Minimal smoke test - writes PASS to mailbox
// Boot address: 0x8000_0000
// Mailbox address: 0xD058_0000

.section .text
.globl _start
_start:
    // Load mailbox address
    lui   a0, 0xD0580      // a0 = 0xD0580000
    // Write 0xFF (PASS) to mailbox
    li    a1, 0xFF
    sb    a1, 0(a0)
    // Loop forever
1:  j     1b
