# ♠ Zolver — a free, open-source GTO poker solver

**A heads-up post-flop Texas Hold'em solver written in Zig.** Computes
approximate Nash-equilibrium strategies on your own laptop — no subscription,
no cloud, no bloat. A config file and a terminal are all you need.

![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue)
![Tests](https://img.shields.io/badge/tests-217%20passing-brightgreen)

```text
$ zolver solve spot.toml --summary

Strategy summary — flop As Kd 7h

OOP to act:
  hand class    combos      check      bet 5     all-in
  two pair         2      94.6%       4.7%       0.7%
  pair             6      97.5%       1.8%       0.7%

IP vs check:
  hand class    combos      check      bet 5     all-in
  pair             6       9.3%      73.2%      17.5%
  high card        4       5.8%      48.9%      45.3%
```

---

## What is this?

Zolver is a **CFR (Counterfactual Regret Minimization) solver** for heads-up
Texas Hold'em. Give it two players' ranges, a flop, stack sizes, and a betting
structure, and it finds the game-theoretically optimal way to play the rest of
the hand — then tells you, per hand, exactly how often to check, bet, call, or
fold.

It's a **serious study tool** for players who want to understand GTO (game
theory optimal) strategy. It is not a poker bot or a real-time assistant.

## Why use it?

- 🆓 **Free and open source.** Commercial solvers cost hundreds of dollars. This costs nothing.
- 💻 **Runs on consumer hardware.** Designed for laptops and desktops, not server racks.
- 🎯 **Exact, no abstraction.** Solves the full game tree — no card bucketing that blurs the answer.
- ⚡ **Fast.** Multi-threaded, SIMD-accelerated, with suit-isomorphism tree reduction.
- 🔁 **Deterministic.** Byte-for-byte identical results regardless of thread count.
- 📊 **Actually usable output.** Human-readable terminal summaries *and* machine-readable JSON.

## Features

- **Post-flop solving** from any flop, turn, or river state
- **Discounted CFR (DCFR)** and CFR+ algorithms
- **Interactive web UI** — visual config builder (range grid + card picker) and strategy viewer (per-hand grid with game tree navigation)
- **Standard range formats** — `QQ+`, `ATs+`, `A5s-A2s`, `JTs-87s`, weights, just like Equilab/Flopzilla
- **Human-readable summaries** (`--summary`) — see your strategy by hand class at a glance
- **JSON output** — per-street strategy grids + per-hand EVs for any runout
- **Helpful error messages** — `spot.toml:3: expected integer for 'game.initial_pot', got 'abc'`
- **Exploitability measurement** — know exactly how close to Nash equilibrium you are
- **Convergence stopping** — halts automatically once exploitability drops below your threshold
- **Suit isomorphism** — collapses suit-symmetric runouts to shrink the tree dramatically

## Quick Start

First build the binary (see [Installation](#installation)), then alias it for
convenience:

```bash
zig build -Doptimize=ReleaseFast
alias zolver=./zig-out/bin/zolver
```

**The fast path — no text editor needed:**

```bash
# 1. Build your spot in the browser: pick a flop, draw both ranges, set sizings
zolver config                       # interactive range grid + card picker
#    → export to spot.toml when done

# 2. Solve it, then explore the result visually
zolver solve spot.toml -o results.json --summary
zolver view results.json            # interactive strategy viewer in the browser
```

**Prefer the terminal?** Start from a documented example and edit it by hand:

```bash
zolver example --output spot.toml   # writes a fully-commented config
$EDITOR spot.toml
zolver solve spot.toml --summary
```

Running `zolver` with no arguments opens the config builder automatically.

## Screenshots

| Config Builder | Strategy Viewer |
|----------------|-----------------|
| ![Config Builder](screenshots/ranges.png) | ![Strategy Viewer](screenshots/results.png) |

![Terminal Summary](screenshots/termView.png)

## Installation

### Build from source

Requires **Zig 0.16.0**.

```bash
git clone https://github.com/phagmaier/zolver.git
cd zolver
zig build -Doptimize=ReleaseFast
./zig-out/bin/zolver example
```

## CLI Reference

### `zolver solve <config.toml> [flags]`

Loads a config, runs the solver until convergence or `max_iterations`, and
reports results. Flags:

| Flag | Effect |
|------|--------|
| `--summary` | Print a human-readable flop strategy overview to the terminal. |
| `--output <path>` / `-o <path>` | Write the full strategy tree as JSON. |
| `--turn <card>` | Also include the turn subtree for that runout, e.g. `--turn 2c`. |
| `--river <card>` | Also include the river subtree (requires `--turn`), e.g. `--river Ah`. |
| `--all-runouts` | Dump *every* canonical turn/river runout (large; per-hand EVs omitted). |

Progress is printed to **stderr** as it solves:

```text
loaded 'spot.toml'
  ranges: 150/180 combos  tree: 142 actions, 198 terminals  runouts: 49 turns, 2352 rivers
  memory: 45.2 MB  threads: 4
solving...
  start  exploitability: 18.234% (18.234 chips)
  iter     64  exploitability:  1.853% (1.853 chips)  4.7s
  iter    128  exploitability:  0.487% (0.487 chips)  9.5s
solve complete: 128 iterations, 0.487% exploitability, 9.5s elapsed
```

A compact run summary is printed to **stdout**:

```text
iterations: 128
exploitability_pct: 0.487
exploitability_chips: 0.487
avg_ev_oop: 48.32
avg_ev_ip: 51.68
initial_pot: 100
elapsed_s: 9.52
converged: true
```

> **Note on EVs:** `avg_ev_oop` and `avg_ev_ip` sum to `initial_pot` only when
> every dealt matchup reaches a terminal at full weight. When the spot contains
> **pre-river all-ins**, each matchup arrives at only the runouts compatible with
> its private cards (weight < 1), so the two EVs sum to *less* than the pot. This
> is expected — it is the same effect that makes exploitability measure `v_u`
> directly rather than assuming the closed-form constant-sum identity.

### `zolver view <results.json>`

Opens an **interactive strategy viewer** in your browser.

**How to use it:**

- The 13×13 grid shows the acting player's range. Each cell is color-coded by
  what the strategy does with that hand — green = check, orange = bet, red =
  fold, purple = raise, pink = all-in. Brighter = higher probability.
- **Click any cell** to see the exact strategy breakdown and EV for that
  specific hand in the detail panel on the right.
- **Click the action buttons** below the grid (\"bet 66\", \"raise 110\", etc.)
  to navigate deeper into the game tree and see how the opponent responds.
- Use the **player toggle** (OOP / IP / Acting) to view the other player's
  perspective at the same decision point.
- If you solved with `--turn` or `--all-runouts`, use the **street dropdown**
  to switch between flop, turn, and river.
- **Keyboard shortcuts:** `Backspace` goes back up the tree, `Escape` deselects
  the current hand, arrow keys switch streets.
- The viewer also works **standalone** — open the HTML file directly and
  drag-and-drop any `results.json` onto it.

### `zolver config`

Opens an **interactive config builder** in your browser. Build a complete
spot without touching a text editor.

**How to build a spot, step by step:**

1. **Pick the flop** — click three cards from the 52-card deck at the top of
   the right panel. The selected cards appear in the board slots. The range
   grid automatically grays out hands that share cards with the board.

2. **Set OOP's range** — in the left panel (\"OOP Range\" tab):
   - **Left-click** a cell to include that hand in the range (blue highlight).
     Click again to remove it.
   - **Right-click** a cell to open a weight slider — set the hand to 75%, 50%,
     or 25% frequency. Partially-weighted hands show a yellow tint with the
     percentage in the cell. Click **Apply** to confirm or **Cancel** to discard.
   - **Click and drag** across multiple cells to select or deselect a region
     of hands at once.
   - Use the **preset buttons** (\"All Pairs\", \"Suited Aces\", \"Top 20%\",
     etc.) to quickly populate common ranges. Presets replace the current
     selection.

3. **Set IP's range** — switch to the \"IP Range\" tab and repeat. The two
   ranges are independent.

4. **Configure the game** — in the right panel:
   - Set **Initial Pot**, **Effective Stack**, and **Min Bet**.
   - Add or remove **bet sizings** per street (as percentages of the pot).
     Click **+ Add** to add a sizing, the × button to remove one.
   - Set **raise caps** per street (\"none\" = unlimited raising).

5. **Configure the solver** — algorithm, max iterations, target exploitability,
   thread count, SIMD, prune options, and DCFR parameters (hidden when
   CFR+ is selected).

6. **Export** — the **TOML Preview** panel updates live as you edit. Click
   **Copy to Clipboard** or **Download spot.toml**, then run:
   `zolver solve spot.toml -o results.json`

### `zolver example [--output <path>]`

Prints a fully-documented example config to stdout (or to a file).

### `zolver help`

Prints usage.

## Output formats

### `--summary` (terminal)

A range-weighted breakdown of the strategy at the key flop decision points —
OOP's opening action and IP's responses — grouped by made-hand class on the
flop (`set+`, `two pair`, `pair`, `high card`). Perfect for a quick read of
"what should I do with this kind of hand here?"

### `--output results.json` (machine-readable)

The full per-hand strategy tree, ready to feed into a script, notebook, or your
own viewer. The flop tree (runout-independent) is always included; turn/river
subtrees are added on demand with `--turn`/`--river`, or exhaustively with
`--all-runouts`.

```jsonc
{
  "meta": {
    "flop": "As Kd 7h", "initial_pot": 100, "effective_stack": 200,
    "iterations": 128, "exploitability_pct": 0.487,
    "ev_oop": 48.32, "ev_ip": 51.68, "converged": true
  },
  "streets": [
    {
      "street": "flop", "board": "As Kd 7h",
      "nodes": [
        {
          "id": 87, "player": "oop", "line": [],
          "actions": ["check", "bet 50", "all-in"],
          "hands": [
            { "combo": "AhKh", "strategy": [0.05, 0.40, 0.55], "ev": 142.3 }
          ]
        }
      ]
    }
  ]
}
```

`strategy` lines up positionally with `actions`; `line` is the action path from
the root to that node. Bet/raise amounts are in chips.

## Config File Reference

The config uses a TOML-like format. Sections and keys are required unless marked
optional. Bad configs report the exact line and reason, e.g.
`spot.toml:3: expected integer for 'game.initial_pot', got 'abc'`.

### `[game]`

| Key | Type | Description |
|-----|------|-------------|
| `flop` | string | Three flop cards, space-separated. Format: rank + suit (`As Kd 7h`). Ranks: 2-9, T, J, Q, K, A. Suits: s, h, d, c. |
| `initial_pot` | integer | Pot size (in chips) at the start of flop betting. |
| `effective_stack` | integer | The smaller of the two remaining postflop stacks. |
| `min_bet` | integer | Minimum bet/raise increment in chips. *Optional, default: 1.* |
| `max_budget_bytes` | integer | Memory limit before solver rejects the config. *Optional, default: 8 GB.* Increase for large trees with many sizings/raises; lower to avoid excessive swap on low-memory machines. |

### `[game.sizings]`

Bet size fractions as percentages of the pot, per street. An empty list `[]`
means only check and all-in are available. Values must be strictly increasing
per street.

| Key | Type | Description |
|-----|------|-------------|
| `flop` | integer array | Bet sizes on the flop (e.g., `[25, 50, 75]` for 25%, 50%, 75% of pot). |
| `turn` | integer array | Bet sizes on the turn. |
| `river` | integer array | Bet sizes on the river. |

### `[game.raise_cap]`

Maximum number of raises per street. Use `none` or `unlimited` (or omit the key)
for no cap. Use `0` to disallow raises (check/call/fold only).

| Key | Type | Description |
|-----|------|-------------|
| `flop` | integer or `none` | Max raises on the flop. |
| `turn` | integer or `none` | Max raises on the turn. |
| `river` | integer or `none` | Max raises on the river. |

### `[ranges]`

Player hand ranges with frequencies. Format: `HAND[SUFFIX][:WEIGHT]`,
comma-separated. The same notation Equilab and Flopzilla export.

**Single hands:**
- `AK` — all 16 combos (suited + offsuit)
- `AKs` — suited only (4 combos)
- `AKo` — offsuit only (12 combos)
- `88` — pocket pair (6 combos; suffix ignored for pairs)

**Plus ranges:**
- `QQ+` → QQ, KK, AA
- `ATs+` → ATs, AJs, AQs, AKs *(ace fixed, kicker climbs)*
- `T9s+` → T9s, JTs, QJs, KQs, AKs *(gap preserved, climbs to ace)*

**Dash ranges:**
- `99-66` → 99, 88, 77, 66
- `A5s-A2s` → A5s, A4s, A3s, A2s
- `JTs-87s` → JTs, T9s, 98s, 87s

**Weights:** append `:VALUE` (0.0–1.0) to play a hand a fraction of the time.
Default is `1.0`. Applies to plus/dash ranges too (`QQ+:0.5`).

| Key | Type | Description |
|-----|------|-------------|
| `oop` | string | Out-of-position player's preflop range. |
| `ip` | string | In-position player's preflop range. |

**Examples:**
```toml
oop = "QQ+, AKs, AQs+, AJo+, T9s+, 88:0.5"
ip  = "JJ+, AKs, KQs, A5s-A2s:0.5"
```

### `[solver]`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `algorithm` | string | — | `"dcfr"` (recommended) or `"cfr_plus"`. |
| `max_iterations` | integer | `1000` | Hard cap on solve iterations. |
| `target_exploitability_pct` | float | `0.5` | Stop when exploitability reaches this % of the initial pot. |
| `num_threads` | integer | `0` | Worker threads. `0` = serial. `4` = 3 workers + main thread. |
| `prune_zero_reach` | boolean | `false` | Skip subtrees where the opponent has zero probability mass. Safe to enable. |
| `use_simd` | boolean | `true` | Use SIMD vectorized kernels (8-wide f32). Recommended. |
| `check_interval` | integer | `64` | Exploitability re-check cadence after iterations 32, 64, 128. |
| `debug_invariants` | boolean | `true` (Debug) | Run NaN/Inf scans of regret arrays after every pass. |

### `[solver.dcfr]`

DCFR discounting parameters. Only used when `algorithm = "dcfr"`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `alpha` | float | `1.5` | Discount exponent for positive regrets. |
| `beta` | float | `0.0` | Discount exponent for negative regrets. |
| `gamma` | float | `2.0` | Strategy averaging weight exponent. |

### Complete example

```toml
[game]
flop = "As Kd 7h"
initial_pot = 100
effective_stack = 200
min_bet = 1
max_budget_bytes = 8589934592  # 8 GB — increase for large trees

[game.sizings]
flop = [25, 50, 75]
turn = [25, 50]
river = [50, 100]

[game.raise_cap]
flop = 1
turn = none
river = 1

[ranges]
oop = "QQ+, AKs, AQs+, AJo+, T9s+, 88:0.5"
ip  = "JJ+, AKs, KQs, A5s-A2s:0.5"

[solver]
algorithm = "dcfr"
max_iterations = 1000
target_exploitability_pct = 0.5
num_threads = 4
prune_zero_reach = true

[solver.dcfr]
alpha = 1.5
beta = 0.0
gamma = 2.0
```

## How It Works

### Algorithm

Zolver uses **Discounted CFR (DCFR)** with parameters α=1.5, β=0, γ=2 — the
configuration recommended by Brown & Sandholm (2019) for fastest convergence in
large games. Each iteration, one player updates their regrets while the opponent
plays their current strategy, then the roles swap. Strategies are extracted from
accumulated positive regrets via regret matching.

### Game tree

The tree is built from the betting structure you specify. Action nodes branch on
every legal action (check, fold, call, bet, raise, all-in); chance nodes deal the
turn and river; terminal nodes are folds or showdowns.

### Suit isomorphism

Rather than considering all 49×48 turn/river combinations, the solver exploits
suit symmetries to collapse the runout space. On a rainbow flop every turn card
is canonical; on two-tone or monotone flops many runouts are equivalent,
dramatically reducing tree size and memory.

### Exploitability

Exploitability measures how far a strategy is from Nash equilibrium, in chips per
hand and as a percentage of the initial pot. Lower is stronger. The solver stops
automatically once it drops below `target_exploitability_pct`.

## Performance

All measurements on a Ryzen 7 7840U (8 cores / 16 threads), `ReleaseFast`
build, DCFR with α=1.5 β=0 γ=2.

### Kernel throughput (bench.zig micro-benchmarks)

| Kernel | Scalar | SIMD | Speedup |
|--------|--------|------|---------|
| Regret matching | 1,005 Mslots/s | 11,504 Mslots/s | 11.5× |
| DCFR regret update | 2,757 Mslots/s | 12,939 Mslots/s | 4.7× |
| Strategy accumulation | 1,727 Mslots/s | 10,570 Mslots/s | 6.1× |
| Showdown sweep | — | — | 319 Mhands/s |

### Thread scaling — realistic 3-bet pot (74/76 combos, Qh Jd 6s, 2 sizings, 482 MB)

| Threads | ms/iter | 64-iter solve | Speedup |
|---------|---------|---------------|---------|
| 1 | ~910 | 61.0s | 1.0× |
| 8 | ~180 | 13.5s | 4.5× |

### Spot complexity comparison (8 threads, target 0.5% exploitability)

| Spot | Sizings | Raises | Tree | Memory | ms/iter | Solve time |
|------|---------|--------|------|--------|---------|------------|
| Standard (rainbow) | 2×3 | 1/0/0 | 348A 477T | 482 MB | ~180 | 13.5s (64 iters) |
| Complex (rainbow) | 3×3 | 2/1/1 | 1,332A 1,901T | 2,056 MB | ~1,000 | 141.9s (128 iters) |
| Complex (monotone) | 3×3 | 2/1/1 | 1,332A 1,901T | 594 MB | ~280 | 35.9s (128 iters) |

Suit isomorphism collapses the monotone flop from 49 → 23 canonical turns
(3.5× fewer runouts), delivering a proportional speedup with identical strategy
quality. Convergence plateaus around 0.1% exploitability — targeting 0.5% is
the practical sweet spot. Scaling is sublinear beyond ~8 threads due to the
serial flop descent (~3.7% of runtime per Amdahl's law).

## Limitations

- **Heads-up only.** Multi-way pots are not supported.
- **Post-flop only.** The solver always begins at the flop; preflop solving is out of scope.
- **No abstraction.** It solves the full game tree with no card bucketing — exact, but the tree can grow large with many bet sizes.

## Project Status

The solver is **complete and tested (217 tests)** — from tree construction
through threaded DCFR, best response, exploitability, SIMD kernels, output
extraction, JSON export, interactive web UI (config builder + strategy viewer),
and human-readable summaries. See
[`AGENTS.md`](AGENTS.md) for detailed implementation notes.

## Building

```bash
# Debug build (assertions + invariant checks)
zig build

# Release build (fast)
zig build -Doptimize=ReleaseFast

# Run the test suite
zig build test

# Run benchmarks
zig run -OReleaseFast src/bench.zig
```

## License

MIT — see [LICENSE](LICENSE) for details.

## Acknowledgments

This project draws on the academic literature on CFR and its variants:

- Zinkevich et al. (2008) — Regret minimization in games
- Brown & Sandholm (2019) — Discounted CFR
- Tammelin (2014) — CFR+
- Johanson et al. (2012) — Suit isomorphism for poker
```
