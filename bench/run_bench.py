#!/usr/bin/env python3
"""End-to-end speed benchmark for Zolver.

Runs `zolver solve` on every config in bench/spots/ (or a subset passed on the
command line), parses the stdout summary and stderr progress, and emits a
markdown table to bench/out/results.md.

The solver already reports everything we need:
  - stdout: iterations, exploitability_pct/chips, ev_oop, ev_ip, elapsed_s, converged
  - stderr: tree size (actions/terminals), memory, thread count

We derive ms/iter from elapsed_s/iterations, and report elapsed_s as
time-to-target (when converged) or time-to-max-iter (when not).

Usage:
  run_bench.py [--bin PATH] [--runs N] [spot.toml ...]
Default bin: ./zig-out/bin/zolver ; default runs: 2 (keeps the faster).
"""
import glob
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BIN = os.path.join(ROOT, "zig-out", "bin", "zolver")
OUT_DIR = os.path.join(ROOT, "bench", "out")


def parse_stdout(s):
    d = {}
    for line in s.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            d[k.strip()] = v.strip()
    return d


def parse_stderr(s):
    d = {}
    m = re.search(r"tree:\s*([\d,]+)\s*actions,\s*([\d,]+)\s*terminals", s)
    if m:
        d["actions"] = m.group(1).replace(",", "")
        d["terminals"] = m.group(2).replace(",", "")
    m = re.search(r"memory:\s*([\d.]+)\s*MB", s)
    if m:
        d["memory_mb"] = m.group(1)
    m = re.search(r"threads:\s*(\d+)", s)
    if m:
        d["threads"] = m.group(1)
    m = re.search(r"runouts:\s*(\d+)\s*turns,\s*(\d+)\s*rivers", s)
    if m:
        d["turns"] = m.group(1)
        d["rivers"] = m.group(2)
    return d


def run_one(binpath, spot, runs):
    best = None
    meta = {}
    for _ in range(runs):
        t0 = time.time()
        p = subprocess.run([binpath, "solve", spot], capture_output=True, text=True)
        wall = time.time() - t0
        out = parse_stdout(p.stdout)
        err = parse_stderr(p.stderr)
        out.update(err)
        out["wall_s"] = f"{wall:.2f}"
        if best is None or wall < float(best.get("wall_s", 1e9)):
            best = out
            meta = {"stdout": p.stdout, "stderr": p.stderr}
    return best, meta


def fmt_row(name, d):
    iters = d.get("iterations", "?")
    try:
        ms_iter = float(d.get("elapsed_s", 0)) * 1000 / max(1, int(iters))
    except Exception:
        ms_iter = 0
    return (
        f"| {name} | {d.get('actions','?')}A {d.get('terminals','?')}T "
        f"| {d.get('memory_mb','?')} MB | {d.get('threads','?')} "
        f"| {iters} | {d.get('exploitability_pct','?')}% "
        f"| {ms_iter:.0f} | {d.get('elapsed_s','?')}s "
        f"| {d.get('converged','?')} |"
    )


def main():
    args = sys.argv[1:]
    binpath = DEFAULT_BIN
    runs = 2
    spots = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--bin":
            binpath = args[i + 1]
            i += 2
        elif a == "--runs":
            runs = int(args[i + 1])
            i += 2
        else:
            spots.append(a)
            i += 1
    if not spots:
        spots = sorted(glob.glob(os.path.join(ROOT, "bench", "spots", "*.toml")))

    os.makedirs(OUT_DIR, exist_ok=True)
    rows = []
    header = (
        "| Spot | Tree | Memory | Thr | Iters | Exploit | ms/iter | Solve | Converged |\n"
        "|------|------|--------|-----|-------|---------|---------|-------|-----------|"
    )
    print(header)
    for spot in spots:
        name = os.path.splitext(os.path.basename(spot))[0]
        d, meta = run_one(binpath, spot, runs)
        with open(os.path.join(OUT_DIR, f"{name}.stdout"), "w") as f:
            f.write(meta["stdout"])
        with open(os.path.join(OUT_DIR, f"{name}.stderr"), "w") as f:
            f.write(meta["stderr"])
        row = fmt_row(name, d)
        rows.append(row)
        print(row)

    with open(os.path.join(OUT_DIR, "results.md"), "w") as f:
        f.write("# Zolver benchmark results\n\n")
        f.write(header + "\n")
        f.write("\n".join(rows) + "\n")
    print(f"\nwrote {os.path.join(OUT_DIR, 'results.md')}")


if __name__ == "__main__":
    main()
