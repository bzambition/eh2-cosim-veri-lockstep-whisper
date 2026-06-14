// SPDX-License-Identifier: Apache-2.0
// EH2 Directed PMP R/W/X Combinations Test
// Tests all 8 combinations of PMP R/W/X permission bits.
// cosim: enabled

.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      x31, 0

    // PMP CSR #1: region at 0x90000000 via NAPOT 4KB
    li      t0, 0x240007FF
    csrw    pmpaddr0, t0

    // PMP CSR #2: Test combination 101=X-only (no R/W, X=1)
    // NAPOT(11) + X=1 = 0x1C
    li      t0, 0x1C
    csrw    pmpcfg0, t0

    // PMP CSR #3: Reconfigure to RWX=111 (full access)
    // NAPOT + L + R=1 W=1 X=1 = 0x9F
    li      t0, 0x9F
    csrw    pmpcfg0, t0
    fence.i

    // Try execute — M-mode fetch might bypass PMP, try data access
    li      t0, 0x90000000
    lw      t1, 0(t0)

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
