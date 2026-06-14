// SPDX-License-Identifier: Apache-2.0
// EH2 Directed AXI4 Error Injection Test
//
// Verifies that AXI4 bus error responses (SLVERR/DECERR) are
// correctly propagated to the core as load access faults (mcause=5).
//
// This test must be run with:
//   +enable_axi4_error_inject=1 +axi4_error_pct=100
// to guarantee error injection on every LSU AXI4 transaction.
//
// Flow:
//   1. Set up mtvec trap handler
//   2. Attempt a load from external memory (AXI4 bus)
//   3. AXI4 driver injects error response -> core takes access fault
//   4. Trap handler checks mcause==5 (load access fault)
//   5. If correct, writes PASS to mailbox
//
// cosim: disabled (error injection alters bus behavior)

.section .text.init
.globl _start

_start:
    // Set up trap handler (direct mode)
    la      t0, trap_handler
    csrw    mtvec, t0

    // Clear flag register
    li      x31, 0

    // ---- Attempt a load from external memory ----
    // Address 0x90000000 is in external AXI4 address space.
    // With error injection enabled, the AXI4 slave will respond
    // with SLVERR or DECERR, causing a load access fault.
    li      t0, 0x90000000
    lw      t1, 0(t0)          // Should trap with mcause=5

    // If we reach here, either:
    //   a) Error injection didn't fire (shouldn't happen at 100%)
    //   b) Core didn't trap on bus error (unexpected)
    // Check if trap handler ran
    li      t0, 0xBEEF
    beq     x31, t0, pass

    // No trap fired -- FAIL
    j       fail

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

// ---- Trap handler ----
.align 4
trap_handler:
    // Read mcause
    csrr    t0, mcause

    // Check for load access fault (mcause=5)
    li      t1, 5
    beq     t0, t1, trap_load_access_fault

    // Check for store/AMO access fault (mcause=7)
    // This can happen if error injection hits a store
    li      t1, 7
    beq     t0, t1, trap_store_access_fault

    // Unexpected trap cause
    j       trap_unexpected

trap_load_access_fault:
    // Expected path: load access fault from AXI4 error injection
    // Set flag to signal success
    li      x31, 0xBEEF

    // Advance mepc past the faulting load (4 bytes)
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0

    // Return from trap
    mret

trap_store_access_fault:
    // Store access fault can happen when error injection hits the
    // mailbox write. Just skip past it and continue.
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0
    mret

trap_unexpected:
    // Unexpected trap cause -- FAIL
    li      t0, 0xD0580000
    li      t1, 0x01
    sw      t1, 0(t0)
1:  j       1b
