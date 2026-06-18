// SPDX-License-Identifier: Apache-2.0
// Generic RVVI-TRACE scoreboard that drives the standard RVVI-API.

module rvvi_scoreboard #(
  parameter int NHART  = 1,
  parameter int RETIRE = 2,
  parameter int XLEN   = 32
) (
  input logic clk,
  input logic rst_l,
  rvviTrace rvvi
);

  import rvviApiPkg::*;

  localparam longint unsigned CFG_WHISPER_PATH        = 1;
  localparam longint unsigned CFG_WHISPER_JSON        = 2;
	  localparam longint unsigned CFG_WHISPER_SERVER_FILE = 3;
	  localparam longint unsigned NET_MIP                 = 12'h344;

  bit enabled;
  bit initialized;
  int rvvi_client;
  longint unsigned cycle_q;
  string rvvi_elf;
  string whisper_path;
  string whisper_json_path;
  string whisper_server_file;

  typedef struct {
    longint unsigned addr;
    longint unsigned data;
    int unsigned size;
    int unsigned mask;
  } store_event_t;

  store_event_t store_q[$];
  longint unsigned store_data_q[$];
  int unsigned store_mask_q[$];

  function automatic bit is_store_insn(input logic [31:0] insn);
    logic [1:0] quadrant;
    logic [2:0] funct3;
    quadrant = insn[1:0];
    funct3 = insn[15:13];
    is_store_insn = (insn[6:0] == 7'h23) ||
                    (quadrant == 2'b00 && funct3 == 3'h6) ||
                    (quadrant == 2'b10 && funct3 == 3'h6);
  endfunction

  function automatic int unsigned mask_to_size(input int unsigned mask);
    int unsigned size;
    size = 0;
    for (int i = 0; i < 32; i++) begin
      if (mask[i]) begin
        size++;
      end
    end
    if (size == 0) begin
      size = 1;
    end
    return size;
  endfunction

  function automatic longint unsigned masked_store_data(
      input longint unsigned data,
      input int unsigned mask);
    longint unsigned result;
    result = '0;
    for (int i = 0; i < 8; i++) begin
      if (mask[i]) begin
        result |= data & (64'hff << (8 * i));
      end
    end
    return result;
  endfunction

  task automatic fail_with_last_error(input string msg_context);
    string err;
    err = rvviErrorGet();
    if (err.len() == 0) begin
      err = msg_context;
    end
    $error("RVVI scoreboard mismatch: %s", err);
    $finish;
  endtask

	  task automatic compare_retire(input int h, input int r);
	    bit ok;
	    if (rvvi.intr[h][r]) begin
	      rvviRefNetSet(NET_MIP, rvvi.csr[h][r][12'h344], h);
	    end
	    if (rvvi.trap[h][r]) begin
      rvviDutTrap(h, rvvi.pc_rdata[h][r], rvvi.insn[h][r]);
    end else begin
      rvviDutRetire(h, rvvi.pc_rdata[h][r], rvvi.insn[h][r],
                    rvvi.debug_mode[h][r]);
    end

    for (int x = 1; x < 32; x++) begin
      if (rvvi.x_wb[h][r][x]) begin
        rvviDutGprSet(h, x, rvvi.x_wdata[h][r][x]);
      end
    end

    for (int csr = 0; csr < 4096; csr++) begin
      if (rvvi.csr_wb[h][r][csr]) begin
        rvviDutCsrSet(h, csr, rvvi.csr[h][r][csr]);
      end
    end

    if (is_store_insn(rvvi.insn[h][r]) && store_q.size() != 0 && !rvvi.trap[h][r]) begin
      store_event_t store;
      store = store_q.pop_front();
      rvviDutBusWrite(h, store.addr, store.data, store.mask);
    end

    if (!rvviRefEventStep(h)) begin
      fail_with_last_error("rvviRefEventStep failed");
    end

    ok = rvviRefPcCompare(h);
    ok = rvviRefInsBinCompare(h) && ok;
    ok = rvviRefGprsCompareWritten(h, RVVI_TRUE) && ok;
    ok = rvviRefCsrsCompare(h) && ok;
    if (!ok) begin
      fail_with_last_error("RVVI compare failed");
    end
  endtask

  initial begin
    enabled = $test$plusargs("cosim_arch_checker") ||
              $test$plusargs("lockstep_whisper");
    initialized = 1'b0;
    if (enabled) begin
      rvvi_client = rvvi.client_register(1'b1, 1'b1);
      if (!rvviVersionCheck(RVVI_API_VERSION)) begin
        $fatal(1, "RVVI-API version mismatch");
      end
      if ($value$plusargs("whisper_path=%s", whisper_path)) begin
        void'(rvviRefConfigSetString(CFG_WHISPER_PATH, whisper_path));
      end
      if ($value$plusargs("whisper_json_path=%s", whisper_json_path)) begin
        void'(rvviRefConfigSetString(CFG_WHISPER_JSON, whisper_json_path));
      end
      if ($value$plusargs("whisper_server_file=%s", whisper_server_file)) begin
        void'(rvviRefConfigSetString(CFG_WHISPER_SERVER_FILE, whisper_server_file));
      end
      if (!$value$plusargs("rvvi_elf=%s", rvvi_elf)) begin
        $fatal(1, "RVVI scoreboard requires +rvvi_elf=<program.elf>");
      end
      if (!rvviRefInit(rvvi_elf)) begin
        fail_with_last_error("rvviRefInit failed");
      end
      initialized = 1'b1;
    end
  end

  final begin
    if (initialized) begin
      void'(rvviRefShutdown());
    end
  end

  always_ff @(posedge clk or negedge rst_l) begin
    if (!rst_l) begin
      cycle_q <= '0;
    end else begin
      cycle_q <= cycle_q + 1;
    end
  end

  always @(posedge clk) begin
    rvvi_mem_access_t mem_access;
    string net_name;
    longint unsigned net_value;
    longint unsigned net_slot;
    if (rst_l && enabled && initialized) begin
      for (int h = 0; h < NHART; h++) begin
        while (rvvi.net_pop(rvvi_client, net_name, net_value, net_slot)) begin
          if (net_name == "store_data") begin
            store_data_q.push_back(net_value & 64'hffff_ffff);
          end else if (net_name == "store_mask") begin
            store_mask_q.push_back(net_value & 4'hf);
          end
        end
        while (rvvi.mem_access_pop(rvvi_client, h, mem_access)) begin
          if (!mem_access.fetch && store_data_q.size() != 0) begin
            store_event_t store;
            store.addr = mem_access.paddr;
            store.data = store_data_q.pop_front();
            store.mask = (store_mask_q.size() != 0) ?
                         store_mask_q.pop_front() :
                         ((1 << mem_access.size) - 1);
            store.data = masked_store_data(store.data, store.mask);
            store.size = mask_to_size(store.mask);
            store_q.push_back(store);
          end
        end
        for (int r = 0; r < RETIRE; r++) begin
          if (rvvi.valid[h][r]) begin
            compare_retire(h, r);
          end
        end
      end
    end
  end

endmodule
