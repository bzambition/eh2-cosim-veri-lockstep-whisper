// SPDX-License-Identifier: Apache-2.0
// Register file toggle pump for R3-B.

.option norvc
.section .text.init
.globl _start

_start:
    li      x1, 0xAAAAAAAA
    li      x1, 0x55555555
    li      x1, 0xDEADBEEF
    li      x2, 0xAAAAAAAA
    li      x2, 0x55555555
    li      x2, 0xDEADBEEF
    li      x3, 0xAAAAAAAA
    li      x3, 0x55555555
    li      x3, 0xDEADBEEF
    li      x4, 0xAAAAAAAA
    li      x4, 0x55555555
    li      x4, 0xDEADBEEF
    li      x5, 0xAAAAAAAA
    li      x5, 0x55555555
    li      x5, 0xDEADBEEF
    li      x6, 0xAAAAAAAA
    li      x6, 0x55555555
    li      x6, 0xDEADBEEF
    li      x7, 0xAAAAAAAA
    li      x7, 0x55555555
    li      x7, 0xDEADBEEF
    li      x8, 0xAAAAAAAA
    li      x8, 0x55555555
    li      x8, 0xDEADBEEF
    li      x9, 0xAAAAAAAA
    li      x9, 0x55555555
    li      x9, 0xDEADBEEF
    li      x10, 0xAAAAAAAA
    li      x10, 0x55555555
    li      x10, 0xDEADBEEF
    li      x11, 0xAAAAAAAA
    li      x11, 0x55555555
    li      x11, 0xDEADBEEF
    li      x12, 0xAAAAAAAA
    li      x12, 0x55555555
    li      x12, 0xDEADBEEF
    li      x13, 0xAAAAAAAA
    li      x13, 0x55555555
    li      x13, 0xDEADBEEF
    li      x14, 0xAAAAAAAA
    li      x14, 0x55555555
    li      x14, 0xDEADBEEF
    li      x15, 0xAAAAAAAA
    li      x15, 0x55555555
    li      x15, 0xDEADBEEF
    li      x16, 0xAAAAAAAA
    li      x16, 0x55555555
    li      x16, 0xDEADBEEF
    li      x17, 0xAAAAAAAA
    li      x17, 0x55555555
    li      x17, 0xDEADBEEF
    li      x18, 0xAAAAAAAA
    li      x18, 0x55555555
    li      x18, 0xDEADBEEF
    li      x19, 0xAAAAAAAA
    li      x19, 0x55555555
    li      x19, 0xDEADBEEF
    li      x20, 0xAAAAAAAA
    li      x20, 0x55555555
    li      x20, 0xDEADBEEF
    li      x21, 0xAAAAAAAA
    li      x21, 0x55555555
    li      x21, 0xDEADBEEF
    li      x22, 0xAAAAAAAA
    li      x22, 0x55555555
    li      x22, 0xDEADBEEF
    li      x23, 0xAAAAAAAA
    li      x23, 0x55555555
    li      x23, 0xDEADBEEF
    li      x24, 0xAAAAAAAA
    li      x24, 0x55555555
    li      x24, 0xDEADBEEF
    li      x25, 0xAAAAAAAA
    li      x25, 0x55555555
    li      x25, 0xDEADBEEF
    li      x26, 0xAAAAAAAA
    li      x26, 0x55555555
    li      x26, 0xDEADBEEF
    li      x27, 0xAAAAAAAA
    li      x27, 0x55555555
    li      x27, 0xDEADBEEF
    li      x28, 0xAAAAAAAA
    li      x28, 0x55555555
    li      x28, 0xDEADBEEF
    li      x29, 0xAAAAAAAA
    li      x29, 0x55555555
    li      x29, 0xDEADBEEF
    li      x30, 0xAAAAAAAA
    li      x30, 0x55555555
    li      x30, 0xDEADBEEF
    li      x31, 0xAAAAAAAA
    li      x31, 0x55555555
    li      x31, 0xDEADBEEF

    xor     x5, x1, x2
    xor     x6, x3, x4
    xor     x7, x5, x6
    xor     x8, x7, x31
    li      x9, 0x80010000
    sw      x8, 0(x9)

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
