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
  run_bench.py [--bin PATH] [--warmup N] [--runs N] [spot.toml ...]
Default bin: ./zig-out/bin/zolver ; default runs: 3 (reports the median after
one warm-up). Every benchmark spot must use the complete physical runout space:
49 turns and 2,352 ordered turn-river runouts.
"""
import glob
import json
import os
import platform
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


def run_one(binpath, spot, warmup, runs):
    """Warm the process, then return the median elapsed sample and raw records."""
    samples = []
    for sample_idx in range(warmup + runs):
        t0 = time.time()
        p = subprocess.run([binpath, "solve", spot], capture_output=True, text=True)
        wall = time.time() - t0
        if p.returncode != 0:
            raise RuntimeError(
                f"{spot}: solver exited {p.returncode}\nstdout:\n{p.stdout}\nstderr:\n{p.stderr}"
            )
        out = parse_stdout(p.stdout)
        # The CLI emits setup metadata on stdout and progress on stderr. Parse
        # both so the harness remains aligned with the user-facing summary.
        err = parse_stderr(f"{p.stdout}\n{p.stderr}")
        out.update(err)
        out["wall_s"] = f"{wall:.2f}"
        missing = {"actions", "terminals", "memory_mb", "threads", "turns", "rivers"} - set(out)
        if missing:
            raise RuntimeError(f"{spot}: could not parse {', '.join(sorted(missing))}")
        if (out["turns"], out["rivers"]) != ("49", "2352"):
            raise RuntimeError(
                f"{spot}: expected physical runouts (49 turns, 2352 rivers), got "
                f"{out['turns']} turns, {out['rivers']} rivers"
            )
        if sample_idx >= warmup:
            samples.append({"metrics": out, "stdout": p.stdout, "stderr": p.stderr})

    ordered = sorted(samples, key=lambda s: float(s["metrics"]["elapsed_s"]))
    median = ordered[len(ordered) // 2]
    return median, samples


def fmt_row(name, d):
    iters = d.get("iterations", "?")
    try:
        ms_iter = float(d.get("elapsed_s", 0)) * 1000 / max(1, int(iters))
    except Exception:
        ms_iter = 0
    return (
        f"| {name} | {d.get('actions','?')}A {d.get('terminals','?')}T "
        f"| {d.get('memory_mb','?')} MB total | {d.get('threads','?')} "
        f"| {iters} | {d.get('exploitability_pct','?')}% "
        f"| {ms_iter:.0f} | {d.get('elapsed_s','?')}s "
        f"| {d.get('converged','?')} |"
    )


def command_output(argv):
    return subprocess.run(argv, capture_output=True, text=True, check=True).stdout.strip()


def cpu_model():
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    return line.partition(":")[2].strip()
    except OSError:
        pass
    return platform.processor() or "unknown"


def main():
    args = sys.argv[1:]
    binpath = DEFAULT_BIN
    runs = 3
    warmup = 1
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
        elif a == "--warmup":
            warmup = int(args[i + 1])
            i += 2
        else:
            spots.append(a)
            i += 1
    if not spots:
        spots = sorted(glob.glob(os.path.join(ROOT, "bench", "spots", "*.toml")))

    os.makedirs(OUT_DIR, exist_ok=True)
    if runs < 1 or warmup < 0:
        raise SystemExit("--runs must be at least 1 and --warmup must be non-negative")
    if not os.path.isfile(binpath) or not os.access(binpath, os.X_OK):
        raise SystemExit(f"solver binary is not executable: {binpath}")

    rows = []
    records = {
        "git_revision": command_output(["git", "-C", ROOT, "rev-parse", "HEAD"]),
        "zig_version": command_output(["zig", "version"]),
        "platform": platform.platform(),
        "cpu": cpu_model(),
        "python": platform.python_version(),
        "binary": os.path.abspath(binpath),
        "warmup_runs": warmup,
        "measured_runs": runs,
        "spots": {},
    }
    header = (
        "| Spot | Tree | Memory | Thr | Iters | Exploit | ms/iter | Solve | Converged |\n"
        "|------|------|--------|-----|-------|---------|---------|-------|-----------|"
    )
    print(header)
    for spot in spots:
        name = os.path.splitext(os.path.basename(spot))[0]
        median, samples = run_one(binpath, spot, warmup, runs)
        d = median["metrics"]
        records["spots"][name] = samples
        with open(os.path.join(OUT_DIR, f"{name}.stdout"), "w") as f:
            f.write(median["stdout"])
        with open(os.path.join(OUT_DIR, f"{name}.stderr"), "w") as f:
            f.write(median["stderr"])
        row = fmt_row(name, d)
        rows.append(row)
        print(row)

    with open(os.path.join(OUT_DIR, "results.md"), "w") as f:
        f.write("# Zolver physical-runout benchmark results\n\n")
        f.write("All rows completed the full 49-turn / 2,352 ordered-runout traversal. "
                f"Each value is the median of {runs} measured runs after {warmup} warm-up run(s).\n\n")
        f.write(header + "\n")
        f.write("\n".join(rows) + "\n")
    with open(os.path.join(OUT_DIR, "results.json"), "w") as f:
        json.dump(records, f, indent=2)
        f.write("\n")
    print(f"\nwrote {os.path.join(OUT_DIR, 'results.md')}")


if __name__ == "__main__":
    main()
