// SPDX-License-Identifier: Apache-2.0
// CSR toggle pump for R3-B.

.option norvc
.section .text.init
.globl _start

.equ CSR_MSCAUSE,      0x7FF
.equ CSR_MRAC,         0x7C0
.equ CSR_MFDC,         0x7F9
.equ CSR_MCYCLE,       0xB00
.equ CSR_MINSTRET,     0xB02
.equ CSR_MHPMCOUNTER3, 0xB03

_start:
    la      t4, csr_shadow

    li      t0, 0xAAAAAAAA
    csrrw   zero, mstatus, t0
    csrr    t1, mstatus
    sw      t1, 0(t4)
    li      t0, 0x55555555
    csrrw   zero, mstatus, t0
    csrr    t1, mstatus
    sw      t1, 4(t4)

    li      t0, 0xAAAAAAAA
    csrrw   zero, mie, t0
    csrr    t1, mie
    sw      t1, 8(t4)
    li      t0, 0x55555555
    csrrw   zero, mie, t0
    csrr    t1, mie
    sw      t1, 12(t4)

    li      t0, 0xAAAAAAAA
    csrrw   zero, mip, t0
    csrr    t1, mip
    sw      t1, 16(t4)
    li      t0, 0x55555555
    csrrw   zero, mip, t0
    csrr    t1, mip
    sw      t1, 20(t4)

    li      t0, 0x80000080
    csrrw   zero, mtvec, t0
    csrr    t1, mtvec
    sw      t1, 24(t4)
    li      t0, 0x80000100
    csrrw   zero, mtvec, t0
    csrr    t1, mtvec
    sw      t1, 28(t4)

    li      t0, 0xAAAAAAAA
    csrrw   zero, mscratch, t0
    csrr    t1, mscratch
    sw      t1, 32(t4)
    li      t0, 0x55555555
    csrrw   zero, mscratch, t0
    csrr    t1, mscratch
    sw      t1, 36(t4)

    li      t0, 0x80002000
    csrrw   zero, mepc, t0
    csrr    t1, mepc
    sw      t1, 40(t4)
    li      t0, 0x80003000
    csrrw   zero, mepc, t0
    csrr    t1, mepc
    sw      t1, 44(t4)

    li      t0, 0x0000000B
    csrrw   zero, mcause, t0
    csrr    t1, mcause
    sw      t1, 48(t4)
    li      t0, 0x00000003
    csrrw   zero, mcause, t0
    csrr    t1, mcause
    sw      t1, 52(t4)

    li      t0, 0xAAAAAAAA
    csrrw   zero, mtval, t0
    csrr    t1, mtval
    sw      t1, 56(t4)
    li      t0, 0x55555555
    csrrw   zero, mtval, t0
    csrr    t1, mtval
    sw      t1, 60(t4)

    li      t0, 0xAAAAAAAA
    csrrw   zero, CSR_MSCAUSE, t0
    csrr    t1, CSR_MSCAUSE
    sw      t1, 64(t4)
    li      t0, 0x55555555
    csrrw   zero, CSR_MSCAUSE, t0
    csrr    t1, CSR_MSCAUSE
    sw      t1, 68(t4)

    li      t0, 0xAAAAAAAA
    csrrw   zero, CSR_MRAC, t0
    csrr    t1, CSR_MRAC
    sw      t1, 72(t4)
    li      t0, 0x55555555
    csrrw   zero, CSR_MRAC, t0
    csrr    t1, CSR_MRAC
    sw      t1, 76(t4)

    li      t0, 0xAAAAAAAA
    csrrw   zero, CSR_MFDC, t0
    csrr    t1, CSR_MFDC
    sw      t1, 80(t4)
    li      t0, 0x55555555
    csrrw   zero, CSR_MFDC, t0
    csrr    t1, CSR_MFDC
    sw      t1, 84(t4)

    li      t0, 0xAAAAAAAA
    csrrw   zero, CSR_MCYCLE, t0
    csrr    t1, CSR_MCYCLE
    sw      t1, 88(t4)
    li      t0, 0x55555555
    csrrw   zero, CSR_MCYCLE, t0
    csrr    t1, CSR_MCYCLE
    sw      t1, 92(t4)

    li      t0, 0xAAAAAAAA
    csrrw   zero, CSR_MINSTRET, t0
    csrr    t1, CSR_MINSTRET
    sw      t1, 96(t4)
    li      t0, 0x55555555
    csrrw   zero, CSR_MINSTRET, t0
    csrr    t1, CSR_MINSTRET
    sw      t1, 100(t4)

    li      t0, 0xAAAAAAAA
    csrrw   zero, CSR_MHPMCOUNTER3, t0
    csrr    t1, CSR_MHPMCOUNTER3
    sw      t1, 104(t4)
    li      t0, 0x55555555
    csrrw   zero, CSR_MHPMCOUNTER3, t0
    csrr    t1, CSR_MHPMCOUNTER3
    sw      t1, 108(t4)

pass:
    li      t0, 0xD0580000
    li      t1, 0xFF
    sw      t1, 0(t0)
done:
    j       done

fail:
    li      t0, 0xD0580000
    li      t1, 0x01
    sw      t1, 0(t0)
    j       done

.section .data
.balign 64
csr_shadow:
    .space 128
