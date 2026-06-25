# VCS UCLI script used when run_regress.py/run_rtl.py enables --waves.
#
# SIM_DIR is set by run_rtl.py to the per-test output directory.  Dump RTL
# signals there so watch_wave opens the wave database from the current run.
if { [info exists ::env(SIM_DIR)] } {
    set sim_dir $::env(SIM_DIR)
} else {
    set sim_dir "."
}

if { [info exists ::env(VERDI_HOME)] } {
    fsdbDumpfile "${sim_dir}/waves.fsdb"
    fsdbDumpvars 0 core_eh2_tb_top +all
    fsdbDumpSVA 0 core_eh2_tb_top.dut
} else {
    dump -file "${sim_dir}/waves.vpd"
    dump -add { core_eh2_tb_top } -depth 0 -aggregates -scope "."
}

run
quit
