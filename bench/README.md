# Zolver benchmark & cross-validation harness

End-to-end speed benchmarks for the solver, plus accuracy cross-validation
against [TexasSolver](https://github.com/bupticybee/TexasSolver). The optional
TexasSolver v0.2.0 package lives at `TexasSolver-v0.2.0-Linux/` in the repository
root (or set `TEXASSOLVER_DIR` to its location).

## Layout

```
bench/
  spots/                     # benchmark configs (one axis varied per spot)
  validation/zolver/*.toml   # Zolver cross-validation configs
  validation/texassolver/*.txt
  run_bench.py               # runs spots/, parses output, writes out/results.md
  run_thread_bench.sh        # thread-pool wall+CPU benchmark (1/2/4/8 threads)
  run_validation.sh          # runs both solvers + compare.py for each Vn
  compare.py                 # aligns Zolver vs TexasSolver flop strategies
  out/                       # generated outputs (gitignored if you prefer)
```

## Running

```bash
zig build -Doptimize=ReleaseFast
python3 bench/run_bench.py                      # 1 warm-up + 3 median samples per spot
TEXASSOLVER_DIR=/path/to/TexasSolver-v0.2.0-Linux bench/run_validation.sh v1b v2
```

## Thread-pool benchmark (follow-up work item 2 — done)

`bench/run_thread_bench.sh` drives the three real solver consumers — a **solve
iteration**, an **exploitability pass**, and the default **JSON output pass** —
at 1/2/4/8 threads and reports wall time and total process CPU time. The key
column is `cores_busy = CPU / wall`: the average number of cores kept busy,
including any idle-worker spin.

```bash
zig build bench-threads -- bench/spots/1_srp_dry.toml   # one spot, prints a table + JSON
bench/run_thread_bench.sh                               # all 3 texture spots -> out/threads/
```

The binary is pinned to ReleaseFast in `build.zig`; JSON goes to stdout, the
human table to stderr. Defaults are deliberately low-rep (a single long serial
call already gives a stable CPU ratio); raise them with `--iters/--warmup/`
`--exploit-reps/--output-reps` for tighter wall numbers.

### Before (busy-spin pool)

Measured at `d933f48`, ReleaseFast, DCFR, 16 logical CPUs, on `1_srp_dry`
(rainbow). Idle workers pure-spun on `generation`, so serial phases pinned
every core.

| Phase | 1t | 2t | 4t | 8t | 8t speedup | 8t cores_busy | 8t efficiency |
|-------|----|----|----|----|-----------|---------------|---------------|
| solve (ms/iter)   | 1239 | 632 | 337 | **197** | 6.29× | 7.93 | **79%** |
| exploit (ms/pass) | 3107 | 2187 | 1887 | **1741** | 1.78× | **7.97** | **22%** |
| output (ms/pass)  | 24457 | 21382 | 21136 | **21751** | 1.12× | **7.98** | **~0%** |

### After (spin-then-park pool)

Measured post spin-then-park (`src/threading.zig`), ReleaseFast, DCFR, 16
logical CPUs, on `1_srp_dry`; `2_srp_twotone` / `3_srp_monotone` agree within
~5% (all use the 764.6 MB physical runout space). Workers spin a bounded
budget (~1 ms) then park on a Linux futex over `generation`. Matched before/
after on this machine (same flags) left solve `ms/iter` flat (~200 ms) while
cutting serial-phase CPU.

| Phase | 1t | 2t | 4t | 8t | 8t speedup | 8t cores_busy | 8t efficiency |
|-------|----|----|----|----|-----------|---------------|---------------|
| solve (ms/iter)   | 1309 | 709 | 383 | **220** | 5.96× | **7.90** | **74%** |
| exploit (ms/pass) | 3201 | 2349 | 2007 | **1825** | 1.75× | **1.99** | **22%** |
| output (ms/pass)  | 25337 | 22438 | 21845 | **22162** | 1.14× | **1.17** | **~0%** |

Findings:
- **Solve hot path is preserved.** At 8 threads, `cores_busy` stays ~7.9 and
  matched before/after wall times are within noise. The spin budget bridges the
  sub-ms gaps between the many `forkJoin` calls inside one iteration, so
  workers almost never park during the solve loop.
- **Exploitability parks between its four fork–join passes.** Wall time is
  unchanged (~1.8 s, still only 1.75× scaling — the work is mostly serial
  reduction), but `cores_busy` drops from **7.97 → 1.99**. The remaining ~2
  cores are real parallel work plus the main thread, not 7 idle spinners.
- **Output is serial and no longer pins the machine.** Wall time is still flat
  across thread counts (~22 s), but `cores_busy` drops from **7.98 → 1.17** —
  essentially the main thread alone for the whole dump.
- **CPU reclaimed on serial phases at 8t:** exploit ~14.2 s → ~3.6 s of CPU
  per pass; output ~177 s → ~26 s of CPU per pass (same wall). That is the
  whole point of the change.
- **Note on pure vs end-to-end ms/iter:** the pure solve iteration (~200–220 ms
  at 8t) is *below* the end-to-end 271–296 ms/iter in the physical-runout
  table below, because that older number folds in periodic exploitability and
  init, which this harness times separately.

**Item 2 complete.** Parking uses a direct Linux futex on `generation` (no
`std.Io` plumbing; Linux-only, matching the existing `clock_gettime` path).
Determinism is unchanged — parking only affects wake timing, not work claiming
or the canonical reduction order. Raw JSON in `bench/out/threads/`.

## Physical-runout speed results (8 threads, 128 forced iterations)

Measured on Linux after spin-then-park, ReleaseFast, DCFR (α=1.5, β=0, γ=2),
using one warm-up plus three measured samples per spot. All rows assert the
full 49-turn / 2,352 ordered-runout traversal. Memory and exploitability are
unchanged vs the pre-park baseline at `669702c`; wall ms/iter is at least as
fast (machine variance ± a few percent).

| Spot | Tree | Total memory | ms/iter | exploit @128 |
|------|------|--------|---------|--------------|
| 1 srp_dry (rainbow) | 288A 389T | 764.6 MB | 271 | 1.2902% |
| 2 srp_twotone | 288A 389T | 764.6 MB | 296 | 0.7528% |
| 3 srp_monotone | 288A 389T | 764.6 MB | 295 | 0.9446% |
| 4 3bet_dry | 204A 269T | 346.9 MB | 127 | 0.7857% |
| 5 srp_3sizings | 1108A 1613T | 3611.4 MB | 1267 | 2.3985% |
| 6 srp_raisecap (2/1/1) | 372A 493T | 920.1 MB | 357 | 1.6058% |

Takeaways:
- **Physical chance has a fixed texture footprint**: the matched
  rainbow/two-tone/monotone trees all retain 764.6 MB and take ~271/296/295
  ms/iter. No solve-time suit compression is active.
- **Bet-size count is the tree-blowup lever**: going 2 -> 3 sizings per street
  (spot 5) explodes the tree ~4x (288 -> 1108 actions), memory ~4.7x (3.6 GB),
  and ms/iter ~4.7x. Raise depth (spot 6) is much cheaper than extra sizings.
- **Spin-then-park does not change retained memory** (still covered by
  `max_budget_bytes`); it only cuts idle CPU during serial phases.

## Accuracy cross-validation (vs TexasSolver)

Method: per-hand frequency matching is confounded by equilibrium multiplicity
(indifferent hands have equal EV, so two correct solvers resolve them
differently). TexasSolver v0.2.0 also doesn't dump per-hand EVs. So we compare
**aggregate / by-class action frequencies** on a **matched, well-converged**
tree. To guarantee an identical tree we use a shallow stack (all-in is a modest
overbet, not a wild shove) with flop-only betting (turn/river check down), and
write TexasSolver ranges as explicit hand lists (its console parser rejects `+`).

The `v1`, `v1b`, and `v2` fixture inputs are retained. `run_validation.sh`
materializes their output paths, forces TexasSolver's `set_use_isomorphism 0`,
and saves a JSON comparison summary alongside raw solver outputs. This keeps the
external check on the same physical-runout convention as Zolver; strategy
differences are interpreted in aggregate because equilibria may be non-unique.

## How this harness paid off

It immediately surfaced a critical convergence bug: the cumulative average
strategy was stored in `f16`, whose running sum overflowed (CFR+ -> NaN at
~iter 360) or lost precision (DCFR drifts/collapses). Fixed by moving the
accumulator to `f32`; convergence now improves monotonically (the stock example
reaches 0.001%, previously stuck rising at 0.06%). See the commit that changed
`src/storage.zig` + `src/kernels.zig`.
```
