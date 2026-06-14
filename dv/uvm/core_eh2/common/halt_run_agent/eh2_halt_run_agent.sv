// SPDX-License-Identifier: Apache-2.0
// Halt/Run Agent for EH2 Verification
//
// UVM agent for halt/run stimulus and monitoring.

class eh2_halt_run_agent extends uvm_agent;

  `uvm_component_utils(eh2_halt_run_agent)

  eh2_halt_run_driver  driver;
  eh2_halt_run_monitor monitor;
  uvm_sequencer #(eh2_halt_run_seq_item) sequencer;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    monitor = eh2_halt_run_monitor::type_id::create("monitor", this);

    if (get_is_active() == UVM_ACTIVE) begin
      driver    = eh2_halt_run_driver::type_id::create("driver", this);
      sequencer = uvm_sequencer#(eh2_halt_run_seq_item)::type_id::create("sequencer", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (get_is_active() == UVM_ACTIVE) begin
      driver.seq_item_port.connect(sequencer.seq_item_export);
    end
  endfunction

endclass
