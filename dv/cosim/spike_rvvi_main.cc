// SPDX-License-Identifier: Apache-2.0

#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "spike_rvvi.h"

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

}  // namespace

int main(int argc, char **argv) {
  if (argc < 2 || argc > 4) {
    std::fprintf(stderr, "usage: %s <program.elf> [trace.csv] [steps]\n", argv[0]);
    return 2;
  }

  const char *program = argv[1];
  const char *trace = (argc >= 3) ? argv[2] : "rvvi_ref_trace.csv";
  int steps = (argc >= 4) ? std::atoi(argv[3]) : 6;

  if (!rvviVersionCheck(RVVI_API_VERSION)) {
    std::fprintf(stderr, "RVVI API version mismatch\n");
    return 1;
  }
  if (!rvviRefInit(program)) {
    std::fprintf(stderr, "rvviRefInit failed: %s\n", rvviErrorGet());
    return 1;
  }

  FILE *fp = std::fopen(trace, "w");
  if (!fp) {
    std::perror(trace);
    rvviRefShutdown();
    return 1;
  }

  std::fprintf(fp, "pc,instr,gpr,csr,binary,mode,instr_str,operand,pad\n");
  for (int i = 0; i < steps; ++i) {
    if (!rvviRefEventStep(0)) {
      std::fprintf(stderr, "rvviRefEventStep(%d) failed: %s\n", i, rvviErrorGet());
      std::fclose(fp);
      rvviRefShutdown();
      return 1;
    }

    uint32_t gpr_mask = rvviRefGprsWrittenGet(0);
    char gpr_buf[512] = {};
    size_t off = 0;
    for (uint32_t reg = 1; reg < 32; ++reg) {
      if (((gpr_mask >> reg) & 1u) == 0) continue;
      int n = std::snprintf(gpr_buf + off, sizeof(gpr_buf) - off,
                            "%s%s:%08x", off ? ";" : "", gpr_name(reg),
                            static_cast<uint32_t>(rvviRefGprGet(0, reg)));
      if (n < 0) break;
      off += static_cast<size_t>(n);
      if (off >= sizeof(gpr_buf)) {
        gpr_buf[sizeof(gpr_buf) - 1] = '\0';
        break;
      }
    }

    std::fprintf(fp, "%08x,,", static_cast<uint32_t>(rvviRefPcGet(0)));
    write_csv_escaped(fp, gpr_buf);
    std::fprintf(fp, ",,%08x,3,,,\n",
                 static_cast<uint32_t>(rvviRefInsBinGet(0)));
  }

  std::fclose(fp);
  rvviRefShutdown();
  return 0;
}
