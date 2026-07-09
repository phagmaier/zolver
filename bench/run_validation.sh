#!/usr/bin/env bash
# Cross-validate Zolver against TexasSolver on the matched validation spots.
# For each Vn: solve with both tools (same flop, ranges, sizings, caps), then
# diff the flop strategies with compare.py.
#
# Usage: bench/run_validation.sh [v1 v2 v3 ...]   (default: all present)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZOLVER="$ROOT/zig-out/bin/zolver"
TS_DIR="${TEXASSOLVER_DIR:-$ROOT/TexasSolver-v0.2.0-Linux}"
TS_BIN="$TS_DIR/console_solver"
OUT="$ROOT/bench/out"
mkdir -p "$OUT"

if [ ! -x "$ZOLVER" ]; then
  echo "error: Zolver binary is not executable: $ZOLVER" >&2
  echo "build it with: zig build -Doptimize=ReleaseFast" >&2
  exit 2
fi
if [ ! -x "$TS_BIN" ]; then
  echo "error: TexasSolver console_solver is not executable: $TS_BIN" >&2
  echo "set TEXASSOLVER_DIR to the TexasSolver-v0.2.0-Linux directory" >&2
  exit 2
fi

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
  generated_input="$OUT/${v}_texas.input"
  if [ ! -f "$ztoml" ] || [ ! -f "$tstxt" ]; then
    echo "error: validation fixture '$v' is incomplete" >&2
    exit 2
  fi

  echo "-- Zolver --"
  "$ZOLVER" solve "$ztoml" -o "$OUT/${v}_zolver.json" 2>"$OUT/${v}_zolver.stderr"
  tail -2 "$OUT/${v}_zolver.stderr"

  echo "-- TexasSolver --"
  sed "s|^dump_result @OUTPUT@\$|dump_result $OUT/${v}_texas.json|" "$tstxt" >"$generated_input"
  if grep -q '^dump_result @OUTPUT@$' "$generated_input"; then
    echo "error: failed to materialize TexasSolver output path for $v" >&2
    exit 2
  fi
  ( cd "$TS_DIR" && "$TS_BIN" --input_file "$generated_input" --resource_dir resources ) \
    >"$OUT/${v}_texas.log" 2>&1
  grep -E "Total exploitability|dump" "$OUT/${v}_texas.log" | tail -2

  echo "-- compare --"
  python3 "$ROOT/bench/compare.py" "$OUT/${v}_zolver.json" "$OUT/${v}_texas.json" \
    --tol=0.05 --summary-json "$OUT/${v}_compare.json" | tee "$OUT/${v}_compare.log"
  echo
done
