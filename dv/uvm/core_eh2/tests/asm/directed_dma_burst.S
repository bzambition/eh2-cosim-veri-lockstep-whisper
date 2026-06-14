// SPDX-License-Identifier: Apache-2.0
// EH2 directed DMA-like memory burst.
//
// EH2's DMA/debug command path is stimulated from UVM when enabled.  This
// program creates a dense aligned memory burst so LSU/AXI memory FSMs also see
// sustained write and read traffic.

.option norvc
.section .text.init
.globl _start

_start:
    la      t0, burst_buf
    li      t1, 0x1000
    li      t2, 32

store_loop:
    sw      t1, 0(t0)
    addi    t1, t1, 3
    addi    t0, t0, 4
    addi    t2, t2, -1
    bnez    t2, store_loop

    fence

    la      t0, burst_buf
    li      t1, 0x1000
    li      t2, 32

load_loop:
    lw      t3, 0(t0)
    bne     t3, t1, fail
    addi    t1, t1, 3
    addi    t0, t0, 4
    addi    t2, t2, -1
    bnez    t2, load_loop

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

.section .data
.balign 64
burst_buf:
    .space 128
