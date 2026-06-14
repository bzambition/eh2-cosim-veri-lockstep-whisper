/* SPDX-License-Identifier: BSD-3-Clause */
/* EH2 RISC-V Compliance I/O Header — RV32IMAC (issue 57) */

#ifndef COMPLIANCE_IO_H
#define COMPLIANCE_IO_H

/* Mailbox address for EH2 */
#define COMPLIANCE_IO_BASE    0xD0580000
#define COMPLIANCE_IO_WRITE   0xD0580000

/* Compliance result codes */
#define COMPLIANCE_PASS  0xFF
#define COMPLIANCE_FAIL  0x01

/* Test result write macro */
static inline void compliance_write_result(int result) {
    volatile unsigned int *tohost = (unsigned int *)0xD0580000;
    *tohost = result ? COMPLIANCE_FAIL : COMPLIANCE_PASS;
}

#endif /* COMPLIANCE_IO_H */
