// SPDX-License-Identifier: Apache-2.0
// EH2 Interrupt Sequence
//
// Simple sequence for sending interrupt transactions.

class eh2_irq_seq extends uvm_sequence #(eh2_irq_seq_item);

  `uvm_object_utils(eh2_irq_seq)

  eh2_irq_seq_item txn;

  function new(string name = "eh2_irq_seq");
    super.new(name);
  endfunction

  virtual task body();
    if (txn != null) begin
      start_item(txn);
      finish_item(txn);
    end
  endtask

  // Convenience: send an interrupt transaction
  static task send_irq(uvm_sequencer_base seqr, eh2_irq_seq_item irq_txn);
    eh2_irq_seq seq = new("irq_seq");
    seq.txn = irq_txn;
    seq.start(seqr);
  endtask

endclass
