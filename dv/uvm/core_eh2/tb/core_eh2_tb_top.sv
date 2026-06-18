// SPDX-License-Identifier: Apache-2.0
// EH2 UVM Verification Platform - Top Testbench
//
// Top-level testbench for EH2 (VeeR) RISC-V core UVM verification.
// Instantiates eh2_veer_wrapper, connects AXI4 memory models,
// monitors mailbox for pass/fail detection.
//
// Architecture:
//   core_eh2_tb_top
//     +-- eh2_veer_wrapper (DUT)
//     |     +-- dmi_wrapper (JTAG-to-DMI bridge)
//     |     +-- eh2_veer (core)
//     |     +-- eh2_mem (internal memory: DCCM/ICCM/ICache)
//     +-- axi4_slave_mem (LSU memory - data)
//     +-- axi4_slave_mem (IFU memory - instruction)
//     +-- axi4_slave_mem (SB memory - debug system bus)
//
// Mailbox convention:
//   Address 0xD0580000: write 0xFF/0x02 = PASS, 0x01/0x03 = FAIL
//   0x02/0x03 are riscv-dv CORE_STATUS TEST_PASS/TEST_FAIL codes.
//   Other printable chars are console output

`include "uvm_macros.svh"
import uvm_pkg::*;

// Ensure UVM packages with tests/sequences register their factory entries.
// VCS auto-elaborates all packages found in the filelist, but NC (ncelab) only
// elaborates packages actually referenced from a top-level module — without
// this import every `uvm_component_utils/`uvm_object_utils registration in
// the test package would be dropped, leading to "test not found" at run time.
import core_eh2_test_pkg::*;

`ifndef RVVI_NHART
`define RVVI_NHART 1
`endif

// Include parameter defines for RV_* macros
// common_defines.vh provides `define RV_* macros used throughout the design
// eh2_pdef.vh provides the eh2_param_t struct definition
// Both are passed as compilation units via the filelist

module core_eh2_tb_top;

  //--------------------------------------------------------------------------
  // DUT hierarchy macros (for internal signal probing)
  //--------------------------------------------------------------------------
  `define DEC dut.veer.dec
  `define EXU dut.veer.exu

  //--------------------------------------------------------------------------
  // Clock and Reset
  //--------------------------------------------------------------------------
  bit core_clk;
  initial begin
    core_clk = 0;
    forever #5 core_clk = ~core_clk;  // 100MHz
  end

  logic rst_l;       // Active-low reset
  logic porst_l;     // Power-on reset (active-low)

  //--------------------------------------------------------------------------
  // DUT Signals
  //--------------------------------------------------------------------------

  //--------------------------------------------------------------------------
  // DUT Signal Declarations (DUT, JTAG, trace, debug, AXI4 LSU/IFU/SB/DMA)
  //--------------------------------------------------------------------------
  `include "core_eh2_dut_signals.svh"


  //--------------------------------------------------------------------------
  // Mailbox Detection
  //--------------------------------------------------------------------------
  logic        mailbox_write;
  logic [63:0] mailbox_data;
  logic [31:0] mailbox_addr;
  logic        mailbox_trace_write;
  logic [63:0] mailbox_trace_data;
  logic [31:0] mailbox_trace_addr;
  logic        mailbox_axi_write;
  logic [63:0] mailbox_axi_data;
  logic [31:0] mailbox_axi_addr;
  event mailbox_test_pass;
  event mailbox_test_fail;
  bit   mailbox_test_done = 0;
  string early_bin_path;
  logic  early_bin_loaded = 0;
  logic [`RV_NUM_THREADS-1:0][1:0] nb_load_retire_tag_valid_wb1;
  logic [`RV_NUM_THREADS-1:0][1:0][3:0] nb_load_retire_tag_wb1;
  logic        lsu_trace_store_write;
  logic        lsu_trace_store_tid;
  logic [31:0] lsu_trace_store_addr;
  logic [31:0] lsu_trace_store_wdata;
  logic [3:0]  lsu_trace_store_wmask;
  logic [63:0] lsu_trace_store_shifted;

  assign mailbox_trace_write = lsu_trace_store_write;
  assign mailbox_trace_addr  = lsu_trace_store_addr;
  assign mailbox_trace_data  = {32'b0, lsu_trace_store_wdata};

  assign mailbox_axi_write = lsu_axi_awvalid && lsu_axi_awready;
  assign mailbox_axi_addr  = lsu_axi_awaddr;
  assign mailbox_axi_data  = lsu_axi_wdata;

  // Prefer the committed LSU store trace.  The AXI AW/W channels are
  // decoupled, and debug/interrupt interleavings can retire the PASS store
  // without an AW+WDATA sample in the same cycle.  Keep the AXI path only as
  // a fallback for any early external signature writes.
  assign mailbox_write = mailbox_trace_write || mailbox_axi_write;
  assign mailbox_addr  = mailbox_trace_write ? mailbox_trace_addr : mailbox_axi_addr;
  assign mailbox_data  = mailbox_trace_write ? mailbox_trace_data : mailbox_axi_data;

  core_eh2_tb_intf tb_intf (.clk(core_clk), .rst_n(rst_l));

  assign tb_intf.mailbox_write     = mailbox_write;
  assign tb_intf.mailbox_addr      = mailbox_addr;
  assign tb_intf.mailbox_data      = mailbox_data;
  assign tb_intf.mailbox_test_done = mailbox_test_done;
  assign tb_intf.early_bin_loaded  = early_bin_loaded;

  always @(tb_intf.mem_write_req) begin
    lsu_mem.mem[tb_intf.mem_write_addr] = tb_intf.mem_write_data;
    ifu_mem.mem[tb_intf.mem_write_addr] = tb_intf.mem_write_data;
    sb_mem.mem[tb_intf.mem_write_addr]  = tb_intf.mem_write_data;
    tb_intf.mem_write_done_id = tb_intf.mem_write_req_id;
  end

  always_ff @(posedge core_clk or negedge rst_l) begin
    if (!rst_l) begin
      nb_load_retire_tag_valid_wb1 <= '0;
      nb_load_retire_tag_wb1       <= '0;
    end else begin
      for (int h = 0; h < `RV_NUM_THREADS; h++) begin
        nb_load_retire_tag_valid_wb1[h][0] <=
            `DEC.decode.wbd.i0valid & `DEC.decode.wbd.i0load &
            (`DEC.decode.wbd.i0tid == h[0]);
        nb_load_retire_tag_valid_wb1[h][1] <=
            `DEC.decode.wbd.i1valid & `DEC.decode.wbd.i1load &
            (`DEC.decode.wbd.i1tid == h[0]);
        nb_load_retire_tag_wb1[h][0] <= `DEC.lsu_nonblock_load_inv_tag_dc5;
        nb_load_retire_tag_wb1[h][1] <= `DEC.lsu_nonblock_load_inv_tag_dc5;
      end
    end
  end

  // Trace commit monitor
  always @(posedge core_clk) begin
    if (rst_l && (trace_rv_i_valid_ip[0][0] || trace_rv_i_valid_ip[0][1])) begin
      $display("TRACE_COMMIT: i0=%b i1=%b at %0t", trace_rv_i_valid_ip[0][0], trace_rv_i_valid_ip[0][1], $time);
    end
  end

  // Mailbox monitor - pass/fail detection
  // Uses events instead of $finish so UVM report_phase/final_phase run properly
  always @(posedge core_clk) begin
    if (rst_l && mailbox_write && mailbox_addr == 32'hD0580000) begin
      $display("MAILBOX WRITE detected at %0t: data=%08x", $time, mailbox_data);
      if (mailbox_data[7:0] == 8'hFF ||
          mailbox_data[31:0] == 32'h0000_0002) begin
        $display("========================================");
        $display("TEST PASSED (mailbox)");
        $display("========================================");
        mailbox_test_done = 1;
        ->mailbox_test_pass;
      end else if (mailbox_data[7:0] == 8'h01 ||
                   mailbox_data[31:0] == 32'h0000_0003) begin
        $display("========================================");
        $display("TEST FAILED (mailbox)");
        $display("========================================");
        mailbox_test_done = 1;
        ->mailbox_test_fail;
      end else if (mailbox_data[7:0] >= 8'h20 && mailbox_data[7:0] < 8'h7F) begin
        // Console output (printable ASCII)
        $write("%c", mailbox_data[7:0]);
      end
    end
  end

  //--------------------------------------------------------------------------
  // Reset Generation
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
    // mpc_debug_halt_req/run_req/reset_run_req driven by eh2_halt_run_intf (assign below)
    // i_cpu_halt_req/run_req driven by eh2_halt_run_intf (assign below)
    lsu_bus_clk_en     = 1;
    ifu_bus_clk_en     = 1;
    dbg_bus_clk_en     = 1;
    dma_bus_clk_en     = 1;
    void'($value$plusargs("reset_vector=%h", reset_vector));
  end

  //--------------------------------------------------------------------------
  // Early Binary Loading (before clock starts, matching reference testbench)
  // Load hex file into all three AXI4 slave memories at time 0 so the
  // core sees valid instructions on its very first fetch after reset.
  //--------------------------------------------------------------------------
  initial begin
    if ($value$plusargs("bin=%s", early_bin_path) && early_bin_path.len() > 0) begin
      // Only load .hex files early; raw binaries still go through UVM
      if (early_bin_path.len() > 4 &&
          early_bin_path.substr(early_bin_path.len()-4, early_bin_path.len()-1) == ".hex") begin
        $display("TB_TOP: Early-loading hex file: %s", early_bin_path);
        $readmemh(early_bin_path, lsu_mem.mem);
        $readmemh(early_bin_path, ifu_mem.mem);
        $readmemh(early_bin_path, sb_mem.mem);
        early_bin_loaded = 1;
        $display("TB_TOP: Early binary load complete");
      end
    end
  end

  //--------------------------------------------------------------------------
  // DUT Instantiation
  //--------------------------------------------------------------------------
  eh2_veer_wrapper dut (
    .clk                    (core_clk),
    .rst_l                  (rst_l),
    .dbg_rst_l              (porst_l),
    .rst_vec                (reset_vector[31:1]),
    .nmi_int                (nmi_int),
    .nmi_vec                (nmi_vector[31:1]),
    .jtag_id                (jtag_id[31:1]),

    // Trace
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

    // DMA AXI4 (tied off - no DMA master in basic tests)
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

    // JTAG
    .jtag_tck          (jtag_tck),
    .jtag_tms          (jtag_tms),
    .jtag_tdi          (jtag_tdi),
    .jtag_trst_n       (jtag_trst_n),
    .jtag_tdo          (jtag_tdo),

    // Interrupts
    .timer_int         (timer_int),
    .soft_int          (soft_int),
    .extintsrc_req     (extintsrc_req),

    // Clock enables
    .lsu_bus_clk_en    (lsu_bus_clk_en),
    .ifu_bus_clk_en    (ifu_bus_clk_en),
    .dbg_bus_clk_en    (dbg_bus_clk_en),
    .dma_bus_clk_en    (dma_bus_clk_en),

    // External memory packets (tied off - internal memories used)
    .dccm_ext_in_pkt   ('0),
    .iccm_ext_in_pkt   ('0),
    .btb_ext_in_pkt    ('0),
    .ic_data_ext_in_pkt('0),
    .ic_tag_ext_in_pkt ('0),

    // MPC halt/run
    .mpc_debug_halt_req (mpc_debug_halt_req),
    .mpc_debug_run_req  (mpc_debug_run_req),
    .mpc_reset_run_req  (mpc_reset_run_req),
    .mpc_debug_halt_ack (mpc_debug_halt_ack),
    .mpc_debug_run_ack  (mpc_debug_run_ack),
    .debug_brkpt_status (debug_brkpt_status),
    .dec_tlu_mhartstart (dec_tlu_mhartstart),

    // CPU halt/run
    .i_cpu_halt_req    (i_cpu_halt_req),
    .o_cpu_halt_ack    (o_cpu_halt_ack),
    .o_cpu_halt_status (o_cpu_halt_status),
    .i_cpu_run_req     (i_cpu_run_req),
    .o_cpu_run_ack     (o_cpu_run_ack),

    // Debug status
    .o_debug_mode_status (o_debug_mode_status),

    // Performance counters
    .dec_tlu_perfcnt0  (dec_tlu_perfcnt0),
    .dec_tlu_perfcnt1  (dec_tlu_perfcnt1),
    .dec_tlu_perfcnt2  (dec_tlu_perfcnt2),
    .dec_tlu_perfcnt3  (dec_tlu_perfcnt3),

    // Misc
    .core_id           ('0),
    .scan_mode         (1'b0),
    .mbist_mode        (1'b0)
  );

  //--------------------------------------------------------------------------
  // Memory Models
  //--------------------------------------------------------------------------

  // LSU memory (data) - connected to LSU AXI4 master port
  axi4_slave_mem #(
    .ADDR_WIDTH (32),
    .DATA_WIDTH (64),
    .ID_WIDTH   (`RV_LSU_BUS_TAG),
    .MEM_SIZE   (64 * 1024 * 1024)
  ) lsu_mem (
    .clk      (core_clk),
    .rst_n    (rst_l),
    .error_inject_mode (lsu_axi_intf.error_inject_mode),
    .force_bresp       (lsu_axi_intf.force_bresp),
    .force_rresp       (lsu_axi_intf.force_rresp),
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

  // IFU memory (instruction) - connected to IFU AXI4 master port
  axi4_slave_mem #(
    .ADDR_WIDTH (32),
    .DATA_WIDTH (64),
    .ID_WIDTH   (`RV_IFU_BUS_TAG),
    .MEM_SIZE   (64 * 1024 * 1024)
  ) ifu_mem (
    .clk      (core_clk),
    .rst_n    (rst_l),
    .error_inject_mode (ifu_axi_intf.error_inject_mode),
    .force_bresp       (ifu_axi_intf.force_bresp),
    .force_rresp       (ifu_axi_intf.force_rresp),
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

  // SB memory (debug system bus) - connected to SB AXI4 master port
  axi4_slave_mem #(
    .ADDR_WIDTH (32),
    .DATA_WIDTH (64),
    .ID_WIDTH   (`RV_SB_BUS_TAG),
    .MEM_SIZE   (64 * 1024 * 1024)
  ) sb_mem (
    .clk      (core_clk),
    .rst_n    (rst_l),
    .error_inject_mode (sb_axi_intf.error_inject_mode),
    .force_bresp       (sb_axi_intf.force_bresp),
    .force_rresp       (sb_axi_intf.force_rresp),
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

  // DMA port: no external DMA master — tie all inputs to inactive values.
  // OUTPUTS are driven by the DUT only (do NOT assign — that caused multi-driver X).
  // AW channel inputs
  assign dma_axi_awvalid = 1'b0;
  assign dma_axi_awid    = '0;
  assign dma_axi_awaddr  = '0;
  assign dma_axi_awsize  = '0;
  assign dma_axi_awprot  = '0;
  assign dma_axi_awlen   = '0;
  assign dma_axi_awburst = '0;
  // W channel inputs
  assign dma_axi_wvalid  = 1'b0;
  assign dma_axi_wdata   = '0;
  assign dma_axi_wstrb   = '0;
  assign dma_axi_wlast   = '0;
  // B channel input
  assign dma_axi_bready  = 1'b0;
  // AR channel inputs
  assign dma_axi_arvalid = 1'b0;
  assign dma_axi_arid    = '0;
  assign dma_axi_araddr  = '0;
  assign dma_axi_arsize  = '0;
  assign dma_axi_arprot  = '0;
  assign dma_axi_arlen   = '0;
  assign dma_axi_arburst = '0;
  // R channel input
  assign dma_axi_rready  = 1'b0;

  //--------------------------------------------------------------------------
  // Safety Timeout (UVM handles timeouts via the test - this is a last resort)
  //--------------------------------------------------------------------------
  initial begin
    #(64'd1_800_000_000_000);  // 30 minutes safety timeout (matches env_cfg.timeout_ns)
    $display("========================================");
    $display("SAFETY TIMEOUT (TB top) - 30 minutes");
    $display("========================================");
    $finish;
  end

  //--------------------------------------------------------------------------
  // Trace Monitor (simplified)
  //--------------------------------------------------------------------------
  always_ff @(posedge core_clk) begin
    if (rst_l && !mailbox_test_done) begin
      if (trace_rv_i_valid_ip[0][0]) begin
        $display("TRACE: t0.i0 PC=%h INSN=%h", trace_rv_i_address_ip[0][31:0], trace_rv_i_insn_ip[0][31:0]);
      end
      if (trace_rv_i_valid_ip[0][1]) begin
        $display("TRACE: t0.i1 PC=%h INSN=%h", trace_rv_i_address_ip[0][63:32], trace_rv_i_insn_ip[0][63:32]);
      end
    end
  end

  //--------------------------------------------------------------------------
  // AXI4 Interface Instances (for UVM agents)
  // Use DUT's actual tag widths to avoid truncation/extension issues
  //--------------------------------------------------------------------------
  axi4_intf #(.ADDR_WIDTH(32), .DATA_WIDTH(64), .ID_WIDTH(`RV_LSU_BUS_TAG))
    lsu_axi_intf (.clk(core_clk), .rst_n(rst_l));

  axi4_intf #(.ADDR_WIDTH(32), .DATA_WIDTH(64), .ID_WIDTH(`RV_IFU_BUS_TAG))
    ifu_axi_intf (.clk(core_clk), .rst_n(rst_l));

  axi4_intf #(.ADDR_WIDTH(32), .DATA_WIDTH(64), .ID_WIDTH(`RV_SB_BUS_TAG))
    sb_axi_intf (.clk(core_clk), .rst_n(rst_l));

  // Connect interface signals to DUT wires
  // LSU interface
  assign lsu_axi_intf.awvalid  = lsu_axi_awvalid;
  assign lsu_axi_intf.awready  = lsu_axi_awready;
  assign lsu_axi_intf.awid     = lsu_axi_awid;
  assign lsu_axi_intf.awaddr   = lsu_axi_awaddr;
  assign lsu_axi_intf.awlen    = lsu_axi_awlen;
  assign lsu_axi_intf.awsize   = lsu_axi_awsize;
  assign lsu_axi_intf.awburst  = lsu_axi_awburst;
  assign lsu_axi_intf.awlock   = lsu_axi_awlock;
  assign lsu_axi_intf.awcache  = lsu_axi_awcache;
  assign lsu_axi_intf.awprot   = lsu_axi_awprot;
  assign lsu_axi_intf.awregion = lsu_axi_awregion;
  assign lsu_axi_intf.awqos    = lsu_axi_awqos;
  assign lsu_axi_intf.wvalid   = lsu_axi_wvalid;
  assign lsu_axi_intf.wready   = lsu_axi_wready;
  assign lsu_axi_intf.wdata    = lsu_axi_wdata;
  assign lsu_axi_intf.wstrb    = lsu_axi_wstrb;
  assign lsu_axi_intf.wlast    = lsu_axi_wlast;
  assign lsu_axi_intf.bvalid   = lsu_axi_bvalid;
  assign lsu_axi_intf.bready   = lsu_axi_bready;
  assign lsu_axi_intf.bresp    = lsu_axi_bresp;
  assign lsu_axi_intf.bid      = lsu_axi_bid;
  assign lsu_axi_intf.arvalid  = lsu_axi_arvalid;
  assign lsu_axi_intf.arready  = lsu_axi_arready;
  assign lsu_axi_intf.arid     = lsu_axi_arid;
  assign lsu_axi_intf.araddr   = lsu_axi_araddr;
  assign lsu_axi_intf.arlen    = lsu_axi_arlen;
  assign lsu_axi_intf.arsize   = lsu_axi_arsize;
  assign lsu_axi_intf.arburst  = lsu_axi_arburst;
  assign lsu_axi_intf.arlock   = lsu_axi_arlock;
  assign lsu_axi_intf.arcache  = lsu_axi_arcache;
  assign lsu_axi_intf.arprot   = lsu_axi_arprot;
  assign lsu_axi_intf.arregion = lsu_axi_arregion;
  assign lsu_axi_intf.arqos    = lsu_axi_arqos;
  assign lsu_axi_intf.rvalid   = lsu_axi_rvalid;
  assign lsu_axi_intf.rready   = lsu_axi_rready;
  assign lsu_axi_intf.rid      = lsu_axi_rid;
  assign lsu_axi_intf.rdata    = lsu_axi_rdata;
  assign lsu_axi_intf.rresp    = lsu_axi_rresp;
  assign lsu_axi_intf.rlast    = lsu_axi_rlast;

  // IFU interface
  assign ifu_axi_intf.awvalid  = ifu_axi_awvalid;
  assign ifu_axi_intf.awready  = ifu_axi_awready;
  assign ifu_axi_intf.awid     = ifu_axi_awid;
  assign ifu_axi_intf.awaddr   = ifu_axi_awaddr;
  assign ifu_axi_intf.awlen    = ifu_axi_awlen;
  assign ifu_axi_intf.awsize   = ifu_axi_awsize;
  assign ifu_axi_intf.awburst  = ifu_axi_awburst;
  assign ifu_axi_intf.awlock   = ifu_axi_awlock;
  assign ifu_axi_intf.awcache  = ifu_axi_awcache;
  assign ifu_axi_intf.awprot   = ifu_axi_awprot;
  assign ifu_axi_intf.awregion = ifu_axi_awregion;
  assign ifu_axi_intf.awqos    = ifu_axi_awqos;
  assign ifu_axi_intf.wvalid   = ifu_axi_wvalid;
  assign ifu_axi_intf.wready   = ifu_axi_wready;
  assign ifu_axi_intf.wdata    = ifu_axi_wdata;
  assign ifu_axi_intf.wstrb    = ifu_axi_wstrb;
  assign ifu_axi_intf.wlast    = ifu_axi_wlast;
  assign ifu_axi_intf.bvalid   = ifu_axi_bvalid;
  assign ifu_axi_intf.bready   = ifu_axi_bready;
  assign ifu_axi_intf.bresp    = ifu_axi_bresp;
  assign ifu_axi_intf.bid      = ifu_axi_bid;
  assign ifu_axi_intf.arvalid  = ifu_axi_arvalid;
  assign ifu_axi_intf.arready  = ifu_axi_arready;
  assign ifu_axi_intf.arid     = ifu_axi_arid;
  assign ifu_axi_intf.araddr   = ifu_axi_araddr;
  assign ifu_axi_intf.arlen    = ifu_axi_arlen;
  assign ifu_axi_intf.arsize   = ifu_axi_arsize;
  assign ifu_axi_intf.arburst  = ifu_axi_arburst;
  assign ifu_axi_intf.arlock   = ifu_axi_arlock;
  assign ifu_axi_intf.arcache  = ifu_axi_arcache;
  assign ifu_axi_intf.arprot   = ifu_axi_arprot;
  assign ifu_axi_intf.arregion = ifu_axi_arregion;
  assign ifu_axi_intf.arqos    = ifu_axi_arqos;
  assign ifu_axi_intf.rvalid   = ifu_axi_rvalid;
  assign ifu_axi_intf.rready   = ifu_axi_rready;
  assign ifu_axi_intf.rid      = ifu_axi_rid;
  assign ifu_axi_intf.rdata    = ifu_axi_rdata;
  assign ifu_axi_intf.rresp    = ifu_axi_rresp;
  assign ifu_axi_intf.rlast    = ifu_axi_rlast;

  // SB interface
  assign sb_axi_intf.awvalid  = sb_axi_awvalid;
  assign sb_axi_intf.awready  = sb_axi_awready;
  assign sb_axi_intf.awid     = sb_axi_awid;
  assign sb_axi_intf.awaddr   = sb_axi_awaddr;
  assign sb_axi_intf.awlen    = sb_axi_awlen;
  assign sb_axi_intf.awsize   = sb_axi_awsize;
  assign sb_axi_intf.awburst  = sb_axi_awburst;
  assign sb_axi_intf.awlock   = sb_axi_awlock;
  assign sb_axi_intf.awcache  = sb_axi_awcache;
  assign sb_axi_intf.awprot   = sb_axi_awprot;
  assign sb_axi_intf.awregion = sb_axi_awregion;
  assign sb_axi_intf.awqos    = sb_axi_awqos;
  assign sb_axi_intf.wvalid   = sb_axi_wvalid;
  assign sb_axi_intf.wready   = sb_axi_wready;
  assign sb_axi_intf.wdata    = sb_axi_wdata;
  assign sb_axi_intf.wstrb    = sb_axi_wstrb;
  assign sb_axi_intf.wlast    = sb_axi_wlast;
  assign sb_axi_intf.bvalid   = sb_axi_bvalid;
  assign sb_axi_intf.bready   = sb_axi_bready;
  assign sb_axi_intf.bresp    = sb_axi_bresp;
  assign sb_axi_intf.bid      = sb_axi_bid;
  assign sb_axi_intf.arvalid  = sb_axi_arvalid;
  assign sb_axi_intf.arready  = sb_axi_arready;
  assign sb_axi_intf.arid     = sb_axi_arid;
  assign sb_axi_intf.araddr   = sb_axi_araddr;
  assign sb_axi_intf.arlen    = sb_axi_arlen;
  assign sb_axi_intf.arsize   = sb_axi_arsize;
  assign sb_axi_intf.arburst  = sb_axi_arburst;
  assign sb_axi_intf.arlock   = sb_axi_arlock;
  assign sb_axi_intf.arcache  = sb_axi_arcache;
  assign sb_axi_intf.arprot   = sb_axi_arprot;
  assign sb_axi_intf.arregion = sb_axi_arregion;
  assign sb_axi_intf.arqos    = sb_axi_arqos;
  assign sb_axi_intf.rvalid   = sb_axi_rvalid;
  assign sb_axi_intf.rready   = sb_axi_rready;
  assign sb_axi_intf.rid      = sb_axi_rid;
  assign sb_axi_intf.rdata    = sb_axi_rdata;
  assign sb_axi_intf.rresp    = sb_axi_rresp;
  assign sb_axi_intf.rlast    = sb_axi_rlast;

  //--------------------------------------------------------------------------
  // Trace Interface Instance (for UVM trace monitor)
  //--------------------------------------------------------------------------
  eh2_trace_intf #(.NUM_THREADS(`RV_NUM_THREADS))
    trace_intf (.clk(core_clk), .rst_n(rst_l));

  // Connect trace interface to DUT trace signals
  assign trace_intf.insn      = trace_rv_i_insn_ip;
  assign trace_intf.address   = trace_rv_i_address_ip;
  assign trace_intf.valid     = trace_rv_i_valid_ip;
  assign trace_intf.exception = trace_rv_i_exception_ip;
  assign trace_intf.ecause    = trace_rv_i_ecause_ip;
  assign trace_intf.interrupt = trace_rv_i_interrupt_ip;
  assign trace_intf.tval      = trace_rv_i_tval_ip;
  assign trace_intf.rd_valid  = trace_rv_i_rd_valid_ip;
  assign trace_intf.rd_addr   = trace_rv_i_rd_addr_ip;
  assign trace_intf.rd_wdata  = trace_rv_i_rd_wdata_ip;

  //--------------------------------------------------------------------------
  // Standard RVVI-TRACE Interface (DUT side only; reference side starts MR2)
  //--------------------------------------------------------------------------
  rvviTrace #(
    .ILEN   (32),
    .XLEN   (32),
    .FLEN   (32),
    .VLEN   (256),
    .NHART  (`RVVI_NHART),
    .RETIRE (2)
  ) rvvi();

  assign rvvi.clk = core_clk;  // CHECK: EH2 main clock for retire trace.

  //--------------------------------------------------------------------------
  // RVFI Interface Instance (for RVFI-equivalent trace monitoring)
  //--------------------------------------------------------------------------
  eh2_rvfi_if rvfi_intf (.clk(core_clk), .rst_l(rst_l));

  //--------------------------------------------------------------------------
  // LSU bus valid signal (derived from AXI4 LSU transactions)
  //--------------------------------------------------------------------------
  logic lsu_bus_valid;
  logic [31:0] lsu_bus_addr;
  logic [31:0] lsu_bus_rdata;
  logic [31:0] lsu_bus_wdata;
  logic [3:0]  lsu_bus_wmask;
  logic        lsu_bus_write;

  assign lsu_bus_valid = (lsu_axi_awvalid && lsu_axi_awready) || (lsu_axi_arvalid && lsu_axi_arready) || (lsu_axi_wvalid && lsu_axi_wready) || (lsu_axi_rvalid && lsu_axi_rready);
  assign lsu_bus_addr  = lsu_axi_awvalid ? lsu_axi_awaddr : lsu_axi_araddr;
  assign lsu_bus_rdata = lsu_axi_rdata[31:0];
  assign lsu_bus_wdata = lsu_axi_wdata[31:0];
  assign lsu_bus_wmask = lsu_axi_wstrb[3:0];
  assign lsu_bus_write = lsu_axi_awvalid && lsu_axi_awready;

  assign lsu_trace_store_write =
      dut.veer.lsu.lsu_pkt_dc5.valid &
      dut.veer.lsu.lsu_commit_dc5 &
      ((dut.veer.lsu.lsu_pkt_dc5.store) |
       (dut.veer.lsu.lsu_pkt_dc5.atomic & ~dut.veer.lsu.lsu_pkt_dc5.lr)) &
      (~dut.veer.lsu.lsu_pkt_dc5.sc | dut.veer.lsu.lsu_sc_success_dc5);
  assign lsu_trace_store_tid = dut.veer.lsu.lsu_pkt_dc5.tid;
  assign lsu_trace_store_addr = dut.veer.lsu.lsu_addr_dc5;
  assign lsu_trace_store_shifted =
      dut.veer.lsu.store_data_ext_dc5 >> {dut.veer.lsu.lsu_addr_dc5[1:0], 3'b000};
  assign lsu_trace_store_wdata = lsu_trace_store_shifted[31:0];
  assign lsu_trace_store_wmask =
      ({4{dut.veer.lsu.lsu_pkt_dc5.by}}   & 4'h1) |
      ({4{dut.veer.lsu.lsu_pkt_dc5.half}} & 4'h3) |
      ({4{dut.veer.lsu.lsu_pkt_dc5.word |
           dut.veer.lsu.lsu_pkt_dc5.dword |
           dut.veer.lsu.lsu_pkt_dc5.atomic}} & 4'hf);

  //--------------------------------------------------------------------------
  // RVFI Converter Instance (Trace + LSU -> Standard RVFI format)
  //--------------------------------------------------------------------------
  eh2_veer_wrapper_rvfi u_rvfi_converter (
    .clk              (core_clk),
    .rst_n            (rst_l),

    // Trace inputs from DUT
    .trace_insn       (trace_rv_i_insn_ip[0]),
    .trace_address    (trace_rv_i_address_ip[0]),
    .trace_valid      (trace_rv_i_valid_ip[0]),
    .trace_exception  (trace_rv_i_exception_ip[0]),
    .trace_ecause     (trace_rv_i_ecause_ip[0]),
    .trace_interrupt  (trace_rv_i_interrupt_ip[0]),
    .trace_tval       (trace_rv_i_tval_ip[0]),
    .trace_rd_valid   (trace_rv_i_rd_valid_ip[0]),
    .trace_rd_addr    (trace_rv_i_rd_addr_ip[0]),
    .trace_rd_wdata   (trace_rv_i_rd_wdata_ip[0]),

    // LSU bus inputs
    .lsu_bus_valid    (lsu_bus_valid),
    .lsu_bus_addr     (lsu_bus_addr),
    .lsu_bus_rdata    (lsu_bus_rdata),
    .lsu_bus_wdata    (lsu_bus_wdata),
    .lsu_bus_wmask    (lsu_bus_wmask),
    .lsu_bus_write    (lsu_bus_write),

    // RVFI output -> interface
    .rvfi_valid       (rvfi_intf.rvfi_valid),
    .rvfi_order       (rvfi_intf.rvfi_order),
    .rvfi_insn        (rvfi_intf.rvfi_insn),
    .rvfi_pc_rdata    (rvfi_intf.rvfi_pc_rdata),
    .rvfi_pc_wdata    (rvfi_intf.rvfi_pc_wdata),
    .rvfi_rs1_addr    (rvfi_intf.rvfi_rs1_addr),
    .rvfi_rs2_addr    (rvfi_intf.rvfi_rs2_addr),
    .rvfi_rd_addr     (rvfi_intf.rvfi_rd_addr),
    .rvfi_rd_wdata    (rvfi_intf.rvfi_rd_wdata),
    .rvfi_mem_addr    (rvfi_intf.rvfi_mem_addr),
    .rvfi_mem_rdata   (rvfi_intf.rvfi_mem_rdata),
    .rvfi_mem_wdata   (rvfi_intf.rvfi_mem_wdata),
    .rvfi_mem_rmask   (rvfi_intf.rvfi_mem_rmask),
    .rvfi_mem_wmask   (rvfi_intf.rvfi_mem_wmask),
    .rvfi_trap        (rvfi_intf.rvfi_trap),
    .rvfi_intr        (rvfi_intf.rvfi_intr),
    .rvfi_mode        (rvfi_intf.rvfi_mode)
  );

  //--------------------------------------------------------------------------
  // DUT Probe Interface Instance (for register writeback monitoring)
  //--------------------------------------------------------------------------
  eh2_dut_probe_if #(.NUM_THREADS(`RV_NUM_THREADS))
    dut_probe_intf (.clk(core_clk), .rst_n(rst_l));

  // Connect DUT probe signals to internal DUT hierarchy.
  // Phase 1 note: regular wb_valid/wb_dest/wb_data/wb_suppress fields are no
  // longer probed here — they ride along the RTL trace packet now (ADR-0004).
  // Only async writeback (DIV / NB-load) and CSR/exception mirror state are
  // exposed via this interface.

  generate
    for (genvar ph = 0; ph < `RV_NUM_THREADS; ph++) begin : g_dut_probe_hart
      assign dut_probe_intf.div_cancel[ph] =
          `DEC.dec_div_cancel & (`DEC.dec_div_tid == ph[0]);
      assign dut_probe_intf.div_cancel_overwrite[ph] =
          `DEC.dec_div_cancel_overwrite & (`DEC.dec_div_tid == ph[0]);
      assign dut_probe_intf.div_issue_valid[ph] =
          dut.veer.div_p.valid & (dut.veer.div_p.tid == ph[0]);
      assign dut_probe_intf.div_issue_rd[ph] = `DEC.decode.i0r.rd;
      assign dut_probe_intf.div_issue_rs1[ph] = dut.veer.exu.div_rs1_d;
      assign dut_probe_intf.div_issue_rs2[ph] = dut.veer.exu.div_rs2_d;
      assign dut_probe_intf.div_issue_unsigned[ph] = dut.veer.div_p.unsign;
      assign dut_probe_intf.div_issue_rem[ph] = dut.veer.div_p.rem;
      assign dut_probe_intf.div_rd[ph]     = `DEC.decode.div_rd;
      assign dut_probe_intf.div_result[ph] = `EXU.div_e1.out_raw[31:0];
      assign dut_probe_intf.div_wren[ph] =
          dut.veer.exu_div_wren & (`DEC.div_tid_wb == ph[0]);
      assign dut_probe_intf.div_wdata[ph]  = dut.veer.exu_div_result[31:0];

      assign dut_probe_intf.nb_load_alloc_valid[ph] =
          `DEC.lsu_nonblock_load_valid_dc1 & (`DEC.decode.nonblock_load_tid_dc1 == ph[0]);
      assign dut_probe_intf.nb_load_alloc_rd[ph] =
          `DEC.decode.nonblock_load_rd;
      assign dut_probe_intf.nb_load_alloc_tag[ph] =
          `DEC.lsu_nonblock_load_tag_dc1;
      assign dut_probe_intf.nb_load_retire_tag_valid[ph][0] =
          nb_load_retire_tag_valid_wb1[ph][0];
      assign dut_probe_intf.nb_load_retire_tag_valid[ph][1] =
          nb_load_retire_tag_valid_wb1[ph][1];
      assign dut_probe_intf.nb_load_retire_tag[ph][0] =
          nb_load_retire_tag_wb1[ph][0];
      assign dut_probe_intf.nb_load_retire_tag[ph][1] =
          nb_load_retire_tag_wb1[ph][1];
      assign dut_probe_intf.nb_load_wen[ph]   = `DEC.dec_nonblock_load_wen[ph];
      assign dut_probe_intf.nb_load_waddr[ph] = `DEC.dec_nonblock_load_waddr[ph];
      assign dut_probe_intf.nb_load_data_valid[ph] =
          `DEC.lsu_nonblock_load_data_valid & (`DEC.lsu_nonblock_load_data_tid == ph[0]);
      assign dut_probe_intf.nb_load_data[ph]  = `DEC.lsu_nonblock_load_data;
      assign dut_probe_intf.nb_load_data_tag[ph] =
          `DEC.lsu_nonblock_load_data_tag;

      // Interrupt/NMI/debug state for cosim notification.
      // Construct MIP: bit 11 = MEIP, bit 7 = MTIP, bit 3 = MSIP.
      // CHECK: EH2 PIC external interrupt pending is global here; per-hart
      // external routing can be tightened when a per-hart MEIP probe is exposed.
      assign dut_probe_intf.mip[ph] =
          {20'b0, extintsrc_req[1], 3'b0, timer_int[ph], 3'b0, soft_int[ph], 3'b0};
      assign dut_probe_intf.nmi[ph]       = nmi_int;
      assign dut_probe_intf.nmi_int[ph]   = nmi_int;
      assign dut_probe_intf.debug_req[ph] = mpc_debug_halt_req[ph];

      assign dut_probe_intf.mcycle[ph] =
          {dut.veer.dec.tlu.tlumt[ph].tlu.mcycleh[31:0],
           dut.veer.dec.tlu.tlumt[ph].tlu.mcyclel[31:0]};

      // CSR signals - probed from per-thread TLU internal registers.
      assign dut_probe_intf.mstatus[ph] =
          {19'b0, 2'b11, 3'b0,
           dut.veer.dec.tlu.tlumt[ph].tlu.mstatus[1],
           3'b0,
           dut.veer.dec.tlu.tlumt[ph].tlu.mstatus[0],
           3'b0};
      assign dut_probe_intf.mtvec[ph] =
          {dut.veer.dec.tlu.tlumt[ph].tlu.mtvec[30:1],
           1'b0,
           dut.veer.dec.tlu.tlumt[ph].tlu.mtvec[0]};
      assign dut_probe_intf.mepc[ph] =
          {dut.veer.dec.tlu.tlumt[ph].tlu.mepc[31:1], 1'b0};
      assign dut_probe_intf.mcause[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.mcause[31:0];
      assign dut_probe_intf.mtval[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.mtval[31:0];

      assign dut_probe_intf.mret_e4[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.mret_e4;
      assign dut_probe_intf.illegal_e4[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.illegal_e4;
      assign dut_probe_intf.ecall_e4[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.ecall_e4;
      assign dut_probe_intf.ebreak_e4[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.ebreak_e4;
      assign dut_probe_intf.ebreak_to_debug_e4[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.ebreak_to_debug_mode_e4;
      assign dut_probe_intf.inst_acc_e4[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.inst_acc_e4;

      assign dut_probe_intf.mret_wb[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.mret_wb;
      assign dut_probe_intf.illegal_wb[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.illegal_wb;
      assign dut_probe_intf.ecall_wb[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.ecall_wb;
      assign dut_probe_intf.ebreak_wb[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.ebreak_wb;

      assign dut_probe_intf.debug_mode[ph] =
          dut.veer.dec.dec_tlu_debug_mode[ph];
      assign dut_probe_intf.dbg_halted[ph] =
          dut.veer.dec.dec_tlu_dbg_halted[ph];

      assign dut_probe_intf.interrupt_valid[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.interrupt_valid;
      assign dut_probe_intf.take_ext_int[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.take_ext_int;
      assign dut_probe_intf.take_timer_int[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.take_timer_int;
      assign dut_probe_intf.take_soft_int[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.take_soft_int;
      assign dut_probe_intf.take_nmi[ph] =
          dut.veer.dec.tlu.tlumt[ph].tlu.take_nmi;
    end
  endgenerate

  //--------------------------------------------------------------------------
  // EH2 trace/RVFI/probe to standard RVVI-TRACE adapter
  //--------------------------------------------------------------------------
  eh2_rvvi_adapter #(
    .NUM_THREADS (`RV_NUM_THREADS),
    .NHART       (`RVVI_NHART),
    .RETIRE      (2)
  ) u_rvvi_adapter (
    .clk             (core_clk),
    .rst_l           (rst_l),
    .rvvi            (rvvi),
    .trace_insn      (trace_rv_i_insn_ip),
    .trace_address   (trace_rv_i_address_ip),
    .trace_valid     (trace_rv_i_valid_ip),
    .trace_exception (trace_rv_i_exception_ip),
    .trace_ecause    (trace_rv_i_ecause_ip),
    .trace_interrupt (trace_rv_i_interrupt_ip),
    .trace_rd_valid  (trace_rv_i_rd_valid_ip),
    .trace_rd_addr   (trace_rv_i_rd_addr_ip),
    .trace_rd_wdata  (trace_rv_i_rd_wdata_ip),
    .csr_mstatus     (dut_probe_intf.mstatus),
    .csr_mtvec       (dut_probe_intf.mtvec),
    .csr_mepc        (dut_probe_intf.mepc),
    .csr_mcause      (dut_probe_intf.mcause),
    .csr_mtval       (dut_probe_intf.mtval),
    .csr_mip         (dut_probe_intf.mip),
    .debug_mode      (dut_probe_intf.debug_mode),
    .csr_wen         (dut.veer.dec.dec_i0_csr_wen_wb),
    .csr_waddr       (dut.veer.dec.dec_i0_csr_wraddr_wb),
    .csr_wdata       (dut.veer.dec.dec_i0_csr_wrdata_wb),
    .csr_wtid        (dut.veer.dec.decode.dec_i0_tid_wb),
    .nb_load_alloc_valid (dut_probe_intf.nb_load_alloc_valid),
    .nb_load_alloc_rd    (dut_probe_intf.nb_load_alloc_rd),
    .nb_load_alloc_tag   (dut_probe_intf.nb_load_alloc_tag),
    .nb_load_retire_tag_valid (dut_probe_intf.nb_load_retire_tag_valid),
    .nb_load_retire_tag  (dut_probe_intf.nb_load_retire_tag),
    .nb_load_wen         (dut_probe_intf.nb_load_wen),
    .nb_load_waddr       (dut_probe_intf.nb_load_waddr),
    .nb_load_data_valid  (dut_probe_intf.nb_load_data_valid),
    .nb_load_data        (dut_probe_intf.nb_load_data),
    .nb_load_data_tag    (dut_probe_intf.nb_load_data_tag),
    .div_issue_valid (dut_probe_intf.div_issue_valid),
    .div_issue_rd    (dut_probe_intf.div_issue_rd),
    .div_issue_rs1   (dut_probe_intf.div_issue_rs1),
    .div_issue_rs2   (dut_probe_intf.div_issue_rs2),
    .div_issue_unsigned (dut_probe_intf.div_issue_unsigned),
    .div_issue_rem   (dut_probe_intf.div_issue_rem),
    .div_wren        (dut_probe_intf.div_wren),
    .div_rd          (dut_probe_intf.div_rd),
    .div_wdata       (dut_probe_intf.div_wdata),
    .div_cancel      (dut_probe_intf.div_cancel),
    .div_cancel_overwrite (dut_probe_intf.div_cancel_overwrite),
    .div_result      (dut_probe_intf.div_result),
    .lsu_bus_write   (lsu_trace_store_write),
    .lsu_bus_tid     (lsu_trace_store_tid),
    .lsu_bus_addr    (lsu_trace_store_addr),
    .lsu_bus_wdata   (lsu_trace_store_wdata),
    .lsu_bus_wmask   (lsu_trace_store_wmask)
  );

  rvvi_cac_bridge #(
    .NHART  (`RVVI_NHART),
    .RETIRE (2),
    .XLEN   (32)
  ) u_rvvi_cac_bridge (
    .clk   (core_clk),
    .rst_l (rst_l),
    .rvvi  (rvvi)
  );

  //--------------------------------------------------------------------------
  // IRQ Interface Instance (for interrupt stimulus)
  //--------------------------------------------------------------------------
  eh2_irq_intf #(
    .NUM_THREADS  (`RV_NUM_THREADS),
    .PIC_TOTAL_INT(`RV_PIC_TOTAL_INT)
  ) irq_intf (.clk(core_clk), .rst_n(rst_l));

  // Connect IRQ interface to DUT interrupt signals
  assign timer_int     = irq_intf.timer_int;
  assign soft_int      = irq_intf.soft_int;
  assign extintsrc_req = irq_intf.extintsrc_req;
  assign nmi_int       = irq_intf.nmi_int;

  //--------------------------------------------------------------------------
  // JTAG Interface Instance (for debug stimulus)
  //--------------------------------------------------------------------------
  eh2_jtag_intf jtag_intf (.clk(core_clk), .rst_n(rst_l));

  // Connect JTAG interface to DUT JTAG signals
  assign jtag_tck    = jtag_intf.tck;
  assign jtag_tms    = jtag_intf.tms;
  assign jtag_tdi    = jtag_intf.tdi;
  assign jtag_trst_n = jtag_intf.trst_n;
  assign jtag_intf.tdo = jtag_tdo;

  //--------------------------------------------------------------------------
  // Halt/Run Interface Instance (for halt/run stimulus)
  //--------------------------------------------------------------------------
  eh2_halt_run_intf halt_run_vif (.clk(core_clk), .rst_n(rst_l));

  // Connect halt/run interface to DUT signals
  assign mpc_debug_halt_req = halt_run_vif.mpc_debug_halt_req;
  assign mpc_debug_run_req  = halt_run_vif.mpc_debug_run_req;
  assign mpc_reset_run_req  = halt_run_vif.mpc_reset_run_req;
  assign i_cpu_halt_req     = halt_run_vif.i_cpu_halt_req;
  assign i_cpu_run_req      = halt_run_vif.i_cpu_run_req;

  // Feed acknowledgment signals back to interface
  assign halt_run_vif.o_cpu_halt_ack     = o_cpu_halt_ack[0];
  assign halt_run_vif.o_cpu_run_ack      = o_cpu_run_ack[0];
  assign halt_run_vif.o_cpu_halt_status  = o_cpu_halt_status[0];
  assign halt_run_vif.o_debug_mode_status = o_debug_mode_status[0];

  //--------------------------------------------------------------------------
  // Fetch Enable Interface Instance (for fetch-enable toggling)
  //--------------------------------------------------------------------------
  fetch_enable_intf fetch_en_intf();

  //--------------------------------------------------------------------------
  // Functional Coverage Interface Instance
  //--------------------------------------------------------------------------
  eh2_fcov_if u_fcov_if (
    .clk_i                    (core_clk),
    .rst_l_i                  (rst_l),

    // Pipeline valids (from eh2_dec internal signals)
    .dec_ib0_valid_d          (dut.veer.dec.dec_ib0_valid_d),
    .dec_ib1_valid_d          (dut.veer.dec.dec_ib1_valid_d),
    .dec_i1_valid_e1          (dut.veer.dec.dec_i1_valid_e1),
    .dec_tlu_i0_valid_e4      (dut.veer.dec.tlu.tlumt[0].tlu.dec_tlu_i0_valid_e4),
    .dec_tlu_i1_valid_e4      (dut.veer.dec.tlu.tlumt[0].tlu.dec_tlu_i1_valid_e4),
    .tlu_i0_commit_cmt        (dut.veer.dec.tlu.tlumt[0].tlu.tlu_i0_commit_cmt),
    .tlu_i1_commit_cmt        (dut.veer.dec.tlu.tlumt[0].tlu.tlu_i1_commit_cmt),

    // Instructions at decode
    .dec_i0_instr_d            (dut.veer.dec.dec_i0_instr_d),
    .dec_i1_instr_d            (dut.veer.dec.dec_i1_instr_d),
    .dec_i0_pc4_d              (dut.veer.dec.dec_i0_pc4_d),
    .dec_i1_pc4_d              (dut.veer.dec.dec_i1_pc4_d),

    // Decode packets (from decode_ctl instance)
    .i0_dec                    (dut.veer.dec.decode.i0_dp),
    .i1_dec                    (dut.veer.dec.decode.i1_dp),

    // Branch signals (inputs to TLU)
    .exu_pmu_i0_br_misp        (dut.veer.dec.tlu.tlumt[0].tlu.exu_pmu_i0_br_misp),
    .exu_pmu_i0_br_ataken      (dut.veer.dec.tlu.tlumt[0].tlu.exu_pmu_i0_br_ataken),
    .exu_pmu_i1_br_misp        (dut.veer.dec.tlu.tlumt[0].tlu.exu_pmu_i1_br_misp),
    .exu_pmu_i1_br_ataken      (dut.veer.dec.tlu.tlumt[0].tlu.exu_pmu_i1_br_ataken),
    .exu_i0_br_valid_e4        (dut.veer.dec.exu_i0_br_valid_e4),
    .exu_i1_br_valid_e4        (dut.veer.dec.exu_i1_br_valid_e4),
    .exu_i0_br_mp_e4           (dut.veer.dec.tlu.tlumt[0].tlu.exu_i0_br_mp_e4),
    .exu_i1_br_mp_e4           (dut.veer.dec.exu_i1_br_mp_e4),

    // Flushes (inputs to decode, outputs of TLU)
    .exu_flush_final           (dut.veer.dec.exu_flush_final[0]),
    .exu_i0_flush_final        (dut.veer.dec.exu_i0_flush_final[0]),
    .exu_i1_flush_final        (dut.veer.dec.exu_i1_flush_final[0]),
    .dec_tlu_flush_lower_wb    (dut.veer.dec.dec_tlu_flush_lower_wb[0]),
    .dec_tlu_flush_mp_wb       (dut.veer.dec.dec_tlu_flush_mp_wb[0]),

    // Stall signals (inputs to TLU)
    .lsu_load_stall_any        (dut.veer.lsu_load_stall_any[0]),
    .lsu_store_stall_any       (dut.veer.dec.tlu.tlumt[0].tlu.lsu_store_stall_any),
    .lsu_amo_stall_any         (dut.veer.lsu_amo_stall_any[0]),
    .dec_pmu_decode_stall      (dut.veer.dec.tlu.tlumt[0].tlu.dec_pmu_decode_stall),
    .dec_pmu_presync_stall     (dut.veer.dec.tlu.tlumt[0].tlu.dec_pmu_presync_stall),
    .dec_pmu_postsync_stall    (dut.veer.dec.tlu.tlumt[0].tlu.dec_pmu_postsync_stall),
    .ifu_pmu_fetch_stall       (dut.veer.dec.tlu.tlumt[0].tlu.ifu_pmu_fetch_stall),

    // Exceptions (TLU internal)
    .i0_exception_valid_e4     (dut.veer.dec.tlu.tlumt[0].tlu.i0_exception_valid_e4),
    .lsu_exc_valid_e4          (dut.veer.dec.tlu.tlumt[0].tlu.lsu_exc_valid_e4),
    .ebreak_e4                 (dut.veer.dec.tlu.tlumt[0].tlu.ebreak_e4),
    .ecall_e4                  (dut.veer.dec.tlu.tlumt[0].tlu.ecall_e4),
    .illegal_e4                (dut.veer.dec.tlu.tlumt[0].tlu.illegal_e4),
    .mret_e4                   (dut.veer.dec.tlu.tlumt[0].tlu.mret_e4),
    .inst_acc_e4               (dut.veer.dec.tlu.tlumt[0].tlu.inst_acc_e4),

    // Interrupts (TLU internal)
    .interrupt_valid           (dut.veer.dec.tlu.tlumt[0].tlu.interrupt_valid),
    .take_ext_int              (dut.veer.dec.tlu.tlumt[0].tlu.take_ext_int),
    .take_timer_int            (dut.veer.dec.tlu.tlumt[0].tlu.take_timer_int),
    .take_soft_int             (dut.veer.dec.tlu.tlumt[0].tlu.take_soft_int),
    .take_nmi                  (dut.veer.dec.tlu.tlumt[0].tlu.take_nmi),
    .take_ce_int               (dut.veer.dec.tlu.tlumt[0].tlu.take_ce_int),

    // Debug (decode output)
    .dec_tlu_dbg_halted        (dut.veer.dec.dec_tlu_dbg_halted[0]),
    .dec_tlu_debug_mode        (dut.veer.dec.dec_tlu_debug_mode[0]),

    // PIC (TLU internal)
    .dec_tlu_meicurpl          (dut.veer.dec.tlu.tlumt[0].tlu.tlu_meicurpl),
    .dec_tlu_meicidpl          (dut.veer.dec.tlu.tlumt[0].tlu.meicidpl[3:0]),

    // LSU PMU (inputs to TLU)
    .lsu_pmu_misaligned_dc3    (dut.veer.lsu_pmu_misaligned_dc3[0]),
    .lsu_pmu_load_external_dc3 (dut.veer.dec.tlu.tlumt[0].tlu.lsu_pmu_load_external_dc3),
    .lsu_pmu_store_external_dc3(dut.veer.dec.tlu.tlumt[0].tlu.lsu_pmu_store_external_dc3),

    // Cache PMU (inputs to TLU)
    .ifu_pmu_ic_miss           (dut.veer.dec.tlu.tlumt[0].tlu.ifu_pmu_ic_miss),
    .ifu_pmu_ic_hit            (dut.veer.dec.tlu.tlumt[0].tlu.ifu_pmu_ic_hit)
  );

  //--------------------------------------------------------------------------
  // PMP Functional Coverage Interface Instance
  //--------------------------------------------------------------------------
  // The default EH2 configuration used by this platform does not implement
  // PMP/ePMP, but the interface is instantiated to keep the coverage scaffold
  // complete and ready for PMP-enabled configurations.
  eh2_pmp_fcov_if #(
    .PMPEnable      (1'b0),
    .PMPGranularity (0),
    .PMPNumRegions  (4)
  ) u_pmp_fcov_if (
    .clk_i          (core_clk),
    .rst_l_i        (rst_l),
    .pmp_cfg_lock   ('0),
    .pmp_cfg_mode   ('0),
    .pmp_cfg_exec   ('0),
    .pmp_cfg_write  ('0),
    .pmp_cfg_read   ('0),
    .pmp_addr       ('0),
    .mseccfg_mml    (1'b0),
    .mseccfg_mmwp   (1'b0),
    .mseccfg_rlb    (1'b0),
    .pmp_iside_err  (1'b0),
    .pmp_dside_err  (1'b0),
    .debug_mode     (dut.veer.dec.dec_tlu_debug_mode[0]),
    .data_req       (1'b0)
  );

  //--------------------------------------------------------------------------
  // CSR Monitoring Interface Instance
  //--------------------------------------------------------------------------
  eh2_csr_if u_csr_if (.clk(core_clk), .rst_n(rst_l));

  // CSR access valid at decode stage
  assign u_csr_if.csr_access = dut.veer.dec.dec_i0_csr_any_unq_d;
  // CSR address at decode (read address = instruction[31:20])
  assign u_csr_if.csr_addr   = dut.veer.dec.dec_i0_csr_rdaddr_d;
  // CSR read data from TLU MUX
  assign u_csr_if.csr_rdata  = dut.veer.dec.dec_i0_csr_rddata_d;
  // CSR write enable at writeback
  assign u_csr_if.csr_wen    = dut.veer.dec.dec_i0_csr_wen_wb;
  // CSR write data at writeback
  assign u_csr_if.csr_wdata  = dut.veer.dec.dec_i0_csr_wrdata_wb;
  // CSR operation type from decode packet
  assign u_csr_if.csr_read   = dut.veer.dec.decode.i0_dp.csr_read;
  assign u_csr_if.csr_write  = dut.veer.dec.decode.i0_dp.csr_write;
  assign u_csr_if.csr_set    = dut.veer.dec.decode.i0_dp.csr_set;
  assign u_csr_if.csr_clr    = dut.veer.dec.decode.i0_dp.csr_clr;

  //--------------------------------------------------------------------------
  // Instruction Monitor Interface Instance
  //--------------------------------------------------------------------------
  eh2_instr_monitor_if u_instr_monitor_if (.clk(core_clk), .rst_n(rst_l));

  // I0 (slot 0) decode stage
  assign u_instr_monitor_if.i0_valid           = dut.veer.dec.dec_ib0_valid_d;
  assign u_instr_monitor_if.i0_instr           = dut.veer.dec.dec_i0_instr_d;
  assign u_instr_monitor_if.i0_compressed      = ~dut.veer.dec.dec_i0_pc4_d;
  assign u_instr_monitor_if.i0_instr_compressed = dut.veer.dec.dec_i0_instr_d[15:0];
  assign u_instr_monitor_if.i0_branch_taken    = dut.veer.dec.exu_i0_br_valid_e4;
  assign u_instr_monitor_if.i0_stall           = dut.veer.dec.tlu.tlumt[0].tlu.dec_pmu_decode_stall;

  // I1 (slot 1) decode stage
  assign u_instr_monitor_if.i1_valid           = dut.veer.dec.dec_ib1_valid_d;
  assign u_instr_monitor_if.i1_instr           = dut.veer.dec.dec_i1_instr_d;
  assign u_instr_monitor_if.i1_compressed      = ~dut.veer.dec.dec_i1_pc4_d;
  assign u_instr_monitor_if.i1_instr_compressed = dut.veer.dec.dec_i1_instr_d[15:0];
  assign u_instr_monitor_if.i1_branch_taken    = dut.veer.dec.exu_i1_br_valid_e4;
  assign u_instr_monitor_if.i1_stall           = dut.veer.dec.tlu.tlumt[0].tlu.dec_pmu_decode_stall;

  // Pipeline control
  assign u_instr_monitor_if.pipe_flush  = dut.veer.dec.exu_flush_final[0];
  assign u_instr_monitor_if.dual_issue  = dut.veer.dec.dec_ib0_valid_d & dut.veer.dec.dec_ib1_valid_d;

  //--------------------------------------------------------------------------
  // UVM Config DB Setup
  //--------------------------------------------------------------------------
  initial begin
    // Store interface references for UVM agents
    uvm_config_db#(virtual core_eh2_tb_intf)::set(null, "*", "tb_vif", tb_intf);
    uvm_config_db#(virtual axi4_intf#(.ID_WIDTH(`RV_LSU_BUS_TAG)))::set(null, "*lsu_agent*", "vif", lsu_axi_intf);
    uvm_config_db#(virtual axi4_intf#(.ID_WIDTH(`RV_IFU_BUS_TAG)))::set(null, "*ifu_agent*", "vif", ifu_axi_intf);
    uvm_config_db#(virtual axi4_intf#(.ID_WIDTH(`RV_SB_BUS_TAG)))::set(null, "*sb_agent*",  "vif", sb_axi_intf);

    // Store trace and DUT probe interfaces
    uvm_config_db#(virtual eh2_trace_intf #(.NUM_THREADS(`RV_NUM_THREADS)))::set(null, "*trace_monitor*", "vif", trace_intf);
    uvm_config_db#(virtual eh2_dut_probe_if #(.NUM_THREADS(`RV_NUM_THREADS)))::set(null, "*dut_probe_monitor*", "vif", dut_probe_intf);

    // Also provide DUT probe interface to trace monitor (for interrupt/debug state sampling)
    uvm_config_db#(virtual eh2_dut_probe_if #(.NUM_THREADS(`RV_NUM_THREADS)))::set(null, "*trace_monitor*", "probe_vif", dut_probe_intf);

    // Store IRQ interface
    uvm_config_db#(virtual eh2_irq_intf)::set(null, "*", "irq_vif", irq_intf);

    // Store JTAG interface
    uvm_config_db#(virtual eh2_jtag_intf)::set(null, "*", "jtag_vif", jtag_intf);

    // Store Halt/Run interface
    uvm_config_db#(virtual eh2_halt_run_intf)::set(null, "*", "halt_run_vif", halt_run_vif);

    // Store fetch enable interface
    uvm_config_db#(virtual fetch_enable_intf)::set(null, "*", "fetch_vif", fetch_en_intf);

    // Store functional coverage interface
    uvm_config_db#(virtual eh2_fcov_if)::set(null, "*", "fcov_vif", u_fcov_if);

    // Store CSR monitoring interface
    uvm_config_db#(virtual eh2_csr_if)::set(null, "*", "csr_vif", u_csr_if);

    // Store instruction monitoring interface
    uvm_config_db#(virtual eh2_instr_monitor_if)::set(null, "*", "instr_monitor_vif", u_instr_monitor_if);

    // Store RVFI interface
    uvm_config_db#(virtual eh2_rvfi_if)::set(null, "*", "rvfi_vif", rvfi_intf);
  end

  //--------------------------------------------------------------------------
  // UVM Test Execution
  //--------------------------------------------------------------------------
  initial begin
    run_test();
  end

endmodule
