// SPDX-License-Identifier: Apache-2.0
// EH2 Trace Agent Package
//
// UVM package for EH2 trace interface monitoring.
// Contains trace sequence item, trace monitor, and DUT probe monitor.

package eh2_trace_agent_pkg;

  `include "uvm_macros.svh"
  import uvm_pkg::*;

  localparam int EH2_WB_SRC_REGULAR = 0;
  localparam int EH2_WB_SRC_DIV     = 1;
  localparam int EH2_WB_SRC_NB_LOAD = 2;

  // Trace agent components
  `include "eh2_trace_seq_item.sv"
  `include "eh2_trace_monitor.sv"
  `include "eh2_dut_probe_monitor.sv"

endpackage
