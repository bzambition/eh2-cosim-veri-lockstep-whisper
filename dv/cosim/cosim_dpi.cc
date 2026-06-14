// SPDX-License-Identifier: Apache-2.0
// EH2 Co-simulation DPI Bridge
//
// Thin C shim functions that bridge SystemVerilog DPI-C calls
// to the C++ Cosim abstract class.
// Based on Ibex's cosim_dpi.cc pattern.
// All per-hart functions accept an optional thread_id parameter (default 0).

#include "cosim.h"
#include <svdpi.h>
#include <cstring>
#include <stdexcept>

extern "C" {

  // Destroy co-simulation instance
  void riscv_cosim_destroy(void* handle) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    delete cosim;
  }

  // Add memory region
  void riscv_cosim_add_memory(void* handle, int base_addr, int size) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (cosim) {
      cosim->add_memory(static_cast<uint32_t>(base_addr),
                        static_cast<size_t>(size));
    }
  }

  // Backdoor write memory
  int riscv_cosim_backdoor_write_mem(void* handle, int addr, int len,
                                     const svOpenArrayHandle data) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (!cosim) return 0;

    const uint8_t* data_ptr = static_cast<const uint8_t*>(
        svGetArrayPtr(data));
    if (!data_ptr) return 0;

    return cosim->backdoor_write_mem(static_cast<uint32_t>(addr),
                                     static_cast<size_t>(len), data_ptr)
               ? 1
               : 0;
  }

  // Backdoor read memory
  int riscv_cosim_backdoor_read_mem(void* handle, int addr, int len,
                                    const svOpenArrayHandle data) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (!cosim) return 0;

    uint8_t* data_ptr = static_cast<uint8_t*>(svGetArrayPtr(data));
    if (!data_ptr) return 0;

    return cosim->backdoor_read_mem(static_cast<uint32_t>(addr),
                                    static_cast<size_t>(len), data_ptr)
               ? 1
               : 0;
  }

  // Step one instruction
  // Returns 1 on match, 0 on mismatch
  int riscv_cosim_step(void* handle, int write_reg, int write_reg_data,
                       int pc, int sync_trap, int suppress_reg_write,
                       int thread_id) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (!cosim) {
      return 0;
    }
    try {
      int result = cosim->step(static_cast<uint32_t>(write_reg),
                               static_cast<uint32_t>(write_reg_data),
                               static_cast<uint32_t>(pc),
                               sync_trap != 0,
                               suppress_reg_write != 0,
                               thread_id)
                 ? 1
                 : 0;
      return result;
    } catch (const std::exception &e) {
      fprintf(stderr, "COSIM WARNING: step exception at PC=0x%08x T%d: %s\n",
              (unsigned)pc, thread_id, e.what());
      fflush(stderr);
      return 0;
    } catch (...) {
      fprintf(stderr, "COSIM WARNING: unknown step exception at PC=0x%08x T%d\n",
              (unsigned)pc, thread_id);
      fflush(stderr);
      return 0;
    }
  }

  // Set MIP (pre and post values)
  void riscv_cosim_set_mip(void* handle, int pre_mip, int post_mip,
                           int thread_id) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (cosim) {
      cosim->set_mip(static_cast<uint32_t>(pre_mip),
                     static_cast<uint32_t>(post_mip), thread_id);
    }
  }

  // Set NMI
  void riscv_cosim_set_nmi(void* handle, int nmi, int thread_id) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (cosim) cosim->set_nmi(nmi != 0, thread_id);
  }

  // Set NMI internal
  void riscv_cosim_set_nmi_int(void* handle, int nmi_int, int thread_id) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (cosim) cosim->set_nmi_int(nmi_int != 0, thread_id);
  }

  // Set debug request
  void riscv_cosim_set_debug_req(void* handle, int debug_req,
                                 int thread_id) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (cosim) cosim->set_debug_req(debug_req != 0, thread_id);
  }

  // Set mcycle
  void riscv_cosim_set_mcycle(void* handle, long long mcycle,
                              int thread_id) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (cosim) cosim->set_mcycle(static_cast<uint64_t>(mcycle), thread_id);
  }

  // Set CSR
  void riscv_cosim_set_csr(void* handle, int csr_num, int new_val,
                           int thread_id) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (cosim) {
      cosim->set_csr(csr_num, static_cast<uint32_t>(new_val), thread_id);
    }
  }

  // Notify dside access
  void riscv_cosim_notify_dside_access(void* handle, int store, int data,
                                       int addr, int be, int error,
                                       int misaligned_first,
                                       int misaligned_second,
                                       int misaligned_first_saw_error,
                                       int m_mode_access,
                                       int widened_load,
                                       int thread_id) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (cosim) {
      DSideAccessInfo info;
      info.store = (store != 0);
      info.data = static_cast<uint32_t>(data);
      info.addr = static_cast<uint32_t>(addr);
      info.be = static_cast<uint32_t>(be);
      info.error = (error != 0);
      info.misaligned_first = (misaligned_first != 0);
      info.misaligned_second = (misaligned_second != 0);
      info.misaligned_first_saw_error = (misaligned_first_saw_error != 0);
      info.m_mode_access = (m_mode_access != 0);
      info.widened_load = (widened_load != 0);
      cosim->notify_dside_access(info, thread_id);
    }
  }

  // Set iside error
  void riscv_cosim_set_iside_error(void* handle, int addr, int thread_id) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (cosim) cosim->set_iside_error(static_cast<uint32_t>(addr), thread_id);
  }

  // Write a single byte to co-simulation memory (for binary loading)
  void riscv_cosim_write_mem_byte(void* handle, int addr, int data) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (cosim) {
      uint8_t byte = static_cast<uint8_t>(data & 0xFF);
      cosim->backdoor_write_mem(static_cast<uint32_t>(addr), 1, &byte);
    }
  }

  // Get error count
  int riscv_cosim_get_num_errors(void* handle) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (!cosim) {
      return 0;
    }
    try {
      return static_cast<int>(cosim->get_errors().size());
    } catch (...) {
      return 0;
    }
  }

  // Get error message at index
  const char* riscv_cosim_get_error(void* handle, int index) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (!cosim) return "null handle";
    try {
      const auto& errors = cosim->get_errors();
      if (index >= 0 && index < static_cast<int>(errors.size())) {
        return errors[index].c_str();
      }
    } catch (...) {}
    return "";
  }

  // Get result (0 = pass, non-zero = fail)
  int riscv_cosim_get_result(void* handle) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (!cosim) return -1;
    try {
      return cosim->get_errors().empty() ? 0 : 1;
    } catch (...) {
      return -1;
    }
  }

  // Clear errors
  void riscv_cosim_clear_errors(void* handle) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (cosim) {
      try {
        cosim->clear_errors();
      } catch (...) {}
    }
  }

  // Get instruction count
  int riscv_cosim_get_insn_cnt(void* handle, int thread_id) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (!cosim) return 0;
    try {
      return static_cast<int>(cosim->get_insn_cnt(thread_id));
    } catch (...) {
      return 0;
    }
  }

  // Trap CSR queries (RISK-9: mcause/mepc/mtvec comparison)
  uint32_t riscv_cosim_get_mcause(void* handle, int thread_id) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (!cosim) return 0;
    return cosim->get_mcause(thread_id);
  }

  uint32_t riscv_cosim_get_mepc(void* handle, int thread_id) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (!cosim) return 0;
    return cosim->get_mepc(thread_id);
  }

  uint32_t riscv_cosim_get_mtvec(void* handle, int thread_id) {
    Cosim* cosim = static_cast<Cosim*>(handle);
    if (!cosim) return 0;
    return cosim->get_mtvec(thread_id);
  }

}  // extern "C"
