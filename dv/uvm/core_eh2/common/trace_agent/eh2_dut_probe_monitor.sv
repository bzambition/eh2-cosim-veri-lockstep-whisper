// SPDX-License-Identifier: Apache-2.0
// EH2 DUT Probe Monitor — async writeback events only.
//
// Phase 1 (ADR-0004) note: regular pipeline writebacks now ride along the
// trace channel inside eh2_trace_seq_item.wb_*. This monitor exists only to
// surface async events that the trace packet cannot describe in time:
//   - DIV writeback / DIV cancel (long latency, separate writeback port)
//   - Non-blocking load completion (writeback arrives after retire)
//
// The cosim scoreboard treats these as overrides/suppressions for the
// matching trace item.

class eh2_dut_probe_monitor extends uvm_monitor;

  `uvm_component_utils(eh2_dut_probe_monitor)

  virtual eh2_dut_probe_if #(.NUM_THREADS(`RV_NUM_THREADS)) vif;
  uvm_analysis_port #(eh2_trace_seq_item) ap;

  int wb_count;
  int wb_seq_counter;  // global writeback sequence (issue 66)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    wb_seq_counter = 1;  // start from 1 so wb_tag >= 1 always (issue 66)
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (!uvm_config_db#(virtual eh2_dut_probe_if #(.NUM_THREADS(`RV_NUM_THREADS)))::get(this, "", "vif", vif)) begin
      `uvm_warning("dut_probe", "Could not get DUT probe virtual interface - async writeback monitoring disabled")
    end
  endfunction

  task run_phase(uvm_phase phase);
    if (vif != null) begin
      fork
        monitor_division();
        monitor_nb_load();
      join
    end
  endtask

  // Monitor DIV writebacks and DIV-cancel events.
  task monitor_division();
    eh2_trace_seq_item txn;

    forever begin
      @(posedge vif.clk iff vif.rst_n);

      for (int h = 0; h < `RV_NUM_THREADS; h++) begin
        if (vif.div_wren[h] && vif.div_rd[h] != 5'b0) begin
          txn = eh2_trace_seq_item::type_id::create("div_wb_txn");
          txn.thread_id = h;
          txn.slot      = 0;  // Divides are i0-only
          txn.wb_valid  = 1;
          txn.wb_dest   = vif.div_rd[h];
          txn.wb_data   = vif.div_wdata[h];
          txn.wb_source = EH2_WB_SRC_DIV;
          txn.wb_tag    = wb_seq_counter;
          vif.wb_seq    = wb_seq_counter;  // write to interface for trace_monitor (issue 66)
          ap.write(txn);
          `uvm_info("dut_probe", $sformatf("T%0d DIV WB: x%0d = %08x wb_tag=%0d",
            h, vif.div_rd[h], vif.div_wdata[h], wb_seq_counter), UVM_HIGH)
          wb_count++;
          wb_seq_counter++;
        end
        else if (vif.div_cancel[h] && vif.div_cancel_overwrite[h] && vif.div_rd[h] != 5'b0) begin
          // Only forward "overwrite" cancels: these pair with a retired div
          // trace whose architectural writeback was killed by a younger same-rd
          // write. Speculative-flush cancels (no matching trace) are dropped.
          txn = eh2_trace_seq_item::type_id::create("div_cancel_txn");
          txn.thread_id   = h;
          txn.slot        = 0;
          txn.wb_valid    = 1;
          txn.wb_dest     = vif.div_rd[h];
          txn.wb_data     = vif.div_result[h];
          txn.wb_suppress = 1;
          txn.wb_source   = EH2_WB_SRC_DIV;
          txn.wb_tag      = wb_seq_counter;
          vif.wb_seq      = wb_seq_counter;
          ap.write(txn);
          `uvm_info("dut_probe", $sformatf("T%0d DIV OVERWRITE-CANCEL: x%0d = %08x wb_tag=%0d",
            h, vif.div_rd[h], vif.div_result[h], wb_seq_counter), UVM_HIGH)
          wb_count++;
          wb_seq_counter++;
        end
        else if (vif.div_cancel[h] && !vif.div_cancel_overwrite[h]) begin
          `uvm_info("dut_probe", $sformatf(
            "T%0d DIV SPEC-CANCEL: x%0d (dropped, no paired trace)",
            h, vif.div_rd[h]), UVM_HIGH)
        end
      end
    end
  endtask

  // Monitor non-blocking load completions.
  task monitor_nb_load();
    eh2_trace_seq_item txn;

    forever begin
      @(posedge vif.clk iff vif.rst_n);

      for (int h = 0; h < `RV_NUM_THREADS; h++) begin
        if (vif.nb_load_wen[h] && vif.nb_load_waddr[h] != 5'b0) begin
          txn = eh2_trace_seq_item::type_id::create("nb_load_txn");
          txn.thread_id = h;
          txn.slot      = 0;
          txn.wb_valid  = 1;
          txn.wb_dest   = vif.nb_load_waddr[h];
          txn.wb_data   = vif.nb_load_data[h];
          txn.wb_source = EH2_WB_SRC_NB_LOAD;
          txn.wb_tag    = wb_seq_counter;
          vif.wb_seq    = wb_seq_counter;  // issue 66
          ap.write(txn);
          `uvm_info("dut_probe", $sformatf("T%0d NB LOAD: x%0d = %08x wb_tag=%0d",
            h, vif.nb_load_waddr[h], vif.nb_load_data[h], wb_seq_counter), UVM_HIGH)
          wb_count++;
          wb_seq_counter++;
        end
      end
    end
  endtask

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("dut_probe", "=== DUT Probe Statistics (async only) ===", UVM_LOW)
    `uvm_info("dut_probe", $sformatf("Total async writebacks: %0d, wb_seq last: %0d",
              wb_count, wb_seq_counter), UVM_LOW)
  endfunction

endclass
