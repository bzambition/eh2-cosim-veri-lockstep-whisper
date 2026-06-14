// SPDX-License-Identifier: Apache-2.0
// EH2 PMP Functional Coverage Interface
//
// Covers PMP (Physical Memory Protection) configuration and behavior.
// Benchmarked against ibex's core_ibex_pmp_fcov_if.sv, adapted for EH2.
//
// Covergroups:
//   pmp_region_cg    - Per-region configuration coverage
//   pmp_access_cg    - PMP access check coverage (iside/dside)
//   pmp_warl_cg      - PMP WARL behavior coverage
//   pmp_epmp_cg      - ePMP (MML/MMWP/RLB) coverage
//   pmp_region_ext_cg   - Per-region extended config coverage (RWX/mode/lock)
//   pmp_access_type_cg  - Access type x fault coverage
//   pmp_addr_match_cg   - Per-region address match coverage
//   pmp_multi_region_cg - Multi-region interaction coverage
//   pmp_boundary_cg     - Address boundary / edge-case coverage
//   pmp_region_prio_cg  - Region priority / first-match coverage
//   pmp_napot_per_region_cg - Per-region NAPOT size coverage
//   pmp_epmp_region_cg  - ePMP config x region config cross coverage
//   pmp_addr_pattern_cg - PMP address register bit-pattern coverage
//   pmp_cfg_transition_cg - PMP config transition / toggle coverage
//
// Enable via: +enable_eh2_fcov=1 (requires PMPEnable=1)

interface eh2_pmp_fcov_if
  import eh2_pkg::*;
#(
  parameter bit          PMPEnable      = 1'b0,
  parameter int unsigned PMPGranularity = 0,
  parameter int unsigned PMPNumRegions  = 4
) (
  input logic clk_i,
  input logic rst_l_i,

  // PMP configuration from CSR registers
  input logic [PMPNumRegions-1:0]       pmp_cfg_lock,
  input logic [PMPNumRegions-1:0] [1:0] pmp_cfg_mode,
  input logic [PMPNumRegions-1:0]       pmp_cfg_exec,
  input logic [PMPNumRegions-1:0]       pmp_cfg_write,
  input logic [PMPNumRegions-1:0]       pmp_cfg_read,
  input logic [PMPNumRegions-1:0] [31:0] pmp_addr,

  // ePMP mseccfg
  input logic mseccfg_mml,
  input logic mseccfg_mmwp,
  input logic mseccfg_rlb,

  // PMP access check results
  input logic pmp_iside_err,
  input logic pmp_dside_err,

  // Debug mode
  input logic debug_mode,

  // Data request
  input logic data_req,

  // Load (1) vs Store (0) cycle indicator — from LSU request phase (issue 68)
  input logic is_load
);

  `include "uvm_macros.svh"

  bit en_pmp_fcov;

  initial begin
    if (PMPEnable) begin
      void'($value$plusargs("enable_eh2_fcov=%d", en_pmp_fcov));
    end else begin
      en_pmp_fcov = 1'b0;
    end
  end

  // =========================================================================
  // PMP Mode enum
  // =========================================================================
  typedef enum logic [1:0] {
    PMP_MODE_OFF   = 2'b00,
    PMP_MODE_TOR   = 2'b01,
    PMP_MODE_NA4   = 2'b10,
    PMP_MODE_NAPOT = 2'b11
  } pmp_mode_e;

  // =========================================================================
  // PMP Permission bits with MML support
  // =========================================================================
  typedef enum logic [4:0] {
    NONE        = 5'b00000,
    R           = 5'b00001,
    W           = 5'b00010,
    WR          = 5'b00011,
    X           = 5'b00100,
    XR          = 5'b00101,
    XW          = 5'b00110,
    XWR         = 5'b00111,
    L           = 5'b01000,
    LR          = 5'b01001,
    LW          = 5'b01010,
    LWR         = 5'b01011,
    LX          = 5'b01100,
    LXR         = 5'b01101,
    LXW         = 5'b01110,
    LXWR        = 5'b01111,
    MML_NONE    = 5'b10000,
    MML_RU      = 5'b10001,
    MML_WRM_RU  = 5'b10010,
    MML_WRU     = 5'b10011,
    MML_XU      = 5'b10100,
    MML_XRU     = 5'b10101,
    MML_WRM_WRU = 5'b10110,
    MML_XWRU    = 5'b10111,
    MML_L       = 5'b11000,
    MML_RM      = 5'b11001,
    MML_XM_XU   = 5'b11010,
    MML_WRM     = 5'b11011,
    MML_XM      = 5'b11100,
    MML_XRM     = 5'b11101,
    MML_XRM_XU  = 5'b11110,
    MML_RM_RU   = 5'b11111
  } pmp_priv_bits_e;

  // =========================================================================
  // Access type enum (for access_type coverpoints)
  // =========================================================================
  typedef enum logic [1:0] {
    ACCESS_EXEC  = 2'b00,
    ACCESS_LOAD  = 2'b01,
    ACCESS_STORE = 2'b10,
    ACCESS_NONE  = 2'b11
  } pmp_access_type_e;

  // =========================================================================
  // Derived signals for coverage
  // =========================================================================

  // Combined RWX per region (non-MML view)
  logic [PMPNumRegions-1:0] [2:0] pmp_cfg_rwx;
  for (genvar r = 0; r < PMPNumRegions; r++) begin : g_rwx
    assign pmp_cfg_rwx[r] = {pmp_cfg_exec[r], pmp_cfg_write[r], pmp_cfg_read[r]};
  end

  // Region active: mode != OFF
  logic [PMPNumRegions-1:0] region_active;
  for (genvar r = 0; r < PMPNumRegions; r++) begin : g_active
    assign region_active[r] = (pmp_cfg_mode[r] != PMP_MODE_OFF);
  end

  // Count of active regions
  logic [$clog2(PMPNumRegions+1)-1:0] num_active_regions;
  always_comb begin
    num_active_regions = '0;
    for (int r = 0; r < PMPNumRegions; r++) begin
      num_active_regions = num_active_regions + {{($clog2(PMPNumRegions+1)-1){1'b0}}, region_active[r]};
    end
  end

  // Access type inference — is_load signal added (issue 68)
  // iside_err => exec access; dside_err + data_req + is_load => load; + !is_load => store
  pmp_access_type_e inferred_access_type;
  always_comb begin
    if (pmp_iside_err)
      inferred_access_type = ACCESS_EXEC;
    else if (data_req & is_load)
      inferred_access_type = ACCESS_LOAD;
    else if (data_req & ~is_load)
      inferred_access_type = ACCESS_STORE;
    else
      inferred_access_type = ACCESS_NONE;
  end

  // Any PMP fault occurred
  logic pmp_any_fault;
  assign pmp_any_fault = pmp_iside_err | pmp_dside_err;

  // Previous-cycle configuration (for transition coverage)
  logic [PMPNumRegions-1:0] [1:0] pmp_cfg_mode_prev;
  logic [PMPNumRegions-1:0]       pmp_cfg_lock_prev;
  logic [PMPNumRegions-1:0] [2:0] pmp_cfg_rwx_prev;
  logic                           mseccfg_mml_prev;
  logic                           mseccfg_mmwp_prev;
  logic                           mseccfg_rlb_prev;

  always_ff @(posedge clk_i or negedge rst_l_i) begin
    if (!rst_l_i) begin
      pmp_cfg_mode_prev <= '0;
      pmp_cfg_lock_prev <= '0;
      pmp_cfg_rwx_prev  <= '0;
      mseccfg_mml_prev  <= '0;
      mseccfg_mmwp_prev <= '0;
      mseccfg_rlb_prev  <= '0;
    end else begin
      pmp_cfg_mode_prev <= pmp_cfg_mode;
      pmp_cfg_lock_prev <= pmp_cfg_lock;
      pmp_cfg_rwx_prev  <= pmp_cfg_rwx;
      mseccfg_mml_prev  <= mseccfg_mml;
      mseccfg_mmwp_prev <= mseccfg_mmwp;
      mseccfg_rlb_prev  <= mseccfg_rlb;
    end
  end

  // Mode changed per region
  logic [PMPNumRegions-1:0] mode_changed;
  for (genvar r = 0; r < PMPNumRegions; r++) begin : g_mode_chg
    assign mode_changed[r] = (pmp_cfg_mode[r] != pmp_cfg_mode_prev[r]);
  end

  // Lock changed per region
  logic [PMPNumRegions-1:0] lock_changed;
  for (genvar r = 0; r < PMPNumRegions; r++) begin : g_lock_chg
    assign lock_changed[r] = (pmp_cfg_lock[r] != pmp_cfg_lock_prev[r]);
  end

  // RWX changed per region
  logic [PMPNumRegions-1:0] rwx_changed;
  for (genvar r = 0; r < PMPNumRegions; r++) begin : g_rwx_chg
    assign rwx_changed[r] = (pmp_cfg_rwx[r] != pmp_cfg_rwx_prev[r]);
  end

  // ePMP config changed
  logic epmp_config_changed;
  assign epmp_config_changed = (mseccfg_mml  != mseccfg_mml_prev) |
                               (mseccfg_mmwp != mseccfg_mmwp_prev) |
                               (mseccfg_rlb  != mseccfg_rlb_prev);

  // NAPOT trailing-ones count per region (for NAPOT size coverage)
  logic [PMPNumRegions-1:0] [5:0] napot_trailing_ones;
  for (genvar r = 0; r < PMPNumRegions; r++) begin : g_napot_cnt
    always_comb begin
      napot_trailing_ones[r] = '0;
      for (int b = 0; b < 32; b++) begin
        if (pmp_addr[r][b])
          napot_trailing_ones[r] = napot_trailing_ones[r] + 6'd1;
        else
          break;
      end
    end
  end

  // Address alignment indicators per region
  logic [PMPNumRegions-1:0] addr_4byte_aligned;
  logic [PMPNumRegions-1:0] addr_page_aligned;   // 4KB boundary
  logic [PMPNumRegions-1:0] addr_is_zero;
  logic [PMPNumRegions-1:0] addr_is_max;
  for (genvar r = 0; r < PMPNumRegions; r++) begin : g_addr_align
    assign addr_4byte_aligned[r] = (pmp_addr[r][1:0] == 2'b00);
    assign addr_page_aligned[r]  = (pmp_addr[r][11:0] == 12'h000);
    assign addr_is_zero[r]       = (pmp_addr[r] == 32'h0);
    assign addr_is_max[r]        = (pmp_addr[r] == 32'hFFFFFFFF);
  end

  // TOR: region[i] lower bound is pmpaddr[i-1] (or 0 for region 0)
  // Adjacent TOR regions: check if region i and i+1 are both TOR
  logic [PMPNumRegions-2:0] adjacent_tor;
  for (genvar r = 0; r < PMPNumRegions-1; r++) begin : g_adj_tor
    assign adjacent_tor[r] = (pmp_cfg_mode[r]   == PMP_MODE_TOR) &&
                             (pmp_cfg_mode[r+1] == PMP_MODE_TOR);
  end

  // =========================================================================
  // Locked region with non-OFF mode
  // =========================================================================
  logic [PMPNumRegions-1:0] locked_and_active;
  for (genvar r = 0; r < PMPNumRegions; r++) begin : g_lock_active
    assign locked_and_active[r] = pmp_cfg_lock[r] && region_active[r];
  end

  // Count of locked active regions
  logic [$clog2(PMPNumRegions+1)-1:0] num_locked_regions;
  always_comb begin
    num_locked_regions = '0;
    for (int r = 0; r < PMPNumRegions; r++) begin
      num_locked_regions = num_locked_regions + {{($clog2(PMPNumRegions+1)-1){1'b0}}, locked_and_active[r]};
    end
  end

  if (PMPEnable) begin : g_pmp_fcov

    // =========================================================================
    // Per-region configuration coverage (existing)
    // =========================================================================
    for (genvar i = 0; i < PMPNumRegions; i++) begin : g_region_cg

      pmp_priv_bits_e region_priv_bits;
      assign region_priv_bits = pmp_priv_bits_e'({mseccfg_mml,
                                                   pmp_cfg_lock[i],
                                                   pmp_cfg_exec[i],
                                                   pmp_cfg_write[i],
                                                   pmp_cfg_read[i]});

      covergroup pmp_region_cg @(posedge clk_i);
        option.per_instance = 1;
        option.name = $sformatf("pmp_region_%0d_cg", i);

        // PMP mode
        cp_mode: coverpoint pmp_cfg_mode[i] {
          bins off   = {PMP_MODE_OFF};
          bins tor   = {PMP_MODE_TOR};
          bins na4   = {PMP_MODE_NA4};
          bins napot = {PMP_MODE_NAPOT};
        }

        // Permission bits (with MML encoding)
        cp_priv_bits: coverpoint region_priv_bits {
          wildcard illegal_bins illegal = {5'b0??10};
        }

        // Lock bit
        cp_lock: coverpoint pmp_cfg_lock[i] {
          bins locked   = {1};
          bins unlocked = {0};
        }

        // Mode x lock cross
        mode_lock_cross: cross cp_mode, cp_lock;

        // Mode x permission cross
        mode_priv_cross: cross cp_mode, cp_priv_bits {
          ignore_bins off_with_priv = binsof(cp_mode) intersect {PMP_MODE_OFF};
        }
      endgroup

      pmp_region_cg region_cg_inst;
      initial region_cg_inst = new();

    end : g_region_cg

    // =========================================================================
    // PMP Access Check Coverage (existing)
    // =========================================================================
    covergroup pmp_access_cg @(posedge clk_i);
      option.per_instance = 1;
      option.name = "pmp_access_cg";

      // Instruction-side PMP error
      cp_iside_err: coverpoint pmp_iside_err {
        bins no_error = {0};
        bins error    = {1};
      }

      // Data-side PMP error
      cp_dside_err: coverpoint pmp_dside_err iff (data_req) {
        bins no_error = {0};
        bins error    = {1};
      }

      // Debug mode during access
      cp_debug_mode: coverpoint debug_mode {
        bins in_debug    = {1};
        bins not_debug   = {0};
      }

      // Iside error x debug mode
      iside_debug_cross: cross cp_iside_err, cp_debug_mode;

      // Dside error x debug mode
      dside_debug_cross: cross cp_dside_err, cp_debug_mode;
    endgroup

    pmp_access_cg access_cg_inst;
    initial access_cg_inst = new();

    // =========================================================================
    // PMP WARL Behavior Coverage (existing)
    // Tracks which PMP CSRs are being written and verifies WARL compliance.
    // =========================================================================
    covergroup pmp_warl_cg @(posedge clk_i);
      option.per_instance = 1;
      option.name = "pmp_warl_cg";

      // PMP address write - NAPOT address patterns
      // In NAPOT mode, the address encodes the region size via trailing ones
      cp_napot_size: coverpoint $countones(pmp_addr[0][31:2]) iff (pmp_cfg_mode[0] == PMP_MODE_NAPOT) {
        bins size_8B    = {30};   // 8 byte region
        bins size_16B   = {29};   // 16 byte region
        bins size_32B   = {28};
        bins size_64B   = {27};
        bins size_128B  = {26};
        bins size_256B  = {25};
        bins size_512B  = {24};
        bins size_1KB   = {23};
        bins size_2KB   = {22};
        bins size_4KB   = {21};
        bins size_8KB   = {20};
        bins size_16KB  = {19};
        bins size_32KB  = {18};
        bins size_64KB  = {17};
        bins size_128KB = {16};
        bins size_256KB = {15};
        bins size_512KB = {14};
        bins size_1MB   = {13};
        bins size_2MB   = {12};
        bins size_4MB   = {11};
        bins size_8MB   = {10};
        bins size_16MB  = {9};
        bins size_32MB  = {8};
        bins size_64MB  = {7};
        bins size_128MB = {6};
        bins size_256MB = {5};
        bins size_512MB = {4};
        bins size_1GB   = {3};
        bins size_2GB   = {2};
        bins size_4GB   = {1};
      }
    endgroup

    pmp_warl_cg warl_cg_inst;
    initial warl_cg_inst = new();

    // =========================================================================
    // ePMP (MML/MMWP/RLB) Coverage (existing)
    // =========================================================================
    covergroup pmp_epmp_cg @(posedge clk_i);
      option.per_instance = 1;
      option.name = "pmp_epmp_cg";

      // MML (Machine Mode Lockdown)
      cp_mml: coverpoint mseccfg_mml {
        bins enabled  = {1};
        bins disabled = {0};
      }

      // MMWP (Machine Mode Whitelist Policy)
      cp_mmwp: coverpoint mseccfg_mmwp {
        bins enabled  = {1};
        bins disabled = {0};
      }

      // RLB (Rule Locking Bypass)
      cp_rlb: coverpoint mseccfg_rlb {
        bins enabled  = {1};
        bins disabled = {0};
      }

      // MML x MMWP cross (key ePMP policy combinations)
      mml_mmwp_cross: cross cp_mml, cp_mmwp;

      // All three ePMP bits
      epmp_config_cross: cross cp_mml, cp_mmwp, cp_rlb;

      // ePMP config x iside error
      epmp_iside_cross: cross cp_mml, cp_mmwp, pmp_iside_err;

      // ePMP config x dside error
      epmp_dside_cross: cross cp_mml, cp_mmwp, pmp_dside_err iff (data_req);
    endgroup

    pmp_epmp_cg epmp_cg_inst;
    initial epmp_cg_inst = new();

    // =========================================================================
    // NEW: Per-region Extended Configuration Coverage
    // Covers mode, RWX decomposed, lock, and key crosses per region.
    // =========================================================================
    for (genvar i = 0; i < PMPNumRegions; i++) begin : g_region_ext_cg

      covergroup pmp_region_ext_cg @(posedge clk_i);
        option.per_instance = 1;
        option.name = $sformatf("pmp_region_ext_%0d_cg", i);

        // -----------------------------------------------------------------
        // PMP mode per region
        // -----------------------------------------------------------------
        cp_mode: coverpoint pmp_cfg_mode[i] {
          bins off   = {PMP_MODE_OFF};
          bins tor   = {PMP_MODE_TOR};
          bins na4   = {PMP_MODE_NA4};
          bins napot = {PMP_MODE_NAPOT};
        }

        // -----------------------------------------------------------------
        // RWX permission bits (non-MML, decomposed 3-bit view)
        // -----------------------------------------------------------------
        cp_rwx: coverpoint pmp_cfg_rwx[i] {
          bins no_access  = {3'b000};
          bins read_only  = {3'b001};
          bins write_only = {3'b010};  // illegal per spec but should be covered
          bins read_write = {3'b011};
          bins exec_only  = {3'b100};
          bins read_exec  = {3'b101};
          bins write_exec = {3'b110};  // illegal per spec but should be covered
          bins all_access = {3'b111};
        }

        // -----------------------------------------------------------------
        // Individual permission bits
        // -----------------------------------------------------------------
        cp_read: coverpoint pmp_cfg_read[i] {
          bins set   = {1};
          bins clear = {0};
        }

        cp_write: coverpoint pmp_cfg_write[i] {
          bins set   = {1};
          bins clear = {0};
        }

        cp_exec: coverpoint pmp_cfg_exec[i] {
          bins set   = {1};
          bins clear = {0};
        }

        // -----------------------------------------------------------------
        // Lock bit
        // -----------------------------------------------------------------
        cp_lock: coverpoint pmp_cfg_lock[i] {
          bins locked   = {1};
          bins unlocked = {0};
        }

        // -----------------------------------------------------------------
        // Cross: mode × RWX
        // When mode is OFF, permissions don't matter
        // -----------------------------------------------------------------
        mode_rwx_cross: cross cp_mode, cp_rwx {
          ignore_bins off_any_rwx = binsof(cp_mode) intersect {PMP_MODE_OFF};
        }

        // -----------------------------------------------------------------
        // Cross: mode × lock
        // -----------------------------------------------------------------
        mode_lock_cross: cross cp_mode, cp_lock;

        // -----------------------------------------------------------------
        // Cross: RWX × lock
        // Locked regions with various permissions
        // -----------------------------------------------------------------
        rwx_lock_cross: cross cp_rwx, cp_lock;

        // -----------------------------------------------------------------
        // Cross: mode × RWX × lock (full config space)
        // -----------------------------------------------------------------
        mode_rwx_lock_cross: cross cp_mode, cp_rwx, cp_lock {
          ignore_bins off_any = binsof(cp_mode) intersect {PMP_MODE_OFF};
        }

        // -----------------------------------------------------------------
        // Region active status
        // -----------------------------------------------------------------
        cp_active: coverpoint region_active[i] {
          bins active   = {1};
          bins inactive = {0};
        }

        // -----------------------------------------------------------------
        // Locked and active (enforcement in effect)
        // -----------------------------------------------------------------
        cp_locked_active: coverpoint locked_and_active[i] {
          bins locked_active = {1};
          bins other         = {0};
        }
      endgroup

      pmp_region_ext_cg region_ext_cg_inst;
      initial region_ext_cg_inst = new();

    end : g_region_ext_cg

    // =========================================================================
    // NEW: PMP Access Type x Fault Coverage
    // Covers inferred access type crossed with fault outcome.
    // =========================================================================
    covergroup pmp_access_type_cg @(posedge clk_i);
      option.per_instance = 1;
      option.name = "pmp_access_type_cg";

      // -----------------------------------------------------------------
      // Inferred access type
      // -----------------------------------------------------------------
      cp_access_type: coverpoint inferred_access_type {
        bins exec  = {ACCESS_EXEC};
        bins load  = {ACCESS_LOAD};
        bins store = {ACCESS_STORE};  // enabled by is_load signal (issue 68)
        ignore_bins none = {ACCESS_NONE};
      }

      // -----------------------------------------------------------------
      // Instruction-side fault
      // -----------------------------------------------------------------
      cp_iside_fault: coverpoint pmp_iside_err {
        bins no_fault = {0};
        bins fault    = {1};
      }

      // -----------------------------------------------------------------
      // Data-side fault
      // -----------------------------------------------------------------
      cp_dside_fault: coverpoint pmp_dside_err iff (data_req) {
        bins no_fault = {0};
        bins fault    = {1};
      }

      // -----------------------------------------------------------------
      // Any PMP fault
      // -----------------------------------------------------------------
      cp_any_fault: coverpoint pmp_any_fault {
        bins no_fault = {0};
        bins fault    = {1};
      }

      // -----------------------------------------------------------------
      // Access type x any fault
      // -----------------------------------------------------------------
      access_fault_cross: cross cp_access_type, cp_any_fault;

      // -----------------------------------------------------------------
      // Access type x debug mode
      // -----------------------------------------------------------------
      cp_debug: coverpoint debug_mode {
        bins in_debug  = {1};
        bins not_debug = {0};
      }

      access_debug_cross: cross cp_access_type, cp_debug;

      // -----------------------------------------------------------------
      // Access type x fault x debug (full scenario)
      // -----------------------------------------------------------------
      access_fault_debug_cross: cross cp_access_type, cp_any_fault, cp_debug;

      // -----------------------------------------------------------------
      // Simultaneous iside and dside errors
      // -----------------------------------------------------------------
      cp_simultaneous_faults: coverpoint {pmp_iside_err, pmp_dside_err} {
        bins no_fault     = {2'b00};
        bins iside_only   = {2'b10};
        bins dside_only   = {2'b01};
        bins both_faults  = {2'b11};
      }
    endgroup

    pmp_access_type_cg access_type_cg_inst;
    initial access_type_cg_inst = new();

    // =========================================================================
    // NEW: Per-region Address Match Coverage
    // Tracks whether addresses fall within each PMP region's bounds.
    // =========================================================================
    for (genvar i = 0; i < PMPNumRegions; i++) begin : g_addr_match_cg

      covergroup pmp_addr_match_cg @(posedge clk_i);
        option.per_instance = 1;
        option.name = $sformatf("pmp_addr_match_%0d_cg", i);

        // -----------------------------------------------------------------
        // Region active (mode != OFF)
        // -----------------------------------------------------------------
        cp_active: coverpoint region_active[i] {
          bins active   = {1};
          bins inactive = {0};
        }

        // -----------------------------------------------------------------
        // Address register is zero
        // -----------------------------------------------------------------
        cp_addr_zero: coverpoint addr_is_zero[i] {
          bins zero     = {1};
          bins nonzero  = {0};
        }

        // -----------------------------------------------------------------
        // Address register is max (0xFFFFFFFF)
        // -----------------------------------------------------------------
        cp_addr_max: coverpoint addr_is_max[i] {
          bins max      = {1};
          bins not_max  = {0};
        }

        // -----------------------------------------------------------------
        // Address 4-byte aligned
        // -----------------------------------------------------------------
        cp_addr_4b_align: coverpoint addr_4byte_aligned[i] {
          bins aligned   = {1};
          bins unaligned = {0};
        }

        // -----------------------------------------------------------------
        // Address page aligned (4KB boundary)
        // -----------------------------------------------------------------
        cp_addr_page_align: coverpoint addr_page_aligned[i] {
          bins aligned   = {1};
          bins unaligned = {0};
        }

        // -----------------------------------------------------------------
        // Active x fault (does this region cause faults when active?)
        // -----------------------------------------------------------------
        cp_iside_err: coverpoint pmp_iside_err {
          bins no_error = {0};
          bins error    = {1};
        }

        active_iside_cross: cross cp_active, cp_iside_err;

        cp_dside_err: coverpoint pmp_dside_err iff (data_req) {
          bins no_error = {0};
          bins error    = {1};
        }

        active_dside_cross: cross cp_active, cp_dside_err;

        // -----------------------------------------------------------------
        // Address boundary cases x mode
        // -----------------------------------------------------------------
        cp_mode: coverpoint pmp_cfg_mode[i] {
          bins off   = {PMP_MODE_OFF};
          bins tor   = {PMP_MODE_TOR};
          bins na4   = {PMP_MODE_NA4};
          bins napot = {PMP_MODE_NAPOT};
        }

        addr_boundary_mode_cross: cross cp_addr_zero, cp_mode {
          ignore_bins off_zero = binsof(cp_mode) intersect {PMP_MODE_OFF};
        }
      endgroup

      pmp_addr_match_cg addr_match_cg_inst;
      initial addr_match_cg_inst = new();

    end : g_addr_match_cg

    // =========================================================================
    // NEW: Multi-Region Interaction Coverage
    // Tracks how many regions are active and their combined configuration.
    // =========================================================================
    covergroup pmp_multi_region_cg @(posedge clk_i);
      option.per_instance = 1;
      option.name = "pmp_multi_region_cg";

      // -----------------------------------------------------------------
      // Number of active regions (mode != OFF)
      // -----------------------------------------------------------------
      cp_num_active: coverpoint num_active_regions {
        bins zero  = {0};
        bins one   = {1};
        bins two   = {2};
        bins three = {3};
        bins four  = {4};
        bins more  = {[5:$]};
      }

      // -----------------------------------------------------------------
      // Number of locked active regions
      // -----------------------------------------------------------------
      cp_num_locked: coverpoint num_locked_regions {
        bins zero  = {0};
        bins one   = {1};
        bins two   = {2};
        bins three = {3};
        bins four  = {4};
        bins more  = {[5:$]};
      }

      // -----------------------------------------------------------------
      // Active count x fault
      // -----------------------------------------------------------------
      cp_any_fault: coverpoint pmp_any_fault {
        bins no_fault = {0};
        bins fault    = {1};
      }

      active_fault_cross: cross cp_num_active, cp_any_fault;

      // -----------------------------------------------------------------
      // Locked count x fault
      // -----------------------------------------------------------------
      locked_fault_cross: cross cp_num_locked, cp_any_fault;

      // -----------------------------------------------------------------
      // Active count x ePMP MML
      // -----------------------------------------------------------------
      cp_mml: coverpoint mseccfg_mml {
        bins enabled  = {1};
        bins disabled = {0};
      }

      active_mml_cross: cross cp_num_active, cp_mml;

      // -----------------------------------------------------------------
      // Active count x debug mode
      // -----------------------------------------------------------------
      cp_debug: coverpoint debug_mode {
        bins in_debug  = {1};
        bins not_debug = {0};
      }

      active_debug_cross: cross cp_num_active, cp_debug;

      // -----------------------------------------------------------------
      // All regions OFF vs at least one active
      // -----------------------------------------------------------------
      cp_all_off: coverpoint (num_active_regions == 0) {
        bins all_off    = {1};
        bins some_on    = {0};
      }

      // -----------------------------------------------------------------
      // All regions locked (when active)
      // -----------------------------------------------------------------
      cp_all_locked: coverpoint (num_locked_regions == num_active_regions &&
                                  num_active_regions > 0) {
        bins all_locked = {1};
        bins not_all    = {0};
      }
    endgroup

    pmp_multi_region_cg multi_region_cg_inst;
    initial multi_region_cg_inst = new();

    // =========================================================================
    // NEW: Address Boundary / Edge-case Coverage
    // Covers NAPOT trailing-ones patterns, TOR adjacency, addr extremes.
    // =========================================================================
    covergroup pmp_boundary_cg @(posedge clk_i);
      option.per_instance = 1;
      option.name = "pmp_boundary_cg";

      // -----------------------------------------------------------------
      // Region 0 NAPOT trailing ones (region size indicator)
      // Already covered in pmp_warl_cg; here we add addr[0] extreme cases
      // -----------------------------------------------------------------
      cp_r0_addr_zero: coverpoint addr_is_zero[0] {
        bins zero    = {1};
        bins nonzero = {0};
      }

      cp_r0_addr_max: coverpoint addr_is_max[0] {
        bins max     = {1};
        bins not_max = {0};
      }

      // -----------------------------------------------------------------
      // TOR adjacent regions: region i and i+1 both TOR
      // -----------------------------------------------------------------
      cp_adj_tor_01: coverpoint adjacent_tor[0] {
        bins adjacent     = {1};
        bins not_adjacent = {0};
      }

      // -----------------------------------------------------------------
      // Region 0 mode with address extreme
      // -----------------------------------------------------------------
      cp_r0_mode: coverpoint pmp_cfg_mode[0] {
        bins off   = {PMP_MODE_OFF};
        bins tor   = {PMP_MODE_TOR};
        bins na4   = {PMP_MODE_NA4};
        bins napot = {PMP_MODE_NAPOT};
      }

      r0_addr_zero_mode_cross: cross cp_r0_addr_zero, cp_r0_mode {
        ignore_bins off_zero = binsof(cp_r0_mode) intersect {PMP_MODE_OFF};
      }

      r0_addr_max_mode_cross: cross cp_r0_addr_max, cp_r0_mode {
        ignore_bins off_max = binsof(cp_r0_mode) intersect {PMP_MODE_OFF};
      }

      // -----------------------------------------------------------------
      // Region 0 page-aligned address with NAPOT mode
      // -----------------------------------------------------------------
      cp_r0_page_aligned: coverpoint addr_page_aligned[0]
        iff (pmp_cfg_mode[0] == PMP_MODE_NAPOT) {
        bins aligned   = {1};
        bins unaligned = {0};
      }

      // -----------------------------------------------------------------
      // TOR region 0: lower bound is implicitly 0
      // Check if upper bound (pmpaddr[0]) is non-zero
      // -----------------------------------------------------------------
      cp_tor_r0_nonzero: coverpoint (!addr_is_zero[0])
        iff (pmp_cfg_mode[0] == PMP_MODE_TOR) {
        bins nonzero_upper = {1};
        bins zero_upper    = {0};  // degenerate empty TOR region
      }

      // -----------------------------------------------------------------
      // Address register upper bits coverage (address space quadrant)
      // -----------------------------------------------------------------
      cp_r0_addr_quadrant: coverpoint pmp_addr[0][31:30] {
        bins q0 = {2'b00};  // 0x00000000 - 0x3FFFFFFF
        bins q1 = {2'b01};  // 0x40000000 - 0x7FFFFFFF
        bins q2 = {2'b10};  // 0x80000000 - 0xBFFFFFFF
        bins q3 = {2'b11};  // 0xC0000000 - 0xFFFFFFFF
      }
    endgroup

    pmp_boundary_cg boundary_cg_inst;
    initial boundary_cg_inst = new();

    // =========================================================================
    // NEW: Region Priority / First-match Coverage
    // In PMP, the lowest-numbered matching region wins. Track scenarios
    // where multiple regions could match (all active) to verify priority.
    // =========================================================================
    covergroup pmp_region_prio_cg @(posedge clk_i);
      option.per_instance = 1;
      option.name = "pmp_region_prio_cg";

      // -----------------------------------------------------------------
      // Per-region mode vector (first 4 regions)
      // -----------------------------------------------------------------
      cp_r0_mode: coverpoint pmp_cfg_mode[0] {
        bins off   = {PMP_MODE_OFF};
        bins tor   = {PMP_MODE_TOR};
        bins na4   = {PMP_MODE_NA4};
        bins napot = {PMP_MODE_NAPOT};
      }

      cp_r1_mode: coverpoint pmp_cfg_mode[1 % PMPNumRegions] {
        bins off   = {PMP_MODE_OFF};
        bins tor   = {PMP_MODE_TOR};
        bins na4   = {PMP_MODE_NA4};
        bins napot = {PMP_MODE_NAPOT};
      }

      cp_r2_mode: coverpoint pmp_cfg_mode[2 % PMPNumRegions] {
        bins off   = {PMP_MODE_OFF};
        bins tor   = {PMP_MODE_TOR};
        bins na4   = {PMP_MODE_NA4};
        bins napot = {PMP_MODE_NAPOT};
      }

      cp_r3_mode: coverpoint pmp_cfg_mode[3 % PMPNumRegions] {
        bins off   = {PMP_MODE_OFF};
        bins tor   = {PMP_MODE_TOR};
        bins na4   = {PMP_MODE_NA4};
        bins napot = {PMP_MODE_NAPOT};
      }

      // -----------------------------------------------------------------
      // Cross: first two regions' modes
      // Captures which priority scenarios exist
      // -----------------------------------------------------------------
      r0_r1_mode_cross: cross cp_r0_mode, cp_r1_mode;

      // -----------------------------------------------------------------
      // Cross: all four regions' modes (full priority picture)
      // -----------------------------------------------------------------
      all_mode_cross: cross cp_r0_mode, cp_r1_mode, cp_r2_mode, cp_r3_mode {
        // Prune: at least one region must be non-OFF
        ignore_bins all_off = binsof(cp_r0_mode) intersect {PMP_MODE_OFF} &&
                              binsof(cp_r1_mode) intersect {PMP_MODE_OFF} &&
                              binsof(cp_r2_mode) intersect {PMP_MODE_OFF} &&
                              binsof(cp_r3_mode) intersect {PMP_MODE_OFF};
      }

      // -----------------------------------------------------------------
      // Priority: first active region's permission
      // Which RWX does the lowest-numbered active region have?
      // -----------------------------------------------------------------
      cp_first_active_rwx: coverpoint
          region_active[0]                           ? pmp_cfg_rwx[0] :
          region_active[1 % PMPNumRegions]           ? pmp_cfg_rwx[1 % PMPNumRegions] :
          region_active[2 % PMPNumRegions]           ? pmp_cfg_rwx[2 % PMPNumRegions] :
          region_active[3 % PMPNumRegions]           ? pmp_cfg_rwx[3 % PMPNumRegions] :
          3'b000 {
        bins no_access  = {3'b000};
        bins read_only  = {3'b001};
        bins write_only = {3'b010};
        bins read_write = {3'b011};
        bins exec_only  = {3'b100};
        bins read_exec  = {3'b101};
        bins write_exec = {3'b110};
        bins all_access = {3'b111};
      }

      // -----------------------------------------------------------------
      // Priority: first active region's lock status
      // -----------------------------------------------------------------
      cp_first_active_locked: coverpoint
          region_active[0]                   ? pmp_cfg_lock[0] :
          region_active[1 % PMPNumRegions]   ? pmp_cfg_lock[1 % PMPNumRegions] :
          region_active[2 % PMPNumRegions]   ? pmp_cfg_lock[2 % PMPNumRegions] :
          region_active[3 % PMPNumRegions]   ? pmp_cfg_lock[3 % PMPNumRegions] :
          1'b0 {
        bins locked   = {1};
        bins unlocked = {0};
      }

      // -----------------------------------------------------------------
      // First active RWX x fault
      // -----------------------------------------------------------------
      cp_any_fault: coverpoint pmp_any_fault {
        bins no_fault = {0};
        bins fault    = {1};
      }

      first_rwx_fault_cross: cross cp_first_active_rwx, cp_any_fault;
    endgroup

    pmp_region_prio_cg region_prio_cg_inst;
    initial region_prio_cg_inst = new();

    // =========================================================================
    // NEW: Per-region NAPOT Size Coverage
    // Extends pmp_warl_cg (which only covers region 0) to all regions.
    // =========================================================================
    for (genvar i = 0; i < PMPNumRegions; i++) begin : g_napot_per_region_cg

      covergroup pmp_napot_per_region_cg @(posedge clk_i);
        option.per_instance = 1;
        option.name = $sformatf("pmp_napot_region_%0d_cg", i);

        // -----------------------------------------------------------------
        // NAPOT trailing ones count (region size encoding)
        // Only meaningful when mode == NAPOT
        // -----------------------------------------------------------------
        cp_napot_trailing: coverpoint napot_trailing_ones[i]
          iff (pmp_cfg_mode[i] == PMP_MODE_NAPOT) {
          bins size_8B     = {0};    // no trailing ones => 8B
          bins size_16B    = {1};
          bins size_32B    = {2};
          bins size_64B    = {3};
          bins size_128B   = {4};
          bins size_256B   = {5};
          bins size_512B   = {6};
          bins size_1KB    = {7};
          bins size_2KB    = {8};
          bins size_4KB    = {9};
          bins size_8KB    = {10};
          bins size_16KB   = {11};
          bins size_32KB   = {12};
          bins size_64KB   = {13};
          bins size_128KB  = {14};
          bins size_256KB  = {15};
          bins size_512KB  = {16};
          bins size_1MB    = {17};
          bins size_2MB    = {18};
          bins size_4MB    = {19};
          bins size_8MB    = {20};
          bins size_16MB   = {21};
          bins size_32MB   = {22};
          bins size_64MB   = {23};
          bins size_128MB  = {24};
          bins size_256MB  = {25};
          bins size_512MB  = {26};
          bins size_1GB    = {27};
          bins size_2GB    = {28};
          bins size_4GB    = {29};
          bins larger      = {[30:$]};
        }

        // -----------------------------------------------------------------
        // NAPOT size x lock
        // -----------------------------------------------------------------
        cp_lock: coverpoint pmp_cfg_lock[i] {
          bins locked   = {1};
          bins unlocked = {0};
        }

        napot_lock_cross: cross cp_napot_trailing, cp_lock;

        // -----------------------------------------------------------------
        // NAPOT size x RWX
        // -----------------------------------------------------------------
        cp_rwx: coverpoint pmp_cfg_rwx[i]
          iff (pmp_cfg_mode[i] == PMP_MODE_NAPOT) {
          bins no_access  = {3'b000};
          bins read_only  = {3'b001};
          bins read_write = {3'b011};
          bins exec_only  = {3'b100};
          bins read_exec  = {3'b101};
          bins all_access = {3'b111};
          bins other      = default;
        }

        napot_rwx_cross: cross cp_napot_trailing, cp_rwx;
      endgroup

      pmp_napot_per_region_cg napot_per_region_cg_inst;
      initial napot_per_region_cg_inst = new();

    end : g_napot_per_region_cg

    // =========================================================================
    // NEW: ePMP Config x Region Config Cross Coverage
    // Covers how ePMP policy bits interact with per-region configuration.
    // =========================================================================
    covergroup pmp_epmp_region_cg @(posedge clk_i);
      option.per_instance = 1;
      option.name = "pmp_epmp_region_cg";

      // -----------------------------------------------------------------
      // ePMP bits
      // -----------------------------------------------------------------
      cp_mml: coverpoint mseccfg_mml {
        bins enabled  = {1};
        bins disabled = {0};
      }

      cp_mmwp: coverpoint mseccfg_mmwp {
        bins enabled  = {1};
        bins disabled = {0};
      }

      cp_rlb: coverpoint mseccfg_rlb {
        bins enabled  = {1};
        bins disabled = {0};
      }

      // -----------------------------------------------------------------
      // Region 0 config under ePMP
      // -----------------------------------------------------------------
      cp_r0_mode: coverpoint pmp_cfg_mode[0] {
        bins off   = {PMP_MODE_OFF};
        bins tor   = {PMP_MODE_TOR};
        bins na4   = {PMP_MODE_NA4};
        bins napot = {PMP_MODE_NAPOT};
      }

      cp_r0_lock: coverpoint pmp_cfg_lock[0] {
        bins locked   = {1};
        bins unlocked = {0};
      }

      cp_r0_rwx: coverpoint pmp_cfg_rwx[0] {
        bins no_access  = {3'b000};
        bins read_only  = {3'b001};
        bins read_write = {3'b011};
        bins exec_only  = {3'b100};
        bins read_exec  = {3'b101};
        bins all_access = {3'b111};
        bins other      = default;
      }

      // -----------------------------------------------------------------
      // MML x region 0 mode
      // -----------------------------------------------------------------
      mml_r0_mode_cross: cross cp_mml, cp_r0_mode;

      // -----------------------------------------------------------------
      // MML x region 0 lock
      // -----------------------------------------------------------------
      mml_r0_lock_cross: cross cp_mml, cp_r0_lock;

      // -----------------------------------------------------------------
      // MML x region 0 RWX
      // -----------------------------------------------------------------
      mml_r0_rwx_cross: cross cp_mml, cp_r0_rwx;

      // -----------------------------------------------------------------
      // MMWP x region 0 mode (whitelist policy affects matching)
      // -----------------------------------------------------------------
      mmwp_r0_mode_cross: cross cp_mmwp, cp_r0_mode;

      // -----------------------------------------------------------------
      // RLB x region 0 lock (bypass vs lock interaction)
      // -----------------------------------------------------------------
      rlb_r0_lock_cross: cross cp_rlb, cp_r0_lock;

      // -----------------------------------------------------------------
      // Full ePMP config x region 0 mode
      // -----------------------------------------------------------------
      epmp_full_r0_mode_cross: cross cp_mml, cp_mmwp, cp_rlb, cp_r0_mode;

      // -----------------------------------------------------------------
      // MML x region 0 lock x RWX (MML changes permission semantics)
      // -----------------------------------------------------------------
      mml_lock_rwx_cross: cross cp_mml, cp_r0_lock, cp_r0_rwx {
        ignore_bins mml_off = binsof(cp_mml) intersect {0};
      }

      // -----------------------------------------------------------------
      // Number of active regions under ePMP
      // -----------------------------------------------------------------
      cp_num_active: coverpoint num_active_regions {
        bins zero  = {0};
        bins one   = {1};
        bins two   = {2};
        bins three = {3};
        bins four  = {4};
        bins more  = {[5:$]};
      }

      mml_active_cross: cross cp_mml, cp_num_active;
      mmwp_active_cross: cross cp_mmwp, cp_num_active;

      // -----------------------------------------------------------------
      // Fault under ePMP
      // -----------------------------------------------------------------
      cp_iside_err: coverpoint pmp_iside_err {
        bins no_error = {0};
        bins error    = {1};
      }

      cp_dside_err: coverpoint pmp_dside_err iff (data_req) {
        bins no_error = {0};
        bins error    = {1};
      }

      // MML x MMWP x iside/dside faults
      epmp_iside_full_cross: cross cp_mml, cp_mmwp, cp_rlb, cp_iside_err;
      epmp_dside_full_cross: cross cp_mml, cp_mmwp, cp_rlb, cp_dside_err;
    endgroup

    pmp_epmp_region_cg epmp_region_cg_inst;
    initial epmp_region_cg_inst = new();

    // =========================================================================
    // NEW: PMP Address Register Bit-pattern Coverage
    // Covers interesting address register patterns for WARL verification.
    // =========================================================================
    covergroup pmp_addr_pattern_cg @(posedge clk_i);
      option.per_instance = 1;
      option.name = "pmp_addr_pattern_cg";

      // -----------------------------------------------------------------
      // Region 0 address upper nibble (memory region selection)
      // -----------------------------------------------------------------
      cp_r0_upper_nibble: coverpoint pmp_addr[0][31:28] {
        bins nibble[] = {[0:15]};
      }

      // -----------------------------------------------------------------
      // Region 0 address lower nibble
      // -----------------------------------------------------------------
      cp_r0_lower_nibble: coverpoint pmp_addr[0][3:0] {
        bins nibble[] = {[0:15]};
      }

      // -----------------------------------------------------------------
      // Region 0: all zeros, all ones, alternating patterns
      // -----------------------------------------------------------------
      cp_r0_special: coverpoint pmp_addr[0] {
        bins zero     = {32'h00000000};
        bins max      = {32'hFFFFFFFF};
        bins alt_01   = {32'h55555555};
        bins alt_10   = {32'hAAAAAAAA};
        bins low_half = {32'h0000FFFF};
        bins hi_half  = {32'hFFFF0000};
        bins default_bin = default;
      }

      // -----------------------------------------------------------------
      // Region 1 address upper nibble
      // -----------------------------------------------------------------
      cp_r1_upper_nibble: coverpoint pmp_addr[1 % PMPNumRegions][31:28] {
        bins nibble[] = {[0:15]};
      }

      // -----------------------------------------------------------------
      // Region 1 special patterns
      // -----------------------------------------------------------------
      cp_r1_special: coverpoint pmp_addr[1 % PMPNumRegions] {
        bins zero     = {32'h00000000};
        bins max      = {32'hFFFFFFFF};
        bins alt_01   = {32'h55555555};
        bins alt_10   = {32'hAAAAAAAA};
        bins default_bin = default;
      }

      // -----------------------------------------------------------------
      // TOR: region 1 addr > region 0 addr (valid TOR range)
      // -----------------------------------------------------------------
      cp_tor_valid_range: coverpoint (pmp_addr[1 % PMPNumRegions] > pmp_addr[0])
        iff (pmp_cfg_mode[1 % PMPNumRegions] == PMP_MODE_TOR) {
        bins valid_range   = {1};
        bins empty_range   = {0};  // degenerate: upper <= lower
      }

      // -----------------------------------------------------------------
      // TOR: region 0 addr == 0 (covers from address 0)
      // -----------------------------------------------------------------
      cp_tor_r0_from_zero: coverpoint addr_is_zero[0]
        iff (pmp_cfg_mode[0] == PMP_MODE_TOR) {
        bins from_zero  = {1};
        bins not_zero   = {0};
      }

      // -----------------------------------------------------------------
      // Granularity-related: low bits set below PMPGranularity
      // When PMPGranularity > 0, low bits are read-as-zero (WARL)
      // -----------------------------------------------------------------
      cp_r0_low_bits: coverpoint pmp_addr[0][1:0] {
        bins b00 = {2'b00};
        bins b01 = {2'b01};
        bins b10 = {2'b10};
        bins b11 = {2'b11};
      }

      // -----------------------------------------------------------------
      // Number of set bits in address (popcount coverage)
      // -----------------------------------------------------------------
      cp_r0_popcount: coverpoint $countones(pmp_addr[0]) {
        bins zero_bits  = {0};
        bins few_bits   = {[1:4]};
        bins some_bits  = {[5:12]};
        bins many_bits  = {[13:20]};
        bins most_bits  = {[21:28]};
        bins all_bits   = {[29:32]};
      }
    endgroup

    pmp_addr_pattern_cg addr_pattern_cg_inst;
    initial addr_pattern_cg_inst = new();

    // =========================================================================
    // NEW: PMP Configuration Transition Coverage
    // Covers configuration changes (mode transitions, lock toggles, etc.)
    // to verify correct CSR write behavior.
    // =========================================================================
    covergroup pmp_cfg_transition_cg @(posedge clk_i);
      option.per_instance = 1;
      option.name = "pmp_cfg_transition_cg";

      // -----------------------------------------------------------------
      // Region 0: mode transition
      // -----------------------------------------------------------------
      cp_r0_mode_changed: coverpoint mode_changed[0] {
        bins changed   = {1};
        bins unchanged = {0};
      }

      cp_r0_mode_prev: coverpoint pmp_cfg_mode_prev[0] {
        bins off   = {PMP_MODE_OFF};
        bins tor   = {PMP_MODE_TOR};
        bins na4   = {PMP_MODE_NA4};
        bins napot = {PMP_MODE_NAPOT};
      }

      cp_r0_mode_curr: coverpoint pmp_cfg_mode[0] {
        bins off   = {PMP_MODE_OFF};
        bins tor   = {PMP_MODE_TOR};
        bins na4   = {PMP_MODE_NA4};
        bins napot = {PMP_MODE_NAPOT};
      }

      // All mode transitions for region 0
      r0_mode_transition: cross cp_r0_mode_prev, cp_r0_mode_curr {
        // Only when actually changing
        ignore_bins no_change_off   = binsof(cp_r0_mode_prev) intersect {PMP_MODE_OFF}   &&
                                      binsof(cp_r0_mode_curr) intersect {PMP_MODE_OFF};
        ignore_bins no_change_tor   = binsof(cp_r0_mode_prev) intersect {PMP_MODE_TOR}   &&
                                      binsof(cp_r0_mode_curr) intersect {PMP_MODE_TOR};
        ignore_bins no_change_na4   = binsof(cp_r0_mode_prev) intersect {PMP_MODE_NA4}   &&
                                      binsof(cp_r0_mode_curr) intersect {PMP_MODE_NA4};
        ignore_bins no_change_napot = binsof(cp_r0_mode_prev) intersect {PMP_MODE_NAPOT} &&
                                      binsof(cp_r0_mode_curr) intersect {PMP_MODE_NAPOT};
      }

      // -----------------------------------------------------------------
      // Region 0: lock transition
      // -----------------------------------------------------------------
      cp_r0_lock_changed: coverpoint lock_changed[0] {
        bins changed   = {1};
        bins unchanged = {0};
      }

      cp_r0_lock_prev: coverpoint pmp_cfg_lock_prev[0] {
        bins locked   = {1};
        bins unlocked = {0};
      }

      cp_r0_lock_curr: coverpoint pmp_cfg_lock[0] {
        bins locked   = {1};
        bins unlocked = {0};
      }

      // Lock transitions: unlocked->locked, locked->unlocked (if RLB)
      r0_lock_transition: cross cp_r0_lock_prev, cp_r0_lock_curr {
        ignore_bins no_change_locked   = binsof(cp_r0_lock_prev) intersect {1} &&
                                          binsof(cp_r0_lock_curr) intersect {1};
        ignore_bins no_change_unlocked = binsof(cp_r0_lock_prev) intersect {0} &&
                                          binsof(cp_r0_lock_curr) intersect {0};
      }

      // -----------------------------------------------------------------
      // Region 0: RWX transition
      // -----------------------------------------------------------------
      cp_r0_rwx_changed: coverpoint rwx_changed[0] {
        bins changed   = {1};
        bins unchanged = {0};
      }

      // -----------------------------------------------------------------
      // Lock transition attempt while locked (should be blocked without RLB)
      // -----------------------------------------------------------------
      cp_locked_write_attempt: coverpoint (pmp_cfg_lock_prev[0] && mode_changed[0]) {
        bins write_while_locked = {1};
        bins normal             = {0};
      }

      // -----------------------------------------------------------------
      // ePMP config transition
      // -----------------------------------------------------------------
      cp_epmp_changed: coverpoint epmp_config_changed {
        bins changed   = {1};
        bins unchanged = {0};
      }

      cp_mml_prev: coverpoint mseccfg_mml_prev {
        bins enabled  = {1};
        bins disabled = {0};
      }

      cp_mml_curr: coverpoint mseccfg_mml {
        bins enabled  = {1};
        bins disabled = {0};
      }

      // MML transition (sticky bit: should only go 0->1)
      mml_transition: cross cp_mml_prev, cp_mml_curr {
        ignore_bins no_change_off = binsof(cp_mml_prev) intersect {0} &&
                                    binsof(cp_mml_curr) intersect {0};
        ignore_bins no_change_on  = binsof(cp_mml_prev) intersect {1} &&
                                    binsof(cp_mml_curr) intersect {1};
      }

      // -----------------------------------------------------------------
      // Any config change x fault (verify config change takes effect)
      // -----------------------------------------------------------------
      cp_any_fault: coverpoint pmp_any_fault {
        bins no_fault = {0};
        bins fault    = {1};
      }

      mode_change_fault_cross: cross cp_r0_mode_changed, cp_any_fault;
      lock_change_fault_cross: cross cp_r0_lock_changed, cp_any_fault;
      rwx_change_fault_cross:  cross cp_r0_rwx_changed, cp_any_fault;

      // -----------------------------------------------------------------
      // Region 1 mode transition
      // -----------------------------------------------------------------
      cp_r1_mode_changed: coverpoint mode_changed[1 % PMPNumRegions] {
        bins changed   = {1};
        bins unchanged = {0};
      }

      // -----------------------------------------------------------------
      // Region 1 lock transition
      // -----------------------------------------------------------------
      cp_r1_lock_changed: coverpoint lock_changed[1 % PMPNumRegions] {
        bins changed   = {1};
        bins unchanged = {0};
      }

      // -----------------------------------------------------------------
      // Region 1 RWX transition
      // -----------------------------------------------------------------
      cp_r1_rwx_changed: coverpoint rwx_changed[1 % PMPNumRegions] {
        bins changed   = {1};
        bins unchanged = {0};
      }

      // -----------------------------------------------------------------
      // Multiple regions changing simultaneously
      // -----------------------------------------------------------------
      cp_multi_mode_change: coverpoint $countones(mode_changed) {
        bins none = {0};
        bins one  = {1};
        bins two  = {2};
        bins more = {[3:$]};
      }
    endgroup

    pmp_cfg_transition_cg cfg_transition_cg_inst;
    initial cfg_transition_cg_inst = new();

  end : g_pmp_fcov

endinterface
