// SPDX-License-Identifier: Apache-2.0
// RVVI-API reference-side wrapper around the EH2 SpikeCosim engine.

#include "spike_rvvi.h"

#include <array>
#include <cstring>
#include <memory>
#include <sstream>
#include <string>

#include "riscv/encoding.h"
#include "spike_cosim.h"

namespace {

constexpr uint32_t kDefaultRamBase = 0x80000000u;
constexpr size_t kDefaultRamSize = 256u * 1024u * 1024u;
constexpr uint32_t kDefaultLowZeroBase = 0x00000000u;
constexpr size_t kDefaultLowZeroSize = 4u * 1024u;
constexpr uint32_t kDefaultMailboxBase = 0xd0580000u;
constexpr size_t kDefaultMailboxSize = 4u * 1024u;
constexpr uint32_t kDefaultDccmBase = 0xf0040000u;
constexpr size_t kDefaultDccmSize = 64u * 1024u;
constexpr uint32_t kDefaultMtvec = 0x0u;
constexpr uint32_t kDefaultPmpRegions = 0u;
constexpr uint32_t kDefaultPmpGranularity = 0u;
constexpr uint32_t kDefaultMhpmCounters = 0u;
constexpr std::array<uint32_t, 6> kComparedCsrs = {
    CSR_MSTATUS, CSR_MTVEC, CSR_MEPC, CSR_MCAUSE, CSR_MTVAL, CSR_MIP};

struct DutState {
  uint32_t pc = 0;
  uint32_t insn = 0;
  bool retired = false;
  bool trap = false;
  bool debug_mode = false;
  uint64_t gpr[32] = {};
  uint32_t gpr_wmask = 0;
  uint64_t csr[4096] = {};
  bool csr_written[4096] = {};
};

std::unique_ptr<SpikeCosim> g_ref;
std::string g_error;
std::array<uint64_t, RVVI_METRIC_FATALS + 1> g_metrics = {};
DutState g_dut[COSIM_MAX_THREADS];
bool g_csr_compare_enable[COSIM_MAX_THREADS][4096] = {};
uint64_t g_csr_compare_mask[COSIM_MAX_THREADS][4096] = {};
uint32_t g_config_num_harts = 1;

bool valid_ref(uint32_t hart) {
  if (!g_ref) {
    g_error = "RVVI reference is not initialized";
    g_metrics[RVVI_METRIC_ERRORS]++;
    return false;
  }
  if (hart >= g_config_num_harts) {
    std::stringstream err;
    err << "Invalid hart " << hart;
    g_error = err.str();
    g_metrics[RVVI_METRIC_ERRORS]++;
    return false;
  }
  return true;
}

void capture_spike_error() {
  if (!g_ref) return;

  const auto &errors = g_ref->get_errors();
  if (!errors.empty()) {
    g_error = errors.back();
  }
}

bool valid_hart(uint32_t hart) {
  if (hart >= g_config_num_harts) {
    std::stringstream err;
    err << "Invalid hart " << hart;
    g_error = err.str();
    g_metrics[RVVI_METRIC_ERRORS]++;
    return false;
  }
  return true;
}

void clear_dut_event(uint32_t hart) {
  if (hart >= COSIM_MAX_THREADS) return;
  g_dut[hart].gpr_wmask = 0;
  g_dut[hart].retired = false;
  g_dut[hart].trap = false;
  g_dut[hart].debug_mode = false;
  std::memset(g_dut[hart].csr_written, 0, sizeof(g_dut[hart].csr_written));
}

void clear_all_dut_state() {
  for (auto &dut : g_dut) {
    dut = DutState{};
  }
  std::memset(g_csr_compare_enable, 0, sizeof(g_csr_compare_enable));
  for (auto &hart_masks : g_csr_compare_mask) {
    for (auto &mask : hart_masks) {
      mask = UINT64_MAX;
    }
  }
}

void enable_standard_csr_compare() {
  for (uint32_t hart = 0; hart < g_config_num_harts; ++hart) {
    for (uint32_t csr : kComparedCsrs) {
      g_csr_compare_enable[hart][csr] = true;
    }
  }
}

bool mismatch(uint32_t hart, const std::string &message) {
  std::stringstream err;
  err << "T" << hart << " " << message;
  g_error = err.str();
  g_metrics[RVVI_METRIC_MISMATCHES]++;
  return false;
}

uint64_t insn_mask(uint64_t insn) {
  return ((insn & 0x3u) == 0x3u) ? UINT64_C(0xffffffff) : UINT64_C(0xffff);
}

uint64_t read_mem(uint64_t address, uint32_t size) {
  if (!g_ref || size == 0 || size > 8) return 0;

  uint64_t value = 0;
  if (!g_ref->backdoor_read_mem(static_cast<uint32_t>(address), size,
                                reinterpret_cast<uint8_t *>(&value))) {
    std::stringstream err;
    err << "RVVI memory read failed at 0x" << std::hex << address
        << " size=" << std::dec << size;
    g_error = err.str();
    g_metrics[RVVI_METRIC_ERRORS]++;
    return 0;
  }
  return value;
}

void write_mem(uint64_t address, uint64_t data, uint32_t size) {
  if (!g_ref || size == 0 || size > 8) return;

  if (!g_ref->backdoor_write_mem(static_cast<uint32_t>(address), size,
                                 reinterpret_cast<const uint8_t *>(&data))) {
    std::stringstream err;
    err << "RVVI memory write failed at 0x" << std::hex << address
        << " size=" << std::dec << size;
    g_error = err.str();
    g_metrics[RVVI_METRIC_ERRORS]++;
  }
}

const char *gpr_name(uint32_t index) {
  static const char *const names[32] = {
      "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
      "s0",   "s1", "a0", "a1", "a2", "a3", "a4", "a5",
      "a6",   "a7", "s2", "s3", "s4", "s5", "s6", "s7",
      "s8",   "s9", "s10", "s11", "t3", "t4", "t5", "t6"};
  return index < 32 ? names[index] : "";
}

}  // namespace

extern "C" bool_t rvviVersionCheck(uint32_t version) {
  return version == RVVI_API_VERSION ? RVVI_TRUE : RVVI_FALSE;
}

extern "C" bool_t rvviRefInit(const char *programPath) {
  g_error.clear();
  g_metrics.fill(0);
  clear_all_dut_state();
  enable_standard_csr_compare();

  try {
    g_ref = std::make_unique<SpikeCosim>(
        "rv32imac_zba_zbb_zbc_zbs", kDefaultRamBase, kDefaultMtvec,
        "", kDefaultPmpRegions, kDefaultPmpGranularity,
        kDefaultMhpmCounters, g_config_num_harts);
    g_ref->add_memory(kDefaultRamBase, kDefaultRamSize);
    // EH2's sparse AXI IFU memory returns zero for uninitialized low
    // addresses, so jumps into the blank zero page retire as illegal
    // 0x00000000 instructions rather than instruction access faults.
    g_ref->add_memory(kDefaultLowZeroBase, kDefaultLowZeroSize);
    g_ref->add_memory(kDefaultMailboxBase, kDefaultMailboxSize);
    g_ref->add_memory(kDefaultDccmBase, kDefaultDccmSize);

    if (programPath && std::strlen(programPath) != 0) {
      if (!g_ref->ref_load_elf(programPath)) {
        capture_spike_error();
        g_ref.reset();
        g_metrics[RVVI_METRIC_ERRORS]++;
        return RVVI_FALSE;
      }
    }
  } catch (const std::exception &e) {
    g_error = e.what();
    g_ref.reset();
    g_metrics[RVVI_METRIC_ERRORS]++;
    return RVVI_FALSE;
  } catch (...) {
    g_error = "Unknown exception during rvviRefInit";
    g_ref.reset();
    g_metrics[RVVI_METRIC_ERRORS]++;
    return RVVI_FALSE;
  }

  return RVVI_TRUE;
}

extern "C" bool_t rvviRefPcSet(uint32_t hartId, uint64_t address) {
  if (!valid_ref(hartId)) return RVVI_FALSE;
  g_ref->ref_pc_set(hartId, address);
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefShutdown(void) {
  g_ref.reset();
  clear_all_dut_state();
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefCsrSetVolatile(uint32_t hartId, uint32_t csrIndex) {
  (void)hartId;
  (void)csrIndex;
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefMemorySetVolatile(uint64_t addressLow,
                                            uint64_t addressHigh) {
  (void)addressLow;
  (void)addressHigh;
  return RVVI_TRUE;
}

extern "C" uint64_t rvviRefNetIndexGet(const char *name) {
  if (!name) return RVVI_INVALID_INDEX;
  if (std::strcmp(name, "MIP") == 0) return 1;
  if (std::strcmp(name, "NMI") == 0) return 2;
  if (std::strcmp(name, "DEBUG_REQ") == 0) return 3;
  return RVVI_INVALID_INDEX;
}

extern "C" uint8_t rvviRefVrGet(uint32_t hartId, uint32_t vrIndex,
                                 uint32_t byteIndex) {
  (void)hartId;
  (void)vrIndex;
  (void)byteIndex;
  return 0;
}

extern "C" void rvviDutVrSet(uint32_t hartId, uint32_t vrIndex,
                              uint32_t byteIndex, uint8_t data) {
  (void)hartId;
  (void)vrIndex;
  (void)byteIndex;
  (void)data;
}

extern "C" void rvviDutFprSet(uint32_t hartId, uint32_t fprIndex,
                               uint64_t value) {
  (void)hartId;
  (void)fprIndex;
  (void)value;
}

extern "C" void rvviDutGprSet(uint32_t hartId, uint32_t gprIndex,
                               uint64_t value) {
  if (!valid_hart(hartId) || gprIndex >= 32) return;
  g_dut[hartId].gpr[gprIndex] = value & 0xffffffffu;
  g_dut[hartId].gpr_wmask |= (1u << gprIndex);
}

extern "C" void rvviDutCsrSet(uint32_t hartId, uint32_t csrIndex,
                               uint64_t value) {
  if (!valid_hart(hartId) || csrIndex >= 4096) return;
  g_dut[hartId].csr[csrIndex] = value & 0xffffffffu;
  g_dut[hartId].csr_written[csrIndex] = true;
}

extern "C" void rvviRefNetGroupSet(uint64_t netIndex, uint32_t group) {
  (void)netIndex;
  (void)group;
}

extern "C" void rvviRefNetSet(uint64_t netIndex, uint64_t value,
                               uint64_t when) {
  if (!g_ref) return;
  uint32_t hart = static_cast<uint32_t>((when >> 32) & 0xffffffffu);
  if (hart >= g_config_num_harts) hart = 0;

  switch (netIndex) {
    case 1:
      g_ref->set_mip(static_cast<uint32_t>(value),
                     static_cast<uint32_t>(value), hart);
      break;
    case 2:
      g_ref->set_nmi(value != 0, hart);
      break;
    case 3:
      g_ref->set_debug_req(value != 0, hart);
      break;
    default:
      break;
  }
}

extern "C" uint64_t rvviRefNetGet(uint64_t netIndex) {
  (void)netIndex;
  return 0;
}

extern "C" void rvviDutRetire(uint32_t hartId, uint64_t dutPc,
                               uint64_t dutInsBin, bool_t debugMode) {
  if (!valid_hart(hartId)) return;
  g_dut[hartId].pc = static_cast<uint32_t>(dutPc);
  g_dut[hartId].insn = static_cast<uint32_t>(dutInsBin);
  g_dut[hartId].debug_mode = debugMode != RVVI_FALSE;
  g_dut[hartId].retired = true;
  g_dut[hartId].trap = false;
}

extern "C" void rvviDutTrap(uint32_t hartId, uint64_t dutPc,
                             uint64_t dutInsBin) {
  if (!valid_hart(hartId)) return;
  g_dut[hartId].pc = static_cast<uint32_t>(dutPc);
  g_dut[hartId].insn = static_cast<uint32_t>(dutInsBin);
  g_dut[hartId].retired = true;
  g_dut[hartId].trap = true;
}

extern "C" void rvviRefReservationInvalidate(uint32_t hartId) {
  (void)hartId;
}

extern "C" bool_t rvviRefEventStep(uint32_t hartId) {
  if (!valid_ref(hartId)) return RVVI_FALSE;

  if (g_ref->ref_async_event_pending(hartId)) {
    g_metrics[RVVI_METRIC_TRAPS]++;
    g_ref->ref_clear_async_event(hartId);
    return RVVI_TRUE;
  }

  if (!g_ref->ref_event_step(hartId)) {
    capture_spike_error();
    g_metrics[RVVI_METRIC_ERRORS]++;
    return RVVI_FALSE;
  }

  if (g_dut[hartId].trap || g_ref->ref_last_trap(hartId)) {
    g_metrics[RVVI_METRIC_TRAPS]++;
  }
  g_metrics[RVVI_METRIC_RETIRES]++;
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefGprsCompare(uint32_t hartId) {
  if (!valid_ref(hartId)) return RVVI_FALSE;

  for (uint32_t idx = 1; idx < 32; ++idx) {
    uint64_t dut = g_dut[hartId].gpr[idx] & 0xffffffffu;
    uint64_t ref = g_ref->ref_gpr(hartId, idx) & 0xffffffffu;
    if (dut != ref) {
      std::stringstream msg;
      msg << "GPR x" << idx << " mismatch: DUT=0x" << std::hex << dut
          << " REF=0x" << ref;
      return mismatch(hartId, msg.str()) ? RVVI_TRUE : RVVI_FALSE;
    }
  }
  g_metrics[RVVI_METRIC_COMPARISONS_GPR]++;
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefGprsCompareWritten(uint32_t hartId,
                                             bool_t ignoreX0) {
  if (!valid_ref(hartId)) return RVVI_FALSE;

  uint32_t mask = g_dut[hartId].gpr_wmask | g_ref->ref_gpr_written_mask(hartId);
  if (ignoreX0 != RVVI_FALSE) {
    mask &= ~1u;
  }

  for (uint32_t idx = 0; idx < 32; ++idx) {
    if (((mask >> idx) & 1u) == 0) continue;
    uint64_t dut = g_dut[hartId].gpr[idx] & 0xffffffffu;
    uint64_t ref = g_ref->ref_gpr(hartId, idx) & 0xffffffffu;
    if (dut != ref) {
      std::stringstream msg;
      msg << "written GPR x" << idx << " mismatch: DUT=0x" << std::hex
          << dut << " REF=0x" << ref << " DUT_WMASK=0x"
          << g_dut[hartId].gpr_wmask << " REF_WMASK=0x"
          << g_ref->ref_gpr_written_mask(hartId);
      return mismatch(hartId, msg.str()) ? RVVI_TRUE : RVVI_FALSE;
    }
  }
  g_metrics[RVVI_METRIC_COMPARISONS_GPR]++;
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefInsBinCompare(uint32_t hartId) {
  if (!valid_ref(hartId)) return RVVI_FALSE;

  uint64_t dut_mask = insn_mask(g_dut[hartId].insn);
  uint64_t ref_mask = insn_mask(g_ref->ref_insn_bin(hartId));
  uint64_t mask = dut_mask < ref_mask ? dut_mask : ref_mask;
  uint64_t dut = g_dut[hartId].insn & mask;
  uint64_t ref = g_ref->ref_insn_bin(hartId) & mask;
  if (dut != ref) {
    std::stringstream msg;
    msg << "instruction mismatch: DUT=0x" << std::hex << dut
        << " REF=0x" << ref << " mask=0x" << mask;
    return mismatch(hartId, msg.str()) ? RVVI_TRUE : RVVI_FALSE;
  }
  g_metrics[RVVI_METRIC_COMPARISONS_INSBIN]++;
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefPcCompare(uint32_t hartId) {
  if (!valid_ref(hartId)) return RVVI_FALSE;

  uint32_t dut = g_dut[hartId].pc;
  uint32_t ref = g_ref->ref_pc(hartId);
  if (dut != ref) {
    std::stringstream msg;
    msg << "PC mismatch: DUT=0x" << std::hex << dut << " REF=0x" << ref;
    return mismatch(hartId, msg.str()) ? RVVI_TRUE : RVVI_FALSE;
  }
  g_metrics[RVVI_METRIC_COMPARISONS_PC]++;
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefCsrCompare(uint32_t hartId, uint32_t csrIndex) {
  if (!valid_ref(hartId) || csrIndex >= 4096) return RVVI_FALSE;
  if (!g_csr_compare_enable[hartId][csrIndex] ||
      !g_dut[hartId].csr_written[csrIndex]) {
    return RVVI_TRUE;
  }

  uint64_t mask = g_csr_compare_mask[hartId][csrIndex];
  uint64_t dut = g_dut[hartId].csr[csrIndex] & mask;
  uint64_t ref = g_ref->ref_csr(hartId, csrIndex) & mask;
  if (dut != ref) {
    std::stringstream msg;
    msg << "CSR 0x" << std::hex << csrIndex << " mismatch: DUT=0x"
        << dut << " REF=0x" << ref << " mask=0x" << mask;
    return mismatch(hartId, msg.str()) ? RVVI_TRUE : RVVI_FALSE;
  }
  g_metrics[RVVI_METRIC_COMPARISONS_CSR]++;
  return RVVI_TRUE;
}

extern "C" void rvviRefCsrCompareEnable(uint32_t hartId, uint32_t csrIndex,
                                         bool_t enableState) {
  if (hartId >= COSIM_MAX_THREADS || csrIndex >= 4096) return;
  g_csr_compare_enable[hartId][csrIndex] = enableState != RVVI_FALSE;
}

extern "C" void rvviRefCsrCompareMask(uint32_t hartId, uint32_t csrIndex,
                                       uint64_t mask) {
  if (hartId >= COSIM_MAX_THREADS || csrIndex >= 4096) return;
  g_csr_compare_mask[hartId][csrIndex] = mask;
}

extern "C" bool_t rvviRefCsrsCompare(uint32_t hartId) {
  if (!valid_ref(hartId)) return RVVI_FALSE;

  for (uint32_t csr = 0; csr < 4096; ++csr) {
    if (rvviRefCsrCompare(hartId, csr) == RVVI_FALSE) {
      return RVVI_FALSE;
    }
  }
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefVrsCompare(uint32_t hartId) {
  (void)hartId;
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefFprsCompare(uint32_t hartId) {
  (void)hartId;
  return RVVI_TRUE;
}

extern "C" void rvviRefGprSet(uint32_t hartId, uint32_t gprIndex,
                               uint64_t gprValue) {
  if (!valid_ref(hartId)) return;
  g_ref->ref_gpr_set(hartId, gprIndex, gprValue);
}

extern "C" uint64_t rvviRefGprGet(uint32_t hartId, uint32_t gprIndex) {
  if (!valid_ref(hartId)) return 0;
  return g_ref->ref_gpr(hartId, gprIndex);
}

extern "C" uint32_t rvviRefGprsWrittenGet(uint32_t hartId) {
  if (!valid_ref(hartId)) return 0;
  return g_ref->ref_gpr_written_mask(hartId);
}

extern "C" uint64_t rvviRefPcGet(uint32_t hartId) {
  if (!valid_ref(hartId)) return 0;
  return g_ref->ref_pc(hartId);
}

extern "C" uint64_t rvviRefCsrGet(uint32_t hartId, uint32_t csrIndex) {
  if (!valid_ref(hartId)) return 0;
  return g_ref->ref_csr(hartId, csrIndex);
}

extern "C" uint64_t rvviRefInsBinGet(uint32_t hartId) {
  if (!valid_ref(hartId)) return 0;
  return g_ref->ref_insn_bin(hartId);
}

extern "C" uint32_t eh2RefCsrWritesGet(uint32_t hartId, uint32_t *csr,
                                        uint64_t *value,
                                        uint32_t maxEntries) {
  if (!valid_ref(hartId) || !csr || !value) return 0;
  const auto &writes = g_ref->ref_csr_writes(hartId);
  uint32_t count = 0;
  for (const auto &write : writes) {
    if (count >= maxEntries) break;
    csr[count] = write.csr;
    value[count] = write.value;
    count++;
  }
  return count;
}

extern "C" uint32_t eh2RefMemWritesGet(uint32_t hartId, uint64_t *addr,
                                        uint64_t *data, uint32_t *be,
                                        uint32_t maxEntries) {
  if (!valid_ref(hartId) || !addr || !data || !be) return 0;
  const auto &writes = g_ref->ref_mem_writes(hartId);
  uint32_t count = 0;
  for (const auto &write : writes) {
    if (count >= maxEntries) break;
    addr[count] = write.addr;
    data[count] = write.data;
    be[count] = write.be;
    count++;
  }
  return count;
}

extern "C" void rvviRefFprSet(uint32_t hartId, uint32_t fprIndex,
                               uint64_t fprValue) {
  (void)hartId;
  (void)fprIndex;
  (void)fprValue;
}

extern "C" uint64_t rvviRefFprGet(uint32_t hartId, uint32_t fprIndex) {
  (void)hartId;
  (void)fprIndex;
  return 0;
}

extern "C" void rvviDutBusWrite(uint32_t hartId, uint64_t address,
                                 uint64_t value, uint64_t byteEnableMask) {
  if (!valid_ref(hartId)) return;

  for (uint32_t byte = 0; byte < 8; ++byte) {
    if (((byteEnableMask >> byte) & 1u) == 0) continue;
    uint8_t data = static_cast<uint8_t>((value >> (8 * byte)) & 0xffu);
    write_mem(address + byte, data, 1);
  }
}

extern "C" void rvviRefMemoryWrite(uint32_t hartId, uint64_t address,
                                    uint64_t data, uint32_t size) {
  (void)hartId;
  write_mem(address, data, size);
}

extern "C" uint64_t rvviRefMemoryRead(uint32_t hartId, uint64_t address,
                                       uint32_t size) {
  (void)hartId;
  return read_mem(address, size);
}

extern "C" const char *rvviDasmInsBin(uint32_t hartId, uint64_t address,
                                       uint64_t insBin) {
  (void)hartId;
  (void)address;
  (void)insBin;
  return "";
}

extern "C" const char *rvviRefCsrName(uint32_t hartId, uint32_t csrIndex) {
  (void)hartId;
  switch (csrIndex) {
    case CSR_MSTATUS:
      return "mstatus";
    case CSR_MISA:
      return "misa";
    case CSR_MIE:
      return "mie";
    case CSR_MTVEC:
      return "mtvec";
    case CSR_MEPC:
      return "mepc";
    case CSR_MCAUSE:
      return "mcause";
    case CSR_MTVAL:
      return "mtval";
    case CSR_MIP:
      return "mip";
    default:
      return "";
  }
}

extern "C" const char *rvviRefGprName(uint32_t hartId, uint32_t gprIndex) {
  (void)hartId;
  return gpr_name(gprIndex);
}

extern "C" bool_t rvviRefCsrPresent(uint32_t hartId, uint32_t csrIndex) {
  if (!valid_ref(hartId)) return RVVI_FALSE;
  (void)csrIndex;
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefFprsPresent(uint32_t hartId) {
  (void)hartId;
  return RVVI_FALSE;
}

extern "C" bool_t rvviRefVrsPresent(uint32_t hartId) {
  (void)hartId;
  return RVVI_FALSE;
}

extern "C" const char *rvviRefFprName(uint32_t hartId, uint32_t fprIndex) {
  (void)hartId;
  static const char *const names[32] = {
      "ft0", "ft1", "ft2",  "ft3",  "ft4",  "ft5",  "ft6",  "ft7",
      "fs0", "fs1", "fa0",  "fa1",  "fa2",  "fa3",  "fa4",  "fa5",
      "fa6", "fa7", "fs2",  "fs3",  "fs4",  "fs5",  "fs6",  "fs7",
      "fs8", "fs9", "fs10", "fs11", "ft8",  "ft9",  "ft10", "ft11"};
  return fprIndex < 32 ? names[fprIndex] : "";
}

extern "C" const char *rvviRefVrName(uint32_t hartId, uint32_t vrIndex) {
  (void)hartId;
  static std::string names[32];
  if (vrIndex >= 32) return "";
  if (names[vrIndex].empty()) {
    names[vrIndex] = "v" + std::to_string(vrIndex);
  }
  return names[vrIndex].c_str();
}

extern "C" const char *rvviErrorGet(void) { return g_error.c_str(); }

extern "C" uint64_t rvviRefMetricGet(rvviMetricE metric) {
  if (metric < RVVI_METRIC_RETIRES || metric > RVVI_METRIC_FATALS) return 0;
  return g_metrics[metric];
}

extern "C" void rvviRefCsrSet(uint32_t hartId, uint32_t csrIndex,
                               uint64_t value) {
  if (!valid_ref(hartId)) return;
  g_ref->ref_csr_set(hartId, csrIndex, value);
}

extern "C" void rvviRefStateDump(uint32_t hartId) { (void)hartId; }

extern "C" bool_t rvviRefProgramLoad(const char *programPath) {
  if (!g_ref) return rvviRefInit(programPath);
  if (!programPath) return RVVI_FALSE;
  if (!g_ref->ref_load_elf(programPath)) {
    capture_spike_error();
    g_metrics[RVVI_METRIC_ERRORS]++;
    return RVVI_FALSE;
  }
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefCsrSetVolatileMask(uint32_t hartId,
                                             uint32_t csrIndex,
                                             uint64_t csrMask) {
  (void)hartId;
  (void)csrIndex;
  (void)csrMask;
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefCsrSetOneWayCompare(uint32_t hartId,
                                              uint32_t csrIndex,
                                              bool_t enable) {
  (void)hartId;
  (void)csrIndex;
  (void)enable;
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefCsrSetOneWayCompareMask(uint32_t hartId,
                                                  uint32_t csrIndex,
                                                  uint64_t csrMask) {
  (void)hartId;
  (void)csrIndex;
  (void)csrMask;
  return RVVI_TRUE;
}

extern "C" void rvviDutCycleCountSet(uint64_t cycleCount) {
  g_metrics[RVVI_METRIC_CYCLES] = cycleCount;
}

extern "C" void rvviRefEventComplete(uint32_t hartId) {
  if (hartId >= COSIM_MAX_THREADS) return;
  clear_dut_event(hartId);
}

extern "C" bool_t rvviRefConfigSetInt(uint64_t configParam, uint64_t value) {
  if (configParam == kRvviConfigNumHarts) {
    if (value == 0 || value > COSIM_MAX_THREADS) {
      std::stringstream err;
      err << "Invalid RVVI hart count " << value
          << " (max " << COSIM_MAX_THREADS << ")";
      g_error = err.str();
      g_metrics[RVVI_METRIC_ERRORS]++;
      return RVVI_FALSE;
    }
    if (g_ref) {
      g_error = "rvvi_nhart must be configured before rvviRefInit";
      g_metrics[RVVI_METRIC_ERRORS]++;
      return RVVI_FALSE;
    }
    g_config_num_harts = static_cast<uint32_t>(value);
  }
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefConfigSetString(uint64_t configParam,
                                          const char *value) {
  (void)configParam;
  (void)value;
  return RVVI_TRUE;
}

extern "C" uint32_t rvviRefCsrIndex(uint32_t hartId, const char *csrName) {
  (void)hartId;
  if (!csrName) return RVVI_INVALID_INDEX;
  if (std::strcmp(csrName, "mstatus") == 0) return CSR_MSTATUS;
  if (std::strcmp(csrName, "misa") == 0) return CSR_MISA;
  if (std::strcmp(csrName, "mie") == 0) return CSR_MIE;
  if (std::strcmp(csrName, "mtvec") == 0) return CSR_MTVEC;
  if (std::strcmp(csrName, "mepc") == 0) return CSR_MEPC;
  if (std::strcmp(csrName, "mcause") == 0) return CSR_MCAUSE;
  if (std::strcmp(csrName, "mtval") == 0) return CSR_MTVAL;
  if (std::strcmp(csrName, "mip") == 0) return CSR_MIP;
  return RVVI_INVALID_INDEX;
}

extern "C" bool_t rvviRefMemorySetPrivilege(uint64_t addrLo, uint64_t addrHi,
                                             uint32_t access) {
  (void)addrLo;
  (void)addrHi;
  (void)access;
  return RVVI_TRUE;
}

extern "C" void rvviRefVrSet(uint32_t hartId, uint32_t vrIndex,
                              uint32_t byteIndex, uint8_t data) {
  (void)hartId;
  (void)vrIndex;
  (void)byteIndex;
  (void)data;
}

extern "C" uint64_t rvviRefConnIndexGet(const char *name) {
  (void)name;
  return RVVI_INVALID_INDEX;
}

extern "C" bool_t rvviRefConnSetEmpty(uint64_t connIndex) {
  (void)connIndex;
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefConnSetFull(uint64_t connIndex) {
  (void)connIndex;
  return RVVI_TRUE;
}

extern "C" bool_t rvviRefConnData(uint64_t connIndex, uint32_t offset,
                                   uint64_t value, bool_t commit) {
  (void)connIndex;
  (void)offset;
  (void)value;
  (void)commit;
  return RVVI_TRUE;
}

extern "C" void rvviRefNetCancel(uint64_t netIndex) { (void)netIndex; }

extern "C" void setContextExtMemory(const char *func) { (void)func; }
