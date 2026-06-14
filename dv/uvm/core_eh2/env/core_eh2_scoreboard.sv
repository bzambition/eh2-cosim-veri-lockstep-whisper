// SPDX-License-Identifier: Apache-2.0
// EH2 Double-Fault Detection Scoreboard
//
// Monitors for consecutive exceptions that indicate a double-fault condition.
// Based on Ibex's core_ibex_scoreboard pattern.
//
// A double-fault occurs when the processor takes an exception while already
// in an exception handler. This is detected by counting consecutive exceptions
// without a successful instruction retirement between them.

class core_eh2_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(core_eh2_scoreboard)

  // Configuration
  bit  enable_detector = 0;
  int  threshold_consecutive = 100;  // Consecutive exception threshold
  int  threshold_total = 1000;       // Total exception threshold
  bit  fatal_on_threshold = 1;       // 1 = UVM_FATAL, 0 = UVM_ERROR

  // Tracking state
  int  consecutive_exceptions = 0;
  int  total_exceptions = 0;
  int  total_retirements = 0;
  int  max_consecutive_exceptions = 0;

  // Analysis FIFO from trace monitor
  uvm_tlm_analysis_fifo #(eh2_trace_seq_item) trace_fifo;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    trace_fifo = new("trace_fifo", this);

    void'($value$plusargs("enable_double_fault_detector=%b", enable_detector));
    void'($value$plusargs("double_fault_threshold=%d", threshold_consecutive));
    void'($value$plusargs("double_fault_total_threshold=%d", threshold_total));
    void'($value$plusargs("double_fault_fatal=%b", fatal_on_threshold));
  endfunction

  task run_phase(uvm_phase phase);
    if (enable_detector) begin
      fork
        monitor_exceptions();
      join
    end
  endtask

  // Monitor trace items for exception patterns
  task monitor_exceptions();
    eh2_trace_seq_item item;

    forever begin
      trace_fifo.get(item);
      if (item == null) continue;

      total_retirements++;

      if (item.exception) begin
        notify_exception();
      end else begin
        notify_retirement();
      end

      // Check consecutive threshold
      if (consecutive_exceptions >= threshold_consecutive) begin
        if (fatal_on_threshold) begin
          `uvm_fatal("scoreboard", $sformatf(
            "Double-fault detected: %0d consecutive exceptions (threshold: %0d)",
            consecutive_exceptions, threshold_consecutive))
        end else begin
          `uvm_error("scoreboard", $sformatf(
            "Double-fault detected: %0d consecutive exceptions (threshold: %0d)",
            consecutive_exceptions, threshold_consecutive))
        end
      end

      // Check total threshold
      if (total_exceptions >= threshold_total) begin
        if (fatal_on_threshold) begin
          `uvm_fatal("scoreboard", $sformatf(
            "Total exception threshold exceeded: %0d (threshold: %0d)",
            total_exceptions, threshold_total))
        end else begin
          `uvm_error("scoreboard", $sformatf(
            "Total exception threshold exceeded: %0d (threshold: %0d)",
            total_exceptions, threshold_total))
        end
      end
    end
  endtask

  // Called when an exception is observed
  function void notify_exception();
    consecutive_exceptions++;
    total_exceptions++;
    if (consecutive_exceptions > max_consecutive_exceptions)
      max_consecutive_exceptions = consecutive_exceptions;
  endfunction

  // Called when a successful retirement is observed
  function void notify_retirement();
    consecutive_exceptions = 0;
  endfunction

  // Report phase
  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("scoreboard", "=== Double-Fault Scoreboard Report ===", UVM_LOW)
    `uvm_info("scoreboard", $sformatf("  Total retirements: %0d", total_retirements), UVM_LOW)
    `uvm_info("scoreboard", $sformatf("  Total exceptions: %0d", total_exceptions), UVM_LOW)
    `uvm_info("scoreboard", $sformatf("  Max consecutive exceptions: %0d", max_consecutive_exceptions), UVM_LOW)
    `uvm_info("scoreboard", $sformatf("  Detector enabled: %0b", enable_detector), UVM_LOW)
  endfunction

endclass
