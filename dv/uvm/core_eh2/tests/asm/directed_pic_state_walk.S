// SPDX-License-Identifier: Apache-2.0
// EH2 directed PIC/trap state walk.
//
// The assembly keeps M-mode interrupt/trap plumbing active while the UVM
// sequence drives +enable_irq_seq.  The ECALL path guarantees at least one
// trap entry/complete cycle even if the external IRQ pulse lands outside the
// short directed window.

.option norvc
.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0

    li      s0, 0
    li      t0, (1 << 3)        // mstatus.MIE
    csrs    mstatus, t0
    li      t0, (1 << 11)       // mie.MEIE
    csrs    mie, t0

    ecall

    li      t0, 0xCAFE
    bne     s0, t0, fail

    // Leave a few taken/not-taken branches after the trap return so IRQ
    // sideband stimulus has cycles to overlap with retirement.
    li      t1, 32
irq_wait_loop:
    addi    t1, t1, -1
    bnez    t1, irq_wait_loop

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
    li      t1, 11              // ECALL from M-mode
    beq     t0, t1, ecall_seen

    // External IRQ path: mark progress and return to interrupted PC.
    li      s0, 0xCAFE
    mret

ecall_seen:
    li      s0, 0xCAFE
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0
    mret
