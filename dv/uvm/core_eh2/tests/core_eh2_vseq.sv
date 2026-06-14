// SPDX-License-Identifier: Apache-2.0
// EH2 Virtual Sequence
//
// Orchestrates all stimulus sequences from a single control point.
// Modeled after Ibex core_ibex_vseq.sv.
//
// The virtual sequence starts:
//   1. IRQ sequences (single, multiple, NMI, drop) - based on cfg
//   2. Debug sequences (stress, single) - based on cfg
//   3. Fetch-enable sequence - based on cfg
//
// Usage:
//   core_eh2_vseq vseq = core_eh2_vseq::type_id::create("vseq");
//   vseq.cfg = env_cfg;
//   vseq.start(env.vseqr);

`include "uvm_macros.svh"
import uvm_pkg::*;
import core_eh2_env_pkg::*;
import eh2_irq_agent_pkg::*;
import eh2_jtag_agent_pkg::*;

class core_eh2_vseq extends uvm_sequence;

  `uvm_object_utils(core_eh2_vseq)

  // Configuration
  core_eh2_env_cfg cfg;

  // Virtual sequencer
  core_eh2_vseqr vseqr;

  // Sub-sequences
  irq_raise_single_seq irq_single_h;
  irq_raise_seq        irq_multi_h;
  irq_raise_nmi_seq    irq_nmi_h;
  irq_drop_seq         irq_drop_h;
  debug_seq            debug_stress_h;
  debug_seq            debug_single_h;
  fetch_enable_seq     fetch_en_h;

  function new(string name = "core_eh2_vseq");
    super.new(name);
  endfunction

  virtual task pre_body();
    if (cfg == null) begin
      `uvm_fatal("vseq", "cfg is null - must set before starting vseq")
    end
    if (vseqr == null && !$cast(vseqr, m_sequencer)) begin
      `uvm_fatal("vseq", "m_sequencer is not a core_eh2_vseqr")
    end
  endtask

  virtual task body();
    `uvm_info("vseq", "Starting virtual sequence", UVM_LOW)

    fork
      // IRQ sequences
      begin
        if (cfg.enable_irq_single_seq) begin
          irq_single_h = irq_raise_single_seq::type_id::create("irq_single_h");
          irq_single_h.irq_vif = get_irq_vif();
          irq_single_h.interval = cfg.max_interval;
          irq_single_h.start(null);
        end
      end

      begin
        if (cfg.enable_irq_multiple_seq) begin
          irq_multi_h = irq_raise_seq::type_id::create("irq_multi_h");
          irq_multi_h.irq_vif = get_irq_vif();
          irq_multi_h.interval = cfg.max_interval;
          irq_multi_h.start(null);
        end
      end

      begin
        if (cfg.enable_irq_nmi_seq) begin
          irq_nmi_h = irq_raise_nmi_seq::type_id::create("irq_nmi_h");
          irq_nmi_h.irq_vif = get_irq_vif();
          irq_nmi_h.interval = cfg.max_interval;
          irq_nmi_h.start(null);
        end
      end

      // Debug sequences
      begin
        if (cfg.enable_debug_seq || cfg.enable_debug_stress) begin
          debug_stress_h = debug_seq::type_id::create("debug_stress_h");
          debug_stress_h.jtag_seqr = vseqr.jtag_seqr;
          debug_stress_h.stress_mode = cfg.enable_debug_stress;
          debug_stress_h.interval = cfg.max_interval;
          debug_stress_h.start(null);
        end
      end

      begin
        if (cfg.enable_debug_single) begin
          debug_single_h = debug_seq::type_id::create("debug_single_h");
          debug_single_h.jtag_seqr = vseqr.jtag_seqr;
          debug_single_h.stress_mode = 0;
          debug_single_h.interval = cfg.max_interval;
          debug_single_h.start(null);
        end
      end

      // Fetch-enable sequence
      begin
        if (cfg.enable_fetch_toggle) begin
          fetch_en_h = fetch_enable_seq::type_id::create("fetch_en_h");
          fetch_en_h.interval = cfg.max_interval;
          fetch_en_h.start(null);
        end
      end
    join_none
  endtask

  // Stop all sequences
  virtual task stop();
    if (irq_single_h != null) irq_single_h.stop();
    if (irq_multi_h  != null) irq_multi_h.stop();
    if (irq_nmi_h    != null) irq_nmi_h.stop();
    if (irq_drop_h   != null) irq_drop_h.stop();
    if (debug_stress_h != null) debug_stress_h.stop();
    if (debug_single_h != null) debug_single_h.stop();
    if (fetch_en_h   != null) fetch_en_h.stop();
  endtask

  // Helper: get IRQ virtual interface from config_db
  function virtual eh2_irq_intf get_irq_vif();
    virtual eh2_irq_intf vif;
    if (!uvm_config_db#(virtual eh2_irq_intf)::get(null, "*", "irq_vif", vif)) begin
      `uvm_warning("vseq", "Could not get IRQ virtual interface")
    end
    return vif;
  endfunction

  // Helper tasks for directed stimulus (called from tests)
  virtual task start_irq_raise_single_seq();
    irq_single_h = irq_raise_single_seq::type_id::create("irq_single_h");
    irq_single_h.irq_vif = get_irq_vif();
    irq_single_h.start(null);
  endtask

  virtual task start_irq_raise_seq();
    irq_multi_h = irq_raise_seq::type_id::create("irq_multi_h");
    irq_multi_h.irq_vif = get_irq_vif();
    irq_multi_h.start(null);
  endtask

  virtual task start_nmi_raise_seq();
    irq_nmi_h = irq_raise_nmi_seq::type_id::create("irq_nmi_h");
    irq_nmi_h.irq_vif = get_irq_vif();
    irq_nmi_h.start(null);
  endtask

  virtual task start_irq_drop_seq();
    irq_drop_h = irq_drop_seq::type_id::create("irq_drop_h");
    irq_drop_h.irq_vif = get_irq_vif();
    irq_drop_h.start(null);
  endtask

  virtual task start_debug_stress_seq();
    debug_stress_h = debug_seq::type_id::create("debug_stress_h");
    debug_stress_h.jtag_seqr = vseqr.jtag_seqr;
    debug_stress_h.stress_mode = 1;
    debug_stress_h.start(null);
  endtask

  virtual task start_debug_single_seq();
    debug_single_h = debug_seq::type_id::create("debug_single_h");
    debug_single_h.jtag_seqr = vseqr.jtag_seqr;
    debug_single_h.stress_mode = 0;
    debug_single_h.start(null);
  endtask

endclass
