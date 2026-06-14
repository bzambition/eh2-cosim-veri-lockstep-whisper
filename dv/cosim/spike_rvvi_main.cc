// SPDX-License-Identifier: Apache-2.0

#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "spike_rvvi.h"

int main(int argc, char **argv) {
  if (argc < 2 || argc > 4) {
    std::fprintf(stderr, "usage: %s <program.elf> [trace.log] [steps]\n", argv[0]);
    return 2;
  }

  const char *program = argv[1];
  const char *trace = (argc >= 3) ? argv[2] : "rvvi_ref_trace.log";
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

  for (int i = 0; i < steps; ++i) {
    if (!rvviRefEventStep(0)) {
      std::fprintf(stderr, "rvviRefEventStep(%d) failed: %s\n", i, rvviErrorGet());
      std::fclose(fp);
      rvviRefShutdown();
      return 1;
    }
    std::fprintf(fp, "0|%d|%08x|%08x\n", i,
                 static_cast<uint32_t>(rvviRefPcGet(0)),
                 static_cast<uint32_t>(rvviRefInsBinGet(0)));
  }

  std::fclose(fp);
  rvviRefShutdown();
  return 0;
}
