// SPDX-License-Identifier: Apache-2.0
// EH2 EXU multiply/divide toggle pump.
//
// Exercises M-extension datapaths with alternating high-activity operands so
// the R3-B structural coverage run does not rely only on random riscv-dv mix.

.option norvc
.section .text.init
.globl _start

_start:
    li      s0, 0

    li      t0, 7
    li      t1, 9
    mul     t2, t0, t1
    li      t3, 63
    bne     t2, t3, fail

    li      t0, 100
    li      t1, 7
    div     t2, t0, t1
    li      t3, 14
    bne     t2, t3, fail
    rem     t2, t0, t1
    li      t3, 2
    bne     t2, t3, fail

    li      x1,  0x00000001
    li      x2,  0x7fffffff
    mul     x3,  x1, x2
    xor     s0,  s0, x3
    mulh    x4,  x2, x2
    xor     s0,  s0, x4
    mulhu   x5,  x2, x2
    xor     s0,  s0, x5
    div     x6,  x2, x1
    xor     s0,  s0, x6
    rem     x7,  x2, x1
    xor     s0,  s0, x7

    li      x8,  0xaaaaaaaa
    li      x9,  0x55555555
    mul     x10, x8, x9
    xor     s0,  s0, x10
    mulh    x11, x8, x9
    xor     s0,  s0, x11
    mulhu   x12, x8, x9
    xor     s0,  s0, x12
    mulhsu  x13, x8, x9
    xor     s0,  s0, x13
    divu    x14, x8, x9
    xor     s0,  s0, x14
    remu    x15, x8, x9
    xor     s0,  s0, x15

    li      x16, 0xffffffff
    li      x17, 0x00010001
    mul     x18, x16, x17
    xor     s0,  s0, x18
    mulh    x19, x16, x17
    xor     s0,  s0, x19
    mulhu   x20, x16, x17
    xor     s0,  s0, x20
    div     x21, x16, x17
    xor     s0,  s0, x21
    rem     x22, x16, x17
    xor     s0,  s0, x22

    li      x23, 0x12345678
    li      x24, 0x00000f0f
    mul     x25, x23, x24
    xor     s0,  s0, x25
    mulh    x26, x23, x24
    xor     s0,  s0, x26
    mulhu   x27, x23, x24
    xor     s0,  s0, x27
    divu    x28, x23, x24
    xor     s0,  s0, x28
    remu    x29, x23, x24
    xor     s0,  s0, x29

    li      t0, 0x80000000
    li      t1, 0x00000003
    div     t2, t0, t1
    xor     s0, s0, t2
    rem     t3, t0, t1
    xor     s0, s0, t3
    divu    t4, t0, t1
    xor     s0, s0, t4
    remu    t5, t0, t1
    xor     s0, s0, t5

    li      t0, 0x13579bdf
    li      t1, 0x2468ace1
    mul     t2, t0, t1
    xor     s0, s0, t2
    mulh    t3, t0, t1
    xor     s0, s0, t3
    mulhu   t4, t0, t1
    xor     s0, s0, t4
    mulhsu  t5, t0, t1
    xor     s0, s0, t5
    divu    t6, t1, t0
    xor     s0, s0, t6

    li      t0, 0xf0040000
    sw      s0, 0(t0)
    lw      t1, 0(t0)
    bne     t1, s0, fail

pass:
    li      t0, 0xD0580000
    li      t1, 0xFF
    sw      t1, 0(t0)
done:
    j       done

fail:
    li      t0, 0xD0580000
    li      t1, 0x01
    sw      t1, 0(t0)
    j       done
