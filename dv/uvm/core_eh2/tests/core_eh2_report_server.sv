// SPDX-License-Identifier: Apache-2.0
// EH2 Custom Report Server
//
// Prints clear PASS/FAIL status based on UVM error/fatal counts.
// Based on Ibex's core_ibex_report_server pattern.

class core_eh2_report_server extends uvm_default_report_server;

  function new(string name = "");
    super.new(name);
  endfunction

  function void report_summarize(UVM_FILE file = 0);
    int error_count;
    error_count = get_severity_count(UVM_ERROR);
    error_count = get_severity_count(UVM_FATAL) + error_count;

    if (error_count == 0) begin
      $display("\n--- EH2 UVM TEST PASSED ---\n");
    end else begin
      $display("\n--- EH2 UVM TEST FAILED ---\n");
    end
    super.report_summarize(file);
  endfunction

endclass
