// Licensed under the Apache License, Version 2.0, see ../LICENSE.TT for details

#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <fstream>

#include "cacCore.h"

static void csr_mismatch_is_reported()
{
  CacCore cac(1);
  unitDataT dut[] = {0x1234};
  unitDataT ref[] = {0x1235};

  cac.updateCsr(0, 0x7c0, dut);
  cac.updateRefCsr(0, 0x7c0, ref);
  cac.step(0);

  assert(!cac.getStatus(0));
}

static void csr_mask_can_ignore_nondeterministic_bits()
{
  const char *mask_path = "/tmp/cac_csr_mask_test.txt";
  {
    std::ofstream mask(mask_path);
    mask << "0xb00 0x0 # mcycle: fully nondeterministic in this unit test\n";
    mask << "0x7c0 0xffffffff # mrac: still fully compared\n";
  }
  setenv("CAC_CSR_MASK_FILE", mask_path, 1);

  CacCore cac(1);
  unitDataT dut_cycle[] = {0x1234};
  unitDataT ref_cycle[] = {0x5678};
  unitDataT dut_mrac[] = {0x1234};
  unitDataT ref_mrac[] = {0x1235};

  cac.updateCsr(0, 0xb00, dut_cycle);
  cac.updateRefCsr(0, 0xb00, ref_cycle);
  cac.step(0);
  assert(cac.getStatus(0));

  cac.updateCsr(0, 0x7c0, dut_mrac);
  cac.updateRefCsr(0, 0x7c0, ref_mrac);
  cac.step(0);
  assert(!cac.getStatus(0));

  unsetenv("CAC_CSR_MASK_FILE");
}

static void fully_masked_csr_does_not_require_ref_snapshot()
{
  const char *mask_path = "/tmp/cac_csr_mask_missing_ref_test.txt";
  {
    std::ofstream mask(mask_path);
    mask << "0x344 0x0 # mip: async pending state may be DUT-only on this retire\n";
  }
  setenv("CAC_CSR_MASK_FILE", mask_path, 1);

  CacCore cac(1);
  unitDataT dut_mip[] = {0x800};

  cac.updateCsr(0, 0x344, dut_mip);
  cac.step(0);
  assert(cac.getStatus(0));

  unsetenv("CAC_CSR_MASK_FILE");
}

static void memory_address_and_value_are_compared()
{
  CacCore cac(1);
  unitDataT dut[] = {0xaa};
  unitDataT ref[] = {0xaa};
  unitDataT other_ref[] = {0xbb};

  cac.updateMemory(0, 0x80000000ull, dut);
  cac.updateRefMemory(0, 0x80000000ull, ref);
  cac.step(0);
  assert(cac.getStatus(0));

  cac.updateMemory(0, 0x80000004ull, dut);
  cac.updateRefMemory(0, 0x80000004ull, other_ref);
  cac.step(0);
  assert(!cac.getStatus(0));
}

int main()
{
  csr_mismatch_is_reported();
  csr_mask_can_ignore_nondeterministic_bits();
  fully_masked_csr_does_not_require_ref_snapshot();
  memory_address_and_value_are_compared();
  return 0;
}
