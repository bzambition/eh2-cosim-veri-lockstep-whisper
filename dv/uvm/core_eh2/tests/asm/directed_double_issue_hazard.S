// SPDX-License-Identifier: Apache-2.0
// EH2 Directed Double-Issue Hazard Test
//
// Constructs i0/i1 same-cycle RAW, WAR, WAW hazards for dual-issue pipeline.
// Verifies writeback ordering matches program order (trace_pkt constraint).
// cosim: enabled

.section .text.init
.globl _start

_start:
    // ---- RAW hazard pair 1 ----
    // i0 writes x1, i1 reads x1 (same cycle if dual-issued)
    li      x1, 100
    add     x2, x1, x0          // RAW: x1
    // Expected: x2 = 100

    // ---- RAW hazard pair 2 ----
    li      x3, 200
    addi    x4, x3, 50          // RAW: x3
    // Expected: x4 = 250

    // ---- WAR hazard pair 1 ----
    // i0 reads x5, i1 writes x5
    li      x5, 10
    li      x6, 20
    add     x7, x5, x6          // reads x5=10, x6=20 -> x7=30
    li      x5, 99              // WAR: overwrites x5 after read
    // x7 should be 30 (not affected by x5=99)

    // ---- WAR hazard pair 2 ----
    li      x8, 0xAA
    li      x9, 0xBB
    xor     x10, x8, x9         // reads x8=0xAA, x9=0xBB -> x10=0x11
    li      x8, 0xFF            // WAR: overwrites x8

    // ---- WAW hazard pair 1 ----
    // Both instructions write same dest
    li      x11, 0x1111
    li      x11, 0x2222          // WAW: second write wins
    // x11 should be 0x2222

    // ---- WAW hazard pair 2 ----
    li      x12, 0xDEAD
    li      x12, 0xBEEF          // WAW: second write wins
    // x12 should be 0xBEEF

    // ---- Verify results ----
    // x2 == 100
    li      x20, 100
    bne     x2, x20, fail

    // x4 == 250
    li      x20, 250
    bne     x4, x20, fail

    // x7 == 30
    li      x20, 30
    bne     x7, x20, fail

    // x10 == 0x11
    li      x20, 0x11
    bne     x10, x20, fail

    // x11 == 0x2222
    li      x20, 0x2222
    bne     x11, x20, fail

    // x12 == 0xBEEF
    li      x20, 0xBEEF
    bne     x12, x20, fail

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
