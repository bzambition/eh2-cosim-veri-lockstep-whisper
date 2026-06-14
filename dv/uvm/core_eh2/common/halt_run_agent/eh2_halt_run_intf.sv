// SPDX-License-Identifier: Apache-2.0
// Halt/Run Interface for EH2 Verification
//
// Drives MPC halt/run signals and CPU halt/run signals.
// Monitors acknowledgment signals.

interface eh2_halt_run_intf (
  input logic clk,
  input logic rst_n
);

  // MPC debug halt/run requests (active high)
  logic mpc_debug_halt_req = 1'b0;
  logic mpc_debug_run_req  = 1'b1;
  logic mpc_reset_run_req  = 1'b1;

  // CPU halt/run requests (active high)
  // Note: i_cpu_run_req=0 matches reference testbench (no active run request,
  // let core run based on mpc_reset_run_req)
  logic i_cpu_halt_req = 1'b0;
  logic i_cpu_run_req  = 1'b0;

  // Acknowledgment signals (active high)
  logic o_cpu_halt_ack;
  logic o_cpu_run_ack;
  logic o_cpu_halt_status;
  logic o_debug_mode_status;

  // Driver clocking block
  clocking driver_cb @(posedge clk);
    output mpc_debug_halt_req;
    output mpc_debug_run_req;
    output mpc_reset_run_req;
    output i_cpu_halt_req;
    output i_cpu_run_req;
  endclocking

  // Monitor clocking block
  clocking monitor_cb @(posedge clk);
    input mpc_debug_halt_req;
    input mpc_debug_run_req;
    input mpc_reset_run_req;
    input i_cpu_halt_req;
    input i_cpu_run_req;
    input o_cpu_halt_ack;
    input o_cpu_run_ack;
    input o_cpu_halt_status;
    input o_debug_mode_status;
  endclocking

  // Modports
  modport driver  (clocking driver_cb, input clk, rst_n,
                   input o_cpu_halt_ack, o_cpu_run_ack, o_cpu_halt_status, o_debug_mode_status);
  modport monitor (clocking monitor_cb, input clk, rst_n);

endinterface
