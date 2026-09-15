# Solver improvements — implementation and validation

Scope: solver, library, CLI, and validation tooling. No UI changes.
Baseline: `b37da9f` (`refined`), Zig 0.16.0, Linux.

## Completed changes

- [x] Correct DCFR history-discount indexing. Explicit recurrence tests verify
  preceding-iteration regret discounts and quadratic average sample weights.
- [x] Use f64 blocker/card/tie-group/terminal intermediates. Preserve f32
  storage and SIMD training kernels. A tiny compatible-reach regression now
  returns its nonzero payoff instead of losing it to cancellation.
- [x] Avoid clearing/merging all 52 card sums for every showdown tie group.
- [x] Validate node, street, runout, and hand combinations in extraction APIs.
- [x] Add an independent physical-runout f64 profile and best-response evaluator,
  optional final verification, and complete saved-policy verification.
- [x] Make external comparisons require full structural coverage and actual
  commitment amounts, with configurable mean/max/p95 numerical gates.
- [x] Reset training storage between thread-benchmark trials and time the
  routine two-pass gap. Zero repetitions safely skip optional phases.
- [x] Remove root-blocked and zero-weight hands before range, storage, and
  symmetry allocation. Range-local indices consequently change.
- [x] Precompute board-specific hand orbits for regret projection.
- [x] Reuse canonical uncached all-in evaluations for symmetric training
  reaches; retain general evaluation for arbitrary asymmetric reaches.
- [x] Build all-in matrices using integer win/tie counts. Retain both player
  orientations for contiguous reads. Consider memory and iteration count when
  selecting the cache, including temporary construction memory.
- [x] Support actual turn and river roots throughout config, tree construction,
  traversal, extraction, summaries, JSON, and verification.
- [x] Add optional DCFR+ and PDCFR+. Prediction storage is separately budgeted.
  Keep DCFR as the default recommendation; alternatives do not always win.
- [x] Add fresh-process algorithm and one-size-at-a-time sensitivity studies.
  Report missed targets explicitly and preserve configs, logs, and outputs.
- [x] Fix allocation-failure cleanup in range-index helpers and thread-pool init.

## Validation

- **256/256 ReleaseSafe tests pass** (baseline: 250).
- **35/35 kernel tests pass in Debug.** The all-algorithm 1/2/4/8-thread
  determinism test also passes in Debug, including prediction invariants.
- ReleaseFast application, kernel benchmark, and thread benchmark builds pass.
- Python comparison tests pass, including amount mismatches, missing coverage,
  invalid probabilities, and failed numerical gates.
- Full-storage serial/parallel determinism at 1/2/4/8 threads, and pruning
  parity, cover all four algorithms, including PDCFR+ prediction storage.
- Independent f64 evaluations cover all root streets and algorithms, cached
  and uncached evaluation. They agree with the production evaluator within
  explicit numerical tolerances.
- Complete flop/river JSON round trips pass independent verification;
  incomplete exports and changed action labels are rejected.
- CLI turn-root solve, summary, complete export, and re-verification pass.
  Root EVs are present; the output contains the turn plus 48 physical rivers.
- Retained TexasSolver fixtures pass the new mean gate with complete coverage:
  v1 mean difference approximately 0.041; v1b mean 0.03095, all 8/8 nodes and
  520 combo/action entries matched. These are retained reference exports, not
  new TexasSolver runs. v1b max difference is 0.55577 and p95 is 0.20651, so
  the stricter maximum gate would correctly fail. Frequency agreement is not
  itself an equilibrium certificate.
- On `bench/validation/zolver/v2.toml`, DCFR reaches the 0.05% target in 768
  iterations. Independent physical f64 verification reports **0.044787052%**;
  profile EVs sum to the 20-chip pot to the displayed 12 decimal places.

Commands:

```bash
zig build test --summary all
zig build -Doptimize=ReleaseFast
zig test src/kernels.zig -O Debug
python3 -m unittest discover -s bench -p 'test_*.py'
zig-out/bin/zolver solve bench/validation/zolver/v2.toml --verify
```

## Matched performance

`bench/spots/1_srp_dry.toml`, ReleaseFast, same machine. Fresh solver for each
worker count, two warm-up iterations followed by four timed iterations and one
two-pass gap check. Three samples per version, alternating version order;
medians below. Original sources were extracted from `b37da9f` into a separate
temporary directory. No simultaneous benchmark workloads ran during sampling.

| Phase | Original | Updated | Reduction |
|---|---:|---:|---:|
| Iteration, 1 thread | 1273.55 ms | 1105.32 ms | 13.2% |
| Iteration, 8 threads | 190.85 ms | 166.02 ms | 13.0% |
| Gap check, 1 thread | 1511.64 ms | 1287.03 ms | 14.9% |
| Gap check, 8 threads | 213.34 ms | 182.59 ms | 14.4% |

[Raw samples and probe source](bench/results/solver-review.json).

This is a short, single-fixture throughput comparison, excluding startup.
The corrected DCFR weights change the six-iteration strategy, so these timings
are not a time-to-equal-accuracy comparison. The six-iteration gaps are 57.4645%
original and 58.7139% updated; an indexing correction need not improve every
early checkpoint.

## Algorithm and tree studies

On the larger v2 flop fixture, the optional DCFR+ settings alpha=1.5/gamma=4
reach the 0.05% target in 576 iterations versus DCFR's 768. Independent
f64 verification reports **0.049467729%** for that DCFR+ profile.
PDCFR+ ends at 0.0777% and CFR+ at 0.1366% after the 1,000-iteration cap;
neither reaches that target. These are workload-specific results.

A separate river study uses the v1 ranges and flop, known turn `2c`, river
`7h`, a 0.001% target, check interval 16, and cap 8,192. All runs include
independent final verification. Three measured fresh processes follow one
warm-up for each variant:

| Variant | Iterations to verified target |
|---|---:|
| DCFR | 1,952 |
| DCFR+ (alpha=1.5, gamma=4) | 3,440 |
| PDCFR+ (alpha=2.3, gamma=5) | 7,520 |
| CFR+ | 5,568 |
| Original DCFR tree plus a 50% river bet | 4,352 |

All four algorithms converge, but the default wins this river example.
Adding the 50% river bet changes root OOP EV by about +0.0334 chips, larger
than the residual solve gap. The study tool reports this sensitivity; it does
not automatically interpret it as a profitable omitted deviation.

## Interfaces and limits

- Set `game.turn` and optionally `game.river` to change the solve root.
  Supply the current pot, remaining effective stack, and conditional ranges.
  Roots start a betting round; arbitrary states facing an existing bet are
  not modeled by these config fields.
- `solve --verify` or `solver.verify_final = true` independently checks the
  in-memory profile and gates CLI convergence on that check.
- `zolver verify original.toml complete.json` validates and evaluates the
  rounded saved policy; it requires complete runout coverage and the original
  range weights. The default partial flop dump cannot certify continuation
  play. Use `--all-runouts` to produce a complete export.
- Library APIs: `verify.exploitability`, `verify.verifyExport`, and
  `best_response.solveVerified`. The existing `solve` API stays fast.
- Low-level terminal scratch card/compatibility buffers now use `[]f64`.
  Callers constructing those buffers directly must update their types.
- Training remains f32. The independent verifier uses physical runouts and
  f64 pairwise sums, but shares the betting tree and card-strength evaluator.
  It is a numerical cross-check, not a formal proof or an independent hand
  evaluator implementation. Broad flop verification can be expensive.
- Verification scratch and predictive storage are budget checked. JSON
  parsing/output allocations and native thread stacks are outside the solver
  memory budget. Cache selection uses a rough cost model, not autotuning.
- Exploitability is relative to the configured betting tree. The sensitivity
  tool evaluates separate expanded trees and helps prioritize further sizes.
  A true off-tree best response needs an explicit policy for responding to
  previously absent actions; inventing that response would give misleading
  results. No unrestricted no-limit accuracy bound is claimed.

See [study usage](bench/README.md#algorithm-and-betting-tree-studies) and
[configuration and verification](README.md#direct-turnriver-solves-and-independent-verification).

Algorithm references: [DCFR paper](https://arxiv.org/abs/1809.04040) and
[DCFR+/PDCFR+ paper](https://www.ijcai.org/proceedings/2024/0583.pdf).
