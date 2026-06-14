// SPDX-License-Identifier: Apache-2.0
// EH2 (VeeR) RISC-V core settings for the local riscv-dv version.

//-----------------------------------------------------------------------------
// Processor feature configuration
//-----------------------------------------------------------------------------
parameter int XLEN = 32;
parameter int NUM_FLOAT_GPR = 0;
parameter int NUM_GPR = 32;
parameter int NUM_VEC_GPR = 0;

parameter int VECTOR_EXTENSION_ENABLE = 0;
parameter int VLEN = 512;
parameter int ELEN = 32;
parameter int SLEN = 32;
parameter int VELEN = 2;
parameter int SELEN = 8;
parameter int MAX_LMUL = 8;

parameter int NUM_HARTS = 1;
parameter satp_mode_t SATP_MODE = BARE;

privileged_mode_t supported_privileged_mode[] = {MACHINE_MODE};

riscv_instr_name_t unsupported_instr[] = {};

bit support_unaligned_load_store = 1'b1;

// EH2 supports RV32IMAC plus configuration-selected bitmanip groups.
riscv_instr_group_t supported_isa[$] = {
  RV32I,
  RV32M,
  RV32A,
  RV32C
  ,RV32ZBA
  ,RV32ZBB
  ,RV32ZBC
  ,RV32ZBS
};

mtvec_mode_t supported_interrupt_mode[$] = {DIRECT, VECTORED};
int max_interrupt_vector_num = 32;

bit support_pmp = 0;
bit support_epmp = 0;
bit support_debug_mode = 1;
bit support_umode_trap = 0;
bit support_sfence = 0;

//-----------------------------------------------------------------------------
// Kernel section settings, required by riscv-dv even for machine-only tests.
//-----------------------------------------------------------------------------
int num_of_kernel_data_pages = 0;
int kernel_data_page_size = 4096;
int kernel_stack_len = 5000;
int kernel_program_instr_cnt = 400;

//-----------------------------------------------------------------------------
// Privileged CSR implementation
//-----------------------------------------------------------------------------
const privileged_reg_t implemented_csr[] = {
  MVENDORID,
  MARCHID,
  MIMPID,
  MHARTID,
  MSTATUS,
  MISA,
  MIE,
  MTVEC,
  MCOUNTEREN,
  MSCRATCH,
  MEPC,
  MCAUSE,
  MTVAL,
  MIP,
  MCYCLE,
  MINSTRET,
  MCYCLEH,
  MINSTRETH,
  MCOUNTINHIBIT,
  MHPMCOUNTER3,
  MHPMCOUNTER4,
  MHPMCOUNTER5,
  MHPMCOUNTER6,
  MHPMCOUNTER3H,
  MHPMCOUNTER4H,
  MHPMCOUNTER5H,
  MHPMCOUNTER6H,
  MHPMEVENT3,
  MHPMEVENT4,
  MHPMEVENT5,
  MHPMEVENT6,
  DCSR,
  DPC,
  TSELECT,
  TDATA1,
  TDATA2
};

// EH2 custom CSRs are generated numerically because upstream riscv-dv does not
// define symbolic names for the VeeR/EH2 machine CSRs.
const bit [11:0] custom_csr[] = {
  12'h7FF,  // mscause
  12'h7C0,  // mrac
  12'h7C9,  // mfdc
  12'h7F8,  // mcgc
  12'h7C6,  // mpmc
  12'h7C2,  // mcpc
  12'h7C4,  // dmst
  12'h7CE,  // mfdht
  12'h7CF,  // mfdhs
  12'hFC4,  // mhartnum
  12'h7FC,  // mhartstart
  12'h7FE,  // mnmipdel
  12'h7D2,  // mitcnt0
  12'h7D5,  // mitcnt1
  12'h7D3,  // mitb0
  12'h7D6,  // mitb1
  12'h7D4,  // mitctl0
  12'h7D7,  // mitctl1
  12'hBC0,  // mdeau
  12'hFC0,  // mdseac
  12'h7F0,  // micect
  12'h7F1,  // miccmect
  12'h7F2,  // mdccmect
  12'hBC8,  // meivt
  12'hFC8,  // meihap
  12'hBC9,  // meipt
  12'hBCA,  // meicpct
  12'hBCC,  // meicurpl
  12'hBCB   // meicidpl
};

//-----------------------------------------------------------------------------
// Functional coverage interrupt/exception settings
//-----------------------------------------------------------------------------
const interrupt_cause_t implemented_interrupt[] = {
  M_SOFTWARE_INTR,
  M_TIMER_INTR,
  M_EXTERNAL_INTR
};

const exception_cause_t implemented_exception[] = {
  INSTRUCTION_ACCESS_FAULT,
  ILLEGAL_INSTRUCTION,
  BREAKPOINT,
  LOAD_ADDRESS_MISALIGNED,
  LOAD_ACCESS_FAULT,
  STORE_AMO_ADDRESS_MISALIGNED,
  STORE_AMO_ACCESS_FAULT,
  ECALL_MMODE
};
