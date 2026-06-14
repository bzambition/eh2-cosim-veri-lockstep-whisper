// SPDX-License-Identifier: Apache-2.0
// EH2 Virtual Sequencer
//
// Coordinates all sequencers in the environment.
// Used by the virtual sequence to orchestrate stimulus.

class core_eh2_vseqr extends uvm_sequencer;

  `uvm_component_utils(core_eh2_vseqr)

  // Sub-sequencers (use specific types for type-safe access)
  eh2_irq_sequencer              irq_seqr;
  eh2_jtag_sequencer             jtag_seqr;
  uvm_sequencer #(eh2_halt_run_seq_item) halt_run_seqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

endclass
