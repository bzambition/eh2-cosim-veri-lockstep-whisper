// SPDX-License-Identifier: Apache-2.0
// EH2 native trace/RVFI-probe view to standard RVVI-TRACE.
//
// This is the EH2-specific boundary in the lockstep flow: it converts retire,
// asynchronous writeback, CSR, trap, interrupt, debug, and store sideband
// signals into the official rvviTrace interface.  The downstream scoreboard and
// C++ checker are intentionally core-agnostic.

`ifndef RVVI_NHART
`define RVVI_NHART 1
`endif

module eh2_rvvi_adapter #(
  parameter int NUM_THREADS = 1,
  parameter int NHART       = `RVVI_NHART,
  parameter int RETIRE      = 2,
  parameter int ILEN        = 32,
  parameter int XLEN        = 32,
  parameter int FLEN        = 32,
  parameter int VLEN        = 256
) (
  input logic clk,
  input logic rst_l,

  rvviTrace rvvi,

  input logic [NUM_THREADS-1:0][63:0] trace_insn,
  input logic [NUM_THREADS-1:0][63:0] trace_address,
  input logic [NUM_THREADS-1:0][1:0]  trace_valid,
  input logic [NUM_THREADS-1:0][1:0]  trace_exception,
  input logic [NUM_THREADS-1:0][4:0]  trace_ecause,
  input logic [NUM_THREADS-1:0][1:0]  trace_interrupt,
  input logic [NUM_THREADS-1:0][1:0]  trace_rd_valid,
  input logic [NUM_THREADS-1:0][9:0]  trace_rd_addr,
  input logic [NUM_THREADS-1:0][63:0] trace_rd_wdata,

  input logic [NHART-1:0][31:0] csr_mstatus,
  input logic [NHART-1:0][31:0] csr_mtvec,
  input logic [NHART-1:0][31:0] csr_mepc,
  input logic [NHART-1:0][31:0] csr_mcause,
  input logic [NHART-1:0][31:0] csr_mtval,
  input logic [NHART-1:0][31:0] csr_mip,
  input logic [NHART-1:0]       debug_mode,
  input logic                    csr_wen,
  input logic [11:0]             csr_waddr,
  input logic [31:0]             csr_wdata,
  input logic                    csr_wtid,

  input logic [NHART-1:0]       nb_load_alloc_valid,
  input logic [NHART-1:0][4:0]  nb_load_alloc_rd,
  input logic [NHART-1:0][3:0]  nb_load_alloc_tag,
  input logic [NHART-1:0][RETIRE-1:0] nb_load_retire_tag_valid,
  input logic [NHART-1:0][RETIRE-1:0][3:0] nb_load_retire_tag,
  input logic [NHART-1:0]       nb_load_wen,
  input logic [NHART-1:0][4:0]  nb_load_waddr,
  input logic [NHART-1:0]       nb_load_data_valid,
  input logic [NHART-1:0][31:0] nb_load_data,
  input logic [NHART-1:0][3:0]  nb_load_data_tag,

  input logic [NHART-1:0]       div_issue_valid,
  input logic [NHART-1:0][4:0]  div_issue_rd,
  input logic [NHART-1:0][31:0] div_issue_rs1,
  input logic [NHART-1:0][31:0] div_issue_rs2,
  input logic [NHART-1:0]       div_issue_unsigned,
  input logic [NHART-1:0]       div_issue_rem,
  input logic [NHART-1:0]       div_wren,
  input logic [NHART-1:0][4:0]  div_rd,
  input logic [NHART-1:0][31:0] div_wdata,
  input logic [NHART-1:0]       div_cancel,
  input logic [NHART-1:0]       div_cancel_overwrite,
  input logic [NHART-1:0][31:0] div_result,

  input logic                    lsu_bus_write,
  input logic                    lsu_bus_tid,
  input logic [31:0]             lsu_bus_addr,
  input logic [31:0]             lsu_bus_wdata,
  input logic [3:0]              lsu_bus_wmask
);

  localparam int CSR_MSTATUS = 12'h300;
  localparam int CSR_MTVEC   = 12'h305;
  localparam int CSR_MEPC    = 12'h341;
  localparam int CSR_MCAUSE  = 12'h342;
  localparam int CSR_MTVAL   = 12'h343;
  localparam int CSR_MIP     = 12'h344;
  localparam int CSR_MCOUNTINHIBIT = 12'h320;
  localparam int CSR_MRAC    = 12'h7c0;
  localparam int CSR_MPMC    = 12'h7c6;
  localparam int CSR_MFDC    = 12'h7f9;
  localparam int CSR_MSCAUSE = 12'h7ff;
  localparam int CSR_MEIVT   = 12'hbc8;
  localparam int CSR_MEIPT   = 12'hbc9;
  localparam int CSR_MEICIDPL = 12'hbcb;
  localparam int CSR_MEICURPL = 12'hbcc;

  logic                    valid_w      [NHART][RETIRE];
  logic [63:0]             order_w      [NHART][RETIRE];
  logic [ILEN-1:0]         insn_w       [NHART][RETIRE];
  logic                    trap_w       [NHART][RETIRE];
  logic                    debug_mode_w [NHART][RETIRE];
  logic [XLEN-1:0]         pc_rdata_w   [NHART][RETIRE];
  logic [31:0][XLEN-1:0]   x_wdata_w    [NHART][RETIRE];
  logic [31:0]             x_wb_w       [NHART][RETIRE];
  logic [4095:0][XLEN-1:0] csr_w        [NHART][RETIRE];
  logic [4095:0]           csr_wb_w     [NHART][RETIRE];
  logic                    intr_w       [NHART][RETIRE];
  logic [1:0]              mode_w       [NHART][RETIRE];

  logic [63:0] order_next_q;
  logic [63:0] order_cursor;
  logic [NHART-1:0] csr_wb_claimed;

  logic [NHART-1:0][31:0] csr_mstatus_q;
  logic [NHART-1:0][31:0] csr_mtvec_q;
  logic [NHART-1:0][31:0] csr_mepc_q;
  logic [NHART-1:0][31:0] csr_mcause_q;
  logic [NHART-1:0][31:0] csr_mtval_q;
  logic [NHART-1:0][31:0] csr_mip_q;

  bit    dump_enabled;
  int    dump_fd;
  string dump_file;

  typedef struct packed {
    logic       valid;
    logic [4:0] rd;
    logic [3:0] hw_tag;
    int unsigned tag;
  } load_tag_entry_t;

  load_tag_entry_t pending_load_q [NHART][$];
  load_tag_entry_t unretired_load_q [NHART][$];
  int unsigned next_load_tag [NHART];

  typedef struct packed {
    logic       valid;
    logic [4:0] rd;
    logic [31:0] dividend;
    logic [31:0] divisor;
    logic       is_unsigned;
    logic       is_rem;
    int unsigned tag;
  } div_tag_entry_t;

  div_tag_entry_t pending_div_q [NHART][$];
  div_tag_entry_t unretired_div_q [NHART][$];
  int unsigned next_div_tag [NHART];

  typedef struct packed {
    logic [31:0] addr;
    logic [31:0] data;
    logic [3:0]  be;
  } mem_write_entry_t;

  function automatic logic [31:0] lane32(input logic [63:0] value,
                                         input int lane);
    lane32 = (lane == 0) ? value[31:0] : value[63:32];
  endfunction

  function automatic logic [4:0] lane5(input logic [9:0] value,
                                       input int lane);
    lane5 = (lane == 0) ? value[4:0] : value[9:5];
  endfunction

  function automatic logic csr_changed(input int h);
    csr_changed = (csr_mstatus[h] != csr_mstatus_q[h]) ||
                  (csr_mtvec[h]   != csr_mtvec_q[h])   ||
                  (csr_mepc[h]    != csr_mepc_q[h])    ||
                  (csr_mcause[h]  != csr_mcause_q[h])  ||
                  (csr_mtval[h]   != csr_mtval_q[h])   ||
                  (csr_mip[h]     != csr_mip_q[h]);
  endfunction

  function automatic logic is_load_insn(input logic [31:0] insn);
    logic [6:0] opcode;
    logic [1:0] quadrant;
    logic [2:0] funct3;
    opcode = insn[6:0];
    quadrant = insn[1:0];
    funct3 = insn[15:13];
    is_load_insn = (opcode == 7'h03) ||
                   (opcode == 7'h2f && insn[31:27] == 5'h02) ||
                   (quadrant == 2'b00 && funct3 == 3'h2) ||
                   (quadrant == 2'b10 && funct3 == 3'h2);
  endfunction

  function automatic logic is_div_insn(input logic [31:0] insn);
    is_div_insn = (insn[6:0] == 7'h33) &&
                  (insn[31:25] == 7'h01) &&
                  (insn[14:12] >= 3'h4) &&
                  (insn[14:12] <= 3'h7);
  endfunction

  function automatic logic is_store_insn(input logic [31:0] insn);
    logic [1:0] quadrant;
    logic [2:0] funct3;
    quadrant = insn[1:0];
    funct3 = insn[15:13];
    is_store_insn = (insn[6:0] == 7'h23) ||
                    (quadrant == 2'b00 && funct3 == 3'h6) ||
                    (quadrant == 2'b10 && funct3 == 3'h6);
  endfunction

  function automatic logic mirrored_csr(input logic [11:0] csr);
    mirrored_csr = (csr == CSR_MSTATUS) ||
                   (csr == CSR_MTVEC)   ||
                   (csr == CSR_MEPC)    ||
                   (csr == CSR_MCAUSE)  ||
                   (csr == CSR_MTVAL)   ||
                   (csr == CSR_MIP);
  endfunction

  function automatic logic [31:0] mrac_arch_value(input logic [31:0] raw);
    for (int i = 0; i < 16; i++) begin
      mrac_arch_value[2*i] = raw[2*i];
      mrac_arch_value[(2*i)+1] = raw[(2*i)+1] & ~raw[2*i];
    end
  endfunction

  function automatic logic [31:0] eh2_csr_arch_value(
      input logic [11:0] csr,
      input logic [31:0] raw);
    unique case (csr)
      12'h301: eh2_csr_arch_value = 32'h4000_1105;
      CSR_MCOUNTINHIBIT: eh2_csr_arch_value = raw & 32'h0000_007d;
      CSR_MRAC: eh2_csr_arch_value = mrac_arch_value(raw);
      CSR_MPMC: eh2_csr_arch_value = raw & 32'h0000_0002;
      CSR_MFDC: eh2_csr_arch_value =
          raw & 32'h0007_1f4d;
      CSR_MSCAUSE: eh2_csr_arch_value = raw & 32'h0000_000f;
      CSR_MEIVT: eh2_csr_arch_value = raw & 32'hffff_fc00;
      CSR_MEIPT,
      CSR_MEICIDPL,
      CSR_MEICURPL: eh2_csr_arch_value = raw & 32'h0000_000f;
      default: eh2_csr_arch_value = raw;
    endcase
  endfunction

  function automatic logic [31:0] div_arch_result(input div_tag_entry_t entry);
    logic signed [31:0] lhs_s;
    logic signed [31:0] rhs_s;
    lhs_s = entry.dividend;
    rhs_s = entry.divisor;
    if (entry.is_rem) begin
      if (entry.divisor == 32'h0) begin
        div_arch_result = entry.dividend;
      end else if (!entry.is_unsigned &&
                   entry.dividend == 32'h8000_0000 &&
                   entry.divisor == 32'hffff_ffff) begin
        div_arch_result = 32'h0;
      end else if (entry.is_unsigned) begin
        div_arch_result = entry.dividend % entry.divisor;
      end else begin
        div_arch_result = lhs_s % rhs_s;
      end
    end else begin
      if (entry.divisor == 32'h0) begin
        div_arch_result = 32'hffff_ffff;
      end else if (!entry.is_unsigned &&
                   entry.dividend == 32'h8000_0000 &&
                   entry.divisor == 32'hffff_ffff) begin
        div_arch_result = 32'h8000_0000;
      end else if (entry.is_unsigned) begin
        div_arch_result = entry.dividend / entry.divisor;
      end else begin
        div_arch_result = lhs_s / rhs_s;
      end
    end
  endfunction

  function automatic logic [4:0] load_rd(input logic [31:0] insn);
    logic [1:0] quadrant;
    logic [2:0] funct3;
    quadrant = insn[1:0];
    funct3 = insn[15:13];
    if (quadrant == 2'b00 && funct3 == 3'h2) begin
      load_rd = {2'b01, insn[4:2]};
    end else begin
      load_rd = insn[11:7];
    end
  endfunction

  genvar gh;
  genvar gr;
  generate
    for (gh = 0; gh < NHART; gh++) begin : g_rvvi_hart
      for (gr = 0; gr < RETIRE; gr++) begin : g_rvvi_retire
        assign rvvi.valid[gh][gr]       = valid_w[gh][gr];
        assign rvvi.order[gh][gr]       = order_w[gh][gr];
        assign rvvi.insn[gh][gr]        = insn_w[gh][gr];
        assign rvvi.trap[gh][gr]        = trap_w[gh][gr];
        assign rvvi.debug_mode[gh][gr]  = debug_mode_w[gh][gr];
        assign rvvi.pc_rdata[gh][gr]    = pc_rdata_w[gh][gr];
        assign rvvi.x_wdata[gh][gr]     = x_wdata_w[gh][gr];
        assign rvvi.x_wb[gh][gr]        = x_wb_w[gh][gr];
        assign rvvi.f_wdata[gh][gr]     = '0;
        assign rvvi.f_wb[gh][gr]        = '0;
        assign rvvi.v_wdata[gh][gr]     = '0;
        assign rvvi.v_wb[gh][gr]        = '0;
        assign rvvi.csr[gh][gr]         = csr_w[gh][gr];
        assign rvvi.csr_wb[gh][gr]      = csr_wb_w[gh][gr];
        assign rvvi.lrsc_cancel[gh][gr] = 1'b0;
        assign rvvi.pc_wdata[gh][gr]    = '0;
        assign rvvi.intr[gh][gr]        = intr_w[gh][gr];
        assign rvvi.halt[gh][gr]        = 1'b0;
        assign rvvi.ixl[gh][gr]         = 2'b01;
        assign rvvi.mode[gh][gr]        = mode_w[gh][gr];
        assign rvvi.mode_virt[gh][gr]   = 1'b0;
      end
    end
  endgenerate

  always_comb begin
    order_cursor  = order_next_q;
    csr_wb_claimed = '0;

    for (int h = 0; h < NHART; h++) begin
      for (int r = 0; r < RETIRE; r++) begin
        valid_w[h][r]      = 1'b0;
        order_w[h][r]      = '0;
        insn_w[h][r]       = '0;
        trap_w[h][r]       = 1'b0;
        debug_mode_w[h][r] = 1'b0;
        pc_rdata_w[h][r]   = '0;
        x_wdata_w[h][r]    = '0;
        x_wb_w[h][r]       = '0;
        csr_w[h][r]        = '0;
        csr_wb_w[h][r]     = '0;
        intr_w[h][r]       = 1'b0;
        mode_w[h][r]       = 2'b11;  // CHECK: replace with exact EH2 privilege mode if exposed.

        if (rst_l && h < NUM_THREADS && r < 2) begin
          if (trace_valid[h][r]) begin
            valid_w[h][r]      = 1'b1;
            order_w[h][r]      = order_cursor;
            insn_w[h][r]       = lane32(trace_insn[h], r);
            trap_w[h][r]       = trace_exception[h][r];
            debug_mode_w[h][r] = debug_mode[h];
            pc_rdata_w[h][r]   = lane32(trace_address[h], r);
            intr_w[h][r]       = trace_interrupt[h][r];

            // CHECK: DIV/NB-load async writebacks are still sourced from the
            // trace packet. MR3 should replace this with exact wb_seq matching
            // if any async writeback is missing from trace_rd_*.
            if (trace_rd_valid[h][r] && lane5(trace_rd_addr[h], r) != 5'd0) begin
              x_wb_w[h][r][lane5(trace_rd_addr[h], r)] = 1'b1;
              x_wdata_w[h][r][lane5(trace_rd_addr[h], r)] =
                  lane32(trace_rd_wdata[h], r);
            end

            csr_w[h][r][CSR_MSTATUS] = csr_mstatus[h];
            csr_w[h][r][CSR_MTVEC]   = csr_mtvec[h];
            csr_w[h][r][CSR_MEPC]    = csr_mepc[h];
            csr_w[h][r][CSR_MCAUSE]  = csr_mcause[h];
            csr_w[h][r][CSR_MTVAL]   = csr_mtval[h];
            csr_w[h][r][CSR_MIP]     = csr_mip[h];

            // CHECK: CSR writeback pulses are derived from mirrored CSR changes,
            // not native TLU CSR write enables. MR3 can tighten this for compare.
            if (csr_changed(h) && !csr_wb_claimed[h]) begin
              csr_wb_w[h][r][CSR_MSTATUS] = (csr_mstatus[h] != csr_mstatus_q[h]);
              csr_wb_w[h][r][CSR_MTVEC]   = (csr_mtvec[h]   != csr_mtvec_q[h]);
              csr_wb_w[h][r][CSR_MEPC]    = (csr_mepc[h]    != csr_mepc_q[h]);
              csr_wb_w[h][r][CSR_MCAUSE]  = (csr_mcause[h]  != csr_mcause_q[h]);
              csr_wb_w[h][r][CSR_MTVAL]   = (csr_mtval[h]   != csr_mtval_q[h]);
              csr_wb_w[h][r][CSR_MIP]     = (csr_mip[h]     != csr_mip_q[h]);
              csr_wb_claimed[h] = 1'b1;
            end

            order_cursor = order_cursor + 64'd1;
          end
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rst_l) begin
    if (!rst_l) begin
      order_next_q  <= 64'd0;
      csr_mstatus_q <= '0;
      csr_mtvec_q   <= '0;
      csr_mepc_q    <= '0;
      csr_mcause_q  <= '0;
      csr_mtval_q   <= '0;
      csr_mip_q     <= '0;
    end else begin
      order_next_q  <= order_cursor;
      csr_mstatus_q <= csr_mstatus;
      csr_mtvec_q   <= csr_mtvec;
      csr_mepc_q    <= csr_mepc;
      csr_mcause_q  <= csr_mcause;
      csr_mtval_q   <= csr_mtval;
      csr_mip_q     <= csr_mip;
    end
  end

  initial begin
    dump_enabled = $test$plusargs("rvvi_trace_dump");
    dump_fd = 0;
    dump_file = "rvvi_trace.log";
    void'($value$plusargs("rvvi_trace_file=%s", dump_file));
    if (dump_enabled) begin
      dump_fd = $fopen(dump_file, "w");
      if (dump_fd == 0) begin
        $fatal(1, "RVVI_TRACE: cannot open dump file %s", dump_file);
      end
      $display("RVVI_TRACE: dumping DUT retire stream to %s", dump_file);
    end
  end

  task automatic dump_gpr_updates(input int h, input int r);
    bit first;
    first = 1'b1;
    $fwrite(dump_fd, "|gpr=");
    for (int i = 1; i < 32; i++) begin
      if (x_wb_w[h][r][i]) begin
        if (!first) $fwrite(dump_fd, ";");
        $fwrite(dump_fd, "x%0d:%08h", i, x_wdata_w[h][r][i]);
        first = 1'b0;
      end
    end
  endtask

  task automatic dump_csr_update(input int h, input int r, input int csr);
    if (csr_wb_w[h][r][csr]) begin
      $fwrite(dump_fd, "%03h:%08h", csr[11:0], csr_w[h][r][csr]);
    end
  endtask

  task automatic dump_csr_updates(input int h, input int r);
    bit first;
    first = 1'b1;
    $fwrite(dump_fd, "|csr=");
    for (int csr = 0; csr < 4096; csr++) begin
      if (csr_wb_w[h][r][csr]) begin
        if (!first) $fwrite(dump_fd, ";");
        dump_csr_update(h, r, csr);
        first = 1'b0;
      end
    end
  endtask

  task automatic capture_load_alloc(input int h);
    load_tag_entry_t entry;
    if (nb_load_alloc_valid[h] && nb_load_alloc_rd[h] != 5'd0) begin
      entry.valid = 1'b1;
      entry.rd = nb_load_alloc_rd[h];
      entry.hw_tag = nb_load_alloc_tag[h];
      entry.tag = 0;
      unretired_load_q[h].push_back(entry);
    end
  endtask

  task automatic capture_div_issue(input int h);
    div_tag_entry_t entry;
    if (div_issue_valid[h] && div_issue_rd[h] != 5'd0) begin
      entry.valid = 1'b1;
      entry.rd = div_issue_rd[h];
      entry.dividend = div_issue_rs1[h];
      entry.divisor = div_issue_rs2[h];
      entry.is_unsigned = div_issue_unsigned[h];
      entry.is_rem = div_issue_rem[h];
      entry.tag = next_div_tag[h]++;
      unretired_div_q[h].push_back(entry);
      pending_div_q[h].push_back(entry);
    end
  endtask

  task automatic discard_flushed_div(input int h);
    if (div_cancel[h] && !div_cancel_overwrite[h]) begin
      if (unretired_div_q[h].size() != 0) begin
        void'(unretired_div_q[h].pop_front());
      end
      if (pending_div_q[h].size() != 0) begin
        void'(pending_div_q[h].pop_front());
      end
    end
  endtask

  task automatic dump_retire_tag(input int h, input int r);
    load_tag_entry_t entry;
    int match_idx;
    bit found;
    logic [4:0] retire_rd;
    logic       retire_hw_tag_valid;
    logic [3:0] retire_hw_tag;
    if (is_load_insn(insn_w[h][r]) && x_wb_w[h][r] == '0 &&
        load_rd(insn_w[h][r]) != 5'd0) begin
      retire_rd = load_rd(insn_w[h][r]);
      retire_hw_tag_valid = nb_load_retire_tag_valid[h][r];
      retire_hw_tag = nb_load_retire_tag[h][r];
      match_idx = -1;
      found = 1'b0;
      if (retire_hw_tag_valid) begin
        foreach (unretired_load_q[h][i]) begin
          if (!found && unretired_load_q[h][i].hw_tag == retire_hw_tag) begin
            match_idx = i;
            entry = unretired_load_q[h][i];
            found = 1'b1;
          end
        end
      end else begin
        foreach (unretired_load_q[h][i]) begin
          if (!found && unretired_load_q[h][i].rd == retire_rd) begin
            match_idx = i;
            entry = unretired_load_q[h][i];
            found = 1'b1;
          end
        end
      end
      if (!found) begin
        entry.valid = 1'b1;
        entry.rd = retire_rd;
        entry.hw_tag = retire_hw_tag_valid ? retire_hw_tag : '0;
      end else begin
        unretired_load_q[h].delete(match_idx);
      end
      entry.rd = retire_rd;
      if (retire_hw_tag_valid) begin
        entry.hw_tag = nb_load_retire_tag[h][r];
      end
      entry.tag = next_load_tag[h]++;
      pending_load_q[h].push_back(entry);
      $fwrite(dump_fd, "|tag=load:%0d", entry.tag);
    end
  endtask

  task automatic dump_div_retire_tag(input int h, input int r);
    div_tag_entry_t entry;
    int match_idx;
    bit found;
    if (is_div_insn(insn_w[h][r]) && x_wb_w[h][r] == '0 &&
        insn_w[h][r][11:7] != 5'd0) begin
      match_idx = -1;
      found = 1'b0;
      foreach (unretired_div_q[h][i]) begin
        if (!found && unretired_div_q[h][i].rd == insn_w[h][r][11:7]) begin
          match_idx = i;
          entry = unretired_div_q[h][i];
          found = 1'b1;
        end
      end
      if (!found) begin
        entry.valid = 1'b1;
        entry.rd = insn_w[h][r][11:7];
        entry.dividend = '0;
        entry.divisor = '0;
        entry.is_unsigned = insn_w[h][r][14] == 1'b1;
        entry.is_rem = insn_w[h][r][13] == 1'b1;
        entry.tag = next_div_tag[h]++;
      end else begin
        unretired_div_q[h].delete(match_idx);
      end
      $fwrite(dump_fd, "|tag=div:%0d", entry.tag);
    end
  endtask

  task automatic capture_store_write();
    rvvi_mem_access_t access;
    longint unsigned packed_data;
    longint unsigned packed_mask;
    if (lsu_bus_write && lsu_bus_wmask != 4'b0) begin
      $fwrite(dump_fd, "M|%0d|%08h:%08h:%0h\n",
              lsu_bus_tid, lsu_bus_addr, lsu_bus_wdata, lsu_bus_wmask);
      access.fetch = 1'b0;
      access.size = 0;
      for (int i = 0; i < 4; i++) begin
        if (lsu_bus_wmask[i]) begin
          access.size++;
        end
      end
      access.vaddr = lsu_bus_addr;
      access.paddr = lsu_bus_addr;
      access.gaddr = '0;
      access.pte = '0;
      access.gpte = '0;
      access.page_type = '0;
      access.guest_page_type = '0;
      rvvi.mem_access_push(lsu_bus_tid, access);
      packed_data = {lsu_bus_addr, lsu_bus_wdata};
      packed_mask = lsu_bus_wmask;
      rvvi.net_push("store_data", packed_data);
      rvvi.net_push("store_mask", packed_mask);
    end
  endtask

  task automatic capture_csr_write(input int h);
    if (csr_wen && csr_wtid == h[0] && !mirrored_csr(csr_waddr)) begin
      $fwrite(dump_fd, "C|%0d|%03h:%08h\n", h, csr_waddr,
              eh2_csr_arch_value(csr_waddr, csr_wdata));
    end
  endtask

  task automatic dump_async_wb(input int h);
    load_tag_entry_t entry;
    div_tag_entry_t div_entry;
    int match_idx;
    int unsigned trace_tag;
    bit found;
    if (nb_load_data_valid[h]) begin
      match_idx = -1;
      trace_tag = 0;
      found = 1'b0;
      foreach (pending_load_q[h][i]) begin
        if (!found && pending_load_q[h][i].hw_tag == nb_load_data_tag[h] &&
            (!nb_load_wen[h] || nb_load_waddr[h] == 5'd0 ||
             pending_load_q[h][i].rd == nb_load_waddr[h])) begin
          match_idx = i;
          trace_tag = pending_load_q[h][i].tag;
          entry = pending_load_q[h][i];
          found = 1'b1;
        end
      end
      if (!found && nb_load_wen[h] && nb_load_waddr[h] != 5'd0) begin
        foreach (pending_load_q[h][i]) begin
          if (!found && pending_load_q[h][i].rd == nb_load_waddr[h]) begin
            match_idx = i;
            trace_tag = pending_load_q[h][i].tag;
            entry = pending_load_q[h][i];
            found = 1'b1;
          end
        end
      end
      if (found) begin
        pending_load_q[h].delete(match_idx);
        $fwrite(dump_fd, "A|%0d|load|x%0d:%08h|tag=%0d\n",
                h, entry.rd, nb_load_data[h], trace_tag);
      end else if (nb_load_wen[h] && nb_load_waddr[h] != 5'd0) begin
        $fwrite(dump_fd, "A|%0d|load|x%0d:%08h\n",
                h, nb_load_waddr[h], nb_load_data[h]);
      end
    end
    if (div_cancel[h] && div_cancel_overwrite[h]) begin
      if (pending_div_q[h].size() != 0) begin
        div_entry = pending_div_q[h].pop_front();
        $fwrite(dump_fd, "A|%0d|div|x%0d:%08h|tag=%0d\n",
                h, div_entry.rd, div_arch_result(div_entry), div_entry.tag);
      end else if (div_rd[h] != 5'd0) begin
        $fwrite(dump_fd, "A|%0d|div|x%0d:%08h\n",
                h, div_rd[h], div_result[h]);
      end
    end else if (div_wren[h] && div_rd[h] != 5'd0) begin
      if (pending_div_q[h].size() != 0) begin
        div_entry = pending_div_q[h].pop_front();
        $fwrite(dump_fd, "A|%0d|div|x%0d:%08h|tag=%0d\n",
                h, div_entry.rd, div_wdata[h], div_entry.tag);
      end else begin
        $fwrite(dump_fd, "A|%0d|div|x%0d:%08h\n",
                h, div_rd[h], div_wdata[h]);
      end
    end
  endtask

  always @(posedge clk) begin
    if (rst_l && dump_enabled && dump_fd != 0) begin
      capture_store_write();
      for (int h = 0; h < NHART; h++) begin
        capture_div_issue(h);
        discard_flushed_div(h);
        capture_csr_write(h);
        for (int r = 0; r < RETIRE; r++) begin
          if (valid_w[h][r]) begin
            $fwrite(dump_fd, "%0d|%0d|%08h|%08h|%0b|%0d",
                    h, order_w[h][r], pc_rdata_w[h][r], insn_w[h][r],
                    trap_w[h][r], mode_w[h][r]);
            dump_gpr_updates(h, r);
            dump_csr_updates(h, r);
            dump_retire_tag(h, r);
            dump_div_retire_tag(h, r);
            $fwrite(dump_fd, "\n");
          end
        end
        // Retire rows must be visible before same-cycle async writebacks so
        // the converter can attach the returned value to the exact row.
        dump_async_wb(h);
        // New dc1 allocations are younger than any wb retire in this cycle.
        // Capture them after retire matching to avoid hardware-tag reuse
        // aliasing a younger allocation onto an older retire.
        capture_load_alloc(h);
      end
      $fflush(dump_fd);
    end
  end

endmodule
