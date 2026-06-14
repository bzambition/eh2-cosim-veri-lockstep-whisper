// SPDX-License-Identifier: Apache-2.0
// EH2 JTAG Sequencer

class eh2_jtag_sequencer extends uvm_sequencer #(eh2_jtag_seq_item);

  `uvm_component_utils(eh2_jtag_sequencer)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

endclass
