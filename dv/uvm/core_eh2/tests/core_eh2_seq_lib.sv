// SPDX-License-Identifier: Apache-2.0
// EH2 Sequence Library
//
// Reusable stimulus sequences for interrupt, debug, and memory response.
// Modeled after Ibex core_ibex_seq_lib.sv.
//
// Sequences:
//   core_eh2_base_seq        - Base class with interval/delay randomization
//   irq_raise_seq            - Raise multiple external interrupts
//   irq_raise_single_seq     - Raise a single interrupt
//   irq_raise_nmi_seq        - Raise NMI
//   irq_drop_seq             - Deassert all interrupts
//   debug_seq                - Debug halt/resume (stress or single)
//   fetch_enable_seq         - Toggle fetch-enable randomly

`include "uvm_macros.svh"
import uvm_pkg::*;
import eh2_irq_agent_pkg::*;
import eh2_jtag_agent_pkg::*;

// ---------------------------------------------------------------------------
// Base sequence with configurable interval and stop mechanism
// ---------------------------------------------------------------------------
class core_eh2_base_seq extends uvm_sequence;

  `uvm_object_utils(core_eh2_base_seq)

  int unsigned interval = 500;    // Max cycles between events
  int unsigned delay_min = 100;   // Min initial delay (ns)
  int unsigned delay_max = 5000;  // Max initial delay (ns)
  bit            stopped = 0;     // Stop flag

  function new(string name = "core_eh2_base_seq");
    super.new(name);
  endfunction

  // Randomized initial delay
  task rand_delay();
    int d;
    d = $urandom_range(delay_min, delay_max);
    #(d * 1ns);
  endtask

  // Randomized interval between events
  task rand_interval();
    int d;
    d = $urandom_range(1, interval);
    #(d * 10ns);
  endtask

  // Stop the sequence
  virtual task stop();
    stopped = 1;
  endtask

  // Wait for stop (non-blocking check)
  virtual task wait_for_stop();
    wait (stopped);
  endtask

endclass

// ---------------------------------------------------------------------------
// IRQ Raise Sequence - Raises multiple external interrupts
// ---------------------------------------------------------------------------
class irq_raise_seq extends core_eh2_base_seq;

  `uvm_object_utils(irq_raise_seq)

  // Virtual interface to drive interrupts
  virtual eh2_irq_intf irq_vif;

  int unsigned max_irq_id = 127;  // Max external interrupt ID
  int unsigned num_irqs = 3;      // Number of interrupts to raise per event

  function new(string name = "irq_raise_seq");
    super.new(name);
  endfunction

  virtual task body();
    int id;
    rand_delay();
    forever begin
      if (stopped) return;
      // Raise multiple random interrupts
      repeat (num_irqs) begin
        id = $urandom_range(1, max_irq_id);
        irq_vif.extintsrc_req[id] <= 1'b1;
      end
      rand_interval();
      // Drop all
      irq_vif.extintsrc_req <= '0;
      rand_interval();
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// IRQ Raise Single Sequence - Raises one interrupt at a time
// ---------------------------------------------------------------------------
class irq_raise_single_seq extends core_eh2_base_seq;

  `uvm_object_utils(irq_raise_single_seq)

  virtual eh2_irq_intf irq_vif;

  int unsigned max_irq_id = 127;

  function new(string name = "irq_raise_single_seq");
    super.new(name);
  endfunction

  virtual task body();
    int id;
    rand_delay();
    forever begin
      if (stopped) return;
      id = $urandom_range(1, max_irq_id);
      irq_vif.extintsrc_req[id] <= 1'b1;
      rand_interval();
      irq_vif.extintsrc_req[id] <= 1'b0;
      rand_interval();
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// IRQ NMI Sequence - Raises non-maskable interrupt
// ---------------------------------------------------------------------------
class irq_raise_nmi_seq extends core_eh2_base_seq;

  `uvm_object_utils(irq_raise_nmi_seq)

  virtual eh2_irq_intf irq_vif;

  function new(string name = "irq_raise_nmi_seq");
    super.new(name);
  endfunction

  virtual task body();
    rand_delay();
    forever begin
      if (stopped) return;
      irq_vif.nmi_int <= 1'b1;
      rand_interval();
      irq_vif.nmi_int <= 1'b0;
      rand_interval();
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// IRQ Drop Sequence - Deasserts all interrupts
// ---------------------------------------------------------------------------
class irq_drop_seq extends core_eh2_base_seq;

  `uvm_object_utils(irq_drop_seq)

  virtual eh2_irq_intf irq_vif;

  function new(string name = "irq_drop_seq");
    super.new(name);
  endfunction

  virtual task body();
    rand_delay();
    forever begin
      if (stopped) return;
      // Drop all interrupts
      irq_vif.extintsrc_req <= '0;
      irq_vif.timer_int <= '0;
      irq_vif.soft_int <= '0;
      irq_vif.nmi_int <= 1'b0;
      rand_interval();
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// Debug Sequence - Drives debug halt/resume via JTAG
// ---------------------------------------------------------------------------
class debug_seq extends core_eh2_base_seq;

  `uvm_object_utils(debug_seq)

  // Sequencer to send JTAG transactions
  uvm_sequencer #(eh2_jtag_seq_item) jtag_seqr;

  bit stress_mode = 0;  // 1 = continuous, 0 = single

  function new(string name = "debug_seq");
    super.new(name);
  endfunction

  virtual task body();
    rand_delay();
    if (stress_mode) begin
      // Continuous debug stimulus for stress tests only.
      forever begin
        if (stopped) return;
        send_debug_command_walk();
        rand_interval();
      end
    end else begin
      // Finite debug stimulus for directed coverage tests. This avoids
      // holding the core in debug mode until the mailbox timeout expires.
      send_debug_command_walk();
    end
  endtask

  virtual task dmi_gap(int unsigned cycles = 40);
    repeat (cycles) #(10ns);
  endtask

  virtual task send_debug_command_walk();
    bit [31:0] dccm_addr;
    send_dmactive();
    dmi_gap(20);
    send_halt();
    dmi_gap(120);
    send_core_register_read();
    dmi_gap(160);
    for (int unsigned i = 0; i < 5; i++) begin
      dccm_addr = 32'hf0040000 + (i * 32'h4);
      send_core_local_memory_read(dccm_addr);
      dmi_gap(180);
    end
    send_external_system_bus_read();
    dmi_gap(220);
    send_direct_system_bus_read_write();
    dmi_gap(220);
    send_resume();
    dmi_gap(120);
    clear_resume();
  endtask

  virtual task send_dmactive();
    eh2_jtag_seq::send_write(jtag_seqr,
      eh2_jtag_seq_item::DMI_DMCONTROL, 32'h00000001);
  endtask

  virtual task send_halt();
    eh2_jtag_seq::send_write(jtag_seqr,
      eh2_jtag_seq_item::DMI_DMCONTROL, 32'h80000001);
  endtask

  virtual task send_core_register_read();
    // Abstract register command: read x0 with transfer=1 and 32-bit size.
    eh2_jtag_seq::send_write(jtag_seqr,
      eh2_jtag_seq_item::DMI_COMMAND, 32'h00221000);
  endtask

  virtual task send_core_local_memory_read(bit [31:0] addr = 32'hf0040000);
    // Debug memory command targeting DCCM. This goes through CORE_CMD_* and
    // exercises the DMA/debug memory path rather than the external SB path.
    eh2_jtag_seq::send_write(jtag_seqr,
      eh2_jtag_seq_item::DMI_DATA1, addr);
    dmi_gap(20);
    eh2_jtag_seq::send_write(jtag_seqr,
      eh2_jtag_seq_item::DMI_COMMAND, 32'h02200000);
  endtask

  virtual task send_external_system_bus_read();
    // Debug memory command targeting external AXI memory. This drives
    // SB_CMD_START/SEND/RESP in eh2_dbg and the SB AXI slave.
    eh2_jtag_seq::send_write(jtag_seqr,
      eh2_jtag_seq_item::DMI_DATA1, 32'h80000000);
    dmi_gap(20);
    eh2_jtag_seq::send_write(jtag_seqr,
      eh2_jtag_seq_item::DMI_COMMAND, 32'h02200000);
  endtask

  virtual task send_direct_system_bus_read_write();
    // Direct system-bus register access covers the standalone sb_state FSM.
    // bit 20 readonaddr starts a read when SBADDRESS0 is written.
    eh2_jtag_seq::send_write(jtag_seqr,
      eh2_jtag_seq_item::DMI_SBCS, 32'h00100000);
    dmi_gap(20);
    eh2_jtag_seq::send_write(jtag_seqr,
      eh2_jtag_seq_item::DMI_SBADDRESS0, 32'h80000000);
    dmi_gap(120);
    eh2_jtag_seq::send_write(jtag_seqr,
      eh2_jtag_seq_item::DMI_SBDATA0, 32'ha5a55a5a);
  endtask

  virtual task send_resume();
    eh2_jtag_seq::send_write(jtag_seqr,
      eh2_jtag_seq_item::DMI_DMCONTROL, 32'h40000001);
  endtask

  virtual task clear_resume();
    eh2_jtag_seq::send_write(jtag_seqr,
      eh2_jtag_seq_item::DMI_DMCONTROL, 32'h00000001);
  endtask

endclass

// ---------------------------------------------------------------------------
// Fetch Enable Sequence - Randomly toggles fetch-enable
// ---------------------------------------------------------------------------
class fetch_enable_seq extends core_eh2_base_seq;

  `uvm_object_utils(fetch_enable_seq)

  virtual interface fetch_enable_intf fetch_vif;

  function new(string name = "fetch_enable_seq");
    super.new(name);
  endfunction

  virtual task body();
    rand_delay();
    forever begin
      if (stopped) return;
      // Disable fetch
      if (fetch_vif != null)
        fetch_vif.fetch_enable <= 1'b0;
      rand_interval();
      // Re-enable fetch
      if (fetch_vif != null)
        fetch_vif.fetch_enable <= 1'b1;
      rand_interval();
    end
  endtask

endclass
