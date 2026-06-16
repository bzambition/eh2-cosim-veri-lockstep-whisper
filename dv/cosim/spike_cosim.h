// SPDX-License-Identifier: Apache-2.0
// EH2 Spike Co-simulation Implementation
//
// Spike reference model for EH2 RVVI cosim verification.
// Based on Ibex's spike_cosim.cc pattern, adapted for EH2.

#ifndef EH2_SPIKE_COSIM_H
#define EH2_SPIKE_COSIM_H

#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <vector>

#include "riscv/devices.h"
#include "riscv/isa_parser.h"
#include "riscv/log_file.h"
#include "riscv/processor.h"
#include "riscv/simif.h"

// EH2 marchid value (VeeR EH2)
#define EH2_MARCHID 0x56524545  // "VEER" in ASCII

// Maximum number of hardware threads supported
#define COSIM_MAX_THREADS 2

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

struct RefMemWrite {
  uint32_t addr;
  uint32_t data;
  uint32_t be;
};

struct RefCsrWrite {
  uint32_t csr;
  uint32_t value;
};

class SpikeCosim : public simif_t {
public:
  SpikeCosim(const std::string &isa_string, uint32_t start_pc,
             uint32_t start_mtvec, const std::string &trace_log_path,
             uint32_t pmp_num_regions, uint32_t pmp_granularity,
             uint32_t mhpm_counter_num, int num_threads = 1);

  // simif_t implementation
  virtual char *addr_to_mem(reg_t addr) override;
  virtual bool mmio_load(reg_t addr, size_t len, uint8_t *bytes) override;
  virtual bool mmio_store(reg_t addr, size_t len,
                          const uint8_t *bytes) override;
  virtual void proc_reset(unsigned id) override;
  virtual const char *get_symbol(uint64_t addr) override;

  void add_memory(uint32_t base_addr, size_t size);
  bool backdoor_write_mem(uint32_t addr, size_t len,
                          const uint8_t *data_in);
  bool backdoor_read_mem(uint32_t addr, size_t len, uint8_t *data_out);
  bool step(uint32_t write_reg, uint32_t write_reg_data, uint32_t pc,
            bool sync_trap, bool suppress_reg_write,
            int thread_id = 0);

  void set_mip(uint32_t pre_mip, uint32_t post_mip,
               int thread_id = 0);
  void set_nmi(bool nmi, int thread_id = 0);
  void set_nmi_int(bool nmi_int, int thread_id = 0);
  void set_debug_req(bool debug_req, int thread_id = 0);
  void set_mcycle(uint64_t mcycle, int thread_id = 0);
  void set_csr(const int csr_num, const uint32_t new_val,
               int thread_id = 0);
  void notify_dside_access(const DSideAccessInfo &access_info,
                           int thread_id = 0);
  void set_iside_error(uint32_t addr, int thread_id = 0);
  const std::vector<std::string> &get_errors();
  void clear_errors();
  unsigned int get_insn_cnt(int thread_id = 0);

  // Trap CSR queries (RISK-9)
  uint32_t get_mcause(int thread_id = 0);
  uint32_t get_mepc(int thread_id = 0);
  uint32_t get_mtvec(int thread_id = 0);

  // RVVI ref-only API helpers. These step Spike without DUT comparison.
  bool ref_load_elf(const std::string &elf_path);
  bool ref_event_step(int hart = 0);
  void ref_pc_set(int hart, uint64_t pc);
  uint32_t ref_pc(int hart = 0);
  uint64_t ref_insn_bin(int hart = 0);
  bool ref_last_trap(int hart = 0);
  bool ref_async_event_pending(int hart = 0);
  void ref_clear_async_event(int hart = 0);
  uint64_t ref_gpr(int hart, int idx);
  void ref_gpr_set(int hart, int idx, uint64_t value);
  uint32_t ref_gpr_written_mask(int hart = 0);
  uint64_t ref_csr(int hart, int idx);
  void ref_csr_set(int hart, int idx, uint64_t value);
  const std::vector<RefCsrWrite> &ref_csr_writes(int hart = 0) const;
  const std::vector<RefMemWrite> &ref_mem_writes(int hart = 0) const;

private:
  // Number of hardware threads (1 or 2)
  int num_threads;

  // Spike processor(s) and ISA
  std::unique_ptr<isa_parser_t> isa_parser;
  std::unique_ptr<processor_t> processors[COSIM_MAX_THREADS];
  std::unique_ptr<log_file_t> log;

  // Active thread for mmio callbacks (set before each step)
  int active_thread;

  // Memory bus (shared across threads — EH2 shares address space)
  bus_t bus;
  std::vector<std::unique_ptr<mem_t>> mems;

  // Error tracking
  std::vector<std::string> errors;

  // Pending dside accesses from DUT
  struct PendingMemAccess {
    DSideAccessInfo dut_access_info;
    uint32_t be_spike;
    bool is_atomic_store = false;  // true for SC/AMO store half
  };

  // Per-thread state
  struct PerThreadState {
    bool nmi_mode = false;
    bool pending_iside_error = false;
    uint32_t pending_iside_err_addr = 0;
    unsigned int insn_cnt = 0;

    // Mstack for NMI handling
    struct {
      uint8_t mpp = 0;
      bool mpie = false;
      uint32_t epc = 0;
      uint32_t cause = 0;
    } mstack;

    // Pending dside accesses from DUT
    std::vector<PendingMemAccess> pending_dside_accesses;

    // LR reservation tracking for atomic cosim (issue 52)
    uint32_t lr_reservation_addr = 0;
    bool lr_reservation_valid = false;

    // PC of last stepped instruction (for commit-log-free instr type checks)
    uint32_t last_step_pc = 0;

    // RVVI ref-only retire event state.
    uint32_t ref_last_pc = 0;
    uint64_t ref_last_insn = 0;
    bool ref_last_trap = false;
    bool ref_async_event_pending = false;
    uint32_t ref_gpr_written_mask = 0;
    std::vector<RefCsrWrite> ref_csr_writes;
    std::vector<RefMemWrite> ref_mem_writes;
  };
  PerThreadState thread_state[COSIM_MAX_THREADS];

  // Helper to get the processor for a thread
  processor_t *get_processor(int thread_id = 0) {
    assert(thread_id >= 0 && thread_id < num_threads);
    return processors[thread_id].get();
  }

  // Internal methods — all operate on the specified thread
  void initial_proc_setup(int thread_id, uint32_t start_pc,
                          uint32_t start_mtvec, uint32_t mhpm_counter_num);
  void fixup_csr(int thread_id, int csr_num, uint32_t csr_val);
  void misaligned_pmp_fixup(int thread_id, uint32_t addr, bool store);
  void atomic_store_fixup(int thread_id, bool store, uint32_t addr,
                          uint32_t rd_data, bool is_sc);
  bool pc_is_atomic_mem_instr(int thread_id, uint32_t pc);
  bool is_sc_instr(int thread_id, uint32_t pc);
  bool is_lr_instr(int thread_id, uint32_t pc);
  bool check_retired_instr(int thread_id, uint32_t write_reg,
                           uint32_t write_reg_data, uint32_t dut_pc,
                           bool suppress_reg_write);
  bool check_sync_trap(int thread_id, uint32_t write_reg, uint32_t pc,
                       uint32_t initial_spike_pc);
  bool check_gpr_write(int thread_id,
                       const commit_log_reg_t::value_type &reg_change,
                       uint32_t write_reg, uint32_t write_reg_data);
  bool check_suppress_reg_write(int thread_id, uint32_t write_reg, uint32_t pc,
                                uint32_t &suppressed_write_reg);
  void on_csr_write(int thread_id,
                    const commit_log_reg_t::value_type &reg_change);
  void leave_nmi_mode(int thread_id);

  // Interrupt/debug handling (Ibex-aligned)
  void early_interrupt_handle(int thread_id);
  bool pc_is_mret(int thread_id, uint32_t pc);
  bool pc_is_debug_ebreak(int thread_id, uint32_t pc);
  void check_debug_ebreak(int thread_id, uint32_t write_reg, uint32_t pc,
                          bool sync_trap);
  bool pc_is_load(uint32_t pc);
  bool pc_is_div_or_rem(uint32_t pc);
  bool is_widened_load_pair(int thread_id, size_t first_idx) const;

  enum check_mem_result_e {
    kCheckMemOk,
    kCheckMemCheckFailed,
    kCheckMemBusError
  };
  check_mem_result_e check_mem_access(int thread_id, bool store, uint32_t addr,
                                      size_t len, const uint8_t *bytes);
};

#endif // EH2_SPIKE_COSIM_H
