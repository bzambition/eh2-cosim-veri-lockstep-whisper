// SPDX-License-Identifier: Apache-2.0
// EH2 directed LSU store-buffer pressure test.

.option norvc
.section .text.init
.globl _start

_start:
    li      t0, 0xF0040000
    li      t1, 0x55AA0000
    li      t2, 64

store_pressure_loop:
    sw      t1, 0(t0)
    sw      t1, 4(t0)
    sw      t1, 8(t0)
    sw      t1, 12(t0)
    addi    t0, t0, 16
    addi    t1, t1, 1
    addi    t2, t2, -4
    bnez    t2, store_pressure_loop

    fence

    li      t0, 0xF0040000
    li      t1, 0x55AA0000
    li      t2, 16

verify_loop:
    lw      t3, 0(t0)
    bne     t3, t1, fail
    addi    t0, t0, 16
    addi    t1, t1, 1
    addi    t2, t2, -1
    bnez    t2, verify_loop

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
