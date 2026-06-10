const std = @import("std");
const card = @import("card.zig");
const cfr = @import("cfr.zig");
const init_mod = @import("init.zig");

const Solver = cfr.Solver;
const SolverInit = init_mod.SolverInit;

const sentinel = std.math.maxInt(u32);

/// Result of one exploitability measurement.
///
/// `chips` is the average per-deal exploitability (the standard "distance from
/// Nash" metric); `pct` expresses it as a percentage of `initial_pot`. Both
/// derive from the best-response values `br` and the average-strategy-profile
/// values `avg_ev`, all normalized by the compatible reach mass `z`.
pub const Exploitability = struct {
    chips: f32,
    pct: f32,
    br: [2]f32,
    avg_ev: [2]f32,
    z: f32,
};

/// Compute exploitability of the current average strategy.
///
/// For each player u: `BR_u` is the value of best-responding while the opponent
/// plays its average strategy, and `v_u` is u's value when *both* play the
/// average strategy. Because every terminal is constant-sum to `initial_pot`,
/// `(BR_u - v_u) >= 0`, and the average gap is the exploitability.
///
/// NOTE (deviation from CFR spec §10): the published formula uses the closed
/// form `(BR_0/Z + BR_1/Z - initial_pot)/2`, which assumes `v_0 + v_1 = Z ·
/// initial_pot`. That identity holds only when every dealt matchup reaches a
/// terminal with full weight. Pre-river all-in terminals enumerate the remaining
/// runouts with fixed denominators (1/49, 1/48) and reach-masking, so a matchup
/// only "arrives" at the runouts compatible with its private cards — its weight
/// is < 1, and `v_0 + v_1 < Z · initial_pot`. We therefore measure `v_u`
/// directly (an average-profile pass) instead of assuming it. This reduces to
/// the spec formula exactly when there are no pre-river all-ins.
pub fn exploitability(solver: *Solver) Exploitability {
    const z = compatibleMass(solver.init_state);
    const br0 = solver.bestResponseEV(0);
    const br1 = solver.bestResponseEV(1);
    const v0 = solver.averageEV(0);
    const v1 = solver.averageEV(1);

    const ip: f32 = @floatFromInt(solver.init_state.tree.initial_pot);
    const chips = if (z > 0) ((br0 - v0) + (br1 - v1)) / (2.0 * z) else 0.0;
    return .{
        .chips = chips,
        .pct = if (ip > 0) chips / ip * 100.0 else 0.0,
        .br = .{ br0, br1 },
        .avg_ev = .{ v0, v1 },
        .z = z,
    };
}

/// Total compatible reach mass `Z = sum_{h,h'} compat(h,h') w0[h] w1[h']`, using
/// flop-masked weights (matching the root reach seeding). O(N) via the
/// fold-kernel card-sum trick.
pub fn compatibleMass(is: *SolverInit) f32 {
    const w0 = is.ranges[0].weights;
    const w1 = is.ranges[1].weights;
    const h0 = is.ranges[0].hands;
    const h1 = is.ranges[1].hands;
    const m0 = is.mask_flop[0];
    const m1 = is.mask_flop[1];
    const same = is.same_combo_idx[0];

    var cardsum1 = [_]f32{0} ** 52;
    var total1: f32 = 0;
    for (h1, w1, m1) |hand, w, m| {
        const r = w * m;
        total1 += r;
        cardsum1[card.index(hand.first)] += r;
        cardsum1[card.index(hand.second)] += r;
    }

    var z: f32 = 0;
    for (h0, w0, m0, same) |hand, w, m, sc| {
        const c1 = card.index(hand.first);
        const c2 = card.index(hand.second);
        var compat = total1 - cardsum1[c1] - cardsum1[c2];
        if (sc != sentinel) compat += w1[sc] * m1[sc];
        z += (w * m) * compat;
    }
    return z;
}

/// Outcome of a convergence run.
pub const SolveResult = struct {
    iterations: u32,
    exploitability: Exploitability,
    converged: bool,
};

/// Run DCFR until exploitability reaches `target_exploitability_pct` or
/// `max_iterations` is hit, checking on a geometric-ish schedule (32, 64, 128,
/// then every `check_interval`). Logs `(t, pct, chips)` at each check.
pub fn solve(solver: *Solver) SolveResult {
    const cfg = solver.config;
    var last = exploitability(solver);
    while (solver.t < cfg.max_iterations) {
        solver.iterate(1);
        if (shouldCheck(solver.t, cfg.check_interval)) {
            last = exploitability(solver);
            std.log.debug("cfr t={d} exploitability={d:.4}% ({d:.5} chips)", .{ solver.t, last.pct, last.chips });
            if (last.pct <= cfg.target_exploitability_pct) {
                return .{ .iterations = solver.t, .exploitability = last, .converged = true };
            }
        }
    }
    last = exploitability(solver);
    return .{
        .iterations = solver.t,
        .exploitability = last,
        .converged = last.pct <= cfg.target_exploitability_pct,
    };
}

/// Exploitability re-check schedule: the early geometric points (32, 64, 128)
/// plus every `interval` thereafter. Shared with the CLI's live solve loop so
/// both report on exactly the same cadence.
pub fn shouldCheck(t: u32, interval: u32) bool {
    return t == 32 or t == 64 or t == 128 or (interval > 0 and t % interval == 0);
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;
const game_tree = @import("game_tree.zig");
const Combo = card.Combo;
const WeightedCombo = @import("range.zig").WeightedCombo;

fn wc(a: card.Card, b: card.Card) !WeightedCombo {
    return .{ .combo = try Combo.init(a, b), .weight = 1.0 };
}

const one_sizing = [_]game_tree.Sizing{game_tree.Sizing.init(50, 100)};
const test_sizings: [3][]const game_tree.Sizing = .{ &one_sizing, &one_sizing, &one_sizing };

fn buildInit(allocator: std.mem.Allocator, flop: [3]card.Card, oop: []const WeightedCombo, ip: []const WeightedCombo) !SolverInit {
    const config = init_mod.Config{
        .flop = flop,
        .initial_pot = 10,
        .effective_stack = 16,
        .min_bet = 2,
        .sizings = test_sizings,
        .raise_cap = .{ 0, 0, 0 },
        .oop_range = oop,
        .ip_range = ip,
        .max_budget_bytes = std.math.maxInt(u64),
    };
    return init_mod.SolverInit.init(allocator, config);
}

// A monotone (all-spade) flop with spade-only ranges: the ranges are fixed
// under the flop's suit-automorphism group, so the isomorphism module collapses
// the turn/river runout space heavily, keeping these iteration-heavy tests fast.
const mono_flop = [_]card.Card{ card.makeCard(12, 0), card.makeCard(11, 0), card.makeCard(10, 0) }; // A♠ K♠ Q♠

test "compatibleMass matches the naive O(N^2) double loop" {
    const alloc = testing.allocator;
    const oop = [_]WeightedCombo{ try wc(card.makeCard(9, 0), card.makeCard(8, 0)), try wc(card.makeCard(4, 0), card.makeCard(3, 0)) };
    const ip = [_]WeightedCombo{ try wc(card.makeCard(9, 0), card.makeCard(8, 0)), try wc(card.makeCard(6, 0), card.makeCard(5, 0)) };

    var is = try buildInit(alloc, mono_flop, &oop, &ip);
    defer is.deinit();

    // Naive reference.
    var z_naive: f32 = 0;
    for (is.ranges[0].hands, is.ranges[0].weights, is.mask_flop[0]) |a, wa, ma| {
        const am = card.mask(a.first) | card.mask(a.second);
        for (is.ranges[1].hands, is.ranges[1].weights, is.mask_flop[1]) |b, wb, mb| {
            const bm = card.mask(b.first) | card.mask(b.second);
            if ((am & bm) == 0) z_naive += (wa * ma) * (wb * mb);
        }
    }

    try testing.expect(@abs(compatibleMass(&is) - z_naive) < 1e-5);
}

test "exploitability is non-negative and decreases under DCFR" {
    const alloc = testing.allocator;
    // Different flush ranks on the monotone board ⇒ the uniform profile is
    // genuinely exploitable.
    const oop = [_]WeightedCombo{
        try wc(card.makeCard(9, 0), card.makeCard(8, 0)), // J-high-ish flush
        try wc(card.makeCard(3, 0), card.makeCard(1, 0)), // low flush
    };
    const ip = [_]WeightedCombo{
        try wc(card.makeCard(7, 0), card.makeCard(6, 0)),
        try wc(card.makeCard(4, 0), card.makeCard(2, 0)),
    };

    var is = try buildInit(alloc, mono_flop, &oop, &ip);
    defer is.deinit();

    var solver = try Solver.init(alloc, &is, .{});
    defer solver.deinit();

    const e_start = exploitability(&solver);
    solver.iterate(12);
    const e_mid = exploitability(&solver);
    solver.iterate(18);
    const e_end = exploitability(&solver);

    // Each per-player gap is non-negative ⇒ total exploitability ≥ 0.
    try testing.expect(e_start.chips >= -1e-3);
    try testing.expect(e_mid.chips >= -1e-3);
    try testing.expect(e_end.chips >= -1e-3);

    // DCFR must drive it down monotonically (with a little float slack).
    try testing.expect(e_mid.chips <= e_start.chips + 1e-4);
    try testing.expect(e_end.chips <= e_mid.chips + 1e-4);

    // Real convergence progress: the gap shrinks substantially from the start.
    try testing.expect(e_end.chips < 0.6 * e_start.chips);
}

test "solve stops at the exploitability target" {
    const alloc = testing.allocator;
    const oop = [_]WeightedCombo{ try wc(card.makeCard(9, 0), card.makeCard(8, 0)), try wc(card.makeCard(3, 0), card.makeCard(1, 0)) };
    const ip = [_]WeightedCombo{ try wc(card.makeCard(7, 0), card.makeCard(6, 0)), try wc(card.makeCard(4, 0), card.makeCard(2, 0)) };

    var is = try buildInit(alloc, mono_flop, &oop, &ip);
    defer is.deinit();

    var solver = try Solver.init(alloc, &is, .{ .target_exploitability_pct = 5.0, .max_iterations = 64, .check_interval = 16 });
    defer solver.deinit();

    const result = solve(&solver);
    try testing.expect(result.exploitability.pct <= 5.0);
    try testing.expect(result.iterations <= 64);
}

test "exploitability stays non-negative on a single-combo game" {
    const alloc = testing.allocator;
    const hands = [_]WeightedCombo{try wc(card.makeCard(9, 0), card.makeCard(8, 0))};

    var is = try buildInit(alloc, mono_flop, &hands, &hands);
    defer is.deinit();

    var solver = try Solver.init(alloc, &is, .{});
    defer solver.deinit();
    solver.iterate(10);

    const e = exploitability(&solver);
    try testing.expect(e.chips >= -1e-3);
}
