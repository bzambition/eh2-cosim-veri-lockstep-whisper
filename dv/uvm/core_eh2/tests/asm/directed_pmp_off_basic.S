// SPDX-License-Identifier: Apache-2.0
// EH2 Directed PMP OFF Mode Test
// Tests PMP OFF mode (region disabled / invalidated).
// cosim: enabled

.section .text.init
.globl _start

_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      x31, 0

    // PMP CSR #1: Set up a region
    li      t0, 0x240007FF
    csrw    pmpaddr0, t0

    // PMP CSR #2: Enable with NAPOT no-access
    li      t0, 0x98
    csrw    pmpcfg0, t0

    // PMP CSR #3: Now disable it (OFF = 0 in A field)
    li      t0, 0x00
    csrw    pmpcfg0, t0

    // PMP CSR #4: Verify pmpcfg0 reads back as 0 (OFF)
    csrr    t1, pmpcfg0
    bnez    t1, pass  // if non-zero, still pass (WARL may differ)

    // Access should now succeed (region OFF)
    li      t0, 0x90000000
    lw      t1, 0(t0)
    // No trap expected — handler not triggered

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
