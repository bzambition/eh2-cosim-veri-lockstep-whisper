// SPDX-License-Identifier: Apache-2.0
// EH2 JTAG Driver
//
// Drives JTAG/DMI transactions to the DUT.
// Implements full JTAG TAP state machine and DMI protocol.
//
// DMI Register (41 bits, DR scan):
//   [40:34] addr  (7-bit DMI address)
//   [33:2]  data  (32-bit DMI data)
//   [1:0]   op    (2-bit: 0=NOP, 1=Read, 2=Write)
//
// DMI Response (41 bits, returned on next DR scan):
//   [40:34] addr
//   [33:2]  data  (32-bit read data for Read op)
//   [1:0]   resp  (2-bit: 0=OK, 1=Reserved, 2=Fail, 3=Busy)

class eh2_jtag_driver extends uvm_driver #(eh2_jtag_seq_item);

  `uvm_component_utils(eh2_jtag_driver)

  virtual eh2_jtag_intf vif;

  // JTAG TAP states
  typedef enum {
    TEST_LOGIC_RESET,
    RUN_TEST_IDLE,
    SELECT_DR_SCAN,
    CAPTURE_DR,
    SHIFT_DR,
    EXIT1_DR,
    PAUSE_DR,
    EXIT2_DR,
    UPDATE_DR,
    SELECT_IR_SCAN,
    CAPTURE_IR,
    SHIFT_IR,
    EXIT1_IR,
    PAUSE_IR,
    EXIT2_IR,
    UPDATE_IR
  } tap_state_e;

  tap_state_e tap_state;

  // DMI operation codes
  localparam DMI_OP_NOP   = 2'b00;
  localparam DMI_OP_READ  = 2'b01;
  localparam DMI_OP_WRITE = 2'b10;

  // DMI response codes
  localparam DMI_RESP_OK   = 2'b00;
  localparam DMI_RESP_FAIL = 2'b10;
  localparam DMI_RESP_BUSY = 2'b11;

  // DTMCS register bits
  localparam DTMCS_DMI_RESET = 16;  // dmireset bit

  // Busy retry configuration
  localparam MAX_BUSY_RETRIES = 5;
  localparam BUSY_RETRY_DELAY = 20;  // Clock cycles between retries

  // DMI register width
  localparam DMI_WIDTH = 41;

  // IR values for RISC-V Debug Spec
  localparam IR_DMI_ACCESS = 5'h11;  // DMI access register
  localparam IR_DTMCSR     = 5'h10;  // DTM Control and Status

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (!uvm_config_db#(virtual eh2_jtag_intf)::get(this, "", "jtag_vif", vif)) begin
      `uvm_fatal("jtag_driver", "Could not get JTAG virtual interface")
    end
  endfunction

  task run_phase(uvm_phase phase);
    // Initialize JTAG signals
    vif.driver_cb.tck    <= 1'b0;
    vif.driver_cb.tms    <= 1'b1;
    vif.driver_cb.tdi    <= 1'b0;
    vif.driver_cb.trst_n <= 1'b0;

    // Hold reset for 10 clock cycles
    repeat (10) @(posedge vif.clk);
    vif.driver_cb.trst_n <= 1'b1;
    repeat (5) @(posedge vif.clk);

    // Navigate to known state
    goto_state(TEST_LOGIC_RESET);
    goto_state(RUN_TEST_IDLE);

    // Set IR to DMI access (always use DMI for RISC-V debug)
    write_ir(IR_DMI_ACCESS);

    // Process transactions
    forever begin
      eh2_jtag_seq_item txn;
      seq_item_port.get_next_item(txn);
      drive_jtag_transaction(txn);
      seq_item_port.item_done();
    end
  endtask

  // Drive a JTAG/DMI transaction
  task drive_jtag_transaction(eh2_jtag_seq_item txn);
    `uvm_info("jtag_driver", $sformatf("Driving: %s", txn.convert2string()), UVM_HIGH)

    case (txn.op)
      eh2_jtag_seq_item::JTAG_READ: begin
        dmi_read(txn.addr, txn.rdata, txn.resp);
      end
      eh2_jtag_seq_item::JTAG_WRITE: begin
        dmi_write(txn.addr, txn.wdata, txn.resp);
      end
      default: begin
        `uvm_error("jtag_driver", $sformatf("Unknown JTAG op: %0d", txn.op))
      end
    endcase
  endtask

  // ---------------------------------------------------------------
  // TCK Generation
  // ---------------------------------------------------------------

  // Generate one TCK cycle (low half then high half, each half = 1 clk).
  // TDO is sampled at the rising edge of TCK (second posedge clk).
  task tck_cycle(bit tms_val, bit tdi_val, output bit tdo_val);
    vif.driver_cb.tms <= tms_val;
    vif.driver_cb.tdi <= tdi_val;
    @(posedge vif.clk);  // TCK low half
    vif.driver_cb.tck <= 1'b1;
    @(posedge vif.clk);  // TCK high half - TDO sampled here
    tdo_val = vif.driver_cb.tdo;
    vif.driver_cb.tck <= 1'b0;
  endtask

  // Wrapper for tck_cycle when TDO is not needed (navigation only)
  task tck_nav(bit tms_val);
    bit unused_tdo;
    tck_cycle(tms_val, 1'b0, unused_tdo);
    update_tap_state(tms_val);
  endtask

  // ---------------------------------------------------------------
  // TAP State Machine Navigation
  // ---------------------------------------------------------------

  // Navigate TAP state machine to target state.
  // Strategy: go to TEST_LOGIC_RESET first (hold TMS=1 for up to 5 cycles),
  // then navigate from there to the target using known paths.
  task goto_state(tap_state_e target);
    if (tap_state == target) return;

    // Go to TEST_LOGIC_RESET: hold TMS=1 for up to 5 cycles
    while (tap_state != TEST_LOGIC_RESET) begin
      tck_nav(1);
    end

    // Navigate from TEST_LOGIC_RESET to target
    case (target)
      TEST_LOGIC_RESET: ; // Already there
      RUN_TEST_IDLE: begin
        tck_nav(0);  // RTI
      end
      SELECT_DR_SCAN: begin
        tck_nav(0);  // RTI
        tck_nav(1);  // SELECT_DR
      end
      CAPTURE_DR: begin
        tck_nav(0);  // RTI
        tck_nav(1);  // SELECT_DR
        tck_nav(0);  // CAPTURE_DR
      end
      SHIFT_DR: begin
        tck_nav(0);  // RTI
        tck_nav(1);  // SELECT_DR
        tck_nav(0);  // CAPTURE_DR
        tck_nav(0);  // SHIFT_DR
      end
      EXIT1_DR: begin
        tck_nav(0);  // RTI
        tck_nav(1);  // SELECT_DR
        tck_nav(0);  // CAPTURE_DR
        tck_nav(1);  // EXIT1_DR
      end
      PAUSE_DR: begin
        tck_nav(0);  // RTI
        tck_nav(1);  // SELECT_DR
        tck_nav(0);  // CAPTURE_DR
        tck_nav(1);  // EXIT1_DR
        tck_nav(0);  // PAUSE_DR
      end
      EXIT2_DR: begin
        tck_nav(0);  // RTI
        tck_nav(1);  // SELECT_DR
        tck_nav(0);  // CAPTURE_DR
        tck_nav(1);  // EXIT1_DR
        tck_nav(0);  // PAUSE_DR
        tck_nav(1);  // EXIT2_DR
      end
      UPDATE_DR: begin
        tck_nav(0);  // RTI
        tck_nav(1);  // SELECT_DR
        tck_nav(0);  // CAPTURE_DR
        tck_nav(1);  // EXIT1_DR
        tck_nav(1);  // UPDATE_DR
      end
      SELECT_IR_SCAN: begin
        tck_nav(0);  // RTI
        tck_nav(1);  // SELECT_DR
        tck_nav(1);  // SELECT_IR
      end
      CAPTURE_IR: begin
        tck_nav(0);  // RTI
        tck_nav(1);  // SELECT_DR
        tck_nav(1);  // SELECT_IR
        tck_nav(0);  // CAPTURE_IR
      end
      SHIFT_IR: begin
        tck_nav(0);  // RTI
        tck_nav(1);  // SELECT_DR
        tck_nav(1);  // SELECT_IR
        tck_nav(0);  // CAPTURE_IR
        tck_nav(0);  // SHIFT_IR
      end
      EXIT1_IR: begin
        tck_nav(0);  // RTI
        tck_nav(1);  // SELECT_DR
        tck_nav(1);  // SELECT_IR
        tck_nav(0);  // CAPTURE_IR
        tck_nav(1);  // EXIT1_IR
      end
      PAUSE_IR: begin
        tck_nav(0);  // RTI
        tck_nav(1);  // SELECT_DR
        tck_nav(1);  // SELECT_IR
        tck_nav(0);  // CAPTURE_IR
        tck_nav(1);  // EXIT1_IR
        tck_nav(0);  // PAUSE_IR
      end
      EXIT2_IR: begin
        tck_nav(0);  // RTI
        tck_nav(1);  // SELECT_DR
        tck_nav(1);  // SELECT_IR
        tck_nav(0);  // CAPTURE_IR
        tck_nav(1);  // EXIT1_IR
        tck_nav(0);  // PAUSE_IR
        tck_nav(1);  // EXIT2_IR
      end
      UPDATE_IR: begin
        tck_nav(0);  // RTI
        tck_nav(1);  // SELECT_DR
        tck_nav(1);  // SELECT_IR
        tck_nav(0);  // CAPTURE_IR
        tck_nav(1);  // EXIT1_IR
        tck_nav(1);  // UPDATE_IR
      end
    endcase
  endtask

  // Update TAP state based on TMS value (mirrors hardware TAP FSM)
  task update_tap_state(bit tms);
    case (tap_state)
      TEST_LOGIC_RESET: tap_state = tms ? TEST_LOGIC_RESET : RUN_TEST_IDLE;
      RUN_TEST_IDLE:    tap_state = tms ? SELECT_DR_SCAN   : RUN_TEST_IDLE;
      SELECT_DR_SCAN:   tap_state = tms ? SELECT_IR_SCAN   : CAPTURE_DR;
      CAPTURE_DR:       tap_state = tms ? EXIT1_DR         : SHIFT_DR;
      SHIFT_DR:         tap_state = tms ? EXIT1_DR         : SHIFT_DR;
      EXIT1_DR:         tap_state = tms ? UPDATE_DR        : PAUSE_DR;
      PAUSE_DR:         tap_state = tms ? EXIT2_DR         : PAUSE_DR;
      EXIT2_DR:         tap_state = tms ? UPDATE_DR        : SHIFT_DR;
      UPDATE_DR:        tap_state = tms ? SELECT_DR_SCAN   : RUN_TEST_IDLE;
      SELECT_IR_SCAN:   tap_state = tms ? TEST_LOGIC_RESET : CAPTURE_IR;
      CAPTURE_IR:       tap_state = tms ? EXIT1_IR         : SHIFT_IR;
      SHIFT_IR:         tap_state = tms ? EXIT1_IR         : SHIFT_IR;
      EXIT1_IR:         tap_state = tms ? UPDATE_IR        : PAUSE_IR;
      PAUSE_IR:         tap_state = tms ? EXIT2_IR         : PAUSE_IR;
      EXIT2_IR:         tap_state = tms ? UPDATE_IR        : SHIFT_IR;
      UPDATE_IR:        tap_state = tms ? SELECT_DR_SCAN   : RUN_TEST_IDLE;
      default:          tap_state = TEST_LOGIC_RESET;
    endcase
  endtask

  // ---------------------------------------------------------------
  // IR Scan (set instruction register)
  // ---------------------------------------------------------------

  task write_ir(bit [4:0] ir_value);
    bit unused_tdo;

    // Navigate: RTI -> SELECT_DR -> SELECT_IR -> CAPTURE_IR -> SHIFT_IR
    goto_state(RUN_TEST_IDLE);
    tck_nav(1);  // SELECT_DR_SCAN
    tck_nav(1);  // SELECT_IR_SCAN
    tck_nav(0);  // CAPTURE_IR
    tck_nav(0);  // SHIFT_IR

    // Shift 5 bits of IR value (LSB first)
    for (int i = 0; i < 5; i++) begin
      bit is_last = (i == 4);
      tck_cycle(is_last, ir_value[i], unused_tdo);  // TMS=1 on last bit to exit
      update_tap_state(is_last);
    end
    // Now in EXIT1_IR

    // EXIT1_IR -> UPDATE_IR
    tck_nav(1);  // UPDATE_IR

    // UPDATE_IR -> RUN_TEST_IDLE
    tck_nav(0);  // RUN_TEST_IDLE

    // Small delay for IR update
    repeat (2) @(posedge vif.clk);
  endtask

  // ---------------------------------------------------------------
  // DR Scan - shift 41 bits in/out
  // ---------------------------------------------------------------

  // Shift 41 bits through DR. Returns the captured value.
  // input_data is shifted in (LSB first).
  // Returns the value captured from TDO (LSB first).
  task shift_dr_41(bit [DMI_WIDTH-1:0] input_data,
                   output bit [DMI_WIDTH-1:0] output_data);
    bit [DMI_WIDTH-1:0] captured;
    bit tdo_val;

    // Navigate: RTI -> SELECT_DR -> CAPTURE_DR -> SHIFT_DR
    goto_state(RUN_TEST_IDLE);
    tck_nav(1);  // SELECT_DR_SCAN
    tck_nav(0);  // CAPTURE_DR
    tck_nav(0);  // SHIFT_DR

    // Shift 41 bits, LSB first
    for (int i = 0; i < DMI_WIDTH; i++) begin
      bit is_last = (i == DMI_WIDTH - 1);

      // Drive TDI with input data bit, TMS=1 on last bit to exit
      tck_cycle(is_last, input_data[i], tdo_val);
      captured[i] = tdo_val;

      update_tap_state(is_last);
    end
    // Now in EXIT1_DR

    // EXIT1_DR -> UPDATE_DR
    tck_nav(1);  // UPDATE_DR

    // UPDATE_DR -> RUN_TEST_IDLE
    tck_nav(0);  // RUN_TEST_IDLE

    output_data = captured;
  endtask

  // ---------------------------------------------------------------
  // DMI Read/Write
  // ---------------------------------------------------------------

  // ---------------------------------------------------------------
  // DTMCS Access (for error recovery)
  // ---------------------------------------------------------------

  // Write to DTMCS register (for dmireset, etc.)
  task write_dtmcs(bit [31:0] wdata);
    bit [DMI_WIDTH-1:0] dmi_resp;
    bit unused_tdo;

    // Switch IR to DTMCS
    write_ir(IR_DTMCSR);

    // Shift 32 bits of DTMCS data (not 41 - DTMCS is 32-bit DR)
    goto_state(RUN_TEST_IDLE);
    tck_nav(1);  // SELECT_DR_SCAN
    tck_nav(0);  // CAPTURE_DR
    tck_nav(0);  // SHIFT_DR

    for (int i = 0; i < 32; i++) begin
      bit is_last = (i == 31);
      tck_cycle(is_last, wdata[i], unused_tdo);
      update_tap_state(is_last);
    end
    tck_nav(1);  // UPDATE_DR
    tck_nav(0);  // RUN_TEST_IDLE

    repeat (2) @(posedge vif.clk);

    // Switch IR back to DMI access
    write_ir(IR_DMI_ACCESS);
  endtask

  // Reset DMI state (clear busy)
  task reset_dmi();
    `uvm_info("jtag_driver", "Resetting DMI (dmireset)", UVM_LOW)
    write_dtmcs(1 << DTMCS_DMI_RESET);
    repeat (5) @(posedge vif.clk);
  endtask

  // ---------------------------------------------------------------
  // DMI Read/Write with Busy retry
  // ---------------------------------------------------------------

  // DMI Read: send read request, then read response on next scan
  // Handles Busy responses with retry and DTMCS error recovery
  task dmi_read(input bit [6:0] addr,
                output bit [31:0] rdata,
                output bit [1:0] resp);
    bit [DMI_WIDTH-1:0] dmi_req;
    bit [DMI_WIDTH-1:0] dmi_resp;
    int retry_count;

    retry_count = 0;
    resp = DMI_RESP_BUSY;

    while (resp == DMI_RESP_BUSY && retry_count < MAX_BUSY_RETRIES) begin
      // Build DMI read request: addr[40:34] | data=0[33:2] | op=READ[1:0]
      dmi_req = {addr, 32'b0, DMI_OP_READ};

      // First DR scan: send the read request (response is for previous op)
      shift_dr_41(dmi_req, dmi_resp);

      // Wait for DMI to process (DTM needs time)
      repeat (5) @(posedge vif.clk);

      // Second DR scan: send NOP, capture the read response
      shift_dr_41({7'b0, 32'b0, DMI_OP_NOP}, dmi_resp);

      // Extract response
      rdata = dmi_resp[33:2];
      resp  = dmi_resp[1:0];

      if (resp == DMI_RESP_BUSY) begin
        retry_count++;
        `uvm_warning("jtag_driver", $sformatf(
          "DMI READ Busy (addr=0x%02x), retry %0d/%0d",
          addr, retry_count, MAX_BUSY_RETRIES))

        // Reset DMI state to clear busy condition
        reset_dmi();

        // Delay before retry
        repeat (BUSY_RETRY_DELAY) @(posedge vif.clk);
      end
    end

    if (resp == DMI_RESP_BUSY) begin
      `uvm_error("jtag_driver", $sformatf(
        "DMI READ still Busy after %0d retries (addr=0x%02x)",
        MAX_BUSY_RETRIES, addr))
    end

    if (resp == DMI_RESP_FAIL) begin
      `uvm_warning("jtag_driver", $sformatf(
        "DMI READ Fail response (addr=0x%02x)", addr))
    end

    `uvm_info("jtag_driver", $sformatf("DMI READ: addr=0x%02x data=0x%08x resp=%0d",
      addr, rdata, resp), UVM_HIGH)
  endtask

  // DMI Write: send write request, then check response
  // Handles Busy responses with retry and DTMCS error recovery
  task dmi_write(input bit [6:0] addr,
                 input bit [31:0] wdata,
                 output bit [1:0] resp);
    bit [DMI_WIDTH-1:0] dmi_req;
    bit [DMI_WIDTH-1:0] dmi_resp;
    int retry_count;

    retry_count = 0;
    resp = DMI_RESP_BUSY;

    while (resp == DMI_RESP_BUSY && retry_count < MAX_BUSY_RETRIES) begin
      // Build DMI write request: addr[40:34] | data[33:2] | op=WRITE[1:0]
      dmi_req = {addr, wdata, DMI_OP_WRITE};

      // First DR scan: send the write request
      shift_dr_41(dmi_req, dmi_resp);

      // Wait for DMI to process
      repeat (5) @(posedge vif.clk);

      // Second DR scan: send NOP, capture the write response
      shift_dr_41({7'b0, 32'b0, DMI_OP_NOP}, dmi_resp);

      // Extract response
      resp = dmi_resp[1:0];

      if (resp == DMI_RESP_BUSY) begin
        retry_count++;
        `uvm_warning("jtag_driver", $sformatf(
          "DMI WRITE Busy (addr=0x%02x), retry %0d/%0d",
          addr, retry_count, MAX_BUSY_RETRIES))

        // Reset DMI state to clear busy condition
        reset_dmi();

        // Delay before retry
        repeat (BUSY_RETRY_DELAY) @(posedge vif.clk);
      end
    end

    if (resp == DMI_RESP_BUSY) begin
      `uvm_error("jtag_driver", $sformatf(
        "DMI WRITE still Busy after %0d retries (addr=0x%02x)",
        MAX_BUSY_RETRIES, addr))
    end

    if (resp == DMI_RESP_FAIL) begin
      `uvm_warning("jtag_driver", $sformatf(
        "DMI WRITE Fail response (addr=0x%02x)", addr))
    end

    `uvm_info("jtag_driver", $sformatf("DMI WRITE: addr=0x%02x data=0x%08x resp=%0d",
      addr, wdata, resp), UVM_HIGH)
  endtask

endclass
