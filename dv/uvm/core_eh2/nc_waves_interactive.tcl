# NC/Incisive interactive (GUI) waveform setup
#
# Loaded by irun via `-input nc_waves_interactive.tcl` when launching the
# `make wave_nc TEST=<name>` target. The key difference vs the batch
# `nc_waves.tcl`:
#   - We open the SHM database and probe signals the same way.
#   - We do NOT call `run` followed by `quit`. After this script returns
#     control to ncsim, the user is dropped into the ncsim interactive
#     shell (or the SimVision GUI when `-gui` is passed alongside).
#   - The user can then issue commands like:
#       ncsim> run 100ns
#       ncsim> add wave -position end /core_eh2_tb_top/dut/veer/exu/*
#       ncsim> stop -name brk1 -object /core_eh2_tb_top/dut/veer/dec/...
#       ncsim> run
#   - SimVision GUI (if started with -gui) attaches to this ncsim session
#     and shows waves in real time as `run` advances simulation.
#
# To exit, the user types `quit` (or closes SimVision).

if { [info exists ::env(SIM_DIR)] } {
    set sim_dir $::env(SIM_DIR)
} else {
    set sim_dir "."
}

# Open the SHM database alongside the test work-dir, same layout as batch
# mode so the user can also do offline review with `simvision waves.shm`
# after exiting.
database -open "${sim_dir}/waves" -shm -default

# Probe the entire TB top by default. The user can `probe -delete` and
# add narrower probes interactively for performance.
probe -create -shm core_eh2_tb_top -depth all -all -memories

# Print a hint and hand control back to ncsim / SimVision. Do NOT run /
# quit here — that is the user's job in interactive mode.
puts ""
puts "==============================================================="
puts "  NC interactive mode ready."
puts "  SHM database: ${sim_dir}/waves.shm/"
puts "  Try:  run 1us   |  add wave ...  |  stop  |  reverse run"
puts "  Exit: quit"
puts "==============================================================="
