// SPDX-License-Identifier: Apache-2.0
// EH2 Trace Monitor - Monitors instruction commits
//
// Observes the EH2 trace interface and captures committed instructions.
// Each committed instruction is sent to the analysis port as a
// eh2_trace_seq_item.
//
// The monitor handles:
//   - Two instructions per cycle (i0 and i1)
//   - Multiple threads (default: 1)
//   - Exception detection
//   - Cycle counting

class eh2_trace_monitor extends uvm_monitor;

  `uvm_component_utils(eh2_trace_monitor)

  // Virtual interfaces
  virtual eh2_trace_intf #(.NUM_THREADS(`RV_NUM_THREADS)) vif;
  virtual eh2_dut_probe_if #(.NUM_THREADS(`RV_NUM_THREADS)) probe_vif;

  // Analysis port
  uvm_analysis_port #(eh2_trace_seq_item) ap;

  // Statistics
  int commit_count;
  int exception_count;
  int cycle_count;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (!uvm_config_db#(virtual eh2_trace_intf #(.NUM_THREADS(`RV_NUM_THREADS)))::get(this, "", "vif", vif)) begin
      `uvm_fatal("trace_monitor", "Could not get trace virtual interface")
    end
    // DUT probe interface is optional - cosim notifications won't work without it
    if (!uvm_config_db#(virtual eh2_dut_probe_if #(.NUM_THREADS(`RV_NUM_THREADS)))::get(this, "", "probe_vif", probe_vif)) begin
      `uvm_warning("trace_monitor", "Could not get DUT probe interface - interrupt/debug state will be zero")
    end
  endfunction

  task run_phase(uvm_phase phase);
    fork
      monitor_trace();
    join
  endtask

  // Populate trace item with interrupt/debug/NMI state from DUT probe
  function void populate_cosim_state(eh2_trace_seq_item txn);
    if (probe_vif != null) begin
      txn.debug_req = probe_vif.debug_req[txn.thread_id];
      txn.nmi       = probe_vif.nmi[txn.thread_id];
      txn.nmi_int   = probe_vif.nmi_int[txn.thread_id];
      txn.mip       = probe_vif.mip[txn.thread_id];
      txn.mcycle    = probe_vif.mcycle[txn.thread_id];
    end else begin
      txn.debug_req = 0;
      txn.nmi       = 0;
      txn.nmi_int   = 0;
      txn.mip       = 0;
      txn.mcycle    = 0;
    end
  endfunction

  // Monitor trace interface
  task monitor_trace();
    eh2_trace_seq_item txn;

    forever begin
      @(posedge vif.clk iff vif.rst_n);

      cycle_count++;

      // Monitor thread 0, instruction 0 (i0)
      if (vif.t0_i0_valid) begin
        txn = eh2_trace_seq_item::type_id::create("trace_txn");
        txn.thread_id   = 0;
        txn.slot        = 0;
        txn.pc          = vif.t0_i0_pc;
        txn.insn        = vif.t0_i0_insn;
        txn.exception   = vif.t0_i0_exception;
        txn.ecause      = vif.t0_i0_ecause;
        txn.interrupt   = vif.interrupt[0][0];
        txn.tval        = vif.tval[0];
        txn.commit_time = $time;
        txn.cycle_count = cycle_count;

        // RVFI-equivalent writeback view from RTL trace packet (lane 0).
        txn.wb_valid    = vif.t0_i0_wb_valid;
        txn.wb_dest     = vif.t0_i0_wb_addr;
        txn.wb_data     = vif.t0_i0_wb_data;
        txn.wb_suppress = 0;
        txn.wb_source   = EH2_WB_SRC_REGULAR;

        // Sample interrupt/debug/NMI/mcycle state for Spike notification
        populate_cosim_state(txn);

        // Capture current wb_seq for async-wb correlation (issue 66)
        if (probe_vif != null) txn.wb_tag = probe_vif.wb_seq;

        commit_count++;
        if (txn.exception) exception_count++;

        // Snapshot trap CSRs when exception or interrupt
        if (txn.exception || txn.interrupt) begin
          if (probe_vif != null) begin
            txn.dut_mtvec  = probe_vif.mtvec[txn.thread_id];
            txn.dut_mepc   = probe_vif.mepc[txn.thread_id];
            txn.dut_mcause = probe_vif.mcause[txn.thread_id];
            txn.dut_mtval  = probe_vif.mtval[txn.thread_id];  // from RTL TLU mtval register (issue 64)
          end else begin
            txn.dut_mtval  = txn.tval;  // fallback from RTL trace packet
          end
        end

        `uvm_info("trace_monitor", $sformatf("Commit: %s wb=%0b rd=x%0d wdata=%08x",
          txn.convert2string(), txn.wb_valid, txn.wb_dest, txn.wb_data), UVM_HIGH)
        ap.write(txn);
      end

      // Monitor thread 0, instruction 1 (i1)
      if (vif.t0_i1_valid) begin
        txn = eh2_trace_seq_item::type_id::create("trace_txn");
        txn.thread_id   = 0;
        txn.slot        = 1;
        txn.pc          = vif.t0_i1_pc;
        txn.insn        = vif.t0_i1_insn;
        txn.exception   = vif.t0_i1_exception;
        txn.ecause      = vif.t0_i1_ecause;
        txn.interrupt   = vif.interrupt[0][1];
        txn.tval        = vif.tval[0];
        txn.commit_time = $time;
        txn.cycle_count = cycle_count;

        // RVFI-equivalent writeback view from RTL trace packet (lane 1).
        txn.wb_valid    = vif.t0_i1_wb_valid;
        txn.wb_dest     = vif.t0_i1_wb_addr;
        txn.wb_data     = vif.t0_i1_wb_data;
        txn.wb_suppress = 0;
        txn.wb_source   = EH2_WB_SRC_REGULAR;

        // Sample interrupt/debug/NMI/mcycle state for Spike notification
        populate_cosim_state(txn);

        // Capture current wb_seq for async-wb correlation (issue 66)
        if (probe_vif != null) txn.wb_tag = probe_vif.wb_seq;

        commit_count++;
        if (txn.exception) exception_count++;

        // Snapshot trap CSRs when exception or interrupt
        if (txn.exception || txn.interrupt) begin
          if (probe_vif != null) begin
            txn.dut_mtvec  = probe_vif.mtvec[txn.thread_id];
            txn.dut_mepc   = probe_vif.mepc[txn.thread_id];
            txn.dut_mcause = probe_vif.mcause[txn.thread_id];
            txn.dut_mtval  = probe_vif.mtval[txn.thread_id];  // from RTL TLU mtval register (issue 64)
          end else begin
            txn.dut_mtval  = txn.tval;  // fallback from RTL trace packet
          end
        end

        `uvm_info("trace_monitor", $sformatf("Commit: %s wb=%0b rd=x%0d wdata=%08x",
          txn.convert2string(), txn.wb_valid, txn.wb_dest, txn.wb_data), UVM_HIGH)
        ap.write(txn);
      end
    end
  endtask

  // Report statistics
  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("trace_monitor", $sformatf("=== Trace Monitor Statistics ==="), UVM_LOW)
    `uvm_info("trace_monitor", $sformatf("Total commits: %0d", commit_count), UVM_LOW)
    `uvm_info("trace_monitor", $sformatf("Total exceptions: %0d", exception_count), UVM_LOW)
    `uvm_info("trace_monitor", $sformatf("Total cycles: %0d", cycle_count), UVM_LOW)
    if (cycle_count > 0) begin
      `uvm_info("trace_monitor", $sformatf("IPC: %0.2f", real'(commit_count) / real'(cycle_count)), UVM_LOW)
    end
  endfunction

endclass
