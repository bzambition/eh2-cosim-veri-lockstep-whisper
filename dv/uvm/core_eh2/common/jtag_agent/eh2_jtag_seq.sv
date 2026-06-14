// SPDX-License-Identifier: Apache-2.0
// EH2 JTAG Sequence
//
// Simple sequence for sending JTAG/DMI transactions.

class eh2_jtag_seq extends uvm_sequence #(eh2_jtag_seq_item);

  `uvm_object_utils(eh2_jtag_seq)

  // Transaction to send
  eh2_jtag_seq_item txn;

  function new(string name = "eh2_jtag_seq");
    super.new(name);
  endfunction

  virtual task body();
    if (txn != null) begin
      start_item(txn);
      finish_item(txn);
    end
  endtask

  // Convenience: send a write transaction
  static task send_write(uvm_sequencer_base seqr, bit [6:0] addr, bit [31:0] data);
    eh2_jtag_seq seq = new("jtag_write_seq");
    seq.txn = eh2_jtag_seq_item::type_id::create("txn");
    seq.txn.op = eh2_jtag_seq_item::JTAG_WRITE;
    seq.txn.addr = addr;
    seq.txn.wdata = data;
    seq.start(seqr);
  endtask

  // Convenience: send a read transaction
  static task send_read(uvm_sequencer_base seqr, bit [6:0] addr, output bit [31:0] data);
    eh2_jtag_seq seq = new("jtag_read_seq");
    seq.txn = eh2_jtag_seq_item::type_id::create("txn");
    seq.txn.op = eh2_jtag_seq_item::JTAG_READ;
    seq.txn.addr = addr;
    seq.start(seqr);
    data = seq.txn.rdata;
  endtask

endclass
