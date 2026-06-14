// ============================================================================
// eh2_veer_wrapper_rvfi.sv — EH2 Trace-to-RVFI Converter Layer
//
// ADR-0015: Converts EH2-native trace signals to standard RVFI format.
// This module is instantiated as a SIDECAR in tb_top (not as a DUT wrapper).
// The existing eh2_veer_wrapper remains the DUT; this converter taps its
// trace output ports (which are already live and driven) and produces the
// RVFI-equivalent interface for lockstep comparison and formal verification.
//
// Dual-channel: i0 (first retire) and i1 (second retire) for dual-issue.
// RVFI reference: https://github.com/SymbioticEDA/riscv-formal/blob/main/docs/rvfi.md
//
// RC4 status (2026-05-08): ALL internal trace signals are now driven by real
// assign statements connected to live DUT trace ports. Previously this file
// was a hollow shell with 0 driven internal signals and 0 instantiations.
// ============================================================================

module eh2_veer_wrapper_rvfi (
    input  logic        clk,
    input  logic        rst_n,

    // Trace inputs (from DUT trace ports, live in tb_top)
    input  logic [63:0] trace_insn,
    input  logic [63:0] trace_address,
    input  logic [1:0]  trace_valid,
    input  logic [1:0]  trace_exception,
    input  logic [4:0]  trace_ecause,
    input  logic [1:0]  trace_interrupt,
    input  logic [31:0] trace_tval,
    input  logic [1:0]  trace_rd_valid,
    input  logic [9:0]  trace_rd_addr,
    input  logic [63:0] trace_rd_wdata,

    // LSU bus inputs (from AXI4 bus signals in tb_top)
    input  logic        lsu_bus_valid,
    input  logic [31:0] lsu_bus_addr,
    input  logic [31:0] lsu_bus_rdata,
    input  logic [31:0] lsu_bus_wdata,
    input  logic [3:0]  lsu_bus_wmask,
    input  logic        lsu_bus_write,

    // RVFI output (standard RVFI format, dual-channel i0/i1)
    output logic [1:0]   rvfi_valid,
    output logic [127:0] rvfi_order,
    output logic [63:0]  rvfi_insn,
    output logic [63:0]  rvfi_pc_rdata,
    output logic [63:0]  rvfi_pc_wdata,
    output logic [63:0]  rvfi_rs1_addr,
    output logic [63:0]  rvfi_rs2_addr,
    output logic [63:0]  rvfi_rd_addr,
    output logic [63:0]  rvfi_rd_wdata,
    output logic [63:0]  rvfi_mem_addr,
    output logic [63:0]  rvfi_mem_rdata,
    output logic [63:0]  rvfi_mem_wdata,
    output logic [63:0]  rvfi_mem_rmask,
    output logic [63:0]  rvfi_mem_wmask,
    output logic [1:0]   rvfi_trap,
    output logic [1:0]   rvfi_intr,
    output logic [3:0]   rvfi_mode
);

    // ========================================================================
    // Internal trace signals — ALL DRIVEN (16 total trace assign statements)
    // ========================================================================
    logic        trace_i0_valid;
    logic        trace_i1_valid;
    logic [31:0] trace_i0_pc;
    logic [31:0] trace_i1_pc;
    logic [31:0] trace_i0_insn;
    logic [31:0] trace_i1_insn;
    logic        trace_i0_exception;
    logic        trace_i1_exception;
    logic        trace_i0_interrupt;
    logic        trace_i1_interrupt;
    logic [3:0]  trace_i0_exc_cause;
    logic [3:0]  trace_i1_exc_cause;
    logic [4:0]  trace_i0_rd_addr;
    logic [4:0]  trace_i1_rd_addr;
    logic [31:0] trace_i0_rd_wdata;
    logic [31:0] trace_i1_rd_wdata;

    // Writeback probe signals
    logic [63:0] wb_seq;
    logic        wb_i0_valid;
    logic        wb_i1_valid;
    logic [31:0] wb_i0_pc;
    logic [31:0] wb_i1_pc;
    logic [31:0] wb_i0_result;
    logic [31:0] wb_i1_result;

    // LSU probe signals
    logic        lsu_bus_valid_int;
    logic [31:0] lsu_bus_addr_int;
    logic [31:0] lsu_bus_rdata_int;
    logic [31:0] lsu_bus_wdata_int;
    logic [3:0]  lsu_bus_wmask_int;
    logic        lsu_bus_write_int;

    // ========================================================================
    // Drive trace_i0_* / trace_i1_* from DUT trace ports
    //   trace_address[31:0]  = channel 0 PC
    //   trace_address[63:32] = channel 1 PC
    //   trace_valid[0]       = channel 0 valid
    //   trace_valid[1]       = channel 1 valid
    //   (same pattern for insn, exception, interrupt, rd_*)
    // ========================================================================
    assign trace_i0_valid      = trace_valid[0];
    assign trace_i1_valid      = trace_valid[1];
    assign trace_i0_pc         = trace_address[31:0];
    assign trace_i1_pc         = trace_address[63:32];
    assign trace_i0_insn       = trace_insn[31:0];
    assign trace_i1_insn       = trace_insn[63:32];
    assign trace_i0_exception  = trace_exception[0];
    assign trace_i1_exception  = trace_exception[1];
    assign trace_i0_interrupt  = trace_interrupt[0];
    assign trace_i1_interrupt  = trace_interrupt[1];
    assign trace_i0_exc_cause  = trace_ecause[3:0];
    assign trace_i1_exc_cause  = trace_ecause[3:0];
    assign trace_i0_rd_addr    = trace_rd_addr[4:0];
    assign trace_i1_rd_addr    = trace_rd_addr[9:5];
    assign trace_i0_rd_wdata   = trace_rd_wdata[31:0];
    assign trace_i1_rd_wdata   = trace_rd_wdata[63:32];

    // ========================================================================
    // Drive LSU bus probe from bus inputs
    // ========================================================================
    assign lsu_bus_valid_int = lsu_bus_valid;
    assign lsu_bus_addr_int  = lsu_bus_addr;
    assign lsu_bus_rdata_int = lsu_bus_rdata;
    assign lsu_bus_wdata_int = lsu_bus_wdata;
    assign lsu_bus_wmask_int = lsu_bus_write ? lsu_bus_wmask : 4'b0;
    assign lsu_bus_write_int = lsu_bus_write;

    // ========================================================================
    // Writeback sequence counter (increments on each retire)
    // ========================================================================
    assign wb_i0_valid  = trace_i0_valid;
    assign wb_i1_valid  = trace_i1_valid;
    assign wb_i0_pc     = trace_i0_pc;
    assign wb_i1_pc     = trace_i1_pc;
    assign wb_i0_result = trace_i0_rd_wdata;
    assign wb_i1_result = trace_i1_rd_wdata;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            wb_seq <= 64'b0;
        else if (trace_i0_valid || trace_i1_valid)
            wb_seq <= wb_seq + 64'd1;
    end

    // ========================================================================
    // RVFI generation: trace packets -> standard RVFI fields
    // ========================================================================

    // Channel 0 (i0)
    assign rvfi_valid[0]       = trace_i0_valid && !trace_i0_exception;
    assign rvfi_order[63:0]    = {32'b0, wb_seq[31:0]};
    assign rvfi_insn[31:0]     = trace_i0_insn;
    assign rvfi_pc_rdata[31:0] = trace_i0_pc;
    assign rvfi_pc_wdata[31:0] = trace_i0_pc + (trace_i0_insn[1:0] != 2'b11 ? 32'd2 : 32'd4);
    assign rvfi_rs1_addr[31:0] = {27'b0, trace_i0_insn[19:15]};
    assign rvfi_rs2_addr[31:0] = {27'b0, trace_i0_insn[24:20]};
    assign rvfi_rd_addr[31:0]  = {27'b0, trace_i0_rd_addr};
    assign rvfi_rd_wdata[31:0] = trace_i0_rd_wdata;
    assign rvfi_trap[0]        = trace_i0_exception;
    assign rvfi_intr[0]        = trace_i0_interrupt;

    // Channel 1 (i1)
    assign rvfi_valid[1]        = trace_i1_valid && !trace_i1_exception;
    assign rvfi_order[127:64]   = {32'b0, wb_seq[31:0] + 32'd1};
    assign rvfi_insn[63:32]     = trace_i1_insn;
    assign rvfi_pc_rdata[63:32] = trace_i1_pc;
    assign rvfi_pc_wdata[63:32] = trace_i1_pc + (trace_i1_insn[1:0] != 2'b11 ? 32'd2 : 32'd4);
    assign rvfi_rs1_addr[63:32] = {27'b0, trace_i1_insn[19:15]};
    assign rvfi_rs2_addr[63:32] = {27'b0, trace_i1_insn[24:20]};
    assign rvfi_rd_addr[63:32]  = {27'b0, trace_i1_rd_addr};
    assign rvfi_rd_wdata[63:32] = trace_i1_rd_wdata;
    assign rvfi_trap[1]         = trace_i1_exception;
    assign rvfi_intr[1]         = trace_i1_interrupt;

    // Memory interface (from LSU probe)
    assign rvfi_mem_addr[31:0]  = lsu_bus_valid_int ? lsu_bus_addr_int : 32'b0;
    assign rvfi_mem_rdata[31:0] = lsu_bus_rdata_int;
    assign rvfi_mem_wdata[31:0] = lsu_bus_wdata_int;
    assign rvfi_mem_wmask[3:0]  = lsu_bus_write_int ? lsu_bus_wmask_int : 4'b0;
    assign rvfi_mem_rmask[3:0]  = lsu_bus_write_int ? 4'b0 : 4'b1111;

    // Upper 32 bits of memory fields tied to 0 (32-bit address space)
    assign rvfi_mem_addr[63:32]  = 32'b0;
    assign rvfi_mem_rdata[63:32] = 32'b0;
    assign rvfi_mem_wdata[63:32] = 32'b0;
    assign rvfi_mem_rmask[7:4]   = 4'b0;
    assign rvfi_mem_wmask[7:4]   = 4'b0;

    // Mode: EH2 only supports M-mode
    assign rvfi_mode = 4'b0011;

endmodule
