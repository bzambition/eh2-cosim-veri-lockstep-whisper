// SPDX-License-Identifier: Apache-2.0
// EH2 Assembly Program Generator
//
// Extends riscv_asm_program_gen to customize test program generation
// for the EH2 (VeeR) RISC-V core.
//
// Key customizations:
//   - Machine-mode only (no user/supervisor)
//   - EH2-specific CSR initialization
//   - Test pass/fail via memory-mapped signature (mailbox)
//   - ECALL handler increments MEPC and returns (does not end test)

class eh2_asm_program_gen extends riscv_asm_program_gen;

  `uvm_object_utils(eh2_asm_program_gen)

  localparam string EH2_KSP_LABEL = "eh2_kernel_sp";

  function new(string name = "");
    super.new(name);
  endfunction

  // Override program generation to set EH2-specific defaults
  virtual function void gen_program();
    // Exclude CSRs that cause co-sim mismatches or are read-only
    default_include_csr_write.delete();
    // Standard M-mode CSRs
    default_include_csr_write.push_back(MSTATUS);
    default_include_csr_write.push_back(MIE);
    default_include_csr_write.push_back(MTVEC);
    default_include_csr_write.push_back(MCAUSE);
    default_include_csr_write.push_back(MTVAL);
    default_include_csr_write.push_back(MCOUNTINHIBIT);
    default_include_csr_write.push_back(MEDELEG);
    default_include_csr_write.push_back(MIDELEG);
    default_include_csr_write.push_back(MIP);
    default_include_csr_write.push_back(PMPADDR0);
    default_include_csr_write.push_back(PMPADDR1);
    default_include_csr_write.push_back(PMPADDR2);
    default_include_csr_write.push_back(PMPADDR3);
    default_include_csr_write.push_back(PMPCFG0);
    super.gen_program();
  endfunction

  // Override program header for EH2 memory map
  virtual function void gen_program_header();
    // EH2 boots from 0x8000_0000
    // Section and label setup
    instr_stream.push_back(".section .text");
    instr_stream.push_back(".global _start");
    instr_stream.push_back("_start:");

    // Initialize stack pointer to the external RAM window used by the EH2 DV linker.
    instr_stream.push_back($sformatf("li sp, 0x%08x", 32'h8200_0000));

    // Set mstatus.MIE = 1
    instr_stream.push_back("li t0, 0x8");
    instr_stream.push_back("csrw mstatus, t0");
  endfunction

  // Keep the trap kernel-stack pointer in a memory slot. Random tests and
  // riscv-dv interrupt helpers may freely modify cfg.tp/MSCRATCH, while the
  // upstream push_gpr_to_kernel_stack() prologue expects cfg.tp to hold KSP.
  virtual function void pre_enter_privileged_mode(int hart);
    string instr[$];
    string old_instr_stream[$];
    string kernel_sp_label;
    string slot_label;
    super.pre_enter_privileged_mode(hart);

    slot_label = get_label(EH2_KSP_LABEL, hart);
    old_instr_stream = instr_stream;
    instr_stream.delete();
    instr = {
      $sformatf("la x%0d, %0skernel_stack_end", cfg.tp, hart_prefix(hart)),
      $sformatf("la x%0d, %0s", cfg.scratch_reg, slot_label),
      $sformatf("sw x%0d, 0(x%0d) # save EH2 KSP", cfg.tp, cfg.scratch_reg)
    };
    gen_section(get_label("kernel_sp", hart), instr);
    instr = instr_stream;
    instr_stream = old_instr_stream;

    kernel_sp_label = format_string(
      $sformatf("%0s:", get_label("kernel_sp", hart)), LABEL_STR_LEN);
    foreach (instr_stream[i]) begin
      if (instr_stream[i] == kernel_sp_label) begin
        instr_stream.delete(i);
        instr_stream.delete(i);
        foreach (instr[j]) begin
          instr_stream.insert(i + j, instr[j]);
        end
        break;
      end
    end
  endfunction

  function void save_next_kernel_sp(int hart, ref string instr[$]);
    string slot_label;
    slot_label = get_label(EH2_KSP_LABEL, hart);
    instr.push_back($sformatf("la x%0d, %0s", cfg.scratch_reg, slot_label));
    instr.push_back($sformatf("sw x%0d, 0(x%0d) # save EH2 KSP", cfg.tp, cfg.scratch_reg));
  endfunction

  function void gen_eh2_kernel_sp_slot(int hart);
    string instr[$];
    instr = {
      ".4byte 0x0"
    };
    gen_section(get_label(EH2_KSP_LABEL, hart), instr);
  endfunction

  virtual function void gen_trap_handler_section(int hart,
                                                 string mode,
                                                 privileged_reg_t cause,
                                                 privileged_reg_t tvec,
                                                 privileged_reg_t tval,
                                                 privileged_reg_t epc,
                                                 privileged_reg_t scratch,
                                                 privileged_reg_t status,
                                                 privileged_reg_t ie,
                                                 privileged_reg_t ip);
    string handler_label;
    string save_done;
    int unsigned insert_idx;
    int unsigned save_idx;
    bit inserted;
    bit saved_after_push;

    super.gen_trap_handler_section(hart, mode, cause, tvec, tval, epc,
                                   scratch, status, ie, ip);

    if (scratch != MSCRATCH) begin
      return;
    end

    handler_label = get_label($sformatf("%0s_handler", tvec.name().tolower()), hart);
    handler_label = format_string($sformatf("%0s:", handler_label), LABEL_STR_LEN);
    foreach (instr_stream[i]) begin
      if (instr_stream[i] == handler_label) begin
        insert_idx = i + 1;
        inserted = 1'b1;
        break;
      end
    end

    if (inserted) begin
      instr_stream.insert(insert_idx,
        $sformatf("%sla x%0d, %0s", indent, cfg.scratch_reg, get_label(EH2_KSP_LABEL, hart)));
      instr_stream.insert(insert_idx + 1,
        $sformatf("%slw x%0d, 0(x%0d) # restore EH2 KSP", indent, cfg.tp, cfg.scratch_reg));
    end

    save_done = $sformatf("%sadd x%0d, x%0d, zero", indent, cfg.tp, cfg.sp);
    foreach (instr_stream[i]) begin
      if (i <= insert_idx) begin
        continue;
      end
      if (instr_stream[i] == save_done) begin
        save_idx = i + 1;
        saved_after_push = 1'b1;
        break;
      end
    end
    if (saved_after_push) begin
      instr_stream.insert(save_idx,
        $sformatf("%sla x%0d, %0s", indent, cfg.scratch_reg, get_label(EH2_KSP_LABEL, hart)));
      instr_stream.insert(save_idx + 1,
        $sformatf("%ssw x%0d, 0(x%0d) # save EH2 KSP", indent, cfg.tp, cfg.scratch_reg));
    end
  endfunction

  // Override ECALL handler: increment MEPC+4 and mret (do not end test)
  virtual function void gen_ecall_handler(int hart);
    string instr[$];
    instr = {
      "csrr t0, mepc",
      "addi t0, t0, 4",
      "csrw mepc, t0",
      "mret"
    };
    gen_section(get_label("ecall_handler", hart), instr);
  endfunction

  function void append_skip_faulting_insn(ref string instr[$]);
    instr = {instr,
      "csrr t0, mepc",
      "addi t0, t0, 4",
      "csrw mepc, t0"
    };
  endfunction

  virtual function void gen_instr_fault_handler(int hart);
    string instr[$];
    gen_signature_handshake(instr, CORE_STATUS, INSTR_FAULT_EXCEPTION);
    gen_signature_handshake(.instr(instr), .signature_type(WRITE_CSR), .csr(MCAUSE));
    if (cfg.pmp_cfg.enable_pmp_exception_handler) begin
      cfg.pmp_cfg.gen_pmp_exception_routine({cfg.gpr, cfg.scratch_reg, cfg.pmp_reg[0],
                                             cfg.pmp_reg[1]},
                                            INSTRUCTION_ACCESS_FAULT,
                                            instr);
    end
    append_skip_faulting_insn(instr);
    pop_gpr_from_kernel_stack(MSTATUS, MSCRATCH, cfg.mstatus_mprv, cfg.sp, cfg.tp, instr);
    save_next_kernel_sp(hart, instr);
    instr.push_back("mret");
    gen_section(get_label("instr_fault_handler", hart), instr);
  endfunction

  virtual function void gen_load_fault_handler(int hart);
    string instr[$];
    gen_signature_handshake(instr, CORE_STATUS, LOAD_FAULT_EXCEPTION);
    gen_signature_handshake(.instr(instr), .signature_type(WRITE_CSR), .csr(MCAUSE));
    if (cfg.pmp_cfg.enable_pmp_exception_handler) begin
      cfg.pmp_cfg.gen_pmp_exception_routine({cfg.gpr, cfg.scratch_reg, cfg.pmp_reg[0],
                                             cfg.pmp_reg[1]},
                                            LOAD_ACCESS_FAULT,
                                            instr);
    end
    append_skip_faulting_insn(instr);
    pop_gpr_from_kernel_stack(MSTATUS, MSCRATCH, cfg.mstatus_mprv, cfg.sp, cfg.tp, instr);
    save_next_kernel_sp(hart, instr);
    instr.push_back("mret");
    gen_section(get_label("load_fault_handler", hart), instr);
  endfunction

  virtual function void gen_store_fault_handler(int hart);
    string instr[$];
    gen_signature_handshake(instr, CORE_STATUS, STORE_FAULT_EXCEPTION);
    gen_signature_handshake(.instr(instr), .signature_type(WRITE_CSR), .csr(MCAUSE));
    if (cfg.pmp_cfg.enable_pmp_exception_handler) begin
      cfg.pmp_cfg.gen_pmp_exception_routine({cfg.gpr, cfg.scratch_reg, cfg.pmp_reg[0],
                                             cfg.pmp_reg[1]},
                                            STORE_AMO_ACCESS_FAULT,
                                            instr);
    end
    append_skip_faulting_insn(instr);
    pop_gpr_from_kernel_stack(MSTATUS, MSCRATCH, cfg.mstatus_mprv, cfg.sp, cfg.tp, instr);
    save_next_kernel_sp(hart, instr);
    instr.push_back("mret");
    gen_section(get_label("store_fault_handler", hart), instr);
  endfunction

  virtual function void gen_program_end(int hart);
    // EH2 tests end via mailbox writes from test_done/test_fail.
  endfunction

  // Generate a single EH2 mailbox write. 0xff means pass, 0x01 means fail.
  virtual function void gen_test_end(input bit pass, ref string instr[$]);
    instr = {
      $sformatf("li t0, 0x%08x", 32'hD058_0000),
      pass ? "li t1, 0xff" : "li t1, 0x01",
      "sw t1, 0(t0)",
      "1: j 1b"
    };
  endfunction

  // Override the upstream write_tohost/ecall ending with the EH2 mailbox.
  virtual function void gen_test_done();
    string instr[$];
    gen_test_end(1'b1, instr);
    instr_stream = {instr_stream, {format_string("test_done:", LABEL_STR_LEN)}, instr};
    instr.delete();
    gen_test_end(1'b0, instr);
    instr_stream = {instr_stream, {format_string("test_fail:", LABEL_STR_LEN)}, instr};
  endfunction

  // Override init section to include test_done/test_fail labels
  virtual function void gen_init_section(int hart);
    super.gen_init_section(hart);
    init_eh2_custom_csr(hart);
    instr_stream.push_back($sformatf("%0sj h%0d_main", indent, hart));
    gen_nmi_handler(hart);
    gen_eh2_kernel_sp_slot(hart);
  endfunction

  // Initialize EH2-specific CSRs
  virtual function void init_eh2_custom_csr(int hart);
    // Enable all performance counters via mcountinhibit
    instr_stream.push_back($sformatf("# EH2 custom CSR init for hart %0d", hart));
    instr_stream.push_back("li t0, 0x0");
    instr_stream.push_back("csrw mcountinhibit, t0");

    // Configure MRAC (memory region access control)
    instr_stream.push_back("li t0, 0x1A55A5A5");  // All regions: cacheable
    instr_stream.push_back("csrw 0x7C0, t0");     // mrac

    // Set MFDC (feature disable control) - enable all features
    instr_stream.push_back("li t0, 0x0");
    instr_stream.push_back("csrw 0x7F9, t0");     // mfdc
  endfunction

  // Generate NMI handler
  virtual function void gen_nmi_handler(int hart);
    instr_stream.push_back("");
    instr_stream.push_back("# NMI handler");
    instr_stream.push_back($sformatf("h%0d_nmi_handler:", hart));
    instr_stream.push_back("  # NMI - read MNMCause for info");
    instr_stream.push_back("  csrr t0, 0x7F8");     // mcgc - read for debug
    instr_stream.push_back("  # Return from NMI via mret");
    instr_stream.push_back("  mret");
  endfunction

  // Generate debug ROM section (for debug mode support)
  virtual function void gen_debug_rom(int hart);
    instr_stream.push_back("");
    instr_stream.push_back("# Debug ROM");
    instr_stream.push_back(".section .debug_rom, \"ax\"");
    instr_stream.push_back($sformatf("h%0d_debug_rom:", hart));
    instr_stream.push_back("  # Read DCSR");
    instr_stream.push_back("  csrr t0, 0x7B0");     // dcsr
    instr_stream.push_back("  # Read DPC");
    instr_stream.push_back("  csrr t1, 0x7B1");     // dpc
    instr_stream.push_back("  # Resume execution");
    instr_stream.push_back("  csrci 0x7B0, 0x4");   // Clear ebreakm in dcsr
    instr_stream.push_back("  dret");
  endfunction

endclass
