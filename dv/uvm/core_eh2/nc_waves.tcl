# TCL file invoked by irun (NC/Incisive) at run-time using:
#   -input @<this file>
#
# Mirrors vcs.tcl but emits the Cadence-native SHM database (viewable with
# simvision) rather than VCS's FSDB/VPD. When Verdi is on the link path
# (via -loadpli1) FSDB can be emitted alongside; that's left to operator
# discretion since Verdi/Incisive integration is site-specific.

# Each test runs in its own work_dir; SIM_DIR is exported by run_rtl.py.
if { [info exists ::env(SIM_DIR)] } {
    set sim_dir $::env(SIM_DIR)
} else {
    set sim_dir "."
}

# Open SHM database under the test's work dir so waves.shm/ lands beside
# sim_*.log / result.yaml (matches the FSDB layout VCS uses).
database -open "${sim_dir}/waves" -shm -default

# Probe everything under the TB top, including memories and packed/MDA
# signals — depth=all matches the VCS fsdbDumpvars `+all` flavour.
probe -create -shm core_eh2_tb_top -depth all -all -memories

# Run the simulation to completion. UVM's drain mechanism will eventually
# call $finish, which surfaces as a normal exit; quit makes that explicit.
run
quit
