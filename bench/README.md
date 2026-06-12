# Zolver benchmark & cross-validation harness

End-to-end speed benchmarks for the solver, plus accuracy cross-validation
against [TexasSolver](https://github.com/bupticket/TexasSolver) (the free
reference solver, vendored in-repo at `../TexasSolver-v0.2.0-Linux/`).

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
python3 bench/run_bench.py --runs 1            # speed matrix -> bench/out/results.md
bench/run_validation.sh v1b v2                 # cross-validate
```

## Speed results (8 threads, 128 forced iterations, Ryzen-class 8c/16t)

One axis changed per spot from the SRP baseline (spot 1).

| Spot | Tree | Memory | ms/iter | exploit @128 |
|------|------|--------|---------|--------------|
| 1 srp_dry (rainbow) | 288A 389T | 757 MB | 274 | 0.66% |
| 2 srp_twotone | 288A 389T | 461 MB | 166 | 0.37% |
| 3 srp_monotone | 288A 389T | 219 MB | 81 | 0.34% |
| 4 3bet_dry | 204A 269T | 342 MB | 121 | 0.30% |
| 5 srp_3sizings | 1108A 1613T | 3604 MB | 1171 | 1.31% |
| 6 srp_raisecap (2/1/1) | 372A 493T | 913 MB | 324 | 0.57% |

Takeaways:
- **Suit isomorphism is the dominant memory/speed lever on texture**: identical
  tree (288A/389T), but rainbow -> two-tone -> monotone cuts memory 757 -> 461
  -> 219 MB and ms/iter 274 -> 166 -> 81 (~3.4x faster monotone vs rainbow).
- **Bet-size count is the tree-blowup lever**: going 2 -> 3 sizings per street
  (spot 5) explodes the tree ~4x (288 -> 1108 actions), memory ~5x (3.6 GB) and
  ms/iter ~4x. Raise depth (spot 6) is much cheaper than extra sizings.
- At its operating point (stop ~0.3-0.5%), most realistic single-/two-sizing
  spots solve in well under a minute on 8 threads.

## Accuracy cross-validation (vs TexasSolver)

Method: per-hand frequency matching is confounded by equilibrium multiplicity
(indifferent hands have equal EV, so two correct solvers resolve them
differently). TexasSolver v0.2.0 also doesn't dump per-hand EVs. So we compare
**aggregate / by-class action frequencies** on a **matched, well-converged**
tree. To guarantee an identical tree we use a shallow stack (all-in is a modest
overbet, not a wild shove) with flop-only betting (turn/river check down), and
write TexasSolver ranges as explicit hand lists (its console parser rejects `+`).

**V2** (As 8d 3c, pot 20, 18 vs 13 hands, both solvers converged to ~0.05%):

| | Zolver | TexasSolver |
|--|--------|-------------|
| OOP root check / bet | 71.5% / 28.5% | 68.8% / 31.2% |

Bet-frequency by made-hand class agrees within ~1-6% on most classes (no-pair,
set, pocket-pair) and ~13% on the marginal "pair" class. Per-combo differences
are dominated by indifference (e.g. QQ facing a bet calls in TexasSolver, folds
in Zolver — equal EV). Conclusion: the two independent solvers agree on the
equilibrium's aggregate shape.

## How this harness paid off

It immediately surfaced a critical convergence bug: the cumulative average
strategy was stored in `f16`, whose running sum overflowed (CFR+ -> NaN at
~iter 360) or lost precision (DCFR drifts/collapses). Fixed by moving the
accumulator to `f32`; convergence now improves monotonically (the stock example
reaches 0.001%, previously stuck rising at 0.06%). See the commit that changed
`src/storage.zig` + `src/kernels.zig`.
```
