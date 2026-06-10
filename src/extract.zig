//! Phase 9 — output extraction (spec §11).
//!
//! Turns a solved `Solver` into answers about *real* boards. Queries arrive with
//! real turn/river cards; the engine only ever stored strategies for the
//! canonical (suit-isomorphic) runouts. This module maps a real runout to its
//! canonical id plus the suit permutation that carries the real board onto the
//! canonical board, then answers by permuting the hand through that permutation:
//! a hand's strategy on the real board equals its image-hand's strategy on the
//! canonical board (spec §11.2).
//!
//! It also exposes single-hand average-strategy lookup (§11.1) and per-node,
//! per-hand EVs under the average profile (§11.3, via `Solver.captureNodeValues`).

const std = @import("std");
const card = @import("card.zig");
const game_tree = @import("game_tree.zig");
const init_mod = @import("init.zig");
const cfr = @import("cfr.zig");
const isomorphism = @import("isomorphism.zig");
const range = @import("range.zig");

const Card = card.Card;
const Combo = card.Combo;
const Street = game_tree.Street;
const NodeRef = game_tree.NodeRef;
const SolverInit = init_mod.SolverInit;
const Solver = cfr.Solver;
const SuitPermutation = isomorphism.SuitPermutation;
const Range = range.Range;

pub const ExtractError = error{
    RiverWithoutTurn,
    TurnNotFound,
    RiverNotFound,
    NoTurnPermutation,
    NoRiverPermutation,
    NotAnActionNode,
    HandNotInRange,
    OutTooSmall,
};

/// Result of mapping a real runout to canonical storage coordinates.
///
/// `permutation` maps the *real* board onto the *canonical* board (and so maps a
/// real hand onto the range-equivalent canonical hand). `runoutId()` returns the
/// storage runout id appropriate to `street`.
pub const RunoutResolution = struct {
    street: Street,
    canonical_turn: u32,
    canonical_river: ?u32,
    permutation: SuitPermutation,

    pub fn runoutId(self: RunoutResolution) u32 {
        return switch (self.street) {
            .flop => 0,
            .turn => self.canonical_turn,
            .river => self.canonical_river.?,
        };
    }
};

/// Resolve a real `(turn, river)` to canonical runout ids and the real→canonical
/// suit permutation. Pass `turn == null` for a flop-street query (identity), and
/// `river == null` for a turn-street query. The permutation is composed so that
/// it carries the entire real board onto the canonical board.
pub fn resolveRunout(is: *const SolverInit, turn: ?Card, river: ?Card) ExtractError!RunoutResolution {
    const rt = &is.runout_tables;

    if (turn == null) {
        if (river != null) return ExtractError.RiverWithoutTurn;
        return .{ .street = .flop, .canonical_turn = 0, .canonical_river = null, .permutation = SuitPermutation.identity() };
    }
    const t = turn.?;

    // Find the canonical turn whose orbit contains the real turn card.
    const turn_idx: u32 = @intCast(findOrbit(rt.canonical_turns, t) orelse return ExtractError.TurnNotFound);
    const c_turn = rt.canonical_turns[turn_idx].card;

    // A valid permutation carrying the real turn onto the canonical turn.
    const pi_turn = permMapping(rt.valid_permutations, null, t, c_turn) orelse
        return ExtractError.NoTurnPermutation;

    if (river == null) {
        return .{ .street = .turn, .canonical_turn = turn_idx, .canonical_river = null, .permutation = pi_turn };
    }
    const r = river.?;

    // Map the real river onto the canonical-turn board, then canonicalize it
    // within the turn-fixed subgroup (permutations that also fix the canonical
    // turn) — exactly how the isomorphism module enumerated canonical rivers.
    const r_mapped = pi_turn.applyCard(r);
    const rivers = rt.riversForTurn(turn_idx);
    const r_local = findOrbit(rivers, r_mapped) orelse return ExtractError.RiverNotFound;
    const c_river = rivers[r_local].card;
    const river_full = rt.canonical_turns[turn_idx].first_river + @as(u32, @intCast(r_local));

    const pi_river = permMapping(rt.valid_permutations, c_turn, r_mapped, c_river) orelse
        return ExtractError.NoRiverPermutation;

    return .{
        .street = .river,
        .canonical_turn = turn_idx,
        .canonical_river = river_full,
        // First map real→canonical-turn-frame (pi_turn), then canonicalize the
        // river (pi_river): π = pi_river ∘ pi_turn.
        .permutation = pi_river.compose(pi_turn),
    };
}

/// Average strategy for a real hand at an action node on a real board.
/// `out` receives the `A` action probabilities (`A == node.num_children`); it
/// must be at least that long. Handles suit expansion end-to-end.
pub fn strategyForHand(
    solver: *Solver,
    node_ref: NodeRef,
    real_hand: Combo,
    turn: ?Card,
    river: ?Card,
    out: []f32,
) ExtractError!void {
    const is = solver.init_state;
    if ((game_tree.refTag(node_ref) catch unreachable) != .action) return ExtractError.NotAnActionNode;
    const node = is.tree.action_nodes.items[game_tree.refIndex(node_ref)];
    if (out.len < node.num_children) return ExtractError.OutTooSmall;

    const res = try resolveRunout(is, turn, river);
    const canon_hand = res.permutation.applyCombo(real_hand) catch return ExtractError.HandNotInRange;
    const h = handIndex(is.ranges[node.player], canon_hand) orelse return ExtractError.HandNotInRange;

    solver.averageStrategyHand(res.street, res.runoutId(), node_ref, h, out[0..node.num_children]);
}

/// Per-hand counterfactual values at a node under the average profile, in the
/// node's player's *canonical* hand space. `out` must be length `N[player]`.
/// Returns false if the node was not reached (e.g. zero-reach prune). This is
/// the per-node EV instrument of spec §11.3 (an average-profile pass that mixes
/// rather than maxes — see `Solver.captureNodeValues`).
pub fn nodeEVs(
    solver: *Solver,
    node_ref: NodeRef,
    turn: ?Card,
    river: ?Card,
    out: []f32,
) ExtractError!bool {
    const is = solver.init_state;
    if ((game_tree.refTag(node_ref) catch unreachable) != .action) return ExtractError.NotAnActionNode;
    const node = is.tree.action_nodes.items[game_tree.refIndex(node_ref)];
    if (out.len < solver.N[node.player]) return ExtractError.OutTooSmall;

    const res = try resolveRunout(is, turn, river);
    return solver.captureNodeValues(node.player, node_ref, res.runoutId(), out[0..solver.N[node.player]]);
}

/// Range-local canonical hand index for a real hand under a resolved runout, or
/// null if the (board-permuted) hand is not in `player`'s range. This is the
/// row to read in `averageStrategy` / `captureNodeValues` output for that hand;
/// it factors out the suit-expansion mapping that `strategyForHand` performs
/// internally, so callers can fetch a whole node's grid once and index it.
pub fn canonicalHandIndex(
    is: *const SolverInit,
    player: u8,
    real_hand: Combo,
    res: RunoutResolution,
) ?u32 {
    const canon = res.permutation.applyCombo(real_hand) catch return null;
    return handIndex(is.ranges[player], canon);
}

// ── Internals ──────────────────────────────────────────────────────────────

/// Index of the orbit (canonical turn or river) whose `orbit_mask` contains the
/// real card `c`. Works for any element type exposing `orbit_mask: u64`.
fn findOrbit(orbits: anytype, c: Card) ?usize {
    const m = card.mask(c);
    for (orbits, 0..) |orbit, i| {
        if ((m & orbit.orbit_mask) != 0) return i;
    }
    return null;
}

/// First permutation in `perms` that maps `src` onto `dst`. If `fix` is
/// non-null, only permutations that also fix that card (the turn-fixed subgroup
/// used for river canonicalization) are considered.
fn permMapping(perms: []const SuitPermutation, fix: ?Card, src: Card, dst: Card) ?SuitPermutation {
    const dst_i = card.index(dst);
    for (perms) |perm| {
        if (fix) |f| {
            if (card.index(perm.applyCard(f)) != card.index(f)) continue;
        }
        if (card.index(perm.applyCard(src)) == dst_i) return perm;
    }
    return null;
}

/// Range-local index of a combo, or null if absent. Hands are stored sorted by
/// `canonicalKey`, so a binary search suffices.
fn handIndex(r: Range, combo: Combo) ?u32 {
    const key = combo.canonicalKey();
    var lo: usize = 0;
    var hi: usize = r.hands.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const k = r.hands[mid].canonicalKey();
        if (k == key) return @intCast(mid);
        if (k < key) lo = mid + 1 else hi = mid;
    }
    return null;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const WeightedCombo = range.WeightedCombo;

fn wc(a: Card, b: Card) !WeightedCombo {
    return .{ .combo = try Combo.init(a, b), .weight = 1.0 };
}

const one_sizing = [_]game_tree.Sizing{game_tree.Sizing.init(50, 100)};
const test_sizings: [3][]const game_tree.Sizing = .{ &one_sizing, &one_sizing, &one_sizing };

fn buildInit(allocator: std.mem.Allocator, flop: [3]Card, oop: []const WeightedCombo, ip: []const WeightedCombo) !SolverInit {
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

test "compose matches sequential application" {
    const a = SuitPermutation{ .map = .{ 1, 0, 3, 2 } };
    const b = SuitPermutation{ .map = .{ 0, 2, 1, 3 } };
    const ab = a.compose(b);
    var s: u8 = 0;
    while (s < 4) : (s += 1) {
        const c = card.makeCard(5, s);
        try testing.expectEqual(card.index(a.applyCard(b.applyCard(c))), card.index(ab.applyCard(c)));
    }
}

test "resolveRunout: flop and identity turn/river round-trip onto canonical cards" {
    const alloc = testing.allocator;
    // Rainbow flop ⇒ only the identity permutation; every real card is its own
    // canonical representative.
    const flop = [_]Card{ card.makeCard(12, 0), card.makeCard(10, 1), card.makeCard(7, 2) };
    const oop = [_]WeightedCombo{ try wc(card.makeCard(11, 0), card.makeCard(9, 0)) };
    const ip = [_]WeightedCombo{ try wc(card.makeCard(8, 3), card.makeCard(6, 3)) };

    var is = try buildInit(alloc, flop, &oop, &ip);
    defer is.deinit();

    // Flop query.
    const rflop = try resolveRunout(&is, null, null);
    try testing.expectEqual(Street.flop, rflop.street);
    try testing.expectEqual(@as(u32, 0), rflop.runoutId());

    // Turn query: real turn equals its canonical card, permutation maps it to itself.
    const turn = is.runout_tables.canonical_turns[3].card;
    const rt = try resolveRunout(&is, turn, null);
    try testing.expectEqual(Street.turn, rt.street);
    try testing.expectEqual(@as(u32, 3), rt.runoutId());
    try testing.expectEqual(card.index(turn), card.index(rt.permutation.applyCard(turn)));

    // River query: canonical river round-trips and the resolved id is global.
    const ct = is.runout_tables.canonical_turns[3];
    const river = is.runout_tables.canonical_rivers[ct.first_river].card;
    const rr = try resolveRunout(&is, turn, river);
    try testing.expectEqual(Street.river, rr.street);
    try testing.expectEqual(ct.first_river, rr.runoutId());
    try testing.expectEqual(card.index(river), card.index(rr.permutation.applyCard(river)));
}

// Two-tone flop (As Ks 2h): board-fixing suit perms are {identity, swap(d,c)}.
// Diamond↔club-symmetric ranges keep that swap valid, so diamond/club runouts
// collapse to one canonical representative and the swap permutes hands.
const two_tone = [_]Card{ card.makeCard(12, 0), card.makeCard(11, 0), card.makeCard(0, 1) };

fn symmetricRange() ![4]WeightedCombo {
    return .{
        // A diamond pair and its club mirror (swapped by d↔c).
        try wc(card.makeCard(5, 2), card.makeCard(4, 2)), // 7d6d
        try wc(card.makeCard(5, 3), card.makeCard(4, 3)), // 7c6c
        // A spade and a heart combo, each fixed by the swap.
        try wc(card.makeCard(9, 0), card.makeCard(8, 0)), // spades
        try wc(card.makeCard(9, 1), card.makeCard(8, 1)), // hearts
    };
}

test "two-tone flop exposes a non-trivial diamond↔club symmetry" {
    const alloc = testing.allocator;
    const r = try symmetricRange();
    var is = try buildInit(alloc, two_tone, &r, &r);
    defer is.deinit();
    // The swap must survive range filtering ⇒ identity + one real permutation.
    try testing.expectEqual(@as(usize, 2), is.runout_tables.valid_permutations.len);
}

/// First action node encountered at `target` street in a pre-order walk, or
/// null. Tracks street across chance nodes (which advance it).
fn findActionAtStreet(is: *const SolverInit, ref: NodeRef, street: Street, target: Street) ?NodeRef {
    switch (game_tree.refTag(ref) catch unreachable) {
        .action => {
            if (street == target) return ref;
            const node = is.tree.action_nodes.items[game_tree.refIndex(ref)];
            var i: u32 = 0;
            while (i < node.num_children) : (i += 1) {
                const child = is.tree.edges.items[node.first_child_edge + i];
                if (findActionAtStreet(is, child, street, target)) |f| return f;
            }
            return null;
        },
        .chance => {
            const node = is.tree.chance_nodes.items[game_tree.refIndex(ref)];
            return findActionAtStreet(is, node.child, @enumFromInt(node.next_street), target);
        },
        .terminal => return null,
    }
}

test "suit expansion: orbit-equivalent turn boards give identical strategies" {
    const alloc = testing.allocator;
    const r = try symmetricRange();
    var is = try buildInit(alloc, two_tone, &r, &r);
    defer is.deinit();

    var solver = try Solver.init(alloc, &is, .{});
    defer solver.deinit();
    solver.iterate(20);

    // A genuine turn-street action node — querying turn boards here reads the
    // turn storage block, unlike querying the flop root.
    const turn_node = findActionAtStreet(&is, is.tree.root, .flop, .turn).?;
    const node = is.tree.action_nodes.items[game_tree.refIndex(turn_node)];
    const a = node.num_children;

    const turn_d = card.makeCard(3, 2); // 5d
    const turn_c = card.makeCard(3, 3); // 5c
    // Both must be the same canonical turn (the diamond↔club orbit), reached via
    // different permutations — that is what makes the expansion non-trivial.
    const res_d = try resolveRunout(&is, turn_d, null);
    const res_c = try resolveRunout(&is, turn_c, null);
    try testing.expectEqual(res_d.canonical_turn, res_c.canonical_turn);

    // A spade hand is fixed by the swap: identical strategy on both boards.
    const spade_hand = try Combo.init(card.makeCard(9, 0), card.makeCard(8, 0));
    var s_d: [8]f32 = undefined;
    var s_c: [8]f32 = undefined;
    try strategyForHand(&solver, turn_node, spade_hand, turn_d, null, &s_d);
    try strategyForHand(&solver, turn_node, spade_hand, turn_c, null, &s_c);
    for (0..a) |i| try testing.expectApproxEqAbs(s_d[i], s_c[i], 1e-6);

    // A diamond hand on the diamond board and its club mirror on the club board
    // are the same situation under the swap ⇒ identical strategies. This path
    // exercises the non-trivial hand permutation (7c6c ↦ 7d6d).
    const dia_hand = try Combo.init(card.makeCard(5, 2), card.makeCard(4, 2)); // 7d6d
    const clb_hand = try Combo.init(card.makeCard(5, 3), card.makeCard(4, 3)); // 7c6c
    var s_dia: [8]f32 = undefined;
    var s_clb: [8]f32 = undefined;
    try strategyForHand(&solver, turn_node, dia_hand, turn_d, null, &s_dia);
    try strategyForHand(&solver, turn_node, clb_hand, turn_c, null, &s_clb);
    for (0..a) |i| try testing.expectApproxEqAbs(s_dia[i], s_clb[i], 1e-6);
}

test "strategyForHand on the canonical board matches the raw average strategy" {
    const alloc = testing.allocator;
    const r = try symmetricRange();
    var is = try buildInit(alloc, two_tone, &r, &r);
    defer is.deinit();

    var solver = try Solver.init(alloc, &is, .{});
    defer solver.deinit();
    solver.iterate(15);

    const root = is.tree.root;
    const node = is.tree.action_nodes.items[game_tree.refIndex(root)];
    const a = node.num_children;
    const n = solver.N[node.player];

    // Root is a flop node: a flop query takes the identity path, so per-hand
    // expansion must equal the directly-extracted average-strategy column.
    const full = try alloc.alloc(f32, @as(usize, a) * n);
    defer alloc.free(full);
    solver.averageStrategy(.flop, 0, root, full);

    const spade_hand = try Combo.init(card.makeCard(9, 0), card.makeCard(8, 0));
    const hidx = handIndex(is.ranges[node.player], spade_hand).?;
    var got: [8]f32 = undefined;
    try strategyForHand(&solver, root, spade_hand, null, null, &got);
    for (0..a) |ai| try testing.expectApproxEqAbs(full[ai * n + hidx], got[ai], 1e-9);
}

test "nodeEVs at the root reconstruct the average root EV" {
    const alloc = testing.allocator;
    const r = try symmetricRange();
    var is = try buildInit(alloc, two_tone, &r, &r);
    defer is.deinit();

    var solver = try Solver.init(alloc, &is, .{});
    defer solver.deinit();
    solver.iterate(15);

    const root = is.tree.root;
    const node = is.tree.action_nodes.items[game_tree.refIndex(root)];
    const player = node.player;
    const n = solver.N[player];

    const evs = try alloc.alloc(f32, n);
    defer alloc.free(evs);
    const found = try nodeEVs(&solver, root, null, null, evs);
    try testing.expect(found);

    // sum_h reach_u[h] * v[h] == averageEV(player): root reach is weight*flop-mask.
    var ev: f32 = 0;
    for (is.ranges[player].hands, is.ranges[player].weights, is.mask_flop[player], 0..) |_, w, m, i| {
        ev += (w * m) * evs[i];
    }
    try testing.expectApproxEqAbs(solver.averageEV(player), ev, 1e-3);
}

test "canonicalHandIndex selects the same row strategyForHand reads" {
    const alloc = testing.allocator;
    const r = try symmetricRange();
    var is = try buildInit(alloc, two_tone, &r, &r);
    defer is.deinit();

    var solver = try Solver.init(alloc, &is, .{});
    defer solver.deinit();
    solver.iterate(20);

    const turn_node = findActionAtStreet(&is, is.tree.root, .flop, .turn).?;
    const node = is.tree.action_nodes.items[game_tree.refIndex(turn_node)];
    const a = node.num_children;
    const n = solver.N[node.player];

    // Club turn, club hand (7c6c) — exercises the non-trivial d↔c permutation.
    const turn_c = card.makeCard(3, 3); // 5c
    const clb_hand = try Combo.init(card.makeCard(5, 3), card.makeCard(4, 3)); // 7c6c

    const res = try resolveRunout(&is, turn_c, null);
    const ci = canonicalHandIndex(&is, node.player, clb_hand, res).?;

    const grid = try alloc.alloc(f32, @as(usize, a) * n);
    defer alloc.free(grid);
    solver.averageStrategy(res.street, res.runoutId(), turn_node, grid);

    var direct: [8]f32 = undefined;
    try strategyForHand(&solver, turn_node, clb_hand, turn_c, null, &direct);

    // The grid row picked by canonicalHandIndex must equal the end-to-end query.
    for (0..a) |i| try testing.expectApproxEqAbs(grid[i * n + ci], direct[i], 1e-9);

    // A hand using the turn card is not in range.
    const uses_turn = try Combo.init(turn_c, card.makeCard(9, 0));
    try testing.expectEqual(@as(?u32, null), canonicalHandIndex(&is, node.player, uses_turn, res));
}

test "handIndex finds present combos and rejects absent ones" {
    const alloc = testing.allocator;
    const r = try symmetricRange();
    var is = try buildInit(alloc, two_tone, &r, &r);
    defer is.deinit();

    for (is.ranges[0].hands, 0..) |hand, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), handIndex(is.ranges[0], hand).?);
    }
    // A combo using a board card is never in range.
    const absent = try Combo.init(card.makeCard(12, 0), card.makeCard(2, 2));
    try testing.expectEqual(@as(?u32, null), handIndex(is.ranges[0], absent));
}
