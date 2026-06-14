// SPDX-License-Identifier: Apache-2.0
// EH2 Trace Sequence Item - Represents a committed instruction
//
// Captures instruction commit information from the EH2 trace interface.
// Each item represents one committed instruction.

class eh2_trace_seq_item extends uvm_sequence_item;

  // Thread ID
  rand bit thread_id;

  // Instruction slot (0 or 1 - EH2 can commit 2 per cycle)
  rand bit slot;

  // Instruction information
  bit [31:0] pc;
  bit [31:0] insn;

  // Exception information
  bit        exception;
  bit [4:0]  ecause;
  bit        interrupt;
  bit [31:0] tval;

  // Register writeback (from DUT probe)
  bit        wb_valid;
  bit [4:0]  wb_dest;
  bit [31:0] wb_data;
  bit        wb_suppress;  // Writeback suppressed (killed load or canceled DIV)
  int        wb_tag;       // Writeback sequence tag for trace-to-wb correlation
  int        wb_source;    // EH2_WB_SRC_*: regular, DIV, or non-blocking load

  // Interrupt/NMI/debug state (from DUT probe, for Spike notification)
  bit [31:0] mip;          // Machine interrupt pending
  bit        nmi;          // NMI mode
  bit        nmi_int;      // NMI interrupt pending
  bit        debug_req;    // Debug request active
  bit [63:0] mcycle;       // Cycle counter

  // DUT-side trap CSR snapshot (sampled by trace_monitor when exception/interrupt)
  bit [31:0] dut_mtvec;
  bit [31:0] dut_mepc;
  bit [31:0] dut_mcause;
  bit [31:0] dut_mtval;

  // Timing
  time       commit_time;
  int        cycle_count;

  `uvm_object_utils_begin(eh2_trace_seq_item)
    `uvm_field_int(thread_id, UVM_ALL_ON)
    `uvm_field_int(slot, UVM_ALL_ON)
    `uvm_field_int(pc, UVM_ALL_ON)
    `uvm_field_int(insn, UVM_ALL_ON)
    `uvm_field_int(exception, UVM_ALL_ON)
    `uvm_field_int(ecause, UVM_ALL_ON)
    `uvm_field_int(interrupt, UVM_ALL_ON)
    `uvm_field_int(tval, UVM_ALL_ON)
    `uvm_field_int(wb_valid, UVM_ALL_ON)
    `uvm_field_int(wb_dest, UVM_ALL_ON)
    `uvm_field_int(wb_data, UVM_ALL_ON)
    `uvm_field_int(wb_suppress, UVM_ALL_ON)
    `uvm_field_int(wb_tag, UVM_ALL_ON)
    `uvm_field_int(wb_source, UVM_ALL_ON)
    `uvm_field_int(mip, UVM_ALL_ON)
    `uvm_field_int(nmi, UVM_ALL_ON)
    `uvm_field_int(nmi_int, UVM_ALL_ON)
    `uvm_field_int(debug_req, UVM_ALL_ON)
    `uvm_field_int(mcycle, UVM_ALL_ON)
    `uvm_field_int(dut_mtvec, UVM_ALL_ON)
    `uvm_field_int(dut_mepc, UVM_ALL_ON)
    `uvm_field_int(dut_mcause, UVM_ALL_ON)
    `uvm_field_int(dut_mtval, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "eh2_trace_seq_item");
    super.new(name);
  endfunction

  // Convert to string
  function string convert2string();
    return $sformatf("t%0d.%0d PC=%08x INSN=%08x %s",
      thread_id, slot, pc, insn,
      exception ? $sformatf("EXC=%0d", ecause) : "OK");
  endfunction

  // Get instruction opcode
  function bit [6:0] get_opcode();
    return insn[6:0];
  endfunction

  // Get destination register
  function bit [4:0] get_rd();
    return insn[11:7];
  endfunction

  // Get destination register for compressed instructions.
  function bit [4:0] get_compressed_rd();
    bit [2:0] funct3;
    bit [1:0] quadrant;

    funct3   = insn[15:13];
    quadrant = insn[1:0];

    case (quadrant)
      2'b00: begin
        // C.ADDI4SPN, C.LW use rd'.
        if (funct3 == 3'b000 || funct3 == 3'b010) return {2'b01, insn[4:2]};
      end
      2'b01: begin
        case (funct3)
          3'b000, 3'b010, 3'b011: return insn[11:7];       // C.ADDI/LI/LUI
          3'b001:                 return 5'd1;             // C.JAL (RV32)
          3'b100: begin
            if (insn[11:10] == 2'b11) return {2'b01, insn[9:7]};
            return {2'b01, insn[9:7]};                      // shifts/ANDI
          end
          default: return 5'd0;
        endcase
      end
      2'b10: begin
        case (funct3)
          3'b000, 3'b010: return insn[11:7];                // C.SLLI/LWSP
          3'b100: begin
            if (insn[12] && insn[6:2] == 5'b0) return 5'd1; // C.JALR
            if (insn[6:2] != 5'b0) return insn[11:7];       // C.MV/C.ADD
          end
          default: return 5'd0;
        endcase
      end
      default: return 5'd0;
    endcase

    return 5'd0;
  endfunction

  // Get source register 1
  function bit [4:0] get_rs1();
    return insn[19:15];
  endfunction

  // Get source register 2
  function bit [4:0] get_rs2();
    return insn[24:20];
  endfunction

  // Check if instruction is a branch
  function bit is_branch();
    return (get_opcode() == 7'b1100011);
  endfunction

  // Check if instruction is a load
  function bit is_load();
    return (get_opcode() == 7'b0000011);
  endfunction

  // Check if instruction is a store
  function bit is_store();
    return (get_opcode() == 7'b0100011);
  endfunction

  // Check if instruction is an atomic memory operation
  function bit is_amo();
    return (get_opcode() == 7'b0101111);
  endfunction

  // Check if instruction is a DIV/REM operation. MUL operations use the same
  // opcode/funct7 but write through the normal pipeline, not the DIV monitor.
  function bit is_div();
    if (is_compressed()) return 1'b0;
    return (get_opcode() == 7'b0110011 &&
            insn[31:25] == 7'b0000001 &&
            insn[14:12] inside {3'b100, 3'b101, 3'b110, 3'b111});
  endfunction

  // Check if instruction is compressed
  function bit is_compressed();
    return (insn[1:0] != 2'b11);
  endfunction

  // Check if compressed instruction performs a load/store.
  // RV32C memory opcodes: C.LW/C.SW in quadrant 0, C.LWSP/C.SWSP in quadrant 2.
  function bit is_compressed_load_store();
    bit [2:0] funct3;
    bit [1:0] quadrant;

    if (!is_compressed()) return 1'b0;

    funct3   = insn[15:13];
    quadrant = insn[1:0];

    return ((quadrant == 2'b00 && (funct3 == 3'b010 || funct3 == 3'b110)) ||
            (quadrant == 2'b10 && (funct3 == 3'b010 || funct3 == 3'b110)));
  endfunction

  // Check if instruction is a jump
  function bit is_jump();
    return (get_opcode() == 7'b1101111) ||  // JAL
           (get_opcode() == 7'b1100111);    // JALR
  endfunction

  // Get architectural destination register for instructions that write GPRs.
  function bit [4:0] get_write_rd();
    if (is_compressed()) return get_compressed_rd();
    return get_rd();
  endfunction

  // Check if instruction writes to register
  function bit writes_rd();
    if (is_compressed()) begin
      return get_compressed_rd() != 5'b0;
    end

    if (get_rd() == 5'b0) return 1'b0;

    if (get_opcode() inside {7'b0110011, 7'b0010011, 7'b0110111,
                             7'b0010111, 7'b1101111, 7'b1100111,
                             7'b0000011, 7'b0101111}) begin
      return 1'b1;
    end

    // CSR instructions write rd when funct3 is nonzero.
    return (get_opcode() == 7'b1110011 && insn[14:12] != 3'b000);
  endfunction

endclass
