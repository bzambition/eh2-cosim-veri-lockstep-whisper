// SPDX-License-Identifier: Apache-2.0
// EH2 Cosim Exception Compare Test — issue 51
//
// Deliberately triggers exception paths to exercise mcause/mepc
// comparison path in the cosim scoreboard:
//   1. ECALL from M-mode (mcause=11)
//   2. Illegal instruction, all-zero encoding (mcause=2)
//   3. Illegal instruction, all-one encoding (mcause=2)
//
// Each exception is caught by mtvec handler, mcause checked, mepc advanced,
// and mret returns to main flow. Cosim verifies DUT mcause/mepc match Spike.

.section .text.init
.globl _start
.option push
.option norvc

_start:
    // Set up trap handler (direct mode)
    la      t0, trap_handler
    csrw    mtvec, t0

    // ── Test 1: ECALL from M-mode ──
    li      x31, 0
    ecall
    li      t0, 0xDEAD
    bne     x31, t0, fail

    // ── Test 2: Illegal instruction ──
    li      x31, 0
    .word   0x00000000   // all-zeros = illegal RV32 encoding
    li      t0, 0xDEAD
    bne     x31, t0, fail

    // ── Test 3: Second illegal instruction encoding ──
    // EH2 supports misaligned data accesses in this configuration, so use a
    // second architecturally illegal encoding rather than assuming LW traps.
    li      x31, 0
    .word   0xffffffff   // reserved/illegal RV32 encoding
    // After mret, check handler ran
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

// ── Trap handler ──
.align 4
trap_handler:
    // Read mcause to identify exception type
    csrr    t0, mcause

    // Dispatch: expected causes are 2 and 11
    li      t1, 2     // illegal instruction
    beq     t0, t1, trap_advance
    li      t1, 11    // ECALL from M-mode
    beq     t0, t1, trap_advance

    // Unexpected exception → FAIL
    j       fail

trap_advance:
    // Signal to main code that the handler executed
    li      x31, 0xDEAD

    // Advance mepc past the faulting instruction (all are 4-byte)
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0

    mret

.option pop
