// SPDX-License-Identifier: Apache-2.0
// RVVI-API wrapper around the existing EH2 SpikeCosim engine.

#ifndef EH2_SPIKE_RVVI_H
#define EH2_SPIKE_RVVI_H

#include "rvviApi.h"

// Vendor-specific RVVI configuration keys used by this EH2 wrapper.
// Set before rvviRefInit() with rvviRefConfigSetInt().
constexpr uint64_t kRvviConfigNumHarts = 1;

extern "C" uint32_t eh2RefCsrWritesGet(uint32_t hartId, uint32_t *csr,
                                        uint64_t *value, uint32_t maxEntries);
extern "C" uint32_t eh2RefMemWritesGet(uint32_t hartId, uint64_t *addr,
                                        uint64_t *data, uint32_t *be,
                                        uint32_t maxEntries);

#endif  // EH2_SPIKE_RVVI_H
