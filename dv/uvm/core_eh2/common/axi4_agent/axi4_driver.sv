// SPDX-License-Identifier: Apache-2.0
// AXI4 Response Driver - Responds to AXI4 master requests
//
// Acts as an AXI4 slave error injector, controlling the axi4_slave_mem's
// response via the error_inject_mode / force_bresp / force_rresp sideband
// signals on the axi4_intf.
//
// The driver does NOT replace the RTL slave_mem for address/data handling.
// Instead, it piggybacks on slave_mem's existing state machine, only
// overriding the resp field when an error should be injected.
//
//   - Passive mode (default, enable_error_inject=0):
//       error_inject_mode stays 0; slave_mem drives OKAY on its own.
//   - Active mode (enable_error_inject=1):
//       The driver watches AR/AW handshakes and randomly sets
//       error_inject_mode + force_bresp/force_rresp to SLVERR/DECERR
//       with configurable probability (error_pct, default 5%).
//       After the response handshake completes, error_inject_mode is
//       cleared so the next transaction defaults to OKAY.
//
// Based on Ibex's ibex_mem_intf_response_driver pattern.

class axi4_driver #(int ID_WIDTH = 4) extends uvm_driver #(axi4_seq_item);

  `uvm_component_param_utils(axi4_driver#(ID_WIDTH))

  // Virtual interface
  virtual axi4_intf#(.ID_WIDTH(ID_WIDTH)) vif;

  // Configuration
  string agent_name = "axi4_driver";
  int    rsp_delay = 0;           // Response delay in clock cycles
  bit    enable_error_inject = 0; // Enable error injection
  int    error_pct = 5;           // Error injection percentage (0-100)
  bit    enable_delay_inject = 0; // Enable random response delays
  int    min_delay = 0;           // Min response delay cycles
  int    max_delay = 10;          // Max response delay cycles

  // Error response type
  typedef enum bit [1:0] {
    RESP_OKAY   = 2'b00,
    RESP_EXOKAY = 2'b01,
    RESP_SLVERR = 2'b10,
    RESP_DECERR = 2'b11
  } axi4_resp_e;

  // Statistics
  int unsigned num_read_errors  = 0;
  int unsigned num_write_errors = 0;
  int unsigned num_read_total   = 0;
  int unsigned num_write_total  = 0;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (!uvm_config_db#(virtual axi4_intf#(.ID_WIDTH(ID_WIDTH)))::get(this, "", "vif", vif)) begin
      `uvm_fatal(agent_name, "Could not get virtual interface")
    end
  endfunction

  task run_phase(uvm_phase phase);
    // Ensure sideband signals are inactive at start
    vif.error_inject_mode <= 1'b0;
    vif.force_bresp       <= 2'b00;
    vif.force_rresp       <= 2'b00;

    if (!enable_error_inject) begin
      // Passive mode - error injection disabled; slave_mem handles everything.
      `uvm_info(agent_name, "Running in PASSIVE mode (no error injection)", UVM_LOW)
      forever begin
        @(posedge vif.clk);
      end
    end else begin
      // Active mode - monitor AXI handshakes, inject errors probabilistically.
      `uvm_info(agent_name, $sformatf(
        "Running in ACTIVE mode: error_pct=%0d%%", error_pct), UVM_LOW)
      fork
        inject_read_errors();
        inject_write_errors();
      join
    end
  endtask

  //----------------------------------------------------------------------------
  // Read channel error injection
  //   Watch for AR handshake, decide error/okay, set sideband, wait for R
  //   completion (rlast+rvalid+rready), then clear sideband.
  //----------------------------------------------------------------------------
  task inject_read_errors();
    forever begin
      // Wait for AR handshake
      @(posedge vif.clk iff (vif.arvalid && vif.arready));

      num_read_total++;

      if (should_inject_error()) begin
        bit [1:0] err_resp = get_error_resp();
        `uvm_info(agent_name, $sformatf(
          "INJECT read error resp=%s addr=0x%08x id=%0d",
          (err_resp == RESP_SLVERR) ? "SLVERR" : "DECERR",
          vif.araddr, vif.arid), UVM_MEDIUM)

        vif.error_inject_mode <= 1'b1;
        vif.force_rresp       <= err_resp;
        num_read_errors++;

        // Wait until last R beat completes
        @(posedge vif.clk iff (vif.rvalid && vif.rready && vif.rlast));

        // Clear error injection for next transaction
        vif.error_inject_mode <= 1'b0;
        vif.force_rresp       <= 2'b00;
      end
      // else: leave sideband at 0, slave_mem drives OKAY on its own
    end
  endtask

  //----------------------------------------------------------------------------
  // Write channel error injection
  //   Watch for AW handshake, decide error/okay, set sideband, wait for B
  //   handshake, then clear sideband.
  //----------------------------------------------------------------------------
  task inject_write_errors();
    forever begin
      // Wait for AW handshake
      @(posedge vif.clk iff (vif.awvalid && vif.awready));

      num_write_total++;

      if (should_inject_error()) begin
        bit [1:0] err_resp = get_error_resp();
        `uvm_info(agent_name, $sformatf(
          "INJECT write error resp=%s addr=0x%08x id=%0d",
          (err_resp == RESP_SLVERR) ? "SLVERR" : "DECERR",
          vif.awaddr, vif.awid), UVM_MEDIUM)

        vif.error_inject_mode <= 1'b1;
        vif.force_bresp       <= err_resp;
        num_write_errors++;

        // Wait until B handshake completes
        @(posedge vif.clk iff (vif.bvalid && vif.bready));

        // Clear error injection for next transaction
        vif.error_inject_mode <= 1'b0;
        vif.force_bresp       <= 2'b00;
      end
      // else: leave sideband at 0, slave_mem drives OKAY on its own
    end
  endtask

  // Check if error should be injected (random)
  function bit should_inject_error();
    if (!enable_error_inject) return 0;
    return ($urandom_range(0, 99) < error_pct);
  endfunction

  // Get error response type (random SLVERR or DECERR)
  function bit [1:0] get_error_resp();
    if ($urandom_range(0, 1) == 0)
      return RESP_SLVERR;
    else
      return RESP_DECERR;
  endfunction

  // Get random delay for response
  function int get_random_delay();
    if (!enable_delay_inject) return rsp_delay;
    return $urandom_range(min_delay, max_delay);
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    if (enable_error_inject) begin
      `uvm_info(agent_name, $sformatf(
        "Error injection stats: reads=%0d/%0d writes=%0d/%0d",
        num_read_errors, num_read_total,
        num_write_errors, num_write_total), UVM_LOW)
    end
  endfunction

endclass
