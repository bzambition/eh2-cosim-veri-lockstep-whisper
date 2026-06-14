// SPDX-License-Identifier: Apache-2.0
// EH2 Interrupt Interface
//
// Interface for EH2 interrupt signals.
// Connects to DUT timer_int, soft_int, and extintsrc_req ports.

interface eh2_irq_intf #(
  parameter NUM_THREADS = 1,
  parameter PIC_TOTAL_INT = 127
)(
  input logic clk,
  input logic rst_n
);

  // Interrupt signals
  logic [NUM_THREADS-1:0]   timer_int;
  logic [NUM_THREADS-1:0]   soft_int;
  logic [PIC_TOTAL_INT:1]   extintsrc_req;
  logic                     nmi_int;

  // Default values
  initial begin
    timer_int     = '0;
    soft_int      = '0;
    extintsrc_req = '0;
    nmi_int       = 1'b0;
  end

  // Driver clocking block
  clocking driver_cb @(posedge clk);
    output timer_int;
    output soft_int;
    output extintsrc_req;
    output nmi_int;
  endclocking

  // Monitor clocking block
  clocking monitor_cb @(posedge clk);
    input timer_int;
    input soft_int;
    input extintsrc_req;
    input nmi_int;
  endclocking

  // Modport for driver
  modport driver (
    input clk, rst_n,
    clocking driver_cb
  );

  // Modport for monitor
  modport monitor (
    input clk, rst_n,
    clocking monitor_cb
  );

endinterface
