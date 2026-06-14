// SPDX-License-Identifier: Apache-2.0
// EH2 Cosim Smoke Test - Minimal test to verify cosim loop
//
// Just writes PASS (0xFF) to the mailbox address.
// Verifies: basic fetch, decode, execute, store pipeline.

.section .text.init
.globl _start

_start:
    // Write 0xFF to mailbox (0xD0580000) = PASS
    li      t0, 0xD0580000
    li      t1, 0xFF
    sw      t1, 0(t0)

    // Loop forever (halt via debug or timeout)
1:  j       1b
