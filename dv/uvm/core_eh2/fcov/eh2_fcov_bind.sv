// SPDX-License-Identifier: Apache-2.0
// EH2 Functional Coverage - Bind Module
//
// Coverage interfaces are instantiated directly in core_eh2_tb_top.sv
// using hierarchical references to access signals across module boundaries.
// This approach is used because EH2's module hierarchy requires cross-module
// references that bind cannot easily reach (e.g., dut.veer.dec.decode.*).
//
// The eh2_fcov_if and eh2_pmp_fcov_if interfaces are created in tb_top
// and connected via assign statements. This file exists as a compilation
// placeholder required by the filelist.

// Coverage instantiation is in core_eh2_tb_top.sv:
//   eh2_fcov_if u_fcov_if (...);
//   eh2_pmp_fcov_if u_pmp_fcov_if (...);
