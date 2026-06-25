// SPDX-License-Identifier: Apache-2.0
// AXI4 Interface for EH2 UVM Verification Platform
//
// This interface defines the AXI4 protocol signals with configurable
// ID width, data width, and address width. It includes clocking blocks
// for UVM driver and monitor.

interface axi4_intf #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 64,
  parameter int ID_WIDTH   = 4
) (
  input logic clk,
  input logic rst_n
);

  // Write Address Channel
  logic [ID_WIDTH-1:0]     awid;
  logic [ADDR_WIDTH-1:0]   awaddr;
  logic [3:0]              awregion;
  logic [7:0]              awlen;
  logic [2:0]              awsize;
  logic [1:0]              awburst;
  logic                    awlock;
  logic [3:0]              awcache;
  logic [2:0]              awprot;
  logic [3:0]              awqos;
  logic                    awvalid;
  logic                    awready;

  // Write Data Channel
  logic [DATA_WIDTH-1:0]   wdata;
  logic [DATA_WIDTH/8-1:0] wstrb;
  logic                    wlast;
  logic                    wvalid;
  logic                    wready;

  // Write Response Channel
  logic [ID_WIDTH-1:0]     bid;
  logic [1:0]              bresp;
  logic                    bvalid;
  logic                    bready;

  // Read Address Channel
  logic [ID_WIDTH-1:0]     arid;
  logic [ADDR_WIDTH-1:0]   araddr;
  logic [3:0]              arregion;
  logic [7:0]              arlen;
  logic [2:0]              arsize;
  logic [1:0]              arburst;
  logic                    arlock;
  logic [3:0]              arcache;
  logic [2:0]              arprot;
  logic [3:0]              arqos;
  logic                    arvalid;
  logic                    arready;

  // Read Data Channel
  logic [ID_WIDTH-1:0]     rid;
  logic [DATA_WIDTH-1:0]   rdata;
  logic [1:0]              rresp;
  logic                    rlast;
  logic                    rvalid;
  logic                    rready;

  // Error injection control (driven by UVM axi4_driver, consumed by axi4_slave_mem)
  logic                    error_inject_mode;
  logic [1:0]              force_bresp;
  logic [1:0]              force_rresp;

  // Default: error injection inactive
  initial begin
    error_inject_mode = 1'b0;
    force_bresp       = 2'b00;
    force_rresp       = 2'b00;
  end

  // Clocking block for response driver (slave side)
  // Drives responses to master requests
  clocking resp_driver_cb @(posedge clk);
    default input #1 ;

    // Input: master requests
    input awid, awaddr, awregion, awlen, awsize, awburst;
    input awlock, awcache, awprot, awqos, awvalid;
    input wdata, wstrb, wlast, wvalid;
    input bready;
    input arid, araddr, arregion, arlen, arsize, arburst;
    input arlock, arcache, arprot, arqos, arvalid;
    input rready;

    // Output: slave responses
    input awready;
    input wready;
    input bid, bresp, bvalid;
    input arready;
    input rid, rdata, rresp, rlast, rvalid;
  endclocking

  // Clocking block for master driver
  // Drives master requests
  clocking master_driver_cb @(posedge clk);
    default input #1;

    // Output: master requests
    input awid, awaddr, awregion, awlen, awsize, awburst;
    input awlock, awcache, awprot, awqos, awvalid;
    input wdata, wstrb, wlast, wvalid;
    input bready;
    input arid, araddr, arregion, arlen, arsize, arburst;
    input arlock, arcache, arprot, arqos, arvalid;
    input rready;

    // Input: slave responses
    input awready;
    input wready;
    input bid, bresp, bvalid;
    input arready;
    input rid, rdata, rresp, rlast, rvalid;
  endclocking

  // Clocking block for monitor
  // Observes all transactions
  clocking monitor_cb @(posedge clk);
    default input #1;

    input awid, awaddr, awregion, awlen, awsize, awburst;
    input awlock, awcache, awprot, awqos, awvalid, awready;
    input wdata, wstrb, wlast, wvalid, wready;
    input bid, bresp, bvalid, bready;
    input arid, araddr, arregion, arlen, arsize, arburst;
    input arlock, arcache, arprot, arqos, arvalid, arready;
    input rid, rdata, rresp, rlast, rvalid, rready;
  endclocking

  // Modport for response agent (slave)
  modport response (
    input clk, rst_n,
    clocking resp_driver_cb
  );

  // Modport for master agent
  modport master (
    input clk, rst_n,
    clocking master_driver_cb
  );

  // Modport for monitor
  modport monitor (
    input clk, rst_n,
    clocking monitor_cb
  );

  //--------------------------------------------------------------------------
  // Protocol Assertions
  //--------------------------------------------------------------------------

  // pragma translate_off
  `ifndef SYNTHESIS

  // AWVALID must remain asserted until AWREADY
  property aw_valid_stable;
    @(posedge clk) disable iff (!rst_n)
    awvalid && !awready |=> awvalid;
  endproperty
  assert property (aw_valid_stable) else
    $error("AXI4: AWVALID deasserted before AWREADY");

  // WVALID must remain asserted until WREADY
  property w_valid_stable;
    @(posedge clk) disable iff (!rst_n)
    wvalid && !wready |=> wvalid;
  endproperty
  assert property (w_valid_stable) else
    $error("AXI4: WVALID deasserted before WREADY");

  // ARVALID must remain asserted until ARREADY
  property ar_valid_stable;
    @(posedge clk) disable iff (!rst_n)
    arvalid && !arready |=> arvalid;
  endproperty
  assert property (ar_valid_stable) else
    $error("AXI4: ARVALID deasserted before ARREADY");

  // BVALID must remain asserted until BREADY
  property b_valid_stable;
    @(posedge clk) disable iff (!rst_n)
    bvalid && !bready |=> bvalid;
  endproperty
  assert property (b_valid_stable) else
    $error("AXI4: BVALID deasserted before BREADY");

  // RVALID must remain asserted until RREADY (or RLAST)
  property r_valid_stable;
    @(posedge clk) disable iff (!rst_n)
    rvalid && !rready |=> rvalid;
  endproperty
  assert property (r_valid_stable) else
    $error("AXI4: RVALID deasserted before RREADY");

  `endif
  // pragma translate_on

endinterface
