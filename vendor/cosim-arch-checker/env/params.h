// Licensed under the Apache License, Version 2.0, see LICENSE.TT for details

#pragma once

#if ((CONFIG == MediumBoomVecConfig) || (CONFIG == MediumOcelotVecConfig))

#ifndef CAC_NUM_HARTS
#define CAC_NUM_HARTS 1
#endif

namespace {

  const int k_NumHarts = CAC_NUM_HARTS;
  const int k_VLen = 256;

}

#endif
