// SPDX-License-Identifier: Apache-2.0
// Halt/Run Monitor for EH2 Verification
//
// Monitors halt/run status signals from the DUT.

class eh2_halt_run_monitor extends uvm_monitor;

  `uvm_component_utils(eh2_halt_run_monitor)

  virtual eh2_halt_run_intf vif;

  // Analysis port for halt/run events
  uvm_analysis_port #(eh2_halt_run_seq_item) item_port;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    item_port = new("item_port", this);
    if (!uvm_config_db#(virtual eh2_halt_run_intf)::get(this, "", "halt_run_vif", vif)) begin
      `uvm_fatal("halt_run_mon", "Failed to get halt_run interface")
    end
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.clk);

      // Monitor halt acknowledgment
      if (vif.monitor_cb.o_cpu_halt_ack) begin
        `uvm_info("halt_run_mon", "CPU halt acknowledged", UVM_HIGH)
      end

      // Monitor run acknowledgment
      if (vif.monitor_cb.o_cpu_run_ack) begin
        `uvm_info("halt_run_mon", "CPU run acknowledged", UVM_HIGH)
      end

      // Monitor halt status change
      if (vif.monitor_cb.o_cpu_halt_status) begin
        `uvm_info("halt_run_mon", "CPU is in halt state", UVM_HIGH)
      end
    end
  endtask

endclass
