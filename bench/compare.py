#!/usr/bin/env python3
"""Strict flop strategy comparison with commitment-based action matching.

Structural coverage, acting player, legal actions and probabilities are always
validated. --metric selects the frequency statistic gated by --tol; frequencies
alone are not an equilibrium certificate because equilibria can be non-unique.
"""
import argparse
import json
import math
from pathlib import Path


def canon_combo(s):
    if len(s) != 4 or any(s[i] not in "23456789TJQKA" or s[i+1] not in "shdc" for i in (0, 2)) or s[:2] == s[2:]:
        raise ValueError(f"invalid combo: {s}")
    return "".join(sorted((s[:2], s[2:])))


def action_key(label, player, committed, stack, source):
    parts = label.upper().replace("_", "-").split()
    kind = parts[0]
    if kind in ("CHECK", "FOLD", "CALL", "ALL-IN", "ALLIN") and len(parts) != 1:
        raise ValueError(f"invalid action: {label}")
    if kind == "CHECK":
        if committed[0] != committed[1]:
            raise ValueError("check facing a bet")
        return ("check", 0)
    if kind == "FOLD":
        if committed[player] >= max(committed):
            raise ValueError("fold without facing a bet")
        return ("fold", 0)
    if kind == "CALL":
        if committed[player] >= max(committed):
            raise ValueError("call without facing a bet")
        return ("call", max(committed))
    if kind in ("ALL-IN", "ALLIN"):
        amount = stack
    elif kind in ("BET", "RAISE") and len(parts) == 2:
        amount = float(parts[1])
        if source == "zolver":
            amount += max(committed) if kind == "RAISE" else committed[player]
    else:
        raise ValueError(f"unknown action: {label}")
    if not math.isfinite(amount) or not max(committed) < amount <= stack:
        raise ValueError(f"invalid commitment for {label}: {amount}, state={committed}")
    return ("bet_to", amount)


def advance(committed, player, action):
    out = list(committed)
    if action[0] in ("bet_to", "call"):
        out[player] = action[1]
    return tuple(out)


def probabilities(combos, keys):
    if len(set(keys)) != len(keys):
        raise ValueError("duplicate semantic actions")
    result = {}
    for hand, probs in combos:
        key = canon_combo(hand)
        if key in result:
            raise ValueError(f"duplicate hand {key}")
        if len(probs) != len(keys) or any(not math.isfinite(p) or p < 0 or p > 1 for p in probs):
            raise ValueError(f"invalid probabilities for {hand}")
        if abs(sum(probs) - 1) > 0.001:
            raise ValueError(f"probabilities do not sum to one: {hand}")
        result[key] = dict(zip(keys, probs))
    return result


def load_zolver(path):
    d = json.loads(Path(path).read_text())
    meta = d["meta"]
    stack = meta["effective_stack"]
    nodes = next(s["nodes"] for s in d["streets"] if s["street"] == "flop")
    by_line = {tuple(n["line"]): n for n in nodes}
    if len(by_line) != len(nodes):
        raise ValueError("duplicate Zolver node paths")
    out = {}
    for node in nodes:
        committed, path_key = (0, 0), ()
        for i, label in enumerate(node["line"]):
            parent = by_line[tuple(node["line"][:i])]
            player = {"oop": 0, "ip": 1}[parent["player"]]
            if label not in parent["actions"]:
                raise ValueError("path action absent from parent")
            key = action_key(label, player, committed, stack, "zolver")
            path_key += (key,)
            committed = advance(committed, player, key)
        player = {"oop": 0, "ip": 1}[node["player"]]
        keys = [action_key(a, player, committed, stack, "zolver") for a in node["actions"]]
        out[path_key] = {"player": player, "keys": set(keys), "strat": probabilities(((h["combo"], h["strategy"]) for h in node["hands"]), keys)}
    return meta, out


def load_texas(path, stack):
    root = json.loads(Path(path).read_text())
    # TexasSolver's numeric seats differ from Zolver's. A flop-root tree starts
    # with OOP; normalize seats once, then verify every descendant's actor.
    oop = root["player"]
    out = {}

    def walk(node, path_key, committed):
        if node.get("node_type") != "action_node":
            return
        if node["player"] not in (0, 1):
            raise ValueError("invalid TexasSolver player")
        player = 0 if node["player"] == oop else 1
        block = node["strategy"]
        labels = block["actions"]
        keys = [action_key(a, player, committed, stack, "texas") for a in labels]
        if path_key in out:
            raise ValueError("duplicate TexasSolver node paths")
        out[path_key] = {"player": player, "keys": set(keys), "strat": probabilities(block["strategy"].items(), keys)}
        for label, child in node.get("childrens", {}).items():
            key = action_key(label, player, committed, stack, "texas")
            if key not in keys:
                raise ValueError("child absent from action list")
            walk(child, path_key + (key,), advance(committed, player, key))

    walk(root, (), (0, 0))
    return out


def compare(znodes, tnodes, tol, metric="mean"):
    errors, diffs = [], []
    if not znodes or set(znodes) != set(tnodes):
        errors.append(f"node coverage mismatch: {len(set(znodes)-set(tnodes))} Zolver-only, {len(set(tnodes)-set(znodes))} Texas-only")
    for path in set(znodes) & set(tnodes):
        z, t = znodes[path], tnodes[path]
        if z["player"] != t["player"]:
            errors.append(f"acting player mismatch at {path}")
        if z["keys"] != t["keys"]:
            errors.append(f"action/commitment mismatch at {path}")
        if set(z["strat"]) != set(t["strat"]):
            errors.append(f"hand coverage mismatch at {path}")
        for h in set(z["strat"]) & set(t["strat"]):
            for a in z["keys"] & t["keys"]:
                diffs.append(abs(z["strat"][h][a] - t["strat"][h][a]))
    diffs.sort()
    stats = {"mean": sum(diffs)/len(diffs), "max": max(diffs), "p95": diffs[min(len(diffs)-1, int(.95*len(diffs)))]} if diffs else {"mean": None, "max": None, "p95": None}
    if not diffs:
        errors.append("no comparable probabilities")
    elif stats[metric] > tol:
        errors.append(f"{metric} frequency difference {stats[metric]:.6g} exceeds {tol}")
    return {"passed": not errors, "errors": errors, "zolver_flop_nodes": len(znodes), "texassolver_flop_nodes": len(tnodes), "matched_flop_nodes": len(set(znodes)&set(tnodes)), "compared_combo_action_pairs": len(diffs), "metric": metric, "tolerance": tol, "frequency_differences": stats}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zolver")
    parser.add_argument("texas")
    parser.add_argument("--tol", type=float, default=.05)
    parser.add_argument("--metric", choices=("mean", "max", "p95"), default="mean")
    parser.add_argument("--summary-json")
    args = parser.parse_args()
    if not math.isfinite(args.tol) or args.tol < 0:
        parser.error("--tol must be finite and nonnegative")
    meta, z = load_zolver(args.zolver)
    t = load_texas(args.texas, meta["effective_stack"])
    result = compare(z, t, args.tol, args.metric)
    print(json.dumps(result, indent=2))
    if args.summary_json:
        p = Path(args.summary_json)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(result, indent=2)+"\n")
    if not result["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
