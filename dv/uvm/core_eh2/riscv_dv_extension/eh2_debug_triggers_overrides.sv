// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Hardware trigger debug ROM and program generator overrides for EH2 (VeeR).
//
// These classes customize the riscv-dv debug ROM generation to support
// hardware trigger testing.  They are used when the testbench selects
// the +enable_hardware_triggers option.

class eh2_hardware_triggers_debug_rom_gen extends riscv_debug_rom_gen;

  `uvm_object_utils(eh2_hardware_triggers_debug_rom_gen)
  `uvm_object_new

  int unsigned eh2_trigger_idx = 0; // See [DbgHwBreakNum]

  virtual function void gen_program();
    string instr[$];

    // Don't save off GPRs (ie. this WILL modify program flow).
    // We want to capture a register value (gpr[1]) from the directed_instr_streams
    // in main() that contains the address for our next trigger.
    // This works in tandem with the breakpoint directed stream which stores the
    // address of the instruction to trigger on in a fixed register, then executes
    // an EBREAK to enter debug mode via dcsr.ebreakm=1.  The debug ROM code then
    // sets up the breakpoint trigger to this address, and returns, allowing main
    // to continue executing until we hit the trigger.

    // riscv-debug-1.0.0-STABLE
    //   5.5 Trigger Registers
    //   <..>
    //   As a result, a debugger can write any supported trigger as follows..
    //
    //   1. Write 0 to TDATA1. (This will result in TDATA1 containing a non-zero
    //      value, since the register is WARL).
    //   2. Write desired values to TDATA2 and TDATA3.
    //   3. Write desired value to TDATA1.
    // <..>

    instr = {// Check DCSR.cause (DCSR[8:6]) to branch to the next block of code.
             $sformatf("csrr x%0d,   0x%0x",        cfg.scratch_reg, DCSR),
             $sformatf("slli x%0d,    x%0d,  0x17", cfg.scratch_reg, cfg.scratch_reg),
             $sformatf("srli x%0d,    x%0d,  0x1d", cfg.scratch_reg, cfg.scratch_reg),
             $sformatf("li   x%0d,     0x1",        cfg.gpr[0]), // EBREAK = 1
             $sformatf("beq  x%0d,    x%0d,  1f",   cfg.scratch_reg, cfg.gpr[0]),
             $sformatf("li   x%0d,     0x2",        cfg.gpr[0]), // TRIGGER = 2
             $sformatf("beq  x%0d,    x%0d,  2f",   cfg.scratch_reg, cfg.gpr[0]),
             $sformatf("li   x%0d,     0x3",        cfg.gpr[0]), // HALTREQ = 3
             $sformatf("beq  x%0d,    x%0d,  3f",   cfg.scratch_reg, cfg.gpr[0]),

             // DCSR.cause == EBREAK
             "1: nop",
             // The breakpoint directed stream inserts EBREAKs such that cfg.gpr[1]
             // now contains the address of the next trigger.
             // Enable the trigger and set to this address.
             $sformatf("csrrwi  zero, 0x%0x, %0d",  TSELECT, eh2_trigger_idx),
             $sformatf("csrrw   zero, 0x%0x, x0",   TDATA1),
             $sformatf("csrrw   zero, 0x%0x, x%0d", TDATA2, cfg.gpr[1]),
             $sformatf("csrrwi  zero, 0x%0x, 5",    TDATA1),
             // Increment the PC + 4 (EBREAK does not do this for you.)
             $sformatf("csrr   x%0d, 0x%0x",    cfg.gpr[0], DPC),
             $sformatf("addi   x%0d,  x%0d, 4", cfg.gpr[0], cfg.gpr[0]),
             $sformatf("csrw  0x%0x,  x%0d",    DPC, cfg.gpr[0]),
             "j 4f",

             // DCSR.cause == TRIGGER
             "2: nop",
             // Disable the trigger until the next breakpoint is known.
             $sformatf("csrrwi  zero, 0x%0x, %0d", TSELECT, eh2_trigger_idx),
             $sformatf("csrrw   zero, 0x%0x, x0",  TDATA1),
             $sformatf("csrrw   zero, 0x%0x, x0",  TDATA2),
             "j 4f",

             // DCSR.cause == HALTREQ
             "3: nop",
             // Use this once near the start of the test to configure ebreakm to
             // enter debug mode.
             // Set DCSR.ebreakm (DCSR[15]) = 1
             $sformatf("li      x%0d, 0x8000", cfg.scratch_reg),
             $sformatf("csrs   0x%0x,  x%0d",  DCSR, cfg.scratch_reg),

             "4: nop"
             };

    debug_main = {instr,
                  $sformatf("la   x%0d, debug_end", cfg.scratch_reg),
                  $sformatf("jalr x0,   x%0d, 0",   cfg.scratch_reg)
                  };
    format_section(debug_main);
    gen_section($sformatf("%0sdebug_rom", hart_prefix(hart)), debug_main);

    debug_end = {dret};
    format_section(debug_end);
    gen_section($sformatf("%0sdebug_end", hart_prefix(hart)), debug_end);

    gen_debug_exception_handler();
  endfunction


  // If we get an exception in debug_mode, fail the test immediately.
  // (something has gone wrong with our stimulus generation)
  virtual function void gen_debug_exception_handler();
    string instr[$];
    instr = {$sformatf("la   x%0d, test_fail", cfg.scratch_reg),
             $sformatf("jalr x1,   x%0d, 0",   cfg.scratch_reg)};
    format_section(instr);
    gen_section($sformatf("%0sdebug_exception", hart_prefix(hart)), instr);
  endfunction

endclass

class eh2_hardware_triggers_asm_program_gen extends eh2_asm_program_gen;

  `uvm_object_utils(eh2_hardware_triggers_asm_program_gen)
  `uvm_object_new

  // Same implementation as the parent class, except substitute for our custom
  // debug ROM class.
  virtual function void gen_debug_rom(int hart);
    `uvm_info(`gfn, "Creating debug ROM", UVM_LOW)
    debug_rom = eh2_hardware_triggers_debug_rom_gen::
                type_id::create("debug_rom", , {"uvm_test_top", ".", `gfn});
    debug_rom.cfg = cfg;
    debug_rom.hart = hart;
    debug_rom.gen_program();
    instr_stream = {instr_stream, debug_rom.instr_stream};
  endfunction

  virtual function void gen_ebreak_handler(int hart);
    string instr[$];

    // EH2 ordinary execute triggers report mcause=BREAKPOINT in M-mode.  This
    // directed test programs tdata2 to the following NOP; handle that breakpoint
    // as expected stimulus, disable the trigger, and return to the same mepc so
    // the target instruction retires once normally.
    instr = {
      $sformatf("csrrwi zero, 0x%0x, 0", TSELECT),
      $sformatf("csrrw  zero, 0x%0x, x0", TDATA1),
      $sformatf("csrrw  zero, 0x%0x, x0", TDATA2)
    };
    pop_gpr_from_kernel_stack(MSTATUS, MSCRATCH, cfg.mstatus_mprv,
                              cfg.sp, cfg.tp, instr);
    save_next_kernel_sp(hart, instr);
    instr.push_back("mret");
    gen_section(get_label("ebreak_handler", hart), instr);
  endfunction

endclass

class eh2_hardware_trigger_stream extends eh2_base_directed_stream;

  `uvm_object_utils(eh2_hardware_trigger_stream)

  int unsigned eh2_trigger_idx = 0; // See [DbgHwBreakNum]
  int unsigned stream_idx;
  static int unsigned next_stream_idx;

  localparam bit [31:0] EH2_TRIGGER_EXECUTE_BREAKPOINT = 32'h0000_0044;

  function new(string name = "");
    super.new(name);
    stream_idx = next_stream_idx++;
  endfunction

  virtual function void gen_instr(bit no_branch = 1, bit no_load_store = 1,
                                  bit is_debug_program = 0);
    riscv_pseudo_instr la_instr;
    riscv_pseudo_instr li_instr;
    riscv_instr instr;
    string target_label;

    target_label = $sformatf("hardware_trigger_target_%0d", stream_idx);

    la_instr = riscv_pseudo_instr::type_id::create("la_trigger_target");
    la_instr.pseudo_instr_name = LA;
    la_instr.rd = cfg.gpr[1];
    la_instr.imm_str = target_label;
    instr_list.push_back(la_instr);

    instr = riscv_instr::get_instr(CSRRWI);
    instr.csr = TSELECT;
    instr.rd = ZERO;
    instr.imm = eh2_trigger_idx;
    instr.imm_str = $sformatf("0x%0x", eh2_trigger_idx);
    instr_list.push_back(instr);

    // WARL programming sequence from riscv-debug trigger register guidance:
    // clear tdata1, write tdata2, then enable the trigger.
    instr = riscv_instr::get_instr(CSRRW);
    instr.csr = TDATA1;
    instr.rd = ZERO;
    instr.has_rs1 = 1;
    instr.rs1 = ZERO;
    instr_list.push_back(instr);

    instr = riscv_instr::get_instr(CSRRW);
    instr.csr = TDATA2;
    instr.rd = ZERO;
    instr.has_rs1 = 1;
    instr.rs1 = cfg.gpr[1];
    instr_list.push_back(instr);

    li_instr = riscv_pseudo_instr::type_id::create("li_trigger_cfg");
    li_instr.pseudo_instr_name = LI;
    li_instr.rd = cfg.gpr[0];
    li_instr.imm_str = $sformatf("0x%0x", EH2_TRIGGER_EXECUTE_BREAKPOINT);
    instr_list.push_back(li_instr);

    instr = riscv_instr::get_instr(CSRRW);
    instr.csr = TDATA1;
    instr.rd = ZERO;
    instr.has_rs1 = 1;
    instr.rs1 = cfg.gpr[0];
    instr_list.push_back(instr);

    instr = riscv_instr::get_instr(CSRRSI);
    instr.csr = MSTATUS;
    instr.rd = ZERO;
    instr.imm = 5'h8;
    instr.imm_str = "0x8";
    instr_list.push_back(instr);

    instr = riscv_instr::get_instr(NOP);
    instr.has_label = 1'b1;
    instr.label = target_label;
    instr.comment = "EH2 hardware trigger target";
    instr_list.push_back(instr);

    instr = riscv_instr::get_instr(CSRRCI);
    instr.csr = MSTATUS;
    instr.rd = ZERO;
    instr.imm = 5'h8;
    instr.imm_str = "0x8";
    instr_list.push_back(instr);
  endfunction

  function void post_randomize();
    gen_instr();
    if (instr_list.size() == 0) begin
      `uvm_fatal(get_full_name(),
                 "EH2 hardware trigger stream produced an empty instr_list")
    end
    foreach(instr_list[i]) begin
      instr_list[i].atomic = 1'b1;
      instr_list[i].has_label = 1'b0;
      if (instr_list[i].comment == "EH2 hardware trigger target") begin
        instr_list[i].has_label = 1'b1;
      end
    end
    instr_list[0].comment = $sformatf("Start %0s", get_name());
    instr_list[$].comment = $sformatf("End %0s", get_name());
    if(label != "") begin
      instr_list[0].label = label;
      instr_list[0].has_label = 1'b1;
    end
  endfunction

endclass


class eh2_hardware_triggers_illegal_instr extends riscv_illegal_instr;

  `uvm_object_utils(eh2_hardware_triggers_illegal_instr)
  `uvm_object_new

  // Make it super-obvious where the illegal instructions are in the assembly.
  function void post_randomize();
    super.post_randomize();
    comment = "INVALID";
  endfunction

endclass // eh2_hardware_triggers_illegal_instr
