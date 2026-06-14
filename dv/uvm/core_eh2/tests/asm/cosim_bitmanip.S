// SPDX-License-Identifier: Apache-2.0
// EH2 Cosim Bitmanip Test — Zba/Zbb proof test
//
// Exercises Zba (sh1add/sh2add/sh3add) and Zbb (andn/orn/xnor/clz/ctz/cpop/
// max/maxu/min/minu) instructions with deterministic data.
// Verifies cosim lockstep for bitmanip ALU operations.
// All register-to-register, no memory access exceptions possible.

.section .text.init
.globl _start

_start:
    // Load test data into registers
    li      x1, 0xAAAAAAAA
    li      x2, 0x55555555
    li      x3, 0x12345678
    li      x4, 0xDEADBEEF
    li      x5, 100
    li      x6, 200

    // ---- Zba: sh1add/sh2add/sh3add ----
    sh1add  x7, x1, x2          // x7 = (x1 << 1) + x2
    sh2add  x8, x1, x2          // x8 = (x1 << 2) + x2
    sh3add  x9, x1, x2          // x9 = (x1 << 3) + x2

    sh1add  x10, x3, x4         // x10 = (x3 << 1) + x4
    sh2add  x11, x5, x6         // x11 = (x5 << 2) + x6
    sh3add  x12, x6, x5         // x12 = (x6 << 3) + x5

    // ---- Zbb: andn/orn/xnor ----
    andn    x13, x1, x2         // x13 = x1 & ~x2
    orn     x14, x1, x2         // x14 = x1 | ~x2
    xnor    x15, x1, x2         // x15 = ~(x1 ^ x2)

    andn    x16, x3, x4
    orn     x17, x4, x3
    xnor    x18, x3, x4

    // ---- Zbb: clz/ctz/cpop ----
    clz     x19, x1             // count leading zeros
    ctz     x20, x2             // count trailing zeros
    cpop    x21, x3             // population count

    clz     x22, x4
    ctz     x23, x3
    cpop    x24, x4

    // ---- Zbb: max/maxu/min/minu ----
    li      x1, -50             // signed negative
    li      x2, 50              // signed positive
    max     x25, x1, x2         // signed max → 50
    min     x26, x1, x2         // signed min → -50
    maxu    x27, x1, x2         // unsigned max → 0xFFFFFFCE (big unsigned)
    minu    x28, x1, x2         // unsigned min → 50

    // ---- Verify critical results ----
    // max(-50, 50) should be 50
    li      x29, 50
    bne     x25, x29, fail

    // min(-50, 50) should be -50
    li      x29, -50
    bne     x26, x29, fail

    // minu(-50, 50) should be 50 (unsigned)
    li      x29, 50
    bne     x28, x29, fail

    // More operations in a chain to exercise dual-issue
    li      x1, 0xFF00FF00
    li      x2, 0x0F0F0F0F
    andn    x3, x1, x2          // 0xF000F000
    orn     x4, x2, x1          // 0x0F0FFF0F
    xnor    x5, x3, x4          // ~(0xF000F000 ^ 0x0F0FFF0F)

    sh1add  x6, x3, x4
    sh2add  x7, x4, x3
    sh3add  x8, x5, x3

    clz     x9, x6
    ctz     x10, x7
    cpop    x11, x8

    max     x12, x9, x10
    min     x13, x10, x11
    maxu    x14, x11, x9
    minu    x15, x12, x13

    // Repeat pattern to increase trace depth
    li      x1, 0x80000001
    li      x2, 0x7FFFFFFF
    andn    x3, x1, x2
    orn     x4, x2, x1
    xnor    x5, x1, x2
    sh1add  x6, x3, x4
    sh2add  x7, x4, x5
    sh3add  x8, x5, x6
    clz     x9, x1
    ctz     x10, x2
    cpop    x11, x1
    cpop    x12, x2
    max     x13, x1, x2
    min     x14, x1, x2
    maxu    x15, x1, x2
    minu    x16, x1, x2

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
