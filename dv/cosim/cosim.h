// SPDX-License-Identifier: Apache-2.0
// EH2 Co-simulation Abstract Class
//
// Defines the interface between UVM testbench and reference model (Spike).
// Based on Ibex's cosim.h pattern, adapted for EH2's trace-based comparison.
//
// Key difference from Ibex:
//   - Ibex uses RVFI (full register/memory/CSR visibility per instruction)
//   - EH2 uses trace (PC + insn + exception) + DUT probe (register writeback)
//   - The scoreboard correlates trace + DUT probe before calling step()
//   - Memory accesses are captured via AXI4 monitoring

#ifndef EH2_COSIM_H
#define EH2_COSIM_H

#include <cstdint>
#include <string>
#include <vector>

// Information about a dside transaction observed on the DUT memory interface
struct DSideAccessInfo {
  bool store;
  uint32_t data;
  uint32_t addr;
  uint32_t be;
  bool error;
  bool misaligned_first;
  bool misaligned_second;
  bool misaligned_first_saw_error;
  bool m_mode_access;
  bool widened_load;
};

class Cosim {
public:
  virtual ~Cosim() {}

  // Add a memory region to the co-simulator environment.
  virtual void add_memory(uint32_t base_addr, size_t size) = 0;

  // Write bytes to co-simulator memory via backdoor.
  virtual bool backdoor_write_mem(uint32_t addr, size_t len,
                                  const uint8_t *data_in) = 0;

  // Read bytes from co-simulator memory via backdoor.
  virtual bool backdoor_read_mem(uint32_t addr, size_t len,
                                 uint8_t *data_out) = 0;

  // Step the co-simulator.
  //
  // write_reg: destination register index (0 = no write)
  // write_reg_data: data written to register
  // pc: program counter of the instruction
  // sync_trap: true if instruction caused synchronous trap
  // suppress_reg_write: true if register write was suppressed
  // thread_id: hardware thread (hart) index (0 or 1)
  //
  // Returns true if step succeeded (no mismatch).
  virtual bool step(uint32_t write_reg, uint32_t write_reg_data, uint32_t pc,
                    bool sync_trap, bool suppress_reg_write,
                    int thread_id = 0) = 0;

  // Set MIP (interrupt pending) with pre/post values.
  // pre_mip: value used to determine if interrupt is pending
  // post_mip: value observed by next instruction
  virtual void set_mip(uint32_t pre_mip, uint32_t post_mip,
                       int thread_id = 0) = 0;

  // Set NMI state.
  virtual void set_nmi(bool nmi, int thread_id = 0) = 0;

  // Set NMI internal state.
  virtual void set_nmi_int(bool nmi_int, int thread_id = 0) = 0;

  // Set debug request.
  virtual void set_debug_req(bool debug_req, int thread_id = 0) = 0;

  // Set mcycle CSR value (full 64-bit).
  virtual void set_mcycle(uint64_t mcycle, int thread_id = 0) = 0;

  // Set a CSR value directly (for DUT-to-Spike synchronization).
  virtual void set_csr(const int csr_num, const uint32_t new_val,
                       int thread_id = 0) = 0;

  // Notify about a dside memory access from the DUT.
  virtual void notify_dside_access(const DSideAccessInfo &access_info,
                                   int thread_id = 0) = 0;

  // Set iside error for next step.
  virtual void set_iside_error(uint32_t addr, int thread_id = 0) = 0;

  // Get error descriptions.
  virtual const std::vector<std::string> &get_errors() = 0;

  // Clear error descriptions.
  virtual void clear_errors() = 0;

  // Get instruction count (number of successfully matched instructions).
  virtual unsigned int get_insn_cnt(int thread_id = 0) = 0;

  // Trap CSR queries (RISK-9: mcause/mepc/mtvec comparison)
  virtual uint32_t get_mcause(int thread_id = 0) = 0;
  virtual uint32_t get_mepc(int thread_id = 0) = 0;
  virtual uint32_t get_mtvec(int thread_id = 0) = 0;
};

#endif // EH2_COSIM_H
