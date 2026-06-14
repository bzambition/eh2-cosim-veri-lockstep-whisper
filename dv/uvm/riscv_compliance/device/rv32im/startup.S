// SPDX-License-Identifier: Apache-2.0
// EH2 RV32I Compliance Startup Code (issue 57)
//
// _start at 0x80000000: init mtvec, clear BSS, call test_entry.
// After test returns, stream signature as 32-bit hex words
// through the compliance mailbox (0xD0580000).
//
// Trap handler reports FAIL to mailbox.

.section .text.init
.align 2

// ---------------------------------------------------------------------------
// _start — entry point at reset (first at boot address)
// ---------------------------------------------------------------------------
.globl _start
_start:
    la   t0, trap_vector
    csrw mtvec, t0
    // Clear BSS
    la   t0, _bss_start
    la   t1, _bss_end
1:  bge  t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:  jal  ra, test_entry
    // Fall through to signature_dump if test returns via ret

// ---------------------------------------------------------------------------
// signature_dump — write 32-bit words as 8-char hex strings via mailbox
// ---------------------------------------------------------------------------
.globl signature_dump
signature_dump:
    lui  s0, 0xD0580            // s0 = mailbox base
    la   t0, begin_signature
    la   t1, end_signature
sig_loop:
    bge  t0, t1, sig_done
    lw   t2, 0(t0)              // load 32-bit word
    // Write as 8 hex chars
    // Word goes MSB-first in the hex output (like reference format)
    srli t3, t2, 28              // nibble 7
    andi t3, t3, 0xF
    jal  ra, hex_nibble
    sw   t3, 0(s0)
    srli t3, t2, 24              // nibble 6
    andi t3, t3, 0xF
    jal  ra, hex_nibble
    sw   t3, 0(s0)
    srli t3, t2, 20              // nibble 5
    andi t3, t3, 0xF
    jal  ra, hex_nibble
    sw   t3, 0(s0)
    srli t3, t2, 16              // nibble 4
    andi t3, t3, 0xF
    jal  ra, hex_nibble
    sw   t3, 0(s0)
    srli t3, t2, 12              // nibble 3
    andi t3, t3, 0xF
    jal  ra, hex_nibble
    sw   t3, 0(s0)
    srli t3, t2, 8               // nibble 2
    andi t3, t3, 0xF
    jal  ra, hex_nibble
    sw   t3, 0(s0)
    srli t3, t2, 4               // nibble 1
    andi t3, t3, 0xF
    jal  ra, hex_nibble
    sw   t3, 0(s0)
    andi t3, t2, 0xF             // nibble 0
    jal  ra, hex_nibble
    sw   t3, 0(s0)
    addi t0, t0, 4
    j    sig_loop
sig_done:
    li   t2, 0xFF
    sw   t2, 0(s0)
    // Newline
    li   t2, 0x0A
    sw   t2, 0(s0)
5:  wfi
    j 5b

// Convert nibble to hex char
hex_nibble:
    addi t3, t3, 0x30
    li   t4, 0x39
    ble  t3, t4, 9f
    addi t3, t3, 0x27
9:  ret

// ---------------------------------------------------------------------------
// Trap vector — 64-byte aligned for direct mode
// ---------------------------------------------------------------------------
.align 6
.globl trap_vector
trap_vector:
    j trap_handler

// ---------------------------------------------------------------------------
// Trap handler — signal FAIL via mailbox
// ---------------------------------------------------------------------------
trap_handler:
    csrr t0, mcause
    lui  t1, 0xD0580
    li   t2, 0x01              // FAIL token
    sw   t2, 0(t1)
    sw   t0, 0(t1)             // mcause for debug
6:  wfi
    j 6b
