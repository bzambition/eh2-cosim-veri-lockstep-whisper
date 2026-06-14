// ============================================================================
// eh2_rvfi_if.sv — RVFI monitor interface for UVM scoreboard
//
// Captures RVFI retire packets from eh2_veer_wrapper_rvfi for cosim
// self-consistency checks. Dual-channel (i0 / i1) for EH2 dual-issue.
// ============================================================================

interface eh2_rvfi_if (
  input logic clk,
  input logic rst_l
);
  logic [1:0]   rvfi_valid;
  logic [127:0] rvfi_order;
  logic [63:0]  rvfi_insn;
  logic [63:0]  rvfi_pc_rdata;
  logic [63:0]  rvfi_pc_wdata;
  logic [63:0]  rvfi_rs1_addr;
  logic [63:0]  rvfi_rs2_addr;
  logic [63:0]  rvfi_rd_addr;
  logic [63:0]  rvfi_rd_wdata;
  logic [63:0]  rvfi_mem_addr;
  logic [63:0]  rvfi_mem_rdata;
  logic [63:0]  rvfi_mem_wdata;
  logic [63:0]  rvfi_mem_rmask;
  logic [63:0]  rvfi_mem_wmask;
  logic [1:0]   rvfi_trap;
  logic [1:0]   rvfi_intr;
  logic [3:0]   rvfi_mode;

  // Clocking block for synchronous sampling
  clocking cb @(posedge clk);
    input rvfi_valid;
    input rvfi_order;
    input rvfi_insn;
    input rvfi_pc_rdata;
    input rvfi_pc_wdata;
    input rvfi_rs1_addr;
    input rvfi_rs2_addr;
    input rvfi_rd_addr;
    input rvfi_rd_wdata;
    input rvfi_mem_addr;
    input rvfi_mem_rdata;
    input rvfi_mem_wdata;
    input rvfi_mem_rmask;
    input rvfi_mem_wmask;
    input rvfi_trap;
    input rvfi_intr;
    input rvfi_mode;
  endclocking

  // Modport for monitor
  modport monitor (
    input clk, rst_l,
    input rvfi_valid, rvfi_order, rvfi_insn,
    input rvfi_pc_rdata, rvfi_pc_wdata,
    input rvfi_rs1_addr, rvfi_rs2_addr,
    input rvfi_rd_addr, rvfi_rd_wdata,
    input rvfi_mem_addr, rvfi_mem_rdata, rvfi_mem_wdata,
    input rvfi_mem_rmask, rvfi_mem_wmask,
    input rvfi_trap, rvfi_intr, rvfi_mode
  );
endinterface
