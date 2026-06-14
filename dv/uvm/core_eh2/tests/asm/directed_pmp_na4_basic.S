// SPDX-License-Identifier: Apache-2.0
// EH2 Directed PMP NA4 Basic Test
// Tests NA4 PMP mode (naturally-aligned 4-byte region).
// cosim: enabled

.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      x31, 0

    // PMP CSR #1: pmpaddr0 = NA4 entry at 0x90000000
    // NA4: full address >> 2 (no encoding)
    li      t0, 0x24000000
    csrw    pmpaddr0, t0

    // PMP CSR #2: pmpcfg0 byte0 = NA4(10) + L(1) + no-rwx(000) = 0x90
    li      t0, 0x90
    csrw    pmpcfg0, t0

    // PMP CSR #3: pmpaddr1 = second NA4 at 0x90000004
    li      t0, 0x24000001
    csrw    pmpaddr1, t0
    fence.i

    // Access the NA4 region — should trap
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
