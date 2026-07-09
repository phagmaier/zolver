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

## Physical-runout speed results (8 threads, 128 forced iterations)

Measured on Linux at `669702c`, ReleaseFast, DCFR (α=1.5, β=0, γ=2), using
one warm-up plus three measured samples per spot. All rows assert the full
49-turn / 2,352 ordered-runout traversal.

| Spot | Tree | Total memory | ms/iter | exploit @128 |
|------|------|--------|---------|--------------|
| 1 srp_dry (rainbow) | 288A 389T | 764.6 MB | 296 | 1.2902% |
| 2 srp_twotone | 288A 389T | 764.6 MB | 319 | 0.7528% |
| 3 srp_monotone | 288A 389T | 764.6 MB | 320 | 0.9446% |
| 4 3bet_dry | 204A 269T | 346.9 MB | 140 | 0.7857% |
| 5 srp_3sizings | 1108A 1613T | 3611.4 MB | 1417 | 2.3985% |
| 6 srp_raisecap (2/1/1) | 372A 493T | 920.1 MB | 332 | 1.6058% |

Takeaways:
- **Physical chance has a fixed texture footprint**: the matched
  rainbow/two-tone/monotone trees all retain 764.6 MB and take 296/319/320
  ms/iter. No solve-time suit compression is active.
- **Bet-size count is the tree-blowup lever**: going 2 -> 3 sizings per street
  (spot 5) explodes the tree ~4x (288 -> 1108 actions), memory ~4.7x (3.6 GB),
  and ms/iter ~4.8x. Raise depth (spot 6) is much cheaper than extra sizings.

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
