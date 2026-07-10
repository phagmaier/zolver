#!/usr/bin/env python3
"""Cross-validate Zolver vs TexasSolver flop strategies.

Both tools solve the full flop->river tree from the same flop. This script
aligns their *flop* action nodes and compares per-combo action frequencies.

Alignment is by semantics, not position, because the two tools disagree on
surface details:
  - TexasSolver orders facing-a-bet actions CALL,FOLD; Zolver orders fold,call.
  - "all-in" is a named action in Zolver but a "BET <stack>" in TexasSolver.
  - Card order within a combo differs (7s7h vs 7h7s).

So we canonicalize: check/fold/call match by name; bet/raise actions at a node
are ranked by ascending chip amount (bet#0, bet#1=all-in, ...) and matched by
rank. Combos are keyed by their sorted card pair. Nodes are matched by the
canonical action path from the flop root.

Usage: compare.py <zolver.json> <texas.json> [--tol 0.05]
"""
import json
import os
import sys

RANK_ORDER = "23456789TJQKA"


def card_key(c):
    return (RANK_ORDER.index(c[0]), c[1])


def canon_combo(s):
    """'7s7h' or '7h7s' -> canonical 'AhKd'-style string, cards sorted."""
    a, b = s[0:2], s[2:4]
    lo, hi = sorted([a, b], key=card_key)
    return lo + hi


def parse_action(label):
    """Return ('check'|'fold'|'call'|'bet', amount_or_None). amount only for bets."""
    t = label.strip().upper()
    if t.startswith("CHECK"):
        return ("check", None)
    if t.startswith("FOLD"):
        return ("fold", None)
    if t.startswith("CALL"):
        return ("call", None)
    if t.startswith("ALLIN") or t.startswith("ALL-IN") or t.startswith("ALL_IN"):
        return ("bet", float("inf"))  # ranked last among bets
    # "BET 15.0", "RAISE 60", "bet 15"
    parts = t.replace("-", " ").split()
    amt = None
    for p in parts:
        try:
            amt = float(p)
            break
        except ValueError:
            continue
    return ("bet", amt if amt is not None else float("inf"))


def node_action_keys(labels):
    """Map a node's ordered action labels -> canonical keys, matching probability
    vector positions. Bets are ranked by ascending amount: ('bet',0),('bet',1)..."""
    parsed = [parse_action(l) for l in labels]
    bet_idx = sorted(
        (i for i, (k, _) in enumerate(parsed) if k == "bet"),
        key=lambda i: parsed[i][1],
    )
    rank = {i: r for r, i in enumerate(bet_idx)}
    out = []
    for i, (k, _) in enumerate(parsed):
        out.append((k, None) if k != "bet" else ("bet", rank[i]))
    return out


def canon_step(label, siblings):
    """Canonicalize a single action step into a path key, ranking bets by their
    position among the *sibling* action set at that node (bet#0, bet#1=all-in,
    ...). This is the same rank scheme `node_action_keys` uses to align
    probability vectors, so it makes the two solvers' all-in encodings agree:
    Zolver's `all-in` and TexasSolver's `BET <stack>` are both the highest-ranked
    bet at their node and collapse to the same ('bet', rank) key.

    `siblings` is the full ordered action-label list at the node the step departs
    from. When it is unavailable we fall back to a name/amount token (which will
    only misalign an all-in, the case this function exists to fix)."""
    if not siblings:
        k, amt = parse_action(label)
        return (k, None) if k != "bet" else ("bet", amt)
    keys = node_action_keys(siblings)
    idx = None
    if label in siblings:
        idx = siblings.index(label)
    else:
        pk = parse_action(label)
        for j, s in enumerate(siblings):
            if parse_action(s) == pk:
                idx = j
                break
    if idx is None:
        k, amt = parse_action(label)
        return (k, None) if k != "bet" else ("bet", amt)
    return keys[idx]


# ---------- Zolver ----------
def load_zolver(path):
    d = json.load(open(path))
    flop = next(s for s in d["streets"] if s["street"] == "flop")
    raw_nodes = flop["nodes"]
    # line-prefix -> action set at that node, so each line step can be ranked
    # against the siblings that were actually available there.
    line_actions = {tuple(n["line"]): n["actions"] for n in raw_nodes}
    nodes = {}
    for n in raw_nodes:
        keys = node_action_keys(n["actions"])
        line = n["line"]
        path = tuple(
            canon_step(step, line_actions.get(tuple(line[:i])))
            for i, step in enumerate(line)
        )
        strat = {}
        for h in n["hands"]:
            strat[canon_combo(h["combo"])] = {keys[i]: h["strategy"][i] for i in range(len(keys))}
        nodes[path] = {"player": n["player"], "strat": strat, "labels": n["actions"]}
    return d.get("meta", {}), nodes


# ---------- TexasSolver ----------
def load_texas(path):
    root = json.load(open(path))
    nodes = {}
    walk_texas(root, (), nodes)
    return nodes


def walk_texas(node, path, nodes):
    if not isinstance(node, dict):
        return
    nt = node.get("node_type")
    if nt == "action_node":
        sblock = node.get("strategy", {})
        labels = sblock.get("actions", node.get("actions", []))
        keys = node_action_keys(labels)
        per_hand = sblock.get("strategy", {})
        strat = {}
        for combo, probs in per_hand.items():
            strat[canon_combo(combo)] = {keys[i]: probs[i] for i in range(len(keys))}
        player = "oop" if node.get("player") == 0 else "ip"
        nodes[path] = {"player": player, "strat": strat, "labels": labels}
        for label, child in node.get("childrens", {}).items():
            # Rank the step against the node's full action set (not just the
            # explored children) so bet ranks match Zolver's sibling ranks.
            step = canon_step(label, labels)
            walk_texas(child, path + (step,), nodes)
    # chance_node / terminal: stop (we only compare the flop street)


# ---------- compare ----------
def compare(zmeta, znodes, tnodes, tol):
    zkeys, tkeys = set(znodes), set(tnodes)
    common = zkeys & tkeys
    print(f"Zolver flop nodes: {len(zkeys)}   TexasSolver flop nodes: {len(tkeys)}   matched: {len(common)}")
    only_z = zkeys - tkeys
    only_t = tkeys - zkeys
    if only_z:
        print(f"  WARNING: {len(only_z)} node-path(s) only in Zolver: {sorted(only_z)[:3]}")
    if only_t:
        print(f"  WARNING: {len(only_t)} node-path(s) only in TexasSolver: {sorted(only_t)[:3]}")

    all_diffs = []
    worst = []  # (diff, path, combo, action, zp, tp)
    for path in sorted(common, key=lambda p: (len(p), str(p))):
        zn, tn = znodes[path], tnodes[path]
        zc, tc = set(zn["strat"]), set(tn["strat"])
        shared = zc & tc
        node_diffs = []
        for combo in shared:
            zs, ts = zn["strat"][combo], tn["strat"][combo]
            for act in zs:
                if act in ts:
                    dd = abs(zs[act] - ts[act])
                    node_diffs.append(dd)
                    all_diffs.append(dd)
                    worst.append((dd, path, combo, act, zs[act], ts[act]))
        if node_diffs:
            mx = max(node_diffs)
            mean = sum(node_diffs) / len(node_diffs)
            flag = "  <-- OVER TOL" if mx > tol else ""
            print(f"  {pp(path):<34} combos={len(shared):>2}  mean={mean:6.3f}  max={mx:6.3f}{flag}")
        if zc != tc:
            print(f"      note: combo sets differ (z-only {len(zc-tc)}, t-only {len(tc-zc)})")

    summary = {
        "zolver_flop_nodes": len(zkeys),
        "texassolver_flop_nodes": len(tkeys),
        "matched_flop_nodes": len(common),
        "zolver_only_nodes": len(only_z),
        "texassolver_only_nodes": len(only_t),
        "tolerance": tol,
    }
    if all_diffs:
        all_diffs.sort()
        n = len(all_diffs)
        mean = sum(all_diffs) / n
        p95 = all_diffs[int(0.95 * n)]
        within = sum(1 for d in all_diffs if d <= tol) / n
        print("\n=== overall ===")
        print(f"  (combo,action) pairs compared: {n}")
        print(f"  mean abs diff:  {mean:.4f}")
        print(f"  p95 abs diff:   {p95:.4f}")
        print(f"  max abs diff:   {all_diffs[-1]:.4f}")
        print(f"  within tol {tol}: {within*100:.1f}%")
        summary.update({
            "compared_combo_action_pairs": n,
            "mean_abs_diff": mean,
            "p95_abs_diff": p95,
            "max_abs_diff": all_diffs[-1],
            "within_tolerance_fraction": within,
        })
        worst.sort(reverse=True)
        print("  worst 8 disagreements (diff | path | combo | action | zolver | texas):")
        for dd, path, combo, act, zp, tp in worst[:8]:
            print(f"    {dd:.3f}  {pp(path):<28} {combo}  {act}  z={zp:.3f} t={tp:.3f}")
    else:
        print("no comparable (combo,action) pairs found")
        summary["compared_combo_action_pairs"] = 0
    return summary


def pp(path):
    if not path:
        return "(root)"
    return " ".join(f"{k}{'' if a is None else a}" for k, a in path)


def main():
    tol = 0.05
    summary_path = None
    args = []
    i = 0
    while i < len(sys.argv) - 1:
        a = sys.argv[i + 1]
        if a.startswith("--tol="):
            tol = float(a.split("=", 1)[1])
        elif a == "--tol":
            i += 1
            if i >= len(sys.argv) - 1:
                raise SystemExit("--tol needs a value")
            tol = float(sys.argv[i + 1])
        elif a.startswith("--summary-json="):
            summary_path = a.split("=", 1)[1]
        elif a == "--summary-json":
            i += 1
            if i >= len(sys.argv) - 1:
                raise SystemExit("--summary-json needs a path")
            summary_path = sys.argv[i + 1]
        elif a.startswith("--"):
            raise SystemExit(f"unknown option: {a}")
        else:
            args.append(a)
        i += 1
    if len(args) != 2:
        raise SystemExit("usage: compare.py <zolver.json> <texas.json> [--tol 0.05] [--summary-json PATH]")
    zpath, tpath = args
    zmeta, znodes = load_zolver(zpath)
    tnodes = load_texas(tpath)
    if zmeta:
        s = zmeta.get("ev_oop", 0) + zmeta.get("ev_ip", 0)
        print(f"Zolver meta: expl={zmeta.get('exploitability_pct')}%  "
              f"ev_oop+ev_ip={s:.2f} (pot {zmeta.get('initial_pot')})  "
              f"iters={zmeta.get('iterations')}\n")
    summary = compare(zmeta, znodes, tnodes, tol)
    if summary_path:
        os.makedirs(os.path.dirname(os.path.abspath(summary_path)), exist_ok=True)
        with open(summary_path, "w") as f:
            json.dump(summary, f, indent=2)
            f.write("\n")
    if summary["matched_flop_nodes"] == 0 or summary["compared_combo_action_pairs"] == 0:
        raise SystemExit("validation produced no comparable flop strategies")


if __name__ == "__main__":
    main()
