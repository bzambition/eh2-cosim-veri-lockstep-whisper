// SPDX-License-Identifier: Apache-2.0
// EH2 Interrupt Sequencer

class eh2_irq_sequencer extends uvm_sequencer #(eh2_irq_seq_item);

  `uvm_component_utils(eh2_irq_sequencer)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

endclass
