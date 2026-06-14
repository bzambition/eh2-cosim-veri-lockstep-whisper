// SPDX-License-Identifier: Apache-2.0
// EH2 Interrupt Agent
//
// UVM agent for EH2 interrupt interface.
// Contains driver, sequencer for driving interrupts to DUT.

class eh2_irq_agent extends uvm_agent;

  `uvm_component_utils(eh2_irq_agent)

  eh2_irq_driver    driver;
  eh2_irq_sequencer sequencer;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (get_is_active() == UVM_ACTIVE) begin
      driver    = eh2_irq_driver::type_id::create("driver", this);
      sequencer = eh2_irq_sequencer::type_id::create("sequencer", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    if (get_is_active() == UVM_ACTIVE) begin
      driver.seq_item_port.connect(sequencer.seq_item_export);
    end
  endfunction

endclass
