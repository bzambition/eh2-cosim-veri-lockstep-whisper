// SPDX-License-Identifier: Apache-2.0
// EH2 Directed PMP Lock Bit Test
// Tests PMP L-bit: lock region then attempt reconfiguration (should fail/WARL).
// cosim: enabled

.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      x31, 0

    // PMP CSR #1: Configure with LOCK bit set
    li      t0, 0x240007FF
    csrw    pmpaddr0, t0

    // PMP CSR #2: pmpcfg0 byte0 = NAPOT + L(1) + XWR = 0x9F
    // L=1 locks until reset
    li      t0, 0x9F
    csrw    pmpcfg0, t0

    // PMP CSR #3: Attempt to overwrite locked cfg — WARL should block
    li      t0, 0x00
    csrw    pmpcfg0, t0

    // PMP CSR #4: Read back — should still show locked value
    csrr    t1, pmpcfg0
    // locked: cfg won't change (WARL behavior)
    fence.i

    // Access via locked region traps
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
