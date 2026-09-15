#!/usr/bin/env python3
"""Fresh-process algorithm and one-size-at-a-time betting-tree sensitivity study.

Uses the supplied game and target. Never equates a small gap in one betting
abstraction with a bound for omitted actions. --verify includes the independent
physical f64 audit in measured time (can be expensive on broad flop trees).
"""
import argparse
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import time


def setting(text, section, key, value):
    """Replace one assignment, preserving this project's TOML-like dialect."""
    header = re.compile(r'^\s*\[([^\]]+)\]\s*(?:#.*)?$', re.M)
    headers = list(header.finditer(text))
    for i, match in enumerate(headers):
        if match[1] != section:
            continue
        end = headers[i+1].start() if i+1 < len(headers) else len(text)
        body = text[match.end():end]
        assignment = re.compile(r'^\s*' + re.escape(key) + r'\s*=.*$', re.M)
        line = f'{key} = {value}'
        if assignment.search(body):
            body = assignment.sub(lambda _: '\n' + line, body)
        else:
            body = body.rstrip() + '\n' + line + '\n\n'
        return text[:match.end()] + body + text[end:]
    return text.rstrip() + f'\n\n[{section}]\n{key} = {value}\n'


def root_policy(data):
    street = next(s for s in data['streets'] if s['street'] == data['meta']['root_street'])
    node = next(n for n in street['nodes'] if not n['line'])
    return {h['combo']: dict(zip(node['actions'], h['strategy'])) for h in node['hands']}


def policy_distance(a, b):
    if a.keys() != b.keys():
        raise ValueError('root hand coverage changed between variants')
    # Per-hand total variation, equally weighted; not a reach-weighted aggregate.
    return statistics.mean(sum(abs(a[h].get(k, 0)-b[h].get(k, 0)) for k in a[h].keys() | b[h].keys()) / 2 for h in a)


def variants(text, algorithms, additions):
    yield 'baseline', text
    for algo in algorithms:
        v = setting(text, 'solver', 'algorithm', json.dumps(algo))
        if algo == 'dcfr_plus':
            v = setting(v, 'solver.dcfr', 'alpha', '1.5')
            v = setting(v, 'solver.dcfr', 'gamma', '4')
        if algo == 'pdcfr_plus':
            v = setting(v, 'solver.pdcfr', 'alpha', '2.3')
            v = setting(v, 'solver.pdcfr', 'gamma', '5')
        yield algo, v
    for addition in additions:
        street, sep, pct = addition.partition(':')
        if not sep or street not in ('flop', 'turn', 'river') or not pct.isdigit() or int(pct) == 0:
            raise ValueError('--add-size must be STREET:POSITIVE_INTEGER_PERCENT')
        section = re.search(r'(?ms)^\[game\.sizings\]\s*\n(.*?)(?=^\[|\Z)', text)
        match = re.search(r'^\s*'+street+r'\s*=\s*(\[[^\]]*\])', section[1], re.M) if section else None
        if not match:
            raise ValueError(f'cannot locate game.sizings.{street}')
        sizes = json.loads(match[1])
        sizes = sorted(set(sizes + [int(pct)]))
        yield f'add_{street}_{pct}', setting(text, 'game.sizings', street, json.dumps(sizes))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('config', type=Path)
    p.add_argument('--bin', type=Path, default=Path('zig-out/bin/zolver'))
    p.add_argument('--out', type=Path, default=Path('bench/out/study'))
    p.add_argument('--algorithm', action='append', choices=['dcfr','cfr_plus','dcfr_plus','pdcfr_plus'], default=[])
    p.add_argument('--add-size', action='append', default=[])
    p.add_argument('--runs', type=int, default=3)
    p.add_argument('--warmup', type=int, default=1)
    p.add_argument('--max-iterations', type=int)
    p.add_argument('--target', type=float)
    p.add_argument('--verify', action='store_true')
    args = p.parse_args()
    if args.runs < 1 or args.warmup < 0:
        p.error('runs must be positive and warmup nonnegative')
    if args.target is not None and (not math.isfinite(args.target) or args.target < 0):
        p.error('target must be finite and nonnegative')
    args.out.mkdir(parents=True, exist_ok=True)
    text = setting(args.config.read_text(), 'solver', 'stall_patience', '0')
    if args.max_iterations is not None:
        text = setting(text, 'solver', 'max_iterations', str(args.max_iterations))
    if args.target is not None:
        text = setting(text, 'solver', 'target_exploitability_pct', str(args.target))
    records = []
    reference = None
    for name, config in variants(text, args.algorithm, args.add_size):
        folder = args.out / name
        folder.mkdir(exist_ok=True)
        path = folder / 'config.toml'
        path.write_text(config)
        samples = []
        for i in range(args.warmup + args.runs):
            dest = folder / f'{i}.json'
            dest.unlink(missing_ok=True)  # a failed CLI must not reuse an old result
            cmd = [str(args.bin.resolve()), 'solve', str(path), '--output', str(dest)]
            if args.verify:
                cmd.append('--verify')
            started = time.perf_counter()
            result = subprocess.run(cmd, capture_output=True, text=True)
            wall = time.perf_counter() - started
            (folder / f'{i}.log').write_text(result.stdout + '\n' + result.stderr)
            if result.returncode or not dest.exists():
                raise RuntimeError(f'{name} failed; see {folder / f"{i}.log"}')
            data = json.loads(dest.read_text())
            meta = data['meta']
            if not all(math.isfinite(meta[k]) for k in ('exploitability_pct','ev_oop','ev_ip')):
                raise ValueError('nonfinite solver output')
            if i >= args.warmup:
                samples.append({'wall_s': wall, **meta})
        median = sorted(samples, key=lambda s:s['wall_s'])[len(samples)//2]
        policy = root_policy(data)
        if reference is None:
            reference = (median, policy)
        record = {'variant': name, 'median': median, 'samples': samples,
                  'oop_ev_change_chips': median['ev_oop']-reference[0]['ev_oop'],
                  'mean_hand_root_total_variation': policy_distance(reference[1], policy),
                  'time_to_target_s': median['wall_s'] if all(s['converged'] for s in samples) else None}
        records.append(record)
        (args.out / 'summary.json').write_text(json.dumps(records, indent=2)+'\n')
        print(f"{name}: {median['wall_s']:.3f}s, {median['iterations']} iterations, gap {median['exploitability_pct']:.6f}%, converged={median['converged']}, OOP EV change {record['oop_ev_change_chips']:+.4f}", flush=True)
    print('Size additions are separate wider-tree solves. EV/policy changes rank sensitivity; they do not certify off-tree exploitability.')


if __name__ == '__main__':
    main()
