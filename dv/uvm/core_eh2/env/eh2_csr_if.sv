// SPDX-License-Identifier: Apache-2.0
// EH2 CSR Monitoring Interface
//
// Probes CSR access bus for coverage and verification.
// Benchmarked against ibex's core_ibex_csr_if.sv, adapted for EH2.
//
// Monitors:
//   - CSR access valid
//   - CSR address (12-bit)
//   - CSR write data
//   - CSR read data
//   - CSR write enable
//
// These signals are probed from the DUT's decode/TLU hierarchy.

interface eh2_csr_if(
  input logic clk,
  input logic rst_n
);

  // CSR access signals (from decode stage)
  logic        csr_access;      // Any CSR operation (read/write/set/clear)
  logic [11:0] csr_addr;        // CSR address (12-bit)
  logic [31:0] csr_wdata;       // CSR write data (at writeback)
  logic [31:0] csr_rdata;       // CSR read data (at decode)
  logic        csr_wen;         // CSR write enable (at writeback)
  logic        csr_read;        // CSR read operation
  logic        csr_write;       // CSR write operation
  logic        csr_set;         // CSR set operation
  logic        csr_clr;         // CSR clear operation

  // Monitor clocking block
  clocking monitor_cb @(posedge clk);
    input csr_access;
    input csr_addr;
    input csr_wdata;
    input csr_rdata;
    input csr_wen;
    input csr_read;
    input csr_write;
    input csr_set;
    input csr_clr;
  endclocking

endinterface
