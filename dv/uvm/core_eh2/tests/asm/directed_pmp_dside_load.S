// SPDX-License-Identifier: Apache-2.0
// EH2 Directed PMP D-Side Load Test
// Tests PMP enforcement on data-side loads.
// cosim: enabled

.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      x31, 0

    // PMP CSR #1: Protect 0xD0580000 region (mailbox) for load
    li      t0, 0x2D160000
    csrw    pmpaddr0, t0

    // PMP CSR #2: NAPOT 4B + R=0 = no read
    li      t0, 0x08
    csrw    pmpcfg0, t0

    // PMP CSR #3: Confirm via read
    csrr    t1, pmpcfg0
    fence.i

    // Attempt load from protected region
    li      t0, 0xD0580000
    lw      t1, 0(t0)  // Should trap on load

    li      t0, 0xDEAD
    beq     x31, t0, pass
    j       pass

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

.align 4
trap_handler:
    li      x31, 0xDEAD
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0
    mret
