// SPDX-License-Identifier: Apache-2.0
// Halt/Run Sequence Item for EH2 Verification

class eh2_halt_run_seq_item extends uvm_sequence_item;

  // Action type
  typedef enum bit [1:0] {
    HALT_CORE    = 2'b00,
    RUN_CORE     = 2'b01,
    RESET_RUN    = 2'b10,
    CPU_HALT     = 2'b11
  } action_e;

  rand action_e action;
  rand int unsigned delay;  // Delay before applying (clock cycles)

  constraint c_reasonable_delay {
    delay inside {[0:100]};
  }

  `uvm_object_utils_begin(eh2_halt_run_seq_item)
    `uvm_field_enum(action_e, action, UVM_ALL_ON)
    `uvm_field_int(delay, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "eh2_halt_run_seq_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("action=%s delay=%0d", action.name(), delay);
  endfunction

endclass
