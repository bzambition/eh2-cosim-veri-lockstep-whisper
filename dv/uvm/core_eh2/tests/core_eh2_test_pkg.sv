// SPDX-License-Identifier: Apache-2.0
// EH2 Core Test Package
//
// Central package for all EH2 UVM test infrastructure.
// Based on Ibex's core_ibex_test_pkg pattern.
// Includes: report server, sequence libraries, virtual sequences,
// base test, and test library.

package core_eh2_test_pkg;

  `include "uvm_macros.svh"
  import uvm_pkg::*;
  import core_eh2_env_pkg::*;
  import axi4_agent_pkg::*;
  import eh2_trace_agent_pkg::*;
  import eh2_irq_agent_pkg::*;
  import eh2_jtag_agent_pkg::*;
  import eh2_cosim_agent_pkg::*;
  import eh2_halt_run_agent_pkg::*;

  // Instruction tracking type (used by directed tests)
  typedef struct {
    bit [6:0]  opcode;
    bit [2:0]  funct3;
    bit [6:0]  funct7;
    bit [11:0] system_imm;
  } instr_t;

  // Run scheduling modes for new_seq_lib
  typedef enum bit [1:0] {
    SingleRun,    // Single iteration
    InfiniteRuns, // Run forever until stop is specified
    MultipleRuns  // Multiple runs with configurable iteration count
  } run_type_e;

  // Error injection side selection
  typedef enum bit [1:0] {
    IsideErr, // Inject error in instruction side memory
    DsideErr, // Inject error in data side memory
    PickErr   // Pick which memory to inject error in
  } error_type_e;

  `include "core_eh2_report_server.sv"
  `include "core_eh2_seq_lib.sv"
  `include "core_eh2_new_seq_lib.sv"
  `include "core_eh2_vseq.sv"
  `include "core_eh2_base_test.sv"
  `include "core_eh2_test_lib.sv"
  `include "core_eh2_intg_test_lib.sv"

endpackage
