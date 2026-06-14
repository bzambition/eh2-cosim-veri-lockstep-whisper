// SPDX-License-Identifier: Apache-2.0
// EH2 Cosim Load/Store Test - Memory access instructions
//
// Tests: lb, lh, lw, lbu, lhu, sb, sh, sw
// Uses a small data region in memory for test values.

.section .text.init
.globl _start

_start:
    // --- Store operations ---
    li      t0, 0x80010000      // Test data region

    // Store word
    li      t1, 0xDEADBEEF
    sw      t1, 0(t0)

    // Store halfword
    li      t2, 0x1234
    sh      t2, 4(t0)

    // Store byte
    li      t3, 0xAB
    sb      t3, 6(t0)

    // --- Load operations (aligned) ---
    // Load word
    lw      t4, 0(t0)
    li      t5, 0xDEADBEEF
    bne     t4, t5, fail

    // Load halfword (signed)
    lh      t4, 4(t0)
    li      t5, 0x1234
    bne     t4, t5, fail

    // Load halfword unsigned
    lhu     t4, 4(t0)
    li      t5, 0x1234
    bne     t4, t5, fail

    // Load byte (signed)
    lb      t4, 6(t0)
    li      t5, 0xFFFFFFAB    // sign-extended 0xAB
    bne     t4, t5, fail

    // Load byte unsigned
    lbu     t4, 6(t0)
    li      t5, 0xAB
    bne     t4, t5, fail

    // --- Byte-addressable load from word ---
    // Load individual bytes from stored 0xDEADBEEF
    lbu     t4, 0(t0)         // byte 0 = 0xEF (little-endian)
    li      t5, 0xEF
    bne     t4, t5, fail

    lbu     t4, 1(t0)         // byte 1 = 0xBE
    li      t5, 0xBE
    bne     t4, t5, fail

    lbu     t4, 2(t0)         // byte 2 = 0xAD
    li      t5, 0xAD
    bne     t4, t5, fail

    lbu     t4, 3(t0)         // byte 3 = 0xDE
    li      t5, 0xDE
    bne     t4, t5, fail

    // --- Negative values (sign extension) ---
    li      t1, 0xFFFF8000    // -32768
    sh      t1, 8(t0)
    lh      t4, 8(t0)
    li      t5, 0xFFFF8000
    bne     t4, t5, fail

    // --- Store/load with register+offset ---
    li      t1, 0x12345678
    li      t2, 16
    add     t3, t0, t2        // t3 = t0 + 16
    sw      t1, 0(t3)
    lw      t4, 0(t3)
    bne     t4, t1, fail

    // All checks passed
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

.section .data
.align 4
    .space 256  // Data region for test values
_stack_top:
