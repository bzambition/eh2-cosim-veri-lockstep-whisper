// SPDX-License-Identifier: Apache-2.0
// EH2 DUT Probe Interface — internal DUT signal probing for verification
//
// Phase 1 (ADR-0004) note: regular pipeline writebacks are now carried by the
// RTL trace packet (rd_valid/rd_addr/rd_wdata fields), so this interface no
// longer needs to expose i0/i1 wb_valid/wb_dest/wb_data. What remains:
//   - DIV unit async writebacks + cancel-overwrite annotation
//   - NB-load async writeback completion
//   - Interrupt/NMI/debug state for cosim notification
//   - CSR mirror state and exception flags (used by directed tests + fcov)
//
// Connect to DUT internal signals via hierarchical references in tb_top.

interface eh2_dut_probe_if #(
  parameter int NUM_THREADS = 1
) (
  input logic clk,
  input logic rst_n
);

  // Division unit signals
  logic [NUM_THREADS-1:0]       div_cancel;             // Division canceled (any kind)
  logic [NUM_THREADS-1:0]       div_cancel_overwrite;   // Cancel due to younger same-rd write (paired with retired div trace)
  logic [NUM_THREADS-1:0][4:0]  div_rd;                 // Division destination register
  logic [NUM_THREADS-1:0][31:0] div_result;             // Division raw result (pre-qualify)
  logic [NUM_THREADS-1:0]       div_wren;               // Division writeback valid (exu_div_wren)
  logic [NUM_THREADS-1:0][31:0] div_wdata;              // Division writeback data (exu_div_result)

  // Non-block load signals
  logic [NUM_THREADS-1:0]       nb_load_wen;
  logic [NUM_THREADS-1:0][4:0]  nb_load_waddr;
  logic [NUM_THREADS-1:0][31:0] nb_load_data;

  // Interrupt/NMI/debug state (sampled each cycle for cosim notification)
  logic [NUM_THREADS-1:0][31:0] mip;           // Machine interrupt pending
  logic [NUM_THREADS-1:0]       nmi;           // NMI mode
  logic [NUM_THREADS-1:0]       nmi_int;       // NMI interrupt pending
  logic [NUM_THREADS-1:0]       debug_req;     // Debug request active
  logic [NUM_THREADS-1:0][63:0] mcycle;        // Cycle counter

  // CSR mirror state (for directed tests and coverage)
  logic [NUM_THREADS-1:0][31:0] mstatus;
  logic [NUM_THREADS-1:0][31:0] mtvec;
  logic [NUM_THREADS-1:0][31:0] mepc;
  logic [NUM_THREADS-1:0][31:0] mcause;
  logic [NUM_THREADS-1:0][31:0] mtval;

  // Exception/trap signals at E4 stage (for directed tests and coverage)
  logic [NUM_THREADS-1:0]       mret_e4;
  logic [NUM_THREADS-1:0]       illegal_e4;
  logic [NUM_THREADS-1:0]       ecall_e4;
  logic [NUM_THREADS-1:0]       ebreak_e4;
  logic [NUM_THREADS-1:0]       ebreak_to_debug_e4;
  logic [NUM_THREADS-1:0]       inst_acc_e4;

  // Exception/trap signals at writeback stage
  logic [NUM_THREADS-1:0]       mret_wb;
  logic [NUM_THREADS-1:0]       illegal_wb;
  logic [NUM_THREADS-1:0]       ecall_wb;
  logic [NUM_THREADS-1:0]       ebreak_wb;

  // Debug state
  logic [NUM_THREADS-1:0]       debug_mode;
  logic [NUM_THREADS-1:0]       dbg_halted;

  // Interrupt tracking
  logic [NUM_THREADS-1:0]       interrupt_valid;
  logic [NUM_THREADS-1:0]       take_ext_int;
  logic [NUM_THREADS-1:0]       take_timer_int;
  logic [NUM_THREADS-1:0]       take_soft_int;
  logic [NUM_THREADS-1:0]       take_nmi;

  // Global writeback sequence counter (issue 66: strict wb_seq ordering)
  // Incremented by probe_monitor for each non-suppressed wb event.
  // Read by trace_monitor to tag trace items for async_wb matching.
  logic [15:0]      wb_seq;

  // Monitor clocking block
  clocking monitor_cb @(posedge clk);
    input div_cancel;
    input div_cancel_overwrite;
    input div_rd;
    input div_result;
    input div_wren;
    input div_wdata;
    input nb_load_wen;
    input nb_load_waddr;
    input nb_load_data;
    input mip;
    input nmi;
    input nmi_int;
    input debug_req;
    input mcycle;
    input mstatus;
    input mtvec;
    input mepc;
    input mcause;
    input mtval;
    input mret_e4;
    input illegal_e4;
    input ecall_e4;
    input ebreak_e4;
    input ebreak_to_debug_e4;
    input inst_acc_e4;
    input mret_wb;
    input illegal_wb;
    input ecall_wb;
    input ebreak_wb;
    input debug_mode;
    input dbg_halted;
    input interrupt_valid;
    input take_ext_int;
    input take_timer_int;
    input take_soft_int;
    input take_nmi;
    output wb_seq;
  endclocking

endinterface
