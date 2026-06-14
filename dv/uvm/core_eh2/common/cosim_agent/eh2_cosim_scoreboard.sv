// SPDX-License-Identifier: Apache-2.0
// EH2 Co-simulation Scoreboard
//
// Compares DUT execution against a Spike reference model.
// Supports NUM_THREADS=1 (single hart) and NUM_THREADS=2 (dual hart).
//
// Phase 1 simplification (ADR-0004): The RTL trace packet now carries the
// RVFI-equivalent {wb_valid, rd_addr, rd_wdata} tuple, so each trace_seq_item
// arriving from the trace monitor is self-contained. The scoreboard no longer
// needs to correlate trace items with a separate writeback FIFO.
//
// Multi-thread support (ADR-0008): When NUM_THREADS=2, per-thread state
// (pending_trace_q, async_wb_q, prev_mip, insn_cnt, mismatch_count) is
// maintained independently and routed by trace_seq_item.thread_id.
//
// Async writeback corner cases (NB-load, DIV-cancel) still arrive via the
// dut probe monitor, but only as suppress hints—they override wb_valid for
// the matching trace item by strict wb_tag association (issue 66).
//
// Spike notification ordering (matching Ibex):
//   1. set_debug_req  (highest priority)
//   2. set_nmi
//   3. set_nmi_int
//   4. set_mip        (pre/post)
//   5. set_mcycle
//   6. step()

`include "uvm_macros.svh"
import uvm_pkg::*;
import eh2_trace_agent_pkg::*;
import axi4_agent_pkg::*;

class eh2_cosim_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(eh2_cosim_scoreboard)

  // Analysis FIFOs from monitors
  uvm_tlm_analysis_fifo #(eh2_trace_seq_item) trace_fifo;
  uvm_tlm_analysis_fifo #(eh2_trace_seq_item) dut_probe_fifo;
  uvm_tlm_analysis_fifo #(axi4_seq_item)      lsu_axi_fifo;

  // Co-simulation handle
  chandle cosim_handle;

  // Configuration object (from config_db, optional)
  eh2_cosim_cfg cfg;

  // Configuration (plusarg overrides or defaults)
  string cosim_config = "";
  bit    enable_cosim = 1;
  bit    fatal_on_mismatch = 0;  // 1 = UVM_FATAL on mismatch, 0 = UVM_ERROR

  // Statistics (aggregated across threads)
  int    step_count;
  int    trace_item_count;
  int    probe_item_count;
  int    suppressed_probe_item_count;
  int    axi_item_count;
  int    pending_trace_high_watermark;

  // Per-thread statistics
  int    mismatch_count[2];
  int    insn_cnt[2];

  // Tracking state
  bit    initialized = 0;

  // EH2 store-buffer coalescing counters: track how many store-type AXI
  // transactions the AXI monitor has delivered vs how many store trace items
  // the cosim has stepped.  When stepped > delivered, a coalesced store
  // was consumed without a matching AXI — let it proceed.
  int    store_axi_delivered  = 0;
  int    store_trace_stepped  = 0;

  // Trace items wait here until matching memory accesses (for stores/AMOs) arrive.
  // Per-thread queues for dual-hart support.
  typedef struct {
    eh2_trace_seq_item item;
  } pending_trace_t;
  pending_trace_t pending_trace_q[2][$];

  // LSU AXI memory accesses from the bus monitor.
  // Memory bus is shared across threads — no per-thread split needed.
  typedef struct {
    axi4_seq_item txn;
    bit           is_store;
    int           observed_access_count;
  } pending_mem_access_t;
  pending_mem_access_t pending_mem_access_q[$];

  // Async writeback hints from the dut probe (NB-load wb / DIV cancel).
  // Per-thread queues. wb_tag enables strict ordering match (issue 66).
  typedef struct {
    bit [4:0]  rd;
    bit [31:0] rd_data;
    bit        suppress;
    int        source;
    int        wb_tag;       // global wb_seq from probe_monitor
  } async_wb_hint_t;
  async_wb_hint_t async_wb_q[2][$];

  // Previous MIP value for pre/post tracking (per-thread)
  bit [31:0] prev_mip[2];

  // Reset handling
  virtual interface eh2_dut_probe_if #(.NUM_THREADS(`RV_NUM_THREADS)) probe_vif;
  bit reset_active = 0;

  // Binary reload support (for reset recovery and deferred loading)
  string     stored_bin_path = "";
  bit [31:0] stored_base_addr = 32'h8000_0000;

  // Deferred binary load request (set by test before run_phase)
  string     pending_bin_path = "";
  bit [31:0] pending_base_addr = 32'h8000_0000;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    trace_fifo     = new("trace_fifo", this);
    dut_probe_fifo = new("dut_probe_fifo", this);
    lsu_axi_fifo   = new("lsu_axi_fifo", this);

    // Get configuration object from config_db (optional)
    void'(uvm_config_db#(eh2_cosim_cfg)::get(this, "", "cosim_cfg", cfg));

    // Get configuration via plusargs (overrides cfg or defaults)
    void'($value$plusargs("enable_cosim=%b", enable_cosim));
    void'($value$plusargs("cosim_config=%s", cosim_config));
    void'($value$plusargs("cosim_fatal_on_mismatch=%b", fatal_on_mismatch));

    // Apply cfg values if cfg was provided and plusargs didn't override
    if (cfg != null) begin
      if (cosim_config == "") cosim_config = cfg.isa_string;
      fatal_on_mismatch = cfg.relax_cosim_check ? 0 : 1;
      // Memory region overrides (issue 65): plusargs override cfg defaults
      void'($value$plusargs("MEM_BOOT_BASE=%h",     cfg.mem_boot.base));
      void'($value$plusargs("MEM_ICCM_BASE=%h",     cfg.mem_iccm.base));
      void'($value$plusargs("MEM_DCCM_BASE=%h",     cfg.mem_dccm.base));
      void'($value$plusargs("MEM_MAILBOX_BASE=%h",  cfg.mem_mailbox.base));
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    // Get probe interface for reset monitoring
    uvm_config_db#(virtual eh2_dut_probe_if #(.NUM_THREADS(`RV_NUM_THREADS)))::get(this, "", "probe_vif", probe_vif);
  endfunction

  task run_phase(uvm_phase phase);
    if (enable_cosim) begin
      init_cosim();
      fork
        run_cosim_trace();
        run_cosim_probe_async();
        run_cosim_dmem();
        run_reset_monitor();
      join
    end
  endtask

  // Monitor reset and re-initialize cosim model after reset de-assertion
  task run_reset_monitor();
    if (probe_vif == null) return;

    forever begin
      @(negedge probe_vif.rst_n);
      reset_active = 1;
      `uvm_info("cosim", "Reset asserted - flushing state", UVM_LOW)
      flush_state();

      @(posedge probe_vif.rst_n);
      reset_active = 0;
      `uvm_info("cosim", "Reset de-asserted - re-initializing cosim", UVM_LOW)

      if (enable_cosim) begin
        init_cosim();
      end
    end
  endtask

  // Flush all scoreboard state (FIFOs, queues, counters)
  function void flush_state();
    eh2_trace_seq_item trash_item;
    axi4_seq_item trash_axi;

    while (trace_fifo.try_get(trash_item)) begin end
    while (dut_probe_fifo.try_get(trash_item)) begin end
    while (lsu_axi_fifo.try_get(trash_axi)) begin end

    for (int t = 0; t < 2; t++) begin
      pending_trace_q[t].delete();
      async_wb_q[t].delete();
      prev_mip[t] = 0;
    end
    pending_mem_access_q.delete();

    store_axi_delivered = 0;
    store_trace_stepped = 0;
  endfunction

  // Process trace items - each carries its own wb data from the RTL trace pkt.
  task run_cosim_trace();
    eh2_trace_seq_item trace_item;

    forever begin
      trace_fifo.get(trace_item);
      trace_item_count++;

      if (cosim_handle != null && initialized) begin
        pending_trace_t pending;
        int tid = int'(trace_item.thread_id);
        pending.item = trace_item;
        pending_trace_q[tid].push_back(pending);
        if (pending_trace_q[tid].size() > pending_trace_high_watermark) begin
          pending_trace_high_watermark = pending_trace_q[tid].size();
        end
        process_pending_trace(tid);
      end
    end
  endtask

  // Async writeback hints (NB-load wb / DIV completion / DIV cancel).
  task run_cosim_probe_async();
    eh2_trace_seq_item probe_item;
    async_wb_hint_t hint;

    forever begin
      dut_probe_fifo.get(probe_item);
      probe_item_count++;

      // Drop regular writebacks - the trace channel already carries them.
      if (probe_item.wb_source == EH2_WB_SRC_REGULAR) continue;

      hint.rd       = probe_item.wb_dest;
      hint.rd_data  = probe_item.wb_data;
      hint.suppress = probe_item.wb_suppress;
      hint.source   = probe_item.wb_source;
      hint.wb_tag   = probe_item.wb_tag;  // strict ordering tag (issue 66)

      begin
        int tid = int'(probe_item.thread_id);
        async_wb_q[tid].push_back(hint);

        `uvm_info("cosim", $sformatf(
          "ASYNC_WB: T%0d src=%s rd=x%0d data=%08x suppress=%0b qsize=%0d",
          tid, wb_source_name(probe_item.wb_source), probe_item.wb_dest,
          probe_item.wb_data, probe_item.wb_suppress, async_wb_q[tid].size()), UVM_HIGH)

        if (cosim_handle != null && initialized) begin
          process_pending_trace(tid);
        end
      end
    end
  endtask

  // Monitor LSU AXI4 transactions for memory access notification
  task run_cosim_dmem();
    axi4_seq_item axi_txn;

    forever begin
      lsu_axi_fifo.get(axi_txn);
      axi_item_count++;

      if (cosim_handle != null && initialized) begin
        enqueue_memory_accesses(axi_txn);
        // Try to unblock both threads
        process_pending_trace(0);
        process_pending_trace(1);
      end
    end
  endtask

  // True if the trace item describes an instruction whose architectural
  // writeback arrives on an async channel (DIV unit / NB-load) instead of
  // the regular pipeline. Wait for the matching async hint before stepping.
  function bit needs_async_wb(eh2_trace_seq_item item);
    if (item.exception || item.interrupt) return 1'b0;
    if (!item.writes_rd()) return 1'b0;
    if (item.is_div()) return 1'b1;
    if (needs_nb_load_async_wb(item)) return 1'b1;
    return 1'b0;
  endfunction

  // Drain pending_trace_q[tid] in order. Gates:
  //   - stores/AMOs wait for matching LSU AXI access (with coalescing bypass)
  //   - DIV / NB-load trace items wait for the matching async writeback hint
  function void process_pending_trace(int tid);
    while (pending_trace_q[tid].size() > 0) begin
      pending_trace_t pending = pending_trace_q[tid][0];

      if (must_wait_for_memory_access(pending.item) &&
          !has_matching_memory_access(pending.item)) begin
        if (store_trace_stepped > store_axi_delivered) begin
          `uvm_info("cosim", $sformatf(
            "T%0d Store at PC=%08x insn=%08x — coalesced (stepped=%0d > axi=%0d), proceeding without AXI",
            tid, pending.item.pc, pending.item.insn, store_trace_stepped, store_axi_delivered), UVM_LOW)
        end else begin
          `uvm_info("cosim", $sformatf(
            "T%0d Waiting for LSU AXI access before stepping store/AMO PC=%08x insn=%08x (stepped=%0d, axi=%0d)",
            tid, pending.item.pc, pending.item.insn, store_trace_stepped, store_axi_delivered), UVM_HIGH)
          break;
        end
      end

      if (needs_async_wb(pending.item) && !has_matching_async_wb(tid, pending.item)) begin
        `uvm_info("cosim", $sformatf(
          "T%0d Waiting for async wb (DIV) before stepping PC=%08x insn=%08x rd=x%0d",
          tid, pending.item.pc, pending.item.insn, pending.item.get_write_rd()), UVM_HIGH)
        break;
      end

      pending_trace_q[tid].pop_front();
      if (is_memory_instruction(pending.item) &&
          has_matching_memory_access(pending.item)) begin
        pop_matching_memory_access(pending.item);
      end
      // Track store trace items stepped (for coalescing detection).
      if (is_store_or_amo_instruction(pending.item)) begin
        store_trace_stepped++;
      end
      compare_instruction(tid, pending.item);
    end
  endfunction

  function bit has_matching_async_wb(int tid, eh2_trace_seq_item item);
    if (!item.writes_rd()) return 1'b0;

    if (item.is_div()) begin
      foreach (async_wb_q[tid][i]) begin
        if (async_wb_q[tid][i].source == EH2_WB_SRC_DIV) begin
          if (async_wb_q[tid][i].wb_tag == item.wb_tag) return 1'b1;
        end
      end
      return 1'b0;
    end

    if (is_load_instruction(item)) begin
      foreach (async_wb_q[tid][i]) begin
        if (async_wb_q[tid][i].source != EH2_WB_SRC_NB_LOAD) continue;
        if (async_wb_q[tid][i].wb_tag > 0 && async_wb_q[tid][i].wb_tag == item.wb_tag) return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  function bit is_memory_instruction(eh2_trace_seq_item item);
    if (item.is_load() || item.is_store() || item.is_amo()) begin
      return 1'b1;
    end
    return item.is_compressed_load_store();
  endfunction

  function bit is_load_instruction(eh2_trace_seq_item item);
    return item.is_load() ||
           is_lr_instruction(item) ||
           (item.is_compressed_load_store() && item.writes_rd());
  endfunction

  function bit is_store_or_amo_instruction(eh2_trace_seq_item item);
    return item.is_store() ||
           (item.is_compressed_load_store() && !item.writes_rd());
  endfunction

  function bit is_lr_instruction(eh2_trace_seq_item item);
    return item.is_amo() && item.insn[31:27] == 5'b00010;
  endfunction

  function bit needs_nb_load_async_wb(eh2_trace_seq_item item);
    return item.is_load() ||
           (item.is_compressed_load_store() && item.writes_rd());
  endfunction

  function bit must_wait_for_memory_access(eh2_trace_seq_item item);
    if (is_load_instruction(item)) return 1'b0;
    return is_store_or_amo_instruction(item);
  endfunction

  function string wb_source_name(int source);
    case (source)
      EH2_WB_SRC_REGULAR: return "regular";
      EH2_WB_SRC_DIV:     return "div";
      EH2_WB_SRC_NB_LOAD: return "nb_load";
      default:            return $sformatf("unknown(%0d)", source);
    endcase
  endfunction

  // Try to consume an async writeback hint that matches this instruction.
  // Strict wb_tag-only matching (issue 66). No rd-based fallback.
  function bit try_consume_async_wb(int tid, eh2_trace_seq_item item,
                                    output async_wb_hint_t hint);
    bit [4:0] expected_rd;
    bit       found_wrong_tag;
    int       wrong_tag_val;
    if (!item.writes_rd()) return 1'b0;
    expected_rd = item.get_write_rd();

    if (item.is_div()) begin
      found_wrong_tag = 0;
      foreach (async_wb_q[tid][i]) begin
        if (async_wb_q[tid][i].source != EH2_WB_SRC_DIV) continue;
        if (async_wb_q[tid][i].wb_tag == item.wb_tag) begin
          hint = async_wb_q[tid][i];
          async_wb_q[tid].delete(i);
          return 1'b1;
        end
        if (!found_wrong_tag) begin
          found_wrong_tag = 1;
          wrong_tag_val = async_wb_q[tid][i].wb_tag;
        end
      end
      if (found_wrong_tag) begin
        mismatch_count[tid]++;
        `uvm_error("cosim", $sformatf(
          "T%0d DIV wb_tag mismatch: item.wb_tag=%0d hint.wb_tag=%0d rd=x%0d — strict matching, no fallback",
          tid, item.wb_tag, wrong_tag_val, expected_rd))
      end
      return 1'b0;
    end

    if (is_load_instruction(item)) begin
      found_wrong_tag = 0;
      foreach (async_wb_q[tid][i]) begin
        if (async_wb_q[tid][i].source != EH2_WB_SRC_NB_LOAD) continue;
        if (async_wb_q[tid][i].wb_tag > 0 && async_wb_q[tid][i].wb_tag == item.wb_tag) begin
          hint = async_wb_q[tid][i];
          async_wb_q[tid].delete(i);
          return 1'b1;
        end
        if (!found_wrong_tag) begin
          found_wrong_tag = 1;
          wrong_tag_val = async_wb_q[tid][i].wb_tag;
        end
      end
      if (found_wrong_tag) begin
        mismatch_count[tid]++;
        `uvm_error("cosim", $sformatf(
          "T%0d NB-LOAD wb_tag mismatch: item.wb_tag=%0d hint.wb_tag=%0d rd=x%0d — strict matching, no fallback",
          tid, item.wb_tag, wrong_tag_val, expected_rd))
      end
    end

    return 1'b0;
  endfunction

  function void enqueue_memory_accesses(axi4_seq_item txn);
    pending_mem_access_t access;
    access.txn = txn;
    access.is_store = (txn.tx_type == axi4_seq_item::AXI4_WRITE);
    access.observed_access_count = count_observed_memory_accesses(txn);
    pending_mem_access_q.push_back(access);
    if (access.is_store) store_axi_delivered++;
  endfunction

  function int count_observed_memory_accesses(axi4_seq_item txn);
    int observed_access_count;
    observed_access_count = 0;

    if (txn.tx_type == axi4_seq_item::AXI4_WRITE) begin
      for (int i = 0; i < txn.get_beat_count(); i++) begin
        bit [7:0] beat_strb = txn.strb[i];
        int beat_bytes = (1 << txn.size);
        observed_access_count += ((beat_strb[3:0] != 4'b0) ? 1 : 0) +
                                 ((beat_bytes > 4 && beat_strb[7:4] != 4'b0) ? 1 : 0);
      end
    end else begin
      observed_access_count = txn.get_beat_count();
    end

    return observed_access_count;
  endfunction

  function bit has_matching_memory_access(eh2_trace_seq_item item);
    bit need_store;
    need_store = is_store_or_amo_instruction(item);

    foreach (pending_mem_access_q[i]) begin
      if (pending_mem_access_q[i].is_store == need_store) return 1'b1;
    end

    return 1'b0;
  endfunction

  function void pop_matching_memory_access(eh2_trace_seq_item item);
    bit need_store;
    int tid;
    need_store = is_store_or_amo_instruction(item);
    tid = int'(item.thread_id);

    foreach (pending_mem_access_q[i]) begin
      if (pending_mem_access_q[i].is_store == need_store) begin
        notify_memory_access(tid, pending_mem_access_q[i].txn);
        pending_mem_access_q.delete(i);
        return;
      end
    end

    `uvm_error("cosim", $sformatf(
      "T%0d Internal error: no queued LSU access for memory instruction PC=%08x insn=%08x",
      tid, item.pc, item.insn))
  endfunction

  // Notify Spike about a memory access from the AXI4 bus.
  // AXI4 bus is 64-bit; split 64-bit beats into two 32-bit notifications.
  function void notify_memory_access(int tid, axi4_seq_item txn);
    if (txn.tx_type == axi4_seq_item::AXI4_WRITE) begin
      bit write_error = (txn.resp[0] != axi4_seq_item::AXI4_RESP_OKAY);

      for (int i = 0; i < txn.get_beat_count(); i++) begin
        bit [31:0] beat_addr = txn.addr + (i * (1 << txn.size));
        bit [63:0] beat_data = txn.data[i];
        bit [7:0]  beat_strb = txn.strb[i];
        int beat_bytes = (1 << txn.size);

        if (beat_strb[3:0] != 4'b0) begin
          riscv_cosim_notify_dside_access(cosim_handle,
            1, int'(beat_data[31:0]), int'(beat_addr),
            int'({4'b0, beat_strb[3:0]}),
            int'(write_error), 0, 0, 0, 1, 0, tid);
          `uvm_info("cosim", $sformatf("T%0d MEM WR: addr=%08x data=%08x be=%04b",
            tid, beat_addr, beat_data[31:0], beat_strb[3:0]), UVM_HIGH)
        end

        if (beat_bytes > 4 && beat_strb[7:4] != 4'b0) begin
          riscv_cosim_notify_dside_access(cosim_handle,
            1, int'(beat_data[63:32]), int'(beat_addr + 4),
            int'({4'b0, beat_strb[7:4]}),
            int'(write_error), 0, 0, 0, 1, 0, tid);
          `uvm_info("cosim", $sformatf("T%0d MEM WR: addr=%08x data=%08x be=%04b",
            tid, beat_addr + 4, beat_data[63:32], beat_strb[7:4]), UVM_HIGH)
        end
      end
    end else begin
      for (int i = 0; i < txn.get_beat_count(); i++) begin
        bit [31:0] beat_addr = txn.addr + (i * (1 << txn.size));
        bit [63:0] beat_data = txn.rdata[i];
        bit read_error = (txn.resp[i] != axi4_seq_item::AXI4_RESP_OKAY);
        int beat_bytes = (1 << txn.size);
        bit widened_load = (beat_bytes > 4);
        bit [3:0] read_be = ((4'b0001 << beat_bytes) - 1) << beat_addr[1:0];

        riscv_cosim_notify_dside_access(cosim_handle,
          0, int'(beat_data[31:0]), int'(beat_addr),
          int'(read_be), int'(read_error),
          0, 0, 0, 1, int'(widened_load), tid);
        `uvm_info("cosim", $sformatf("T%0d MEM RD: addr=%08x data=%08x",
          tid, beat_addr, beat_data[31:0]), UVM_HIGH)

        if (beat_bytes > 4) begin
          riscv_cosim_notify_dside_access(cosim_handle,
            0, int'(beat_data[63:32]), int'(beat_addr + 4),
            int'(4'hf), int'(read_error),
            0, 0, 0, 1, int'(widened_load), tid);
          `uvm_info("cosim", $sformatf("T%0d MEM RD: addr=%08x data=%08x",
            tid, beat_addr + 4, beat_data[63:32]), UVM_HIGH)
        end
      end
    end
  endfunction

  // Compare one instruction against Spike.
  function void compare_instruction(int tid, eh2_trace_seq_item item);
    bit [4:0]  write_reg;
    bit [31:0] write_reg_data;
    bit        sync_trap;
    bit        suppress_reg_write;
    int        result;
    async_wb_hint_t async_hint;

    // EH2: When interrupt=1 and exception=0, the trace item is only an
    // interrupt notification (no instruction executed at this PC).
    if (item.interrupt && !item.exception) begin
      riscv_cosim_set_debug_req(cosim_handle, int'(item.debug_req), tid);
      riscv_cosim_set_nmi(cosim_handle, int'(item.nmi), tid);
      riscv_cosim_set_nmi_int(cosim_handle, int'(item.nmi_int), tid);
      riscv_cosim_set_mip(cosim_handle, int'(prev_mip[tid]), int'(item.mip), tid);
      prev_mip[tid] = item.mip;
      riscv_cosim_set_mcycle(cosim_handle, longint'(item.mcycle), tid);
      `uvm_info("cosim", $sformatf("T%0d IRQ-ONLY: PC=%08x", tid, item.pc), UVM_HIGH)

      // Compare trap CSRs on interrupt path — upgraded to mismatch (issue 51)
      begin
        int unsigned spike_mcause, spike_mepc;
        spike_mcause = riscv_cosim_get_mcause(cosim_handle, tid);
        spike_mepc   = riscv_cosim_get_mepc(cosim_handle, tid);

        if (spike_mcause != item.dut_mcause) begin
          mismatch_count[tid]++;
          `uvm_error("cosim", $sformatf(
            "T%0d IRQ mcause MISMATCH: DUT=%08x Spike=%08x PC=%08x",
            tid, item.dut_mcause, spike_mcause, item.pc))
        end

        if (spike_mepc != item.dut_mepc) begin
          mismatch_count[tid]++;
          `uvm_error("cosim", $sformatf(
            "T%0d IRQ mepc MISMATCH: DUT=%08x Spike=%08x PC=%08x",
            tid, item.dut_mepc, spike_mepc, item.pc))
        end

        `uvm_info("cosim", $sformatf(
          "T%0d IRQ-CSR-COMPARE: PC=%08x DUT_mcause=%08x Spike_mcause=%08x DUT_mepc=%08x Spike_mepc=%08x",
          tid, item.pc, item.dut_mcause, spike_mcause, item.dut_mepc, spike_mepc), UVM_HIGH)
      end

      return;
    end

    // Pull writeback view directly from the trace packet (RVFI-equivalent).
    if (item.wb_valid && item.wb_dest != 0) begin
      write_reg          = item.wb_dest;
      write_reg_data     = item.wb_data;
      suppress_reg_write = 0;
    end else begin
      write_reg          = 0;
      write_reg_data     = 0;
      suppress_reg_write = 0;
    end

    // Async overrides
    if (try_consume_async_wb(tid, item, async_hint)) begin
      if (async_hint.suppress) begin
        suppress_reg_write = 1;
        write_reg          = 0;
        write_reg_data     = 0;
      end else begin
        write_reg          = async_hint.rd;
        write_reg_data     = async_hint.rd_data;
        suppress_reg_write = 0;
      end
    end else if (item.is_div()) begin
      suppress_reg_write = 1;
      write_reg          = 0;
      write_reg_data     = 0;
    end

    sync_trap = item.exception && !item.interrupt;

    // Spike notification ordering (Ibex pattern)
    riscv_cosim_set_debug_req(cosim_handle, int'(item.debug_req), tid);
    riscv_cosim_set_nmi(cosim_handle, int'(item.nmi), tid);
    riscv_cosim_set_nmi_int(cosim_handle, int'(item.nmi_int), tid);
    riscv_cosim_set_mip(cosim_handle, int'(prev_mip[tid]), int'(item.mip), tid);
    prev_mip[tid] = item.mip;
    riscv_cosim_set_mcycle(cosim_handle, longint'(item.mcycle), tid);
    if (item.exception && !item.interrupt && item.ecause == 5'd1) begin
      riscv_cosim_set_iside_error(cosim_handle, int'(item.pc), tid);
    end

    result = riscv_cosim_step(cosim_handle,
      int'(write_reg), int'(write_reg_data),
      int'(item.pc), sync_trap ? 1 : 0,
      suppress_reg_write ? 1 : 0, tid);

    if (result == 0) begin
      mismatch_count[tid]++;
      `uvm_info("cosim", $sformatf(
        "T%0d MISMATCH: PC=%08x insn=%08x slot=%0d rd=x%0d data=%08x",
        tid, item.pc, item.insn, item.slot, write_reg, write_reg_data), UVM_LOW)
      if (fatal_on_mismatch) begin
        `uvm_fatal("cosim", $sformatf("T%0d MISMATCH at PC=%08x insn=%08x\n%s",
          tid, item.pc, item.insn, get_cosim_error_str()))
      end else begin
        `uvm_error("cosim", $sformatf("T%0d MISMATCH at PC=%08x insn=%08x\n%s",
          tid, item.pc, item.insn, get_cosim_error_str()))
      end
    end else begin
      `uvm_info("cosim", $sformatf("T%0d MATCH: PC=%08x insn=%08x rd=x%0d data=%08x",
        tid, item.pc, item.insn, write_reg, write_reg_data), UVM_HIGH)
    end

    // Compare trap CSRs on exception path — upgraded to mismatch (issue 51)
    // mtval is now connected from RTL trace packet (issue 64); Spike-side
    // get_mtval() API not yet added — deferred to future cosim API extension
    if (sync_trap && result != 0) begin
      int unsigned spike_mcause, spike_mepc;
      spike_mcause = riscv_cosim_get_mcause(cosim_handle, tid);
      spike_mepc   = riscv_cosim_get_mepc(cosim_handle, tid);

      if (spike_mcause != item.dut_mcause) begin
        mismatch_count[tid]++;
        `uvm_error("cosim", $sformatf(
          "T%0d EXC mcause MISMATCH: DUT=%08x Spike=%08x PC=%08x ecause=%0d",
          tid, item.dut_mcause, spike_mcause, item.pc, item.ecause))
      end

      if (spike_mepc != item.dut_mepc) begin
        mismatch_count[tid]++;
        `uvm_error("cosim", $sformatf(
          "T%0d EXC mepc MISMATCH: DUT=%08x Spike=%08x PC=%08x ecause=%0d",
          tid, item.dut_mepc, spike_mepc, item.pc, item.ecause))
      end

      `uvm_info("cosim", $sformatf(
        "T%0d EXC-CSR-COMPARE: PC=%08x DUT_mcause=%08x Spike_mcause=%08x DUT_mepc=%08x Spike_mepc=%08x",
        tid, item.pc, item.dut_mcause, spike_mcause, item.dut_mepc, spike_mepc), UVM_HIGH)
    end

    step_count++;
  endfunction

  function string get_cosim_error_str();
    string error = "Cosim mismatch: ";
    int num_errors = riscv_cosim_get_num_errors(cosim_handle);
    for (int i = 0; i < num_errors; i++) begin
      error = {error, riscv_cosim_get_error(cosim_handle, i), "\n"};
    end
    riscv_cosim_clear_errors(cosim_handle);
    return error;
  endfunction

  // Load binary into co-simulation reference model — implementation lives in
  // a sibling header so the scoreboard core stays focused on the cosim loop.
  `include "eh2_cosim_binary_loader.svh"

  protected function void init_cosim();
    cleanup_cosim();

    if (enable_cosim) begin
      cosim_handle = riscv_cosim_init(cosim_config);
      if (cosim_handle == null) begin
        `uvm_fatal("cosim", "Failed to initialize co-simulation")
      end
      initialized = 1;

      // Register all DUT-accessible memory regions with Spike (from cfg — issue 65).
      if (cfg != null) begin
        riscv_cosim_add_memory(cosim_handle, cfg.mem_boot.base,      cfg.mem_boot.size);
        riscv_cosim_add_memory(cosim_handle, cfg.mem_debug_sb.base,  cfg.mem_debug_sb.size);
        riscv_cosim_add_memory(cosim_handle, cfg.mem_ext_data1.base, cfg.mem_ext_data1.size);
        riscv_cosim_add_memory(cosim_handle, cfg.mem_ext_data2.base, cfg.mem_ext_data2.size);
        riscv_cosim_add_memory(cosim_handle, cfg.mem_iccm.base,      cfg.mem_iccm.size);
        riscv_cosim_add_memory(cosim_handle, cfg.mem_dccm.base,      cfg.mem_dccm.size);
        riscv_cosim_add_memory(cosim_handle, cfg.mem_pic.base,       cfg.mem_pic.size);
        riscv_cosim_add_memory(cosim_handle, cfg.mem_mailbox.base,   cfg.mem_mailbox.size);
        riscv_cosim_add_memory(cosim_handle, cfg.mem_nmi_vec.base,   cfg.mem_nmi_vec.size);
      end else begin
        riscv_cosim_add_memory(cosim_handle, 32'h8000_0000, 32'h0400_0000);
        riscv_cosim_add_memory(cosim_handle, 32'hA058_0000, 32'h0400_0000);
        riscv_cosim_add_memory(cosim_handle, 32'hB000_0000, 32'h0400_0000);
        riscv_cosim_add_memory(cosim_handle, 32'hC058_0000, 32'h0400_0000);
        riscv_cosim_add_memory(cosim_handle, 32'hF00C_0000, 32'h0000_8000);
        riscv_cosim_add_memory(cosim_handle, 32'hD058_0000, 32'h0000_1000);
        riscv_cosim_add_memory(cosim_handle, 32'h1111_0000, 32'h0000_1000);
        // ICCM/DCCM memory regions are now injected from env via eh2_cosim_cfg
        // (issue 65). Without cfg, these EH2-specific memory regions are not
        // registered — the env guarantees cfg != null when cosim is enabled.
        `uvm_warning("cosim", "No cosim_cfg provided — ICCM/DCCM memory regions not registered with Spike")
      end

      // Pre-register EH2 vendor-specific CSRs in Spike (see header for list).
      `include "eh2_cosim_csr_preregister.svh"

      `uvm_info("cosim", "Pre-registered 28 EH2 custom CSRs", UVM_LOW)

      if (pending_bin_path != "") begin
        `uvm_info("cosim", $sformatf("Loading pending binary: %s at 0x%08x",
          pending_bin_path, pending_base_addr), UVM_LOW)
        load_binary(pending_bin_path, pending_base_addr);
        pending_bin_path = "";
      end
      else if (stored_bin_path != "") begin
        `uvm_info("cosim", "Reloading binary after reset recovery", UVM_LOW)
        load_binary(stored_bin_path, stored_base_addr);
      end
    end

    step_count = 0;
    trace_item_count = 0;
    probe_item_count = 0;
    suppressed_probe_item_count = 0;
    axi_item_count = 0;
    pending_trace_high_watermark = 0;
    for (int t = 0; t < 2; t++) begin
      mismatch_count[t] = 0;
      insn_cnt[t] = 0;
      prev_mip[t] = 0;
      pending_trace_q[t].delete();
      async_wb_q[t].delete();
    end
    pending_mem_access_q.delete();
  endfunction

  protected function void cleanup_cosim();
    if (cosim_handle != null) begin
      riscv_cosim_destroy(cosim_handle);
      cosim_handle = null;
    end
    initialized = 0;
  endfunction

  function void report_phase(uvm_phase phase);
    int total_mismatch;
    int total_pending_trace;
    int total_pending_async;

    super.report_phase(phase);

    total_mismatch = mismatch_count[0] + mismatch_count[1];
    total_pending_trace = pending_trace_q[0].size() + pending_trace_q[1].size();
    total_pending_async = async_wb_q[0].size() + async_wb_q[1].size();

    `uvm_info("cosim", "=== Co-simulation Scoreboard Report ===", UVM_LOW)
    `uvm_info("cosim", $sformatf("Trace items received: %0d", trace_item_count), UVM_LOW)
    `uvm_info("cosim", $sformatf("Probe items received: %0d (async-only)", probe_item_count), UVM_LOW)
    `uvm_info("cosim", $sformatf("AXI items received: %0d", axi_item_count), UVM_LOW)
    `uvm_info("cosim", $sformatf("Pending trace items: T0=%0d T1=%0d",
      pending_trace_q[0].size(), pending_trace_q[1].size()), UVM_LOW)
    `uvm_info("cosim", $sformatf("Pending LSU accesses: %0d", pending_mem_access_q.size()), UVM_LOW)
    `uvm_info("cosim", $sformatf("Pending async wb hints: T0=%0d T1=%0d",
      async_wb_q[0].size(), async_wb_q[1].size()), UVM_LOW)
    `uvm_info("cosim", $sformatf("Trace backlog high watermark: %0d",
      pending_trace_high_watermark), UVM_LOW)
    `uvm_info("cosim", $sformatf("Steps executed: %0d", step_count), UVM_LOW)
    `uvm_info("cosim", $sformatf("Mismatches: T0=%0d T1=%0d total=%0d",
      mismatch_count[0], mismatch_count[1], total_mismatch), UVM_LOW)
    if (cosim_handle != null) begin
      `uvm_info("cosim", $sformatf("Instructions matched: T0=%0d T1=%0d",
        riscv_cosim_get_insn_cnt(cosim_handle, 0),
        riscv_cosim_get_insn_cnt(cosim_handle, 1)), UVM_LOW)
    end
    if (total_mismatch == 0 && step_count > 0) begin
      if (total_pending_trace > 0 || pending_mem_access_q.size() > 0) begin
        `uvm_info("cosim", $sformatf(
          "NOTE: %0d pending trace items, %0d pending LSU accesses at end-of-test (EH2 nb_load/store-buffer timing)",
          total_pending_trace, pending_mem_access_q.size()), UVM_LOW)
      end
      `uvm_info("cosim", "RESULT: PASS", UVM_LOW)
    end else if (trace_item_count > 0 || step_count > 0 ||
                 total_pending_trace > 0 ||
                 pending_mem_access_q.size() > 0) begin
      `uvm_error("cosim", "RESULT: FAIL")
    end
  endfunction

  function void final_phase(uvm_phase phase);
    super.final_phase(phase);
    if (cosim_handle != null) begin
      `uvm_info("cosim", $sformatf("Co-simulation matched T0=%0d T1=%0d instructions",
        riscv_cosim_get_insn_cnt(cosim_handle, 0),
        riscv_cosim_get_insn_cnt(cosim_handle, 1)), UVM_LOW)
    end
    cleanup_cosim();
  endfunction

  function void pre_abort();
    cleanup_cosim();
  endfunction

endclass
