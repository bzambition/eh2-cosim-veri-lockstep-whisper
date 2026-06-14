// SPDX-License-Identifier: Apache-2.0
// Minimal RVVI-API online lockstep scoreboard for MR3a smoke.

import rvviApiPkg::*;

module eh2_rvvi_scoreboard #(
  parameter int NHART  = 1,
  parameter int RETIRE = 2,
  parameter int XLEN   = 32,
  parameter int ILEN   = 32
) (
  input logic clk,
  input logic rst_l,
  input logic test_done,

  input logic [NHART-1:0]       nb_load_wen,
  input logic [NHART-1:0][4:0]  nb_load_waddr,
  input logic [NHART-1:0][31:0] nb_load_data,

  input logic [NHART-1:0]       div_wren,
  input logic [NHART-1:0][4:0]  div_rd,
  input logic [NHART-1:0][31:0] div_wdata,
  input logic [NHART-1:0]       div_cancel,
  input logic [NHART-1:0]       div_cancel_overwrite,
  input logic [NHART-1:0][31:0] div_result,

  input logic [NHART-1:0][31:0] mip,
  input logic [NHART-1:0]       nmi,
  input logic [NHART-1:0]       debug_req,

  input logic        lsu_bus_write,
  input logic [31:0] lsu_bus_addr,
  input logic [31:0] lsu_bus_wdata,
  input logic [3:0]  lsu_bus_wmask,

  rvviTrace rvvi
);

  import "DPI-C" context function void rvviRefEventComplete(input int hartId);

  localparam int CSR_MSTATUS = 12'h300;
  localparam int CSR_MTVEC   = 12'h305;
  localparam int CSR_MEPC    = 12'h341;
  localparam int CSR_MCAUSE  = 12'h342;
  localparam int CSR_MTVAL   = 12'h343;
  localparam int CSR_MIP     = 12'h344;

  localparam int WB_SRC_DIV     = 1;
  localparam int WB_SRC_NB_LOAD = 2;
  localparam longint kRvviConfigNumHarts = 1;

  typedef struct {
    int                 hart;
    int                 slot;
    logic [XLEN-1:0]    pc;
    logic [ILEN-1:0]    insn;
    logic               trap;
    logic               intr;
    logic               debug_mode;
    logic [31:0]        x_wb;
    logic [31:0][XLEN-1:0] x_wdata;
    logic [XLEN-1:0]    csr_mstatus;
    logic [XLEN-1:0]    csr_mtvec;
    logic [XLEN-1:0]    csr_mepc;
    logic [XLEN-1:0]    csr_mcause;
    logic [XLEN-1:0]    csr_mtval;
    logic [XLEN-1:0]    csr_mip;
    logic               csr_mstatus_wb;
    logic               csr_mtvec_wb;
    logic               csr_mepc_wb;
    logic               csr_mcause_wb;
    logic               csr_mtval_wb;
    logic               csr_mip_wb;
  } retire_event_t;

  typedef struct {
    int              source;
    logic [4:0]      rd;
    logic [31:0]     data;
    logic            suppress;
  } async_wb_hint_t;

  bit enabled;
  bit initialized;
  bit saw_error;
  string elf_path;
  longint unsigned dut_retires;
  int configured_nhart;
  longint mip_net_idx;
  longint nmi_net_idx;
  longint debug_req_net_idx;
  retire_event_t pending_retire_q[NHART][$];
  async_wb_hint_t async_wb_q[NHART][$];

  function automatic bit api_ok(input byte result, input string what);
    if (result == RVVI_FALSE) begin
      $error("RVVI_SCOREBOARD: %s failed: %s", what, rvviErrorGet());
      saw_error = 1'b1;
      return 1'b0;
    end
    return 1'b1;
  endfunction

  function automatic bit compare_retire(input retire_event_t retire_evt);
    bit ok;

    ok = 1'b1;
    ok &= api_ok(rvviRefPcCompare(retire_evt.hart), "rvviRefPcCompare");
    ok &= api_ok(rvviRefInsBinCompare(retire_evt.hart), "rvviRefInsBinCompare");
    ok &= api_ok(rvviRefGprsCompareWritten(retire_evt.hart, RVVI_TRUE),
                 "rvviRefGprsCompareWritten");
    ok &= api_ok(rvviRefCsrsCompare(retire_evt.hart), "rvviRefCsrsCompare");

    if (!ok) begin
      $error("RVVI_SCOREBOARD: mismatch h%0d r%0d pc=%08h insn=%08h: %s",
             retire_evt.hart, retire_evt.slot, retire_evt.pc, retire_evt.insn, rvviErrorGet());
      saw_error = 1'b1;
      return 1'b0;
    end

    return 1'b1;
  endfunction

  function automatic bit is_compressed(input logic [31:0] insn);
    return insn[1:0] != 2'b11;
  endfunction

  function automatic bit [4:0] compressed_rd(input logic [31:0] insn);
    logic [2:0] funct3;
    logic [1:0] quadrant;

    funct3 = insn[15:13];
    quadrant = insn[1:0];

    case (quadrant)
      2'b00: begin
        if (funct3 == 3'b000 || funct3 == 3'b010) return {2'b01, insn[4:2]};
      end
      2'b01: begin
        case (funct3)
          3'b000, 3'b010, 3'b011: return insn[11:7];
          3'b001:                 return 5'd1;
          3'b100:                 return {2'b01, insn[9:7]};
          default:                return 5'd0;
        endcase
      end
      2'b10: begin
        case (funct3)
          3'b000, 3'b010: return insn[11:7];
          3'b100: begin
            if (insn[12] && insn[6:2] == 5'b0) return 5'd1;
            if (insn[6:2] != 5'b0) return insn[11:7];
          end
          default: return 5'd0;
        endcase
      end
      default: return 5'd0;
    endcase

    return 5'd0;
  endfunction

  function automatic bit [4:0] write_rd(input logic [31:0] insn);
    if (is_compressed(insn)) return compressed_rd(insn);
    return insn[11:7];
  endfunction

  function automatic bit is_compressed_load(input logic [31:0] insn);
    logic [2:0] funct3;
    logic [1:0] quadrant;

    if (!is_compressed(insn)) return 1'b0;
    funct3 = insn[15:13];
    quadrant = insn[1:0];

    return ((quadrant == 2'b00 && funct3 == 3'b010) ||
            (quadrant == 2'b10 && funct3 == 3'b010));
  endfunction

  function automatic bit is_lr(input logic [31:0] insn);
    return (insn[6:0] == 7'b0101111 && insn[31:27] == 5'b00010);
  endfunction

  function automatic bit is_load(input logic [31:0] insn);
    if (is_compressed_load(insn)) return 1'b1;
    return (insn[6:0] == 7'b0000011) || is_lr(insn);
  endfunction

  function automatic bit is_div(input logic [31:0] insn);
    if (is_compressed(insn)) return 1'b0;
    return (insn[6:0] == 7'b0110011 &&
            insn[31:25] == 7'b0000001 &&
            insn[14:12] inside {3'b100, 3'b101, 3'b110, 3'b111});
  endfunction

  function automatic bit needs_async_wb(input retire_event_t retire_evt);
    if (retire_evt.trap || retire_evt.intr) return 1'b0;
    if (write_rd(retire_evt.insn) == 5'd0) return 1'b0;
    return is_load(retire_evt.insn) || is_div(retire_evt.insn);
  endfunction

  function automatic int async_source_for(input retire_event_t retire_evt);
    if (is_div(retire_evt.insn)) return WB_SRC_DIV;
    if (is_load(retire_evt.insn)) return WB_SRC_NB_LOAD;
    return 0;
  endfunction

  function automatic bit try_consume_async_wb(input retire_event_t retire_evt,
                                              output async_wb_hint_t hint);
    int need_source;

    need_source = async_source_for(retire_evt);
    if (need_source == 0) return 1'b0;

    foreach (async_wb_q[retire_evt.hart][i]) begin
      if (async_wb_q[retire_evt.hart][i].source != need_source) continue;
      if (async_wb_q[retire_evt.hart][i].rd != write_rd(retire_evt.insn)) continue;
      hint = async_wb_q[retire_evt.hart][i];
      async_wb_q[retire_evt.hart].delete(i);
      return 1'b1;
    end

    return 1'b0;
  endfunction

  task automatic stage_csrs(input retire_event_t retire_evt);
    if (retire_evt.csr_mstatus_wb) rvviDutCsrSet(retire_evt.hart, CSR_MSTATUS, longint'(retire_evt.csr_mstatus));
    if (retire_evt.csr_mtvec_wb)   rvviDutCsrSet(retire_evt.hart, CSR_MTVEC,   longint'(retire_evt.csr_mtvec));
    if (retire_evt.csr_mepc_wb)    rvviDutCsrSet(retire_evt.hart, CSR_MEPC,    longint'(retire_evt.csr_mepc));
    if (retire_evt.csr_mcause_wb)  rvviDutCsrSet(retire_evt.hart, CSR_MCAUSE,  longint'(retire_evt.csr_mcause));
    if (retire_evt.csr_mtval_wb)   rvviDutCsrSet(retire_evt.hart, CSR_MTVAL,   longint'(retire_evt.csr_mtval));
    if (retire_evt.csr_mip_wb)     rvviDutCsrSet(retire_evt.hart, CSR_MIP,     longint'(retire_evt.csr_mip));
  endtask

  task automatic stage_dut(input retire_event_t retire_evt,
                           input bit has_async,
                           input async_wb_hint_t async_hint);
    if (has_async) begin
      if (!async_hint.suppress) begin
        rvviDutGprSet(retire_evt.hart, async_hint.rd, longint'(async_hint.data));
      end
    end else begin
    for (int i = 0; i < 32; i++) begin
        if (retire_evt.x_wb[i]) begin
          rvviDutGprSet(retire_evt.hart, i, longint'(retire_evt.x_wdata[i]));
        end
      end
    end

    stage_csrs(retire_evt);

    if (retire_evt.trap) begin
      rvviDutTrap(retire_evt.hart, longint'(retire_evt.pc),
                  longint'(retire_evt.insn));
    end else begin
      rvviDutRetire(retire_evt.hart, longint'(retire_evt.pc),
                    longint'(retire_evt.insn),
                    retire_evt.debug_mode ? RVVI_TRUE : RVVI_FALSE);
    end
  endtask

  task automatic inject_async_nets(input int hart);
    if (debug_req_net_idx != RVVI_INVALID_INDEX) begin
      rvviRefNetSet(debug_req_net_idx, longint'(debug_req[hart]), {longint'(hart), 32'd0});
    end
    if (nmi_net_idx != RVVI_INVALID_INDEX) begin
      rvviRefNetSet(nmi_net_idx, longint'(nmi[hart]), {longint'(hart), 32'd0});
    end
    if (mip_net_idx != RVVI_INVALID_INDEX) begin
      rvviRefNetSet(mip_net_idx, longint'(mip[hart]), {longint'(hart), 32'd0});
    end
  endtask

  task automatic stage_bus_writes();
    if (lsu_bus_write && lsu_bus_wmask != 4'b0) begin
      // CHECK: EH2 LSU AXI sideband does not expose a sampled TID here yet.
      // Mirror the shared-memory write against harts retiring in this cycle.
      for (int h = 0; h < NHART; h++) begin
        if (rvvi.valid[h][0] || rvvi.valid[h][1]) begin
          rvviDutBusWrite(h, longint'(lsu_bus_addr), longint'(lsu_bus_wdata),
                          longint'({60'b0, lsu_bus_wmask}));
        end
      end
    end
  endtask

  task automatic process_retire(input retire_event_t retire_evt,
                                input bit has_async,
                                input async_wb_hint_t async_hint);
    if (retire_evt.intr) begin
      process_async_interrupt(retire_evt);
      return;
    end

    stage_dut(retire_evt, has_async, async_hint);
    inject_async_nets(retire_evt.hart);
    if (!api_ok(rvviRefEventStep(retire_evt.hart), "rvviRefEventStep")) begin
      return;
    end

    void'(compare_retire(retire_evt));
    rvviRefEventComplete(retire_evt.hart);
    dut_retires++;
  endtask

  task automatic process_async_interrupt(input retire_event_t retire_evt);
    bit ok;

    stage_csrs(retire_evt);
    inject_async_nets(retire_evt.hart);
    if (!api_ok(rvviRefEventStep(retire_evt.hart), "rvviRefEventStep(async)")) begin
      return;
    end

    ok = api_ok(rvviRefCsrsCompare(retire_evt.hart), "rvviRefCsrsCompare(async)");
    if (!ok) begin
      $error("RVVI_SCOREBOARD: async interrupt CSR mismatch h%0d pc=%08h: %s",
             retire_evt.hart, retire_evt.pc, rvviErrorGet());
      saw_error = 1'b1;
    end
    rvviRefEventComplete(retire_evt.hart);
  endtask

  task automatic enqueue_retire(input int h, input int r);
    retire_event_t retire_evt;

    retire_evt.hart        = h;
    retire_evt.slot        = r;
    retire_evt.pc          = rvvi.pc_rdata[h][r];
    retire_evt.insn        = rvvi.insn[h][r];
    retire_evt.trap        = rvvi.trap[h][r];
    retire_evt.intr        = rvvi.intr[h][r];
    retire_evt.debug_mode  = rvvi.debug_mode[h][r];
    retire_evt.x_wb        = rvvi.x_wb[h][r];
    retire_evt.x_wdata     = rvvi.x_wdata[h][r];
    retire_evt.csr_mstatus = rvvi.csr[h][r][CSR_MSTATUS];
    retire_evt.csr_mtvec   = rvvi.csr[h][r][CSR_MTVEC];
    retire_evt.csr_mepc    = rvvi.csr[h][r][CSR_MEPC];
    retire_evt.csr_mcause  = rvvi.csr[h][r][CSR_MCAUSE];
    retire_evt.csr_mtval   = rvvi.csr[h][r][CSR_MTVAL];
    retire_evt.csr_mip     = rvvi.csr[h][r][CSR_MIP];
    retire_evt.csr_mstatus_wb = rvvi.csr_wb[h][r][CSR_MSTATUS];
    retire_evt.csr_mtvec_wb   = rvvi.csr_wb[h][r][CSR_MTVEC];
    retire_evt.csr_mepc_wb    = rvvi.csr_wb[h][r][CSR_MEPC];
    retire_evt.csr_mcause_wb  = rvvi.csr_wb[h][r][CSR_MCAUSE];
    retire_evt.csr_mtval_wb   = rvvi.csr_wb[h][r][CSR_MTVAL];
    retire_evt.csr_mip_wb     = rvvi.csr_wb[h][r][CSR_MIP];

    pending_retire_q[h].push_back(retire_evt);
  endtask

  task automatic enqueue_async_writebacks();
    async_wb_hint_t hint;

    for (int h = 0; h < NHART; h++) begin
      if (nb_load_wen[h] && nb_load_waddr[h] != 5'd0) begin
        hint.source   = WB_SRC_NB_LOAD;
        hint.rd       = nb_load_waddr[h];
        hint.data     = nb_load_data[h];
        hint.suppress = 1'b0;
        async_wb_q[h].push_back(hint);
      end

      if (div_wren[h] && div_rd[h] != 5'd0) begin
        hint.source   = WB_SRC_DIV;
        hint.rd       = div_rd[h];
        hint.data     = div_wdata[h];
        hint.suppress = 1'b0;
        async_wb_q[h].push_back(hint);
      end else if (div_cancel[h] && div_cancel_overwrite[h] && div_rd[h] != 5'd0) begin
        hint.source   = WB_SRC_DIV;
        hint.rd       = div_rd[h];
        hint.data     = div_result[h];
        hint.suppress = 1'b1;
        async_wb_q[h].push_back(hint);
      end
    end
  endtask

  task automatic process_pending(input int h);
    retire_event_t retire_evt;
    async_wb_hint_t async_hint;
    bit has_async;

    while (pending_retire_q[h].size() > 0) begin
      retire_evt = pending_retire_q[h][0];
      has_async = 1'b0;

      if (needs_async_wb(retire_evt)) begin
        if (!try_consume_async_wb(retire_evt, async_hint)) begin
          break;
        end
        has_async = 1'b1;
      end

      pending_retire_q[h].pop_front();
      process_retire(retire_evt, has_async, async_hint);
    end
  endtask

  initial begin
    enabled = $test$plusargs("use_rvvi_cosim");
    initialized = 1'b0;
    saw_error = 1'b0;
    dut_retires = 0;
    configured_nhart = NHART;
    void'($value$plusargs("rvvi_nhart=%d", configured_nhart));
    elf_path = "";
    mip_net_idx = RVVI_INVALID_INDEX;
    nmi_net_idx = RVVI_INVALID_INDEX;
    debug_req_net_idx = RVVI_INVALID_INDEX;

    if (!enabled) begin
      $display("RVVI_SCOREBOARD: disabled");
    end else begin
      if (!$value$plusargs("rvvi_elf=%s", elf_path) || elf_path.len() == 0) begin
        $fatal(1, "RVVI_SCOREBOARD: +rvvi_elf=<program.elf> is required");
      end
      if (!api_ok(rvviVersionCheck(RVVI_API_VERSION), "rvviVersionCheck")) begin
        $fatal(1, "RVVI_SCOREBOARD: RVVI API version mismatch");
      end
      if (configured_nhart != NHART) begin
        $fatal(1, "RVVI_SCOREBOARD: +rvvi_nhart=%0d does not match compiled NHART=%0d",
               configured_nhart, NHART);
      end
      if (!api_ok(rvviRefConfigSetInt(kRvviConfigNumHarts, NHART), "rvviRefConfigSetInt(num_harts)")) begin
        $fatal(1, "RVVI_SCOREBOARD: cannot configure %0d RVVI hart(s): %s",
               NHART, rvviErrorGet());
      end
      if (!api_ok(rvviRefInit(elf_path), "rvviRefInit")) begin
        $fatal(1, "RVVI_SCOREBOARD: cannot initialize ref with %s", elf_path);
      end
      mip_net_idx = rvviRefNetIndexGet("MIP");
      nmi_net_idx = rvviRefNetIndexGet("NMI");
      debug_req_net_idx = rvviRefNetIndexGet("DEBUG_REQ");
      initialized = 1'b1;
      $display("RVVI_SCOREBOARD: online lockstep enabled with %s", elf_path);
    end
  end

  always @(posedge clk) begin
    if (enabled && initialized && rst_l) begin
      enqueue_async_writebacks();
      stage_bus_writes();

      for (int h = 0; h < NHART; h++) begin
        for (int r = 0; r < RETIRE; r++) begin
          if (rvvi.valid[h][r]) begin
            enqueue_retire(h, r);
          end
        end
        process_pending(h);
      end

      if (test_done) begin
        longint unsigned ref_retires;
        longint unsigned mismatches;
        longint unsigned errors;
        ref_retires = rvviRefMetricGet(RVVI_METRIC_RETIRES);
        mismatches  = rvviRefMetricGet(RVVI_METRIC_MISMATCHES);
        errors      = rvviRefMetricGet(RVVI_METRIC_ERRORS);

        if (mismatches != 0) begin
          $error("RVVI_SCOREBOARD: %0d mismatch(es), last: %s",
                 mismatches, rvviErrorGet());
          saw_error = 1'b1;
        end
        if (errors != 0) begin
          $error("RVVI_SCOREBOARD: %0d API/ref error(s), last: %s",
                 errors, rvviErrorGet());
          saw_error = 1'b1;
        end
        if (ref_retires != dut_retires) begin
          $error("RVVI_SCOREBOARD: retire count mismatch DUT=%0d REF=%0d",
                 dut_retires, ref_retires);
          saw_error = 1'b1;
        end
        $display("RVVI_SCOREBOARD: DUT retires=%0d REF retires=%0d mismatches=%0d",
                 dut_retires, ref_retires, mismatches);
        void'(rvviRefShutdown());
        initialized = 1'b0;
        if (saw_error) begin
          $fatal(1, "RVVI_SCOREBOARD: online lockstep failed");
        end
      end
    end
  end

endmodule
