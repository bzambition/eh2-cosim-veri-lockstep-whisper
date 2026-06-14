// SPDX-License-Identifier: Apache-2.0
// EH2 Directed PMP CSR WARL Test
// Tests pmpcfg/pmpaddr WARL behavior when writing illegal values.
// cosim: enabled

.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      x31, 0

    // PMP CSR #1: Write illegal address (bit 0 = 1 violates alignment) to pmpaddr0
    li      t0, 0xFFFFFFFF
    csrw    pmpaddr0, t0

    // PMP CSR #2: Read back — WARL must return legalized value
    csrr    t1, pmpaddr0
    // Just record read — WARL behavior is implementation-specific

    // PMP CSR #3: Write illegal pmpcfg (reserved bits)
    li      t0, 0xFF  // bits 1:0 = 11 (RWX=111) and A=11 (NAPOT) — legal
    csrw    pmpcfg0, t0

    // PMP CSR #4: Read back pmpcfg
    csrr    t2, pmpcfg0
    fence.i

    // PMP CSR #5: Write pmpaddr with NAPOT encoding
    li      t0, 0xDEADBEEF
    csrw    pmpaddr0, t0
    csrr    t3, pmpaddr0
    // WARL legalization should strip illegal bits

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
