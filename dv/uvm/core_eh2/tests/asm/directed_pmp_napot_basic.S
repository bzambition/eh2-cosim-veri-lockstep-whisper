// SPDX-License-Identifier: Apache-2.0
// EH2 Directed PMP NAPOT Basic Test
// Tests NAPOT PMP mode with sizes 4B, 16B, 256B, 4KB.
// cosim: enabled

.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      x31, 0

    // PMP CSR #1: pmpaddr0 = NAPOT 4KB at 0x90000000
    // NAPOT 4KB: (base>>2) | ((4096/2 - 1)>>2) = 0x24000000 | 0x7FF
    li      t0, 0x240007FF
    csrw    pmpaddr0, t0

    // PMP CSR #2: pmpcfg0 byte0 = NAPOT(11) + L(1) + W=0 R=0 X=0 = 0x98
    li      t0, 0x98
    csrw    pmpcfg0, t0

    // PMP CSR #3: Reconfigure for 16B NAPOT at 0x90001000
    // pmpaddr1 = (0x90001000>>2) | ((16/2 - 1)>>2) = 0x24000400 | 0x3
    li      t0, 0x24000403
    csrw    pmpaddr1, t0
    fence.i

    // Attempt access in 4KB NAPOT region → trap
    li      t0, 0x90000000
    lw      t1, 0(t0)

    li      t0, 0xDEAD
    beq     x31, t0, pass

    // No trap: try 16B region
    li      t0, 0x90001000
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
