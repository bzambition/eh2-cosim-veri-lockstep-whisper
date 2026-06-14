// SPDX-License-Identifier: Apache-2.0
// Halt/Run Driver for EH2 Verification
//
// Drives halt/run signals to the DUT via the halt_run interface.

class eh2_halt_run_driver extends uvm_driver #(eh2_halt_run_seq_item);

  `uvm_component_utils(eh2_halt_run_driver)

  virtual eh2_halt_run_intf vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual eh2_halt_run_intf)::get(this, "", "halt_run_vif", vif)) begin
      `uvm_fatal("halt_run_drv", "Failed to get halt_run interface")
    end
  endfunction

  task run_phase(uvm_phase phase);
    eh2_halt_run_seq_item item;

    // Default: no halt request, run request active
    vif.driver_cb.mpc_debug_halt_req <= 1'b0;
    vif.driver_cb.mpc_debug_run_req  <= 1'b1;
    vif.driver_cb.mpc_reset_run_req  <= 1'b1;
    vif.driver_cb.i_cpu_halt_req     <= 1'b0;
    vif.driver_cb.i_cpu_run_req      <= 1'b1;

    forever begin
      seq_item_port.get_next_item(item);

      if (item.delay > 0) begin
        repeat (item.delay) @(posedge vif.clk);
      end

      case (item.action)
        eh2_halt_run_seq_item::HALT_CORE: begin
          `uvm_info("halt_run_drv", "Asserting MPC debug halt", UVM_MEDIUM)
          vif.driver_cb.mpc_debug_halt_req <= 1'b1;
          vif.driver_cb.mpc_debug_run_req  <= 1'b0;
          // Wait for acknowledgment
          repeat (100) begin
            @(posedge vif.clk);
            if (vif.o_cpu_halt_ack) break;
          end
        end

        eh2_halt_run_seq_item::RUN_CORE: begin
          `uvm_info("halt_run_drv", "Asserting MPC debug run", UVM_MEDIUM)
          vif.driver_cb.mpc_debug_halt_req <= 1'b0;
          vif.driver_cb.mpc_debug_run_req  <= 1'b1;
          // Wait for acknowledgment
          repeat (100) begin
            @(posedge vif.clk);
            if (vif.o_cpu_run_ack) break;
          end
        end

        eh2_halt_run_seq_item::RESET_RUN: begin
          `uvm_info("halt_run_drv", "Asserting MPC reset run", UVM_MEDIUM)
          vif.driver_cb.mpc_reset_run_req <= 1'b0;
          repeat (5) @(posedge vif.clk);
          vif.driver_cb.mpc_reset_run_req <= 1'b1;
        end

        eh2_halt_run_seq_item::CPU_HALT: begin
          `uvm_info("halt_run_drv", "Asserting CPU halt request", UVM_MEDIUM)
          vif.driver_cb.i_cpu_halt_req <= 1'b1;
          vif.driver_cb.i_cpu_run_req  <= 1'b0;
          repeat (100) begin
            @(posedge vif.clk);
            if (vif.o_cpu_halt_ack) break;
          end
        end
      endcase

      seq_item_port.item_done();
    end
  endtask

endclass
