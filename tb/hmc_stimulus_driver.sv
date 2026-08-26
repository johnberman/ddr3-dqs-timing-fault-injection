// hmc_stimulus_driver.sv
//
// Stimulus generator standing in for the Cyclone V hard memory
// controller's command/data output. Drives CK, address/command, and
// write DQ/DQS into the ddr3_behavioral_model, and issues reads.
//
// This replaces the role the Virtex-driven stimulus played in the
// original 2017-18 project (per the project background: "modifying
// the stimuli coming from the Virtex" was the original debug method).
// Here the stimulus is generated directly in SystemVerilog so the
// fault classes of interest -- DQS-to-DQ skew, eye narrowing -- can be
// swept parametrically and repeatably, rather than requiring physical
// access to a second FPGA's output logic.
//
// This module is intentionally a plain driver, not a UVM agent --
// scope decision made to keep the repo approachable and focused on
// the timing/fault story rather than verification-framework overhead.
// A UVM-ified version is a reasonable "next step" callout in the
// README, not something built here.

`timescale 1ps/1ps

module hmc_stimulus_driver #(
    parameter int NUM_LANES        = 4,
    parameter int DQ_BITS_PER_LANE = 8,
    parameter int ADDR_WIDTH       = 15,
    parameter int BANK_WIDTH       = 3,
    parameter real TCK_PS          = 2500.0,

    // Data valid window shape, relative to the nominal DQS edge.
    // These define how much margin a clean (zero-skew) write has:
    // the strobe lands DATA_VALID_LEAD_PS after DQ goes valid, and
    // DQ stays valid DATA_VALID_TRAIL_PS beyond the strobe.
    // Set close to the DRAM's tDS/tDH so that injected skew of a
    // realistic magnitude actually walks the strobe out of the
    // window -- if these are set generously large, every sweep step
    // passes and the testbench proves nothing.
    parameter real DATA_VALID_LEAD_PS  = 120.0,
    parameter real DATA_VALID_TRAIL_PS = 120.0
) (
    output logic                  ck,
    output logic                  ck_n,
    output logic                  cs_n,
    output logic                  ras_n,
    output logic                  cas_n,
    output logic                  we_n,
    output logic [BANK_WIDTH-1:0] ba,
    output logic [ADDR_WIDTH-1:0] addr,

    inout  wire  [NUM_LANES*DQ_BITS_PER_LANE-1:0] dq,
    inout  wire  [NUM_LANES-1:0]                  dqs,
    inout  wire  [NUM_LANES-1:0]                  dqs_n,
    output logic [NUM_LANES-1:0]                  dm
);

    // Fixed-size unpacked-array typedef for per-lane real delay values.
    // Icarus Verilog (and some other tools) do not support unpacked-
    // array-typed task/function ports declared inline; a typedef'd
    // array type as the port works around that while keeping the same
    // per-lane semantics.
    typedef real lane_delay_t [NUM_LANES];

    // ------------------------------------------------------------------
    // CK generation -- free-running, 50% duty cycle, period TCK_PS.
    // This is the single PLL-derived master clock discussed: address/
    // command timed off this directly, data derived from it at the
    // driver side too (DQS launched from a phase-related edge).
    // ------------------------------------------------------------------
    initial begin
        ck   = 1'b0;
        ck_n = 1'b1;
    end

    always #(TCK_PS/2.0) begin
        ck   = ~ck;
        ck_n = ~ck_n;
    end

    // ------------------------------------------------------------------
    // Drive registers for data lanes (driver side owns dq/dqs during
    // writes; releases to 'z during reads so the DRAM model can drive)
    // ------------------------------------------------------------------
    logic [NUM_LANES*DQ_BITS_PER_LANE-1:0] dq_drv;
    logic [NUM_LANES-1:0]                  dqs_drv;
    logic                                  driving_write;

    genvar g;
    generate
        for (g = 0; g < NUM_LANES; g++) begin : g_drv
            assign dq[g*DQ_BITS_PER_LANE +: DQ_BITS_PER_LANE] =
                driving_write ? dq_drv[g*DQ_BITS_PER_LANE +: DQ_BITS_PER_LANE]
                              : {DQ_BITS_PER_LANE{1'bz}};
            assign dqs[g]   = driving_write ? dqs_drv[g]  : 1'bz;
            assign dqs_n[g] = driving_write ? ~dqs_drv[g] : 1'bz;
        end
    endgenerate

    initial begin
        cs_n = 1'b1; ras_n = 1'b1; cas_n = 1'b1; we_n = 1'b1;
        ba = '0; addr = '0; dm = '0;
        driving_write = 1'b0;
        dq_drv = '0; dqs_drv = '0;
    end

    // ------------------------------------------------------------------
    // Command tasks. Each issues one command aligned to the next CK
    // rising edge, holding address/command stable across the edge for
    // (at minimum) TIS_PS/TIH_PS -- callers needing to exercise
    // marginal timing should use the *_with_extra_delay variants below,
    // which deliberately shrink that margin.
    // ------------------------------------------------------------------
    task automatic activate(input [BANK_WIDTH-1:0] bank, input [ADDR_WIDTH-1:0] row);
        @(negedge ck); // set up mid-low-phase, ahead of next rising edge
        cs_n = 1'b0; ras_n = 1'b0; cas_n = 1'b1; we_n = 1'b1;
        ba = bank; addr = row;
        @(posedge ck);
        @(negedge ck);
        cs_n = 1'b1;
    endtask

    // NOTE ON PORT SHAPE: per-lane DQS launch delay is passed as four
    // explicit scalar arguments (lane0..lane3) rather than an unpacked
    // array port. Some simulators (Icarus Verilog among them) do not
    // support unpacked-array-typed task/function ports; this shape is
    // more portable across toolchains at the cost of not scaling
    // automatically if NUM_LANES changes. If NUM_LANES is made
    // parametric beyond 4 lanes, revisit this as a packed array of
    // fixed-width fields instead.
    task automatic issue_write(
        input [BANK_WIDTH-1:0] bank,
        input [ADDR_WIDTH-1:0] col,
        input [NUM_LANES*DQ_BITS_PER_LANE-1:0] data,
        // Per-lane DQS launch delay relative to nominal, ps. 0 = clean
        // write; nonzero on a given lane models a driver-side skew
        // fault (distinct from the DRAM-model-side fault injection,
        // which models degraded *reception* rather than *transmission*
        // -- both are real fault locations worth distinguishing).
        input real launch_delay_lane0_ps,
        input real launch_delay_lane1_ps,
        input real launch_delay_lane2_ps,
        input real launch_delay_lane3_ps
    );
        real launch_delay [4];
        @(negedge ck);
        cs_n = 1'b0; ras_n = 1'b1; cas_n = 1'b0; we_n = 1'b0;
        ba = bank; addr = col;
        @(posedge ck);
        @(negedge ck);
        cs_n = 1'b1;

        launch_delay[0] = launch_delay_lane0_ps;
        launch_delay[1] = launch_delay_lane1_ps;
        launch_delay[2] = launch_delay_lane2_ps;
        launch_delay[3] = launch_delay_lane3_ps;

        // Establish the data valid window explicitly.
        //
        // MODELING NOTE: DQ must transition a finite time before the
        // strobe and change again a finite time after it, or the
        // "window" is unbounded and no strobe position can ever be
        // wrong. An earlier version held DQ stable for two full CK
        // periods around the strobe, which made every injected skew
        // value pass -- the sweep reported 100% clean across 200 ps of
        // skew against a 150 ps window. DATA_VALID_LEAD_PS below sets
        // how long before the nominal strobe edge the data goes valid;
        // it is deliberately set close to the DRAM's tDS so that
        // modest injected skew pushes the strobe outside the window,
        // which is the whole point of the sweep.
        driving_write = 1'b1;
        dq_drv = ~data;              // previous bus state (arbitrary,
                                      // just needs to differ from data)
        # (TCK_PS / 2.0);
        dq_drv = data;               // data goes valid here
        # (DATA_VALID_LEAD_PS);      // ... and the strobe follows

        // Launch each lane's DQS with its configured delay -- 0 for a
        // clean write, nonzero to model a driver-side skew fault.
        //
        // PORTABILITY NOTE: written as explicitly unrolled parallel
        // branches inside a single fork/join rather than a loop
        // spawning join_none processes. A loop-spawned join_none
        // inside an automatic task crashed the Icarus Verilog runtime
        // outright (assertion failure in of_JOIN_DETACH) during
        // development -- a simulator bug rather than a language issue,
        // but the unrolled form is equivalent here and avoids it.
        // Fixed at 4 lanes as a consequence.
        fork
            begin
                # (launch_delay[0]);
                dqs_drv[0] = 1'b1;
                # (TCK_PS/4.0);
                dqs_drv[0] = 1'b0;
            end
            begin
                # (launch_delay[1]);
                dqs_drv[1] = 1'b1;
                # (TCK_PS/4.0);
                dqs_drv[1] = 1'b0;
            end
            begin
                # (launch_delay[2]);
                dqs_drv[2] = 1'b1;
                # (TCK_PS/4.0);
                dqs_drv[2] = 1'b0;
            end
            begin
                # (launch_delay[3]);
                dqs_drv[3] = 1'b1;
                # (TCK_PS/4.0);
                dqs_drv[3] = 1'b0;
            end
            // Window-closing branch, running in parallel with the
            // strobe launches above.
            //
            // TIMING NOTE: this must be scheduled relative to the
            // NOMINAL strobe time, not sequenced after the strobe
            // pulses complete. Each strobe branch holds its pulse for
            // TCK_PS/4 (625 ps at 400 MHz), so closing the window
            // after the fork joined put the trailing edge ~625 ps
            // late -- far outside any realistic data valid window,
            // which meant a strobe could be skewed arbitrarily late
            // and still land inside. That is why the sweep passed at
            // 200 ps of skew against a 150 ps window.
            begin
                # (DATA_VALID_TRAIL_PS);
                dq_drv = ~data;   // data valid window closes here
            end
        join

        # (TCK_PS);
        driving_write = 1'b0;
    endtask

    task automatic issue_read(input [BANK_WIDTH-1:0] bank, input [ADDR_WIDTH-1:0] col);
        @(negedge ck);
        cs_n = 1'b0; ras_n = 1'b1; cas_n = 1'b0; we_n = 1'b1;
        ba = bank; addr = col;
        @(posedge ck);
        @(negedge ck);
        cs_n = 1'b1;
    endtask

    // ------------------------------------------------------------------
    // Marginal-timing variant: deliberately shrinks address/command
    // setup margin ahead of the sampling edge, to sweep toward and
    // past the tIS boundary -- the address/command analogue of the
    // 2005 MPC8560 COARSE/TAP problem, reproduced here as a
    // parametric, repeatable test rather than a bench probe.
    // ------------------------------------------------------------------
    task automatic activate_with_late_setup(
        input [BANK_WIDTH-1:0] bank,
        input [ADDR_WIDTH-1:0] row,
        input real setup_margin_ps  // time before the sampling edge that
                                     // addr/cmd becomes stable; compare
                                     // against ddr3_behavioral_model's
                                     // TIS_PS to know if this is a
                                     // deliberate violation
    );
        @(posedge ck);
        # (TCK_PS - setup_margin_ps);
        cs_n = 1'b0; ras_n = 1'b0; cas_n = 1'b1; we_n = 1'b1;
        ba = bank; addr = row;
        @(posedge ck);
        @(negedge ck);
        cs_n = 1'b1;
    endtask

endmodule
