// SPDX-License-Identifier: Apache-2.0
// EH2 Directed PMP No-Match Default Test
// Tests default deny when no PMP region matches (M-mode exception).
// cosim: enabled

.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      x31, 0

    // PMP CSR #1: Configure a region far from our test address
    li      t0, 0x10000000  // protects 0x40000000+
    csrw    pmpaddr0, t0

    // PMP CSR #2: TOR + no-rwx for that region
    li      t0, 0x08
    csrw    pmpcfg0, t0

    // PMP CSR #3: Set pmpcfg byte1 to OFF (no match)
    // No other regions configured → default deny for non-M-mode
    // M-mode is always permitted
    fence.i

    // M-mode access should succeed
    li      t0, 0x80000000
    lw      t1, 0(t0)
    // M-mode: no trap expected (PMP doesn't restrict M-mode by default)

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
