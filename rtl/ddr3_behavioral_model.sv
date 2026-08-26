// ddr3_behavioral_model.sv
//
// Behavioral DDR3 SDRAM model, timing-accurate on the two relationships
// this project centers on: CK-referenced address/command sampling, and
// DQS-referenced (source-synchronous) per-lane data capture/launch.
//
// Scope, deliberately: this models the read/write data timing path and
// address/command setup-hold checking accurately enough to demonstrate
// and characterize a DQS-to-DQ skew / eye-narrowing fault. It does NOT
// implement mode registers, refresh, ODT, ZQ calibration, or bank
// interleaving/pipelining -- those are functional-completeness items
// that would be added after the timing/fault-injection base here is
// validated, so timing bugs and functional bugs are never being
// debugged at the same time.
//
// Lane organization: NUM_LANES lanes x DQ_BITS_PER_LANE bits, each with
// its own DQS/DQS_N pair. Default 4 x 8 = 32-bit data bus, matching a
// typical Cyclone V HMC DDR3 configuration.

`timescale 1ps/1ps

module ddr3_behavioral_model #(
    parameter int  NUM_LANES          = 4,
    parameter int  DQ_BITS_PER_LANE   = 8,
    parameter int  ADDR_WIDTH         = 15,
    parameter int  BANK_WIDTH         = 3,
    parameter int  MEM_DEPTH_PER_BANK = 1024,   // small on purpose, sim-only

    // Timing parameters (ps), representative of a DDR3-1600-class part
    // at CK = 400 MHz (2500 ps period), matching the Cyclone V HMC
    // discussion this project is built around. Substitute real
    // datasheet numbers for a specific part before treating results as
    // more than illustrative of the methodology.
    parameter real TCK_PS    = 2500.0,
    parameter real TIS_PS    = 170.0,   // addr/cmd setup vs CK
    parameter real TIH_PS    = 170.0,   // addr/cmd hold vs CK
    parameter real TDS_PS    = 75.0,    // DQ setup vs DQS (write)
    parameter real TDH_PS    = 75.0,    // DQ hold vs DQS (write)
    parameter real TDQSCK_PS = 200.0,   // DQS launch delay after CAS window, read
    parameter real TCAS_PS   = 13750.0  // CAS latency, ~11 cycles @ 400 MHz
) (
    // Command/address interface -- CK-referenced
    input  logic                    ck,
    input  logic                    ck_n,
    input  logic                    cs_n,
    input  logic                    ras_n,
    input  logic                    cas_n,
    input  logic                    we_n,
    input  logic [BANK_WIDTH-1:0]   ba,
    input  logic [ADDR_WIDTH-1:0]   addr,

    // Data interface -- DQS-referenced, per lane, bidirectional
    inout  wire  [NUM_LANES*DQ_BITS_PER_LANE-1:0] dq,
    inout  wire  [NUM_LANES-1:0]                  dqs,
    inout  wire  [NUM_LANES-1:0]                  dqs_n,
    input  logic [NUM_LANES-1:0]                  dm,

    // --- Fault injection / observability (not real DDR3 pins) ---
    // Used by the testbench to reproduce and characterize the
    // DQS-to-DQ skew / SI-degraded-eye fault class this project
    // targets.
    // PORTABILITY NOTE: per-lane fault values are passed as explicit
    // scalar ports (lane0..lane3) rather than unpacked-array ports.
    // The Icarus Verilog build used to validate this repo does not
    // support unpacked-array module/subroutine ports or whole-array
    // assignment; this shape is the portable equivalent. Fixed at 4
    // lanes as a result -- widening NUM_LANES requires adding ports.
    input  logic  fault_inject_en,

    // Extra per-lane DQS arrival delay, ps (pure skew fault)
    input  real   fault_dqs_skew_lane0_ps,
    input  real   fault_dqs_skew_lane1_ps,
    input  real   fault_dqs_skew_lane2_ps,
    input  real   fault_dqs_skew_lane3_ps,

    // Per-lane reduction of the effective tDS+tDH window, ps
    // (SI-degraded eye, distinct from pure skew)
    input  real   fault_eye_narrow_lane0_ps,
    input  real   fault_eye_narrow_lane1_ps,
    input  real   fault_eye_narrow_lane2_ps,
    input  real   fault_eye_narrow_lane3_ps,

    output logic [NUM_LANES-1:0] capture_error,  // sticky per-lane write
                                                   // capture violation
    output logic                 addr_cmd_error   // sticky addr/cmd
                                                    // setup/hold violation
);

    // Internal per-lane vectors, fanned out from the scalar ports so
    // the generate block below can still index by lane number.
    real fault_dqs_skew_ps   [NUM_LANES];
    real fault_eye_narrow_ps [NUM_LANES];

    always @(*) begin
        fault_dqs_skew_ps[0]   = fault_dqs_skew_lane0_ps;
        fault_dqs_skew_ps[1]   = fault_dqs_skew_lane1_ps;
        fault_dqs_skew_ps[2]   = fault_dqs_skew_lane2_ps;
        fault_dqs_skew_ps[3]   = fault_dqs_skew_lane3_ps;
        fault_eye_narrow_ps[0] = fault_eye_narrow_lane0_ps;
        fault_eye_narrow_ps[1] = fault_eye_narrow_lane1_ps;
        fault_eye_narrow_ps[2] = fault_eye_narrow_lane2_ps;
        fault_eye_narrow_ps[3] = fault_eye_narrow_lane3_ps;
    end

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------
    localparam int BANKS = 1 << BANK_WIDTH;
    logic [NUM_LANES*DQ_BITS_PER_LANE-1:0] mem [BANKS][MEM_DEPTH_PER_BANK];

    // ------------------------------------------------------------------
    // Command decode (simplified truth table)
    // ------------------------------------------------------------------
    typedef enum logic [2:0] {
        CMD_NOP, CMD_ACT, CMD_READ, CMD_WRITE, CMD_PRECHARGE
    } cmd_e;

    cmd_e cmd_decoded;

    always_comb begin
        if (cs_n) cmd_decoded = CMD_NOP;
        else begin
            unique case ({ras_n, cas_n, we_n})
                3'b011:  cmd_decoded = CMD_ACT;
                3'b101:  cmd_decoded = CMD_READ;
                3'b100:  cmd_decoded = CMD_WRITE;
                3'b010:  cmd_decoded = CMD_PRECHARGE;
                default: cmd_decoded = CMD_NOP;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Address/command setup & hold checking, referenced to CK rising
    // edge. Implemented by tracking the timestamp of the last change
    // on the addr/cmd bus and the timestamp of the last CK edge, then
    // comparing gaps -- runs in any event-driven simulator without
    // needing SDF back-annotation. This is checking exactly the
    // relationship a wrong COARSE/TAP-style delay setting would break,
    // as in the 2005 MPC8560 erratum this project's methodology grew
    // out of.
    // ------------------------------------------------------------------
    real last_bus_change_ps;
    real last_ck_edge_ps;

    initial begin
        last_bus_change_ps = 0.0;
        last_ck_edge_ps     = 0.0;
        addr_cmd_error      = 1'b0;
    end

    always @(cs_n, ras_n, cas_n, we_n, ba, addr) begin
        last_bus_change_ps = $realtime;
        // Hold check: did the bus change too soon after the last edge?
        if (($realtime - last_ck_edge_ps) < TIH_PS &&
            ($realtime - last_ck_edge_ps) >= 0.0) begin
            addr_cmd_error <= 1'b1;
        end
    end

    always @(posedge ck) begin
        // Setup check: did the bus settle at least TIS_PS before this edge?
        if (($realtime - last_bus_change_ps) < TIS_PS) begin
            addr_cmd_error <= 1'b1;
        end
        last_ck_edge_ps <= $realtime;
    end

    // ------------------------------------------------------------------
    // ACT / READ / WRITE sequencing. Single outstanding transaction at
    // a time -- no bank interleaving pipeline modeled yet. Sufficient
    // for characterizing the data-path timing fault this project
    // targets, which lives on DQS/DQ, not command scheduling.
    // ------------------------------------------------------------------
    logic [BANK_WIDTH-1:0] active_bank;
    logic                  bank_open;
    logic                  pending_read, pending_write;
    logic [ADDR_WIDTH-1:0] pending_col;
    logic [BANK_WIDTH-1:0] pending_bank;

    // NOTE ON COMMAND STATE LIFETIME:
    // pending_write must stay asserted from the WRITE command until
    // the write data actually arrives on DQ/DQS, which is several CK
    // cycles later. An earlier revision cleared it on the next edge
    // (treating it as a one-cycle pulse), so by the time the strobe
    // arrived the model no longer knew a write was in progress and
    // silently discarded every write -- reads then returned X and the
    // whole testbench "failed" for reasons that had nothing to do with
    // the timing faults under study. Same trap as the read path: a
    // one-cycle command flag consulted cycles later is always stale.
    //
    // pending_read is likewise held until the read data has been
    // launched. Both are cleared explicitly by their respective data
    // phases rather than by the next clock edge.
    always @(posedge ck) begin
        case (cmd_decoded)
            CMD_ACT: begin
                active_bank <= ba;
                bank_open   <= 1'b1;
            end
            CMD_READ: begin
                pending_read <= 1'b1;
                pending_col  <= addr;
                pending_bank <= ba;
            end
            CMD_WRITE: begin
                pending_write <= 1'b1;
                pending_col   <= addr;
                pending_bank  <= ba;
            end
            CMD_PRECHARGE: bank_open <= 1'b0;
            default: ; // NOP: leave pending_* alone; data phase clears
        endcase
    end

    // ------------------------------------------------------------------
    // Per-lane DQS-referenced data capture (write) and launch (read)
    //
    // WRITE path: DQS is the sampling reference for DQ -- source-
    // synchronous capture, "DQS is the flashbulb." Fault injection
    // adds a per-lane extra DQS arrival delay (skew fault) and can
    // separately shrink the effective tDS/tDH margin (eye-narrowing
    // fault, modeling SI degradation rather than pure skew).
    //
    // READ path: this model always launches a clean, centered DQS/DQ
    // relationship. Fault injection on reads is intended to be
    // exercised on the controller's own input DQS delay chain, in the
    // controller-side testbench -- matching how the real Cyclone V HMC
    // issue class centers on read-capture calibration living in the
    // FPGA, not in the DRAM.
    // ------------------------------------------------------------------
    genvar lane;
    generate
        for (lane = 0; lane < NUM_LANES; lane++) begin : g_lane

            localparam int LO = lane * DQ_BITS_PER_LANE;
            localparam int HI = LO + DQ_BITS_PER_LANE - 1;

            // --- WRITE CAPTURE ---
            logic dqs_eff;
            real  eff_tds, eff_tdh, applied_skew_ps, eye_narrow_eff;

            // EYE NARROWING SEMANTICS
            //
            // Signal-integrity degradation (ISI, crosstalk,
            // reflections, attenuation) shrinks the width of the
            // *data valid window* the receiver actually sees -- the
            // data arrives late and/or departs early because the
            // transitions are slower and the levels take longer to
            // settle. It does NOT relax the DRAM's required setup and
            // hold times, which are fixed properties of the part.
            //
            // An earlier revision modeled narrowing by subtracting
            // from TDS_PS/TDH_PS, i.e. reducing the requirement. That
            // makes the check strictly more permissive, so the entire
            // eye-narrowing sweep passed -- including at an effective
            // window of 10 ps, which should have been catastrophic.
            // The requirement stays fixed; what narrows is the window,
            // modeled here as an effective delay in when the data is
            // considered valid at the receiver.
            always_comb begin
                applied_skew_ps = fault_inject_en ? fault_dqs_skew_ps[lane] : 0.0;
                eff_tds = TDS_PS;   // fixed part requirement
                eff_tdh = TDH_PS;   // fixed part requirement
                eye_narrow_eff = fault_inject_en ? fault_eye_narrow_ps[lane] : 0.0;
            end

            // Initialized to 0 rather than left at X: an X -> 1
            // transition does not reliably fire @(posedge ...), so an
            // uninitialized strobe silently suppresses every capture
            // check in the model.
            initial dqs_eff = 1'b0;

            always @(dqs[lane]) begin
                if (applied_skew_ps > 0.0) # (applied_skew_ps);
                dqs_eff = (dqs[lane] === 1'b1) ? 1'b1 : 1'b0;
            end

            // Track when DQ last changed on this lane, so the capture
            // check can compare strobe arrival against the real data
            // valid window rather than against the data value itself.
            //
            // MODELING NOTE: an earlier version of this check sampled
            // DQ before/at/after the strobe and flagged a violation if
            // the samples differed. That check is inert in this
            // testbench: the driver holds DQ stable for two full CK
            // periods around each strobe, so DQ never changes inside
            // the sampling window and no amount of injected skew ever
            // triggered it. The whole sweep reported zero failures,
            // which looked like a passing testbench but was actually a
            // testbench incapable of failing. The correct question is
            // not "did the data change near the strobe" but "did the
            // strobe land inside the data valid window" -- which
            // requires knowing where that window is, hence this
            // explicit tracking.
            realtime dq_last_change;
            initial dq_last_change = 0;

            always @(dq[HI:LO]) dq_last_change = $realtime;

            // Per-lane capture state. Declared at module scope rather
            // than as automatic variables inside the process: the
            // Icarus build used here does not support overriding
            // default variable lifetime (`automatic` inside a
            // non-automatic block), which silently broke the hold
            // check in an earlier revision.
            logic [DQ_BITS_PER_LANE-1:0] captured_word;
            logic [DQ_BITS_PER_LANE-1:0] val_at_edge;
            realtime edge_time;
            real setup_margin;

            // A strobe that arrives too LATE is just as broken as one
            // that arrives too early, but the two fail differently and
            // an earlier revision only caught the early case. Injected
            // skew delays the strobe, which *increases* the measured
            // setup margin -- so a setup-only check reported clean
            // results across the entire sweep, right up to 200 ps of
            // skew against a 150 ps window. The strobe must land
            // inside the window on BOTH sides: at least eff_tds after
            // the data went valid, and at least eff_tdh before it
            // changes again. The hold-side check below is what
            // actually catches injected skew.
            always @(posedge dqs_eff) begin
                edge_time    = $realtime;
                val_at_edge  = dq[HI:LO];
                // Eye narrowing pushes the effective data-valid onset
                // later (slower edges, longer settling), so the same
                // strobe position sees less setup margin.
                setup_margin = ($realtime - dq_last_change) - eye_narrow_eff;

                if (setup_margin < eff_tds) begin
                    // Strobe arrived before the data had been stable
                    // long enough -- setup violation.
                    capture_error[lane] <= 1'b1;
                    $display("[DRAM %0t] lane %0d SETUP VIOLATION: DQ stable only %0.1f ps before strobe (need %0.1f ps)",
                              edge_time, lane, setup_margin, eff_tds);
                end else begin
                    // Wait out the hold window and confirm DQ did not
                    // change during it. A strobe skewed late enough
                    // that the data valid window closes underneath it
                    // fails here.
                    # (eff_tdh > 0.0 ? eff_tdh : 0.001);
                    if (dq[HI:LO] !== val_at_edge) begin
                        capture_error[lane] <= 1'b1;
                        $display("[DRAM %0t] lane %0d HOLD VIOLATION: DQ changed within %0.1f ps of strobe (skew walked strobe past end of data valid window)",
                                  edge_time, lane, eff_tdh);
                    end else begin
                        captured_word = val_at_edge;
                        if (pending_write && !dm[lane]) begin
                            mem[pending_bank][pending_col][HI:LO] <= captured_word;
                        end
                    end
                    // Write data phase for this beat is done. Only one
                    // lane clears the shared flag (see pending_read
                    // note above) and only after all lanes have had a
                    // chance to capture this beat.
                    if (lane == 0) begin
                        # (TCK_PS / 2.0);
                        pending_write = 1'b0;
                    end
                end
            end

            // --- READ LAUNCH ---
            logic dqs_drv, dqs_oe, dq_oe;
            logic [DQ_BITS_PER_LANE-1:0] dq_drv;

            assign dqs[lane]   = dqs_oe ? dqs_drv  : 1'bz;
            assign dqs_n[lane] = dqs_oe ? ~dqs_drv : 1'bz;
            assign dq[HI:LO]   = dq_oe  ? dq_drv   : {DQ_BITS_PER_LANE{1'bz}};

            initial begin
                dqs_oe  = 1'b0;
                dq_oe   = 1'b0;
                dqs_drv = 1'b0;
                dq_drv  = '0;
            end

            // Simplified single-beat read launch.
            //
            // The output-enable window and the data launch must be
            // driven from the SAME timed sequence: pending_read is
            // asserted for only one CK cycle, but the data does not
            // appear until TCAS_PS later (~5.5 cycles at 400 MHz).
            // Driving dq_oe from a separate always block clocked on
            // pending_read leaves the bus tri-stated by the time the
            // data actually arrives, which produces an all-'z' read
            // that looks like a data-integrity failure but is really a
            // model bug. Keeping enable and data in one sequence
            // avoids that.
            //
            // Full BL8 burst sequencing across 4 CK cycles is a
            // follow-on extension once this base timing model is
            // validated end to end.
            always @(posedge ck) begin
                if (pending_read) begin
                    # (TCAS_PS);
                    dq_drv  = mem[pending_bank][pending_col][HI:LO];
                    dq_oe   = 1'b1;
                    # (TDQSCK_PS);
                    dqs_oe  = 1'b1;
                    dqs_drv = 1'b1;
                    # (TCK_PS / 4.0);
                    dqs_drv = 1'b0;
                    // Hold the data valid for a further margin so the
                    // testbench can sample it, then release the bus.
                    # (TCK_PS * 2.0);
                    dq_oe        = 1'b0;
                    dqs_oe       = 1'b0;
                    // pending_read is shared across lanes, so only one
                    // lane clears it -- otherwise all four race to
                    // write the same flag in the same timestep.
                    if (lane == 0) pending_read = 1'b0;
                end
            end

        end : g_lane
    endgenerate

    // ------------------------------------------------------------------
    // SCOPE NOTES -- deliberately not yet implemented:
    //   - full BL8 burst ordering / seamless back-to-back bursts
    //   - bank interleaving / multiple outstanding transactions
    //   - refresh, ZQ calibration, mode register set behavior
    //   - ODT / termination modeling
    // Next layer once skew/eye-narrowing fault injection and the
    // controller-side SVA assertions are validated against this base.
    // ------------------------------------------------------------------

endmodule
