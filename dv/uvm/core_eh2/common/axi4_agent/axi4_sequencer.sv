// SPDX-License-Identifier: Apache-2.0
// AXI4 Sequencer - Controls transaction generation
//
// Standard UVM sequencer for AXI4 transactions.
// Used by the driver to receive sequence items.

class axi4_sequencer extends uvm_sequencer #(axi4_seq_item);

  `uvm_component_utils(axi4_sequencer)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

endclass
