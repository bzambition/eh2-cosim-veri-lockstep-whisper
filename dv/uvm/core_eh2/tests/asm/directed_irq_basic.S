// SPDX-License-Identifier: Apache-2.0
// EH2 Directed IRQ Basic Test
//
// Sets up mtvec trap handler, triggers an ECALL (environment call),
// verifies trap handler catches it with correct mcause, then returns.
// This tests the basic trap/return path without depending on interrupt
// controller behavior.
// cosim: enabled

.section .text.init
.globl _start

_start:
    // Set up trap handler (direct mode)
    la      t0, trap_handler
    csrw    mtvec, t0

    // Clear flag register
    li      x31, 0

    // Trigger synchronous trap via ECALL
    ecall

    // After mret, we should land here
    // Check that trap handler set our flag
    li      t0, 0xCAFE
    bne     x31, t0, fail

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

// ---- Trap handler ----
.align 4
trap_handler:
    // Read mcause - should be 11 (ecall from M-mode)
    csrr    t0, mcause
    li      t1, 11
    bne     t0, t1, trap_unexpected

    // Read mepc (should point to ecall instruction)
    csrr    t0, mepc

    // Signal to main code that handler ran
    li      x31, 0xCAFE

    // Advance mepc past ecall (4 bytes)
    addi    t0, t0, 4
    csrw    mepc, t0

    // Return from trap
    mret

trap_unexpected:
    // Unexpected trap cause -- FAIL
    li      t0, 0xD0580000
    li      t1, 0x01
    sw      t1, 0(t0)
1:  j       1b
