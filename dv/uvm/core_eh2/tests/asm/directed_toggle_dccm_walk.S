// SPDX-License-Identifier: Apache-2.0
// DCCM byte/halfword/word toggle pump for R3-B.

.option norvc
.section .text.init
.globl _start

_start:
    li      t0, 0xF0040000

    li      t1, 0x00000001
    sb      t1, 0(t0)
    lbu     t2, 0(t0)
    li      t3, 0x01
    bne     t2, t3, fail
    lb      t2, 0(t0)
    bne     t2, t3, fail

    li      t1, 0x000000FE
    sb      t1, 4(t0)
    lbu     t2, 4(t0)
    li      t3, 0xFE
    bne     t2, t3, fail
    lb      t2, 4(t0)
    li      t3, 0xFFFFFFFE
    bne     t2, t3, fail

    li      t1, 0x00001234
    sh      t1, 8(t0)
    lhu     t2, 8(t0)
    li      t3, 0x1234
    bne     t2, t3, fail
    lh      t2, 8(t0)
    bne     t2, t3, fail

    li      t1, 0x00008001
    sh      t1, 12(t0)
    lhu     t2, 12(t0)
    li      t3, 0x8001
    bne     t2, t3, fail
    lh      t2, 12(t0)
    li      t3, 0xFFFF8001
    bne     t2, t3, fail

    li      t1, 0xAAAAAAAA
    sw      t1, 16(t0)
    lw      t2, 16(t0)
    bne     t2, t1, fail
    li      t1, 0x55555555
    sw      t1, 16(t0)
    lw      t2, 16(t0)
    bne     t2, t1, fail

    li      t1, 0xFF00FF00
    sw      t1, 20(t0)
    lw      t2, 20(t0)
    bne     t2, t1, fail
    li      t1, 0x00FF00FF
    sw      t1, 20(t0)
    lw      t2, 20(t0)
    bne     t2, t1, fail

    li      t1, 0x00000001
    sw      t1, 24(t0)
    li      t2, 31
walk_one_loop:
    sll     t3, t1, t2
    sw      t3, 24(t0)
    lw      t4, 24(t0)
    bne     t4, t3, fail
    addi    t2, t2, -4
    bgez    t2, walk_one_loop

    li      t1, 0xFFFFFFFE
    sw      t1, 28(t0)
    li      t2, 0
walk_zero_loop:
    li      t3, 1
    sll     t3, t3, t2
    not     t3, t3
    sw      t3, 28(t0)
    lw      t4, 28(t0)
    bne     t4, t3, fail
    addi    t2, t2, 4
    li      t5, 32
    blt     t2, t5, walk_zero_loop

    li      t1, 0xDEADBEEF
    sw      t1, 0(t0)
    lbu     t2, 0(t0)
    lbu     t3, 1(t0)
    lbu     t4, 2(t0)
    lbu     t5, 3(t0)
    xor     t6, t2, t3
    xor     t6, t6, t4
    xor     t6, t6, t5

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
