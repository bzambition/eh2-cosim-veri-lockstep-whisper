// SPDX-License-Identifier: Apache-2.0
// AXI4 Agent Package
//
// UVM package for AXI4 protocol agent.
// Contains all agent components: sequence item, driver, monitor,
// sequencer, and agent.

package axi4_agent_pkg;

  `include "uvm_macros.svh"
  import uvm_pkg::*;

  // Agent components
  `include "axi4_seq_item.sv"
  `include "axi4_driver.sv"
  `include "axi4_monitor.sv"
  `include "axi4_sequencer.sv"
  `include "axi4_agent.sv"

endpackage
