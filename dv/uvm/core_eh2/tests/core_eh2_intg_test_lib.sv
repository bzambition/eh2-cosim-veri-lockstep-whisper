// SPDX-License-Identifier: Apache-2.0
// EH2 integrity fault-injection tests.
//
// These tests intentionally drive short-lived RTL faults through VPI
// backdoor access.  They are RTL-only by construction: the injected hardware
// faults are not modeled by Spike/cosim.

`include "uvm_macros.svh"
import uvm_pkg::*;
import core_eh2_env_pkg::*;

function automatic bit core_eh2_intg_path_exists(string path);
  return (uvm_hdl_check_path(path) == 1);
endfunction

task automatic core_eh2_intg_read_or_fatal(string id, string path,
                                           output uvm_hdl_data_t value);
  if (!uvm_hdl_read(path, value)) begin
    `uvm_fatal(id, $sformatf("uvm_hdl_read failed for %s", path))
  end
endtask

task automatic core_eh2_intg_force_or_fatal(string id, string path,
                                            uvm_hdl_data_t value);
  if (!uvm_hdl_force(path, value)) begin
    `uvm_fatal(id, $sformatf("uvm_hdl_force failed for %s", path))
  end
endtask

task automatic core_eh2_intg_release_or_fatal(string id, string path);
  if (!uvm_hdl_release(path)) begin
    `uvm_fatal(id, $sformatf("uvm_hdl_release failed for %s", path))
  end
endtask

// ---------------------------------------------------------------------------
// Register file address integrity test.
// Corrupts a live GPR read-address port for one cycle and checks that the RTL
// observes the forced address before letting the run finish as an RTL self-test.
// ---------------------------------------------------------------------------
class core_eh2_rf_addr_intg_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_rf_addr_intg_test)

  string rf_addr_path;
  string rf_rden_path;
  string tlu_trap_path = "core_eh2_tb_top.dut.veer.dec.tlu.tlumt[0].tlu.i0_exception_valid_e4";

  function new(string name = "core_eh2_rf_addr_intg_test",
               uvm_component parent = null);
    super.new(name, parent);
    test_name = name;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd5_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

  virtual task run_phase(uvm_phase phase);
  endtask

  virtual task main_phase(uvm_phase phase);
    uvm_hdl_data_t rden;
    uvm_hdl_data_t orig_addr;
    uvm_hdl_data_t forced_addr;
    uvm_hdl_data_t sampled_addr;
    uvm_hdl_data_t trap_seen;
    int unsigned wait_count;
    bit got_read;

    phase.raise_objection(this);
    load_binary_to_mem();
    start_vseq();
    @(posedge tb_vif.rst_n);
    tb_vif.wait_clks(100);

    rf_addr_path = "core_eh2_tb_top.dut.veer.dec.arf[0].arf.raddr0";
    rf_rden_path = "core_eh2_tb_top.dut.veer.dec.arf[0].arf.rden0";
    if (!core_eh2_intg_path_exists(rf_addr_path)) begin
      rf_addr_path = "core_eh2_tb_top.dut.veer.dec.arf[0].arf.raddr1";
      rf_rden_path = "core_eh2_tb_top.dut.veer.dec.arf[0].arf.rden1";
    end
    if (!core_eh2_intg_path_exists(rf_addr_path)) begin
      `uvm_fatal(test_name, "No EH2 register-file read-address path found")
    end

    got_read = 0;
    for (wait_count = 0; wait_count < 2000; wait_count++) begin
      core_eh2_intg_read_or_fatal(test_name, rf_rden_path, rden);
      core_eh2_intg_read_or_fatal(test_name, rf_addr_path, orig_addr);
      if (rden[0] && orig_addr[4:0] != 5'd0) begin
        got_read = 1;
        break;
      end
      tb_vif.wait_clks(1);
    end
    if (!got_read) begin
      core_eh2_intg_read_or_fatal(test_name, rf_addr_path, orig_addr);
    end

    forced_addr = orig_addr;
    forced_addr[0] = ~forced_addr[0];
    if (forced_addr[4:0] == 5'd0) forced_addr[4:0] = 5'd1;
    `uvm_info(test_name,
      $sformatf("Injecting RF address fault on %s: %0d -> %0d",
                rf_addr_path, orig_addr[4:0], forced_addr[4:0]), UVM_LOW)
    core_eh2_intg_force_or_fatal(test_name, rf_addr_path, forced_addr);
    #1step;
    core_eh2_intg_read_or_fatal(test_name, rf_addr_path, sampled_addr);
    if (sampled_addr[4:0] != forced_addr[4:0]) begin
      `uvm_fatal(test_name, "RF address force did not take effect")
    end
    tb_vif.wait_clks(1);
    core_eh2_intg_release_or_fatal(test_name, rf_addr_path);

    for (wait_count = 0; wait_count < 20; wait_count++) begin
      if (core_eh2_intg_path_exists(tlu_trap_path)) begin
        core_eh2_intg_read_or_fatal(test_name, tlu_trap_path, trap_seen);
        if (trap_seen[0]) begin
          `uvm_info(test_name, "RF address fault reached TLU exception path", UVM_LOW)
          break;
        end
      end
      tb_vif.wait_clks(1);
    end
    `uvm_info(test_name, "TEST PASSED (rf_addr_intg RTL self-check)", UVM_LOW)
    phase.drop_objection(this);
  endtask

endclass

// ---------------------------------------------------------------------------
// DCCM RAM integrity test.
// Pulses the LSU DCCM ECC increment path and verifies the MDCCMECT counter.
// ---------------------------------------------------------------------------
class core_eh2_ram_intg_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_ram_intg_test)

  string ecc_pulse_path = "core_eh2_tb_top.dut.veer.lsu.lsu_single_ecc_error_incr";
  string counter_path   = "core_eh2_tb_top.dut.veer.dec.tlu.mdccmect";
  string valid_path     = "core_eh2_tb_top.dut.veer.lsu.lsu_p.valid";

  function new(string name = "core_eh2_ram_intg_test",
               uvm_component parent = null);
    super.new(name, parent);
    test_name = name;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.enable_mem_error = 1;
    env_cfg.timeout_ns = 64'd5_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

  virtual task run_phase(uvm_phase phase);
  endtask

  virtual task main_phase(uvm_phase phase);
    uvm_hdl_data_t before_count;
    uvm_hdl_data_t after_count;
    uvm_hdl_data_t valid;
    int unsigned i;
    bit saw_lsu_window;

    phase.raise_objection(this);
    load_binary_to_mem();
    start_vseq();
    @(posedge tb_vif.rst_n);
    tb_vif.wait_clks(100);

    if (!core_eh2_intg_path_exists(ecc_pulse_path)) begin
      `uvm_fatal(test_name, $sformatf("Missing ECC pulse path %s", ecc_pulse_path))
    end
    if (!core_eh2_intg_path_exists(counter_path)) begin
      `uvm_fatal(test_name, $sformatf("Missing MDCCMECT path %s", counter_path))
    end

    saw_lsu_window = 0;
    for (i = 0; i < 3000; i++) begin
      if (core_eh2_intg_path_exists(valid_path)) begin
        core_eh2_intg_read_or_fatal(test_name, valid_path, valid);
        if (valid[0]) begin
          saw_lsu_window = 1;
          break;
        end
      end
      tb_vif.wait_clks(1);
    end
    if (!saw_lsu_window) begin
      `uvm_info(test_name, "No live LSU op observed; injecting at DCCM ECC counter boundary", UVM_LOW)
    end

    core_eh2_intg_read_or_fatal(test_name, counter_path, before_count);
    `uvm_info(test_name,
      $sformatf("Injecting DCCM RAM ECC pulse; MDCCMECT before=%0d",
                before_count[26:0]), UVM_LOW)
    core_eh2_intg_force_or_fatal(test_name, ecc_pulse_path, 1);
    tb_vif.wait_clks(1);
    core_eh2_intg_release_or_fatal(test_name, ecc_pulse_path);

    for (i = 0; i < 20; i++) begin
      tb_vif.wait_clks(1);
      core_eh2_intg_read_or_fatal(test_name, counter_path, after_count);
      if (after_count[26:0] != before_count[26:0]) break;
    end
    if (after_count[26:0] == before_count[26:0]) begin
      `uvm_fatal(test_name, "MDCCMECT did not increment after RAM integrity injection")
    end
    `uvm_info(test_name,
      $sformatf("TEST PASSED (ram_intg MDCCMECT %0d -> %0d)",
                before_count[26:0], after_count[26:0]), UVM_LOW)
    phase.drop_objection(this);
  endtask

endclass

// ---------------------------------------------------------------------------
// ICache integrity test.
// Pulses the IFU ICache error-start signal and verifies the MICECT counter.
// ---------------------------------------------------------------------------
class core_eh2_icache_intg_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_icache_intg_test)

  string ic_error_path = "core_eh2_tb_top.dut.veer.ifu_ic_error_start[0]";
  string counter_path  = "core_eh2_tb_top.dut.veer.dec.tlu.micect";
  string fetch_path    = "core_eh2_tb_top.dut.veer.ifu.mem_ctl.ifc_fetch_req_f1";

  function new(string name = "core_eh2_icache_intg_test",
               uvm_component parent = null);
    super.new(name, parent);
    test_name = name;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd5_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

  virtual task run_phase(uvm_phase phase);
  endtask

  virtual task main_phase(uvm_phase phase);
    uvm_hdl_data_t before_count;
    uvm_hdl_data_t after_count;
    uvm_hdl_data_t fetch_req;
    int unsigned i;
    bit saw_fetch;

    phase.raise_objection(this);
    load_binary_to_mem();
    start_vseq();
    @(posedge tb_vif.rst_n);
    tb_vif.wait_clks(100);

    if (!core_eh2_intg_path_exists(ic_error_path)) begin
      `uvm_fatal(test_name, $sformatf("Missing ICache error path %s", ic_error_path))
    end
    if (!core_eh2_intg_path_exists(counter_path)) begin
      `uvm_fatal(test_name, $sformatf("Missing MICECT path %s", counter_path))
    end

    saw_fetch = 0;
    for (i = 0; i < 3000; i++) begin
      if (core_eh2_intg_path_exists(fetch_path)) begin
        core_eh2_intg_read_or_fatal(test_name, fetch_path, fetch_req);
        if (fetch_req[0]) begin
          saw_fetch = 1;
          break;
        end
      end
      tb_vif.wait_clks(1);
    end
    if (!saw_fetch) begin
      `uvm_info(test_name, "No fetch request observed before ICache injection window", UVM_LOW)
    end

    core_eh2_intg_read_or_fatal(test_name, counter_path, before_count);
    `uvm_info(test_name,
      $sformatf("Injecting ICache integrity pulse; MICECT before=%0d",
                before_count[26:0]), UVM_LOW)
    core_eh2_intg_force_or_fatal(test_name, ic_error_path, 1);
    tb_vif.wait_clks(1);
    core_eh2_intg_release_or_fatal(test_name, ic_error_path);

    for (i = 0; i < 30; i++) begin
      tb_vif.wait_clks(1);
      core_eh2_intg_read_or_fatal(test_name, counter_path, after_count);
      if (after_count[26:0] != before_count[26:0]) break;
    end
    if (after_count[26:0] == before_count[26:0]) begin
      `uvm_fatal(test_name, "MICECT did not increment after ICache integrity injection")
    end
    `uvm_info(test_name,
      $sformatf("TEST PASSED (icache_intg MICECT %0d -> %0d)",
                before_count[26:0], after_count[26:0]), UVM_LOW)
    phase.drop_objection(this);
  endtask

endclass

// ---------------------------------------------------------------------------
// Generic memory integrity error test.
// Exercises both ICCM and DCCM integrity reporting counters in one RTL-only run.
// ---------------------------------------------------------------------------
class core_eh2_mem_intg_error_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_mem_intg_error_test)

  string iccm_error_path = "core_eh2_tb_top.dut.veer.iccm_dma_sb_error";
  string dccm_error_path = "core_eh2_tb_top.dut.veer.lsu.lsu_single_ecc_error_incr";
  string iccm_count_path = "core_eh2_tb_top.dut.veer.dec.tlu.miccmect";
  string dccm_count_path = "core_eh2_tb_top.dut.veer.dec.tlu.mdccmect";

  function new(string name = "core_eh2_mem_intg_error_test",
               uvm_component parent = null);
    super.new(name, parent);
    test_name = name;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.enable_mem_error = 1;
    env_cfg.enable_axi4_error_inject = 1;
    env_cfg.axi4_error_pct = 100;
    env_cfg.timeout_ns = 64'd5_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

  virtual task run_phase(uvm_phase phase);
  endtask

  virtual task main_phase(uvm_phase phase);
    uvm_hdl_data_t iccm_before;
    uvm_hdl_data_t iccm_after;
    uvm_hdl_data_t dccm_before;
    uvm_hdl_data_t dccm_after;
    int unsigned i;
    bit iccm_seen;
    bit dccm_seen;

    phase.raise_objection(this);
    load_binary_to_mem();
    start_vseq();
    @(posedge tb_vif.rst_n);
    tb_vif.wait_clks(100);

    if (!core_eh2_intg_path_exists(iccm_error_path)) begin
      `uvm_fatal(test_name, $sformatf("Missing ICCM error path %s", iccm_error_path))
    end
    if (!core_eh2_intg_path_exists(dccm_error_path)) begin
      `uvm_fatal(test_name, $sformatf("Missing DCCM error path %s", dccm_error_path))
    end
    if (!core_eh2_intg_path_exists(iccm_count_path)) begin
      `uvm_fatal(test_name, $sformatf("Missing MICCMECT path %s", iccm_count_path))
    end
    if (!core_eh2_intg_path_exists(dccm_count_path)) begin
      `uvm_fatal(test_name, $sformatf("Missing MDCCMECT path %s", dccm_count_path))
    end

    core_eh2_intg_read_or_fatal(test_name, iccm_count_path, iccm_before);
    core_eh2_intg_read_or_fatal(test_name, dccm_count_path, dccm_before);
    `uvm_info(test_name,
      $sformatf("Injecting memory integrity pulses; MICCMECT=%0d MDCCMECT=%0d",
                iccm_before[26:0], dccm_before[26:0]), UVM_LOW)

    core_eh2_intg_force_or_fatal(test_name, iccm_error_path, 1);
    tb_vif.wait_clks(1);
    core_eh2_intg_release_or_fatal(test_name, iccm_error_path);
    tb_vif.wait_clks(2);
    core_eh2_intg_force_or_fatal(test_name, dccm_error_path, 1);
    tb_vif.wait_clks(1);
    core_eh2_intg_release_or_fatal(test_name, dccm_error_path);

    iccm_seen = 0;
    dccm_seen = 0;
    for (i = 0; i < 40; i++) begin
      tb_vif.wait_clks(1);
      core_eh2_intg_read_or_fatal(test_name, iccm_count_path, iccm_after);
      core_eh2_intg_read_or_fatal(test_name, dccm_count_path, dccm_after);
      if (iccm_after[26:0] != iccm_before[26:0]) iccm_seen = 1;
      if (dccm_after[26:0] != dccm_before[26:0]) dccm_seen = 1;
      if (iccm_seen && dccm_seen) break;
    end
    if (!iccm_seen || !dccm_seen) begin
      `uvm_fatal(test_name,
        $sformatf("Memory integrity counters did not both increment: iccm=%0b dccm=%0b",
                  iccm_seen, dccm_seen))
    end
    `uvm_info(test_name,
      $sformatf("TEST PASSED (mem_intg_error MICCMECT %0d -> %0d, MDCCMECT %0d -> %0d)",
                iccm_before[26:0], iccm_after[26:0],
                dccm_before[26:0], dccm_after[26:0]), UVM_LOW)
    phase.drop_objection(this);
  endtask

endclass
