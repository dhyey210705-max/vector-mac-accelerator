# Parameterized Vector MAC Accelerator

A compact, parameterized RTL hardware accelerator that computes a vector dot product
(multiply-accumulate reduction) in Verilog-2001, built and verified as a portfolio
project for RTL/VLSI design interviews.

```
Y = SUM( A[i] * B[i] ),  i = 0 .. VECTOR_LEN - 1
```

## Problem statement & motivation

The MAC (multiply-accumulate) reduction is the core primitive behind FIR filters,
dot products, and the innermost loop of matrix-vector multiplication in DSP/ML
datapaths. This project implements it as a small, synthesizable, parameterized
hardware block — chosen specifically to demonstrate real microarchitecture and
verification skills on a design small enough to fully whiteboard and re-derive
from memory, rather than a large project that's hard to defend line-by-line.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | System clock |
| `rst_n` | in | 1 | Active-low reset (async assert, sync deassert) |
| `start` | in | 1 | Pulse to begin a new MAC sequence |
| `a_in` | in | `DATA_WIDTH` | Element A[i], streamed one per cycle |
| `b_in` | in | `DATA_WIDTH` | Element B[i], streamed one per cycle |
| `result` | out | `ACC_WIDTH` | Final accumulated sum |
| `busy` | out | 1 | High while a sequence is in progress |
| `done` | out | 1 | One-cycle pulse when `result` is valid |

**Interface choice:** operands stream in one pair per cycle rather than being
pre-loaded into an internal array, keeping on-chip storage to a single register
per operand instead of `VECTOR_LEN × DATA_WIDTH` bits of memory. This matches how
a MAC unit would typically sit behind a FIFO or memory controller in a larger
pipeline.

## Parameters

```verilog
DATA_WIDTH = 8   // width of each A/B element
ACC_WIDTH  = 32  // accumulator/result width — must cover worst-case sum
VECTOR_LEN = 8   // number of MAC operations per sequence
```

## Microarchitecture

```
             +-------------+
a_in ------> |             |
             | Multiplier  | ---> product (2*DATA_WIDTH bits)
b_in ------> |             |
             +-------------+
                    |
                    v
             +-------------+
    acc_reg->| Accumulator |---> acc_next = acc_reg + product
             +-------------+
                    |
                    v
             +-------------+
             |   result    |  (registered in S_DONE)
             +-------------+

                 ^
                 |
             Control FSM  <--- start, count == VECTOR_LEN-1
                 |
          Index Counter (0 .. VECTOR_LEN-1)
```

- **Datapath**: one combinational multiplier (`2×DATA_WIDTH` wide, to avoid
  truncating the product before accumulation) feeding a single `ACC_WIDTH`-bit
  accumulator register.
- **Control path**: a 3-state FSM (`IDLE → COMPUTE → DONE → IDLE`) plus a small
  index counter that tracks how many elements have been accumulated.

### FSM

```
        start
  IDLE -------> COMPUTE --------------> DONE
   ^                |  (count==LEN-1)     |
   |                | else stay COMPUTE   |
   +----------------+---------------------+
                (1 cycle in DONE, then back to IDLE)
```

- **IDLE**: `busy=0`. On `start`, the first element (already valid on `a_in`/`b_in`
  this same cycle) is accumulated directly, and `count` is set to 1.
- **COMPUTE**: `busy=1`. Each cycle accumulates the current `a_in × b_in` and
  increments `count`, until `count == VECTOR_LEN-1` (meaning this cycle is
  processing the last element), at which point the FSM moves to `DONE`.
- **DONE**: registers `acc_reg` into `result`, pulses `done` for exactly one
  cycle, then returns to `IDLE`.

A `start` pulse received while `busy=1` is deliberately ignored — verified
explicitly in the testbench.

### Timing

Measured (not estimated) from simulation: one full sequence takes
**`VECTOR_LEN + 1` clock cycles** — `VECTOR_LEN` cycles of one MAC each
(the first folded into the `IDLE→COMPUTE` transition cycle) plus one cycle
for `DONE` to register the result and pulse `done`.

## Verification methodology

A self-checking Verilog testbench (`tb/mac_accelerator_tb.v`) instantiates two
DUT configurations (`VECTOR_LEN=8` and `VECTOR_LEN=4`) and computes each
expected result independently in the testbench itself, comparing against the
RTL output with `===`. Coverage:

1. Reset behavior
2. Single MAC sequence, positive values
3. All-zero inputs
4. Maximum input values (overflow-safe accumulator check)
5. Multiple consecutive back-to-back operations
6. `start` asserted while busy (must be ignored)
7. A different `VECTOR_LEN` configuration
8. Reset asserted mid-computation
9. Functional correctness after a mid-operation reset
10. `done` asserted for exactly one cycle

**During verification, cycle-by-cycle waveform tracing caught a real FSM/datapath
timing bug** in the initial RTL: the first streamed element was silently dropped
(accumulated during a cycle where the control logic was still in `IDLE` and only
performing a reset), while the last element was accumulated twice (the FSM
lingered one extra cycle in `COMPUTE` before the counter's stop condition caught
up). The fix folds the first MAC into the `IDLE→COMPUTE` transition cycle and
re-bases the counter to mean "elements already accumulated." Full trace and
fix are documented in the verification writeup.

### Simulation results

Verified in two independent simulators — Icarus Verilog and Xilinx Vivado XSim —
with identical results:

```
TOTAL: 12 PASS, 0 FAIL
=== ALL TESTS PASSED ===
```

**Vivado XSim waveform**, all 12 tests passing (`pass_count = 0xc = 12`,
`fail_count = 0`):

![All tests passed](docs/waveform_all_pass.png)

Run with Icarus Verilog:
```bash
iverilog -g2001 -o sim.out rtl/mac_accelerator.v tb/mac_accelerator_tb.v
vvp sim.out
gtkwave simulation/waveform.vcd
```

Run with Vivado: create a project, add `rtl/mac_accelerator.v` as a design
source and `tb/mac_accelerator_tb.v` as a simulation source, set
`mac_accelerator_tb` as the simulation top, then Run Simulation → **Run All**
(the testbench self-terminates via `$finish`).

## Performance analysis

- **Latency**: `VECTOR_LEN + 1` cycles per sequence (measured via simulation).
- **Throughput**: 1 MAC/cycle while `busy`, independent of `VECTOR_LEN`.
- **Scaling**: latency is `O(N)` in `VECTOR_LEN` — expected for a sequential
  single-MAC datapath with no intra-sequence parallelism.
- A parallel `k`-lane variant (not implemented) would reduce latency to roughly
  `O(N/k + log k)` at the cost of `k` multipliers and adder-tree combining logic
  — a natural extension discussed but not built or measured here.

## Area considerations

Dominant resource: **one multiplier** (`DATA_WIDTH × DATA_WIDTH`), whose area
grows roughly quadratically with `DATA_WIDTH` for a straightforward
array/Wallace-tree implementation. Everything else (accumulator, result
register, counter, 2-bit FSM state) scales linearly or logarithmically.
Increasing `VECTOR_LEN` barely affects area (only `log2(VECTOR_LEN)` bits of
counter/accumulator headroom); increasing `DATA_WIDTH` is the expensive knob.
A `k`-lane parallel version scales area roughly linearly with `k`.

## Power considerations

RTL-level, qualitative only — no synthesis/power tool was run, so no numbers
are claimed:

- The multiplier dominates switching activity since it re-evaluates every
  cycle `busy` is high.
- `result` only updates once per sequence (low activity); `acc_reg` updates
  every active cycle (higher activity).
- Operand isolation on the multiplier inputs during `IDLE`/`DONE` would reduce
  wasted combinational switching in a stall-capable variant, though this
  single-cycle-per-state design has limited need for it.
- The sequential single-MAC architecture inherently has fewer simultaneously-
  switching multipliers than a parallel version — a qualitative power
  advantage that trades off directly against latency.

## Design tradeoffs: sequential vs. parallel

| | Sequential (this design) | Parallel (k lanes) |
|---|---|---|
| Area | Minimal (1 multiplier) | ~linear in k |
| Latency | O(N) | ~O(N/k) |
| Throughput | 1 MAC/cycle | up to k MACs/cycle |
| Power | Lower peak | Higher peak |
| Complexity | Simple FSM | Needs partial-sum combining |

The sequential design was chosen for this project because it's small enough to
fully explain and re-derive on a whiteboard while still exercising every core
RTL concept an interviewer probes for.

## Clocking

Single clock domain (`clk`), active-low async-assert/sync-deassert reset
(`rst_n`). No clock-domain crossing, no PLL, no clock gating.

## Limitations

- Single MAC unit — no intra-sequence parallelism.
- Operands must be streamed exactly one valid pair per cycle while `busy=1`;
  there's no stall/backpressure input.
- No overflow detection flag — `ACC_WIDTH` must be sized by the integrator to
  cover the worst-case sum for the chosen `DATA_WIDTH`/`VECTOR_LEN`.
- No power/area numbers beyond qualitative RTL-level reasoning — synthesis was
  not run as part of this project.

## Future improvements

- Parallel `k`-lane variant with an adder-tree combiner.
- Streaming backpressure (`a_valid`/`b_valid` or ready/valid handshake) instead
  of the fixed one-per-cycle assumption.
- Optional saturating accumulator with overflow flag.
- Gate-level synthesis + power analysis to replace qualitative claims with
  measured numbers.

## Repository structure

```
vector-mac-accelerator/
│
├── rtl/
│   └── mac_accelerator.v
│
├── tb/
│   └── mac_accelerator_tb.v
│
├── docs/
│   ├── architecture.png
│   └── fsm.png
│
├── simulation/
│   └── waveform.vcd
│
└── README.md
```
