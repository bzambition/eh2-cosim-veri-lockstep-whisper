// SPDX-License-Identifier: Apache-2.0
// RVVI-API wrapper around the existing EH2 SpikeCosim engine.

#ifndef EH2_SPIKE_RVVI_H
#define EH2_SPIKE_RVVI_H

#include "rvviApi.h"

// Vendor-specific RVVI configuration keys used by this EH2 wrapper.
// Set before rvviRefInit() with rvviRefConfigSetInt().
constexpr uint64_t kRvviConfigNumHarts = 1;

#endif  // EH2_SPIKE_RVVI_H
