// SPDX-License-Identifier: Apache-2.0
// AXI4 data bus toggle pump for R3-B.

.option norvc
.section .text.init
.globl _start

_start:
    li      t0, 0x80010000

    li      t1, 0xAAAAAAAA
    sw      t1, 0(t0)
    li      t1, 0x55555555
    sw      t1, 4(t0)
    li      t1, 0xFF00FF00
    sw      t1, 8(t0)
    li      t1, 0x00FF00FF
    sw      t1, 12(t0)
    li      t1, 0xDEADBEEF
    sw      t1, 16(t0)
    li      t1, 0xCAFEBABE
    sw      t1, 20(t0)
    li      t1, 0x00000000
    sw      t1, 24(t0)
    li      t1, 0xFFFFFFFF
    sw      t1, 28(t0)

    li      t1, 0x55555555
    sw      t1, 0(t0)
    li      t1, 0xAAAAAAAA
    sw      t1, 4(t0)
    li      t1, 0x00FF00FF
    sw      t1, 8(t0)
    li      t1, 0xFF00FF00
    sw      t1, 12(t0)
    li      t1, 0xCAFEBABE
    sw      t1, 16(t0)
    li      t1, 0xDEADBEEF
    sw      t1, 20(t0)
    li      t1, 0xFFFFFFFF
    sw      t1, 24(t0)
    li      t1, 0x00000000
    sw      t1, 28(t0)

    fence

    lw      t2, 0(t0)
    li      t3, 0x55555555
    bne     t2, t3, fail
    lw      t2, 4(t0)
    li      t3, 0xAAAAAAAA
    bne     t2, t3, fail
    lw      t2, 8(t0)
    li      t3, 0x00FF00FF
    bne     t2, t3, fail
    lw      t2, 12(t0)
    li      t3, 0xFF00FF00
    bne     t2, t3, fail
    lw      t2, 16(t0)
    li      t3, 0xCAFEBABE
    bne     t2, t3, fail
    lw      t2, 20(t0)
    li      t3, 0xDEADBEEF
    bne     t2, t3, fail
    lw      t2, 24(t0)
    li      t3, 0xFFFFFFFF
    bne     t2, t3, fail
    lw      t2, 28(t0)
    bne     t2, zero, fail

    li      t1, 0x13579BDF
    sw      t1, 32(t0)
    li      t1, 0x2468ACE0
    sw      t1, 36(t0)
    li      t1, 0x0F0F0F0F
    sw      t1, 40(t0)
    li      t1, 0xF0F0F0F0
    sw      t1, 44(t0)
    li      t1, 0x3333CCCC
    sw      t1, 48(t0)
    li      t1, 0xCCCC3333
    sw      t1, 52(t0)
    li      t1, 0xA5A5A5A5
    sw      t1, 56(t0)
    li      t1, 0x5A5A5A5A
    sw      t1, 60(t0)

    lw      t2, 32(t0)
    xor     t4, t4, t2
    lw      t2, 36(t0)
    xor     t4, t4, t2
    lw      t2, 40(t0)
    xor     t4, t4, t2
    lw      t2, 44(t0)
    xor     t4, t4, t2
    lw      t2, 48(t0)
    xor     t4, t4, t2
    lw      t2, 52(t0)
    xor     t4, t4, t2
    lw      t2, 56(t0)
    xor     t4, t4, t2
    lw      t2, 60(t0)
    xor     t4, t4, t2

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
