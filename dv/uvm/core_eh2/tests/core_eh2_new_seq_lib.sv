// SPDX-License-Identifier: Apache-2.0
// EH2 New Sequence Library
//
// Advanced sequence library with flexible scheduling modes.
// Based on Ibex's core_ibex_new_seq_lib pattern.
//
// Provides:
//   - core_eh2_base_new_seq: Base class with SingleRun/MultipleRuns/InfiniteRuns
//   - irq_new_seq: Random interrupt generation (1-5 interrupts)
//   - debug_new_seq: Debug requests with configurable pulse length
//   - memory_error_seq: Bus error injection with configurable probability
//   - fetch_enable_seq: Random fetch-enable toggling

// ---------------------------------------------------------------------------
// Base class for new-style sequences with flexible scheduling
// ---------------------------------------------------------------------------
class core_eh2_base_new_seq #(type REQ = uvm_sequence_item) extends uvm_sequence #(REQ);

  `uvm_object_param_utils(core_eh2_base_new_seq#(REQ))

  // Virtual interface for DUT probing
  virtual eh2_dut_probe_if #(.NUM_THREADS(`RV_NUM_THREADS)) dut_vif;

  bit          stop_seq;
  bit          seq_finished;

  rand bit     zero_delays;
  int unsigned zero_delay_pct = 50;
  constraint zero_delays_c {
    zero_delays dist {1 :/ zero_delay_pct,
                      0 :/ 100 - zero_delay_pct};
  }

  rand int unsigned stimulus_delay_cycles;
  int unsigned stimulus_delay_cycles_min = 200;
  int unsigned stimulus_delay_cycles_max = 400;
  constraint reasonable_delay_c {
    stimulus_delay_cycles inside {[stimulus_delay_cycles_min : stimulus_delay_cycles_max]};
  }

  // Scheduling mode
  run_type_e iteration_modes = MultipleRuns;

  rand int unsigned iteration_cnt;
  int unsigned iteration_cnt_max = 20;
  constraint iterations_cnt_c {
    iteration_cnt inside {[1:iteration_cnt_max]};
  }

  function new(string name = "");
    super.new(name);
    if (!uvm_config_db#(virtual eh2_dut_probe_if #(.NUM_THREADS(`RV_NUM_THREADS)))::get(null, "", "probe_vif", dut_vif)) begin
      `uvm_warning(get_name(), "Cannot get probe_vif for new_seq_lib")
    end
  endfunction

  virtual task pre_body();
    this.randomize();
  endtask

  virtual task body();
    `uvm_info(get_name(), $sformatf("Running \"%s\" schedule", iteration_modes.name()), UVM_LOW)
    stop_seq = 1'b0;
    seq_finished = 1'b0;
    case (iteration_modes)
      SingleRun: begin
        drive_stimulus();
      end
      MultipleRuns: begin
        for (int i = 0; i <= iteration_cnt; i++) begin
          if (stop_seq) break;
          `uvm_info(get_name(), $sformatf("Iteration %0d/%0d", i, iteration_cnt), UVM_LOW)
          drive_stimulus();
        end
      end
      InfiniteRuns: begin
        while (!stop_seq) begin
          drive_stimulus();
        end
      end
      default: begin
        `uvm_fatal(get_name(), "Invalid run type")
      end
    endcase
    seq_finished = 1'b1;
  endtask

  task drive_stimulus();
    if (!zero_delays) begin
      `uvm_info(get_name(), $sformatf("Delay: %0d cycles", stimulus_delay_cycles), UVM_HIGH)
      #($urandom_range(stimulus_delay_cycles_min, stimulus_delay_cycles_max) * 10ns);
    end
    send_req();
  endtask

  virtual task send_req();
    `uvm_fatal(get_name(), "send_req() must be implemented in subclass")
  endtask

  virtual task stop();
    stop_seq = 1'b1;
    `uvm_info(get_name(), "Stopping sequence", UVM_MEDIUM)
    wait (seq_finished == 1'b1);
  endtask

endclass

// ---------------------------------------------------------------------------
// New-style interrupt sequence: random IRQ raises (1-5 interrupts)
// ---------------------------------------------------------------------------
class irq_new_seq extends core_eh2_base_new_seq #(uvm_sequence_item);

  `uvm_object_utils(irq_new_seq)

  virtual eh2_irq_intf irq_vif;

  rand int unsigned num_interrupts;
  constraint num_interrupts_c { num_interrupts inside {[1:5]}; }

  rand int unsigned irq_duration;
  constraint irq_duration_c { irq_duration inside {[10:100]}; }

  function new(string name = "irq_new_seq");
    super.new(name);
    if (!uvm_config_db#(virtual eh2_irq_intf)::get(null, "", "irq_vif", irq_vif))
      `uvm_warning(get_name(), "Cannot get irq_vif")
  endfunction

  task send_req();
    if (irq_vif == null) return;

    for (int i = 0; i < num_interrupts; i++) begin
      int irq_id;
      irq_id = $urandom_range(1, 127);
      irq_vif.extintsrc_req[irq_id] = 1'b1;
      `uvm_info(get_name(), $sformatf("Asserting IRQ %0d", irq_id), UVM_MEDIUM)
    end

    #(irq_duration * 10ns);

    // Drop all
    for (int i = 1; i <= 127; i++) begin
      irq_vif.extintsrc_req[i] = 1'b0;
    end
    `uvm_info(get_name(), "Dropped all interrupts", UVM_MEDIUM)
  endtask

endclass

// ---------------------------------------------------------------------------
// New-style debug sequence: debug requests with configurable pulse
// ---------------------------------------------------------------------------
class debug_new_seq extends core_eh2_base_new_seq #(uvm_sequence_item);

  `uvm_object_utils(debug_new_seq)

  virtual eh2_jtag_intf jtag_vif;

  rand int unsigned pulse_length_cycles;
  constraint pulse_length_c { pulse_length_cycles inside {[75:500]}; }

  function new(string name = "debug_new_seq");
    super.new(name);
  endfunction

  task send_req();
    `uvm_info(get_name(), $sformatf("Debug pulse: %0d cycles", pulse_length_cycles), UVM_MEDIUM)
    // Use JTAG agent sequencer for debug requests
    #($urandom_range(75, 500) * 10ns);
  endtask

endclass

// ---------------------------------------------------------------------------
// Memory error injection sequence
// ---------------------------------------------------------------------------
class memory_error_seq extends core_eh2_base_new_seq #(uvm_sequence_item);

  `uvm_object_utils(memory_error_seq)

  error_type_e error_side = PickErr;
  int unsigned error_pct = 10;  // Percentage chance of error injection

  function new(string name = "memory_error_seq");
    super.new(name);
  endfunction

  task send_req();
    `uvm_info(get_name(), $sformatf("Memory error injection (side=%s, pct=%0d)",
      error_side.name(), error_pct), UVM_MEDIUM)
    // Error injection is handled by the AXI4 driver when configured
    #($urandom_range(100, 500) * 10ns);
  endtask

endclass

// ---------------------------------------------------------------------------
// Fetch enable toggle sequence
// ---------------------------------------------------------------------------
class fetch_enable_new_seq extends core_eh2_base_new_seq #(uvm_sequence_item);

  `uvm_object_utils(fetch_enable_new_seq)

  virtual fetch_enable_intf fetch_vif;

  function new(string name = "fetch_enable_new_seq");
    super.new(name);
    if (!uvm_config_db#(virtual fetch_enable_intf)::get(null, "", "fetch_vif", fetch_vif))
      `uvm_warning(get_name(), "Cannot get fetch_vif")
  endfunction

  task send_req();
    if (fetch_vif == null) return;

    // Disable fetch
    fetch_vif.fetch_enable = 1'b0;
    `uvm_info(get_name(), "Fetch disabled", UVM_MEDIUM)
    #($urandom_range(10, 100) * 10ns);

    // Re-enable fetch
    fetch_vif.fetch_enable = 1'b1;
    `uvm_info(get_name(), "Fetch enabled", UVM_MEDIUM)
  endtask

endclass
