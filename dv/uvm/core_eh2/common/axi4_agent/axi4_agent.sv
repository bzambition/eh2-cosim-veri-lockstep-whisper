// SPDX-License-Identifier: Apache-2.0
// AXI4 Agent - Top-level agent component
//
// UVM agent for AXI4 protocol. Contains:
//   - axi4_driver: Responds to AXI4 master requests
//   - axi4_monitor: Observes transactions for scoreboard/coverage
//   - axi4_sequencer: Controls transaction generation
//
// Configuration:
//   - is_active: UVM_ACTIVE (with driver) or UVM_PASSIVE (monitor only)
//   - agent_name: Name for debug messages
//
// Usage:
//   The agent is configured as ACTIVE by default. For monitoring-only
//   scenarios (when RTL memory model handles responses), set to PASSIVE.

class axi4_agent #(int ID_WIDTH = 4) extends uvm_agent;

  `uvm_component_param_utils(axi4_agent#(ID_WIDTH))

  // Components
  axi4_driver#(ID_WIDTH) driver;
  axi4_monitor#(ID_WIDTH) monitor;
  axi4_sequencer sequencer;

  // Analysis port (from monitor)
  uvm_analysis_port #(axi4_seq_item) ap;

  // Configuration
  string agent_name = "axi4_agent";

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // Always create monitor
    monitor = axi4_monitor#(ID_WIDTH)::type_id::create("monitor", this);

    // Create driver and sequencer only if active
    if (get_is_active() == UVM_ACTIVE) begin
      driver    = axi4_driver#(ID_WIDTH)::type_id::create("driver", this);
      sequencer = axi4_sequencer::type_id::create("sequencer", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // Connect monitor analysis port
    ap = monitor.ap;

    // Connect driver to sequencer (if active)
    if (get_is_active() == UVM_ACTIVE) begin
      driver.seq_item_port.connect(sequencer.seq_item_export);
    end
  endfunction

endclass
