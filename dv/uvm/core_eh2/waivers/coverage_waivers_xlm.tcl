# SPDX-License-Identifier: Apache-2.0
# Xcelium Coverage Waivers for EH2
#
# Loaded by: imc -load build/cov -exec waivers/coverage_waivers_xlm.tcl
#
# This file configures coverage collection and loads refinement files
# for the EH2 UVM verification platform.

# --- Type exclusions ---

# Exclude coverage interfaces (functional coverage only, not code coverage)
exclude -type "eh2_fcov_if*" -metrics code:statement:fsm:assertion
exclude -type "eh2_pmp_fcov_if*" -metrics code:statement:fsm:assertion

# Exclude testbench infrastructure from code coverage
exclude -type "core_eh2_tb_top" -metrics code:statement:fsm:assertion

# --- Toggle exclusions on DUT top-level ---

# Hard-wired inputs that do not toggle during normal operation
exclude -type "veer_el2_core" -toggle "hart_id_i"
exclude -type "veer_el2_core" -toggle "boot_addr_i"

# --- Load refinement files ---

set waiver_dir [file dirname [file normalize [info script]]]

# Waivers for unreachable code (created via IMC GUI or manual analysis)
load -refinement "$waiver_dir/unr.vRefine"

# Waivers for auxiliary testbench code
load -refinement "$waiver_dir/aux_code.vRefine"
