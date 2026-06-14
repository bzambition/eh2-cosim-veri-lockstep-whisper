/* SPDX-License-Identifier: Apache-2.0 */
/* EH2 RISC-V Compliance — Target compliance_test.h (issue 57)                  */
/*                                                                             */
/* Adapted from ibex riscv-target/ibex/compliance_test.h.                      */
/* The EH2 compliance mailbox lives at 0xD058_0000:                            */
/*   +0x0  HALT — any write triggers signature dump & simulation termination   */
/*   +0x4  Set signature begin address (32-bit)                                */
/*   +0x8  Set signature end address   (32-bit)                                */

#ifndef _COMPLIANCE_TEST_H
#define _COMPLIANCE_TEST_H

#include "riscv_test.h"

#define COMPLIANCE_MBX_BASE              0xD0580000
#define COMPLIANCE_MBX_HALT              (COMPLIANCE_MBX_BASE + 0x0)
#define COMPLIANCE_MBX_BEGIN_SIGNATURE   (COMPLIANCE_MBX_BASE + 0x4)
#define COMPLIANCE_MBX_END_SIGNATURE     (COMPLIANCE_MBX_BASE + 0x8)

#define RV_COMPLIANCE_HALT                                                    \
        la t0, begin_signature;                                               \
        li t1, COMPLIANCE_MBX_BEGIN_SIGNATURE;                                \
        sw t0, 0(t1);                                                         \
        la t0, end_signature;                                                 \
        li t1, COMPLIANCE_MBX_END_SIGNATURE;                                  \
        sw t0, 0(t1);                                                         \
        RVTEST_PASS

#define RV_COMPLIANCE_RV32M                                                   \
        RVTEST_RV32M

#define RV_COMPLIANCE_CODE_BEGIN                                              \
        .section .text;                                                       \
        .globl  test_entry;                                                   \
test_entry:

#define RV_COMPLIANCE_CODE_END                                                \
        j signature_dump;                                                     \
        nop

#define RV_COMPLIANCE_DATA_BEGIN                                              \
        .section .signature, "aw", @progbits;                                                 \
        .align 4

#define RV_COMPLIANCE_DATA_END                                                \
        .align 4;                                                             \
        .global end_signature;                                                \
        end_signature:                                                        \
        nop;                                                                  \
        nop

#endif /* _COMPLIANCE_TEST_H */
