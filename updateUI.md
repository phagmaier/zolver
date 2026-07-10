# Minimal UX fix list (effort × impact)

No code changes — prioritized backlog only. Rule of thumb: **stop after tier 1–2** unless users keep complaining.

**Effort scale:** S = hours · M = ~1 day · L = multi-day  
**Impact scale:** 1–5 (5 = “people bounce / wrong results / can’t use the tool”)

---

## Tier 0 — Ship blockers / correctness (do these)

| # | Fix | Where | Effort | Impact | Why |
|---|---|---|---|---|---|
| **0.1** | Export bare `none`, not `"none"`, for raise caps | `config.html` `getRaiseCapStr` | **S** | **5** | Default turn/river caps are `none`. Download → `solve` can fail parse. Real footgun. |
| **0.2** | Block download/copy unless flop has 3 cards + both ranges non-empty | `config.html` export path | **S** | **4** | Today you can export `flop = "SELECT_3_CARDS"` / empty-ish ranges and only discover it at solve time. |
| **0.3** | Align “safe starter” defaults with `zolver example` | `config.html` defaults | **S** | **3** | GUI pot/stack/iters/threads ≠ example/README. New users get inconsistent first experiences. Prefer one starter profile (small tree that finishes fast). |

**Tier 0 total:** roughly an afternoon. Highest ROI of anything UI-related.

Suggested starter defaults (match the spirit of `example`, not the huge bench spots):
- pot `100`, stack `150–200`, flop sizings small (`[33,75]`), raise caps `1/1/0` or similar  
- threads: `0` or auto-ish (`4`/`8` is fine if documented)  
- iters `500–1000`, target `0.5`, prune on, dcfr defaults as-now  
- raise_cap export: `none` unquoted

---

## Tier 1 — High leverage usability (do if anyone uses the builder)

| # | Fix | Where | Effort | Impact | Why |
|---|---|---|---|---|---|
| **1.1** | **Paste range string** → grid (one box per OOP/IP) | `config.html` | **M** | **5** | Biggest real gap vs Equilab/Flopzilla users. Click-only ranges die for serious study. |
| **1.2** | After export, show copyable next command | `config.html` | **S** | **4** | Closes the loop: `zolver solve spot.toml -o results.json --summary` then `zolver view results.json`. |
| **1.3** | After solve with `-o`, print the view command | `main.zig` / CLI | **S** | **3** | Same loop, terminal side. One line of UX glue. |
| **1.4** | Viewer: **color legend** (check/bet/call/fold/raise/all-in) | `viewer.html` | **S** | **3** | README explains colors; UI doesn’t. First-time users guess. |
| **1.5** | Viewer: grey out / don’t pretend terminal actions navigate | `viewer.html` `navigateAction` | **S** | **3** | Fold/showdown buttons look clickable, silently do nothing. |

**Tier 1 total:** ~1–2 days if 1.1 is done carefully (reuse/port the same range grammar semantics the solver accepts; don’t invent a second dialect).

### Notes on 1.1 (scope it tightly)

**In scope:**
- Text input: `QQ+, AKs, A5s-A2s:0.5, …`
- Parse → set cells + weights
- Error toast on bad tokens
- Prefer matching solver range semantics (same `+` / dash rules as README)

**Out of scope for minimal:**
- Full TOML round-trip editor
- Multi-file range libraries
- Equity-ranked “Top 20%” truthfulness (see Tier 3)

---

## Tier 2 — Trust & study quality (optional, still small)

| # | Fix | Where | Effort | Impact | Why |
|---|---|---|---|---|---|
| **2.1** | Grid cell strategy = **average over combos in that cell**, not first match | `viewer.html` | **M** | **4** | Current “first combo wins” can miscolor suited/offsuit cells under blockers. This is a trust issue. |
| **2.2** | Detail panel: if cell selected, show **combo list** or “N combos · avg EV” with ability to pick a specific combo | `viewer.html` | **M** | **3** | Pairs with 2.1; otherwise average without drill-down is still fuzzy. |
| **2.3** | Load existing `spot.toml` into builder (board, ranges, sizings, solver knobs) | `config.html` | **M–L** | **4** | Huge for iteration; bigger than paste-range because full TOML parse in JS. Do only after 1.1. |
| **2.4** | Expose `compress_suits` + `max_budget_bytes` (advanced collapse) | `config.html` | **S** | **2** | Power-user completeness; defaults are fine for most. |
| **2.5** | Write temp HTML under `/tmp` (or OS temp), not cwd next to results | `main.zig` `runView`/`runConfig` | **S–M** | **2** | Less clutter; slightly more path/browser pain on some setups. |

**Tier 2 total:** another 2–4 days if you do 2.1–2.3. Stop after 2.1 unless people re-edit spots a lot.

---

## Tier 3 — Nice-to-have / probably skip

| # | Fix | Effort | Impact | Verdict |
|---|---|---|---|---|
| 3.1 | Honest “Top N%” presets (or rename to “Top NxN”) | M | 2 | **Rename, don’t implement real equity %** |
| 3.2 | `zolver solve … --view` auto-open viewer | S | 2 | Convenience only |
| 3.3 | Progress: iters/s + ETA | S–M | 2 | Nice for long solves |
| 3.4 | Viewer: open another JSON without reload | S | 2 | Minor |
| 3.5 | Node-level class summary inside viewer (like `--summary`) | M | 2 | Duplicates CLI; optional |
| 3.6 | EV heatmap toggle | M | 2 | Study candy |
| 3.7 | Keyboard: number keys → take action N | S | 1 | Power-user only |
| 3.8 | Theme / responsive mobile layout | L | 1 | Skip — desktop study tool |
| 3.9 | In-browser solve / WASM / live progress UI | L+ | — | **Do not** — wrong product shape |
| 3.10 | Full commercial tree browser (aggregates, filters, reports, compare spots) | L+ | — | **Do not** unless this becomes the product |

---

## Suggested execution plan (minimal)

### Pass A — “Don’t ship footguns” (half day)
1. **0.1** bare `none`  
2. **0.2** export validation  
3. **0.3** default alignment  
4. **1.2** + **1.3** next-command hints  
5. **1.4** + **1.5** viewer legend + dead actions  

This alone makes the UX feel intentional and safe.

### Pass B — “People can actually build spots” (1–2 days)
6. **1.1** paste range string  

Stop here unless feedback demands more.

### Pass C — only if study users hit trust issues
7. **2.1** (+ maybe **2.2**) combo-averaged grid  
8. **2.3** TOML import if re-edit is common  

---

## Explicit non-goals (write these down so you don’t thrash)

- No SPA rewrite, no React, no backend, no account system  
- No solving in the browser  
- No second results format  
- No matching Pio/GTO+ feature lists  
- CLI command surface stays as-is (`solve` / `view` / `config` / `example`)  
- File-based workflow stays the product spine  

---

## Effort × impact map (quick scan)

```text
Impact
  5 │  0.1 raise_cap bug     1.1 paste ranges
  4 │  0.2 export validate   1.2 next cmd     2.1 avg combos   2.3 toml import
  3 │  0.3 defaults          1.3/1.4/1.5      2.2 combo drill
  2 │  2.4 advanced knobs    2.5 temp paths   3.x niceties
  1 │  polish / themes / hotkeys
    └──────────────────────────────────────────────► Effort
         S                    M                    L
```

**Sweet spot:** everything in the upper-left (S/M + impact ≥3).

---

## Definition of “done enough”

You’re done refining UX when:

1. A new user can: open config builder → build a legal spot → download → solve without parse errors  
2. They can paste a normal range string instead of painting 169 cells  
3. They always know the next CLI command  
4. The viewer doesn’t silently fail or unexplained-color-code  
5. You’re not tempted to rebuild the UI “properly”

After that, **leave it**. Further time belongs in solver correctness, memory, output-pass performance, validation — not HTML.

---

## One-line priority order (copy/paste backlog)

```text
0.1 bare none export
0.2 validate flop+ranges before export
0.3 align starter defaults
1.2 show solve command after export
1.3 print view command after -o solve
1.4 viewer color legend
1.5 disable terminal action buttons
1.1 paste range string → grid
2.1 average strategy across combos in cell
2.2 combo drill-down in detail panel
2.3 optional TOML import
(stop)
```

