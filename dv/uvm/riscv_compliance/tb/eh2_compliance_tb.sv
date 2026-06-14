// SPDX-License-Identifier: Apache-2.0
// EH2 RISC-V Compliance Testbench (issue 57)
//
// Standalone top-level testbench for running riscv-compliance tests
// against the EH2 (VeeR) RISC-V core.  Modeled after
// ibex/dv/riscv_compliance/rtl/ibex_riscv_compliance.sv.
//
// Architecture:
//   eh2_compliance_tb
//     +-- eh2_veer_wrapper (DUT)
//     |     +-- dmi_wrapper
//     |     +-- eh2_veer (core)
//     |     +-- eh2_mem (internal DCCM/ICCM/ICache)
//     +-- axi4_slave_mem (LSU memory - data)
//     +-- axi4_slave_mem (IFU memory - instruction)
//     +-- axi4_slave_mem (SB memory - debug)
//     +-- signature_monitor (mailbox 0xD058_0000 + signature dump)
//
// The test binary (.hex) is loaded into all three AXI memories at time 0.
// The compliance test software writes begin/end signature addresses to
// 0xD058_0004 / 0xD058_0008, then triggers signature dump via a write to
// 0xD058_0000.  The TB reads the signature from memory and writes
// "SIGNATURE: XXXXXXXX" lines to stdout — byte-by-byte comparable with
// riscv-compliance reference outputs.

module eh2_compliance_tb;

  //--------------------------------------------------------------------------
  // Clock and Reset
  //--------------------------------------------------------------------------
  bit core_clk;
  initial begin
    core_clk = 0;
    forever #5 core_clk = ~core_clk;  // 100 MHz
  end

  logic rst_l;       // Active-low core reset
  logic porst_l;     // Power-on reset

  //--------------------------------------------------------------------------
  // DUT signal declarations (shared via core_eh2_tb_top include)
  //--------------------------------------------------------------------------
  // NOTE: rst_l, porst_l, core_clk declared above; all other signals
  //       (AXI, trace, interrupts, JTAG, control) come from the include.
`include "core_eh2_dut_signals.svh"

  //--------------------------------------------------------------------------
  // Compliance signature tracking (EH2-specific, not in shared header)
  //--------------------------------------------------------------------------
  logic [31:0]  sig_begin_addr;
  logic [31:0]  sig_end_addr;
  logic [31:0]  mailbox_write_data;
  logic [31:0]  mailbox_write_addr;
  logic         mailbox_write_valid;

  //--------------------------------------------------------------------------
  // Reset Generation (matches core_eh2_tb_top)
  //--------------------------------------------------------------------------
  initial begin
    rst_l   = 0;
    porst_l = 0;
    repeat (3) @(posedge core_clk);
    porst_l = 1;
    repeat (3) @(posedge core_clk);
    rst_l   = 1;
  end

  //--------------------------------------------------------------------------
  // Default Signal Values
  //--------------------------------------------------------------------------
  initial begin
    reset_vector       = 32'h80000000;
    nmi_vector         = 32'h00000000;
    jtag_id            = 31'h1;
    lsu_bus_clk_en     = 1;
    ifu_bus_clk_en     = 1;
    dbg_bus_clk_en     = 1;
    dma_bus_clk_en     = 1;
  end

  //--------------------------------------------------------------------------
  // Early Binary Loading
  //--------------------------------------------------------------------------
  string hex_path;
  initial begin
    if ($value$plusargs("bin=%s", hex_path) && hex_path.len() > 0) begin
      $display("COMPLIANCE_TB: Loading hex file: %s", hex_path);
      $readmemh(hex_path, lsu_mem.mem);
      $readmemh(hex_path, ifu_mem.mem);
      $readmemh(hex_path, sb_mem.mem);
      $display("COMPLIANCE_TB: Hex load complete");
    end else begin
      $display("COMPLIANCE_TB: WARNING - no +bin=<hex> argument provided");
    end
  end

  //--------------------------------------------------------------------------
  // Mailbox / Signature Monitor
  //
  // Address map (monitored on LSU AXI write channel):
  //   0xD058_0000  HALT — dump signature, terminate simulation
  //   0xD058_0004  Set signature begin address
  //   0xD058_0008  Set signature end address
  //
  // On HALT: read signature bytes from axi4_slave_mem via hierarchical ref
  // and emit "SIGNATURE: XXXXXXXX" for each 32-bit word.
  //--------------------------------------------------------------------------

  // Detect valid write from LSU AXI AW+W channels
  assign mailbox_write_valid = lsu_axi_awvalid && lsu_axi_awready;
  assign mailbox_write_addr  = lsu_axi_awaddr;
  assign mailbox_write_data  = lsu_axi_wdata;

  // Mailbox address capture — combinational detection
  logic mb_halt_req, mb_set_begin, mb_set_end;
  assign mb_halt_req  = rst_l && mailbox_write_valid && (mailbox_write_addr == 32'hD058_0000);
  assign mb_set_begin = rst_l && mailbox_write_valid && (mailbox_write_addr == 32'hD058_0004);
  assign mb_set_end   = rst_l && mailbox_write_valid && (mailbox_write_addr == 32'hD058_0008);

  always @(posedge core_clk) begin
    if (mb_set_begin) begin
      sig_begin_addr <= mailbox_write_data;
      $display("COMPLIANCE_TB: signature begin = 0x%08x", mailbox_write_data);
    end
    if (mb_set_end) begin
      sig_end_addr <= mailbox_write_data;
      $display("COMPLIANCE_TB: signature end   = 0x%08x", mailbox_write_data);
    end
    if (mb_halt_req) begin
      $display("COMPLIANCE_TB: HALT signal received at %0t", $time);
    end
  end

  // Signature dump FSM
  typedef enum logic [1:0] {
    IDLE, DUMPING, DONE
  } dump_state_e;
  dump_state_e dump_state;
  logic [31:0] dump_addr;
  int          dump_delay;

  always @(posedge core_clk or negedge rst_l) begin
    if (!rst_l) begin
      dump_state       <= IDLE;
      dump_addr        <= 0;
      dump_delay       <= 0;
      sig_begin_addr   <= 32'hFFFF_FFFF;
      sig_end_addr     <= 0;
    end else begin
      case (dump_state)
        IDLE: begin
          if (mb_halt_req) begin
            if (sig_begin_addr == 32'hFFFF_FFFF || sig_end_addr == 0) begin
              $display("COMPLIANCE_TB: WARNING - signature bounds not set, using default");
              sig_begin_addr = 32'h8000_1000;
              sig_end_addr   = 32'h8000_2000;
            end
            $display("COMPLIANCE_TB: Dumping signature from 0x%08x to 0x%08x",
                     sig_begin_addr, sig_end_addr);
            dump_delay <= 2;
            dump_addr  <= sig_begin_addr;
            dump_state <= DUMPING;
          end
        end

        DUMPING: begin
          if (dump_delay > 0) begin
            dump_delay <= dump_delay - 1;
          end else begin
            if (dump_addr < sig_end_addr) begin
              $display("SIGNATURE: %08x", {
                read_mem_byte(dump_addr + 3),
                read_mem_byte(dump_addr + 2),
                read_mem_byte(dump_addr + 1),
                read_mem_byte(dump_addr + 0)
              });
              dump_addr <= dump_addr + 4;
            end else begin
              dump_state <= DONE;
            end
          end
        end

        DONE: begin
          $display("COMPLIANCE_TB: Signature dump complete. Terminating.");
          $finish;
        end
      endcase
    end
  end

  // Read a byte from AXI memory (hierarchical access)
  function automatic logic [7:0] read_mem_byte(input logic [31:0] addr);
    if (ifu_mem.mem.exists(addr))
      return ifu_mem.mem[addr];
    else if (lsu_mem.mem.exists(addr))
      return lsu_mem.mem[addr];
    else
      return 8'h00;
  endfunction

  //--------------------------------------------------------------------------
  // DUT Instantiation
  //--------------------------------------------------------------------------
  // Signals rst_l, porst_l, core_clk from local declarations.
  // All other signals come from core_eh2_dut_signals.svh with matching
  // widths defined by common_defines.vh (RV_NUM_THREADS=1 etc.)
`ifdef RV_BUILD_AXI4
  eh2_veer_wrapper dut (
    .clk                    (core_clk),
    .rst_l                  (rst_l),
    .dbg_rst_l              (porst_l),
    .rst_vec                (reset_vector[31:1]),
    .nmi_int                (nmi_int),
    .nmi_vec                (nmi_vector[31:1]),
    .jtag_id                (jtag_id[31:1]),

    .trace_rv_i_insn_ip      (trace_rv_i_insn_ip),
    .trace_rv_i_address_ip   (trace_rv_i_address_ip),
    .trace_rv_i_valid_ip     (trace_rv_i_valid_ip),
    .trace_rv_i_exception_ip (trace_rv_i_exception_ip),
    .trace_rv_i_ecause_ip    (trace_rv_i_ecause_ip),
    .trace_rv_i_interrupt_ip (trace_rv_i_interrupt_ip),
    .trace_rv_i_tval_ip      (trace_rv_i_tval_ip),
    .trace_rv_i_rd_valid_ip  (trace_rv_i_rd_valid_ip),
    .trace_rv_i_rd_addr_ip   (trace_rv_i_rd_addr_ip),
    .trace_rv_i_rd_wdata_ip  (trace_rv_i_rd_wdata_ip),

    // LSU AXI4
    .lsu_axi_awvalid   (lsu_axi_awvalid),
    .lsu_axi_awready   (lsu_axi_awready),
    .lsu_axi_awid      (lsu_axi_awid),
    .lsu_axi_awaddr    (lsu_axi_awaddr),
    .lsu_axi_awregion  (lsu_axi_awregion),
    .lsu_axi_awlen     (lsu_axi_awlen),
    .lsu_axi_awsize    (lsu_axi_awsize),
    .lsu_axi_awburst   (lsu_axi_awburst),
    .lsu_axi_awlock    (lsu_axi_awlock),
    .lsu_axi_awcache   (lsu_axi_awcache),
    .lsu_axi_awprot    (lsu_axi_awprot),
    .lsu_axi_awqos     (lsu_axi_awqos),
    .lsu_axi_wvalid    (lsu_axi_wvalid),
    .lsu_axi_wready    (lsu_axi_wready),
    .lsu_axi_wdata     (lsu_axi_wdata),
    .lsu_axi_wstrb     (lsu_axi_wstrb),
    .lsu_axi_wlast     (lsu_axi_wlast),
    .lsu_axi_bvalid    (lsu_axi_bvalid),
    .lsu_axi_bready    (lsu_axi_bready),
    .lsu_axi_bresp     (lsu_axi_bresp),
    .lsu_axi_bid       (lsu_axi_bid),
    .lsu_axi_arvalid   (lsu_axi_arvalid),
    .lsu_axi_arready   (lsu_axi_arready),
    .lsu_axi_arid      (lsu_axi_arid),
    .lsu_axi_araddr    (lsu_axi_araddr),
    .lsu_axi_arregion  (lsu_axi_arregion),
    .lsu_axi_arlen     (lsu_axi_arlen),
    .lsu_axi_arsize    (lsu_axi_arsize),
    .lsu_axi_arburst   (lsu_axi_arburst),
    .lsu_axi_arlock    (lsu_axi_arlock),
    .lsu_axi_arcache   (lsu_axi_arcache),
    .lsu_axi_arprot    (lsu_axi_arprot),
    .lsu_axi_arqos     (lsu_axi_arqos),
    .lsu_axi_rvalid    (lsu_axi_rvalid),
    .lsu_axi_rready    (lsu_axi_rready),
    .lsu_axi_rid       (lsu_axi_rid),
    .lsu_axi_rdata     (lsu_axi_rdata),
    .lsu_axi_rresp     (lsu_axi_rresp),
    .lsu_axi_rlast     (lsu_axi_rlast),

    // IFU AXI4
    .ifu_axi_awvalid   (ifu_axi_awvalid),
    .ifu_axi_awready   (ifu_axi_awready),
    .ifu_axi_awid      (ifu_axi_awid),
    .ifu_axi_awaddr    (ifu_axi_awaddr),
    .ifu_axi_awregion  (ifu_axi_awregion),
    .ifu_axi_awlen     (ifu_axi_awlen),
    .ifu_axi_awsize    (ifu_axi_awsize),
    .ifu_axi_awburst   (ifu_axi_awburst),
    .ifu_axi_awlock    (ifu_axi_awlock),
    .ifu_axi_awcache   (ifu_axi_awcache),
    .ifu_axi_awprot    (ifu_axi_awprot),
    .ifu_axi_awqos     (ifu_axi_awqos),
    .ifu_axi_wvalid    (ifu_axi_wvalid),
    .ifu_axi_wready    (ifu_axi_wready),
    .ifu_axi_wdata     (ifu_axi_wdata),
    .ifu_axi_wstrb     (ifu_axi_wstrb),
    .ifu_axi_wlast     (ifu_axi_wlast),
    .ifu_axi_bvalid    (ifu_axi_bvalid),
    .ifu_axi_bready    (ifu_axi_bready),
    .ifu_axi_bresp     (ifu_axi_bresp),
    .ifu_axi_bid       (ifu_axi_bid),
    .ifu_axi_arvalid   (ifu_axi_arvalid),
    .ifu_axi_arready   (ifu_axi_arready),
    .ifu_axi_arid      (ifu_axi_arid),
    .ifu_axi_araddr    (ifu_axi_araddr),
    .ifu_axi_arregion  (ifu_axi_arregion),
    .ifu_axi_arlen     (ifu_axi_arlen),
    .ifu_axi_arsize    (ifu_axi_arsize),
    .ifu_axi_arburst   (ifu_axi_arburst),
    .ifu_axi_arlock    (ifu_axi_arlock),
    .ifu_axi_arcache   (ifu_axi_arcache),
    .ifu_axi_arprot    (ifu_axi_arprot),
    .ifu_axi_arqos     (ifu_axi_arqos),
    .ifu_axi_rvalid    (ifu_axi_rvalid),
    .ifu_axi_rready    (ifu_axi_rready),
    .ifu_axi_rid       (ifu_axi_rid),
    .ifu_axi_rdata     (ifu_axi_rdata),
    .ifu_axi_rresp     (ifu_axi_rresp),
    .ifu_axi_rlast     (ifu_axi_rlast),

    // SB AXI4
    .sb_axi_awvalid    (sb_axi_awvalid),
    .sb_axi_awready    (sb_axi_awready),
    .sb_axi_awid       (sb_axi_awid),
    .sb_axi_awaddr     (sb_axi_awaddr),
    .sb_axi_awregion   (sb_axi_awregion),
    .sb_axi_awlen      (sb_axi_awlen),
    .sb_axi_awsize     (sb_axi_awsize),
    .sb_axi_awburst    (sb_axi_awburst),
    .sb_axi_awlock     (sb_axi_awlock),
    .sb_axi_awcache    (sb_axi_awcache),
    .sb_axi_awprot     (sb_axi_awprot),
    .sb_axi_awqos      (sb_axi_awqos),
    .sb_axi_wvalid     (sb_axi_wvalid),
    .sb_axi_wready     (sb_axi_wready),
    .sb_axi_wdata      (sb_axi_wdata),
    .sb_axi_wstrb      (sb_axi_wstrb),
    .sb_axi_wlast      (sb_axi_wlast),
    .sb_axi_bvalid     (sb_axi_bvalid),
    .sb_axi_bready     (sb_axi_bready),
    .sb_axi_bresp      (sb_axi_bresp),
    .sb_axi_bid        (sb_axi_bid),
    .sb_axi_arvalid    (sb_axi_arvalid),
    .sb_axi_arready    (sb_axi_arready),
    .sb_axi_arid       (sb_axi_arid),
    .sb_axi_araddr     (sb_axi_araddr),
    .sb_axi_arregion   (sb_axi_arregion),
    .sb_axi_arlen      (sb_axi_arlen),
    .sb_axi_arsize     (sb_axi_arsize),
    .sb_axi_arburst    (sb_axi_arburst),
    .sb_axi_arlock     (sb_axi_arlock),
    .sb_axi_arcache    (sb_axi_arcache),
    .sb_axi_arprot     (sb_axi_arprot),
    .sb_axi_arqos      (sb_axi_arqos),
    .sb_axi_rvalid     (sb_axi_rvalid),
    .sb_axi_rready     (sb_axi_rready),
    .sb_axi_rid        (sb_axi_rid),
    .sb_axi_rdata      (sb_axi_rdata),
    .sb_axi_rresp      (sb_axi_rresp),
    .sb_axi_rlast      (sb_axi_rlast),

    // DMA AXI4 — no external DMA master
    .dma_axi_awvalid   (dma_axi_awvalid),
    .dma_axi_awready   (dma_axi_awready),
    .dma_axi_awid      (dma_axi_awid),
    .dma_axi_awaddr    (dma_axi_awaddr),
    .dma_axi_awsize    (dma_axi_awsize),
    .dma_axi_awprot    (dma_axi_awprot),
    .dma_axi_awlen     (dma_axi_awlen),
    .dma_axi_awburst   (dma_axi_awburst),
    .dma_axi_wvalid    (dma_axi_wvalid),
    .dma_axi_wready    (dma_axi_wready),
    .dma_axi_wdata     (dma_axi_wdata),
    .dma_axi_wstrb     (dma_axi_wstrb),
    .dma_axi_wlast     (dma_axi_wlast),
    .dma_axi_bvalid    (dma_axi_bvalid),
    .dma_axi_bready    (dma_axi_bready),
    .dma_axi_bresp     (dma_axi_bresp),
    .dma_axi_bid       (dma_axi_bid),
    .dma_axi_arvalid   (dma_axi_arvalid),
    .dma_axi_arready   (dma_axi_arready),
    .dma_axi_arid      (dma_axi_arid),
    .dma_axi_araddr    (dma_axi_araddr),
    .dma_axi_arsize    (dma_axi_arsize),
    .dma_axi_arprot    (dma_axi_arprot),
    .dma_axi_arlen     (dma_axi_arlen),
    .dma_axi_arburst   (dma_axi_arburst),
    .dma_axi_rvalid    (dma_axi_rvalid),
    .dma_axi_rready    (dma_axi_rready),
    .dma_axi_rid       (dma_axi_rid),
    .dma_axi_rdata     (dma_axi_rdata),
    .dma_axi_rresp     (dma_axi_rresp),
    .dma_axi_rlast     (dma_axi_rlast),

    // JTAG — inactive, keep clock alive
    .jtag_tck          (core_clk),
    .jtag_tms          (1'b0),
    .jtag_tdi          (1'b0),
    .jtag_trst_n       (1'b1),
    .jtag_tdo          (jtag_tdo),

    // Interrupts — tied off for compliance
    .timer_int         ('0),
    .soft_int          ('0),
    .extintsrc_req     ('0),

    // Clock enables
    .lsu_bus_clk_en    (lsu_bus_clk_en),
    .ifu_bus_clk_en    (ifu_bus_clk_en),
    .dbg_bus_clk_en    (dbg_bus_clk_en),
    .dma_bus_clk_en    (dma_bus_clk_en),

    // External memory packets — tied off
    .dccm_ext_in_pkt   ('0),
    .iccm_ext_in_pkt   ('0),
    .btb_ext_in_pkt    ('0),
    .ic_data_ext_in_pkt('0),
    .ic_tag_ext_in_pkt ('0),

    // MPC halt/run — let core run freely after reset
    .mpc_debug_halt_req ('0),
    .mpc_debug_run_req  ({`RV_NUM_THREADS{1'b1}}),
    .mpc_reset_run_req  ({`RV_NUM_THREADS{1'b1}}),
    .mpc_debug_halt_ack (),
    .mpc_debug_run_ack  (),
    .debug_brkpt_status (),
    .dec_tlu_mhartstart (),

    // CPU halt/run — let core run freely
    .i_cpu_halt_req     ('0),
    .o_cpu_halt_ack     (),
    .o_cpu_halt_status  (),
    .i_cpu_run_req      ({`RV_NUM_THREADS{1'b1}}),
    .o_cpu_run_ack      (),

    .o_debug_mode_status(),

    // Performance counters
    .dec_tlu_perfcnt0  (),
    .dec_tlu_perfcnt1  (),
    .dec_tlu_perfcnt2  (),
    .dec_tlu_perfcnt3  (),

    .core_id           ('0),
    .scan_mode         (1'b0),
    .mbist_mode        (1'b0)
  );
`endif // RV_BUILD_AXI4

  //--------------------------------------------------------------------------
  // AXI4 Slave Memory Models (only when building AXI4 config)
  //--------------------------------------------------------------------------
`ifdef RV_BUILD_AXI4
  axi4_slave_mem #(
    .ADDR_WIDTH (32),
    .DATA_WIDTH (64),
    .ID_WIDTH   (`RV_LSU_BUS_TAG),
    .MEM_SIZE   (64 * 1024 * 1024)
  ) lsu_mem (
    .clk      (core_clk),
    .rst_n    (rst_l),
    .error_inject_mode (1'b0),
    .force_bresp       (2'b00),
    .force_rresp       (2'b00),
    .awid     (lsu_axi_awid),
    .awaddr   (lsu_axi_awaddr),
    .awlen    (lsu_axi_awlen),
    .awsize   (lsu_axi_awsize),
    .awburst  (lsu_axi_awburst),
    .awvalid  (lsu_axi_awvalid),
    .awready  (lsu_axi_awready),
    .wdata    (lsu_axi_wdata),
    .wstrb    (lsu_axi_wstrb),
    .wlast    (lsu_axi_wlast),
    .wvalid   (lsu_axi_wvalid),
    .wready   (lsu_axi_wready),
    .bid      (lsu_axi_bid),
    .bresp    (lsu_axi_bresp),
    .bvalid   (lsu_axi_bvalid),
    .bready   (lsu_axi_bready),
    .arid     (lsu_axi_arid),
    .araddr   (lsu_axi_araddr),
    .arlen    (lsu_axi_arlen),
    .arsize   (lsu_axi_arsize),
    .arburst  (lsu_axi_arburst),
    .arvalid  (lsu_axi_arvalid),
    .arready  (lsu_axi_arready),
    .rid      (lsu_axi_rid),
    .rdata    (lsu_axi_rdata),
    .rresp    (lsu_axi_rresp),
    .rlast    (lsu_axi_rlast),
    .rvalid   (lsu_axi_rvalid),
    .rready   (lsu_axi_rready)
  );

  axi4_slave_mem #(
    .ADDR_WIDTH (32),
    .DATA_WIDTH (64),
    .ID_WIDTH   (`RV_IFU_BUS_TAG),
    .MEM_SIZE   (64 * 1024 * 1024)
  ) ifu_mem (
    .clk      (core_clk),
    .rst_n    (rst_l),
    .error_inject_mode (1'b0),
    .force_bresp       (2'b00),
    .force_rresp       (2'b00),
    .awid     (ifu_axi_awid),
    .awaddr   (ifu_axi_awaddr),
    .awlen    (ifu_axi_awlen),
    .awsize   (ifu_axi_awsize),
    .awburst  (ifu_axi_awburst),
    .awvalid  (ifu_axi_awvalid),
    .awready  (ifu_axi_awready),
    .wdata    (ifu_axi_wdata),
    .wstrb    (ifu_axi_wstrb),
    .wlast    (ifu_axi_wlast),
    .wvalid   (ifu_axi_wvalid),
    .wready   (ifu_axi_wready),
    .bid      (ifu_axi_bid),
    .bresp    (ifu_axi_bresp),
    .bvalid   (ifu_axi_bvalid),
    .bready   (ifu_axi_bready),
    .arid     (ifu_axi_arid),
    .araddr   (ifu_axi_araddr),
    .arlen    (ifu_axi_arlen),
    .arsize   (ifu_axi_arsize),
    .arburst  (ifu_axi_arburst),
    .arvalid  (ifu_axi_arvalid),
    .arready  (ifu_axi_arready),
    .rid      (ifu_axi_rid),
    .rdata    (ifu_axi_rdata),
    .rresp    (ifu_axi_rresp),
    .rlast    (ifu_axi_rlast),
    .rvalid   (ifu_axi_rvalid),
    .rready   (ifu_axi_rready)
  );

  axi4_slave_mem #(
    .ADDR_WIDTH (32),
    .DATA_WIDTH (64),
    .ID_WIDTH   (`RV_SB_BUS_TAG),
    .MEM_SIZE   (64 * 1024 * 1024)
  ) sb_mem (
    .clk      (core_clk),
    .rst_n    (rst_l),
    .error_inject_mode (1'b0),
    .force_bresp       (2'b00),
    .force_rresp       (2'b00),
    .awid     (sb_axi_awid),
    .awaddr   (sb_axi_awaddr),
    .awlen    (sb_axi_awlen),
    .awsize   (sb_axi_awsize),
    .awburst  (sb_axi_awburst),
    .awvalid  (sb_axi_awvalid),
    .awready  (sb_axi_awready),
    .wdata    (sb_axi_wdata),
    .wstrb    (sb_axi_wstrb),
    .wlast    (sb_axi_wlast),
    .wvalid   (sb_axi_wvalid),
    .wready   (sb_axi_wready),
    .bid      (sb_axi_bid),
    .bresp    (sb_axi_bresp),
    .bvalid   (sb_axi_bvalid),
    .bready   (sb_axi_bready),
    .arid     (sb_axi_arid),
    .araddr   (sb_axi_araddr),
    .arlen    (sb_axi_arlen),
    .arsize   (sb_axi_arsize),
    .arburst  (sb_axi_arburst),
    .arvalid  (sb_axi_arvalid),
    .arready  (sb_axi_arready),
    .rid      (sb_axi_rid),
    .rdata    (sb_axi_rdata),
    .rresp    (sb_axi_rresp),
    .rlast    (sb_axi_rlast),
    .rvalid   (sb_axi_rvalid),
    .rready   (sb_axi_rready)
  );

  // DMA port: no external DMA master — tie all inputs to inactive values
  assign dma_axi_awvalid = 1'b0;
  assign dma_axi_awid    = '0;
  assign dma_axi_awaddr  = '0;
  assign dma_axi_awsize  = '0;
  assign dma_axi_awprot  = '0;
  assign dma_axi_awlen   = '0;
  assign dma_axi_awburst = '0;
  assign dma_axi_wvalid  = 1'b0;
  assign dma_axi_wdata   = '0;
  assign dma_axi_wstrb   = '0;
  assign dma_axi_wlast   = '0;
  assign dma_axi_bready  = 1'b0;
  assign dma_axi_arvalid = 1'b0;
  assign dma_axi_arid    = '0;
  assign dma_axi_araddr  = '0;
  assign dma_axi_arsize  = '0;
  assign dma_axi_arprot  = '0;
  assign dma_axi_arlen   = '0;
  assign dma_axi_arburst = '0;
  assign dma_axi_rready  = 1'b0;
`endif // RV_BUILD_AXI4

  //--------------------------------------------------------------------------
  // Safety Timeout
  //--------------------------------------------------------------------------
  initial begin
    #(64'd1_800_000_000_000);  // 30 minutes
    $display("COMPLIANCE_TB: TIMEOUT - simulation stopped");
    $finish;
  end

  //--------------------------------------------------------------------------
  // Simple trace monitor for debugging
  //--------------------------------------------------------------------------
  always_ff @(posedge core_clk) begin
    if (rst_l && trace_rv_i_valid_ip[0][0]) begin
      $display("TRACE: PC=%08h INSN=%08h",
               trace_rv_i_address_ip[0][31:0],
               trace_rv_i_insn_ip[0][31:0]);
    end
  end

endmodule
