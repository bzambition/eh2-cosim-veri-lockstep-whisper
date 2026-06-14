  // Reset vector and NMI
  logic [31:0]  reset_vector;
  logic [31:0]  nmi_vector;
  logic         nmi_int;

  // JTAG
  logic         jtag_tck;
  logic         jtag_tms;
  logic         jtag_tdi;
  logic         jtag_trst_n;
  logic         jtag_tdo;
  logic [31:1]  jtag_id;

  // Trace
  logic [`RV_NUM_THREADS-1:0][63:0] trace_rv_i_insn_ip;
  logic [`RV_NUM_THREADS-1:0][63:0] trace_rv_i_address_ip;
  logic [`RV_NUM_THREADS-1:0][1:0]  trace_rv_i_valid_ip;
  logic [`RV_NUM_THREADS-1:0][1:0]  trace_rv_i_exception_ip;
  logic [`RV_NUM_THREADS-1:0][4:0]  trace_rv_i_ecause_ip;
  logic [`RV_NUM_THREADS-1:0][1:0]  trace_rv_i_interrupt_ip;
  logic [`RV_NUM_THREADS-1:0][31:0] trace_rv_i_tval_ip;
  // Verification-only RVFI-equivalent writeback view (lane 0 = i0, lane 1 = i1).
  logic [`RV_NUM_THREADS-1:0][1:0]  trace_rv_i_rd_valid_ip;
  logic [`RV_NUM_THREADS-1:0][9:0]  trace_rv_i_rd_addr_ip;
  logic [`RV_NUM_THREADS-1:0][63:0] trace_rv_i_rd_wdata_ip;

  // Debug/Control
  logic [`RV_NUM_THREADS-1:0] o_debug_mode_status;
  logic [`RV_NUM_THREADS-1:0] o_cpu_halt_ack;
  logic [`RV_NUM_THREADS-1:0] o_cpu_halt_status;
  logic [`RV_NUM_THREADS-1:0] o_cpu_run_ack;
  logic [`RV_NUM_THREADS-1:0] mpc_debug_halt_req;
  logic [`RV_NUM_THREADS-1:0] mpc_debug_run_req;
  logic [`RV_NUM_THREADS-1:0] mpc_reset_run_req;
  logic [`RV_NUM_THREADS-1:0] mpc_debug_halt_ack;
  logic [`RV_NUM_THREADS-1:0] mpc_debug_run_ack;
  logic [`RV_NUM_THREADS-1:0] debug_brkpt_status;
  logic [`RV_NUM_THREADS-1:0] dec_tlu_mhartstart;
  logic [`RV_NUM_THREADS-1:0] i_cpu_run_req;

  // Performance counters
  logic [`RV_NUM_THREADS-1:0][1:0] dec_tlu_perfcnt0;
  logic [`RV_NUM_THREADS-1:0][1:0] dec_tlu_perfcnt1;
  logic [`RV_NUM_THREADS-1:0][1:0] dec_tlu_perfcnt2;
  logic [`RV_NUM_THREADS-1:0][1:0] dec_tlu_perfcnt3;

  // Interrupts
  logic [`RV_NUM_THREADS-1:0] timer_int;
  logic [`RV_NUM_THREADS-1:0] soft_int;
  logic [`RV_PIC_TOTAL_INT:1] extintsrc_req;

  // Clock enables
  logic        lsu_bus_clk_en;
  logic        ifu_bus_clk_en;
  logic        dbg_bus_clk_en;
  logic        dma_bus_clk_en;

  //--------------------------------------------------------------------------
  // AXI4 Signals - LSU Port
  //--------------------------------------------------------------------------
  wire                            lsu_axi_awvalid;
  wire                            lsu_axi_awready;
  wire [`RV_LSU_BUS_TAG-1:0]     lsu_axi_awid;
  wire [31:0]                     lsu_axi_awaddr;
  wire [3:0]                      lsu_axi_awregion;
  wire [7:0]                      lsu_axi_awlen;
  wire [2:0]                      lsu_axi_awsize;
  wire [1:0]                      lsu_axi_awburst;
  wire                            lsu_axi_awlock;
  wire [3:0]                      lsu_axi_awcache;
  wire [2:0]                      lsu_axi_awprot;
  wire [3:0]                      lsu_axi_awqos;
  wire                            lsu_axi_wvalid;
  wire                            lsu_axi_wready;
  wire [63:0]                     lsu_axi_wdata;
  wire [7:0]                      lsu_axi_wstrb;
  wire                            lsu_axi_wlast;
  wire                            lsu_axi_bvalid;
  wire                            lsu_axi_bready;
  wire [1:0]                      lsu_axi_bresp;
  wire [`RV_LSU_BUS_TAG-1:0]     lsu_axi_bid;
  wire                            lsu_axi_arvalid;
  wire                            lsu_axi_arready;
  wire [`RV_LSU_BUS_TAG-1:0]     lsu_axi_arid;
  wire [31:0]                     lsu_axi_araddr;
  wire [3:0]                      lsu_axi_arregion;
  wire [7:0]                      lsu_axi_arlen;
  wire [2:0]                      lsu_axi_arsize;
  wire [1:0]                      lsu_axi_arburst;
  wire                            lsu_axi_arlock;
  wire [3:0]                      lsu_axi_arcache;
  wire [2:0]                      lsu_axi_arprot;
  wire [3:0]                      lsu_axi_arqos;
  wire                            lsu_axi_rvalid;
  wire                            lsu_axi_rready;
  wire [`RV_LSU_BUS_TAG-1:0]     lsu_axi_rid;
  wire [63:0]                     lsu_axi_rdata;
  wire [1:0]                      lsu_axi_rresp;
  wire                            lsu_axi_rlast;

  //--------------------------------------------------------------------------
  // AXI4 Signals - IFU Port
  //--------------------------------------------------------------------------
  wire                            ifu_axi_awvalid;
  wire                            ifu_axi_awready;
  wire [`RV_IFU_BUS_TAG-1:0]     ifu_axi_awid;
  wire [31:0]                     ifu_axi_awaddr;
  wire [3:0]                      ifu_axi_awregion;
  wire [7:0]                      ifu_axi_awlen;
  wire [2:0]                      ifu_axi_awsize;
  wire [1:0]                      ifu_axi_awburst;
  wire                            ifu_axi_awlock;
  wire [3:0]                      ifu_axi_awcache;
  wire [2:0]                      ifu_axi_awprot;
  wire [3:0]                      ifu_axi_awqos;
  wire                            ifu_axi_wvalid;
  wire                            ifu_axi_wready;
  wire [63:0]                     ifu_axi_wdata;
  wire [7:0]                      ifu_axi_wstrb;
  wire                            ifu_axi_wlast;
  wire                            ifu_axi_bvalid;
  wire                            ifu_axi_bready;
  wire [1:0]                      ifu_axi_bresp;
  wire [`RV_IFU_BUS_TAG-1:0]     ifu_axi_bid;
  wire                            ifu_axi_arvalid;
  wire                            ifu_axi_arready;
  wire [`RV_IFU_BUS_TAG-1:0]     ifu_axi_arid;
  wire [31:0]                     ifu_axi_araddr;
  wire [3:0]                      ifu_axi_arregion;
  wire [7:0]                      ifu_axi_arlen;
  wire [2:0]                      ifu_axi_arsize;
  wire [1:0]                      ifu_axi_arburst;
  wire                            ifu_axi_arlock;
  wire [3:0]                      ifu_axi_arcache;
  wire [2:0]                      ifu_axi_arprot;
  wire [3:0]                      ifu_axi_arqos;
  wire                            ifu_axi_rvalid;
  wire                            ifu_axi_rready;
  wire [`RV_IFU_BUS_TAG-1:0]     ifu_axi_rid;
  wire [63:0]                     ifu_axi_rdata;
  wire [1:0]                      ifu_axi_rresp;
  wire                            ifu_axi_rlast;

  //--------------------------------------------------------------------------
  // AXI4 Signals - SB (Debug) Port
  //--------------------------------------------------------------------------
  wire                            sb_axi_awvalid;
  wire                            sb_axi_awready;
  wire [`RV_SB_BUS_TAG-1:0]      sb_axi_awid;
  wire [31:0]                     sb_axi_awaddr;
  wire [3:0]                      sb_axi_awregion;
  wire [7:0]                      sb_axi_awlen;
  wire [2:0]                      sb_axi_awsize;
  wire [1:0]                      sb_axi_awburst;
  wire                            sb_axi_awlock;
  wire [3:0]                      sb_axi_awcache;
  wire [2:0]                      sb_axi_awprot;
  wire [3:0]                      sb_axi_awqos;
  wire                            sb_axi_wvalid;
  wire                            sb_axi_wready;
  wire [63:0]                     sb_axi_wdata;
  wire [7:0]                      sb_axi_wstrb;
  wire                            sb_axi_wlast;
  wire                            sb_axi_bvalid;
  wire                            sb_axi_bready;
  wire [1:0]                      sb_axi_bresp;
  wire [`RV_SB_BUS_TAG-1:0]      sb_axi_bid;
  wire                            sb_axi_arvalid;
  wire                            sb_axi_arready;
  wire [`RV_SB_BUS_TAG-1:0]      sb_axi_arid;
  wire [31:0]                     sb_axi_araddr;
  wire [3:0]                      sb_axi_arregion;
  wire [7:0]                      sb_axi_arlen;
  wire [2:0]                      sb_axi_arsize;
  wire [1:0]                      sb_axi_arburst;
  wire                            sb_axi_arlock;
  wire [3:0]                      sb_axi_arcache;
  wire [2:0]                      sb_axi_arprot;
  wire [3:0]                      sb_axi_arqos;
  wire                            sb_axi_rvalid;
  wire                            sb_axi_rready;
  wire [`RV_SB_BUS_TAG-1:0]      sb_axi_rid;
  wire [63:0]                     sb_axi_rdata;
  wire [1:0]                      sb_axi_rresp;
  wire                            sb_axi_rlast;

  //--------------------------------------------------------------------------
  // AXI4 Signals - DMA Port (tied off)
  //--------------------------------------------------------------------------
  wire                            dma_axi_awvalid;
  wire                            dma_axi_awready;
  wire [`RV_DMA_BUS_TAG-1:0]     dma_axi_awid;
  wire [31:0]                     dma_axi_awaddr;
  wire [2:0]                      dma_axi_awsize;
  wire [2:0]                      dma_axi_awprot;
  wire [7:0]                      dma_axi_awlen;
  wire [1:0]                      dma_axi_awburst;
  wire                            dma_axi_wvalid;
  wire                            dma_axi_wready;
  wire [63:0]                     dma_axi_wdata;
  wire [7:0]                      dma_axi_wstrb;
  wire                            dma_axi_wlast;
  wire                            dma_axi_bvalid;
  wire                            dma_axi_bready;
  wire [1:0]                      dma_axi_bresp;
  wire [`RV_DMA_BUS_TAG-1:0]     dma_axi_bid;
  wire                            dma_axi_arvalid;
  wire                            dma_axi_arready;
  wire [`RV_DMA_BUS_TAG-1:0]     dma_axi_arid;
  wire [31:0]                     dma_axi_araddr;
  wire [2:0]                      dma_axi_arsize;
  wire [2:0]                      dma_axi_arprot;
  wire [7:0]                      dma_axi_arlen;
  wire [1:0]                      dma_axi_arburst;
  wire                            dma_axi_rvalid;
  wire                            dma_axi_rready;
  wire [`RV_DMA_BUS_TAG-1:0]     dma_axi_rid;
  wire [63:0]                     dma_axi_rdata;
  wire [1:0]                      dma_axi_rresp;
  wire                            dma_axi_rlast;
