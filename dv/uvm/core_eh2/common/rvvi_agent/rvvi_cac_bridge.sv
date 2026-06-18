// SPDX-License-Identifier: Apache-2.0
// Generic RVVI-TRACE to external cosim-arch-checker monitor bridge.

module rvvi_cac_bridge #(
  parameter int NHART  = 1,
  parameter int RETIRE = 2,
  parameter int XLEN   = 32
) (
  input logic clk,
  input logic rst_l,
  rvviTrace rvvi
);

  import "DPI-C" context function void env_init();
  import "DPI-C" context function void env_final();
  import "DPI-C" context function void monitor_instr(
      input string name,
      input int hart,
      input longint unsigned cycle,
      input longint unsigned tag,
      input longint unsigned pc,
      input longint unsigned opcode,
      input int unsigned trap);
  import "DPI-C" context function void monitor_gpr(
      input string name,
      input int hart,
      input longint unsigned cycle,
      input int unsigned addr,
      input longint unsigned data);
  import "DPI-C" context function void monitor_csr(
      input string name,
      input int hart,
      input longint unsigned cycle,
      input int unsigned addr,
      input longint unsigned data);
  import "DPI-C" context function void monitor_mem(
      input string name,
      input int hart,
      input longint unsigned cycle,
      input longint unsigned addr,
      input longint unsigned data,
      input int unsigned size,
      input int unsigned mask);
  import "DPI-C" context function void monitor_async(
      input string name,
      input int hart,
      input longint unsigned cycle,
      input longint unsigned mip,
      input int unsigned interrupt,
      input int unsigned debug_mode);

  localparam string MON_NAME = "mon_instr";

  bit enabled;
  bit initialized;
  int rvvi_client;
  longint unsigned cycle_q;
  longint unsigned store_data_q[$];
  int unsigned store_mask_q[$];

  typedef struct {
    longint unsigned addr;
    longint unsigned data;
    int unsigned size;
    int unsigned mask;
  } store_event_t;

  store_event_t store_q[$];

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

  initial begin
    enabled = $test$plusargs("cosim_arch_checker") ||
              $test$plusargs("lockstep_whisper");
    initialized = 1'b0;
    if (enabled) begin
      rvvi_client = rvvi.client_register(1'b1, 1'b1);
      env_init();
      initialized = 1'b1;
    end
  end

  final begin
    if (initialized) begin
      env_final();
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
    if (rst_l && enabled) begin
      for (int h = 0; h < NHART; h++) begin
        while (rvvi.net_pop(rvvi_client, net_name, net_value, net_slot)) begin
          if (net_name == "store_data") begin
            longint unsigned data;
            data = net_value & 64'hffff_ffff;
            store_data_q.push_back(data);
          end else if (net_name == "store_mask") begin
            int unsigned mask;
            mask = net_value & 4'hf;
            store_mask_q.push_back(mask);
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
            if (is_store_insn(rvvi.insn[h][r]) && store_q.size() != 0) begin
              store_event_t store;
              store = store_q.pop_front();
              if (!rvvi.trap[h][r]) begin
                monitor_mem(MON_NAME, h, cycle_q, store.addr, store.data,
                            store.size, store.mask);
              end
            end
            for (int x = 1; x < 32; x++) begin
              if (rvvi.x_wb[h][r][x]) begin
                monitor_gpr(MON_NAME, h, cycle_q, x, rvvi.x_wdata[h][r][x]);
              end
            end
            for (int csr = 0; csr < 4096; csr++) begin
              if (rvvi.csr_wb[h][r][csr]) begin
                monitor_csr(MON_NAME, h, cycle_q, csr, rvvi.csr[h][r][csr]);
              end
            end
            monitor_async(MON_NAME, h, cycle_q, rvvi.csr[h][r][12'h344],
                          rvvi.intr[h][r], rvvi.debug_mode[h][r]);
            monitor_instr(MON_NAME, h, cycle_q, rvvi.order[h][r],
                          rvvi.pc_rdata[h][r], rvvi.insn[h][r],
                          rvvi.trap[h][r]);
          end
        end
      end
    end
  end

endmodule
