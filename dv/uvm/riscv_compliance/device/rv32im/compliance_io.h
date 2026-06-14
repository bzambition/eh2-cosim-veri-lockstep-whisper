/* SPDX-License-Identifier: Apache-2.0 */
/* EH2 RISC-V Compliance — Target compliance_io.h (issue 57)     */
/*                                                               */
/* The compliance tests use RVTEST_IO_* macros.  For EH2,        */
/* these are informational only — the real I/O is done through   */
/* the compliance mailbox at 0xD058_0000 (see compliance_test.h).*/

#ifndef _COMPLIANCE_IO_H
#define _COMPLIANCE_IO_H

#define RVTEST_IO_INIT
#define RVTEST_IO_WRITE_STR(_SP, _STR)
#define RVTEST_IO_CHECK()
#define RVTEST_IO_ASSERT_GPR_EQ(_SP, _R, _I)
#define RVTEST_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVTEST_IO_ASSERT_DFPR_EQ(_D, _R, _I)

/* Override RVTEST_PASS from riscv-compliance — must NOT contain ecall.
 * The EH2 trap handler interprets ecall as a FAIL, and the exit protocol
 * is handled by signature_dump in startup.S (via j signature_dump from
 * RV_COMPLIANCE_CODE_END). */
#undef RVTEST_PASS
#define RVTEST_PASS  fence

#endif /* _COMPLIANCE_IO_H */
