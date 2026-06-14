// SPDX-License-Identifier: Apache-2.0
// EH2 Interrupt Sequence Item
//
// Represents an interrupt transaction for EH2's PIC controller.
// EH2 supports 127 external interrupt sources plus timer and software interrupts.

class eh2_irq_seq_item extends uvm_sequence_item;

  // Interrupt type
  typedef enum bit [2:0] {
    IRQ_TIMER    = 3'b000,
    IRQ_SOFTWARE = 3'b001,
    IRQ_EXTERNAL = 3'b010,
    IRQ_NMI      = 3'b011
  } irq_type_e;

  // Interrupt fields
  rand irq_type_e irq_type;
  rand bit [6:0]  irq_id;       // External interrupt ID (0-126)
  rand bit        irq_val;      // Interrupt value (1=set, 0=clear)
  rand bit [7:0]  duration;     // Duration in clock cycles (0=one-shot)

  `uvm_object_utils_begin(eh2_irq_seq_item)
    `uvm_field_enum(irq_type_e, irq_type, UVM_ALL_ON)
    `uvm_field_int(irq_id, UVM_ALL_ON)
    `uvm_field_int(irq_val, UVM_ALL_ON)
    `uvm_field_int(duration, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "eh2_irq_seq_item");
    super.new(name);
  endfunction

  // Constraint: valid interrupt ID
  constraint c_valid_id {
    irq_id inside {[0:126]};
  }

  // Constraint: reasonable duration
  constraint c_reasonable_duration {
    duration inside {[0:255]};
  }

  function string convert2string();
    return $sformatf("%s id=%0d val=%0b dur=%0d",
      irq_type.name(), irq_id, irq_val, duration);
  endfunction

endclass
