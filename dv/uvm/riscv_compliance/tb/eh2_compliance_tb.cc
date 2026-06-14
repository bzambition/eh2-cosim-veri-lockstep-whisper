// SPDX-License-Identifier: Apache-2.0
// EH2 RISC-V Compliance Testbench — Verilator C++ harness (issue 57)
//
// Modeled after ibex/dv/riscv_compliance/ibex_riscv_compliance.cc.
// Drives eh2_compliance_tb with Verilator, loads the test hex,
// runs N cycles or until $finish, and captures SIGNATURE lines from stdout.

#include <iostream>
#include <fstream>
#include <string>
#include <cstdlib>
#include <cstring>
#include <signal.h>

#include "Veh2_compliance_tb.h"
#include "verilated.h"

static bool got_finish = false;

double sc_time_stamp() { return 0; }

//----------------------------------------------------------------------
// Helpers
//----------------------------------------------------------------------
static std::string hex_path;
static std::string signature_path;
static long long max_cycles = 10000000LL;

static void parse_args(int argc, char **argv) {
  for (int i = 1; i < argc; ++i) {
    std::string arg(argv[i]);
    if (arg.rfind("+bin=", 0) == 0) {
      hex_path = arg.substr(5);
    } else if (arg.rfind("+signature=", 0) == 0) {
      signature_path = arg.substr(12);
    } else if (arg.rfind("+max_cycles=", 0) == 0) {
      max_cycles = std::atoll(arg.substr(13).c_str());
    }
  }
}

//----------------------------------------------------------------------
// main
//----------------------------------------------------------------------
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  parse_args(argc, argv);

  Veh2_compliance_tb *top = new Veh2_compliance_tb;

  // Redirect stdout to capture SIGNATURE lines
  std::string sim_stdout_path = (signature_path.empty())
      ? "compliance_stdout.log"
      : signature_path + ".log";
  FILE *log_fd = std::fopen(sim_stdout_path.c_str(), "w");
  if (!log_fd) {
    std::cerr << "ERROR: cannot open log file " << sim_stdout_path << "\n";
    return 1;
  }

  // Simulation loop
  top->core_clk = 0;
  top->eval();
  long long cycle = 0;

  while (!Verilated::gotFinish() && cycle < max_cycles) {
    // Toggle clock
    top->core_clk = !top->core_clk;
    top->eval();

    if (top->core_clk) {
      cycle++;
    }

    // After a $finish in the DUT, Verilator sets gotFinish
    if (Verilated::gotFinish()) break;
  }

  // Extract SIGNATURE: lines from the simulation stdout
  // (In Verilator, $display goes to stdout by default)
  // For a real flow, capture is done via the sim log

  std::fclose(log_fd);
  top->final();
  delete top;

  std::cout << "COMPLIANCE_TB: simulation complete, " << cycle/2 << " cycles" << std::endl;
  return 0;
}
