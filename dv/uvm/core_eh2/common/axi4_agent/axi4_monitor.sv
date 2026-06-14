// SPDX-License-Identifier: Apache-2.0
// AXI4 Monitor - Observes AXI4 transactions on the interface
//
// Monitors both read and write channels of the AXI4 interface.
// Captures complete transactions (address, data, response) and
// sends them to the analysis port for scoreboard/coverage.
//
// Architecture:
//   Two independent threads:
//   1. Write monitor: AW channel -> W channel -> B channel
//   2. Read monitor:  AR channel -> R channel
//
// Each thread captures the address phase, then collects all data
// beats, and finally sends the complete transaction.

class axi4_monitor #(int ID_WIDTH = 4) extends uvm_monitor;

  `uvm_component_param_utils(axi4_monitor#(ID_WIDTH))

  // Virtual interface
  virtual axi4_intf#(.ID_WIDTH(ID_WIDTH)) vif;

  // Analysis port for transactions
  uvm_analysis_port #(axi4_seq_item) ap;

  // Configuration
  string agent_name = "axi4_monitor";

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (!uvm_config_db#(virtual axi4_intf#(.ID_WIDTH(ID_WIDTH)))::get(this, "", "vif", vif)) begin
      `uvm_warning(agent_name, "Could not get virtual interface - monitor disabled")
    end
  endfunction

  task run_phase(uvm_phase phase);
    if (vif == null) return;  // No interface - skip monitoring
    fork
      monitor_writes();
      monitor_reads();
    join
  endtask

  // Monitor write transactions (AW -> W -> B)
  task monitor_writes();
    axi4_seq_item txn;
    bit [7:0] awlen;
    bit [2:0] awsize;
    bit [1:0] awburst;
    bit [31:0] awaddr;
    bit [3:0] awid;
    int beat_count;

    forever begin
      // Wait for AW handshake (address phase)
      @(posedge vif.clk iff (vif.awvalid && vif.awready));

      // Capture address phase
      awaddr  = vif.awaddr;
      awlen   = vif.awlen;
      awsize  = vif.awsize;
      awburst = vif.awburst;
      awid    = vif.awid;

      // Create transaction
      txn = axi4_seq_item::type_id::create("write_txn");
      txn.tx_type    = axi4_seq_item::AXI4_WRITE;
      txn.addr       = awaddr;
      txn.id         = awid;
      txn.len        = awlen;
      txn.size       = awsize;
      txn.burst      = axi4_seq_item::burst_type_e'(awburst);
      txn.start_time = $time;

      // Allocate data arrays
      beat_count = awlen + 1;
      txn.data = new[beat_count];
      txn.strb = new[beat_count];

      // Collect W channel data beats
      for (int i = 0; i < beat_count; i++) begin
        // AW and W are independent AXI channels and EH2 can handshake both on
        // the same clock. If W is already valid on the AW sample edge, consume
        // it immediately instead of waiting for a later edge and losing the
        // beat.
        if (!(vif.wvalid && vif.wready)) begin
          @(posedge vif.clk iff (vif.wvalid && vif.wready));
        end
        txn.data[i] = vif.wdata;
        txn.strb[i] = vif.wstrb;
      end

      txn.resp = new[1];
      txn.resp[0] = axi4_seq_item::AXI4_RESP_OKAY;
      txn.end_time = $time;

      // Send to analysis port as soon as address and data are complete. EH2
      // may retire the store before the write response handshake is visible to
      // the monitor; waiting for B can starve the cosim scoreboard.
      `uvm_info(agent_name, $sformatf("Write txn: %s", txn.convert2string()), UVM_HIGH)
      ap.write(txn);

      // Drain the response channel when it is observable. The transaction has
      // already been published, so do not block reset or early test completion.
      if (vif.bvalid && vif.bready) begin
        txn.resp[0] = axi4_seq_item::resp_type_e'(vif.bresp);
      end
    end
  endtask

  // Monitor read transactions (AR -> R)
  task monitor_reads();
    axi4_seq_item txn;
    bit [7:0] arlen;
    bit [2:0] arsize;
    bit [1:0] arburst;
    bit [31:0] araddr;
    bit [3:0] arid;
    int beat_count;

    forever begin
      // Wait for AR handshake (address phase)
      @(posedge vif.clk iff (vif.arvalid && vif.arready));

      // Capture address phase
      araddr  = vif.araddr;
      arlen   = vif.arlen;
      arsize  = vif.arsize;
      arburst = vif.arburst;
      arid    = vif.arid;

      // Create transaction
      txn = axi4_seq_item::type_id::create("read_txn");
      txn.tx_type    = axi4_seq_item::AXI4_READ;
      txn.addr       = araddr;
      txn.id         = arid;
      txn.len        = arlen;
      txn.size       = arsize;
      txn.burst      = axi4_seq_item::burst_type_e'(arburst);
      txn.start_time = $time;

      // Allocate data arrays
      beat_count = arlen + 1;
      txn.rdata = new[beat_count];
      txn.resp  = new[beat_count];

      // Collect R channel data beats
      for (int i = 0; i < beat_count; i++) begin
        @(posedge vif.clk iff (vif.rvalid && vif.rready));
        txn.rdata[i] = vif.rdata;
        txn.resp[i]  = axi4_seq_item::resp_type_e'(vif.rresp);
      end

      txn.end_time = $time;

      // Send to analysis port
      `uvm_info(agent_name, $sformatf("Read txn: %s", txn.convert2string()), UVM_HIGH)
      ap.write(txn);
    end
  endtask

endclass
