// SPDX-License-Identifier: Apache-2.0
// AXI4 Package for EH2 UVM Verification Platform
//
// This package defines AXI4 protocol constants and types used across
// the verification platform. It is parameterized to support different
// ID widths for different EH2 ports.

package axi4_pkg;

  // AXI4 Burst Types
  localparam [1:0] AXI_BURST_FIXED = 2'b00;
  localparam [1:0] AXI_BURST_INCR  = 2'b01;
  localparam [1:0] AXI_BURST_WRAP  = 2'b10;

  // AXI4 Response Codes
  localparam [1:0] AXI_RESP_OKAY   = 2'b00;
  localparam [1:0] AXI_RESP_EXOKAY = 2'b01;
  localparam [1:0] AXI_RESP_SLVERR = 2'b10;
  localparam [1:0] AXI_RESP_DECERR = 2'b11;

  // AXI4 Lock Types
  localparam AXI_LOCK_NORMAL    = 1'b0;
  localparam AXI_LOCK_EXCLUSIVE = 1'b1;

  // AXI4 Size Encoding
  localparam [2:0] AXI_SIZE_1B   = 3'b000;
  localparam [2:0] AXI_SIZE_2B   = 3'b001;
  localparam [2:0] AXI_SIZE_4B   = 3'b010;
  localparam [2:0] AXI_SIZE_8B   = 3'b011;
  localparam [2:0] AXI_SIZE_16B  = 3'b100;
  localparam [2:0] AXI_SIZE_32B  = 3'b101;
  localparam [2:0] AXI_SIZE_64B  = 3'b110;
  localparam [2:0] AXI_SIZE_128B = 3'b111;

  // AXI4 Cache Encoding (common values)
  localparam [3:0] AXI_CACHE_NONCACHE_NONBUF = 4'b0000;
  localparam [3:0] AXI_CACHE_BUF_NONCACHE    = 4'b0001;
  localparam [3:0] AXI_CACHE_CACHE_NONALLOC  = 4'b0010;
  localparam [3:0] AXI_CACHE_CACHE_BUF       = 4'b0011;

  // AXI4 Protection Encoding
  localparam [2:0] AXI_PROT_UNPRIV    = 3'b000;
  localparam [2:0] AXI_PROT_PRIV      = 3'b001;
  localparam [2:0] AXI_PROT_SECURE    = 3'b000;
  localparam [2:0] AXI_PROT_NONSECURE = 3'b010;
  localparam [2:0] AXI_PROT_DATA      = 3'b000;
  localparam [2:0] AXI_PROT_INSTR     = 3'b100;

  // Maximum outstanding transactions
  localparam int MAX_OUTSTANDING = 16;

endpackage
