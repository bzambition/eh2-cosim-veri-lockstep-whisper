// Testbench file list for EH2 UVM Verification Platform
// Includes UVM components and testbench top
// NOTE: eh2_shared.f and eh2_rtl.f are passed separately by the Makefile
// Paths are relative to eh2-veri/ project root

// Bus parameters (must precede agent packages)
dv/uvm/bus_params_pkg/bus_params_pkg.sv

// UVM agent packages (include path for package-internal includes)

// AXI4 agent
+incdir+dv/uvm/core_eh2/common/axi4_agent
dv/uvm/core_eh2/common/axi4_agent/axi4_agent_pkg.sv

// Trace agent (trace interface and monitor only - env interfaces moved to env/)
+incdir+dv/uvm/core_eh2/common/trace_agent
dv/uvm/core_eh2/common/trace_agent/eh2_trace_intf.sv
dv/uvm/core_eh2/common/trace_agent/eh2_trace_agent_pkg.sv

// IRQ agent (interrupt stimulus)
+incdir+dv/uvm/core_eh2/common/irq_agent
dv/uvm/core_eh2/common/irq_agent/eh2_irq_intf.sv
dv/uvm/core_eh2/common/irq_agent/eh2_irq_agent_pkg.sv

// JTAG agent (debug stimulus)
+incdir+dv/uvm/core_eh2/common/jtag_agent
dv/uvm/core_eh2/common/jtag_agent/eh2_jtag_intf.sv
dv/uvm/core_eh2/common/jtag_agent/eh2_jtag_agent_pkg.sv

// Halt/Run agent (MPC halt/run stimulus)
+incdir+dv/uvm/core_eh2/common/halt_run_agent
dv/uvm/core_eh2/common/halt_run_agent/eh2_halt_run_intf.sv
dv/uvm/core_eh2/common/halt_run_agent/eh2_halt_run_agent_pkg.sv

// Fetch enable interface
dv/uvm/core_eh2/common/fetch_enable_intf.sv

// Testbench service interface
dv/uvm/core_eh2/common/core_eh2_tb_intf.sv

// Functional coverage
+incdir+dv/uvm/core_eh2/fcov
dv/uvm/core_eh2/fcov/eh2_csr_categories.svh
dv/uvm/core_eh2/fcov/eh2_fcov_if.sv
dv/uvm/core_eh2/fcov/eh2_pmp_fcov_if.sv
dv/uvm/core_eh2/fcov/eh2_fcov_bind.sv

// UVM environment interfaces (DUT probe, CSR, instr monitor — Ibex-style env/ layout)
+incdir+dv/uvm/core_eh2/env
dv/uvm/core_eh2/env/eh2_dut_probe_if.sv
dv/uvm/core_eh2/env/eh2_csr_if.sv
dv/uvm/core_eh2/env/eh2_instr_monitor_if.sv

// UVM environment (env_pkg includes cfg, vseqr, scoreboard, env)
dv/uvm/core_eh2/env/core_eh2_env_pkg.sv

// UVM test package (includes seq_lib, new_seq_lib, vseq, base_test, test_lib, report_server)
+incdir+dv/uvm/core_eh2/tests
dv/uvm/core_eh2/tests/core_eh2_test_pkg.sv

// RVFI interface (formal verification)
+incdir+dv/uvm/core_eh2/env
dv/uvm/core_eh2/env/eh2_rvfi_if.sv

// Standard RVVI-TRACE DUT-side stream (MR1)
+incdir+vendor/rvvi/include/host/rvvi
vendor/rvvi/source/host/rvvi/rvviTrace.sv
+incdir+dv/uvm/core_eh2/common/rvvi_agent
dv/uvm/core_eh2/common/rvvi_agent/eh2_rvvi_adapter.sv

// UVM testbench top
+incdir+dv/uvm/core_eh2/tb
dv/uvm/core_eh2/tb/core_eh2_tb_top.sv
