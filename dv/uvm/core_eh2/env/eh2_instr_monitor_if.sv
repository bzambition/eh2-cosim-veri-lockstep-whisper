// SPDX-License-Identifier: Apache-2.0
// EH2 Instruction Monitor Interface
//
// Probes the decode stage pipeline for instruction tracking.
// Benchmarked against ibex's core_ibex_instr_monitor_if.sv, adapted for EH2.
//
// Monitors (per dual-issue slot):
//   - Pipeline valid
//   - Instruction word
//   - PC
//   - Compressed vs uncompressed
//   - Branch taken/flush
//   - Stall conditions
//
// These signals are probed from the DUT's decode hierarchy.

interface eh2_instr_monitor_if(
  input logic clk,
  input logic rst_n
);

  // I0 (slot 0) decode stage signals
  logic        i0_valid;           // I0 valid at decode
  logic [31:0] i0_instr;           // I0 instruction word
  logic        i0_compressed;      // I0 is 16-bit compressed
  logic [15:0] i0_instr_compressed; // I0 compressed instruction bits
  logic        i0_branch_taken;    // I0 branch was taken
  logic        i0_stall;           // I0 stage stalled

  // I1 (slot 1) decode stage signals
  logic        i1_valid;           // I1 valid at decode
  logic [31:0] i1_instr;           // I1 instruction word
  logic        i1_compressed;      // I1 is 16-bit compressed
  logic [15:0] i1_instr_compressed; // I1 compressed instruction bits
  logic        i1_branch_taken;    // I1 branch was taken
  logic        i1_stall;           // I1 stage stalled

  // Pipeline control
  logic        pipe_flush;         // Pipeline flush
  logic        dual_issue;         // Dual-issue active

  // Monitor clocking block
  clocking monitor_cb @(posedge clk);
    input i0_valid;
    input i0_instr;
    input i0_compressed;
    input i0_instr_compressed;
    input i0_branch_taken;
    input i0_stall;
    input i1_valid;
    input i1_instr;
    input i1_compressed;
    input i1_instr_compressed;
    input i1_branch_taken;
    input i1_stall;
    input pipe_flush;
    input dual_issue;
  endclocking

endinterface
