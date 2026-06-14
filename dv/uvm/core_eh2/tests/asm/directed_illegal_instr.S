// SPDX-License-Identifier: Apache-2.0
// EH2 Directed Illegal Instruction Test
//
// Sets up mtvec trap handler, executes an illegal instruction (.word 0x00000000),
// verifies trap handler catches it with mcause=2 (illegal instruction),
// advances mepc past the faulting 4-byte word, then mrets.
// cosim: enabled

.section .text.init
.globl _start

_start:
    // Set up trap handler (direct mode)
    la      t0, trap_handler
    csrw    mtvec, t0

    // Clear flag register
    li      x31, 0

    // Execute an illegal instruction (all-zeros is not a valid RV32 encoding)
    .word   0x00000000

    // After mret, we should land here
    // Check that trap handler set our flag
    li      t0, 0xDEAD
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
    // Read mcause - should be 2 (illegal instruction)
    csrr    t0, mcause
    li      t1, 2
    bne     t0, t1, trap_unexpected

    // Signal to main code that handler ran
    li      x31, 0xDEAD

    // Skip the faulting instruction (4 bytes for .word)
    csrr    t0, mepc
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
