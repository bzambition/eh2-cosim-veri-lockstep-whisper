// SPDX-License-Identifier: Apache-2.0
// EH2 Directed PMP Cross-Region Test
// Tests load/store that spans across two PMP region boundaries.
// cosim: enabled

.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      x31, 0

    // PMP CSR #1: region0 NAPOT 4B at 0x90000000 — no access
    li      t0, 0x24000000
    csrw    pmpaddr0, t0

    // PMP CSR #2: NAPOT 4B + no-rwx
    li      t0, 0x18
    csrw    pmpcfg0, t0

    // PMP CSR #3: region1 at 0x90000004 — full access
    li      t0, 0x24000001
    csrw    pmpaddr1, t0
    li      t0, 0x1F00  // byte1=NAPOT+RWX
    csrw    pmpcfg0, t0
    fence.i

    // Access at 0x90000000 (region0 boundary)
    li      t0, 0x90000000
    lw      t1, 0(t0)   // 4-byte load crosses into region1

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
