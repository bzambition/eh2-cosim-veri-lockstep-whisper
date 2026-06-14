// SPDX-License-Identifier: Apache-2.0
// EH2 Directed PMP D-Side Store Test
// Tests PMP enforcement on data-side stores.
// cosim: enabled

.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      x31, 0

    // PMP CSR #1: Protect scratch area at 0xC0000000
    li      t0, 0x30000000
    csrw    pmpaddr0, t0

    // PMP CSR #2: TOR + W=0 X=0 R=1 = can read but not write
    li      t0, 0x0B
    csrw    pmpcfg0, t0

    // PMP CSR #3: Upper TOR bound
    li      t0, 0x30000400
    csrw    pmpaddr1, t0
    fence.i

    // Attempt store — should trap
    li      t0, 0xC0000000
    li      t1, 0xCAFE
    sw      t1, 0(t0)

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
