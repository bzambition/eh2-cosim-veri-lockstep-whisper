// SPDX-License-Identifier: Apache-2.0
// EH2 Base Test
//
// Full-featured base test class modeled after Ibex core_ibex_base_test.sv.
// Provides:
//   - Environment creation with env_cfg
//   - ISA string construction
//   - Binary loading into memory models
//   - Co-simulation configuration
//   - Reset handling
//   - 4-way test completion detection (signature, double-fault, cycle timeout, wall-clock)
//   - Signature-based CSR verification helpers
//   - Virtual sequence orchestration

`include "uvm_macros.svh"
import uvm_pkg::*;
import core_eh2_env_pkg::*;
import axi4_agent_pkg::*;
import eh2_trace_agent_pkg::*;
import eh2_irq_agent_pkg::*;
import eh2_jtag_agent_pkg::*;

class core_eh2_base_test extends uvm_test;

  `uvm_component_utils(core_eh2_base_test)

  // Environment and configuration
  core_eh2_env     env;
  core_eh2_env_cfg env_cfg;

  // Virtual sequence
  core_eh2_vseq vseq;

  // Testbench service interfaces
  virtual core_eh2_tb_intf tb_vif;
  virtual eh2_halt_run_intf    halt_run_vif;

  // Test identity
  string test_name = "core_eh2_base_test";

  // ISA string for RVVI reference model
  string isa_string = "";

  // Signature address for riscv-dv handshake
  parameter bit [31:0] SIGNATURE_ADDR = 32'hD058_0000;
  parameter bit [31:0] BOOT_ADDR      = 32'h8000_0000;

  // Core status codes (from riscv-dv)
  localparam INITIALIZED     = 0;
  localparam CORE_RUNNING    = 1;
  localparam TEST_PASS       = 2;
  localparam TEST_FAIL       = 3;
  localparam WB_EXCEPTION    = 4;
  localparam IRQ_EXCEPTION   = 5;
  localparam DEBUG_REQ       = 6;
  localparam CSR_ACCESS      = 7;
  localparam WFI_INSTR       = 8;
  localparam TIMER_INTRPT     = 9;
  localparam EXT_INTRPT       = 10;
  localparam ECALL            = 11;

  function new(string name, uvm_component parent);
    core_eh2_report_server eh2_report_server;
    super.new(name, parent);
    eh2_report_server = new();
    uvm_report_server::set_server(eh2_report_server);
  endfunction

  // =========================================================================
  // Build Phase
  // =========================================================================
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // Create environment (which creates env_cfg internally)
    env = core_eh2_env::type_id::create("env", this);

    // env.cfg is created in env's constructor, so it's available immediately
    env_cfg = env.cfg;

    if (!uvm_config_db#(virtual core_eh2_tb_intf)::get(null, "", "tb_vif", tb_vif)) begin
      `uvm_fatal(test_name, "Cannot get tb_vif")
    end

    if (!uvm_config_db#(virtual eh2_halt_run_intf)::get(null, "", "halt_run_vif", halt_run_vif)) begin
      `uvm_info(test_name, "halt_run_vif not set; halt/load helper tasks disabled", UVM_LOW)
    end

    // Build ISA string
    build_isa_string();

    `uvm_info(test_name, $sformatf("ISA: %s", isa_string), UVM_LOW)
  endfunction

  // =========================================================================
  // End of Elaboration
  // =========================================================================
  function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);

    `uvm_info(test_name, "Test environment:", UVM_LOW)
    env.print();
  endfunction

  // =========================================================================
  // Run Phase
  // =========================================================================
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);

    `uvm_info(test_name, "Test started", UVM_LOW)

    // Load binary into memory (core is in reset, safe without halting)
    load_binary_to_mem();

    // Start virtual sequence
    `uvm_info(test_name, "Starting vseq", UVM_LOW)
    start_vseq();
    `uvm_info(test_name, "Vseq done, waiting for completion", UVM_LOW)

    // Wait for test completion
    wait_for_completion(phase);
    `uvm_info(test_name, "Completion detected", UVM_LOW)

    `uvm_info(test_name, "Test finished", UVM_LOW)

    // Stop virtual sequence
    if (vseq != null) vseq.stop();

    phase.drop_objection(this);
  endtask

  // Halt core during binary loading (prevent partial execution)
  virtual task halt_core_for_loading();
    if (halt_run_vif == null) begin
      `uvm_warning(test_name, "Cannot halt core for loading: halt_run_vif is null")
      return;
    end
    `uvm_info(test_name, "Halting core for binary loading", UVM_LOW)
    halt_run_vif.mpc_debug_halt_req <= '1;
    halt_run_vif.mpc_debug_run_req  <= '0;
    // Wait for halt acknowledgment (with timeout)
    fork
      begin
        wait (halt_run_vif.o_cpu_halt_ack !== '0);
      end
      begin
        tb_vif.wait_clks(100);
        `uvm_warning(test_name, "Timeout waiting for mpc_debug_halt_ack")
      end
    join_any
    disable fork;
    tb_vif.wait_clks(2);
  endtask

  // Release core after binary loading
  virtual task release_core_after_loading();
    if (halt_run_vif == null) begin
      `uvm_warning(test_name, "Cannot release core after loading: halt_run_vif is null")
      return;
    end
    `uvm_info(test_name, "Releasing core after binary loading", UVM_LOW)
    halt_run_vif.mpc_debug_halt_req <= '0;
    halt_run_vif.mpc_debug_run_req  <= '1;
    tb_vif.wait_clks(5);
  endtask

  virtual task send_debug_resume(
    uvm_sequencer #(eh2_jtag_seq_item) jtag_seqr = null,
    int unsigned clear_delay_ns = 1200
  );
    if (jtag_seqr == null)
      jtag_seqr = env.jtag_agent.sequencer;

    eh2_jtag_seq::send_write(jtag_seqr,
      eh2_jtag_seq_item::DMI_DMCONTROL, 32'h40000001);
    #(clear_delay_ns * 1ns);
    eh2_jtag_seq::send_write(jtag_seqr,
      eh2_jtag_seq_item::DMI_DMCONTROL, 32'h00000001);
  endtask

  // =========================================================================
  // ISA String Construction
  // =========================================================================
  virtual function void build_isa_string();
    // EH2 supports RV32IMAC + Zba/Zbb/Zbc/Zbs bitmanip extensions
    isa_string = "rv32imac_zba_zbb_zbc_zbs";
  endfunction

  // =========================================================================
  // Binary Loading
  // =========================================================================
  virtual task load_binary_to_mem();
    string bin_path;

    bin_path = env_cfg.binary;
    if (bin_path == "") begin
      `uvm_info(test_name, "No binary specified, skipping load", UVM_LOW)
      return;
    end

    // Skip if already loaded early by tb_top via $readmemh
    if (tb_vif.early_bin_loaded) begin
      `uvm_info(test_name, "Binary already loaded early by tb_top, skipping UVM load", UVM_LOW)
      return;
    end

    `uvm_info(test_name, $sformatf("Loading binary: %s at 0x%08x", bin_path, env_cfg.boot_addr), UVM_LOW)

    if (bin_path.len() > 4 && bin_path.substr(bin_path.len()-4, bin_path.len()-1) == ".hex") begin
      load_hex_to_mem(bin_path);
    end else begin
      load_raw_binary_to_mem(bin_path, env_cfg.boot_addr);
    end
  endtask

  // Load a raw binary file into memory
  virtual task load_raw_binary_to_mem(string bin_path, bit [31:0] base_addr);
    int fd;
    int byte_val;
    bit [7:0] mem_byte;
    int addr;

    fd = $fopen(bin_path, "rb");
    if (fd == 0) begin
      `uvm_fatal(test_name, $sformatf("Cannot open binary: %s", bin_path))
    end

    addr = base_addr;
    while (!$feof(fd)) begin
      byte_val = $fread(mem_byte, fd);
      if (byte_val == 1) begin
        write_mem_byte(addr, mem_byte);
        addr++;
      end
    end
    $fclose(fd);

    `uvm_info(test_name, $sformatf("Loaded %0d bytes from raw binary", addr - base_addr), UVM_LOW)
  endtask

  // Load a hex file (Intel HEX-like format: @ADDR followed by hex bytes)
  virtual task load_hex_to_mem(string hex_path);
    int fd;
    int addr;
    string line;
    int c;
    bit [7:0] val;
    int nybble_count;
    int bytes_loaded;

    fd = $fopen(hex_path, "r");
    if (fd == 0) begin
      `uvm_fatal(test_name, $sformatf("Cannot open hex file: %s", hex_path))
    end

    addr = env_cfg.boot_addr;
    bytes_loaded = 0;
    nybble_count = 0;
    val = 0;

    while (!$feof(fd)) begin
      c = $fgetc(fd);
      if (c < 0) break;  // EOF

      if (c == "@" ) begin
        // Address marker: read hex address
        int new_addr;
        new_addr = 0;
        while (!$feof(fd)) begin
          c = $fgetc(fd);
          if (c < 0) break;
          if (c >= "0" && c <= "9")      new_addr = (new_addr << 4) | (c - "0");
          else if (c >= "a" && c <= "f") new_addr = (new_addr << 4) | (c - "a" + 10);
          else if (c >= "A" && c <= "F") new_addr = (new_addr << 4) | (c - "A" + 10);
          else break;  // Non-hex char ends address
        end
        addr = new_addr;
        nybble_count = 0;
        val = 0;
      end else if (c >= "0" && c <= "9") begin
        val = (val << 4) | (c - "0");
        nybble_count++;
      end else if (c >= "a" && c <= "f") begin
        val = (val << 4) | (c - "a" + 10);
        nybble_count++;
      end else if (c >= "A" && c <= "F") begin
        val = (val << 4) | (c - "A" + 10);
        nybble_count++;
      end else if (c == " " || c == "\t" || c == "\n" || c == "\r") begin
        // Whitespace: commit accumulated byte if any
        if (nybble_count > 0) begin
          write_mem_byte(addr, val);
          addr++;
          bytes_loaded++;
          val = 0;
          nybble_count = 0;
        end
      end
      // Ignore other characters (comments, etc.)
    end
    // Commit final byte if file doesn't end with whitespace
    if (nybble_count > 0) begin
      write_mem_byte(addr, val);
      bytes_loaded++;
    end

    $fclose(fd);
    `uvm_info(test_name, $sformatf("Loaded %0d bytes from hex file", bytes_loaded), UVM_LOW)
  endtask

  // Write a byte to all AXI4 memory models via backdoor
  virtual task write_mem_byte(bit [31:0] addr, bit [7:0] data);
    tb_vif.write_mem_byte(addr, data);
  endtask

  // =========================================================================
  // Virtual Sequence
  // =========================================================================
  virtual task start_vseq();
    vseq = core_eh2_vseq::type_id::create("vseq");
    vseq.cfg = env_cfg;
    vseq.start(env.vseqr);
  endtask

  // =========================================================================
  // Test Completion Detection (4-way)
  // =========================================================================
  virtual task wait_for_completion(uvm_phase phase);
    fork
      // Way 1: Signature-based completion (mailbox write)
      begin
        if (env_cfg.use_signature)
          wait_for_signature();
        else
          wait (0);  // Block forever if disabled
      end

      // Way 2: Wall-clock timeout
      begin
        #(env_cfg.timeout_ns);
        `uvm_error(test_name, $sformatf("Wall-clock timeout: %0d ns", env_cfg.timeout_ns))
      end

      // Way 3: Cycle count timeout
      begin
        tb_vif.wait_clks(env_cfg.max_cycles);
        `uvm_error(test_name, $sformatf("Cycle timeout: %0d cycles", env_cfg.max_cycles))
      end

      // Way 4: Double-fault detector
      begin
        if (env_cfg.enable_double_fault_detector)
          detect_double_fault();
        else
          wait (0);  // Block forever if disabled
      end
    join_any
    disable fork;
  endtask

  // Signature-based completion: watch for writes to SIGNATURE_ADDR
  // Polls mailbox_test_done flag instead of using events (avoids triggered-state issues)
  virtual task wait_for_signature();
    forever begin
      @(posedge tb_vif.clk);
      if (tb_vif.mailbox_test_done) begin
        // Check which event fired
        if (tb_vif.mailbox_data[7:0] == 8'hFF ||
            tb_vif.mailbox_data[31:0] == TEST_PASS) begin
          `uvm_info(test_name, "TEST PASSED (signature)", UVM_LOW)
        end else if (tb_vif.mailbox_data[7:0] == 8'h01 ||
                     tb_vif.mailbox_data[31:0] == TEST_FAIL) begin
          `uvm_error(test_name, "TEST FAILED (signature)")
        end else begin
          `uvm_error(test_name,
            $sformatf("Unexpected completion signature: 0x%02x",
                      tb_vif.mailbox_data[7:0]))
        end
        // EH2 can retire the mailbox store before the external AXI write
        // response is observed. Leave a short drain window so monitors and
        // scoreboards can close outstanding transactions before report_phase.
        tb_vif.wait_clks(10);
        return;
      end
    end
  endtask

  // Double-fault detection
  virtual task detect_double_fault();
    int fault_count = 0;
    forever begin
      #1000ns;
      // Monitor for consecutive exceptions via trace
      // Simplified: count exceptions and trigger if threshold exceeded
      if (env.trace_monitor != null && env.trace_monitor.exception_count > env_cfg.double_fault_threshold) begin
        `uvm_error(test_name, $sformatf("Double-fault detected: %0d exceptions",
          env.trace_monitor.exception_count))
        return;
      end
    end
  endtask

  // =========================================================================
  // Signature-based CSR Verification Helpers
  // =========================================================================

  // Wait for a write to the signature address
  // Monitors the mailbox events from TB top
  virtual task wait_for_mem_txn(output bit [31:0] addr, output bit [31:0] data,
                                 output bit is_write);
    // Wait for a mailbox write event
    @(posedge tb_vif.mailbox_write);
    addr    = tb_vif.mailbox_addr;
    data    = tb_vif.mailbox_data[31:0];
    is_write = 1;
  endtask

  // Check next core status from signature
  virtual task check_next_core_status(input int expected_status);
    bit [31:0] addr, data;
    bit is_write;
    wait_for_mem_txn(addr, data, is_write);
    if (is_write && addr == SIGNATURE_ADDR) begin
      if (data[7:0] != expected_status[7:0]) begin
        `uvm_error(test_name, $sformatf(
          "Core status mismatch: expected=%0d got=%0d",
          expected_status, data[7:0]))
      end
    end
  endtask

  // Wait for specific core status
  virtual task wait_for_core_status(input int status);
    bit [31:0] addr, data;
    bit is_write;
    forever begin
      wait_for_mem_txn(addr, data, is_write);
      if (is_write && addr == SIGNATURE_ADDR && data[7:0] == status[7:0])
        return;
    end
  endtask

  // Wait for CSR write verification
  virtual task wait_for_csr_write(input int csr_addr);
    bit [31:0] addr, data;
    bit is_write;
    forever begin
      wait_for_mem_txn(addr, data, is_write);
      if (is_write && addr == SIGNATURE_ADDR && data[31:20] == csr_addr[11:0])
        return;
    end
  endtask

  // =========================================================================
  // Report Phase
  // =========================================================================
  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    if (tb_vif != null && tb_vif.mailbox_test_done) begin
      if (tb_vif.mailbox_data[7:0] == 8'hFF ||
          tb_vif.mailbox_data[31:0] == TEST_PASS) begin
        `uvm_info(test_name, "TEST PASSED (signature)", UVM_LOW)
      end else if (tb_vif.mailbox_data[7:0] == 8'h01 ||
                   tb_vif.mailbox_data[31:0] == TEST_FAIL) begin
        `uvm_error(test_name, "TEST FAILED (signature)")
      end
    end
    `uvm_info(test_name, "========================================", UVM_LOW)
    `uvm_info(test_name, $sformatf("Test: %s", test_name), UVM_LOW)
    `uvm_info(test_name, $sformatf("ISA: %s", isa_string), UVM_LOW)
    `uvm_info(test_name, $sformatf("Binary: %s", env_cfg.binary), UVM_LOW)
    `uvm_info(test_name, "========================================", UVM_LOW)
  endfunction

endclass
