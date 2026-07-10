//! Suit-orbit remap tables for solve-time isomorphism compression.
//!
//! When compression is enabled the solver stores regrets/strategies and board
//! tables for the *canonical* runouts only, but must still account for every
//! *physical* runout — a private hand may contain a non-canonical card of an
//! orbit, so a representative board cannot simply be multiplied by its orbit
//! size (see the note in `init.zig`).
//!
//! This module precomputes, for each physical orbit member, (a) the canonical
//! runout id it maps to and (b) the per-player hand-index permutation induced by
//! the suit permutation that carries the member board onto the canonical board.
//! The traversal (`cfr.zig`) permutes reaches into canonical hand order before
//! descending the canonical subtree and inverse-permutes the returned CFVs.
//!
//! Key economy: the hand permutation depends only on the `SuitPermutation`, and
//! there are at most 24 valid permutations (typically ≤6). So hand tables are
//! precomputed once per distinct permutation, and each member merely references
//! a permutation index. Member weights are the plain physical chance
//! probabilities (1/45 turn, 1/44 river) — NOT multiplicity-scaled — because the
//! traversal visits each physical member individually.

const std = @import("std");
const card = @import("card.zig");
const isomorphism = @import("isomorphism.zig");

const Allocator = std.mem.Allocator;
const Card = card.Card;
const Combo = card.Combo;
const SuitPermutation = isomorphism.SuitPermutation;
const RunoutTables = isomorphism.RunoutTables;

/// Per-player, per-permutation hand-index maps.
///
/// `to_canon[p][h]` = canonical-frame hand index of physical hand `h` under the
/// permutation; `from_canon[p][j]` = physical hand index whose canonical image is
/// `j` (the inverse). Both length `N_p`.
pub const HandPerm = struct {
    to_canon: [2][]u32,
    from_canon: [2][]u32,
};

/// One physical orbit member: which permutation carries it onto the canonical
/// board (an index into `perms` / `hand_perms`).
pub const Member = struct {
    perm_index: u32,
};

/// One physical flop→turn→river runout for a flop all-in terminal: the canonical
/// river it maps to (flat index into `canonical_rivers`) plus the single composed
/// permutation (turn∘river) that carries the physical 5-card board onto the
/// canonical board. Enumerated in turn-major, river-major order so rainbow flops
/// accumulate in the same order as the physical `allInEvalFlop`.
pub const FlopRunout = struct {
    canonical_river: u32,
    perm_index: u32,
};

pub const RemapTables = struct {
    allocator: Allocator,

    /// Distinct valid suit permutations (borrowed alias of the runout tables'
    /// `valid_permutations`; not owned).
    perms: []const SuitPermutation,
    /// Index of the identity permutation within `perms` (always present).
    identity_index: u32,

    /// Per-permutation hand maps, `hand_perms[perm_index]`.
    hand_perms: []HandPerm,

    /// `turn_members[canonical_turn]` = physical members of that turn's orbit.
    /// Concatenation over all turns covers the 49 physical turns exactly once.
    turn_members: [][]Member,
    /// `river_members[canonical_river_full]` = physical members of that river's
    /// orbit under the turn-fixed subgroup. Concatenation covers 2,352 exactly.
    river_members: [][]Member,

    /// Physical flop→turn→river runouts for flop all-in terminals, grouped by
    /// canonical turn (`flop_runouts[canonical_turn]`). Grouping mirrors the
    /// physical `allInEvalFlop`'s per-turn partial-sum reduction so the rainbow
    /// case accumulates in an identical order. Each entry carries the canonical
    /// river it maps to and the composed permutation onto that board.
    flop_runouts: [][]FlopRunout,

    /// Plain per-physical-member chance weights (1/45, 1/44).
    weight_turn: f32,
    weight_river: f32,

    /// Bytes of all owned tables (for total-memory reporting). The borrowed
    /// `perms` alias is not counted; it belongs to the runout tables.
    pub fn memoryBytes(self: *const RemapTables) u64 {
        var total: u64 = 0;
        for (self.hand_perms) |hp| {
            inline for (0..2) |p| {
                total += @as(u64, hp.to_canon[p].len) * @sizeOf(u32);
                total += @as(u64, hp.from_canon[p].len) * @sizeOf(u32);
            }
        }
        total += @as(u64, self.hand_perms.len) * @sizeOf(HandPerm);
        total += @as(u64, self.turn_members.len) * @sizeOf([]Member);
        for (self.turn_members) |m| total += @as(u64, m.len) * @sizeOf(Member);
        total += @as(u64, self.river_members.len) * @sizeOf([]Member);
        for (self.river_members) |m| total += @as(u64, m.len) * @sizeOf(Member);
        total += @as(u64, self.flop_runouts.len) * @sizeOf([]FlopRunout);
        for (self.flop_runouts) |g| total += @as(u64, g.len) * @sizeOf(FlopRunout);
        return total;
    }

    pub fn deinit(self: *RemapTables) void {
        for (self.flop_runouts) |g| self.allocator.free(g);
        self.allocator.free(self.flop_runouts);
        for (self.hand_perms) |*hp| {
            inline for (0..2) |p| {
                self.allocator.free(hp.to_canon[p]);
                self.allocator.free(hp.from_canon[p]);
            }
        }
        self.allocator.free(self.hand_perms);
        for (self.turn_members) |m| self.allocator.free(m);
        self.allocator.free(self.turn_members);
        for (self.river_members) |m| self.allocator.free(m);
        self.allocator.free(self.river_members);
        self.* = undefined;
    }
};

/// Build the remap tables for a compressed runout space. `hands` are the two
/// players' range-local combo arrays (canonical order). `rt` must be a compressed
/// `RunoutTables` (its `valid_permutations` is the group under which orbits were
/// formed). Safe to call for the uncompressed identity case as well, in which
/// case every orbit has size one and all permutations are the identity.
pub fn build(
    allocator: Allocator,
    hands: [2][]const Combo,
    flop: [3]Card,
    rt: *const RunoutTables,
) !RemapTables {
    const perms = rt.valid_permutations;
    const num_perms = perms.len;

    const identity_index = findIdentity(perms) orelse return error.NoIdentityPermutation;

    // Per-permutation hand maps.
    var hand_perms = try allocator.alloc(HandPerm, num_perms);
    var built: usize = 0;
    errdefer {
        for (hand_perms[0..built]) |*hp| {
            inline for (0..2) |p| {
                allocator.free(hp.to_canon[p]);
                allocator.free(hp.from_canon[p]);
            }
        }
        allocator.free(hand_perms);
    }
    for (perms, 0..) |perm, pi| {
        hand_perms[pi] = try buildHandPerm(allocator, hands, perm);
        built += 1;
    }

    const flop_mask = card.boardMask(flop[0..]);

    // Turn members: iterate the physical cards in each canonical turn's orbit.
    var turn_members = try allocator.alloc([]Member, rt.canonical_turns.len);
    var turns_built: usize = 0;
    errdefer {
        for (turn_members[0..turns_built]) |m| allocator.free(m);
        allocator.free(turn_members);
    }
    for (rt.canonical_turns, 0..) |turn, t| {
        turn_members[t] = try buildMembers(
            allocator,
            perms,
            null, // no fixed card for turn-level orbit
            turn.orbit_mask,
            turn.card,
            identity_index,
        );
        turns_built += 1;
    }

    // River members: for each canonical turn, its turn-fixed subgroup forms the
    // river orbits. Iterate canonical rivers in flat order.
    var river_members = try allocator.alloc([]Member, rt.canonical_rivers.len);
    var rivers_built: usize = 0;
    errdefer {
        for (river_members[0..rivers_built]) |m| allocator.free(m);
        allocator.free(river_members);
    }
    for (rt.canonical_turns, 0..) |turn, t| {
        const first: usize = @intCast(turn.first_river);
        for (rt.riversForTurn(t), 0..) |river, r| {
            const full = first + r;
            river_members[full] = try buildMembers(
                allocator,
                perms,
                turn.card, // river orbits live in the turn-fixed subgroup
                river.orbit_mask,
                river.card,
                identity_index,
            );
            rivers_built += 1;
        }
    }

    _ = flop_mask;

    // Physical flop→turn→river runout lists for flop all-in terminals, grouped by
    // canonical turn. Within a turn the order is (turn member, river, river
    // member) — turn-major/river-major to match physical `allInEvalFlop`. Each
    // runout's permutation is the river member's composed with the turn member's
    // (river applied after turn), carrying the physical board onto the canonical.
    var flop_runouts = try allocator.alloc([]FlopRunout, rt.canonical_turns.len);
    var groups_built: usize = 0;
    errdefer {
        for (flop_runouts[0..groups_built]) |g| allocator.free(g);
        allocator.free(flop_runouts);
    }
    for (rt.canonical_turns, 0..) |turn, t| {
        const first: usize = @intCast(turn.first_river);
        var group = std.ArrayList(FlopRunout).empty;
        errdefer group.deinit(allocator);
        for (turn_members[t]) |tm| {
            const pi_turn = perms[tm.perm_index];
            for (rt.riversForTurn(t), 0..) |_, r| {
                const full = first + r;
                for (river_members[full]) |rmem| {
                    const pi_river = perms[rmem.perm_index];
                    const composed = pi_river.compose(pi_turn);
                    const ci = findPermIndex(perms, composed) orelse return error.ComposedPermNotInGroup;
                    try group.append(allocator, .{ .canonical_river = @intCast(full), .perm_index = ci });
                }
            }
        }
        flop_runouts[t] = try group.toOwnedSlice(allocator);
        groups_built += 1;
    }

    return .{
        .allocator = allocator,
        .perms = perms,
        .identity_index = identity_index,
        .hand_perms = hand_perms,
        .turn_members = turn_members,
        .river_members = river_members,
        .flop_runouts = flop_runouts,
        // Computed as an f32/f32 division to match `allocChanceWeights`
        // (multiplicity 1 case) bit-for-bit, so rainbow parity stays byte-exact.
        .weight_turn = @as(f32, 1.0) / @as(f32, 45.0),
        .weight_river = @as(f32, 1.0) / @as(f32, 44.0),
    };
}

fn findIdentity(perms: []const SuitPermutation) ?u32 {
    for (perms, 0..) |perm, i| {
        if (perm.map[0] == 0 and perm.map[1] == 1 and perm.map[2] == 2 and perm.map[3] == 3) {
            return @intCast(i);
        }
    }
    return null;
}

fn buildHandPerm(allocator: Allocator, hands: [2][]const Combo, perm: SuitPermutation) !HandPerm {
    var hp: HandPerm = undefined;
    var done: usize = 0;
    errdefer {
        // Free whatever was allocated so far (to_canon[0], from_canon[0], ...).
        if (done > 0) allocator.free(hp.to_canon[0]);
        if (done > 1) allocator.free(hp.from_canon[0]);
        if (done > 2) allocator.free(hp.to_canon[1]);
    }
    inline for (0..2) |p| {
        const n = hands[p].len;
        const to_canon = try allocator.alloc(u32, n);
        done += 1;
        const from_canon = try allocator.alloc(u32, n);
        done += 1;
        for (hands[p], 0..) |h, i| {
            const mapped = try h.applySuitMap(perm.map);
            const j = handIndex(hands[p], mapped) orelse return error.PermutedHandNotInRange;
            to_canon[i] = j;
            from_canon[j] = @intCast(i);
        }
        hp.to_canon[p] = to_canon;
        hp.from_canon[p] = from_canon;
    }
    return hp;
}

/// Enumerate the physical cards in `orbit_mask` and, for each, find the (subgroup)
/// permutation mapping it onto `canonical`. `fix` (a turn card) restricts the
/// search to permutations that also fix that card, matching how river orbits were
/// formed under the turn-fixed subgroup. The canonical card itself uses identity.
fn buildMembers(
    allocator: Allocator,
    perms: []const SuitPermutation,
    fix: ?Card,
    orbit_mask: u64,
    canonical: Card,
    identity_index: u32,
) ![]Member {
    const count = @popCount(orbit_mask);
    const members = try allocator.alloc(Member, count);
    errdefer allocator.free(members);

    const canon_i = card.index(canonical);
    var out: usize = 0;
    var ci: u8 = 0;
    while (ci < card.deck_count) : (ci += 1) {
        if ((orbit_mask & (@as(u64, 1) << @intCast(ci))) == 0) continue;
        const phys = try card.fromIndex(ci);
        const perm_index: u32 = if (ci == canon_i)
            identity_index
        else
            permMapping(perms, fix, phys, canonical) orelse return error.NoMemberPermutation;
        members[out] = .{ .perm_index = perm_index };
        out += 1;
    }
    std.debug.assert(out == count);
    return members;
}

/// First permutation index mapping `src` onto `dst`, optionally fixing `fix`.
fn permMapping(perms: []const SuitPermutation, fix: ?Card, src: Card, dst: Card) ?u32 {
    const dst_i = card.index(dst);
    for (perms, 0..) |perm, i| {
        if (fix) |f| {
            if (card.index(perm.applyCard(f)) != card.index(f)) continue;
        }
        if (card.index(perm.applyCard(src)) == dst_i) return @intCast(i);
    }
    return null;
}

/// Index of `target` within `perms` by its suit map, or null.
fn findPermIndex(perms: []const SuitPermutation, target: SuitPermutation) ?u32 {
    for (perms, 0..) |perm, i| {
        if (std.mem.eql(u8, &perm.map, &target.map)) return @intCast(i);
    }
    return null;
}

/// Range-local index of a combo (hands sorted by `canonicalKey`), or null.
fn handIndex(hands: []const Combo, combo: Combo) ?u32 {
    const key = combo.canonicalKey();
    var lo: usize = 0;
    var hi: usize = hands.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const k = hands[mid].canonicalKey();
        if (k == key) return @intCast(mid);
        if (k < key) lo = mid + 1 else hi = mid;
    }
    return null;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const WeightedCombo = isomorphism.WeightedCombo;

test "rainbow: every orbit is size one and identity" {
    const flop = [_]Card{ card.makeCard(12, 0), card.makeCard(11, 1), card.makeCard(7, 2) };
    var rt = try isomorphism.buildRunoutTables(testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    const hands: [2][]const Combo = .{ &.{}, &.{} };
    var rm = try build(testing.allocator, hands, flop, &rt);
    defer rm.deinit();

    try testing.expectEqual(@as(usize, 1), rm.perms.len);
    try testing.expectEqual(@as(usize, 49), rm.turn_members.len);
    try testing.expectEqual(@as(usize, 2352), rm.river_members.len);
    for (rm.turn_members) |m| {
        try testing.expectEqual(@as(usize, 1), m.len);
        try testing.expectEqual(rm.identity_index, m[0].perm_index);
    }
    for (rm.river_members) |m| try testing.expectEqual(@as(usize, 1), m.len);

    // Flop all-in list covers all physical runouts (grouped by canonical turn),
    // each identity and pointing at its own canonical (== physical) river. For a
    // rainbow flop canonical turns are the 49 physical turns in order, and each
    // turn's rivers are the 48 physical rivers in flat order.
    try testing.expectEqual(@as(usize, 49), rm.flop_runouts.len);
    var seen: usize = 0;
    for (rm.flop_runouts) |group| {
        try testing.expectEqual(@as(usize, 48), group.len);
        for (group) |fr| {
            try testing.expectEqual(rm.identity_index, fr.perm_index);
            seen += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2352), seen);
}

test "monotone: physical turns covered exactly once, weights sum to one" {
    const flop = [_]Card{ card.makeCard(12, 0), card.makeCard(10, 0), card.makeCard(7, 0) };
    var rt = try isomorphism.buildRunoutTables(testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    const hands: [2][]const Combo = .{ &.{}, &.{} };
    var rm = try build(testing.allocator, hands, flop, &rt);
    defer rm.deinit();

    try testing.expect(rm.turn_members.len < 49);

    // Every canonical turn's member count equals its multiplicity, and the total
    // is the 49 physical turns.
    var total_turn_members: u64 = 0;
    for (rt.canonical_turns, 0..) |turn, t| {
        try testing.expectEqual(@as(usize, turn.multiplicity), rm.turn_members[t].len);
        total_turn_members += rm.turn_members[t].len;
    }
    try testing.expectEqual(@as(u64, 49), total_turn_members);

    for (rt.canonical_rivers, 0..) |river, r| {
        try testing.expectEqual(@as(usize, river.multiplicity), rm.river_members[r].len);
    }

    // River members are enumerated in each canonical *turn* frame: for every
    // canonical turn, its rivers' members cover exactly the 48 physical rivers of
    // that (canonical) board. The turn-multiplicity factor is applied separately
    // at the turn seam, so the grand total of physical turn→river runouts is
    // Σ_turn (turn members × rivers-under-turn members) = 49 × 48 = 2,352.
    var grand_total: u64 = 0;
    for (rt.canonical_turns, 0..) |_, t| {
        var rivers_here: u64 = 0;
        for (rt.riversForTurn(t)) |river| rivers_here += river.multiplicity;
        try testing.expectEqual(@as(u64, 48), rivers_here);
        grand_total += rm.turn_members[t].len * rivers_here;
    }
    try testing.expectEqual(@as(u64, 2352), grand_total);
    var flop_total: usize = 0;
    for (rm.flop_runouts) |group| flop_total += group.len;
    try testing.expectEqual(@as(usize, 2352), flop_total);

    // Per-member weights recover the physical chance mass.
    try testing.expect(@abs(@as(f32, @floatFromInt(49)) * rm.weight_turn - 49.0 / 45.0) < 1e-6);
}

test "hand perm composes to identity round-trip" {
    // Monotone flop with a symmetric range so non-identity permutations survive.
    const flop = [_]Card{ card.makeCard(12, 0), card.makeCard(10, 0), card.makeCard(7, 0) };
    // Range: a couple of offsuit combos closed under h<->d<->c swaps.
    var oop_list = std.ArrayList(WeightedCombo).empty;
    defer oop_list.deinit(testing.allocator);
    // 2h3h, 2d3d, 2c3c (spade-flop leaves the three red/black offsuits symmetric)
    try oop_list.append(testing.allocator, .{ .combo = try Combo.init(card.makeCard(0, 1), card.makeCard(1, 1)), .weight = 1.0 });
    try oop_list.append(testing.allocator, .{ .combo = try Combo.init(card.makeCard(0, 2), card.makeCard(1, 2)), .weight = 1.0 });
    try oop_list.append(testing.allocator, .{ .combo = try Combo.init(card.makeCard(0, 3), card.makeCard(1, 3)), .weight = 1.0 });

    var rt = try isomorphism.buildRunoutTables(testing.allocator, flop, .{ oop_list.items, oop_list.items });
    defer rt.deinit();

    const range = @import("range.zig");
    var r0 = try range.buildRange(testing.allocator, oop_list.items);
    defer r0.deinit();
    const hands: [2][]const Combo = .{ r0.hands, r0.hands };

    var rm = try build(testing.allocator, hands, flop, &rt);
    defer rm.deinit();

    // For every permutation, to_canon then from_canon is the identity mapping.
    for (rm.hand_perms) |hp| {
        for (0..r0.hands.len) |h| {
            const j = hp.to_canon[0][h];
            try testing.expectEqual(@as(u32, @intCast(h)), hp.from_canon[0][j]);
        }
    }
}
