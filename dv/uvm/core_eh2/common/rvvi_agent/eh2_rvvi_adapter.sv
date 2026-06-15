// SPDX-License-Identifier: Apache-2.0
// EH2 native trace/RVFI-probe view to standard RVVI-TRACE.
//
// MR1 scope: publish DUT retire stream and optional offline dump.  Reference
// model stepping and online comparison are intentionally left for MR2/MR3.

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

  input logic [NHART-1:0]       nb_load_wen,
  input logic [NHART-1:0][4:0]  nb_load_waddr,
  input logic [NHART-1:0][31:0] nb_load_data,

  input logic [NHART-1:0]       div_wren,
  input logic [NHART-1:0][4:0]  div_rd,
  input logic [NHART-1:0][31:0] div_wdata,
  input logic [NHART-1:0]       div_cancel,
  input logic [NHART-1:0]       div_cancel_overwrite,
  input logic [NHART-1:0][31:0] div_result
);

  localparam int CSR_MSTATUS = 12'h300;
  localparam int CSR_MTVEC   = 12'h305;
  localparam int CSR_MEPC    = 12'h341;
  localparam int CSR_MCAUSE  = 12'h342;
  localparam int CSR_MTVAL   = 12'h343;
  localparam int CSR_MIP     = 12'h344;

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
    if (csr_wb_w[h][r][CSR_MSTATUS]) begin
      if (!first) $fwrite(dump_fd, ";");
      dump_csr_update(h, r, CSR_MSTATUS);
      first = 1'b0;
    end
    if (csr_wb_w[h][r][CSR_MTVEC]) begin
      if (!first) $fwrite(dump_fd, ";");
      dump_csr_update(h, r, CSR_MTVEC);
      first = 1'b0;
    end
    if (csr_wb_w[h][r][CSR_MEPC]) begin
      if (!first) $fwrite(dump_fd, ";");
      dump_csr_update(h, r, CSR_MEPC);
      first = 1'b0;
    end
    if (csr_wb_w[h][r][CSR_MCAUSE]) begin
      if (!first) $fwrite(dump_fd, ";");
      dump_csr_update(h, r, CSR_MCAUSE);
      first = 1'b0;
    end
    if (csr_wb_w[h][r][CSR_MTVAL]) begin
      if (!first) $fwrite(dump_fd, ";");
      dump_csr_update(h, r, CSR_MTVAL);
      first = 1'b0;
    end
    if (csr_wb_w[h][r][CSR_MIP]) begin
      if (!first) $fwrite(dump_fd, ";");
      dump_csr_update(h, r, CSR_MIP);
      first = 1'b0;
    end
  endtask

  task automatic dump_async_wb(input int h);
    if (nb_load_wen[h] && nb_load_waddr[h] != 5'd0) begin
      $fwrite(dump_fd, "A|%0d|load|x%0d:%08h\n",
              h, nb_load_waddr[h], nb_load_data[h]);
    end
    if (div_wren[h] && div_rd[h] != 5'd0) begin
      if (div_cancel[h] && div_cancel_overwrite[h]) begin
        $fwrite(dump_fd, "A|%0d|div|x%0d:%08h\n",
                h, div_rd[h], div_result[h]);
      end else if (!div_cancel[h]) begin
        $fwrite(dump_fd, "A|%0d|div|x%0d:%08h\n",
                h, div_rd[h], div_wdata[h]);
      end
    end
  endtask

  always @(posedge clk) begin
    if (rst_l && dump_enabled && dump_fd != 0) begin
      for (int h = 0; h < NHART; h++) begin
        dump_async_wb(h);
        for (int r = 0; r < RETIRE; r++) begin
          if (valid_w[h][r]) begin
            $fwrite(dump_fd, "%0d|%0d|%08h|%08h|%0b|%0d",
                    h, order_w[h][r], pc_rdata_w[h][r], insn_w[h][r],
                    trap_w[h][r], mode_w[h][r]);
            dump_gpr_updates(h, r);
            dump_csr_updates(h, r);
            $fwrite(dump_fd, "\n");
          end
        end
      end
      $fflush(dump_fd);
    end
  end

endmodule
