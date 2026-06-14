// SPDX-License-Identifier: Apache-2.0
// EH2 directed IFU branch predictor / BTB walk.

.option norvc
.section .text.init
.globl _start

_start:
    li      s0, 0
    li      t0, 96

branch_train_loop:
    addi    s0, s0, 1
    andi    t1, s0, 3
    beqz    t1, taken_path

not_taken_path:
    addi    t2, t2, 5
    j       join_path

taken_path:
    addi    t2, t2, 7

join_path:
    addi    t0, t0, -1
    bnez    t0, branch_train_loop

    jal     ra, call_target_a
    jal     ra, call_target_b
    jal     ra, call_target_a

    li      t0, 96
    bne     s0, t0, fail

pass:
    li      t0, 0xD0580000
    li      t1, 0xFF
    sw      t1, 0(t0)
done:
    j       done

call_target_a:
    addi    t4, t4, 1
    ret

call_target_b:
    addi    t4, t4, 2
    ret

fail:
    li      t0, 0xD0580000
    li      t1, 0x01
    sw      t1, 0(t0)
    j       done
