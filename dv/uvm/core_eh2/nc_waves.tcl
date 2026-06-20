# NC/Incisive batch waveform setup.
#
# run_rtl.py loads this file when --waves is enabled for SIMULATOR=nc.
# SIM_DIR is provided by run_rtl.py and points at the per-test output
# directory, for example build/watch_smoke_nc/smoke_s1.

if { [info exists ::env(SIM_DIR)] } {
    set sim_dir $::env(SIM_DIR)
} else {
    set sim_dir "."
}

database -open "${sim_dir}/waves" -shm -default
probe -create -shm core_eh2_tb_top -depth all -all -memories
run
quit
