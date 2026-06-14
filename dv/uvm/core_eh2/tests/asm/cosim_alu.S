// SPDX-License-Identifier: Apache-2.0
// EH2 Cosim ALU Test - Deterministic ALU instructions
//
// Tests: addi, add, sub, and, or, xor, sll, srl, sra, slt, sltu
// Each instruction writes a known result to a register.
// Final check: if all results match expected, write PASS.

.section .text.init
.globl _start

_start:
    // x0 is hardwired to 0
    // Use x1-x10 for results, x11-x15 for expected values

    // --- Immediate instructions ---
    li      x1, 0x12345678
    addi    x2, x1, 0x10        // x2 = 0x12345688
    addi    x3, x1, -1          // x3 = 0x12345677

    // --- Register-register arithmetic ---
    li      x4, 0xAAAAAAAA
    li      x5, 0x55555555
    add     x6, x4, x5          // x6 = 0xFFFFFFFF
    sub     x7, x4, x5          // x7 = 0x55555555

    // --- Bitwise operations ---
    and     x8, x4, x5          // x8 = 0x00000000
    or      x9, x4, x5          // x9 = 0xFFFFFFFF
    xor     x10, x4, x5         // x10 = 0xFFFFFFFF

    // --- Shift operations ---
    li      x11, 0x00000001
    sll     x12, x11, x11       // x12 = 0x00000002 (shift left by 1)
    li      x13, 0x80000000
    srl     x14, x13, x11       // x14 = 0x40000000 (logical right by 1)
    sra     x15, x13, x11       // x15 = 0xC0000000 (arithmetic right by 1)

    // --- Set less than ---
    li      x16, -1
    li      x17, 1
    slt     x18, x16, x17       // x18 = 1 (signed: -1 < 1)
    sltu    x19, x16, x17       // x19 = 0 (unsigned: 0xFFFFFFFF > 1)

    // --- Verify results ---
    // x2 should be 0x12345688
    li      x20, 0x12345688
    bne     x2, x20, fail

    // x6 should be 0xFFFFFFFF
    li      x20, 0xFFFFFFFF
    bne     x6, x20, fail

    // x10 should be 0xFFFFFFFF
    bne     x10, x20, fail

    // x15 should be 0xC0000000
    li      x20, 0xC0000000
    bne     x15, x20, fail

    // x18 should be 1
    li      x20, 1
    bne     x18, x20, fail

    // x19 should be 0
    bne     x19, x0, fail

pass:
    // Write PASS to mailbox
    li      t0, 0xD0580000
    li      t1, 0xFF
    sw      t1, 0(t0)
    j       done

fail:
    // Write FAIL to mailbox
    li      t0, 0xD0580000
    li      t1, 0x01
    sw      t1, 0(t0)

done:
    // Loop forever
1:  j       1b
