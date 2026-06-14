// SPDX-License-Identifier: Apache-2.0
// EH2 Cosim Atomic Basic Test — issue 52
//
// Exercises LR/SC lock acquire-release loop and 4 AMO arithmetic ops
// with cosim lockstep. Verifies:
//   1. LR.W loads reservation address value
//   2. SC.W succeeds on uncontended reservation (rd=0)
//   3. AMOSWAP.W atomically swaps register and memory
//   4. AMOADD.W atomically adds to memory
//   5. AMOXOR.W atomically XORs memory
//   6. AMOAND.W atomically ANDs memory
//   7. Mailbox PASS if all checks pass

.section .text.init
.globl _start

_start:
    // ── Test 1: LR/SC lock acquire-release ──
    // EH2 atomics operate against DCCM. Avoid regular stores for setup so the
    // cosim scoreboard does not require an external AXI write notification.
    li      t0, 0xF0040000
1:  lr.w    t1, (t0)        // Load reservation
    bne     t1, zero, 1b    // Not free, retry
    li      t2, 1
    sc.w    t3, t2, (t0)    // Try to acquire (rd=0 means success)
    bne     t3, zero, 1b    // Failed, retry

    // Verify lock was acquired (lock_word should now be 1)
    lw      t4, 0(t0)
    li      t5, 1
    bne     t4, t5, fail

    // Release lock
    amoswap.w x0, zero, (t0)

    // ── Test 2: AMOSWAP.W ──
    li      t0, 0xF0040004
    li      t1, 0xDEADBEEF
    amoswap.w x0, t1, (t0)   // Initialize memory without a plain store
    li      t1, 0xDEADBEEF
    li      t2, 0xCAFEBABE
    amoswap.w t3, t2, (t0)   // Atomically swap: t3=old, mem=new
    // t3 should be 0xDEADBEEF (old value)
    li      t4, 0xDEADBEEF
    bne     t3, t4, fail
    // Memory should now be 0xCAFEBABE
    lw      t5, 0(t0)
    li      t6, 0xCAFEBABE
    bne     t5, t6, fail

    // ── Test 3: AMOADD.W ──
    li      t1, 100
    amoswap.w x0, t1, (t0)   // mem = 100
    li      t2, 25
    amoadd.w t3, t2, (t0)    // t3=100 (old), mem=125 (new)
    li      t4, 100
    bne     t3, t4, fail
    lw      t5, 0(t0)
    li      t6, 125
    bne     t5, t6, fail

    // ── Test 4: AMOXOR.W ──
    li      t1, 0x0F0F0F0F
    amoswap.w x0, t1, (t0)   // mem = 0x0F0F0F0F
    li      t2, 0xF0F0F0F0
    amoxor.w t3, t2, (t0)    // t3=0x0F0F0F0F, mem=0xFFFFFFFF
    li      t4, 0x0F0F0F0F
    bne     t3, t4, fail
    lw      t5, 0(t0)
    li      t6, 0xFFFFFFFF
    bne     t5, t6, fail

    // ── Test 5: AMOAND.W ──
    li      t1, 0xFF00FF00
    amoswap.w x0, t1, (t0)   // mem = 0xFF00FF00
    li      t2, 0x0F0F0F0F
    amoand.w t3, t2, (t0)    // t3=0xFF00FF00, mem=0x0F000F00
    li      t4, 0xFF00FF00
    bne     t3, t4, fail
    lw      t5, 0(t0)
    li      t6, 0x0F000F00
    bne     t5, t6, fail

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
