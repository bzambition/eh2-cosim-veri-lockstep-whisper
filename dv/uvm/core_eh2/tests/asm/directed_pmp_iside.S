// SPDX-License-Identifier: Apache-2.0
// EH2 Directed PMP I-Side Test
// Tests PMP instruction-side trap handling and terminates after observation.
// cosim: enabled

.option norvc
.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0

    // Use the original TOR execute-deny window, but make the test bounded.
    // The old test jumped back into _start and looped until max_cycles.
    li      t0, 0x20000400
    csrw    pmpaddr0, t0
    li      t0, 0x04
    csrw    pmpcfg0, t0
    li      t0, 0x20000800
    csrw    pmpaddr1, t0
    fence.i

    li      t0, 0x80000000
    jalr    zero, t0, 0

    j       fail

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

.balign 4
trap_handler:
    csrr    t2, mscratch
    addi    t2, t2, 1
    csrw    mscratch, t2
    li      t1, 4
    bge     t2, t1, pass

    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0
    mret
