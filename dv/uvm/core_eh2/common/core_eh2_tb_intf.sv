// SPDX-License-Identifier: Apache-2.0
// EH2 testbench service interface.
//
// UVM classes live in packages, so they must not reach into core_eh2_tb_top
// with hierarchical references.  This interface carries the small set of
// testbench services that tests need: clocked waits, mailbox status, early
// binary-load state, and byte backdoor writes to the AXI memory models.

interface core_eh2_tb_intf (
  input logic clk,
  input logic rst_n
);

  logic        mailbox_write;
  logic [31:0] mailbox_addr;
  logic [63:0] mailbox_data;
  logic        mailbox_test_done;
  logic        early_bin_loaded;

  bit [31:0] mem_write_addr;
  bit [7:0]  mem_write_data;
  int unsigned mem_write_req_id;
  int unsigned mem_write_done_id;
  event mem_write_req;

  task automatic wait_clks(input int unsigned cycles);
    repeat (cycles) @(posedge clk);
  endtask

  task automatic write_mem_byte(input bit [31:0] addr, input bit [7:0] data);
    mem_write_addr = addr;
    mem_write_data = data;
    mem_write_req_id++;
    -> mem_write_req;
    wait (mem_write_done_id == mem_write_req_id);
  endtask

endinterface
