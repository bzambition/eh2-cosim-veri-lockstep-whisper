// SPDX-License-Identifier: Apache-2.0
// EH2 Custom CSR Pre-registration
//
// EH2 implements 28 vendor-specific CSRs that Spike's csrmap does not know
// about. Pre-register them as zero-initialized so that any CSR access
// instruction Spike sees is treated as a legal CSR operation rather than
// triggering an illegal-instruction trap.
//
// Future work: model these CSRs' WARL behavior in Spike's fixup_csr() so
// reads/writes match the EH2 RTL semantics. See ADR (TBD).
//
// Included from inside eh2_cosim_scoreboard's init_cosim function.

      riscv_cosim_set_csr(cosim_handle, 32'h7FF, 0, 0);  // mscause
      riscv_cosim_set_csr(cosim_handle, 32'h7C0, 0, 0);  // mrac
      riscv_cosim_set_csr(cosim_handle, 32'h7F9, 0, 0);  // mfdc
      riscv_cosim_set_csr(cosim_handle, 32'h7F8, 0, 0);  // mcgc
      riscv_cosim_set_csr(cosim_handle, 32'h7C6, 0, 0);  // mpmc
      riscv_cosim_set_csr(cosim_handle, 32'h7C2, 0, 0);  // mcpc
      riscv_cosim_set_csr(cosim_handle, 32'h7C4, 0, 0);  // dmst
      riscv_cosim_set_csr(cosim_handle, 32'h7CE, 0, 0);  // mfdht
      riscv_cosim_set_csr(cosim_handle, 32'h7CF, 0, 0);  // mfdhs
      riscv_cosim_set_csr(cosim_handle, 32'h7FC, 0, 0);  // mhartstart
      riscv_cosim_set_csr(cosim_handle, 32'h7FE, 0, 0);  // mnmipdel
      riscv_cosim_set_csr(cosim_handle, 32'h7D2, 0, 0);  // mitcnt0
      riscv_cosim_set_csr(cosim_handle, 32'h7D5, 0, 0);  // mitcnt1
      riscv_cosim_set_csr(cosim_handle, 32'h7D3, 0, 0);  // mitb0
      riscv_cosim_set_csr(cosim_handle, 32'h7D6, 0, 0);  // mitb1
      riscv_cosim_set_csr(cosim_handle, 32'h7D4, 0, 0);  // mitctl0
      riscv_cosim_set_csr(cosim_handle, 32'h7D7, 0, 0);  // mitctl1
      riscv_cosim_set_csr(cosim_handle, 32'hBC0, 0, 0);  // mdeau
      riscv_cosim_set_csr(cosim_handle, 32'hFC0, 0, 0);  // mdseac
      riscv_cosim_set_csr(cosim_handle, 32'h7F0, 0, 0);  // micect
      riscv_cosim_set_csr(cosim_handle, 32'h7F1, 0, 0);  // miccmect
      riscv_cosim_set_csr(cosim_handle, 32'h7F2, 0, 0);  // mdccmect
      riscv_cosim_set_csr(cosim_handle, 32'hBC8, 0, 0);  // meivt
      riscv_cosim_set_csr(cosim_handle, 32'hFC8, 0, 0);  // meihap
      riscv_cosim_set_csr(cosim_handle, 32'hBC9, 0, 0);  // meipt
      riscv_cosim_set_csr(cosim_handle, 32'hBCA, 0, 0);  // meicpct
      riscv_cosim_set_csr(cosim_handle, 32'hBCC, 0, 0);  // meicurpl
      riscv_cosim_set_csr(cosim_handle, 32'hBCB, 0, 0);  // meicidpl
