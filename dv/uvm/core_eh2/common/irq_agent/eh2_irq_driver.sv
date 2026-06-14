// SPDX-License-Identifier: Apache-2.0
// EH2 Interrupt Driver
//
// Drives interrupt signals to the DUT.
// Handles 127 external interrupts, timer interrupt, and software interrupt.
// Properly handles reset: kills orphan fork threads and clears signals.

class eh2_irq_driver extends uvm_driver #(eh2_irq_seq_item);

  `uvm_component_utils(eh2_irq_driver)

  // Virtual interface
  virtual eh2_irq_intf vif;

  // Process handle for background de-assert threads (killable on reset)
  process bg_process;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (!uvm_config_db#(virtual eh2_irq_intf)::get(this, "", "irq_vif", vif)) begin
      `uvm_fatal("irq_driver", "Could not get IRQ virtual interface")
    end
  endfunction

  task run_phase(uvm_phase phase);
    eh2_irq_seq_item txn;

    forever begin
      seq_item_port.get_next_item(txn);
      drive_interrupt(txn);
      seq_item_port.item_done();
    end
  endtask

  // Drive interrupt transaction
  // Non-blocking: asserts signal immediately, schedules de-assert if duration > 0
  // For duration == 0: asserts for one clock cycle then de-asserts (pulse)
  task drive_interrupt(eh2_irq_seq_item txn);
    case (txn.irq_type)
      eh2_irq_seq_item::IRQ_TIMER: begin
        vif.timer_int <= txn.irq_val;
        if (txn.duration > 0) begin
          // Non-blocking: schedule de-assert in background
          fork
            begin
              bg_process = process::self();
              repeat (txn.duration) @(posedge vif.clk);
              vif.timer_int <= 1'b0;
            end
          join_none
        end else begin
          // Pulse: de-assert on next clock edge
          @(posedge vif.clk);
          vif.timer_int <= 1'b0;
        end
      end

      eh2_irq_seq_item::IRQ_SOFTWARE: begin
        vif.soft_int <= txn.irq_val;
        if (txn.duration > 0) begin
          fork
            begin
              bg_process = process::self();
              repeat (txn.duration) @(posedge vif.clk);
              vif.soft_int <= 1'b0;
            end
          join_none
        end else begin
          @(posedge vif.clk);
          vif.soft_int <= 1'b0;
        end
      end

      eh2_irq_seq_item::IRQ_EXTERNAL: begin
        vif.extintsrc_req[txn.irq_id] <= txn.irq_val;
        if (txn.duration > 0) begin
          fork
            begin
              bg_process = process::self();
              repeat (txn.duration) @(posedge vif.clk);
              vif.extintsrc_req[txn.irq_id] <= 1'b0;
            end
          join_none
        end else begin
          @(posedge vif.clk);
          vif.extintsrc_req[txn.irq_id] <= 1'b0;
        end
      end

      eh2_irq_seq_item::IRQ_NMI: begin
        vif.nmi_int <= txn.irq_val;
        if (txn.duration > 0) begin
          fork
            begin
              bg_process = process::self();
              repeat (txn.duration) @(posedge vif.clk);
              vif.nmi_int <= 1'b0;
            end
          join_none
        end else begin
          @(posedge vif.clk);
          vif.nmi_int <= 1'b0;
        end
      end
    endcase
  endtask

  // Reset handling: kill background threads and clear all IRQ signals
  task pre_reset_phase(uvm_phase phase);
    if (bg_process != null) begin
      bg_process.kill();
      bg_process = null;
    end
    if (vif != null) begin
      vif.timer_int     <= '0;
      vif.soft_int      <= '0;
      vif.extintsrc_req <= '0;
      vif.nmi_int       <= 1'b0;
    end
  endtask

endclass
