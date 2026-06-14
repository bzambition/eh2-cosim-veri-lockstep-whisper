// SPDX-License-Identifier: Apache-2.0
// EH2 Directed PMP mscause Decode Test
// Tests EH2 secondary cause register (mscause) after PMP faults.
// cosim: enabled

.option norvc
.section .text.init
.globl _start

.equ CSR_MSCAUSE, 0x7FF

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      x31, 0

    // PMP CSR #1: Protect data region
    li      t0, 0x2D160000
    csrw    pmpaddr0, t0

    // PMP CSR #2: TOR + no-rwx
    li      t0, 0x08
    csrw    pmpcfg0, t0

    // PMP CSR #3: Set upper bound
    li      t0, 0x2D160400
    csrw    pmpaddr1, t0
    fence.i

    // Trigger PMP load fault
    li      t0, 0xD0580000
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
    csrr    t0, mcause
    csrr    t1, mtval
    // EH2-specific: check mscause for secondary classification.
    // GNU as does not know the EH2 CSR mnemonic, so use the numeric CSR.
    csrr    t2, CSR_MSCAUSE
    li      x31, 0xDEAD
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0
    mret
