// SPDX-License-Identifier: Apache-2.0
// AXI4 Slave Memory Model for EH2 UVM Verification Platform
//
// This module implements a behavioral AXI4 slave memory. It responds
// to read and write transactions from the DUT's AXI4 master ports.
// Memory contents can be loaded via backdoor access for test loading.

module axi4_slave_mem #(
  parameter int ADDR_WIDTH    = 32,
  parameter int DATA_WIDTH    = 64,
  parameter int ID_WIDTH      = 4,
  parameter int MEM_SIZE      = 64 * 1024 * 1024,  // 64MB default
  parameter int RESPONSE_DELAY = 0                  // Fixed response delay in cycles
) (
  input  logic clk,
  input  logic rst_n,

  // Error injection control (from UVM driver)
  input  logic        error_inject_mode,  // 1 = use forced resp values
  input  logic [1:0]  force_bresp,        // Forced write response (when error_inject_mode=1)
  input  logic [1:0]  force_rresp,        // Forced read response  (when error_inject_mode=1)

  // Write Address Channel
  input  logic [ID_WIDTH-1:0]     awid,
  input  logic [ADDR_WIDTH-1:0]   awaddr,
  input  logic [7:0]              awlen,
  input  logic [2:0]              awsize,
  input  logic [1:0]              awburst,
  input  logic                    awvalid,
  output logic                    awready,

  // Write Data Channel
  input  logic [DATA_WIDTH-1:0]   wdata,
  input  logic [DATA_WIDTH/8-1:0] wstrb,
  input  logic                    wlast,
  input  logic                    wvalid,
  output logic                    wready,

  // Write Response Channel
  output logic [ID_WIDTH-1:0]     bid,
  output logic [1:0]              bresp,
  output logic                    bvalid,
  input  logic                    bready,

  // Read Address Channel
  input  logic [ID_WIDTH-1:0]     arid,
  input  logic [ADDR_WIDTH-1:0]   araddr,
  input  logic [7:0]              arlen,
  input  logic [2:0]              arsize,
  input  logic [1:0]              arburst,
  input  logic                    arvalid,
  output logic                    arready,

  // Read Data Channel
  output logic [ID_WIDTH-1:0]     rid,
  output logic [DATA_WIDTH-1:0]   rdata,
  output logic [1:0]              rresp,
  output logic                    rlast,
  output logic                    rvalid,
  input  logic                    rready
);

  //--------------------------------------------------------------------------
  // Memory Array
  //--------------------------------------------------------------------------
  logic [7:0] mem [bit [ADDR_WIDTH-1:0]];

  //--------------------------------------------------------------------------
  // Write Channel State Machine
  //--------------------------------------------------------------------------
  typedef enum logic [1:0] {
    WR_IDLE,
    WR_DATA,
    WR_RESP
  } wr_state_e;

  wr_state_e wr_state;
  logic [ID_WIDTH-1:0]     wr_id;
  logic [ADDR_WIDTH-1:0]   wr_addr;
  logic [7:0]              wr_len;
  logic [2:0]              wr_size;
  logic [1:0]              wr_burst;
  logic [7:0]              wr_beat_cnt;
  logic [ADDR_WIDTH-1:0]   wr_next_addr;
  logic [RESPONSE_DELAY:0] wr_delay_cnt;

  // Write state machine
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_state     <= WR_IDLE;
      awready      <= 1'b0;
      wready       <= 1'b0;
      bvalid       <= 1'b0;
      bid          <= '0;
      bresp        <= '0;
      wr_beat_cnt  <= '0;
      wr_delay_cnt <= '0;
    end else begin
      case (wr_state)
        WR_IDLE: begin
          awready <= 1'b1;
          if (awvalid && awready) begin
            wr_id       <= awid;
            wr_addr     <= awaddr;
            wr_len      <= awlen;
            wr_size     <= awsize;
            wr_burst    <= awburst;
            wr_beat_cnt <= '0;
            awready     <= 1'b0;
            wready      <= 1'b1;
            wr_state    <= WR_DATA;
          end
        end

        WR_DATA: begin
          if (wvalid && wready) begin
            // Write data to memory
            write_mem(wr_addr, wdata, wstrb, wr_size);

            if (wlast) begin
              wready <= 1'b0;
              if (RESPONSE_DELAY == 0) begin
                bvalid <= 1'b1;
                bid    <= wr_id;
                bresp  <= error_inject_mode ? force_bresp : 2'b00;
                wr_state <= WR_RESP;
              end else begin
                wr_delay_cnt <= RESPONSE_DELAY;
                wr_state     <= WR_RESP;
              end
            end else begin
              // Calculate next address for burst
              wr_addr      <= calc_next_addr(wr_addr, wr_size, wr_burst, wr_len);
              wr_beat_cnt  <= wr_beat_cnt + 1;
            end
          end
        end

        WR_RESP: begin
          if (wr_delay_cnt > 0) begin
            wr_delay_cnt <= wr_delay_cnt - 1;
          end else begin
            bvalid <= 1'b1;
            bid    <= wr_id;
            bresp  <= error_inject_mode ? force_bresp : 2'b00;
            if (bready) begin
              bvalid  <= 1'b0;
              wr_state <= WR_IDLE;
            end
          end
        end

        default: wr_state <= WR_IDLE;
      endcase
    end
  end

  //--------------------------------------------------------------------------
  // Read Channel State Machine
  //--------------------------------------------------------------------------
  typedef enum logic [1:0] {
    RD_IDLE,
    RD_DATA,
    RD_WAIT
  } rd_state_e;

  rd_state_e rd_state;
  logic [ID_WIDTH-1:0]     rd_id;
  logic [ADDR_WIDTH-1:0]   rd_addr;
  logic [7:0]              rd_len;
  logic [2:0]              rd_size;
  logic [1:0]              rd_burst;
  logic [7:0]              rd_beat_cnt;
  logic [RESPONSE_DELAY:0] rd_delay_cnt;

  // Read state machine
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_state     <= RD_IDLE;
      arready      <= 1'b0;
      rvalid       <= 1'b0;
      rlast        <= 1'b0;
      rid          <= '0;
      rdata        <= '0;
      rresp        <= '0;
      rd_beat_cnt  <= '0;
      rd_delay_cnt <= '0;
    end else begin
      case (rd_state)
        RD_IDLE: begin
          arready <= 1'b1;
          if (arvalid && arready) begin
            rd_id       <= arid;
            rd_addr     <= araddr;
            rd_len      <= arlen;
            rd_size     <= arsize;
            rd_burst    <= arburst;
            rd_beat_cnt <= '0;
            arready     <= 1'b0;
            if (RESPONSE_DELAY == 0) begin
              rvalid <= 1'b1;
              rdata  <= read_mem(araddr, arsize);
              rlast  <= (arlen == 0);
              rid    <= arid;
              rresp  <= error_inject_mode ? force_rresp : 2'b00;
              rd_state <= RD_DATA;
            end else begin
              rd_delay_cnt <= RESPONSE_DELAY;
              rd_state     <= RD_WAIT;
            end
          end
        end

        RD_WAIT: begin
          if (rd_delay_cnt > 0) begin
            rd_delay_cnt <= rd_delay_cnt - 1;
          end else begin
            rvalid   <= 1'b1;
            rdata    <= read_mem(rd_addr, rd_size);
            rlast    <= (rd_len == 0);
            rid      <= rd_id;
            rresp    <= error_inject_mode ? force_rresp : 2'b00;
            rd_state <= RD_DATA;
          end
        end

        RD_DATA: begin
          if (rvalid && rready) begin
            if (rd_beat_cnt == rd_len) begin
              // Last beat
              rvalid    <= 1'b0;
              rlast     <= 1'b0;
              rd_state  <= RD_IDLE;
            end else begin
              // More beats to come
              rd_addr     <= calc_next_addr(rd_addr, rd_size, rd_burst, rd_len);
              rd_beat_cnt <= rd_beat_cnt + 1;
              rdata       <= read_mem(rd_addr, rd_size);
              rlast       <= (rd_beat_cnt + 1 == rd_len);
              rid         <= rd_id;
            end
          end
        end

        default: rd_state <= RD_IDLE;
      endcase
    end
  end

  //--------------------------------------------------------------------------
  // Memory Access Tasks
  //--------------------------------------------------------------------------
  task write_mem(
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [DATA_WIDTH-1:0] data,
    input logic [DATA_WIDTH/8-1:0] strb,
    input logic [2:0] size
  );
    for (int i = 0; i < DATA_WIDTH/8; i++) begin
      if (strb[i]) begin
        mem[addr + i] = data[i*8 +: 8];
      end
    end
  endtask

  function automatic logic [DATA_WIDTH-1:0] read_mem(
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [2:0] size
  );
    logic [DATA_WIDTH-1:0] data;
    data = '0;
    for (int i = 0; i < DATA_WIDTH/8; i++) begin
      if (mem.exists(addr + i))
        data[i*8 +: 8] = mem[addr + i];
      else
        data[i*8 +: 8] = 8'h00;  // Return 0 for uninitialized
    end
    return data;
  endfunction

  //--------------------------------------------------------------------------
  // Address Calculation
  //--------------------------------------------------------------------------
  function automatic logic [ADDR_WIDTH-1:0] calc_next_addr(
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [2:0]            size,
    input logic [1:0]            burst,
    input logic [7:0]            len
  );
    logic [ADDR_WIDTH-1:0] next_addr;
    int unsigned bytes;
    int unsigned wrap_boundary;

    bytes = 1 << size;

    case (burst)
      2'b00: begin  // FIXED
        next_addr = addr;
      end
      2'b01: begin  // INCR
        next_addr = addr + bytes;
      end
      2'b10: begin  // WRAP
        wrap_boundary = bytes * (len + 1);
        next_addr = addr + bytes;
        // Check for wrap
        if ((next_addr % wrap_boundary) == 0) begin
          next_addr = next_addr - wrap_boundary;
        end
      end
      default: next_addr = addr + bytes;
    endcase

    return next_addr;
  endfunction

  //--------------------------------------------------------------------------
  // Backdoor Access Tasks (for test loading)
  //--------------------------------------------------------------------------

  // Write a single byte via backdoor
  task backdoor_write_byte(
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [7:0] data
  );
    mem[addr] = data;
  endtask

  // Read a single byte via backdoor
  task backdoor_read_byte(
    input  logic [ADDR_WIDTH-1:0] addr,
    output logic [7:0] data
  );
    if (mem.exists(addr))
      data = mem[addr];
    else
      data = 8'h00;
  endtask

  // Load HEX file into memory
  task load_hex(input string hex_file);
    int fd;
    int fgets_status;
    int scan_status;
    string line;
    logic [ADDR_WIDTH-1:0] addr;
    logic [7:0] data;

    fd = $fopen(hex_file, "r");
    if (fd == 0) begin
      $error("Failed to open HEX file: %s", hex_file);
      return;
    end

    while (!$feof(fd)) begin
      line = "";
      fgets_status = $fgets(line, fd);
      if (fgets_status == 0) begin
        continue;
      end
      // Parse hex line (simplified - assumes @address format)
      if (line.len() > 0 && line[0] == "@") begin
        scan_status = $sscanf(line, "@%h", addr);
        if (scan_status != 1) begin
          $error("Malformed HEX address line in %s: %s", hex_file, line);
        end
      end else if (line.len() > 0) begin
        scan_status = $sscanf(line, "%h", data);
        if (scan_status == 1) begin
          mem[addr] = data;
          addr = addr + 1;
        end else begin
          $error("Malformed HEX data line in %s: %s", hex_file, line);
        end
      end
    end

    $fclose(fd);
    $display("Loaded HEX file: %s", hex_file);
  endtask

  // Load binary data into memory at specified address
  task load_binary(
    input logic [ADDR_WIDTH-1:0] base_addr,
    input logic [7:0] data[],
    input int size
  );
    for (int i = 0; i < size; i++) begin
      mem[base_addr + i] = data[i];
    end
  endtask

  // Clear memory
  task clear_memory();
    mem.delete();
  endtask

endmodule
