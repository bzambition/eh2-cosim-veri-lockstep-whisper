// SPDX-License-Identifier: Apache-2.0
// EH2 JTAG Interface
//
// Interface for JTAG signals connecting to DUT.

interface eh2_jtag_intf(
  input logic clk,
  input logic rst_n
);

  // JTAG signals
  logic       tck;
  logic       tms;
  logic       tdi;
  logic       trst_n;
  logic       tdo;

  // Default values (trst_n release is controlled by the JTAG driver)
  initial begin
    tck    = 0;
    tms    = 1;
    tdi    = 0;
    trst_n = 0;
  end

  // Clocking block for driver
  clocking driver_cb @(posedge clk);
    output tck;
    output tms;
    output tdi;
    output trst_n;
    input  tdo;
  endclocking

  // Clocking block for monitor
  clocking monitor_cb @(posedge clk);
    input tck;
    input tms;
    input tdi;
    input trst_n;
    input tdo;
  endclocking

endinterface
