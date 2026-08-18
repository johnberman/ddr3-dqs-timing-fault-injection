// tb_top.sv
//
// Top-level testbench. Ties together:
//   - hmc_stimulus_driver   (address/command + write data generation)
//   - ddr3_behavioral_model (timing-accurate DRAM endpoint with
//                             per-lane DQS skew / eye-narrowing fault
//                             injection)
//   - hmc_timing_assertions (SVA-based checking)
//   - hmc_scoreboard         (data-integrity tracking + structured log)
//
// TEST PLAN
//
//   Phase 1 -- Baseline / control case.
//     Clean writes and reads with fault injection disabled. Establishes
//     that the base timing model passes before any fault is introduced.
//     A fault-injection testbench that has never been shown to pass
//     clean is not evidence of anything, so this phase exists to make
//     the later failures meaningful.
//
//   Phase 2 -- DQS skew sweep, lane 2.
//     Sweep injected DQS arrival skew on one lane from 0 ps upward past
//     the tDS/tDH margin, writing and reading back at each step. This
//     is the automated equivalent of the original 2017-18 debug method
//     (modifying the driving FPGA's output timing to see whether the
//     fault worsened or cleared), turned into a repeatable parametric
//     sweep instead of a bench-side experiment.
//
//   Phase 3 -- Eye-narrowing sweep, lane 1.
//     Hold skew at zero and instead shrink the effective data-valid
//     window, modeling SI degradation (ISI, crosstalk, reflections)
//     rather than pure skew. Demonstrates that these two mechanisms
//     produce distinguishable signatures -- skew fails asymmetrically
//     as the strobe walks off one edge of the window, while eye
//     narrowing fails symmetrically as the window closes around a
//     correctly-centered strobe. Telling those apart on real hardware
//     is exactly the diagnostic question this kind of testbench is
//     meant to answer.
//
// Each step is logged by the scoreboard with the exact fault parameters
// in effect, so the resulting transcript is itself the debugging
// narrative artifact.

`timescale 1ps/1ps

module tb_top;

    localparam int  NUM_LANES        = 4;
    localparam int  DQ_BITS_PER_LANE = 8;
    localparam int  ADDR_WIDTH       = 15;
    localparam int  BANK_WIDTH       = 3;
    localparam real TCK_PS           = 2500.0; // 400 MHz CK
    localparam real TDS_PS           = 75.0;
    localparam real TDH_PS           = 75.0;

    // ------------------------------------------------------------------
    // Interconnect
    // ------------------------------------------------------------------
    logic ck, ck_n, cs_n, ras_n, cas_n, we_n;
    logic [BANK_WIDTH-1:0] ba;
    logic [ADDR_WIDTH-1:0] addr;
    wire  [NUM_LANES*DQ_BITS_PER_LANE-1:0] dq;
    wire  [NUM_LANES-1:0] dqs, dqs_n;
    logic [NUM_LANES-1:0] dm;

    logic fault_inject_en;
    real  skew0, skew1, skew2, skew3;
    real  narrow0, narrow1, narrow2, narrow3;

    logic [NUM_LANES-1:0] capture_error;
    logic                 addr_cmd_error;

    // ------------------------------------------------------------------
    // DRAM model
    // ------------------------------------------------------------------
    ddr3_behavioral_model #(
        .NUM_LANES(NUM_LANES),
        .DQ_BITS_PER_LANE(DQ_BITS_PER_LANE),
        .ADDR_WIDTH(ADDR_WIDTH),
        .BANK_WIDTH(BANK_WIDTH),
        .TCK_PS(TCK_PS),
        .TDS_PS(TDS_PS),
        .TDH_PS(TDH_PS)
    ) u_dram (
        .ck(ck), .ck_n(ck_n),
        .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .ba(ba), .addr(addr),
        .dq(dq), .dqs(dqs), .dqs_n(dqs_n), .dm(dm),
        .fault_inject_en(fault_inject_en),
        .fault_dqs_skew_lane0_ps(skew0),
        .fault_dqs_skew_lane1_ps(skew1),
        .fault_dqs_skew_lane2_ps(skew2),
        .fault_dqs_skew_lane3_ps(skew3),
        .fault_eye_narrow_lane0_ps(narrow0),
        .fault_eye_narrow_lane1_ps(narrow1),
        .fault_eye_narrow_lane2_ps(narrow2),
        .fault_eye_narrow_lane3_ps(narrow3),
        .capture_error(capture_error),
        .addr_cmd_error(addr_cmd_error)
    );

    // ------------------------------------------------------------------
    // Stimulus driver (stands in for the Cyclone V HMC output side)
    // ------------------------------------------------------------------
    hmc_stimulus_driver #(
        .NUM_LANES(NUM_LANES),
        .DQ_BITS_PER_LANE(DQ_BITS_PER_LANE),
        .ADDR_WIDTH(ADDR_WIDTH),
        .BANK_WIDTH(BANK_WIDTH),
        .TCK_PS(TCK_PS)
    ) u_driver (
        .ck(ck), .ck_n(ck_n),
        .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .ba(ba), .addr(addr),
        .dq(dq), .dqs(dqs), .dqs_n(dqs_n), .dm(dm)
    );

    // ------------------------------------------------------------------
    // Assertions
    //
    // PORTABILITY NOTE: instantiated directly rather than via SystemVerilog
    // `bind`, which the Icarus Verilog build used to validate this repo
    // does not support (confirmed with an isolated minimal test case --
    // `bind` produced a parser error even in its simplest two-module
    // form). `bind` is the cleaner approach on a fully SV-compliant
    // simulator since it keeps the checker decoupled from the model
    // hierarchy; noted as a follow-up if ported to Questa/VCS/Xcelium.
    // ------------------------------------------------------------------
    hmc_timing_assertions #(
        .NUM_LANES(NUM_LANES)
    ) u_assertions (
        .ck(ck), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .capture_error(capture_error),
        .addr_cmd_error(addr_cmd_error)
    );

    // ------------------------------------------------------------------
    // Scoreboard
    // ------------------------------------------------------------------
    hmc_scoreboard #(
        .NUM_LANES(NUM_LANES),
        .DQ_BITS_PER_LANE(DQ_BITS_PER_LANE),
        .ADDR_WIDTH(ADDR_WIDTH),
        .BANK_WIDTH(BANK_WIDTH)
    ) u_scoreboard ();

    // ------------------------------------------------------------------
    // Test sequence helper
    // ------------------------------------------------------------------
    localparam logic [BANK_WIDTH-1:0] TEST_BANK = 3'd0;

    // Drives one write/read/check cycle at the currently-configured
    // fault settings. Fault values are applied to the module-level
    // signals by the caller before invoking this, so the scoreboard
    // records exactly what was in effect.
    task automatic do_write_read_check(
        input [ADDR_WIDTH-1:0] col,
        input [NUM_LANES*DQ_BITS_PER_LANE-1:0] wdata
    );
        // Driver-side DQS launch delay held at zero throughout these
        // sweeps: the fault is injected at the model's *reception*
        // side, representing a signal-integrity problem on the board
        // and channel rather than a controller-side scheduling bug.
        // That matches this project's suspected root cause. Driver-side
        // launch skew is available via issue_write's arguments if the
        // opposite hypothesis needs testing.
        u_driver.activate(TEST_BANK, 15'h0100);
        u_driver.issue_write(TEST_BANK, col, wdata, 0.0, 0.0, 0.0, 0.0);
        u_scoreboard.record_write(TEST_BANK, col, wdata,
                                   skew0, skew1, skew2, skew3,
                                   narrow0, narrow1, narrow2, narrow3);

        u_driver.issue_read(TEST_BANK, col);
        // Wait out CAS latency + DQS launch + margin before sampling
        #(13750.0 + 200.0 + TCK_PS);
        u_scoreboard.check_read(TEST_BANK, col, dq);
    endtask

    task automatic clear_faults();
        skew0 = 0.0; skew1 = 0.0; skew2 = 0.0; skew3 = 0.0;
        narrow0 = 0.0; narrow1 = 0.0; narrow2 = 0.0; narrow3 = 0.0;
    endtask

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);

        $display("=== Cyclone V HMC fault-injection testbench ===");
        $display("CK period %0.1f ps (%0.1f MHz); tDS/tDH %0.1f/%0.1f ps; nominal window %0.1f ps",
                  TCK_PS, 1.0e6/TCK_PS, TDS_PS, TDH_PS, TDS_PS + TDH_PS);

        fault_inject_en = 1'b0;
        clear_faults();

        #(TCK_PS * 4);

        // ---------------- Phase 1: baseline ----------------
        $display("");
        $display("--- Phase 1: baseline, fault injection DISABLED ---");
        fault_inject_en = 1'b0;
        do_write_read_check(15'h0010, 32'hA5A5_5A5A);
        do_write_read_check(15'h0011, 32'h1234_5678);

        // ---------------- Phase 2: DQS skew sweep, lane 2 ----------------
        $display("");
        $display("--- Phase 2: DQS skew sweep on lane 2 (window = %0.1f ps) ---",
                  TDS_PS + TDH_PS);
        fault_inject_en = 1'b1;
        for (int s = 0; s <= 200; s += 25) begin
            clear_faults();
            skew2 = real'(s);
            $display("  [sweep] lane2 DQS skew = %0d ps", s);
            do_write_read_check(15'h0020 + s[ADDR_WIDTH-1:0], 32'hDEAD_BEEF);
        end

        // ---------------- Phase 3: eye narrowing, lane 1 ----------------
        $display("");
        $display("--- Phase 3: eye-narrowing sweep on lane 1, skew held at 0 ---");
        for (int n = 0; n <= 140; n += 20) begin
            clear_faults();
            narrow1 = real'(n);
            $display("  [sweep] lane1 eye narrowing = %0d ps (effective window %0.1f ps)",
                      n, TDS_PS + TDH_PS - real'(n));
            do_write_read_check(15'h0040 + n[ADDR_WIDTH-1:0], 32'hC0FF_FEED);
        end

        fault_inject_en = 1'b0;
        clear_faults();
        #(TCK_PS * 4);

        $display("");
        u_scoreboard.report_summary();
        $display("=== Testbench complete ===");
        $finish;
    end

    // Safety timeout
    initial begin
        #(TCK_PS * 20000);
        $display("ERROR: testbench timeout -- did not reach $finish");
        $finish;
    end

endmodule
