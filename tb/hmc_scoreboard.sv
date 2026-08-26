// hmc_scoreboard.sv
//
// Data-integrity scoreboard plus structured transaction logging.
//
// Purpose: independently track what was written (address, data,
// per-lane fault settings in effect at the time) so that when a later
// read comes back wrong, the log immediately shows whether the fault
// injection active at write time explains it -- turning a "the data
// is wrong" observation into "lane 2 was written with 180 ps of
// injected DQS skew, consistent with a setup violation on that lane."
// That correlation, not just pass/fail, is what makes this a
// debugging demonstration piece rather than a bare pass/fail test.
//
// PORTABILITY NOTE: implemented with fixed-size arrays indexed
// directly by the packed {bank,col} key, rather than SystemVerilog
// associative arrays or a struct type. The Icarus Verilog build used
// to validate this repo (12.0) does not support associative arrays
// (logic [..] arr [int]) or unpacked structs at all -- both produced
// elaboration errors during development, confirmed with a minimal
// isolated test case before working around them here. Table size is
// 2**(BANK_WIDTH+ADDR_WIDTH) entries, which is small enough for
// simulation at the default widths (3+15 = 18 bits, ~256K entries) but
// will not scale to a full-size real address space -- this scoreboard
// is sized for a directed test/sweep, not a random full-memory test.
// If porting to a simulator with full SV associative-array support,
// switching back to `logic [...] arr [int]` keyed storage removes
// this size ceiling.

`timescale 1ps/1ps

module hmc_scoreboard #(
    parameter int NUM_LANES        = 4,
    parameter int DQ_BITS_PER_LANE = 8,
    parameter int ADDR_WIDTH       = 15,
    parameter int BANK_WIDTH       = 3
) ();

    localparam int KEY_BITS  = BANK_WIDTH + ADDR_WIDTH;
    localparam int TABLE_SIZE = 1 << KEY_BITS;

    logic [NUM_LANES*DQ_BITS_PER_LANE-1:0] exp_data    [TABLE_SIZE];
    real                                    exp_skew0   [TABLE_SIZE];
    real                                    exp_skew1   [TABLE_SIZE];
    real                                    exp_skew2   [TABLE_SIZE];
    real                                    exp_skew3   [TABLE_SIZE];
    real                                    exp_narrow0 [TABLE_SIZE];
    real                                    exp_narrow1 [TABLE_SIZE];
    real                                    exp_narrow2 [TABLE_SIZE];
    real                                    exp_narrow3 [TABLE_SIZE];
    realtime                                exp_wtime   [TABLE_SIZE];
    bit                                      exp_valid   [TABLE_SIZE];

    int total_writes;
    int total_reads;
    int total_mismatches;

    function automatic int key_of(input logic [BANK_WIDTH-1:0] bank,
                                   input logic [ADDR_WIDTH-1:0] col);
        return {bank, col};
    endfunction

    // ------------------------------------------------------------------
    // Call after issuing a write, with the fault settings that were
    // active at that moment, so a later mismatch can be explained.
    // ------------------------------------------------------------------
    task automatic record_write(
        input logic [BANK_WIDTH-1:0] bank,
        input logic [ADDR_WIDTH-1:0] col,
        input logic [NUM_LANES*DQ_BITS_PER_LANE-1:0] data,
        input real skew0, input real skew1, input real skew2, input real skew3,
        input real narrow0, input real narrow1, input real narrow2, input real narrow3
    );
        int k;
        k = key_of(bank, col);

        exp_data[k]    = data;
        exp_skew0[k]   = skew0;   exp_skew1[k]   = skew1;
        exp_skew2[k]   = skew2;   exp_skew3[k]   = skew3;
        exp_narrow0[k] = narrow0; exp_narrow1[k] = narrow1;
        exp_narrow2[k] = narrow2; exp_narrow3[k] = narrow3;
        exp_wtime[k]   = $realtime;
        exp_valid[k]   = 1'b1;

        total_writes++;

        $display("[SCOREBOARD %0t] WRITE bank=%0d col=%0d data=%h skew_ps=[%0.1f,%0.1f,%0.1f,%0.1f] eye_narrow_ps=[%0.1f,%0.1f,%0.1f,%0.1f]",
                  $realtime, bank, col, data,
                  skew0, skew1, skew2, skew3,
                  narrow0, narrow1, narrow2, narrow3);
    endtask

    // ------------------------------------------------------------------
    // Call after a read completes, with the data actually observed on
    // the bus. Reports match/mismatch and, on mismatch, echoes back
    // the fault conditions recorded at write time -- the debug payoff.
    // ------------------------------------------------------------------
    task automatic check_read(
        input logic [BANK_WIDTH-1:0] bank,
        input logic [ADDR_WIDTH-1:0] col,
        input logic [NUM_LANES*DQ_BITS_PER_LANE-1:0] observed_data
    );
        int k;
        total_reads++;
        k = key_of(bank, col);

        if (!exp_valid[k]) begin
            $display("[SCOREBOARD %0t] READ bank=%0d col=%0d : NO PRIOR WRITE RECORDED (uninitialized read)",
                      $realtime, bank, col);
        end else if (observed_data !== exp_data[k]) begin
            total_mismatches++;
            $display("[SCOREBOARD %0t] READ MISMATCH bank=%0d col=%0d expected=%h observed=%h",
                      $realtime, bank, col, exp_data[k], observed_data);
            $display("    fault context at write time (t=%0t): skew_ps=[%0.1f,%0.1f,%0.1f,%0.1f] eye_narrow_ps=[%0.1f,%0.1f,%0.1f,%0.1f]",
                      exp_wtime[k],
                      exp_skew0[k], exp_skew1[k], exp_skew2[k], exp_skew3[k],
                      exp_narrow0[k], exp_narrow1[k], exp_narrow2[k], exp_narrow3[k]);
        end else begin
            $display("[SCOREBOARD %0t] READ OK bank=%0d col=%0d data=%h",
                      $realtime, bank, col, observed_data);
        end
    endtask

    function automatic void report_summary();
        $display("==================================================");
        $display("SCOREBOARD SUMMARY: writes=%0d reads=%0d mismatches=%0d",
                   total_writes, total_reads, total_mismatches);
        $display("==================================================");
    endfunction

endmodule
