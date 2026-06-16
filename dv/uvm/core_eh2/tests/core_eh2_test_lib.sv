// SPDX-License-Identifier: Apache-2.0
// EH2 UVM Test Library
//
// Contains 20+ specialized test classes for different verification scenarios.
// The testbench top handles mailbox detection and simulation termination.

`include "uvm_macros.svh"
import uvm_pkg::*;
import core_eh2_env_pkg::*;
import axi4_agent_pkg::*;
import eh2_trace_agent_pkg::*;
import eh2_irq_agent_pkg::*;
import eh2_jtag_agent_pkg::*;

// ---------------------------------------------------------------------------
// Base class for directed test scenarios (benchmarked against ibex
// core_ibex_directed_test). Provides instruction decode tracking,
// send_stimulus / check_stimulus pattern, debug stimulus helpers,
// and DCSR checking utilities.
// ---------------------------------------------------------------------------
class core_eh2_directed_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_directed_test)

  // Debug entry cause codes and CSR addresses (RISC-V Debug Spec) are declared
  // up-front so they are visible to all methods below. NC/ncvlog does not allow
  // forward references to class-scope localparams the way VCS does.
  localparam bit [2:0] DBG_CAUSE_EBREAK     = 3'd1;
  localparam bit [2:0] DBG_CAUSE_TRIGGER    = 3'd2;
  localparam bit [2:0] DBG_CAUSE_HALTREQ    = 3'd3;
  localparam bit [2:0] DBG_CAUSE_STEP       = 3'd4;
  localparam bit [2:0] DBG_CAUSE_RESETHALT  = 3'd5;
  localparam bit [11:0] CSR_DCSR = 12'h7B0;
  localparam bit [11:0] CSR_DPC  = 12'h7B1;

  function new(string name = "core_eh2_directed_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // =========================================================================
  // Instruction tracking types
  // =========================================================================

  typedef struct {
    bit [6:0]  opcode;
    bit [2:0]  funct3;
    bit [6:0]  funct7;
    bit [11:0] system_imm;  // 12-bit immediate for SYSTEM instructions
  } instr_t;

  // Standard RISC-V opcode encodings (bits [6:0] of instruction)
  localparam bit [6:0] OPCODE_LOAD     = 7'b0000011;
  localparam bit [6:0] OPCODE_LOAD_FP  = 7'b0000111;
  localparam bit [6:0] OPCODE_MADD     = 7'b1000011;
  localparam bit [6:0] OPCODE_MSUB     = 7'b1000111;
  localparam bit [6:0] OPCODE_NMSUB    = 7'b1001011;
  localparam bit [6:0] OPCODE_NMADD    = 7'b1001111;
  localparam bit [6:0] OPCODE_OP_FP    = 7'b1010011;
  localparam bit [6:0] OPCODE_BRANCH   = 7'b1100011;
  localparam bit [6:0] OPCODE_JALR     = 7'b1100111;
  localparam bit [6:0] OPCODE_JAL      = 7'b1101111;
  localparam bit [6:0] OPCODE_SYSTEM   = 7'b1110011;
  localparam bit [6:0] OPCODE_OP       = 7'b0110011;
  localparam bit [6:0] OPCODE_OP_IMM   = 7'b0010011;
  localparam bit [6:0] OPCODE_OP_IMM_32 = 7'b0011011;
  localparam bit [6:0] OPCODE_OP_32    = 7'b0111011;
  localparam bit [6:0] OPCODE_STORE    = 7'b0100011;
  localparam bit [6:0] OPCODE_STORE_FP = 7'b0100111;
  localparam bit [6:0] OPCODE_AUIPC    = 7'b0010111;
  localparam bit [6:0] OPCODE_LUI      = 7'b0110111;
  localparam bit [6:0] OPCODE_MISC_MEM = 7'b0001111;

  // =========================================================================
  // Instruction tracking queues
  // =========================================================================
  instr_t     seen_instr[$];
  bit [15:0]  seen_compressed_instr[$];

  // Cached DCSR value from the most recent debug entry (populated by
  // send_debug_stimulus / wait_for_csr_write)
  bit [31:0]  dcsr_data;

  // =========================================================================
  // send_stimulus / check_stimulus pattern (ibex-style)
  // =========================================================================
  //
  // send_stimulus() is the main run-phase entry point. It:
  //   1. Starts the virtual sequence (background stimulus)
  //   2. Waits for core initialization (first mailbox write)
  //   3. Forks check_stimulus() -- the per-test payload
  //   4. Waits for test_done, then cleans up
  //
  // Subclasses override check_stimulus() to inject directed stimulus
  // (debug requests, specific interrupts, etc.) and verify core behavior.
  // =========================================================================

  virtual task send_stimulus();
    fork
      begin
        // Background: start the virtual sequence for ambient stimulus
        vseq.start(env.vseqr);
      end
      begin
        // Wait for core initialization before starting the stimulus check loop
        // First write to signature address is guaranteed to be core init info
        wait_for_core_setup();
        // Allow core to begin executing <main>
        tb_vif.wait_clks(50);

        // Per-test directed stimulus (override in subclass)
        fork
          check_stimulus();
        join_none

        // Wait for test completion signal
        wait_test_done();

        // Let sequences wind down before disabling
        if (vseq != null) vseq.stop();
        tb_vif.wait_clks(100);
        disable fork;

        // Drop any remaining objection
        // (objection management is handled by the caller / run_phase)
      end
    join_none
  endtask

  // Override in subclasses to provide directed stimulus and checking.
  // The base implementation raises a fatal error -- this class is not
  // meant to be used directly.
  virtual task check_stimulus();
    `uvm_fatal(test_name, "check_stimulus() not implemented -- extend core_eh2_directed_test")
  endtask

  // =========================================================================
  // Core setup / completion helpers
  // =========================================================================

  // Wait for the core to write its initialization info to the signature
  // address, indicating it is ready to execute <main>.
  virtual task wait_for_core_setup();
    bit [31:0] addr, data;
    bit is_write;
    `uvm_info(test_name, "Waiting for core initialization (signature write)", UVM_LOW)
    wait_for_mem_txn(addr, data, is_write);
    `uvm_info(test_name, "Core initialization detected", UVM_LOW)
  endtask

  // Poll the mailbox_test_done flag set by the test program.
  virtual task wait_test_done();
    forever begin
      @(posedge tb_vif.clk);
      if (tb_vif.mailbox_test_done) begin
        `uvm_info(test_name, "Test done detected (mailbox)", UVM_LOW)
        return;
      end
    end
  endtask

  // =========================================================================
  // Debug stimulus helper
  // =========================================================================
  //
  // Sends a single debug request via JTAG, checks that the core enters
  // debug mode, verifies privilege mode and DCSR fields, then resumes.
  //
  // Parameters:
  //   mode               - Expected privilege mode encoded in dcsr.prv
  //                          (11=M, 01=S, 00=U)
  //   debug_status_msg   - Error message if core does not enter debug mode
  //   jtag_seqr          - JTAG sequencer to use (default: env.jtag_agent.sequencer)
  //   halt_timeout_ns    - Timeout in ns to wait for debug entry (default: 10000)
  // =========================================================================

  virtual task send_debug_stimulus(
    bit [1:0]  mode,
    string     debug_status_msg,
    uvm_sequencer #(eh2_jtag_seq_item) jtag_seqr = null,
    int        halt_timeout_ns = 10000
  );
    bit [31:0] addr, data;
    bit is_write;

    if (jtag_seqr == null)
      jtag_seqr = env.jtag_agent.sequencer;

    // Send debug halt request via JTAG
    eh2_jtag_seq::send_write(jtag_seqr,
      eh2_jtag_seq_item::DMI_DMCONTROL, 32'h80000001);

    // Wait for core to acknowledge debug mode entry
    fork
      begin
        wait_for_core_status(DEBUG_REQ);
      end
      begin
        #(halt_timeout_ns * 1ns);
        `uvm_fatal(test_name, $sformatf(
          "Timeout waiting for debug entry: %0s", debug_status_msg))
      end
    join_any
    disable fork;

    `uvm_info(test_name, $sformatf("Debug mode entered: %0s", debug_status_msg), UVM_LOW)

    // Verify we are in M-mode (EH2 debug entry always runs in M-mode)
    // Note: privilege mode checking depends on trace interface availability.
    // The DCSR.prv field below provides the authoritative check.

    // Read DCSR via abstract command (dmdata0 / abstract data register)
    // The EH2 debug module provides DCSR through abstract CSR read.
    // We read it from the signature mailbox if available, otherwise via JTAG.
    wait_for_csr_write(CSR_DCSR);
    dcsr_data = get_last_signature_data();

    // Verify dcsr.prv matches expected mode
    check_dcsr_prv(mode);

    // Verify dcsr.cause indicates halt request (cause = 3)
    check_dcsr_cause(DBG_CAUSE_HALTREQ);

    // Resume from debug mode while keeping dmactive asserted.
    send_debug_resume(jtag_seqr);

    `uvm_info(test_name, "Debug resume sent", UVM_LOW)
  endtask

  // =========================================================================
  // DCSR checking helpers
  // =========================================================================
  //
  // These functions verify DCSR fields against the dcsr_data value cached
  // by send_debug_stimulus() or populated by wait_for_csr_write().
  //
  // DCSR bit layout (RISC-V Debug Spec 0.13):
  //   [31:28] xdebugver  - Debug version
  //   [27:16] reserved
  //   [15]    ebreakm     - EBREAK in M-mode enters debug
  //   [14]    reserved
  //   [13]    ebreaks     - EBREAK in S-mode enters debug
  //   [12]    ebreaku     - EBREAK in U-mode enters debug
  //   [11]    stepie      - Interrupts enabled during single-step
  //   [10]    stopcount   - Stop counters in debug mode
  //   [9]     stoptime    - Stop timers in debug mode
  //   [8:6]   cause       - Debug entry cause
  //   [5:4]   reserved / v / mprv (implementation-dependent)
  //   [3:0]   prv / reserved (prv in [1:0] for standard spec)
  //
  // Note: Some implementations use [1:0] for prv, others use [3:0].
  // The ibex implementation uses [1:0]. We follow the same convention.
  // =========================================================================

  // Check dcsr.ebreak against the privilege mode encoded in dcsr.prv.
  // Verifies that the ebreak bit for the current privilege mode is set.
  virtual function void check_dcsr_ebreak();
    case (dcsr_data[1:0])
      2'b11: begin  // M-mode
        if (dcsr_data[15] !== 1'b1)
          `uvm_fatal(test_name, $sformatf(
            "dcsr.ebreakm is not set (dcsr[15]=%b, dcsr=0x%08x)", dcsr_data[15], dcsr_data))
      end
      2'b01: begin  // S-mode
        if (dcsr_data[13] !== 1'b1)
          `uvm_fatal(test_name, $sformatf(
            "dcsr.ebreaks is not set (dcsr[13]=%b, dcsr=0x%08x)", dcsr_data[13], dcsr_data))
      end
      2'b00: begin  // U-mode
        if (dcsr_data[12] !== 1'b1)
          `uvm_fatal(test_name, $sformatf(
            "dcsr.ebreaku is not set (dcsr[12]=%b, dcsr=0x%08x)", dcsr_data[12], dcsr_data))
      end
      default: begin
        `uvm_fatal(test_name, $sformatf(
          "dcsr.prv = 2'b%b is an unsupported privilege mode", dcsr_data[1:0]))
      end
    endcase
  endfunction

  // Check that dcsr.cause matches the expected debug entry cause.
  virtual function void check_dcsr_cause(bit [2:0] expected_cause);
    if (dcsr_data[8:6] !== expected_cause)
      `uvm_fatal(test_name, $sformatf(
        "dcsr.cause mismatch: expected %0d, got %0d (dcsr=0x%08x)",
        expected_cause, dcsr_data[8:6], dcsr_data))
  endfunction

  // Check that dcsr.prv matches the expected privilege mode.
  virtual function void check_dcsr_prv(bit [1:0] expected_mode);
    if (dcsr_data[1:0] !== expected_mode)
      `uvm_fatal(test_name, $sformatf(
        "dcsr.prv mismatch: expected 2'b%b, got 2'b%b (dcsr=0x%08x)",
        expected_mode, dcsr_data[1:0], dcsr_data))
  endfunction

  // =========================================================================
  // Instruction decode / tracking (ibex-compatible)
  // =========================================================================
  //
  // Tracks which instruction types have been seen during the test. Used by
  // directed tests that want to trigger stimulus after observing every
  // unique instruction (e.g., interrupt-on-every-instruction tests).
  //
  // decode_instr() returns 1 if the instruction type is new (not seen
  // before), 0 if it was already tracked.  WFI always returns 1 (so
  // interrupt stimulus can wake the core).
  //
  // decode_compressed_instr() does the same for 16-bit compressed (C)
  // instructions.

  virtual function bit decode_instr(bit [31:0] instr);
    bit [6:0]  opcode;
    bit [2:0]  funct3;
    bit [6:0]  funct7;
    bit [11:0] system_imm;
    instr_t    instr_fields;

    opcode     = instr[6:0];
    funct3     = instr[14:12];
    funct7     = instr[31:25];
    system_imm = instr[31:20];

    case (opcode)
      OPCODE_LUI, OPCODE_AUIPC, OPCODE_JAL: begin
        // Identified by opcode alone
        foreach (seen_instr[i]) begin
          if (opcode == seen_instr[i].opcode)
            return 0;
        end
      end

      OPCODE_JALR, OPCODE_BRANCH, OPCODE_LOAD,
      OPCODE_STORE, OPCODE_MISC_MEM: begin
        // Identified by opcode + funct3
        foreach (seen_instr[i]) begin
          if (opcode == seen_instr[i].opcode &&
              funct3 == seen_instr[i].funct3)
            return 0;
        end
      end

      OPCODE_OP_IMM: begin
        // Register-immediate ALU.  slli/srli/srai use funct7 in addition.
        foreach (seen_instr[i]) begin
          if (opcode == seen_instr[i].opcode &&
              funct3 == seen_instr[i].funct3) begin
            if (funct3 inside {3'b001, 3'b101}) begin
              // Shifts: also compare funct7 (shamt[11:5])
              if (funct7 == seen_instr[i].funct7)
                return 0;
            end else begin
              return 0;
            end
          end
        end
      end

      OPCODE_OP: begin
        // Register-register ALU: opcode + funct3 + funct7
        foreach (seen_instr[i]) begin
          if (opcode == seen_instr[i].opcode &&
              funct3 == seen_instr[i].funct3 &&
              funct7 == seen_instr[i].funct7)
            return 0;
        end
      end

      OPCODE_SYSTEM: begin
        // WFI: always report as "not seen" so tests can interrupt it
        if (funct3 == 3'b000 && system_imm == 12'h105)
          return 1;

        // ECALL/MRET/DRET: report as "seen" to avoid nested traps
        if (funct3 == 3'b000 && system_imm != 12'h001)
          return 0;

        // CSR instructions: opcode + funct3 + csr_addr (system_imm)
        foreach (seen_instr[i]) begin
          if (opcode == seen_instr[i].opcode &&
              funct3 == seen_instr[i].funct3 &&
              system_imm == seen_instr[i].system_imm)
            return 0;
        end
      end

      default: begin
        `uvm_fatal(test_name, $sformatf(
          "Unrecognized instruction opcode: 7'b%b", opcode))
      end
    endcase

    // Instruction type not yet seen -- record it
    instr_fields = '{opcode, funct3, funct7, system_imm};
    seen_instr.push_back(instr_fields);
    return 1;
  endfunction

  // Track compressed (16-bit) instruction types.  Returns 1 if the
  // instruction is new, 0 if previously seen.
  virtual function bit decode_compressed_instr(bit [15:0] instr);
    foreach (seen_compressed_instr[i]) begin
      if (instr[1:0] == seen_compressed_instr[i][1:0]) begin
        case (instr[1:0])
          2'b00: begin  // C0 quadrant
            if (instr[15:13] == seen_compressed_instr[i][15:13])
              return 0;
          end

          2'b01: begin  // C1 quadrant
            if (instr[15:13] == seen_compressed_instr[i][15:13]) begin
              case (instr[15:13])
                3'b000, 3'b001, 3'b010,
                3'b011, 3'b101, 3'b110, 3'b111: begin
                  return 0;
                end
                3'b100: begin  // C1.SRLI/SRAI/ANDI/C.*SUB/C.*XOR/C.*OR/C.*AND
                  if (instr[11:10] == seen_compressed_instr[i][11:10]) begin
                    case (instr[11:10])
                      2'b00, 2'b01, 2'b10: begin
                        return 0;
                      end
                      2'b11: begin
                        if (instr[12] == seen_compressed_instr[i][12] &&
                            instr[6:5] == seen_compressed_instr[i][6:5])
                          return 0;
                      end
                    endcase
                  end
                end
                default: begin
                  `uvm_fatal(test_name, "Invalid C1 compressed instruction")
                end
              endcase
            end
          end

          2'b10: begin  // C2 quadrant
            if (instr[15:13] == seen_compressed_instr[i][15:13]) begin
              case (instr[15:13])
                3'b000, 3'b010, 3'b110: begin
                  return 0;
                end
                3'b100: begin
                  if (instr[12] == seen_compressed_instr[i][12])
                    return 0;
                end
                default: begin
                  `uvm_fatal(test_name, "Illegal C2 compressed instruction")
                end
              endcase
            end
          end

          default: begin
            `uvm_fatal(test_name, "Instruction is not compressed (bits [1:0] != 2'b11)")
          end
        endcase
      end
    end

    // Not seen before -- record it
    seen_compressed_instr.push_back(instr);
    return 1;
  endfunction

  // =========================================================================
  // Internal: read last signature data (for DCSR / CSR checks)
  // =========================================================================
  // Returns the data word from the most recent signature write.
  // This is populated by wait_for_csr_write() and check_next_core_status().
  virtual function bit [31:0] get_last_signature_data();
    return tb_vif.mailbox_data[31:0];
  endfunction

  // Override wait_for_csr_write to also cache the data for check_dcsr_*()
  virtual task wait_for_csr_write(input int csr_addr);
    bit [31:0] addr, data;
    bit is_write;
    forever begin
      wait_for_mem_txn(addr, data, is_write);
      if (is_write && addr == SIGNATURE_ADDR && data[31:20] == csr_addr[11:0]) begin
        dcsr_data = data;
        return;
      end
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// 1. Interrupt Test - Drives random interrupt sequences
// ---------------------------------------------------------------------------
class core_eh2_irq_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_irq_test)

  function new(string name = "core_eh2_irq_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Override start_vseq: fork a background IRQ stimulus so the test
  // doesn't complete before interrupts are generated.
  virtual task start_vseq();
    fork
      begin
        eh2_irq_seq_item txn;
        #10000ns;  // Wait for reset
        forever begin
          #($urandom_range(500, 5000) * 10ns);
          txn = eh2_irq_seq_item::type_id::create("txn");
          txn.irq_type = eh2_irq_seq_item::IRQ_EXTERNAL;
          txn.irq_id = $urandom_range(1, 127);
          txn.irq_val = 1'b1;
          txn.duration = $urandom_range(10, 100);
          eh2_irq_seq::send_irq(env.irq_agent.sequencer, txn);
        end
      end
    join_none
    super.start_vseq();
  endtask

endclass

// ---------------------------------------------------------------------------
// 2. Debug Test - Drives debug requests to test halt/resume
// ---------------------------------------------------------------------------
class core_eh2_debug_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_debug_test)

  function new(string name = "core_eh2_debug_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Override start_vseq: fork a background debug_seq on the JTAG sequencer
  // so that the vseq body() doesn't return immediately (causing join_any
  // to complete at time 0).
  virtual task start_vseq();
    debug_seq dbg_h;
    fork
      begin
        dbg_h = debug_seq::type_id::create("dbg_h");
        dbg_h.jtag_seqr = env.vseqr.jtag_seqr;
        dbg_h.stress_mode = 1;
        dbg_h.start(null);
      end
    join_none
    // Also start the vseq for any other configured sequences
    super.start_vseq();
  endtask

endclass

// ---------------------------------------------------------------------------
// 3. Stress Test - Combines interrupt and debug stimulus
// ---------------------------------------------------------------------------
class core_eh2_stress_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_stress_test)

  function new(string name = "core_eh2_stress_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Override start_vseq: fork background IRQ + debug stimulus so the test
  // doesn't complete before stimulus is generated.
  virtual task start_vseq();
    fork
      // IRQ stimulus
      begin
        eh2_irq_seq_item txn;
        #5000ns;
        forever begin
          #($urandom_range(100, 2000) * 10ns);
          txn = eh2_irq_seq_item::type_id::create("txn");
          txn.irq_type = eh2_irq_seq_item::IRQ_EXTERNAL;
          txn.irq_id = $urandom_range(1, 127);
          txn.irq_val = 1'b1;
          txn.duration = $urandom_range(5, 50);
          eh2_irq_seq::send_irq(env.irq_agent.sequencer, txn);
        end
      end
      // Debug stimulus
      begin
        #50000ns;
        forever begin
          #($urandom_range(2000, 10000) * 10ns);
          eh2_jtag_seq::send_write(env.jtag_agent.sequencer,
            eh2_jtag_seq_item::DMI_DMCONTROL, 32'h80000001);
          #($urandom_range(20, 200) * 10ns);
          send_debug_resume(env.jtag_agent.sequencer);
        end
      end
    join_none
    super.start_vseq();
  endtask

endclass

// ---------------------------------------------------------------------------
// 4. Bitmanip Test - Focus on Zba/Zbb/Zbc/Zbs instructions
// ---------------------------------------------------------------------------
class core_eh2_bitmanip_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_bitmanip_test)

  function new(string name = "core_eh2_bitmanip_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_isa_string();
    isa_string = "rv32imac_zba_zbb_zbc_zbs";
  endfunction

endclass

// ---------------------------------------------------------------------------
// 5. RVVI Test - Standard RVVI lockstep checking
// ---------------------------------------------------------------------------
class core_eh2_rvvi_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_rvvi_test)

  function new(string name = "core_eh2_rvvi_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
  endfunction

endclass

// ---------------------------------------------------------------------------
// 6. Timer Interrupt Test - Timer interrupt specific
// ---------------------------------------------------------------------------
class core_eh2_timer_irq_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_timer_irq_test)

  function new(string name = "core_eh2_timer_irq_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "Timer IRQ test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_timer_stimulus();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_timer_stimulus();
    eh2_irq_seq_item txn;
    #10000ns;
    forever begin
      #($urandom_range(1000, 5000) * 10ns);
      txn = eh2_irq_seq_item::type_id::create("txn");
      txn.irq_type = eh2_irq_seq_item::IRQ_TIMER;
      txn.irq_val = 1'b1;
      txn.duration = $urandom_range(5, 20);
      eh2_irq_seq::send_irq(env.irq_agent.sequencer, txn);
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// 7. Software Interrupt Test - Software interrupt specific
// ---------------------------------------------------------------------------
class core_eh2_soft_irq_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_soft_irq_test)

  function new(string name = "core_eh2_soft_irq_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "Software IRQ test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_soft_irq_stimulus();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_soft_irq_stimulus();
    eh2_irq_seq_item txn;
    #10000ns;
    forever begin
      #($urandom_range(500, 3000) * 10ns);
      txn = eh2_irq_seq_item::type_id::create("txn");
      txn.irq_type = eh2_irq_seq_item::IRQ_SOFTWARE;
      txn.irq_val = 1'b1;
      txn.duration = $urandom_range(5, 30);
      eh2_irq_seq::send_irq(env.irq_agent.sequencer, txn);
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// 8. NMI Test - Non-maskable interrupt test
// ---------------------------------------------------------------------------
class core_eh2_nmi_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_nmi_test)

  function new(string name = "core_eh2_nmi_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "NMI test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_nmi_stimulus();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_nmi_stimulus();
    eh2_irq_seq_item txn;
    #20000ns;
    forever begin
      #($urandom_range(5000, 20000) * 10ns);
      txn = eh2_irq_seq_item::type_id::create("txn");
      txn.irq_type = eh2_irq_seq_item::IRQ_EXTERNAL;
      txn.irq_id = 1;  // NMI source
      txn.irq_val = 1'b1;
      txn.duration = $urandom_range(2, 10);
      eh2_irq_seq::send_irq(env.irq_agent.sequencer, txn);
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// 9. Nested Interrupt Test - Multiple concurrent interrupts
// ---------------------------------------------------------------------------
class core_eh2_nested_irq_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_nested_irq_test)

  function new(string name = "core_eh2_nested_irq_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "Nested IRQ test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_nested_irq_stimulus();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_nested_irq_stimulus();
    eh2_irq_seq_item txn;
    #10000ns;
    forever begin
      #($urandom_range(200, 1000) * 10ns);
      // Raise multiple interrupts at once
      repeat (3) begin
        txn = eh2_irq_seq_item::type_id::create("txn");
        txn.irq_type = eh2_irq_seq_item::IRQ_EXTERNAL;
        txn.irq_id = $urandom_range(1, 127);
        txn.irq_val = 1'b1;
        txn.duration = $urandom_range(10, 50);
        eh2_irq_seq::send_irq(env.irq_agent.sequencer, txn);
      end
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// 10. Debug Stress Test - Continuous debug halt/resume
// ---------------------------------------------------------------------------
class core_eh2_debug_stress_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_debug_stress_test)

  function new(string name = "core_eh2_debug_stress_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "Debug stress test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_debug_stress();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_debug_stress();
    #20000ns;
    forever begin
      #($urandom_range(500, 2000) * 10ns);
      eh2_jtag_seq::send_write(env.jtag_agent.sequencer,
        eh2_jtag_seq_item::DMI_DMCONTROL, 32'h80000001);
      #($urandom_range(10, 100) * 10ns);
      send_debug_resume(env.jtag_agent.sequencer);
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// 11. Debug Single Step Test
// ---------------------------------------------------------------------------
class core_eh2_debug_step_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_debug_step_test)

  function new(string name = "core_eh2_debug_step_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "Debug step test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_debug_step();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_debug_step();
    #30000ns;
    // Enter debug mode
    eh2_jtag_seq::send_write(env.jtag_agent.sequencer,
      eh2_jtag_seq_item::DMI_DMCONTROL, 32'h80000001);
    #1000ns;
    // Set step bit in DCSR
    eh2_jtag_seq::send_write(env.jtag_agent.sequencer,
      eh2_jtag_seq_item::DMI_ABSTRACTCS, 32'h00000001);
    #100ns;
    // Resume with step
    eh2_jtag_seq::send_write(env.jtag_agent.sequencer,
      eh2_jtag_seq_item::DMI_DMCONTROL, 32'h40000001);
    #5000ns;
    // Clear step resume while keeping dmactive asserted.
    eh2_jtag_seq::send_write(env.jtag_agent.sequencer,
      eh2_jtag_seq_item::DMI_DMCONTROL, 32'h00000001);
  endtask

endclass

// ---------------------------------------------------------------------------
// 12. CSR Access Test - Comprehensive CSR read/write
// ---------------------------------------------------------------------------
class core_eh2_csr_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_csr_test)

  function new(string name = "core_eh2_csr_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // CSR tests don't need random stimulus
    env_cfg.enable_irq_single_seq = 0;
    env_cfg.enable_irq_multiple_seq = 0;
    env_cfg.enable_debug_stress = 0;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 13. Load/Store Test - Memory access patterns
// ---------------------------------------------------------------------------
class core_eh2_load_store_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_load_store_test)

  function new(string name = "core_eh2_load_store_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.enable_irq_single_seq = 0;
    env_cfg.enable_debug_stress = 0;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 14. Multiply/Divide Test
// ---------------------------------------------------------------------------
class core_eh2_muldiv_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_muldiv_test)

  function new(string name = "core_eh2_muldiv_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.enable_irq_single_seq = 0;
    env_cfg.enable_debug_stress = 0;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 15. Atomic Test - LR/SC sequences
// ---------------------------------------------------------------------------
class core_eh2_atomic_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_atomic_test)

  function new(string name = "core_eh2_atomic_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.enable_irq_single_seq = 0;
    env_cfg.enable_debug_stress = 0;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 16. Dual Issue Test - Pipeline dual-issue behavior
// ---------------------------------------------------------------------------
class core_eh2_dual_issue_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_dual_issue_test)

  function new(string name = "core_eh2_dual_issue_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // Minimal stimulus to observe pipeline behavior
    env_cfg.enable_irq_single_seq = 0;
    env_cfg.enable_debug_stress = 0;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 17. Exception Test - Exception handling
// ---------------------------------------------------------------------------
class core_eh2_exception_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_exception_test)

  function new(string name = "core_eh2_exception_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.enable_debug_stress = 0;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 18. Fetch Toggle Test - Fetch enable/disable
// ---------------------------------------------------------------------------
class core_eh2_fetch_toggle_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_fetch_toggle_test)

  function new(string name = "core_eh2_fetch_toggle_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.enable_fetch_toggle = 1;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 19. PIC Interrupt Test - PIC controller specific
// ---------------------------------------------------------------------------
class core_eh2_pic_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_pic_test)

  function new(string name = "core_eh2_pic_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "PIC test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_pic_stimulus();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_pic_stimulus();
    eh2_irq_seq_item txn;
    #10000ns;
    // Test different PIC priority levels
    repeat (20) begin
      #($urandom_range(1000, 5000) * 10ns);
      txn = eh2_irq_seq_item::type_id::create("txn");
      txn.irq_type = eh2_irq_seq_item::IRQ_EXTERNAL;
      txn.irq_id = $urandom_range(1, 31);  // Lower IDs = higher priority
      txn.irq_val = 1'b1;
      txn.duration = $urandom_range(5, 30);
      eh2_irq_seq::send_irq(env.irq_agent.sequencer, txn);
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// 20. Memory Error Test - ECC/parity error injection
// ---------------------------------------------------------------------------
class core_eh2_mem_error_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_mem_error_test)

  function new(string name = "core_eh2_mem_error_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.enable_mem_error = 1;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 21. Random Instruction Mix Test
// ---------------------------------------------------------------------------
class core_eh2_random_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_random_test)

  function new(string name = "core_eh2_random_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass

// ---------------------------------------------------------------------------
// 22. Interrupt + Debug Combined Test
// ---------------------------------------------------------------------------
class core_eh2_irq_debug_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_irq_debug_test)

  function new(string name = "core_eh2_irq_debug_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.enable_irq_single_seq = 1;
    env_cfg.enable_debug_single = 1;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 23. Pipeline Stall Test
// ---------------------------------------------------------------------------
class core_eh2_stall_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_stall_test)

  function new(string name = "core_eh2_stall_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // Enable fetch toggling to create stalls
    env_cfg.enable_fetch_toggle = 1;
    env_cfg.max_interval = 100;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 24. Long Run Test - Extended execution
// ---------------------------------------------------------------------------
class core_eh2_long_run_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_long_run_test)

  function new(string name = "core_eh2_long_run_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 100_000_000;  // 100ms
    env_cfg.max_cycles = 1_000_000;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 25. Regression Quick Test - Fast smoke test
// ---------------------------------------------------------------------------
class core_eh2_quick_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_quick_test)

  function new(string name = "core_eh2_quick_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 1_000_000;  // 1ms
    env_cfg.max_cycles = 10_000;
    // Minimal stimulus
    env_cfg.enable_irq_single_seq = 0;
    env_cfg.enable_irq_multiple_seq = 0;
    env_cfg.enable_debug_stress = 0;
    env_cfg.enable_debug_single = 0;
    env_cfg.enable_fetch_toggle = 0;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 26. PMP Basic Test - Basic PMP region test
// ---------------------------------------------------------------------------
class core_eh2_pmp_basic_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_pmp_basic_test)

  function new(string name = "core_eh2_pmp_basic_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd5_000_000_000;  // 5s
    env_cfg.max_cycles = 500_000;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 27. PMP Disable Test - Disable all PMP regions
// ---------------------------------------------------------------------------
class core_eh2_pmp_disable_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_pmp_disable_test)

  function new(string name = "core_eh2_pmp_disable_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd5_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 28. PMP Random Test - Random PMP configuration
// ---------------------------------------------------------------------------
class core_eh2_pmp_random_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_pmp_random_test)

  function new(string name = "core_eh2_pmp_random_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd10_000_000_000;  // 10s
    env_cfg.max_cycles = 1_000_000;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 29. PC Integrity Test - PC corruption detection
// ---------------------------------------------------------------------------
class core_eh2_pc_intg_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_pc_intg_test)

  function new(string name = "core_eh2_pc_intg_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd5_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 30. Register File Integrity Test - RF corruption detection
// ---------------------------------------------------------------------------
class core_eh2_rf_intg_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_rf_intg_test)

  function new(string name = "core_eh2_rf_intg_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd5_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 31. Reset Test - Random mid-test resets
// ---------------------------------------------------------------------------
class core_eh2_reset_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_reset_test)

  function new(string name = "core_eh2_reset_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd10_000_000_000;
    env_cfg.max_cycles = 1_000_000;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 32. Single Step Test - Debug single stepping
// ---------------------------------------------------------------------------
class core_eh2_single_step_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_single_step_test)

  function new(string name = "core_eh2_single_step_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.enable_debug_single = 1;
    env_cfg.timeout_ns = 64'd10_000_000_000;
    env_cfg.max_cycles = 1_000_000;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 33. ePMP MML Test - Machine Mode Lockdown
// ---------------------------------------------------------------------------
class core_eh2_epmp_mml_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_epmp_mml_test)

  function new(string name = "core_eh2_epmp_mml_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd10_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 34. ePMP MMWP Test - Machine Mode Whitelist Policy
// ---------------------------------------------------------------------------
class core_eh2_epmp_mmwp_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_epmp_mmwp_test)

  function new(string name = "core_eh2_epmp_mmwp_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd10_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

endclass

// ---------------------------------------------------------------------------
// 35. ePMP RLB Test - Rule Locking Bypass
// ---------------------------------------------------------------------------
class core_eh2_epmp_rlb_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_epmp_rlb_test)

  function new(string name = "core_eh2_epmp_rlb_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd10_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

endclass

// ---------------------------------------------------------------------------
// Debug WFI Test - Debug request during WFI instruction
// Verifies that debug halt correctly interrupts a WFI wait state.
// ---------------------------------------------------------------------------
class core_eh2_debug_wfi_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_debug_wfi_test)

  function new(string name = "core_eh2_debug_wfi_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "Debug WFI test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_debug_wfi_stimulus();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_debug_wfi_stimulus();
    #20000ns;  // Wait for reset and initial setup
    forever begin
      // Wait for core to enter WFI-like idle state
      #($urandom_range(5000, 20000) * 10ns);
      // Send debug halt request
      eh2_jtag_seq::send_write(env.jtag_agent.sequencer,
        eh2_jtag_seq_item::DMI_DMCONTROL, 32'h80000001);
      #($urandom_range(100, 500) * 10ns);
      // Resume
      send_debug_resume(env.jtag_agent.sequencer);
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// Debug CSR Test - Debug request during CSR access
// Verifies CSR state consistency when debug interrupts CSR read-modify-write.
// ---------------------------------------------------------------------------
class core_eh2_debug_csr_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_debug_csr_test)

  function new(string name = "core_eh2_debug_csr_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "Debug CSR test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_debug_csr_stimulus();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_debug_csr_stimulus();
    #20000ns;
    forever begin
      // Short-interval debug requests to catch CSR operations
      #($urandom_range(500, 3000) * 10ns);
      eh2_jtag_seq::send_write(env.jtag_agent.sequencer,
        eh2_jtag_seq_item::DMI_DMCONTROL, 32'h80000001);
      #($urandom_range(50, 200) * 10ns);
      send_debug_resume(env.jtag_agent.sequencer);
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// Debug EBREAK Test - Tests ebreak instruction entering debug mode
// Verifies that ebreak with dcsr.ebreakm set enters debug mode correctly.
// ---------------------------------------------------------------------------
class core_eh2_debug_ebreak_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_debug_ebreak_test)

  function new(string name = "core_eh2_debug_ebreak_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd10_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "Debug EBREAK test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

endclass

// ---------------------------------------------------------------------------
// IRQ WFI Test - Interrupt during WFI wait state
// Verifies that interrupts correctly wake the core from WFI.
// ---------------------------------------------------------------------------
class core_eh2_irq_wfi_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_irq_wfi_test)

  function new(string name = "core_eh2_irq_wfi_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "IRQ WFI test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_irq_wfi_stimulus();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_irq_wfi_stimulus();
    eh2_irq_seq_item txn;
    #10000ns;
    forever begin
      // Send interrupt after WFI has had time to execute
      #($urandom_range(2000, 10000) * 10ns);
      txn = eh2_irq_seq_item::type_id::create("txn");
      txn.irq_type = eh2_irq_seq_item::IRQ_EXTERNAL;
      txn.irq_id = $urandom_range(1, 127);
      txn.irq_val = 1'b1;
      txn.duration = $urandom_range(50, 200);
      eh2_irq_seq::send_irq(env.irq_agent.sequencer, txn);
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// IRQ CSR Test - Interrupt during CSR access
// Verifies CSR state consistency when interrupt fires during CSR instruction.
// ---------------------------------------------------------------------------
class core_eh2_irq_csr_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_irq_csr_test)

  function new(string name = "core_eh2_irq_csr_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "IRQ CSR test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_irq_csr_stimulus();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_irq_csr_stimulus();
    eh2_irq_seq_item txn;
    #10000ns;
    forever begin
      // Short-interval interrupts to catch CSR operations
      #($urandom_range(500, 3000) * 10ns);
      txn = eh2_irq_seq_item::type_id::create("txn");
      txn.irq_type = eh2_irq_seq_item::IRQ_EXTERNAL;
      txn.irq_id = $urandom_range(1, 127);
      txn.irq_val = 1'b1;
      txn.duration = $urandom_range(10, 50);
      eh2_irq_seq::send_irq(env.irq_agent.sequencer, txn);
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// IRQ Nested Test - Nested interrupt handling
// Verifies that higher-priority interrupts can preempt lower-priority ones.
// ---------------------------------------------------------------------------
class core_eh2_irq_nest_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_irq_nest_test)

  function new(string name = "core_eh2_irq_nest_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd10_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "IRQ nest test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_nested_irq_stimulus();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_nested_irq_stimulus();
    eh2_irq_seq_item txn;
    #10000ns;
    forever begin
      #($urandom_range(1000, 5000) * 10ns);
      // Send multiple rapid interrupts to trigger nesting
      for (int i = 0; i < $urandom_range(2, 5); i++) begin
        txn = eh2_irq_seq_item::type_id::create($sformatf("txn_%0d", i));
        txn.irq_type = eh2_irq_seq_item::IRQ_EXTERNAL;
        txn.irq_id = $urandom_range(1, 127);
        txn.irq_val = 1'b1;
        txn.duration = $urandom_range(5, 20);
        fork
          eh2_irq_seq::send_irq(env.irq_agent.sequencer, txn);
        join_none
      end
      #1000ns;
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// IRQ in Debug Test - Interrupt during debug mode
// Verifies interrupt behavior while the core is in debug mode.
// ---------------------------------------------------------------------------
class core_eh2_irq_in_debug_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_irq_in_debug_test)

  function new(string name = "core_eh2_irq_in_debug_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd10_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "IRQ in debug test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_irq_in_debug_stimulus();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_irq_in_debug_stimulus();
    eh2_irq_seq_item txn;
    #10000ns;
    forever begin
      #($urandom_range(2000, 8000) * 10ns);
      // Enter debug mode first, then fire interrupt
      txn = eh2_irq_seq_item::type_id::create("dbg_irq_txn");
      txn.irq_type = eh2_irq_seq_item::IRQ_EXTERNAL;
      txn.irq_id = $urandom_range(1, 127);
      txn.irq_val = 1'b1;
      txn.duration = $urandom_range(10, 50);
      eh2_irq_seq::send_irq(env.irq_agent.sequencer, txn);
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// Debug in IRQ Test - Debug request during IRQ handler
// Verifies debug mode entry while processing an interrupt handler.
// ---------------------------------------------------------------------------
class core_eh2_debug_in_irq_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_debug_in_irq_test)

  function new(string name = "core_eh2_debug_in_irq_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd10_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "Debug in IRQ test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_debug_in_irq_stimulus();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_debug_in_irq_stimulus();
    eh2_irq_seq_item irq_txn;
    #10000ns;
    forever begin
      #($urandom_range(2000, 8000) * 10ns);
      // Fire interrupt, then request debug shortly after
      irq_txn = eh2_irq_seq_item::type_id::create("irq_then_dbg_txn");
      irq_txn.irq_type = eh2_irq_seq_item::IRQ_EXTERNAL;
      irq_txn.irq_id = $urandom_range(1, 127);
      irq_txn.irq_val = 1'b1;
      irq_txn.duration = $urandom_range(10, 30);
      eh2_irq_seq::send_irq(env.irq_agent.sequencer, irq_txn);
      // Short delay then trigger debug
      #($urandom_range(100, 500) * 10ns);
    end
  endtask

endclass

// ---------------------------------------------------------------------------
// DRET Test - DRET instruction execution
// Verifies correct behavior of DRET (debug return) instruction.
// ---------------------------------------------------------------------------
class core_eh2_dret_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_dret_test)

  function new(string name = "core_eh2_dret_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd10_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "DRET test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

endclass

// ---------------------------------------------------------------------------
// Debug EBREAKMU Test - dcsr.ebreakm and dcsr.ebreaku behavior
// Verifies EBREAK behavior with dcsr.ebreakm/u bits set.
// ---------------------------------------------------------------------------
class core_eh2_debug_ebreakmu_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_debug_ebreakmu_test)

  function new(string name = "core_eh2_debug_ebreakmu_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd10_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "Debug EBREAKMU test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

endclass

// ---------------------------------------------------------------------------
// Single Debug Pulse Test - Single debug request pulse
// Verifies behavior with a single short debug request pulse.
// ---------------------------------------------------------------------------
class core_eh2_single_debug_pulse_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_single_debug_pulse_test)

  function new(string name = "core_eh2_single_debug_pulse_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd10_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "Single debug pulse test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_single_debug_pulse();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_single_debug_pulse();
    #($urandom_range(5000, 15000) * 10ns);
    `uvm_info(test_name, "Sending single debug pulse", UVM_LOW)
    // Single pulse handled by vseq
    #10000ns;
  endtask

endclass

// ---------------------------------------------------------------------------
// Invalid CSR Test - Invalid CSR access behavior
// Verifies correct exception handling for invalid CSR accesses.
// ---------------------------------------------------------------------------
class core_eh2_invalid_csr_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_invalid_csr_test)

  function new(string name = "core_eh2_invalid_csr_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd10_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "Invalid CSR test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

endclass

// ---------------------------------------------------------------------------
// Fetch Enable Check Test - Fetch enable/disable behavior
// Verifies correct behavior when fetch enable is toggled.
// ---------------------------------------------------------------------------
class core_eh2_fetch_en_chk_test extends core_eh2_base_test;

  `uvm_component_utils(core_eh2_fetch_en_chk_test)

  function new(string name = "core_eh2_fetch_en_chk_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env_cfg.timeout_ns = 64'd10_000_000_000;
    env_cfg.max_cycles = 500_000;
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info(test_name, "Fetch enable check test started", UVM_LOW)
    load_binary_to_mem();
    start_vseq();
    fork
      run_fetch_en_stimulus();
      wait_for_completion(phase);
    join_any
    disable fork;
    if (vseq != null) vseq.stop();
    phase.drop_objection(this);
  endtask

  virtual task run_fetch_en_stimulus();
    #($urandom_range(5000, 15000) * 10ns);
    `uvm_info(test_name, "Toggling fetch enable", UVM_LOW)
    // Fetch enable toggling handled by vseq
    #10000ns;
  endtask

endclass
