// SPDX-License-Identifier: Apache-2.0
// EH2 Functional Coverage Interface
//
// Captures microarchitectural coverage for EH2 pipeline behavior.
// Bound to eh2_veer via SystemVerilog bind.
//
// Covergroups:
//   uarch_cg - Pipeline state, instruction categories, stalls, branches,
//              interrupts, exceptions, privilege modes, debug mode
//
// Enable via: +enable_eh2_fcov=1

interface eh2_fcov_if
  import eh2_pkg::*;
(
  input logic clk_i,
  input logic rst_l_i,

  // -- Pipeline stage valids --
  input logic        dec_ib0_valid_d,
  input logic        dec_ib1_valid_d,
  input logic        dec_i1_valid_e1,
  input logic        dec_tlu_i0_valid_e4,
  input logic        dec_tlu_i1_valid_e4,
  input logic        tlu_i0_commit_cmt,
  input logic        tlu_i1_commit_cmt,

  // -- Instruction at decode --
  input logic [31:0] dec_i0_instr_d,
  input logic [31:0] dec_i1_instr_d,
  input logic        dec_i0_pc4_d,
  input logic        dec_i1_pc4_d,

  // -- Decode packet --
  input eh2_dec_pkt_t i0_dec,
  input eh2_dec_pkt_t i1_dec,

  // -- Branch signals --
  input logic        exu_pmu_i0_br_misp,
  input logic        exu_pmu_i0_br_ataken,
  input logic        exu_pmu_i1_br_misp,
  input logic        exu_pmu_i1_br_ataken,
  input logic        exu_i0_br_valid_e4,
  input logic        exu_i1_br_valid_e4,
  input logic        exu_i0_br_mp_e4,
  input logic        exu_i1_br_mp_e4,

  // -- Pipeline flushes --
  input logic        exu_flush_final,
  input logic        exu_i0_flush_final,
  input logic        exu_i1_flush_final,
  input logic        dec_tlu_flush_lower_wb,
  input logic        dec_tlu_flush_mp_wb,

  // -- Stall signals --
  input logic        lsu_load_stall_any,
  input logic        lsu_store_stall_any,
  input logic        lsu_amo_stall_any,
  input logic        dec_pmu_decode_stall,
  input logic        dec_pmu_presync_stall,
  input logic        dec_pmu_postsync_stall,
  input logic        ifu_pmu_fetch_stall,

  // -- Exceptions --
  input logic        i0_exception_valid_e4,
  input logic        lsu_exc_valid_e4,
  input logic        ebreak_e4,
  input logic        ecall_e4,
  input logic        illegal_e4,
  input logic        mret_e4,
  input logic        inst_acc_e4,

  // -- Interrupts --
  input logic        interrupt_valid,
  input logic        take_ext_int,
  input logic        take_timer_int,
  input logic        take_soft_int,
  input logic        take_nmi,
  input logic        take_ce_int,

  // -- Debug --
  input logic        dec_tlu_dbg_halted,
  input logic        dec_tlu_debug_mode,

  // -- Privilege mode (EH2: always M-mode, but check anyway) --
  input logic [3:0]  dec_tlu_meicurpl,
  input logic [3:0]  dec_tlu_meicidpl,

  // -- LSU --
  input logic        lsu_pmu_misaligned_dc3,
  input logic        lsu_pmu_load_external_dc3,
  input logic        lsu_pmu_store_external_dc3,

  // -- PMU --
  input logic        ifu_pmu_ic_miss,
  input logic        ifu_pmu_ic_hit
);

  // =========================================================================
  // Instruction category classification
  // =========================================================================
  typedef enum {
    InstrCategoryALU,
    InstrCategoryMul,
    InstrCategoryDiv,
    InstrCategoryBranch,
    InstrCategoryJump,
    InstrCategoryLoad,
    InstrCategoryStore,
    InstrCategoryCSRAccess,
    InstrCategoryEBreak,
    InstrCategoryECall,
    InstrCategoryMRet,
    InstrCategoryFence,
    InstrCategoryAtomic,
    InstrCategoryIllegal,
    InstrCategoryNone
  } instr_category_e;

  // Classify I0 instruction at decode stage
  function automatic instr_category_e get_i0_instr_category();
    if (!dec_ib0_valid_d) return InstrCategoryNone;

    // Use decode packet for classification
    if (!i0_dec.legal)     return InstrCategoryIllegal;
    if (i0_dec.ebreak)      return InstrCategoryEBreak;
    if (i0_dec.ecall)       return InstrCategoryECall;
    if (i0_dec.mret)        return InstrCategoryMRet;
    if (i0_dec.fence || i0_dec.fence_i) return InstrCategoryFence;
    if (i0_dec.condbr || i0_dec.jal)    return InstrCategoryBranch;
    if (i0_dec.csr_read || i0_dec.csr_write || i0_dec.csr_set || i0_dec.csr_clr)
      return InstrCategoryCSRAccess;
    if (i0_dec.load)        return InstrCategoryLoad;
    if (i0_dec.store)       return InstrCategoryStore;
    if (i0_dec.mul)         return InstrCategoryMul;
    if (i0_dec.div || i0_dec.rem) return InstrCategoryDiv;
    if (i0_dec.atomic)      return InstrCategoryAtomic;

    // Default: ALU (includes bitmanip)
    return InstrCategoryALU;
  endfunction

  // Classify I1 instruction at decode stage
  function automatic instr_category_e get_i1_instr_category();
    if (!dec_ib1_valid_d) return InstrCategoryNone;

    if (!i1_dec.legal)     return InstrCategoryIllegal;
    if (i1_dec.ebreak)      return InstrCategoryEBreak;
    if (i1_dec.ecall)       return InstrCategoryECall;
    if (i1_dec.mret)        return InstrCategoryMRet;
    if (i1_dec.fence || i1_dec.fence_i) return InstrCategoryFence;
    if (i1_dec.condbr || i1_dec.jal)    return InstrCategoryBranch;
    if (i1_dec.csr_read || i1_dec.csr_write || i1_dec.csr_set || i1_dec.csr_clr)
      return InstrCategoryCSRAccess;
    if (i1_dec.load)        return InstrCategoryLoad;
    if (i1_dec.store)       return InstrCategoryStore;
    if (i1_dec.mul)         return InstrCategoryMul;
    if (i1_dec.div || i1_dec.rem) return InstrCategoryDiv;
    if (i1_dec.atomic)      return InstrCategoryAtomic;

    return InstrCategoryALU;
  endfunction

  // =========================================================================
  // Stall type classification
  // =========================================================================
  typedef enum {
    StallTypeNone,
    StallTypeLoad,
    StallTypeStore,
    StallTypeAMO,
    StallTypeDecode,
    StallTypePresync,
    StallTypePostsync,
    StallTypeFetch
  } stall_type_e;

  function automatic stall_type_e get_stall_type();
    if (lsu_load_stall_any)    return StallTypeLoad;
    if (lsu_store_stall_any)   return StallTypeStore;
    if (lsu_amo_stall_any)     return StallTypeAMO;
    if (dec_pmu_decode_stall)  return StallTypeDecode;
    if (dec_pmu_presync_stall) return StallTypePresync;
    if (dec_pmu_postsync_stall) return StallTypePostsync;
    if (ifu_pmu_fetch_stall)   return StallTypeFetch;
    return StallTypeNone;
  endfunction

  // =========================================================================
  // Pipeline stage states
  // =========================================================================
  typedef enum {
    IfStageEmpty,
    IfStageFetching
  } if_stage_state_e;

  typedef enum {
    IdStageEmpty,
    IdStageDecoding,
    IdStageStalled
  } id_stage_state_e;

  typedef enum {
    E4StageEmpty,
    E4StageValid,
    E4StageException
  } e4_stage_state_e;

  // =========================================================================
  // Main microarchitecture covergroup
  // =========================================================================
  covergroup uarch_cg @(posedge clk_i);
    option.per_instance = 1;
    option.name = "uarch_cg";

    // -----------------------------------------------------------------------
    // Instruction categories at decode
    // -----------------------------------------------------------------------
    cp_i0_instr_category: coverpoint get_i0_instr_category() {
      bins alu         = {InstrCategoryALU};
      bins mul         = {InstrCategoryMul};
      bins div         = {InstrCategoryDiv};
      bins branch      = {InstrCategoryBranch};
      bins jump        = {InstrCategoryJump};
      bins load        = {InstrCategoryLoad};
      bins store       = {InstrCategoryStore};
      bins csr_access  = {InstrCategoryCSRAccess};
      bins ebreak      = {InstrCategoryEBreak};
      bins ecall       = {InstrCategoryECall};
      bins mret        = {InstrCategoryMRet};
      bins fence       = {InstrCategoryFence};
      bins atomic      = {InstrCategoryAtomic};
      bins illegal     = {InstrCategoryIllegal};
      ignore_bins none = {InstrCategoryNone};
    }

    cp_i1_instr_category: coverpoint get_i1_instr_category() {
      bins alu         = {InstrCategoryALU};
      bins mul         = {InstrCategoryMul};
      bins div         = {InstrCategoryDiv};
      bins branch      = {InstrCategoryBranch};
      bins jump        = {InstrCategoryJump};
      bins load        = {InstrCategoryLoad};
      bins store       = {InstrCategoryStore};
      bins csr_access  = {InstrCategoryCSRAccess};
      bins ebreak      = {InstrCategoryEBreak};
      bins ecall       = {InstrCategoryECall};
      bins mret        = {InstrCategoryMRet};
      bins fence       = {InstrCategoryFence};
      bins atomic      = {InstrCategoryAtomic};
      bins illegal     = {InstrCategoryIllegal};
      ignore_bins none = {InstrCategoryNone};
    }

    // -----------------------------------------------------------------------
    // Stall types
    // -----------------------------------------------------------------------
    cp_stall_type: coverpoint get_stall_type() {
      bins none     = {StallTypeNone};
      bins load     = {StallTypeLoad};
      bins store    = {StallTypeStore};
      bins amo      = {StallTypeAMO};
      bins decode   = {StallTypeDecode};
      bins presync  = {StallTypePresync};
      bins postsync = {StallTypePostsync};
      bins fetch    = {StallTypeFetch};
    }

    // -----------------------------------------------------------------------
    // Branch behavior
    // -----------------------------------------------------------------------
    cp_i0_branch_taken: coverpoint exu_pmu_i0_br_ataken iff (exu_i0_br_valid_e4) {
      bins taken    = {1};
      bins not_taken = {0};
    }

    cp_i1_branch_taken: coverpoint exu_pmu_i1_br_ataken iff (exu_i1_br_valid_e4) {
      bins taken    = {1};
      bins not_taken = {0};
    }

    cp_i0_branch_mispredict: coverpoint exu_pmu_i0_br_misp iff (exu_i0_br_valid_e4) {
      bins mispredict = {1};
      bins correct    = {0};
    }

    cp_i1_branch_mispredict: coverpoint exu_pmu_i1_br_misp iff (exu_i1_br_valid_e4) {
      bins mispredict = {1};
      bins correct    = {0};
    }

    // -----------------------------------------------------------------------
    // Pipeline flushes
    // -----------------------------------------------------------------------
    cp_flush_type: coverpoint 1 {
      bins mispredict = {1} iff (dec_tlu_flush_mp_wb);
      bins exception  = {1} iff (dec_tlu_flush_lower_wb && !dec_tlu_flush_mp_wb);
      bins other      = {1} iff (exu_flush_final && !dec_tlu_flush_lower_wb);
    }

    // -----------------------------------------------------------------------
    // Exceptions
    // -----------------------------------------------------------------------
    cp_exception_type: coverpoint 1 iff (i0_exception_valid_e4) {
      bins inst_acc_fault = {1} iff (inst_acc_e4);
      bins illegal_instr  = {1} iff (illegal_e4);
      bins ebreak         = {1} iff (ebreak_e4);
      bins ecall          = {1} iff (ecall_e4);
    }

    cp_lsu_exception: coverpoint 1 iff (lsu_exc_valid_e4) {
      bins load_misaligned  = {1};
    }

    // -----------------------------------------------------------------------
    // Interrupts
    // -----------------------------------------------------------------------
    cp_interrupt_taken: coverpoint 1 iff (interrupt_valid) {
      bins external_int = {1} iff (take_ext_int);
      bins timer_int    = {1} iff (take_timer_int);
      bins software_int = {1} iff (take_soft_int);
      bins nmi          = {1} iff (take_nmi);
      bins ce_int       = {1} iff (take_ce_int);
    }

    // -----------------------------------------------------------------------
    // Debug mode
    // -----------------------------------------------------------------------
    cp_debug_mode: coverpoint dec_tlu_debug_mode {
      bins in_debug    = {1};
      bins not_debug   = {0};
    }

    cp_debug_halted: coverpoint dec_tlu_dbg_halted {
      bins halted     = {1};
      bins running    = {0};
    }

    // -----------------------------------------------------------------------
    // Dual-issue
    // -----------------------------------------------------------------------
    cp_dual_issue: coverpoint (dec_tlu_i0_valid_e4 && dec_tlu_i1_valid_e4) {
      bins dual  = {1};
      bins single = {0};
    }

    // -----------------------------------------------------------------------
    // Compressed vs uncompressed
    // -----------------------------------------------------------------------
    cp_i0_compressed: coverpoint dec_i0_pc4_d {
      bins compressed     = {0};
      bins uncompressed   = {1};
    }

    cp_i1_compressed: coverpoint dec_i1_pc4_d {
      bins compressed     = {0};
      bins uncompressed   = {1};
    }

    // -----------------------------------------------------------------------
    // Cache events
    // -----------------------------------------------------------------------
    cp_icache_hit: coverpoint ifu_pmu_ic_hit {
      bins hit  = {1};
    }

    cp_icache_miss: coverpoint ifu_pmu_ic_miss {
      bins miss = {1};
    }

    // -----------------------------------------------------------------------
    // LSU external accesses
    // -----------------------------------------------------------------------
    cp_lsu_external_load: coverpoint lsu_pmu_load_external_dc3 {
      bins external = {1};
    }

    cp_lsu_external_store: coverpoint lsu_pmu_store_external_dc3 {
      bins external = {1};
    }

    cp_lsu_misaligned: coverpoint lsu_pmu_misaligned_dc3 {
      bins misaligned = {1};
    }

    // -----------------------------------------------------------------------
    // Crosses
    // -----------------------------------------------------------------------

    // Instruction category x stall type
    stall_cross: cross cp_i0_instr_category, cp_stall_type {
      ignore_bins illegal_stall = binsof(cp_i0_instr_category.illegal);
    }

    // Branch taken x mispredict
    branch_cross: cross cp_i0_branch_taken, cp_i0_branch_mispredict;

    // Interrupt x debug mode
    interrupt_debug_cross: cross cp_interrupt_taken, cp_debug_mode;

    // Dual-issue x I0 category
    dual_issue_cross: cross cp_dual_issue, cp_i0_instr_category;

    // Exception x stall
    exception_stall_cross: cross cp_exception_type, cp_stall_type;

    // I0 x I1 instruction categories (for dual-issue coverage)
    pipe_cross: cross cp_i0_instr_category, cp_i1_instr_category {
      // Only meaningful when both pipes are active
      ignore_bins i1_empty = binsof(cp_i1_instr_category) intersect {InstrCategoryNone};
    }

    // Compressed x dual-issue
    compressed_dual_cross: cross cp_i0_compressed, cp_i1_compressed, cp_dual_issue;

  endgroup

  // =========================================================================
  // CSR Access Coverage
  // =========================================================================
  covergroup csr_cg @(posedge clk_i);
    option.per_instance = 1;
    option.name = "csr_cg";

    // CSR access type
    cp_csr_access_type: coverpoint 1 {
      bins read  = {1} iff (i0_dec.csr_read);
      bins write = {1} iff (i0_dec.csr_write);
      bins set   = {1} iff (i0_dec.csr_set);
      bins clear = {1} iff (i0_dec.csr_clr);
    }
  endgroup

  // =========================================================================
  // Pipeline Dual-Issue Coverage
  // =========================================================================
  covergroup dual_issue_cg @(posedge clk_i);
    option.per_instance = 1;
    option.name = "dual_issue_cg";

    // Dual-issue combinations
    cp_i0_cat: coverpoint get_i0_instr_category() {
      bins alu    = {InstrCategoryALU};
      bins mul    = {InstrCategoryMul};
      bins div    = {InstrCategoryDiv};
      bins branch = {InstrCategoryBranch};
      bins jump   = {InstrCategoryJump};
      bins load   = {InstrCategoryLoad};
      bins store  = {InstrCategoryStore};
      bins csr    = {InstrCategoryCSRAccess};
      ignore_bins none = {InstrCategoryNone};
    }

    cp_i1_cat: coverpoint get_i1_instr_category() {
      bins alu    = {InstrCategoryALU};
      bins mul    = {InstrCategoryMul};
      bins div    = {InstrCategoryDiv};
      bins branch = {InstrCategoryBranch};
      bins jump   = {InstrCategoryJump};
      bins load   = {InstrCategoryLoad};
      bins store  = {InstrCategoryStore};
      bins csr    = {InstrCategoryCSRAccess};
      ignore_bins none = {InstrCategoryNone};
    }

    // All meaningful dual-issue combinations
    dual_cross: cross cp_i0_cat, cp_i1_cat;
  endgroup

  // =========================================================================
  // Interrupt Coverage Detail
  // =========================================================================
  covergroup interrupt_cg @(posedge clk_i);
    option.per_instance = 1;
    option.name = "interrupt_cg";

    // Interrupt source
    cp_int_source: coverpoint 1 iff (interrupt_valid) {
      bins ext_int    = {1} iff (take_ext_int);
      bins timer_int  = {1} iff (take_timer_int);
      bins soft_int   = {1} iff (take_soft_int);
      bins nmi        = {1} iff (take_nmi);
      bins ce_int     = {1} iff (take_ce_int);
    }

    // NMI vs regular interrupt
    cp_nmi_type: coverpoint take_nmi iff (interrupt_valid) {
      bins nmi     = {1};
      bins regular = {0};
    }

    // Interrupt during debug mode
    cp_int_in_debug: cross cp_int_source, dec_tlu_debug_mode;
  endgroup

  // =========================================================================
  // CSR WARL Coverage (B2)
  // Verifies that EH2 CSRs correctly implement WARL behavior.
  // Tracks CSR writes and checks that read-back values are legal.
  // =========================================================================
  covergroup csr_warl_cg @(posedge clk_i);
    option.per_instance = 1;
    option.name = "csr_warl_cg";

    // CSR write address coverage - which CSR is being written
    cp_csr_addr: coverpoint i0_dec.csr_clr ? 12'hFFF :
                            i0_dec.csr_set ? 12'hFFF :
                            i0_dec.csr_write ? 12'hFFF :
                            i0_dec.csr_read ? 12'hFFF : 12'h000
      iff (i0_dec.csr_read || i0_dec.csr_write || i0_dec.csr_set || i0_dec.csr_clr) {
      // Standard RISC-V CSRs
      bins mstatus   = {12'h300};
      bins misa      = {12'h301};
      bins mie       = {12'h304};
      bins mtvec     = {12'h305};
      bins mscratch  = {12'h340};
      bins mepc      = {12'h341};
      bins mcause    = {12'h342};
      bins mtval     = {12'h343};
      bins mip       = {12'h344};
      bins mcycle    = {12'hB00};
      bins mcycleh   = {12'hB80};
      bins minstret  = {12'hB02};
      bins minstreth = {12'hB82};
      bins mcountinhibit = {12'h320};
      // EH2 custom CSRs
      bins mrac      = {12'h7C0};
      bins mfdc      = {12'h7C9};
      bins mcgc      = {12'h7F8};
      bins mpmc      = {12'h7C6};
      bins mcpc      = {12'h7C2};
      bins dmst      = {12'h7C4};
      bins mscause   = {12'h7FF};
      bins meivt     = {12'hBC8};
      bins meipt     = {12'hBC9};
      bins meicurpl  = {12'hBCC};
      bins meicidpl  = {12'hBCB};
      // Debug CSRs
      bins dcsr      = {12'h7B0};
      bins dpc       = {12'h7B1};
      bins dscratch0 = {12'h7B2};
      bins dscratch1 = {12'h7B3};
    }

    // CSR operation type
    cp_csr_op: coverpoint 1 iff (i0_dec.csr_read || i0_dec.csr_write ||
                                  i0_dec.csr_set || i0_dec.csr_clr) {
      bins read  = {1} iff (i0_dec.csr_read && !i0_dec.csr_write &&
                             !i0_dec.csr_set && !i0_dec.csr_clr);
      bins write = {1} iff (i0_dec.csr_write);
      bins set   = {1} iff (i0_dec.csr_set);
      bins clear = {1} iff (i0_dec.csr_clr);
    }

    // CSR address x operation cross
    csr_addr_op_cross: cross cp_csr_addr, cp_csr_op;
  endgroup

  // =========================================================================
  // Instruction Category Detail Coverage (B3)
  // Extends uarch_cg with more granular instruction sub-categories.
  // =========================================================================
  covergroup instr_detail_cg @(posedge clk_i);
    option.per_instance = 1;
    option.name = "instr_detail_cg";

    // Branch subtypes
    cp_branch_subtype: coverpoint 1 iff (dec_ib0_valid_d && (i0_dec.condbr || i0_dec.jal)) {
      bins beq  = {1} iff (i0_dec.beq);
      bins bne  = {1} iff (i0_dec.bne);
      bins bge  = {1} iff (i0_dec.bge);
      bins blt  = {1} iff (i0_dec.blt);
      bins jal  = {1} iff (i0_dec.jal);
    }

    // Load subtypes
    cp_load_subtype: coverpoint 1 iff (dec_ib0_valid_d && i0_dec.load) {
      bins byte_load  = {1} iff (i0_dec.by);
      bins half_load  = {1} iff (i0_dec.half);
      bins word_load  = {1} iff (i0_dec.word);
    }

    // Store subtypes
    cp_store_subtype: coverpoint 1 iff (dec_ib0_valid_d && i0_dec.store) {
      bins byte_store = {1} iff (i0_dec.by);
      bins half_store = {1} iff (i0_dec.half);
      bins word_store = {1} iff (i0_dec.word);
    }

    // ALU operation subtypes
    cp_alu_subtype: coverpoint 1 iff (dec_ib0_valid_d && i0_dec.legal &&
                                       !i0_dec.load && !i0_dec.store &&
                                       !i0_dec.mul && !i0_dec.div &&
                                       !i0_dec.condbr && !i0_dec.jal &&
                                       !i0_dec.csr_read && !i0_dec.csr_write &&
                                       !i0_dec.csr_set && !i0_dec.csr_clr &&
                                       !i0_dec.ebreak && !i0_dec.ecall &&
                                       !i0_dec.mret && !i0_dec.fence &&
                                       !i0_dec.fence_i) {
      bins add  = {1} iff (i0_dec.add);
      bins sub  = {1} iff (i0_dec.sub);
      bins sll  = {1} iff (i0_dec.sll);
      bins srl  = {1} iff (i0_dec.srl);
      bins sra  = {1} iff (i0_dec.sra);
      bins slt  = {1} iff (i0_dec.slt);
      bins land = {1} iff (i0_dec.land);
      bins lor  = {1} iff (i0_dec.lor);
      bins lxor = {1} iff (i0_dec.lxor);
    }

    // Signed vs unsigned operations
    cp_signed_ops: coverpoint 1 iff (dec_ib0_valid_d && (i0_dec.mul || i0_dec.div)) {
      bins signed_x_signed   = {1} iff (i0_dec.rs1_sign && i0_dec.rs2_sign);
      bins signed_x_unsigned = {1} iff (i0_dec.rs1_sign && !i0_dec.rs2_sign);
      bins unsigned_x_signed = {1} iff (!i0_dec.rs1_sign && i0_dec.rs2_sign);
      bins unsigned_x_unsigned = {1} iff (!i0_dec.rs1_sign && !i0_dec.rs2_sign);
    }

    // Mul vs div/rem
    cp_muldiv_type: coverpoint 1 iff (dec_ib0_valid_d && (i0_dec.mul || i0_dec.div)) {
      bins mul = {1} iff (i0_dec.mul);
      bins div = {1} iff (i0_dec.div && !i0_dec.rem);
      bins rem = {1} iff (i0_dec.rem);
    }

    // Presync/postsync (CSR fence instructions)
    cp_sync_type: coverpoint 1 iff (dec_ib0_valid_d && i0_dec.legal) {
      bins presync  = {1} iff (i0_dec.presync);
      bins postsync = {1} iff (i0_dec.postsync);
      bins both     = {1} iff (i0_dec.presync && i0_dec.postsync);
    }

    // Instruction width (compressed vs uncompressed)
    cp_i0_width: coverpoint dec_i0_pc4_d {
      bins compressed   = {0};
      bins uncompressed = {1};
    }

    // Instruction category (reuse function)
    cp_i0_category: coverpoint get_i0_instr_category() {
      bins alu    = {InstrCategoryALU};
      bins mul    = {InstrCategoryMul};
      bins div    = {InstrCategoryDiv};
      bins branch = {InstrCategoryBranch};
      bins jump   = {InstrCategoryJump};
      bins load   = {InstrCategoryLoad};
      bins store  = {InstrCategoryStore};
      bins csr    = {InstrCategoryCSRAccess};
      ignore_bins none = {InstrCategoryNone};
    }

    // Width x category cross
    width_category_cross: cross cp_i0_width, cp_i0_category;
  endgroup

  // =========================================================================
  // Controller FSM Coverage (B4)
  // EH2 uses distributed state (no single FSM). Track key state transitions:
  //   - Debug halt/run transitions
  //   - Exception entry/return
  //   - Interrupt entry
  //   - Reset recovery
  // =========================================================================
  covergroup controller_fsm_cg @(posedge clk_i);
    option.per_instance = 1;
    option.name = "controller_fsm_cg";

    // Debug state machine
    cp_debug_state: coverpoint 1 {
      bins running       = {1} iff (!dec_tlu_debug_mode && !dec_tlu_dbg_halted);
      bins debug_halted  = {1} iff (dec_tlu_debug_mode && dec_tlu_dbg_halted);
      bins debug_active  = {1} iff (dec_tlu_debug_mode && !dec_tlu_dbg_halted);
    }

    // Exception entry type
    cp_exception_entry: coverpoint 1 iff (i0_exception_valid_e4) {
      bins inst_acc_fault = {1} iff (inst_acc_e4);
      bins illegal_instr  = {1} iff (illegal_e4);
      bins ebreak         = {1} iff (ebreak_e4);
      bins ecall          = {1} iff (ecall_e4);
    }

    // Interrupt entry type
    cp_interrupt_entry: coverpoint 1 iff (interrupt_valid) {
      bins ext_int    = {1} iff (take_ext_int);
      bins timer_int  = {1} iff (take_timer_int);
      bins soft_int   = {1} iff (take_soft_int);
      bins nmi        = {1} iff (take_nmi);
      bins ce_int     = {1} iff (take_ce_int);
    }

    // MRET (exception return)
    cp_mret: coverpoint mret_e4 {
      bins mret_taken = {1};
    }

    // Pipeline flush reasons
    cp_flush_reason: coverpoint 1 {
      bins mispredict    = {1} iff (dec_tlu_flush_mp_wb);
      bins exception     = {1} iff (dec_tlu_flush_lower_wb && !dec_tlu_flush_mp_wb);
      bins pipe_flush    = {1} iff (exu_flush_final && !dec_tlu_flush_lower_wb);
    }

    // Debug mode x exception cross
    debug_exception_cross: cross cp_debug_state, cp_exception_entry;

    // Debug mode x interrupt cross
    debug_interrupt_cross: cross cp_debug_state, cp_interrupt_entry;

    // Exception x interrupt (can't happen simultaneously, but track both)
    exception_flush_cross: cross cp_exception_entry, cp_flush_reason;

    // MRET x debug mode
    mret_debug_cross: cross cp_mret, cp_debug_state;
  endgroup

  // =========================================================================
  // Pipeline Stage Coverage (B4 supplement)
  // Track pipeline utilization and hazard conditions.
  // =========================================================================
  covergroup pipeline_state_cg @(posedge clk_i);
    option.per_instance = 1;
    option.name = "pipeline_state_cg";

    // Pipeline slot utilization
    cp_pipe_utilization: coverpoint 1 {
      bins both_slots_valid = {1} iff (dec_ib0_valid_d && dec_ib1_valid_d);
      bins only_i0_valid    = {1} iff (dec_ib0_valid_d && !dec_ib1_valid_d);
      bins only_i1_valid    = {1} iff (!dec_ib0_valid_d && dec_ib1_valid_d);
      bins neither_valid    = {1} iff (!dec_ib0_valid_d && !dec_ib1_valid_d);
    }

    // E4 stage commit
    cp_e4_commit: coverpoint 1 {
      bins dual_commit  = {1} iff (tlu_i0_commit_cmt && tlu_i1_commit_cmt);
      bins i0_only      = {1} iff (tlu_i0_commit_cmt && !tlu_i1_commit_cmt);
      bins i1_only      = {1} iff (!tlu_i0_commit_cmt && tlu_i1_commit_cmt);
      bins no_commit    = {1} iff (!tlu_i0_commit_cmt && !tlu_i1_commit_cmt);
    }

    // Stall type (inline coverpoint)
    cp_stall: coverpoint get_stall_type() {
      bins none     = {StallTypeNone};
      bins load     = {StallTypeLoad};
      bins store    = {StallTypeStore};
      bins amo      = {StallTypeAMO};
      bins decode   = {StallTypeDecode};
      bins presync  = {StallTypePresync};
      bins postsync = {StallTypePostsync};
      bins fetch    = {StallTypeFetch};
    }

    // Branch mispredict
    cp_br_mispredict: coverpoint exu_pmu_i0_br_misp iff (exu_i0_br_valid_e4) {
      bins mispredict = {1};
      bins correct    = {0};
    }

    // Stall x pipeline state
    stall_pipe_cross: cross cp_pipe_utilization, cp_stall;

    // Commit x branch mispredict
    commit_branch_cross: cross cp_e4_commit, cp_br_mispredict;
  endgroup

  // =========================================================================
  // Coverage enable and instantiation
  // =========================================================================
  logic fcov_en;

  initial begin
    fcov_en = 0;
    if ($test$plusargs("enable_eh2_fcov"))
      fcov_en = 1;
  end

  uarch_cg         uarch_cg_inst;
  csr_cg           csr_cg_inst;
  dual_issue_cg    dual_issue_cg_inst;
  interrupt_cg     interrupt_cg_inst;
  csr_warl_cg      csr_warl_cg_inst;
  instr_detail_cg  instr_detail_cg_inst;
  controller_fsm_cg controller_fsm_cg_inst;
  pipeline_state_cg pipeline_state_cg_inst;

  initial begin
    uarch_cg_inst         = new();
    csr_cg_inst           = new();
    dual_issue_cg_inst    = new();
    interrupt_cg_inst     = new();
    csr_warl_cg_inst      = new();
    instr_detail_cg_inst  = new();
    controller_fsm_cg_inst = new();
    pipeline_state_cg_inst = new();
  end

endinterface
