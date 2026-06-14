// SPDX-License-Identifier: Apache-2.0
// EH2 CSR Categories for Coverage
//
// Defines macros for grouping CSRs into categories for coverage filtering.

// CSRs that are read-only or not meaningful for write testing
`define EH2_READ_ONLY_CSRS \
  12'hF11, /* mvendorid */ \
  12'hF12, /* marchid */ \
  12'hF13, /* mimpid */ \
  12'hF14, /* mhartid */ \
  12'hFC0, /* mdseac */ \
  12'hFC8, /* meihap */ \
  12'hFC4  /* mhartnum */

// CSRs only accessible in debug mode
`define EH2_DEBUG_CSRS \
  12'h7B0, /* dcsr */ \
  12'h7B1, /* dpc */ \
  12'h7C8, /* dicawics */ \
  12'h7C9, /* dicad0 */ \
  12'h7CC, /* dicad0h */ \
  12'h7CA, /* dicad1 */ \
  12'h7CB  /* dicago */

// Performance counter CSRs (excluded from detailed write testing)
`define EH2_PERF_COUNTER_CSRS \
  12'hB00, /* mcyclel */ \
  12'hB80, /* mcycleh */ \
  12'hB02, /* minstretl */ \
  12'hB82, /* minstreth */ \
  12'hB03, /* mhpmc3 */ \
  12'hB04, /* mhpmc4 */ \
  12'hB05, /* mhpmc5 */ \
  12'hB06, /* mhpmc6 */ \
  12'hB83, /* mhpmc3h */ \
  12'hB84, /* mhpmc4h */ \
  12'hB85, /* mhpmc5h */ \
  12'hB86, /* mhpmc6h */ \
  12'hB07, /* perfva */ \
  12'hB87  /* perfvd */

// EH2 custom WD/Microchip CSRs
`define EH2_CUSTOM_CSRS \
  12'h7FF, /* mscause */ \
  12'h7C0, /* mrac */ \
  12'h7C9, /* mfdc */ \
  12'h7F8, /* mcgc */ \
  12'h7C6, /* mpmc */ \
  12'h7C2, /* mcpc */ \
  12'h7C4, /* dmst */ \
  12'h7CE, /* mfdht */ \
  12'h7CF, /* mfdhs */ \
  12'h7FC, /* mhartstart */ \
  12'h7FE  /* mnmipdel */
