# DDR3 DQS/DQ Timing Fault Injection Testbench

A SystemVerilog testbench that reproduces, characterizes, and
distinguishes two classes of DDR3 data-capture timing fault:
per-lane strobe skew, and signal-integrity-driven eye narrowing.

Written to demonstrate a verification-driven approach to the kind of
memory-interface bring-up problem where the symptom is intermittent
data corruption and the root cause is a timing margin that calibration
measured optimistically.

## What this is

The core question in DDR data capture is whether the strobe (DQS)
lands inside the data valid window on DQ. That window is bounded on
both sides: the strobe must arrive at least tDS after the data goes
valid, and at least tDH before it changes again. A fault that walks
the strobe toward either boundary produces corruption that is:

- **per-lane** (each byte lane has its own strobe and its own routing)
- **intermittent** (margin erodes with temperature and voltage)
- **pattern-dependent** (ISI depends on the preceding bits)

which is exactly the symptom profile that makes these faults hard to
localize on hardware. This testbench makes the mechanism explicit and
sweepable.

## Structure

```
rtl/ddr3_behavioral_model.sv    DDR3 endpoint: CK-referenced command
                                 capture, per-lane DQS-referenced data
                                 capture, fault injection hooks
tb/hmc_stimulus_driver.sv        Controller-side stimulus: command
                                 issue, write data launch with a
                                 bounded data valid window
tb/hmc_timing_assertions.sv      SVA surfacing timing violations as
                                 assertion failures
tb/hmc_scoreboard.sv             Data integrity checking plus logging
                                 that correlates each mismatch with
                                 the fault parameters in effect
tb/tb_top.sv                     Test plan: baseline, skew sweep,
                                 eye-narrowing sweep
docs/sample_run.log              Checked-in output of `make log`
```

## Running it

```
make run      # build and run
make log      # regenerate docs/sample_run.log
make waves    # run, then open build/tb_top.vcd in gtkwave
```

Requires Icarus Verilog 12.0 or later. No commercial simulator needed.

## Test plan and results

**Phase 1 — baseline.** Fault injection disabled. Both writes read back
clean. This phase exists because a fault-injection testbench that has
never been shown to pass is not evidence of anything.

**Phase 2 — DQS skew sweep, lane 2.** Injected strobe delay swept
0–200 ps against a 150 ps window (tDS + tDH = 75 + 75).

| Skew | Result | Mechanism |
|------|--------|-----------|
| 0–25 ps | pass | strobe still inside window |
| 50–100 ps | fail | hold violation — strobe walks past window close |
| 125–175 ps | fail | setup violation — strobe enters next data phase |

Corruption appears **only in lane 2's byte** (`deadbeef` → `dexxbeef`),
which is the diagnostic signature that separates a per-lane strobe
problem from a bus-wide one.

**Phase 3 — eye narrowing, lane 1.** Strobe held at nominal; the
effective data valid window shrunk directly, modeling SI degradation
rather than skew. Passes to 40 ps of narrowing, fails from 60 ps on
with setup violations, corrupting only lane 1 (`c0fffeed` →
`c0ffxxed`).

The distinction matters diagnostically: skew fails **asymmetrically**
(one window edge first, and the violation type changes as the strobe
keeps moving), while eye narrowing fails **symmetrically** around a
correctly centered strobe. On hardware, that difference is what tells
you whether to go after routing/calibration or after the channel
itself.

Final tally: 19 writes, 19 reads, 12 mismatches — all 12 attributable
to injected faults, with the responsible lane and parameter recorded
in the log.

## Relationship to the original hardware problem

This models a fault class encountered on a Cyclone V–based board where
the hard memory controller showed an apparent timing fault with signal
integrity as the suspected root cause. On that system the debug method
was to modify the stimulus driven into the Cyclone from an upstream
Virtex and observe whether the fault worsened or cleared — effectively
a manual margin sweep. This testbench is that method turned into a
repeatable, parametric, self-checking simulation.

## Documented Cyclone V HMC issues

Intel/Altera published several relevant advisories for this device
family. Two are marked Critical Issue and bear directly on the fault
classes modeled here.

**Runtime read/write errors at voltage and temperature extremes**
(Intel KDB article 000083611, last reviewed January 2014). The hard
memory controller on Cyclone V GX, GT, and SoC devices can produce
read and write errors during normal operation when core Vcc is low and
temperature is at either extreme. For Cyclone V parts the affected
DDR3 range is 300–400 MHz — which brackets the 400 MHz CK modeled in
this testbench. The resolution was a Quartus II patch plus EMIF IP
regeneration and recompile.

This is the closest documented analogue to the failure profile this
repo reproduces: an interface that calibrates successfully and then
fails in service as voltage and temperature erode the margin that
calibration measured under nominal conditions. The mechanism is not
stated in the advisory, so this repo models the *symptom class*
(margin loss at the capture point), not the specific silicon defect.

**Calibration failure from device and board skew combinations**
(Intel KDB article 000084806, last reviewed June 2012). Certain
combinations of device and board skew cause read calibration to fail,
with the EMIF Debug Toolkit reporting "No working DQSen phase found"
— the DQS enable calibration stage failing to find a usable phase.
Flagged as more likely at DDR3 frequencies of 667 MHz and above, so a
400 MHz interface sits below the stated risk band. Relevant here
because it confirms board-level skew as a documented cause of
DQS-domain calibration failure on this family.

**DQS postamble glitching.** The Cyclone V device handbook (CV-52006)
documents dedicated postamble registers whose purpose is to ground the
shifted DQS signal at the end of a read, so that glitches occurring
while DQS is in its postamble state cannot corrupt the DQ input
registers. That this hardware exists is itself evidence that strobe
glitching in the preamble/postamble window is a real failure mode on
bidirectional-strobe interfaces. **Not modeled in this repo** — a
worthwhile extension, since it produces corruption that looks like a
timing fault but has a different root cause and a different fix.

**Address/command skew relative to CK.** Intel support guidance
identifies address and command skew with respect to the memory clock
at the DRAM pins as a common cause of a distinct calibration failure
class. This is the direct descendant of the DDR1-era problem that
motivated this project's approach, and the model checks it
(`addr_cmd_error`), though the sweeps here exercise the data path.

### Caveats on the above

The two Critical Issue advisories predate the 2017–18 project by
several years and both had software fixes available, so a design
compiled in that era would likely have carried the corrections
already. They are cited here as evidence that these fault classes are
real and documented on this silicon — **not** as a claim that either
one caused the specific fault this project encountered. Root cause on
that board was never established.

This repo does **not** reproduce any specific published erratum. The
mechanisms modeled are generic DDR3 capture-timing physics, selected
because they match the observed symptom profile. Anyone using this as
a starting point for real silicon debug should pull the current errata
and EMIF handbook for their exact device, speed grade, and Quartus
version rather than relying on this summary.

## Scope and honest limitations

This is a focused timing demonstration, not a qualification model.

**Not implemented:**
- Full BL8 burst ordering and seamless back-to-back bursts (single-beat
  transactions only)
- Bank interleaving, multiple outstanding transactions
- Refresh, ZQ calibration, mode register set
- ODT and termination
- Read-path fault injection (reads launch clean; the controller-side
  input delay chain is where read-capture faults would be modeled)

**Timing parameters** are representative DDR3-1600-class values at
400 MHz CK, not datasheet values for a specific part number. Substitute
real numbers before drawing conclusions about a real device.

**The SI model is behavioral.** Eye narrowing is a parameter, not a
channel simulation. Real ISI is pattern-dependent and frequency-
dependent; this models its *effect* on margin, which is sufficient to
demonstrate the diagnostic method but is not a substitute for IBIS/
SPICE channel analysis.

**Fixed at 4 byte lanes.** Several interfaces use explicit per-lane
scalar ports rather than arrays (see below), so widening the bus
requires adding ports rather than changing a parameter.

## Simulator portability notes

Validated against Icarus Verilog 12.0, which is free and installable,
at the cost of avoiding several SystemVerilog constructs it does not
support. Each of the following was confirmed unsupported with an
isolated minimal test case during development:

| Construct | Workaround used |
|-----------|-----------------|
| Associative arrays (`logic [..] a [int]`) | Fixed-size arrays indexed by packed key |
| Unpacked structs | Parallel arrays, one per field |
| Unpacked-array module/task ports | Explicit per-lane scalar ports |
| Whole-array assignment / `'{...}` literals | Per-element assignment |
| `property`/`endproperty` blocks | Inline boolean `assert property` |
| `\|->` implication operator | Boolean assertions on model-side flags |
| `covergroup` | Plain counters |
| `bind` | Direct instantiation |
| `return` from a task | Restructured if/else |
| `automatic` vars inside a process | Module-scope variables |
| Loop-spawned `join_none` in an automatic task | Explicitly unrolled `fork`/`join` (this one crashed the simulator outright — assertion failure in `of_JOIN_DETACH`) |

On a fully SV-compliant simulator (Questa, VCS, Xcelium) the natural
improvements are: express the timing checks as real SVA sequences with
implication rather than sampling model-side flags, use `bind` to keep
the checker out of the DUT hierarchy, and replace the counters with
proper functional coverage. None of those change the results; they make
the code cleaner and the coverage reporting real.

## Development notes

Several bugs in this testbench were only caught because the sweep
results were checked against expectation rather than just checked for
"did it run." Recorded here because the debugging is the point of the
exercise:

1. **Read path returned all `z`.** Output enable was driven from a
   one-cycle command flag while the data launched ~5.5 cycles later, so
   the bus was tri-stated by the time data arrived. One-cycle command
   flags consulted cycles later are always stale.

2. **Writes silently discarded.** Same root cause on the write side:
   `pending_write` cleared before the strobe arrived, so the capture
   logic did not know a write was in progress. Reads returned X.

3. **The sweep passed at every skew value.** The capture check compared
   DQ against itself before/at/after the strobe — but the driver held
   DQ stable for two full CK periods, so DQ never changed inside the
   sampling window and the check could not fail. A testbench reporting
   100% clean across 200 ps of skew against a 150 ps window looked like
   a pass and was actually a check incapable of failing.

4. **Skew only checked one window edge.** Delaying the strobe
   *increases* measured setup margin; the failure shows up on the hold
   side. A setup-only check missed every late-strobe fault.

5. **Eye narrowing had the sign backwards.** It was modeled as reducing
   the DRAM's *required* tDS/tDH, which makes the check more permissive
   — the entire narrowing sweep passed, including at a 10 ps effective
   window. SI degradation shrinks the *actual* window; the part's
   requirement is fixed.

Items 3 and 5 are the instructive ones: both produced a testbench that
ran clean and proved nothing. A fault-injection environment that cannot
be shown to fail when the fault is present is worse than no testbench,
because it manufactures false confidence.

## References

- Intel KDB 000083611 — Possible Read/Write Errors for DDR2 and DDR3
  Hard Memory Controllers on Arria V and Cyclone V Devices at Low Vcc
  and Extreme Temperatures.
  https://www.intel.com/content/www/us/en/support/programmable/articles/000083611.html
- Intel KDB 000084806 — Possible Calibration Error for DDR2 and DDR3
  Interfaces on Arria V, Cyclone V, and Stratix V Devices.
  https://www.intel.com/content/www/us/en/support/programmable/articles/000084806.html
- Cyclone V Device Handbook, External Memory Interfaces in Cyclone V
  Devices (CV-52006) — I/O path registers, DQS postamble handling.
- Intel External Memory Interface Handbook, Volume 3 — hard memory
  controller register map, calibration stages, EMIF Debug Toolkit.
