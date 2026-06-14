// SPDX-License-Identifier: Apache-2.0
// EH2 Directed Nested ECALL Trap Test
//
// Sets up mtvec trap handler, triggers two nested ECALLs.
// First ECALL enters trap handler which saves mepc on the stack,
// then issues a second ECALL. The second-level handler sets x30=0xBEEF,
// first-level handler sets x31=0xCAFE. Both mret back correctly.
// Verifies x30==0xBEEF && x31==0xCAFE at the end.
// cosim: enabled

.section .text.init
.globl _start

_start:
    // Set up stack pointer (use end of .bss region, _stack_top from linker)
    la      sp, _stack_top
    addi    sp, sp, 1024        // Give ourselves 1KB of stack space

    // Set up trap handler (direct mode)
    la      t0, trap_handler
    csrw    mtvec, t0

    // Clear flag registers
    li      x30, 0
    li      x31, 0

    // Clear nesting depth counter in mscratch
    li      t0, 0
    csrw    mscratch, t0

    // Trigger first-level ECALL
    ecall

    // After both levels mret, we should land here
    // Verify x30 == 0xBEEF (set by second-level handler)
    li      t0, 0xBEEF
    bne     x30, t0, fail

    // Verify x31 == 0xCAFE (set by first-level handler)
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
// Uses mscratch as nesting depth counter (0 = first level, 1 = second level)
.align 4
trap_handler:
    // Read mcause - should be 11 (ecall from M-mode)
    csrr    t0, mcause
    li      t1, 11
    bne     t0, t1, trap_unexpected

    // Read nesting depth from mscratch
    csrr    t2, mscratch

    // If depth == 0, this is the first-level trap
    bnez    t2, second_level

first_level:
    // Save mepc on stack (we need it after the nested ecall)
    csrr    t0, mepc
    addi    sp, sp, -8
    sw      t0, 0(sp)
    // Also save mstatus so nested mret works correctly
    csrr    t0, mstatus
    sw      t0, 4(sp)

    // Increment depth to 1
    li      t0, 1
    csrw    mscratch, t0

    // Advance mepc past the first ecall (so mret after second-level goes right)
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0

    // Trigger second-level ECALL from within the handler
    ecall

    // After second-level mret, we return here
    // Set first-level flag
    li      x31, 0xCAFE

    // Restore original mepc and mstatus from stack
    lw      t0, 0(sp)
    // mepc was the original ecall instruction; advance past it
    addi    t0, t0, 4
    csrw    mepc, t0
    lw      t0, 4(sp)
    csrw    mstatus, t0
    addi    sp, sp, 8

    // Reset depth to 0
    li      t0, 0
    csrw    mscratch, t0

    // Return from first-level trap
    mret

second_level:
    // Set second-level flag
    li      x30, 0xBEEF

    // Advance mepc past the second ecall
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0

    // Return from second-level trap
    mret

trap_unexpected:
    // Unexpected trap cause -- FAIL
    li      t0, 0xD0580000
    li      t1, 0x01
    sw      t1, 0(t0)
1:  j       1b
