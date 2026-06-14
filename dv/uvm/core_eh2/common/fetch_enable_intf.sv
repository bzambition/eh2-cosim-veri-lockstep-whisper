// SPDX-License-Identifier: Apache-2.0
// Fetch Enable Interface
// Controls the fetch-enable signal for the EH2 core.

interface fetch_enable_intf;
  logic fetch_enable = 1'b1;  // Default: fetch enabled

  modport driver (output fetch_enable);
  modport monitor (input fetch_enable);
endinterface
