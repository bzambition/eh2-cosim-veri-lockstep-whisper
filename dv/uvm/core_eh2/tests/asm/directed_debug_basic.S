// SPDX-License-Identifier: Apache-2.0
// EH2 Directed Debug Basic Test (EBREAK)
//
// Sets up mtvec trap handler, executes an EBREAK instruction.
// In M-mode, EBREAK triggers mcause=3 (breakpoint exception).
// Trap handler catches it, advances mepc past the EBREAK (4 bytes for
// the 32-bit encoding), and mrets.
// Verifies the handler actually ran.
// cosim: enabled

.section .text.init
.globl _start

_start:
    // Set up trap handler (direct mode)
    la      t0, trap_handler
    csrw    mtvec, t0

    // Clear flag register
    li      x31, 0

    // Execute EBREAK -- should trap with mcause=3
    ebreak

    // After mret, we should land here
    // Check that trap handler set our flag
    li      t0, 0xBEEF
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
    // Read mcause - should be 3 (breakpoint)
    csrr    t0, mcause
    li      t1, 3
    bne     t0, t1, trap_unexpected

    // Signal to main code that handler ran
    li      x31, 0xBEEF

    // Determine instruction length at mepc to skip correctly.
    // RISC-V: if bits [1:0] of the instruction != 0b11, it's a 16-bit
    // compressed instruction; otherwise it's 32-bit.
    csrr    t0, mepc
    lhu     t1, 0(t0)          // load halfword at mepc
    andi    t2, t1, 0x3        // check bits [1:0]
    li      t3, 0x3
    bne     t2, t3, skip_2     // compressed: skip 2 bytes

skip_4:
    // 32-bit instruction: advance mepc by 4
    addi    t0, t0, 4
    j       write_mepc

skip_2:
    // 16-bit compressed instruction: advance mepc by 2
    addi    t0, t0, 2

write_mepc:
    csrw    mepc, t0

    // Return from trap
    mret

trap_unexpected:
    // Unexpected trap cause -- FAIL
    li      t0, 0xD0580000
    li      t1, 0x01
    sw      t1, 0(t0)
1:  j       1b
