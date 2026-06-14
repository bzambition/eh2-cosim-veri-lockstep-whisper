// SPDX-License-Identifier: Apache-2.0
// EH2 Directed PMP Priority Test
// Tests multi-region priority: low-index region takes precedence.
// cosim: enabled

.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      x31, 0

    // PMP CSR #1: region 0 covers 0x90000000-0x90001000 NAPOT, no access
    li      t0, 0x240007FF
    csrw    pmpaddr0, t0

    // PMP CSR #2: pmpcfg0 byte0 = NAPOT(11) + L(0) + no-rwx = 0x18
    li      t0, 0x18
    csrw    pmpcfg0, t0

    // PMP CSR #3: region 1 covers 0x90000000-0x90010000 NAPOT, full access
    // Overlaps region0; region0 should win (lower index)
    li      t0, 0x24003FFF
    csrw    pmpaddr1, t0
    li      t0, 0x1F00  // byte1=NAPOT+RWX
    csrw    pmpcfg0, t0
    fence.i

    // Access overlapping address — region0 should block
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
