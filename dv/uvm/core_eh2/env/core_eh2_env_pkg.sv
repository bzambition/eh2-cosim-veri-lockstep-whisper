// SPDX-License-Identifier: Apache-2.0
// EH2 Core Environment Package
//
// Unified package that imports all agent packages and includes
// environment components. Modeled after ibex's core_ibex_env_pkg.sv.

`include "uvm_macros.svh"

package core_eh2_env_pkg;

  import uvm_pkg::*;
  import axi4_agent_pkg::*;
  import eh2_trace_agent_pkg::*;
  import eh2_irq_agent_pkg::*;
  import eh2_jtag_agent_pkg::*;
  import eh2_halt_run_agent_pkg::*;

  `include "core_eh2_vseqr.sv"
  `include "core_eh2_env_cfg.sv"
  `include "core_eh2_scoreboard.sv"
  `include "core_eh2_env.sv"

endpackage
