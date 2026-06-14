// SPDX-License-Identifier: Apache-2.0
// EH2 UVM Environment
//
// Top-level verification environment containing all agents, monitors,
// scoreboard, and virtual sequencer.
//
// Architecture:
//   core_eh2_env
//     +-- cfg (core_eh2_env_cfg)
//     +-- vseqr (core_eh2_vseqr)
//     +-- lsu_agent / ifu_agent / sb_agent (AXI4 agents)
//     +-- irq_agent (interrupt agent)
//     +-- jtag_agent (JTAG debug agent)
//     +-- trace_monitor (instruction commit monitor)
//     +-- dut_probe_monitor (register writeback monitor)
//     +-- cosim_scoreboard (co-simulation scoreboard)

class core_eh2_env extends uvm_env;

  `uvm_component_utils(core_eh2_env)

  // Configuration
  core_eh2_env_cfg cfg;

  // Virtual sequencer
  core_eh2_vseqr vseqr;

  // AXI4 agents (passive - monitor only)
  axi4_agent#(`RV_LSU_BUS_TAG) lsu_agent;
  axi4_agent#(`RV_IFU_BUS_TAG) ifu_agent;
  axi4_agent#(`RV_SB_BUS_TAG) sb_agent;

  // Interrupt agent (active - drives interrupts)
  eh2_irq_agent irq_agent;

  // JTAG agent (active - drives debug)
  eh2_jtag_agent jtag_agent;

  // Halt/Run agent (active - drives halt/run)
  eh2_halt_run_agent halt_run_agt;

  // Trace monitor
  eh2_trace_monitor trace_monitor;

  // DUT probe monitor
  eh2_dut_probe_monitor dut_probe_monitor;

  // Co-simulation agent (owns scoreboard + backdoor loading)
  eh2_cosim_agent cosim_agt;

  // Double-fault detection scoreboard
  core_eh2_scoreboard dfd_scoreboard;

  // CSR monitoring interface virtual handle
  virtual eh2_csr_if csr_vif;

  // Instruction monitoring interface virtual handle
  virtual eh2_instr_monitor_if instr_monitor_vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    // Create cfg in constructor so it's available during child build_phase
    cfg = core_eh2_env_cfg::type_id::create("cfg");
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    `uvm_info("env", cfg.convert2string(), UVM_LOW)

    // Virtual sequencer
    vseqr = core_eh2_vseqr::type_id::create("vseqr", this);

    // AXI4 agents — active when error injection is enabled, passive otherwise
    lsu_agent = axi4_agent#(`RV_LSU_BUS_TAG)::type_id::create("lsu_agent", this);
    if (cfg.enable_axi4_error_inject) begin
      uvm_config_db#(uvm_active_passive_enum)::set(this, "lsu_agent", "is_active", UVM_ACTIVE);
    end else begin
      uvm_config_db#(uvm_active_passive_enum)::set(this, "lsu_agent", "is_active", UVM_PASSIVE);
    end

    ifu_agent = axi4_agent#(`RV_IFU_BUS_TAG)::type_id::create("ifu_agent", this);
    uvm_config_db#(uvm_active_passive_enum)::set(this, "ifu_agent", "is_active", UVM_PASSIVE);

    sb_agent = axi4_agent#(`RV_SB_BUS_TAG)::type_id::create("sb_agent", this);
    uvm_config_db#(uvm_active_passive_enum)::set(this, "sb_agent", "is_active", UVM_PASSIVE);

    // Interrupt agent (active)
    irq_agent = eh2_irq_agent::type_id::create("irq_agent", this);
    uvm_config_db#(uvm_active_passive_enum)::set(this, "irq_agent", "is_active", UVM_ACTIVE);

    // JTAG agent (active)
    jtag_agent = eh2_jtag_agent::type_id::create("jtag_agent", this);
    uvm_config_db#(uvm_active_passive_enum)::set(this, "jtag_agent", "is_active", UVM_ACTIVE);

    // Halt/Run agent (active)
    halt_run_agt = eh2_halt_run_agent::type_id::create("halt_run_agt", this);
    uvm_config_db#(uvm_active_passive_enum)::set(this, "halt_run_agt", "is_active", UVM_ACTIVE);

    // Trace monitor
    trace_monitor = eh2_trace_monitor::type_id::create("trace_monitor", this);

    // DUT probe monitor
    dut_probe_monitor = eh2_dut_probe_monitor::type_id::create("dut_probe_monitor", this);

    // Co-simulation agent (only if enabled)
    if (cfg.enable_cosim) begin
      // Create and inject cosim_cfg from config_db so the scoreboard receives
      // memory region mappings (issue 65).  Plusargs MEM_ICCM_BASE,
      // MEM_DCCM_BASE etc. override the defaults set in eh2_cosim_cfg.
      begin
        eh2_cosim_cfg cosim_cfg;
        cosim_cfg = eh2_cosim_cfg::type_id::create("cosim_cfg");
        // Read plusarg overrides for DCCM/ICCM base addresses
        void'($value$plusargs("MEM_ICCM_BASE=%h", cosim_cfg.iccm_base));
        void'($value$plusargs("MEM_ICCM_SIZE=%h", cosim_cfg.iccm_size));
        void'($value$plusargs("MEM_DCCM_BASE=%h", cosim_cfg.dccm_base));
        void'($value$plusargs("MEM_DCCM_SIZE=%h", cosim_cfg.dccm_size));
        // Sync flat fields into struct fields so scoreboard mem_region_t paths work
        cosim_cfg.sync_mem_regions();
        uvm_config_db#(eh2_cosim_cfg)::set(this, "cosim_agt.scoreboard", "cosim_cfg", cosim_cfg);
      end
      cosim_agt = eh2_cosim_agent::type_id::create("cosim_agt", this);
    end

    // Double-fault detection scoreboard
    dfd_scoreboard = core_eh2_scoreboard::type_id::create("dfd_scoreboard", this);

    // CSR monitoring interface
    if (!uvm_config_db#(virtual eh2_csr_if)::get(this, "", "csr_vif", csr_vif))
      `uvm_info("env", "CSR monitoring interface not set (optional)", UVM_LOW)

    // Instruction monitoring interface
    if (!uvm_config_db#(virtual eh2_instr_monitor_if)::get(this, "", "instr_monitor_vif", instr_monitor_vif))
      `uvm_info("env", "Instruction monitoring interface not set (optional)", UVM_LOW)

    // Configure AXI4 error injection on LSU driver (only when active)
    // NOTE: driver is not yet built here (build_phase is top-down, agent's
    // build_phase runs after env's). Configuration is deferred to connect_phase.
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // Configure AXI4 error injection on LSU driver (driver is now built)
    if (cfg.enable_axi4_error_inject && lsu_agent.driver != null) begin
      lsu_agent.driver.enable_error_inject = 1;
      lsu_agent.driver.error_pct           = cfg.axi4_error_pct;
      `uvm_info("env", $sformatf("AXI4 error injection enabled on LSU (pct=%0d)", cfg.axi4_error_pct), UVM_LOW)
    end

    // Connect trace monitor to co-simulation agent's scoreboard
    if (cfg.enable_cosim && cosim_agt != null) begin
      trace_monitor.ap.connect(cosim_agt.scoreboard.trace_fifo.analysis_export);
    end

    // Connect DUT probe monitor to co-simulation agent's scoreboard
    if (cfg.enable_cosim && cosim_agt != null) begin
      dut_probe_monitor.ap.connect(cosim_agt.scoreboard.dut_probe_fifo.analysis_export);
    end

    // Connect LSU AXI4 monitor to co-simulation agent
    if (cfg.enable_cosim && cosim_agt != null) begin
      lsu_agent.ap.connect(cosim_agt.dmem_port);
    end

    // Connect trace monitor to double-fault detection scoreboard
    trace_monitor.ap.connect(dfd_scoreboard.trace_fifo.analysis_export);

    // Wire sub-sequencers to virtual sequencer
    vseqr.irq_seqr      = irq_agent.sequencer;
    vseqr.jtag_seqr     = jtag_agent.sequencer;
    vseqr.halt_run_seqr = halt_run_agt.sequencer;
  endfunction

endclass
