// RTL file list for EH2
// Package definitions (must be compiled before library files)
rtl/design/include/eh2_def.sv

// Library files (compiled with -v = library mode, only when needed)
-v rtl/design/lib/beh_lib.sv
-v rtl/design/lib/eh2_lib.sv
-v rtl/design/lib/mem_lib.sv

// AXI/AHB converters
rtl/design/lib/ahb_to_axi4.sv
rtl/design/lib/axi4_to_ahb.sv

// IFU
rtl/design/ifu/eh2_ifu_aln_ctl.sv
rtl/design/ifu/eh2_ifu_bp_ctl.sv
rtl/design/ifu/eh2_ifu_btb_mem.sv
rtl/design/ifu/eh2_ifu_compress_ctl.sv
rtl/design/ifu/eh2_ifu_iccm_mem.sv
rtl/design/ifu/eh2_ifu_ic_mem.sv
rtl/design/ifu/eh2_ifu_ifc_ctl.sv
rtl/design/ifu/eh2_ifu_mem_ctl.sv
rtl/design/ifu/eh2_ifu.sv
rtl/design/ifu/eh2_ifu_tb_memread.sv

// Decode
rtl/design/dec/eh2_dec_csr.sv
rtl/design/dec/eh2_dec_decode_ctl.sv
rtl/design/dec/eh2_dec_gpr_ctl.sv
rtl/design/dec/eh2_dec_ib_ctl.sv
rtl/design/dec/eh2_dec.sv
rtl/design/dec/eh2_dec_tlu_ctl.sv
rtl/design/dec/eh2_dec_tlu_top.sv
rtl/design/dec/eh2_dec_trigger.sv

// Execution Unit
rtl/design/exu/eh2_exu_alu_ctl.sv
rtl/design/exu/eh2_exu_div_ctl.sv
rtl/design/exu/eh2_exu_mul_ctl.sv
rtl/design/exu/eh2_exu.sv

// Load/Store Unit
rtl/design/lsu/eh2_lsu_addrcheck.sv
rtl/design/lsu/eh2_lsu_amo.sv
rtl/design/lsu/eh2_lsu_bus_buffer.sv
rtl/design/lsu/eh2_lsu_bus_intf.sv
rtl/design/lsu/eh2_lsu_clkdomain.sv
rtl/design/lsu/eh2_lsu_dccm_ctl.sv
rtl/design/lsu/eh2_lsu_dccm_mem.sv
rtl/design/lsu/eh2_lsu_ecc.sv
rtl/design/lsu/eh2_lsu_lsc_ctl.sv
rtl/design/lsu/eh2_lsu_stbuf.sv
rtl/design/lsu/eh2_lsu.sv
rtl/design/lsu/eh2_lsu_trigger.sv

// Debug
rtl/design/dbg/eh2_dbg.sv

// DMI (Verilog)
rtl/design/dmi/dmi_jtag_to_core_sync.v
rtl/design/dmi/dmi_wrapper.v
rtl/design/dmi/rvjtag_tap.v

// Top-level
rtl/design/eh2_dma_ctrl.sv
rtl/design/eh2_mem.sv
rtl/design/eh2_pic_ctrl.sv
rtl/design/eh2_veer.sv
rtl/design/eh2_veer_wrapper.sv

// RVFI (formal verification interface)
rtl/eh2_veer_wrapper_rvfi.sv
