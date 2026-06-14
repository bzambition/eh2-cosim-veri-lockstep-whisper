// SPDX-License-Identifier: Apache-2.0
// EH2 Cosim Binary Loader
//
// Helper functions for the cosim scoreboard to load test binaries (raw or
// Verilog-style hex format @ADDR/byte) into Spike's memory model via the
// riscv_cosim_write_mem_byte DPI call.
//
// Included from inside eh2_cosim_scoreboard so it can reference cosim_handle,
// stored_bin_path, stored_base_addr without explicit forwarding.

  // Load binary into co-simulation reference model.
  // Dispatches to load_hex (.hex extension) or load_raw_binary, then records
  // the path/base for reset-recovery reload.
  function void load_binary(string bin_path, bit [31:0] base_addr);
    `uvm_info("cosim", $sformatf("Loading binary: %s at 0x%08x", bin_path, base_addr), UVM_LOW)

    if (cosim_handle == null) begin
      `uvm_error("cosim", "Cannot load binary: cosim not initialized")
      return;
    end

    if (bin_path.len() > 4 && bin_path.substr(bin_path.len()-4, bin_path.len()-1) == ".hex") begin
      load_hex(bin_path, base_addr);
    end else begin
      load_raw_binary(bin_path, base_addr);
    end

    stored_bin_path = bin_path;
    stored_base_addr = base_addr;
  endfunction

  function void load_raw_binary(string bin_path, bit [31:0] base_addr);
    int fd;
    int byte_val;
    bit [7:0] mem_byte;
    bit [31:0] addr;
    int bytes_loaded;

    fd = $fopen(bin_path, "rb");
    if (fd == 0) begin
      `uvm_error("cosim", $sformatf("Cannot open binary file: %s", bin_path))
      return;
    end

    addr = base_addr;
    bytes_loaded = 0;
    while (!$feof(fd)) begin
      byte_val = $fread(mem_byte, fd);
      if (byte_val == 1) begin
        riscv_cosim_write_mem_byte(cosim_handle, int'(addr), int'(mem_byte));
        addr++;
        bytes_loaded++;
      end
    end
    $fclose(fd);

    `uvm_info("cosim", $sformatf("Loaded %0d bytes (raw) into cosim at 0x%08x",
      bytes_loaded, base_addr), UVM_LOW)
  endfunction

  function void load_hex(string hex_path, bit [31:0] base_addr);
    int fd;
    int addr;
    int c;
    bit [7:0] val;
    int nybble_count;
    int bytes_loaded;

    fd = $fopen(hex_path, "r");
    if (fd == 0) begin
      `uvm_error("cosim", $sformatf("Cannot open hex file: %s", hex_path))
      return;
    end

    addr = base_addr;
    bytes_loaded = 0;
    nybble_count = 0;
    val = 0;

    while (!$feof(fd)) begin
      c = $fgetc(fd);
      if (c < 0) break;

      if (c == "@") begin
        int new_addr;
        new_addr = 0;
        while (!$feof(fd)) begin
          c = $fgetc(fd);
          if (c < 0) break;
          if (c >= "0" && c <= "9")      new_addr = (new_addr << 4) | (c - "0");
          else if (c >= "a" && c <= "f") new_addr = (new_addr << 4) | (c - "a" + 10);
          else if (c >= "A" && c <= "F") new_addr = (new_addr << 4) | (c - "A" + 10);
          else break;
        end
        addr = new_addr;
        nybble_count = 0;
        val = 0;
      end else if (c >= "0" && c <= "9") begin
        val = (val << 4) | (c - "0");
        nybble_count++;
      end else if (c >= "a" && c <= "f") begin
        val = (val << 4) | (c - "a" + 10);
        nybble_count++;
      end else if (c >= "A" && c <= "F") begin
        val = (val << 4) | (c - "A" + 10);
        nybble_count++;
      end else if (c == " " || c == "\t" || c == "\n" || c == "\r") begin
        if (nybble_count > 0) begin
          riscv_cosim_write_mem_byte(cosim_handle, int'(addr), int'(val));
          addr++;
          bytes_loaded++;
          val = 0;
          nybble_count = 0;
        end
      end
    end
    if (nybble_count > 0) begin
      riscv_cosim_write_mem_byte(cosim_handle, int'(addr), int'(val));
      bytes_loaded++;
    end

    $fclose(fd);
    `uvm_info("cosim", $sformatf("Loaded %0d bytes (hex) into cosim at 0x%08x",
      bytes_loaded, base_addr), UVM_LOW)
  endfunction
