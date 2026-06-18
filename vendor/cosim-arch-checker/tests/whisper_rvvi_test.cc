// Licensed under the Apache License, Version 2.0, see ../LICENSE.TT for details

#include <cassert>
#include <cstdlib>
#include <cstring>
#include <iostream>

#include "rvviApi.h"

static void version_check_accepts_header_version()
{
  assert(rvviVersionCheck(RVVI_API_VERSION) == RVVI_TRUE);
  assert(rvviVersionCheck(RVVI_API_VERSION + 1) == RVVI_FALSE);
}

static void ref_step_reports_state_when_integration_env_is_present()
{
  const char *elf = std::getenv("WHISPER_RVVI_TEST_ELF");
  if (!elf || !*elf) {
    std::cout << "SKIP whisper RVVI integration: WHISPER_RVVI_TEST_ELF unset\n";
    return;
  }

  assert(rvviRefInit(elf) == RVVI_TRUE);
  assert(rvviRefPcSet(0, 0x80000000ull) == RVVI_TRUE);
  assert(rvviRefEventStep(0) == RVVI_TRUE);

  const uint64_t expected_pcs[] = {0x80000000ull, 0x80000004ull, 0x80000008ull};
  uint64_t pc = rvviRefPcGet(0);
  uint64_t insn = rvviRefInsBinGet(0);
  std::cout << "RVVI Whisper step 1: pc=0x" << std::hex << pc
            << " insn=0x" << insn << std::dec << "\n";
  assert(pc == expected_pcs[0]);
  assert(insn != 0);
  assert(rvviRefMetricGet(RVVI_METRIC_RETIRES) == 1);

  uint32_t written = rvviRefGprsWrittenGet(0);
  uint32_t any_written = written;
  for (unsigned i = 1; i < 3; ++i) {
    assert(rvviRefEventStep(0) == RVVI_TRUE);
    written = rvviRefGprsWrittenGet(0);
    any_written |= written;
    pc = rvviRefPcGet(0);
    insn = rvviRefInsBinGet(0);
    std::cout << "RVVI Whisper step " << (i + 1)
              << ": pc=0x" << std::hex << pc
              << " insn=0x" << insn
              << " gpr_written=0x" << written << std::dec << "\n";
    assert(pc == expected_pcs[i]);
    assert(insn != 0);
  }
  for (unsigned i = 0; i < 16 && any_written == 0; ++i) {
    assert(rvviRefEventStep(0) == RVVI_TRUE);
    written = rvviRefGprsWrittenGet(0);
    any_written |= written;
    std::cout << "RVVI Whisper extra step " << (i + 1)
              << ": pc=0x" << std::hex << rvviRefPcGet(0)
              << " insn=0x" << rvviRefInsBinGet(0)
              << " gpr_written=0x" << written << std::dec << "\n";
  }
  assert(any_written != 0);

  assert(rvviRefGprGet(0, 0) == 0);
  (void)rvviRefCsrGet(0, 0x300);

  assert(rvviRefShutdown() == RVVI_TRUE);
}

int main()
{
  version_check_accepts_header_version();
  ref_step_reports_state_when_integration_env_is_present();
  assert(std::strlen(rvviErrorGet()) == 0);
  return 0;
}
