// SPDX-License-Identifier: Apache-2.0

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <vector>

#include "spike_cosim.h"

namespace {

const char *gpr_name(uint32_t idx) {
  static const char *const names[32] = {
      "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
      "s0",   "s1", "a0", "a1", "a2", "a3", "a4", "a5",
      "a6",   "a7", "s2", "s3", "s4", "s5", "s6", "s7",
      "s8",   "s9", "s10", "s11", "t3", "t4", "t5", "t6"};
  return idx < 32 ? names[idx] : "";
}

void write_csv_escaped(FILE *fp, const char *text) {
  std::fputc('"', fp);
  for (const char *p = text; p && *p; ++p) {
    if (*p == '"') std::fputc('"', fp);
    std::fputc(*p, fp);
  }
  std::fputc('"', fp);
}

bool read_hart_schedule(const char *path, std::vector<uint32_t> *schedule) {
  FILE *fp = std::fopen(path, "r");
  if (!fp) {
    std::perror(path);
    return false;
  }

  unsigned long hart = 0;
  while (std::fscanf(fp, "%lu", &hart) == 1) {
    schedule->push_back(static_cast<uint32_t>(hart));
  }
  if (std::ferror(fp)) {
    std::perror(path);
    std::fclose(fp);
    return false;
  }
  std::fclose(fp);
  return true;
}

constexpr uint32_t kDefaultRamBase = 0x80000000u;
constexpr uint32_t kDefaultRamSize = 256u * 1024u * 1024u;
constexpr uint32_t kDefaultLowZeroBase = 0x00000000u;
constexpr uint32_t kDefaultLowZeroSize = 4u * 1024u;
constexpr uint32_t kDefaultMailboxBase = 0xd0580000u;
constexpr uint32_t kDefaultMailboxSize = 4u * 1024u;
constexpr uint32_t kDefaultDccmBase = 0xf0040000u;
constexpr uint32_t kDefaultDccmSize = 64u * 1024u;

std::unique_ptr<SpikeCosim> create_ref(uint32_t nhart) {
  auto ref = std::make_unique<SpikeCosim>(
      "rv32imac_zba_zbb_zbc_zbs", kDefaultRamBase, 0, "", 0, 0, 0,
      static_cast<int>(nhart));
  ref->add_memory(kDefaultRamBase, kDefaultRamSize);
  ref->add_memory(kDefaultLowZeroBase, kDefaultLowZeroSize);
  ref->add_memory(kDefaultMailboxBase, kDefaultMailboxSize);
  ref->add_memory(kDefaultDccmBase, kDefaultDccmSize);
  return ref;
}

bool write_ref_row(SpikeCosim &ref, FILE *fp, uint32_t hart, int step) {
  if (!ref.ref_event_step(static_cast<int>(hart))) {
    const auto &errors = ref.get_errors();
    const char *error = errors.empty() ? "unknown error" : errors.back().c_str();
    std::fprintf(stderr, "ref_event_step(step=%d,hart=%u) failed: %s\n",
                 step, hart, error);
    return false;
  }

  uint32_t gpr_mask = ref.ref_gpr_written_mask(static_cast<int>(hart));
  char gpr_buf[512] = {};
  size_t off = 0;
  for (uint32_t reg = 1; reg < 32; ++reg) {
    if (((gpr_mask >> reg) & 1u) == 0) continue;
    int n = std::snprintf(gpr_buf + off, sizeof(gpr_buf) - off,
                          "%s%s:%08x", off ? ";" : "", gpr_name(reg),
                          static_cast<uint32_t>(
                              ref.ref_gpr(static_cast<int>(hart),
                                          static_cast<int>(reg))));
    if (n < 0) break;
    off += static_cast<size_t>(n);
    if (off >= sizeof(gpr_buf)) {
      gpr_buf[sizeof(gpr_buf) - 1] = '\0';
      break;
    }
  }

  const auto &csr_writes = ref.ref_csr_writes(static_cast<int>(hart));
  char csr_buf[1024] = {};
  off = 0;
  for (const auto &csr_write : csr_writes) {
    int n = std::snprintf(csr_buf + off, sizeof(csr_buf) - off,
                          "%s%03x:%08x", off ? ";" : "",
                          csr_write.csr & 0xfffu,
                          static_cast<uint32_t>(csr_write.value));
    if (n < 0) break;
    off += static_cast<size_t>(n);
    if (off >= sizeof(csr_buf)) {
      csr_buf[sizeof(csr_buf) - 1] = '\0';
      break;
    }
  }

  const auto &mem_writes = ref.ref_mem_writes(static_cast<int>(hart));
  char operand_buf[1024] = {};
  off = static_cast<size_t>(std::snprintf(operand_buf, sizeof(operand_buf),
                                          "hart=%u", hart));
  for (const auto &mem_write : mem_writes) {
    if (off >= sizeof(operand_buf)) break;
    int n = std::snprintf(operand_buf + off, sizeof(operand_buf) - off,
                          ";mem=%08x:%08x:%x",
                          mem_write.addr,
                          mem_write.data,
                          mem_write.be);
    if (n < 0) break;
    off += static_cast<size_t>(n);
    if (off >= sizeof(operand_buf)) {
      operand_buf[sizeof(operand_buf) - 1] = '\0';
      break;
    }
  }

  std::fprintf(fp, "%08x,,",
               static_cast<uint32_t>(ref.ref_pc(static_cast<int>(hart))));
  write_csv_escaped(fp, gpr_buf);
  std::fprintf(fp, ",");
  write_csv_escaped(fp, csr_buf);
  std::fprintf(fp, ",%08x,3,,",
               static_cast<uint32_t>(
                   ref.ref_insn_bin(static_cast<int>(hart))));
  if (ref.ref_last_trap(static_cast<int>(hart)) &&
      off < sizeof(operand_buf)) {
    int n = std::snprintf(operand_buf + off, sizeof(operand_buf) - off,
                          "%strap=1", off ? ";" : "");
    if (n > 0) off += static_cast<size_t>(n);
  }
  write_csv_escaped(fp, operand_buf);
  std::fprintf(fp, ",\n");
  return true;
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 2 || argc > 6) {
    std::fprintf(stderr, "usage: %s <program.elf> [trace.csv] [steps] [nhart] [hart_schedule]\n", argv[0]);
    return 2;
  }

  const char *program = argv[1];
  const char *trace = (argc >= 3) ? argv[2] : "rvvi_ref_trace.csv";
  int steps = (argc >= 4) ? std::atoi(argv[3]) : 6;
  uint32_t nhart = (argc >= 5) ? static_cast<uint32_t>(std::atoi(argv[4])) : 1;
  const char *hart_schedule = (argc >= 6) ? argv[5] : nullptr;
  if (nhart == 0) nhart = 1;

  std::vector<uint32_t> schedule;
  if (hart_schedule && !read_hart_schedule(hart_schedule, &schedule)) {
    return 1;
  }
  if (!schedule.empty()) {
    steps = static_cast<int>(schedule.size());
  }

  auto ref = create_ref(nhart);
  if (!ref->ref_load_elf(program)) {
    const auto &errors = ref->get_errors();
    const char *error = errors.empty() ? "unknown error" : errors.back().c_str();
    std::fprintf(stderr, "ref_load_elf failed: %s\n", error);
    return 1;
  }

  FILE *fp = std::fopen(trace, "w");
  if (!fp) {
    std::perror(trace);
    return 1;
  }

  std::fprintf(fp, "pc,instr,gpr,csr,binary,mode,instr_str,operand,pad\n");
  if (!schedule.empty()) {
    for (size_t i = 0; i < schedule.size(); ++i) {
      uint32_t hart = schedule[i];
      if (hart >= nhart) {
        std::fprintf(stderr, "hart_schedule[%zu]=%u exceeds nhart=%u\n",
                     i, hart, nhart);
        std::fclose(fp);
        return 1;
      }
      if (!write_ref_row(*ref, fp, hart, static_cast<int>(i))) {
        std::fclose(fp);
        return 1;
      }
    }
  } else {
    for (int i = 0; i < steps; ++i) {
      for (uint32_t hart = 0; hart < nhart; ++hart) {
        if (!write_ref_row(*ref, fp, hart, i)) {
          std::fclose(fp);
          return 1;
        }
      }
    }
  }

  std::fclose(fp);
  return 0;
}
