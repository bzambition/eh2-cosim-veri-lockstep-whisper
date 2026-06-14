// SPDX-License-Identifier: Apache-2.0
// EH2 Cosim Dual-Issue Test - Tests dual-issue pipeline ordering
//
// EH2 can retire two instructions per cycle (i0 and i1).
// This test uses instruction pairs that can dual-issue:
//   - No data dependencies between the pair
//   - No structural hazards (both using same unit)
//   - Compatible instruction types for i0/i1 slots
//
// The test verifies that results are correct regardless of
// whether instructions are single-issued or dual-issued.

.section .text.init
.globl _start

_start:
    // --- Dual-issue pairs: independent ALU operations ---
    // Pair 1: addi + addi (independent, different dest regs)
    addi    x1, x0, 10
    addi    x2, x0, 20

    // Pair 2: add + sub (independent, different dest regs)
    li      x3, 100
    li      x4, 50
    add     x5, x3, x4       // x5 = 150
    sub     x6, x3, x4       // x6 = 50

    // Pair 3: and + or (independent)
    li      x7, 0xFF00FF00
    li      x8, 0x00FF00FF
    and     x9, x7, x8       // x9 = 0x00000000
    or      x10, x7, x8      // x10 = 0xFFFFFFFF

    // Pair 4: store + ALU (store doesn't write register)
    li      x11, 0x80010000
    li      x12, 0xCAFEBABE
    sw      x12, 0(x11)      // store
    addi    x13, x0, 42      // ALU (no dependency on store)

    // Pair 5: load + ALU (ALU doesn't depend on load result)
    lw      x14, 0(x11)      // load 0xCAFEBABE
    addi    x15, x0, 99      // ALU (independent of load)

    // Pair 6: branch + ALU (branch doesn't write register)
    // Note: branch target must be aligned for dual-issue
    beq     x0, x0, 1f
    nop
1:  addi    x16, x0, 77

    // --- Verify results ---
    // x5 = 150
    li      x17, 150
    bne     x5, x17, fail

    // x6 = 50
    li      x17, 50
    bne     x6, x17, fail

    // x9 = 0
    bne     x9, x0, fail

    // x10 = 0xFFFFFFFF
    li      x17, 0xFFFFFFFF
    bne     x10, x17, fail

    // x13 = 42
    li      x17, 42
    bne     x13, x17, fail

    // x14 = 0xCAFEBABE
    li      x17, 0xCAFEBABE
    bne     x14, x17, fail

    // x15 = 99
    li      x17, 99
    bne     x15, x17, fail

    // x16 = 77
    li      x17, 77
    bne     x16, x17, fail

    // --- Stress dual-issue with a loop ---
    // Loop with independent operations that should dual-issue
    li      x18, 0
    li      x19, 100
    li      x20, 0x80010010
loop:
    addi    x18, x18, 1
    addi    x20, x20, 4
    bne     x18, x19, loop

    // x18 = 100
    li      x17, 100
    bne     x18, x17, fail

    // All checks passed
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
