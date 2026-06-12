#!/usr/bin/env bash
# Cross-validate Zolver against TexasSolver on the matched validation spots.
# For each Vn: solve with both tools (same flop, ranges, sizings, caps), then
# diff the flop strategies with compare.py.
#
# Usage: bench/run_validation.sh [v1 v2 v3 ...]   (default: all present)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZOLVER="$ROOT/zig-out/bin/zolver"
TS_DIR="$ROOT/TexasSolver-v0.2.0-Linux"
TS_BIN="$TS_DIR/console_solver"
OUT="$ROOT/bench/out"
mkdir -p "$OUT"

spots=("$@")
if [ ${#spots[@]} -eq 0 ]; then
  spots=()
  for f in "$ROOT"/bench/validation/zolver/v*.toml; do
    spots+=("$(basename "${f%.toml}")")
  done
fi

for v in "${spots[@]}"; do
  echo "=============================================================="
  echo "Validating $v"
  echo "=============================================================="
  ztoml="$ROOT/bench/validation/zolver/$v.toml"
  tstxt="$ROOT/bench/validation/texassolver/$v.txt"

  echo "-- Zolver --"
  "$ZOLVER" solve "$ztoml" -o "$OUT/${v}_zolver.json" 2>"$OUT/${v}_zolver.stderr"
  tail -2 "$OUT/${v}_zolver.stderr"

  echo "-- TexasSolver --"
  ( cd "$TS_DIR" && "$TS_BIN" --input_file "$tstxt" --resource_dir resources ) \
    >"$OUT/${v}_texas.log" 2>&1
  grep -E "Total exploitability|dump" "$OUT/${v}_texas.log" | tail -2

  echo "-- compare --"
  python3 "$ROOT/bench/compare.py" "$OUT/${v}_zolver.json" "$OUT/${v}_texas.json" --tol=0.05
  echo
done
