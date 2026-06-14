// SPDX-License-Identifier: Apache-2.0
// EH2 Co-simulation Configuration
//
// Configuration object for the Spike co-simulation model.
// Placed into uvm_config_db by the testbench; read by the
// cosim scoreboard during build_phase.
//
// Based on ibex's core_ibex_cosim_cfg pattern, adapted for EH2.

class eh2_cosim_cfg extends uvm_object;

  `uvm_object_utils(eh2_cosim_cfg)

  // RISC-V ISA string passed to Spike (e.g. "rv32imac_zba_zbb_zbc_zbs")
  string isa_string = "rv32imac_zba_zbb_zbc_zbs";

  // Initial program counter for the cosim
  bit [31:0] start_pc = 32'h8000_0000;

  // Initial machine trap-vector base address
  bit [31:0] start_mtvec = 32'h0;

  // Number of PMP regions
  bit [31:0] pmp_num_regions = 16;

  // PMP granularity (log2 of minimum region size)
  bit [31:0] pmp_granularity = 0;

  // Number of MHPM performance counters
  bit [31:0] mhpm_counter_num = 0;

  // When set, mismatches are logged as UVM_LOW instead of UVM_FATAL
  bit relax_cosim_check = 0;

  // Path to Spike log output (empty = no log)
  string log_file = "";

  // Debug module address range
  bit [31:0] dm_start_addr = 32'h0000_0000;
  bit [31:0] dm_end_addr   = 32'h0000_0FFF;

  // Memory region configuration (issue 65: from RTL pkg, no hardcoding)
  // Override with plusargs: +MEM_BOOT_BASE=... +MEM_BOOT_SIZE=...
  typedef struct {
    bit [31:0] base;
    bit [31:0] size;
  } mem_region_t;

  mem_region_t mem_boot      = '{base: 32'h8000_0000, size: 32'h0400_0000};
  mem_region_t mem_debug_sb  = '{base: 32'hA058_0000, size: 32'h0400_0000};
  mem_region_t mem_ext_data1 = '{base: 32'hB000_0000, size: 32'h0400_0000};
  mem_region_t mem_ext_data2 = '{base: 32'hC058_0000, size: 32'h0400_0000};
  mem_region_t mem_iccm      = '{base: 32'hEE00_0000, size: 32'h0001_0000};
  mem_region_t mem_dccm      = '{base: 32'hF004_0000, size: 32'h0001_0000};

  // Explicit DCCM/ICCM base/size fields for env injection from RTL parameters
  // (issue 65). These mirror mem_dccm/mem_iccm but provide flat access for
  // testbench wiring and plusarg override.
  bit [31:0] dccm_base = 32'hF004_0000;
  bit [31:0] dccm_size = 32'h0001_0000;
  bit [31:0] iccm_base = 32'hEE00_0000;
  bit [31:0] iccm_size = 32'h0001_0000;
  mem_region_t mem_pic       = '{base: 32'hF00C_0000, size: 32'h0000_8000};
  mem_region_t mem_mailbox   = '{base: 32'hD058_0000, size: 32'h0000_1000};
  mem_region_t mem_nmi_vec   = '{base: 32'h1111_0000, size: 32'h0000_1000};

  function new(string name = "eh2_cosim_cfg");
    super.new(name);
  endfunction

  // Sync flat fields into struct fields (for env injection path).
  // Called after plusarg overrides to keep both representations in agreement.
  function void sync_mem_regions();
    mem_iccm.base = iccm_base;
    mem_iccm.size = iccm_size;
    mem_dccm.base = dccm_base;
    mem_dccm.size = dccm_size;
  endfunction

  function string convert2string();
    return $sformatf(
      "eh2_cosim_cfg: isa=%s start_pc=%08x mtvec=%08x pmp=%0d relax=%0b dccm_base=%08h iccm_base=%08h",
      isa_string, start_pc, start_mtvec, pmp_num_regions, relax_cosim_check, dccm_base, iccm_base);
  endfunction

endclass
