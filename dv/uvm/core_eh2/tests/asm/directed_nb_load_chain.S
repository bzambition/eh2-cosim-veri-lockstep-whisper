// SPDX-License-Identifier: Apache-2.0
// EH2 Directed NB-Load Chain Test
//
// Three consecutive non-blocking loads followed by a branch using results.
// Verifies RISK-5 (NB-load wb cross-slot) does not resurface.
// cosim: enabled

.section .text.init
.globl _start

_start:
    // Set up data in memory
    li      t0, 0x80001000
    li      t1, 0xAABBCCDD
    sw      t1, 0(t0)
    li      t1, 0x11223344
    sw      t1, 4(t0)
    li      t1, 0x55667788
    sw      t1, 8(t0)

    // Fence to ensure stores complete
    fence

    // Three consecutive loads (non-blocking pipeline)
    lw      x1, 0(t0)           // x1 = 0xAABBCCDD
    lw      x2, 4(t0)           // x2 = 0x11223344
    lw      x3, 8(t0)           // x3 = 0x55667788

    // Use all three results in computation
    add     x4, x1, x2          // x4 = 0xBBDE0021
    add     x5, x4, x3          // x5 = 0x114477A9

    // Verify chain result
    li      x20, 0xAABBCCDD
    bne     x1, x20, fail
    li      x20, 0x11223344
    bne     x2, x20, fail
    li      x20, 0x55667788
    bne     x3, x20, fail

    // Verify computed values
    add     x20, x1, x2
    bne     x4, x20, fail
    add     x20, x4, x3
    bne     x5, x20, fail

pass:
    li      t0, 0xD0580000
    li      t1, 0xFF
    sw      t1, 0(t0)
    j       done

fail:
    li      t0, 0xD0580000
    li      t1, 0x01
    sw      t1, 0(t0)

done:
1:  j       1b
