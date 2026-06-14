// SPDX-License-Identifier: Apache-2.0
// EH2 JTAG Sequence Item
//
// Represents a JTAG/DMI transaction for debug module access.

class eh2_jtag_seq_item extends uvm_sequence_item;

  // Transaction type
  typedef enum bit {
    JTAG_READ  = 1'b0,
    JTAG_WRITE = 1'b1
  } jtag_op_e;

  // DMI register addresses (from Debug Spec)
  typedef enum bit [6:0] {
    DMI_DATA0    = 7'h04,
    DMI_DATA1    = 7'h05,
    DMI_DMCONTROL = 7'h10,
    DMI_DMSTATUS  = 7'h11,
    DMI_HAWINDOW  = 7'h15,
    DMI_ABSTRACTCS = 7'h16,
    DMI_COMMAND   = 7'h17,
    DMI_SBCS      = 7'h38,
    DMI_SBADDRESS0 = 7'h39,
    DMI_SBDATA0   = 7'h3C,
    DMI_SBDATA1   = 7'h3D,
    DMI_HALTSUM   = 7'h40
  } dmi_reg_e;

  // Transaction fields
  rand jtag_op_e   op;
  rand bit [6:0]   addr;
  rand bit [31:0]  wdata;
  bit [31:0]       rdata;
  bit [1:0]        resp;

  `uvm_object_utils_begin(eh2_jtag_seq_item)
    `uvm_field_enum(jtag_op_e, op, UVM_ALL_ON)
    `uvm_field_int(addr, UVM_ALL_ON)
    `uvm_field_int(wdata, UVM_ALL_ON)
    `uvm_field_int(rdata, UVM_ALL_ON)
    `uvm_field_int(resp, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "eh2_jtag_seq_item");
    super.new(name);
  endfunction

  function string convert2string();
    if (op == JTAG_READ)
      return $sformatf("READ  addr=0x%02x rdata=0x%08x", addr, rdata);
    else
      return $sformatf("WRITE addr=0x%02x wdata=0x%08x", addr, wdata);
  endfunction

endclass
