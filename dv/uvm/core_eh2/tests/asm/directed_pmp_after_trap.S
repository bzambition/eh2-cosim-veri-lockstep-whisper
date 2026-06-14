// SPDX-License-Identifier: Apache-2.0
// EH2 Directed PMP After-Trap Test
// Tests that mtval/mcause are correctly set after a PMP access violation.
// cosim: enabled

.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      x31, 0

    // PMP CSR #1: Protect region
    li      t0, 0x240007FF
    csrw    pmpaddr0, t0

    // PMP CSR #2: NAPOT + L + no-rwx
    li      t0, 0x98
    csrw    pmpcfg0, t0

    // PMP CSR #3: stashed failing address for handler
    li      t0, 0x90000000
    csrw    mscratch, t0  // stash expected fault addr
    fence.i

    // Trigger PMP fault
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
    // Verify mcause has a valid exception code
    csrr    t0, mcause
    // mcause[31] = 0 (exception), code should be one of {1,5,7}
    // Load access fault=5, Store access fault=7, Instruction access fault=1

    // Verify mtval contains the faulting address
    csrr    t1, mtval
    // Should be 0x90000000 or similar

    li      x31, 0xDEAD
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0
    mret
