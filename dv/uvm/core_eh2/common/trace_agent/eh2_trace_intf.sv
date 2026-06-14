// SPDX-License-Identifier: Apache-2.0
// EH2 Trace Interface - Connects to DUT trace ports
//
// EH2 provides a simplified trace interface (NOT standard RVFI):
//   - trace_rv_i_insn_ip:      [NUM_THREADS-1:0][63:0] - Instructions (2 per thread)
//   - trace_rv_i_address_ip:   [NUM_THREADS-1:0][63:0] - PC addresses (2 per thread)
//   - trace_rv_i_valid_ip:     [NUM_THREADS-1:0][1:0]  - Valid flags (2 per thread)
//   - trace_rv_i_exception_ip: [NUM_THREADS-1:0][1:0]  - Exception flags
//   - trace_rv_i_ecause_ip:    [NUM_THREADS-1:0][4:0]  - Exception cause
//   - trace_rv_i_interrupt_ip: [NUM_THREADS-1:0][1:0]  - Interrupt flags
//   - trace_rv_i_tval_ip:      [NUM_THREADS-1:0][31:0] - Trap value
//
// Limitations vs RVFI:
//   - No rd_addr/rd_wdata (register writeback not directly visible)
//   - No mem_addr/mem_wdata/mem_rdata (memory access not directly visible)
//   - No CSR updates
//   - Only 2 instructions per cycle per thread

interface eh2_trace_intf #(
  parameter NUM_THREADS = 1
)(
  input logic clk,
  input logic rst_n
);

  // Trace signals
  logic [NUM_THREADS-1:0][63:0] insn;
  logic [NUM_THREADS-1:0][63:0] address;
  logic [NUM_THREADS-1:0][1:0]  valid;
  logic [NUM_THREADS-1:0][1:0]  exception;
  logic [NUM_THREADS-1:0][4:0]  ecause;
  logic [NUM_THREADS-1:0][1:0]  interrupt;
  logic [NUM_THREADS-1:0][31:0] tval;
  // Verification-only RVFI-equivalent writeback view (lane 0 = i0, lane 1 = i1).
  logic [NUM_THREADS-1:0][1:0]  rd_valid;
  logic [NUM_THREADS-1:0][9:0]  rd_addr;
  logic [NUM_THREADS-1:0][63:0] rd_wdata;

  // Decoded per-instruction signals (convenience)
  // For thread 0, instruction 0 (i0)
  logic [31:0] t0_i0_pc;
  logic [31:0] t0_i0_insn;
  logic        t0_i0_valid;
  logic        t0_i0_exception;
  logic [4:0]  t0_i0_ecause;
  logic        t0_i0_wb_valid;
  logic [4:0]  t0_i0_wb_addr;
  logic [31:0] t0_i0_wb_data;

  // For thread 0, instruction 1 (i1)
  logic [31:0] t0_i1_pc;
  logic [31:0] t0_i1_insn;
  logic        t0_i1_valid;
  logic        t0_i1_exception;
  logic [4:0]  t0_i1_ecause;
  logic        t0_i1_wb_valid;
  logic [4:0]  t0_i1_wb_addr;
  logic [31:0] t0_i1_wb_data;

  // Decode convenience signals
  assign t0_i0_pc        = address[0][31:0];
  assign t0_i0_insn      = insn[0][31:0];
  assign t0_i0_valid     = valid[0][0];
  assign t0_i0_exception = exception[0][0];
  assign t0_i0_ecause    = ecause[0][4:0];
  assign t0_i0_wb_valid  = rd_valid[0][0];
  assign t0_i0_wb_addr   = rd_addr[0][4:0];
  assign t0_i0_wb_data   = rd_wdata[0][31:0];

  assign t0_i1_pc        = address[0][63:32];
  assign t0_i1_insn      = insn[0][63:32];
  assign t0_i1_valid     = valid[0][1];
  assign t0_i1_exception = exception[0][1];
  assign t0_i1_ecause    = ecause[0][4:0];
  assign t0_i1_wb_valid  = rd_valid[0][1];
  assign t0_i1_wb_addr   = rd_addr[0][9:5];
  assign t0_i1_wb_data   = rd_wdata[0][63:32];

  // Monitor clocking block
  clocking monitor_cb @(posedge clk);
    input insn;
    input address;
    input valid;
    input exception;
    input ecause;
    input interrupt;
    input tval;
    input rd_valid;
    input rd_addr;
    input rd_wdata;
  endclocking

endinterface
