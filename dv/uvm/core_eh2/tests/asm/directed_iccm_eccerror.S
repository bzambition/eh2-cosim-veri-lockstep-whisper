// SPDX-License-Identifier: Apache-2.0
// EH2 directed ICCM fetch/ECC error stimulus shell.
//
// The UVM side may enable memory-error injection.  The assembly repeatedly
// executes aligned code and fences instruction fetch so ICCM/IFU paths are
// active during that injection window.

.option norvc
.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      s0, 0
    fence.i

    li      t1, 32
fetch_loop:
    jal     ra, iccm_probe
    addi    t1, t1, -1
    bnez    t1, fetch_loop

    li      t0, 0x1234
    bne     s0, t0, fail

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

.align 5
iccm_probe:
    li      s0, 0x1234
    addi    s1, s1, 1
    addi    s2, s2, -1
    ret

.align 4
trap_handler:
    // If memory-error injection raises a recoverable trap, skip the faulting
    // instruction and continue.  Unexpected repeated traps will timeout rather
    // than report a false PASS.
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0
    mret
