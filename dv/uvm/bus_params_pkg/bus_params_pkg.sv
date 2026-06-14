// SPDX-License-Identifier: Apache-2.0
// EH2 Bus Parameters Package
//
// Defines AXI4 bus width parameters used throughout the verification environment.
// Based on Ibex's bus_params_pkg pattern, adapted for EH2's AXI4 bus.

package bus_params_pkg;

  // Bus address width
  localparam int BUS_AW = 32;

  // Bus data width (EH2 AXI4 is 64-bit)
  localparam int BUS_DW = 64;

  // Bus data mask width (number of byte lanes)
  localparam int BUS_DBW = (BUS_DW >> 3);

  // Bus transfer size width (number of bits needed to select the number of bytes)
  localparam int BUS_SZW = $clog2($clog2(BUS_DBW) + 1);

  // Bus ID width (EH2 uses 4-bit IDs for LSU/IFU, 1-bit for SB/DMA)
  localparam int BUS_IDW = 4;

endpackage
