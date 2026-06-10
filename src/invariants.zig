//! Phase 10 — debug invariant sweeps (spec §9, §13).
//!
//! Reusable correctness tripwires, intended for debug builds and tests rather
//! than production solves:
//!
//!  * no NaN/Inf in the regret arrays (the solve loop calls the cheap scan
//!    after every pass when `SolverConfig.debug_invariants` is set);
//!  * every terminal kernel satisfies the constant-sum identity on arbitrary
//!    reaches — `Σ reach_u·v_u + Σ reach_opp·v_opp == initial_pot · compat_mass`,
//!    a direct consequence of each matchup paying out exactly `initial_pot`;
//!  * best-response exploitability is never significantly negative (a negative
//!    value beyond float noise means a value-convention bug).
//!
//! None of these alter a solve; they only assert facts that must already hold.

const std = @import("std");
const card = @import("card.zig");
const game_tree = @import("game_tree.zig");
const init_mod = @import("init.zig");
const cfr = @import("cfr.zig");
const terminal_eval = @import("terminal_eval.zig");
const best_response = @import("best_response.zig");

const Combo = card.Combo;
const SolverInit = init_mod.SolverInit;
const Solver = cfr.Solver;
const TerminalNode = game_tree.TerminalNode;

// ── NaN/Inf ────────────────────────────────────────────────────────────────

pub fn allFinite(xs: []const f32) bool {
    for (xs) |x| if (!std.math.isFinite(x)) return false;
    return true;
}

pub fn assertFinite(xs: []const f32) void {
    for (xs) |x| std.debug.assert(std.math.isFinite(x));
}

/// All regret arrays are free of NaN/Inf.
pub fn assertSolverRegretsFinite(is: *const SolverInit) void {
    assertFinite(is.storage.regrets_flop);
    assertFinite(is.storage.regrets_turn);
    assertFinite(is.storage.regrets_river);
}

// ── Constant-sum identity ────────────────────────────────────────────────────

/// Naive O(N²) compatible reach mass: Σ reach0[h]·reach1[h'] over hand pairs
/// that share no card. Reference implementation for the constant-sum identity.
pub fn naiveCompatMass(
    reach0: []const f32,
    reach1: []const f32,
    hands0: []const Combo,
    hands1: []const Combo,
) f32 {
    var mass: f32 = 0;
    for (hands0, reach0) |a, ra| {
        const am = a.cardMask();
        for (hands1, reach1) |b, rb| {
            if ((am & b.cardMask()) == 0) mass += ra * rb;
        }
    }
    return mass;
}

/// Residual of the constant-sum identity given both players' value vectors:
/// `|(Σ reach0·v0 + Σ reach1·v1) − initial_pot · compat_mass|`. Should be ~0
/// (float noise) for any correct terminal kernel.
pub fn constantSumResidual(
    initial_pot: u32,
    reach0: []const f32,
    reach1: []const f32,
    v0: []const f32,
    v1: []const f32,
    compat_mass: f32,
) f32 {
    var lhs: f32 = 0;
    for (reach0, v0) |r, v| lhs += r * v;
    for (reach1, v1) |r, v| lhs += r * v;
    const ip: f32 = @floatFromInt(initial_pot);
    return @abs(lhs - ip * compat_mass);
}

/// Exploitability of the current average strategy must be ≥ −tol. A value more
/// negative than float noise indicates a value-convention bug (the game is
/// constant-sum, so the best response can never beat the average by a negative
/// margin).
pub fn assertExploitabilityNonNegative(solver: *Solver, tol: f32) void {
    const e = best_response.exploitability(solver);
    std.debug.assert(e.chips >= -tol);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const WeightedCombo = @import("range.zig").WeightedCombo;

fn wc(a: card.Card, b: card.Card) !WeightedCombo {
    return .{ .combo = try Combo.init(a, b), .weight = 1.0 };
}

const one_sizing = [_]game_tree.Sizing{game_tree.Sizing.init(50, 100)};
const test_sizings: [3][]const game_tree.Sizing = .{ &one_sizing, &one_sizing, &one_sizing };
const mono_flop = [_]card.Card{ card.makeCard(12, 0), card.makeCard(11, 0), card.makeCard(10, 0) };

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

fn fillRandom(rng: std.Random, xs: []f32) void {
    for (xs) |*x| x.* = rng.float(f32);
}

test "allFinite / assertFinite" {
    try testing.expect(allFinite(&[_]f32{ 0, 1, -2.5, 100 }));
    try testing.expect(!allFinite(&[_]f32{ 0, std.math.nan(f32) }));
    try testing.expect(!allFinite(&[_]f32{ 0, std.math.inf(f32) }));
    assertFinite(&[_]f32{ 1, 2, 3 });
}

test "fold kernel satisfies the constant-sum identity on random reaches" {
    const alloc = testing.allocator;
    const oop = [_]WeightedCombo{
        try wc(card.makeCard(9, 0), card.makeCard(8, 0)),
        try wc(card.makeCard(7, 0), card.makeCard(6, 0)),
        try wc(card.makeCard(5, 0), card.makeCard(4, 0)),
    };
    const ip = [_]WeightedCombo{
        try wc(card.makeCard(9, 0), card.makeCard(8, 0)),
        try wc(card.makeCard(3, 0), card.makeCard(2, 0)),
        try wc(card.makeCard(7, 0), card.makeCard(6, 0)),
    };
    var is = try buildInit(alloc, mono_flop, &oop, &ip);
    defer is.deinit();

    const n0 = is.ranges[0].N();
    const n1 = is.ranges[1].N();
    const r0 = try alloc.alloc(f32, n0);
    defer alloc.free(r0);
    const r1 = try alloc.alloc(f32, n1);
    defer alloc.free(r1);
    const v0 = try alloc.alloc(f32, n0);
    defer alloc.free(v0);
    const v1 = try alloc.alloc(f32, n1);
    defer alloc.free(v1);
    var cardsum = [_]f32{0} ** 52;

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();

    // who_folded = 0 then 1; folder_committed varies. The identity must hold
    // for any signed split that sums to initial_pot.
    for (0..16) |trial| {
        fillRandom(rng, r0);
        fillRandom(rng, r1);
        const term = TerminalNode{
            .kind = .fold,
            .who_folded = @intCast(trial % 2),
            .pot = 10 + @as(u32, @intCast(trial)) * 2,
            .folder_committed = @intCast(trial % 5),
        };

        // v0: player 0 is u, opponent reach = r1.
        @memset(&cardsum, 0);
        terminal_eval.foldEval(v0, r1, is.card_idx[0], is.card_idx[1], is.same_combo_idx[0], cfr.foldUtility(is.tree.initial_pot, term, 0), &cardsum);
        // v1: player 1 is u, opponent reach = r0.
        @memset(&cardsum, 0);
        terminal_eval.foldEval(v1, r0, is.card_idx[1], is.card_idx[0], is.same_combo_idx[1], cfr.foldUtility(is.tree.initial_pot, term, 1), &cardsum);

        const mass = naiveCompatMass(r0, r1, is.ranges[0].hands, is.ranges[1].hands);
        try testing.expect(constantSumResidual(is.tree.initial_pot, r0, r1, v0, v1, mass) < 1e-2);
    }
}

test "showdown kernel satisfies the constant-sum identity on random reaches" {
    const alloc = testing.allocator;
    const oop = [_]WeightedCombo{
        try wc(card.makeCard(9, 0), card.makeCard(8, 0)),
        try wc(card.makeCard(7, 0), card.makeCard(6, 0)),
        try wc(card.makeCard(5, 0), card.makeCard(4, 0)),
    };
    const ip = [_]WeightedCombo{
        try wc(card.makeCard(9, 0), card.makeCard(8, 0)),
        try wc(card.makeCard(3, 0), card.makeCard(2, 0)),
        try wc(card.makeCard(6, 0), card.makeCard(5, 0)),
    };
    var is = try buildInit(alloc, mono_flop, &oop, &ip);
    defer is.deinit();

    const n0 = is.ranges[0].N();
    const n1 = is.ranges[1].N();
    const r0 = try alloc.alloc(f32, n0);
    defer alloc.free(r0);
    const r1 = try alloc.alloc(f32, n1);
    defer alloc.free(r1);
    const v0 = try alloc.alloc(f32, n0);
    defer alloc.free(v0);
    const v1 = try alloc.alloc(f32, n1);
    defer alloc.free(v1);
    var lo = [_]f32{0} ** 52;
    var eq = [_]f32{0} ** 52;
    var cs = [_]f32{0} ** 52;
    const sr = try alloc.alloc(f32, @max(n0, n1));
    defer alloc.free(sr);
    const comp = try alloc.alloc(f32, @max(n0, n1));
    defer alloc.free(comp);

    // Section-2 coefficients for an arbitrary pot; the identity is pot-independent.
    const ip_u = is.tree.initial_pot;
    const pot: u32 = 30;
    const ip_f: f32 = @floatFromInt(ip_u);
    const c_chip: f32 = (@as(f32, @floatFromInt(pot)) - ip_f) / 2.0;
    const win = ip_f + c_chip;
    const loss = c_chip;
    const tie = ip_f / 2.0;

    const sd = &is.showdown;
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rng = prng.random();

    // Test against the first canonical river runout; mask board-blocked hands to
    // zero reach so only live matchups participate.
    const runout: u32 = 0;
    const mr0 = is.mask_river[0][runout * n0 ..][0..n0];
    const mr1 = is.mask_river[1][runout * n1 ..][0..n1];

    for (0..16) |_| {
        fillRandom(rng, r0);
        fillRandom(rng, r1);
        for (r0, mr0) |*r, m| r.* *= m;
        for (r1, mr1) |*r, m| r.* *= m;

        @memset(&lo, 0);
        @memset(&eq, 0);
        @memset(&cs, 0);
        const total0 = terminal_eval.computeCardSum(&cs, r1, is.card_idx[1]);
        for (0..n0) |h| {
            const s = is.same_combo_idx[0][h];
            sr[h] = if (s != std.math.maxInt(u32)) r1[s] else 0.0;
        }
        terminal_eval.showdownEval(
            v0, r1, is.card_idx[0], is.card_idx[1],
            sd.order[0][runout * n0 ..][0..n0], sd.strengths[0][runout * n0 ..][0..n0],
            sd.order[1][runout * n1 ..][0..n1], sd.strengths[1][runout * n1 ..][0..n1],
            win, loss, tie,
            &cs, total0, sr[0..n0], &lo, &eq, comp[0..n0],
        );
        @memset(&lo, 0);
        @memset(&eq, 0);
        @memset(&cs, 0);
        const total1 = terminal_eval.computeCardSum(&cs, r0, is.card_idx[0]);
        for (0..n1) |h| {
            const s = is.same_combo_idx[1][h];
            sr[h] = if (s != std.math.maxInt(u32)) r0[s] else 0.0;
        }
        terminal_eval.showdownEval(
            v1, r0, is.card_idx[1], is.card_idx[0],
            sd.order[1][runout * n1 ..][0..n1], sd.strengths[1][runout * n1 ..][0..n1],
            sd.order[0][runout * n0 ..][0..n0], sd.strengths[0][runout * n0 ..][0..n0],
            win, loss, tie,
            &cs, total1, sr[0..n1], &lo, &eq, comp[0..n1],
        );

        const mass = naiveCompatMass(r0, r1, is.ranges[0].hands, is.ranges[1].hands);
        try testing.expect(constantSumResidual(ip_u, r0, r1, v0, v1, mass) < 1e-2);
    }
}

test "solver invariants hold through a DCFR run" {
    const alloc = testing.allocator;
    const oop = [_]WeightedCombo{
        try wc(card.makeCard(9, 0), card.makeCard(8, 0)),
        try wc(card.makeCard(3, 0), card.makeCard(1, 0)),
    };
    const ip = [_]WeightedCombo{
        try wc(card.makeCard(7, 0), card.makeCard(6, 0)),
        try wc(card.makeCard(4, 0), card.makeCard(2, 0)),
    };
    var is = try buildInit(alloc, mono_flop, &oop, &ip);
    defer is.deinit();

    var solver = try Solver.init(alloc, &is, .{});
    defer solver.deinit();

    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        solver.iterate(1);
        assertSolverRegretsFinite(&is);
        assertExploitabilityNonNegative(&solver, 1e-3);
    }
}

test "invalid solver config is rejected" {
    const alloc = testing.allocator;
    const hands = [_]WeightedCombo{try wc(card.makeCard(9, 0), card.makeCard(8, 0))};
    var is = try buildInit(alloc, mono_flop, &hands, &hands);
    defer is.deinit();

    try testing.expectError(error.InvalidSolverConfig, Solver.init(alloc, &is, .{ .max_iterations = 0 }));
    try testing.expectError(error.InvalidSolverConfig, Solver.init(alloc, &is, .{ .dcfr = .{ .gamma = -1 } }));
}
