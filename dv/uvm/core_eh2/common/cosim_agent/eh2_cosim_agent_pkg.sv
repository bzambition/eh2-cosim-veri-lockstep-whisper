// SPDX-License-Identifier: Apache-2.0
// EH2 Co-simulation Agent Package
//
// UVM package for co-simulation verification.
// Contains configuration, DPI declarations, scoreboard, and agent.

package eh2_cosim_agent_pkg;

  `include "uvm_macros.svh"
  import uvm_pkg::*;
  import eh2_trace_agent_pkg::*;
  import axi4_agent_pkg::*;

  // Configuration object
  `include "eh2_cosim_cfg.sv"

  // DPI declarations
  `include "cosim_dpi.svh"

  // Co-simulation scoreboard
  `include "eh2_cosim_scoreboard.sv"

  // Top-level agent
  `include "eh2_cosim_agent.sv"

endpackage
