// SPDX-License-Identifier: Apache-2.0
// EH2 directed debug halt/resume stimulus.
//
// The companion UVM plusargs drive debug request pulses.  The program provides
// deterministic breakpoint/trap activity so debug entry, resume, and trap
// return windows are exercised without requiring direct access to debug CSRs.

.option norvc
.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      s0, 0

    ebreak

    li      t0, 0xDB67
    bne     s0, t0, fail

    li      t1, 64
debug_spin:
    addi    t2, t2, 1
    xor     t3, t2, t1
    addi    t1, t1, -1
    bnez    t1, debug_spin

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

.align 4
trap_handler:
    csrr    t0, mcause
    li      t1, 3               // Breakpoint
    bne     t0, t1, fail
    li      s0, 0xDB67
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0
    mret
