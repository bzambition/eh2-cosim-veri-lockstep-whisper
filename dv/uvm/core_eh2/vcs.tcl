# VCS UCLI script used when run_regress.py/run_rtl.py enables --waves.
#
# FSDB/UVM-aware recording is enabled by compile-time Verdi options and the
# +UVM_VERDI_TRACE/+UVM_TR_RECORD plusargs.  This script only lets the
# simulation run to its normal UVM-controlled completion instead of exiting at
# time 0 after entering UCLI.
run
