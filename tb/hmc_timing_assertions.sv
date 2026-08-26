// hmc_timing_assertions.sv
//
// SVA checking the timing relationships this project is built around:
//   1. Address/command setup/hold, as flagged by the DRAM model
//      (addr_cmd_error)
//   2. Per-lane DQS/DQ write-data capture violations, as flagged by
//      the DRAM model (capture_error)
//
// These assertions are written against signals of the
// ddr3_behavioral_model instance; bind this module to that instance
// from the top-level testbench rather than instantiating it directly,
// so the checker stays decoupled from the DUT/model hierarchy.
//
// PORTABILITY NOTE: written using only simple boolean concurrent
// assertions (`assert property (@(posedge clk) expr)`), with no
// property/endproperty blocks, no |-> implication operator, and no
// covergroup. Confirmed by isolated minimal test cases during
// development that the Icarus Verilog build used to validate this
// repo (12.0) does not support standalone property blocks, the |->
// operator inside assert property, or covergroups -- all produced
// parser errors even in a two-line reduced test case. The checks
// below are logically equivalent to what a full-SVA-capable tool
// (Questa, VCS, Xcelium) would express with |-> sequences; this is a
// least-common-denominator version so the repo runs on a free,
// installable, open-source toolchain without requiring a commercial
// simulator license just to demonstrate the methodology. A version
// using full SVA sequence/implication syntax is a natural "if I had a
// commercial simulator" follow-up to note in the README.

module hmc_timing_assertions #(
    parameter int NUM_LANES = 4
) (
    input logic ck,
    input logic cs_n,
    input logic ras_n,
    input logic cas_n,
    input logic we_n,
    input logic [NUM_LANES-1:0] capture_error,
    input logic                 addr_cmd_error
);

    // ------------------------------------------------------------------
    // Direct violation reporting: surface the model's own error flags
    // as assertion failures at every CK edge, so a regression run's
    // pass/fail count reflects timing violations directly rather than
    // relying on someone reading a printed log line.
    // ------------------------------------------------------------------
    a_no_addr_cmd_violation: assert property (
        @(posedge ck) !addr_cmd_error
    ) else $error("hmc_timing_assertions: address/command setup or hold violation detected");

    genvar lane;
    generate
        for (lane = 0; lane < NUM_LANES; lane++) begin : g_lane_check
            a_no_capture_violation: assert property (
                @(posedge ck) !capture_error[lane]
            ) else $error("hmc_timing_assertions: lane %0d write-data capture violation (DQS/DQ timing)", lane);
        end
    endgenerate

    // ------------------------------------------------------------------
    // Activity tracking: plain counters instead of a covergroup, so
    // that a regression report can note what fraction of CK cycles
    // actually carried a command -- catches the common first-pass-
    // testbench blind spot of a stimulus generator that mostly idles
    // without anyone noticing.
    // ------------------------------------------------------------------
    int cmd_active_cycles;
    int cmd_idle_cycles;

    initial begin
        cmd_active_cycles = 0;
        cmd_idle_cycles   = 0;
    end

    always @(posedge ck) begin
        if (!cs_n) cmd_active_cycles <= cmd_active_cycles + 1;
        else       cmd_idle_cycles   <= cmd_idle_cycles + 1;
    end

    final begin
        $display("[hmc_timing_assertions] command activity: %0d active cycles, %0d idle cycles",
                   cmd_active_cycles, cmd_idle_cycles);
    end

endmodule
