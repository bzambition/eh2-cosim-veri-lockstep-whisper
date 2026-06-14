// SPDX-License-Identifier: Apache-2.0
// EH2 Co-simulation Agent
//
// Top-level UVM agent for co-simulation verification.
// Owns the cosim scoreboard and provides backdoor memory
// loading utilities for testbench initialization.
//
// Based on ibex's ibex_cosim_agent pattern.
// EH2 differs from Ibex in that:
//   - No dedicated RVFI/ifetch/ifetch_pmp monitors (EH2 uses trace + DUT probe)
//   - Memory traffic comes from AXI4 agents (not mem_intf agents)
//   - Scoreboard receives data via env-level connect_phase

class eh2_cosim_agent extends uvm_agent;

  `uvm_component_utils(eh2_cosim_agent)

  // Co-simulation scoreboard
  eh2_cosim_scoreboard scoreboard;

  // External analysis exports for memory traffic
  // (connected by env to AXI4 agent monitors)
  uvm_analysis_export #(axi4_seq_item) dmem_port;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    scoreboard = eh2_cosim_scoreboard::type_id::create("scoreboard", this);
    dmem_port  = new("dmem_port", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    // Connect external memory port to scoreboard's LSU AXI FIFO
    dmem_port.connect(scoreboard.lsu_axi_fifo.analysis_export);
  endfunction

  // Backdoor-write a single byte into the Spike memory model
  function void write_mem_byte(bit [31:0] addr, bit [7:0] data);
    if (scoreboard.cosim_handle != null) begin
      riscv_cosim_write_mem_byte(scoreboard.cosim_handle, int'(addr), int'(data));
    end
  endfunction

  // Backdoor-write a 32-bit word (little-endian) into the Spike memory model
  function void write_mem_word(bit [31:0] addr, bit [31:0] data);
    write_mem_byte(addr,     data[7:0]);
    write_mem_byte(addr + 1, data[15:8]);
    write_mem_byte(addr + 2, data[23:16]);
    write_mem_byte(addr + 3, data[31:24]);
  endfunction

  // Load a binary file into the Spike memory model
  function void load_binary_to_mem(bit [31:0] base_addr, string bin_path);
    scoreboard.load_binary(bin_path, base_addr);
  endfunction

  // Flush all scoreboard state (called on reset)
  function void reset();
    scoreboard.flush_state();
  endfunction

endclass
