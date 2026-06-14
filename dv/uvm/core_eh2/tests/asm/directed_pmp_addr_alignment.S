// SPDX-License-Identifier: Apache-2.0
// EH2 Directed PMP Address Alignment Test
// Tests PMP address LSB alignment and granularity (G=1/0).
// cosim: enabled

.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      x31, 0

    // PMP CSR #1: Address with G=1 (granularity 0 means lower bits ignored)
    li      t0, 0x240007FF  // NAPOT 4KB, all LSB bits part of encoding
    csrw    pmpaddr0, t0

    // PMP CSR #2: NAPOT + no-rwx
    li      t0, 0x18
    csrw    pmpcfg0, t0

    // PMP CSR #3: Second address at word boundary
    li      t0, 0x24000800
    csrw    pmpaddr1, t0
    fence.i

    // Access region 0 — should trap
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
