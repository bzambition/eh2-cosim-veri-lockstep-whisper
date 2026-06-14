// SPDX-License-Identifier: Apache-2.0
// EH2 Environment Configuration
//
// Central configuration object for the EH2 UVM verification environment.
// All knobs are controlled via +plusargs for maximum flexibility.
//
// Plusarg examples:
//   +enable_irq_seq=1          Enable interrupt stimulus sequences
//   +enable_debug_seq=1        Enable debug stimulus sequences
//   +enable_fetch_toggle=1     Enable fetch-enable toggling
//   +enable_mem_error=1        Enable memory error injection
//   +enable_axi4_error_inject=1  Enable AXI4 error response injection
//   +axi4_error_pct=5          AXI4 error injection percentage (0-100)
//   +spurious_response_pct=5   Spurious response percentage (0-100)
//   +double_fault_threshold=3  Double-fault detection threshold
//   +max_interval=500          Max interval between stimulus events

class core_eh2_env_cfg extends uvm_object;

  `uvm_object_utils(core_eh2_env_cfg)

  // =========================================================================
  // Stimulus control knobs
  // =========================================================================

  // Interrupt sequences
  bit enable_irq_single_seq     = 0;  // Single interrupt per event
  bit enable_irq_multiple_seq   = 0;  // Multiple simultaneous interrupts
  bit enable_irq_nmi_seq        = 0;  // NMI stimulus
  bit enable_irq_drop_seq       = 0;  // Interrupt deassert sequence

  // Debug sequences
  bit enable_debug_seq          = 0;  // Debug halt/resume
  bit enable_debug_stress       = 0;  // Continuous debug requests
  bit enable_debug_single       = 0;  // Single debug pulse

  // Fetch enable
  bit enable_fetch_toggle       = 0;  // Random fetch-enable toggling

  // =========================================================================
  // AXI4 error injection control
  // =========================================================================
  bit enable_axi4_error_inject = 0;  // Enable AXI4 SLVERR/DECERR injection
  int axi4_error_pct           = 5;  // Error injection percentage (0-100)

  // =========================================================================
  // Memory model control
  // =========================================================================
  bit enable_mem_error          = 0;  // Enable memory error injection
  bit enable_spurious_response  = 0;  // Enable spurious memory responses
  int spurious_response_pct     = 0;  // Spurious response percentage (0-100)

  // =========================================================================
  // Double-fault detection
  // =========================================================================
  bit enable_double_fault_detector = 0;
  int double_fault_threshold       = 3;

  // =========================================================================
  // Stimulus timing
  // =========================================================================
  int max_interval              = 500;   // Max cycles between stimulus events
  int irq_delay_min             = 100;   // Min delay before first IRQ (ns)
  int irq_delay_max             = 5000;  // Max delay before first IRQ (ns)
  int debug_delay_min           = 1000;  // Min delay before debug request (ns)
  int debug_delay_max           = 10000; // Max delay before debug request (ns)

  // =========================================================================
  // Test completion
  // =========================================================================
  longint timeout_ns            = 64'd1_800_000_000_000;  // Wall-clock timeout (ns) - 30 minutes
  int max_cycles                = 100_000;     // Cycle count timeout
  bit use_signature             = 1;  // Use signature-based completion
  bit [31:0] signature_addr     = 32'hD058_0000;  // Mailbox/signature address
  bit [31:0] boot_addr          = 32'h8000_0000;  // Boot address

  // =========================================================================
  // ISA configuration
  // =========================================================================
  string isa                    = "rv32imac_zba_zbb_zbc_zbs";
  bit [31:0] misa_value         = 32'h40001104;  // RV32IMAC

  // =========================================================================
  // Binary paths
  // =========================================================================
  string binary                 = "";

  function new(string name = "core_eh2_env_cfg");
    super.new(name);
    // Read all plusargs
    void'($value$plusargs("enable_irq_seq=%0d", enable_irq_single_seq));
    void'($value$plusargs("enable_irq_single_seq=%0d", enable_irq_single_seq));
    void'($value$plusargs("enable_irq_multiple_seq=%0d", enable_irq_multiple_seq));
    void'($value$plusargs("enable_irq_nmi_seq=%0d", enable_irq_nmi_seq));
    void'($value$plusargs("enable_irq_drop_seq=%0d", enable_irq_drop_seq));
    void'($value$plusargs("enable_debug_seq=%0d", enable_debug_seq));
    void'($value$plusargs("enable_debug_stress=%0d", enable_debug_stress));
    void'($value$plusargs("enable_debug_single=%0d", enable_debug_single));
    void'($value$plusargs("enable_fetch_toggle=%0d", enable_fetch_toggle));
    void'($value$plusargs("enable_axi4_error_inject=%0d", enable_axi4_error_inject));
    void'($value$plusargs("axi4_error_pct=%d", axi4_error_pct));
    void'($value$plusargs("enable_mem_error=%0d", enable_mem_error));
    void'($value$plusargs("enable_spurious_response=%0d", enable_spurious_response));
    void'($value$plusargs("spurious_response_pct=%d", spurious_response_pct));
    void'($value$plusargs("enable_double_fault_detector=%0d", enable_double_fault_detector));
    void'($value$plusargs("double_fault_threshold=%d", double_fault_threshold));
    void'($value$plusargs("max_interval=%d", max_interval));
    void'($value$plusargs("timeout_ns=%d", timeout_ns));
    void'($value$plusargs("max_cycles=%d", max_cycles));
    void'($value$plusargs("bin=%s", binary));
    void'($value$plusargs("boot_addr=%h", boot_addr));
    void'($value$plusargs("irq_delay_min=%d", irq_delay_min));
    void'($value$plusargs("irq_delay_max=%d", irq_delay_max));
    void'($value$plusargs("debug_delay_min=%d", debug_delay_min));
    void'($value$plusargs("debug_delay_max=%d", debug_delay_max));

    // If enable_irq_seq is set, enable single + drop IRQ sequences
    // (multiple and NMI must be enabled independently)
    if (enable_irq_single_seq) begin
      enable_irq_drop_seq = 1;
    end
  endfunction

  function string convert2string();
    string s;
    s = "EH2 Environment Configuration:\n";
    s = {s, $sformatf("  IRQ sequences: single=%0b multi=%0b nmi=%0b drop=%0b\n",
         enable_irq_single_seq, enable_irq_multiple_seq, enable_irq_nmi_seq, enable_irq_drop_seq)};
    s = {s, $sformatf("  Debug sequences: debug=%0b stress=%0b single=%0b\n",
         enable_debug_seq, enable_debug_stress, enable_debug_single)};
    s = {s, $sformatf("  Fetch toggle=%0b\n", enable_fetch_toggle)};
    s = {s, $sformatf("  Memory: error=%0b spurious=%0b (pct=%0d)\n",
         enable_mem_error, enable_spurious_response, spurious_response_pct)};
    s = {s, $sformatf("  AXI4 error inject=%0b (pct=%0d)\n",
         enable_axi4_error_inject, axi4_error_pct)};
    s = {s, $sformatf("  Timeout: %0d ns / %0d cycles\n", timeout_ns, max_cycles)};
    s = {s, $sformatf("  Binary: %s\n", binary)};
    return s;
  endfunction

endclass
