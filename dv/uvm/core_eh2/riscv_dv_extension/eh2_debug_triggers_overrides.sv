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
