// SPDX-License-Identifier: Apache-2.0
// AXI4 Sequence Item - Transaction class for AXI4 protocol
//
// Represents a single AXI4 transaction (read or write).
// Used by driver, monitor, and sequencer.
//
// Fields:
//   - tx_type: READ or WRITE
//   - addr: 32-bit address
//   - len: burst length (0-255, actual beats = len+1)
//   - size: beat size (1/2/4/8 bytes)
//   - burst: burst type (FIXED/INCR/WRAP)
//   - id: transaction ID
//   - data[]: write data array
//   - strb[]: write strobe array
//   - resp[]: response array

class axi4_seq_item extends uvm_sequence_item;

  // Transaction type
  typedef enum bit { AXI4_READ = 0, AXI4_WRITE = 1 } tx_type_e;

  // Burst type
  typedef enum bit [1:0] {
    AXI4_BURST_FIXED = 2'b00,
    AXI4_BURST_INCR  = 2'b01,
    AXI4_BURST_WRAP  = 2'b10
  } burst_type_e;

  // Response type
  typedef enum bit [1:0] {
    AXI4_RESP_OKAY   = 2'b00,
    AXI4_RESP_EXOKAY = 2'b01,
    AXI4_RESP_SLVERR = 2'b10,
    AXI4_RESP_DECERR = 2'b11
  } resp_type_e;

  // Transaction fields
  rand tx_type_e    tx_type;
  rand bit [31:0]   addr;
  rand bit [3:0]    id;
  rand bit [7:0]    len;      // Burst length (0-255)
  rand bit [2:0]    size;     // Beat size (0=1B, 1=2B, 2=4B, 3=8B)
  rand burst_type_e burst;

  // Write data (for write transactions)
  rand bit [63:0]   data[];
  rand bit [7:0]    strb[];

  // Response data (for read transactions)
  bit [63:0]        rdata[];
  resp_type_e       resp[];

  // Metadata
  time              start_time;
  time              end_time;

  `uvm_object_utils_begin(axi4_seq_item)
    `uvm_field_enum(tx_type_e, tx_type, UVM_ALL_ON)
    `uvm_field_int(addr, UVM_ALL_ON)
    `uvm_field_int(id, UVM_ALL_ON)
    `uvm_field_int(len, UVM_ALL_ON)
    `uvm_field_int(size, UVM_ALL_ON)
    `uvm_field_enum(burst_type_e, burst, UVM_ALL_ON)
    `uvm_field_array_int(data, UVM_ALL_ON)
    `uvm_field_array_int(strb, UVM_ALL_ON)
    `uvm_field_array_int(rdata, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "axi4_seq_item");
    super.new(name);
  endfunction

  // Constraint: reasonable burst lengths
  constraint c_reasonable_len {
    len inside {[0:15]};  // Max 16 beats
  }

  // Constraint: size <= 8 bytes
  constraint c_valid_size {
    size <= 3;  // 8 bytes max
  }

  // Get beat count
  function int get_beat_count();
    return len + 1;
  endfunction

  // Get byte count per beat
  function int get_beat_bytes();
    return 1 << size;
  endfunction

  // Get total byte count
  function int get_total_bytes();
    return get_beat_count() * get_beat_bytes();
  endfunction

  // Convert to string
  function string convert2string();
    return $sformatf("%s addr=0x%08x id=%0d len=%0d size=%0d burst=%s",
      tx_type.name(), addr, id, len, size, burst.name());
  endfunction

endclass
