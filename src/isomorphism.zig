const std = @import("std");
const card = @import("card.zig");

const Allocator = std.mem.Allocator;
const Card = card.Card;

pub const WeightedCombo = struct {
    combo: card.Combo,
    weight: f32,
};

pub const SuitPermutation = struct {
    map: [4]u8,

    pub fn identity() SuitPermutation {
        return .{ .map = .{ 0, 1, 2, 3 } };
    }

    pub fn applyCard(self: SuitPermutation, c: Card) Card {
        return card.applySuitMap(c, self.map);
    }

    pub fn applyCombo(self: SuitPermutation, combo: card.Combo) !card.Combo {
        return combo.applySuitMap(self.map);
    }

    /// Composition: `self ∘ inner`. Applying the result is equivalent to
    /// applying `inner` first, then `self`:
    /// `result.applyCard(c) == self.applyCard(inner.applyCard(c))`.
    pub fn compose(self: SuitPermutation, inner: SuitPermutation) SuitPermutation {
        var m: [4]u8 = undefined;
        for (0..4) |s| m[s] = self.map[inner.map[s]];
        return .{ .map = m };
    }
};

pub const CanonicalRiver = struct {
    card: Card,
    multiplicity: u8,
    orbit_mask: u64,
};

pub const CanonicalTurn = struct {
    card: Card,
    multiplicity: u8,
    orbit_mask: u64,
    first_river: u32,
    num_rivers: u16,
};

pub const RunoutTables = struct {
    allocator: Allocator,
    valid_permutations: []SuitPermutation,
    canonical_turns: []CanonicalTurn,
    canonical_rivers: []CanonicalRiver,

    pub fn deinit(self: *RunoutTables) void {
        self.allocator.free(self.valid_permutations);
        self.allocator.free(self.canonical_turns);
        self.allocator.free(self.canonical_rivers);
        self.* = undefined;
    }

    pub fn runoutCounts(self: RunoutTables) [3]u64 {
        return .{ 1, self.canonical_turns.len, self.canonical_rivers.len };
    }

    pub fn riversForTurn(self: RunoutTables, turn_index: usize) []const CanonicalRiver {
        const turn = self.canonical_turns[turn_index];
        const first: usize = @intCast(turn.first_river);
        return self.canonical_rivers[first .. first + turn.num_rivers];
    }

    pub fn weightedTurnCount(self: RunoutTables) u64 {
        var total: u64 = 0;
        for (self.canonical_turns) |turn| {
            total += turn.multiplicity;
        }
        return total;
    }

    pub fn weightedRiverPairCount(self: RunoutTables) u64 {
        var total: u64 = 0;
        for (self.canonical_turns, 0..) |turn, turn_index| {
            var rivers_for_turn: u64 = 0;
            for (self.riversForTurn(turn_index)) |river| {
                rivers_for_turn += river.multiplicity;
            }
            total += @as(u64, turn.multiplicity) * rivers_for_turn;
        }
        return total;
    }
};

pub fn buildRunoutTables(
    allocator: Allocator,
    flop: [3]Card,
    ranges: [2][]const WeightedCombo,
) !RunoutTables {
    const flop_mask = try boardMask(flop[0..]);

    var valid_permutations = std.ArrayList(SuitPermutation).empty;
    errdefer valid_permutations.deinit(allocator);

    const all_permutations = allSuitPermutations();
    for (all_permutations.items[0..all_permutations.len]) |perm| {
        if (!try mapsBoardToItself(flop[0..], perm)) continue;
        if (!try preservesRange(ranges[0], perm)) continue;
        if (!try preservesRange(ranges[1], perm)) continue;
        try valid_permutations.append(allocator, perm);
    }
    if (valid_permutations.items.len == 0) return error.NoValidSuitPermutation;

    var turns = std.ArrayList(CanonicalTurn).empty;
    errdefer turns.deinit(allocator);
    var rivers = std.ArrayList(CanonicalRiver).empty;
    errdefer rivers.deinit(allocator);

    var visited_turns = [_]bool{false} ** card.deck_count;
    var turn_index: u8 = 0;
    while (turn_index < card.deck_count) : (turn_index += 1) {
        const turn = try card.fromIndex(turn_index);
        if ((card.mask(turn) & flop_mask) != 0 or visited_turns[turn_index]) continue;

        const turn_orbit = try cardOrbit(turn, flop_mask, valid_permutations.items);
        markOrbitVisited(&visited_turns, turn_orbit.orbit_mask);

        const canonical_turn = turn_orbit.card;
        const turn_dead_mask = flop_mask | card.mask(canonical_turn);
        const turn_group = try turnFixedGroup(allocator, valid_permutations.items, canonical_turn);
        defer allocator.free(turn_group);

        const first_river = try u32Index(rivers.items.len);
        try appendCanonicalRivers(allocator, &rivers, turn_dead_mask, turn_group);
        const num_rivers = rivers.items.len - first_river;
        if (num_rivers > std.math.maxInt(u16)) return error.TooManyCanonicalRiversForTurn;

        try turns.append(allocator, .{
            .card = canonical_turn,
            .multiplicity = turn_orbit.multiplicity,
            .orbit_mask = turn_orbit.orbit_mask,
            .first_river = first_river,
            .num_rivers = @intCast(num_rivers),
        });
    }

    const owned_valid_permutations = try valid_permutations.toOwnedSlice(allocator);
    errdefer allocator.free(owned_valid_permutations);
    const owned_turns = try turns.toOwnedSlice(allocator);
    errdefer allocator.free(owned_turns);
    const owned_rivers = try rivers.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .valid_permutations = owned_valid_permutations,
        .canonical_turns = owned_turns,
        .canonical_rivers = owned_rivers,
    };
}

const PermutationBuffer = struct {
    items: [24]SuitPermutation = undefined,
    len: u8 = 0,

    fn append(self: *PermutationBuffer, perm: SuitPermutation) void {
        self.items[self.len] = perm;
        self.len += 1;
    }
};

const Orbit = struct {
    card: Card,
    multiplicity: u8,
    orbit_mask: u64,
};

fn allSuitPermutations() PermutationBuffer {
    var result: PermutationBuffer = .{};
    var a: u8 = 0;
    while (a < card.suit_count) : (a += 1) {
        var b: u8 = 0;
        while (b < card.suit_count) : (b += 1) {
            if (b == a) continue;
            var c: u8 = 0;
            while (c < card.suit_count) : (c += 1) {
                if (c == a or c == b) continue;
                var d: u8 = 0;
                while (d < card.suit_count) : (d += 1) {
                    if (d == a or d == b or d == c) continue;
                    result.append(.{ .map = .{ a, b, c, d } });
                }
            }
        }
    }
    return result;
}

fn appendCanonicalRivers(
    allocator: Allocator,
    rivers: *std.ArrayList(CanonicalRiver),
    dead_mask: u64,
    turn_group: []const SuitPermutation,
) !void {
    var visited_rivers = [_]bool{false} ** card.deck_count;
    var river_index: u8 = 0;
    while (river_index < card.deck_count) : (river_index += 1) {
        const river = try card.fromIndex(river_index);
        if ((card.mask(river) & dead_mask) != 0 or visited_rivers[river_index]) continue;

        const orbit = try cardOrbit(river, dead_mask, turn_group);
        markOrbitVisited(&visited_rivers, orbit.orbit_mask);
        try rivers.append(allocator, .{
            .card = orbit.card,
            .multiplicity = orbit.multiplicity,
            .orbit_mask = orbit.orbit_mask,
        });
    }
}

fn cardOrbit(c: Card, dead_mask: u64, permutations: []const SuitPermutation) !Orbit {
    var seen = [_]bool{false} ** card.deck_count;
    var orbit_mask: u64 = 0;
    var multiplicity: u8 = 0;
    var canonical_index: u8 = card.deck_count;

    for (permutations) |perm| {
        const mapped = perm.applyCard(c);
        const mapped_mask = card.mask(mapped);
        if ((mapped_mask & dead_mask) != 0) return error.SuitPermutationMapsLiveCardToDeadCard;

        const mapped_index = card.index(mapped);
        if (!seen[mapped_index]) {
            seen[mapped_index] = true;
            orbit_mask |= mapped_mask;
            multiplicity += 1;
            if (mapped_index < canonical_index) canonical_index = mapped_index;
        }
    }

    if (multiplicity == 0) return error.EmptyOrbit;
    return .{
        .card = try card.fromIndex(canonical_index),
        .multiplicity = multiplicity,
        .orbit_mask = orbit_mask,
    };
}

fn markOrbitVisited(visited: *[card.deck_count]bool, orbit_mask: u64) void {
    var i: u8 = 0;
    while (i < card.deck_count) : (i += 1) {
        if ((orbit_mask & (@as(u64, 1) << @intCast(i))) != 0) {
            visited[i] = true;
        }
    }
}

fn turnFixedGroup(allocator: Allocator, valid_permutations: []const SuitPermutation, turn: Card) ![]SuitPermutation {
    var group = std.ArrayList(SuitPermutation).empty;
    errdefer group.deinit(allocator);

    const turn_index = card.index(turn);
    for (valid_permutations) |perm| {
        if (card.index(perm.applyCard(turn)) == turn_index) {
            try group.append(allocator, perm);
        }
    }
    if (group.items.len == 0) return error.NoTurnFixedSuitPermutation;
    return group.toOwnedSlice(allocator);
}

fn mapsBoardToItself(board: []const Card, perm: SuitPermutation) !bool {
    const original = try boardMask(board);
    var mapped_cards: [5]Card = undefined;
    if (board.len > mapped_cards.len) return error.BoardTooLarge;
    for (board, 0..) |c, i| {
        mapped_cards[i] = perm.applyCard(c);
    }
    const mapped = try boardMask(mapped_cards[0..board.len]);
    return original == mapped;
}

fn boardMask(board: []const Card) !u64 {
    var result: u64 = 0;
    for (board) |c| {
        const bit = card.mask(c);
        if ((result & bit) != 0) return error.DuplicateBoardCard;
        result |= bit;
    }
    return result;
}

fn preservesRange(range: []const WeightedCombo, perm: SuitPermutation) !bool {
    var lookup = [_]?f32{null} ** 2652;
    for (range) |entry| {
        lookup[entry.combo.canonicalKey()] = entry.weight;
    }
    for (range) |entry| {
        const mapped = try perm.applyCombo(entry.combo);
        const w = lookup[mapped.canonicalKey()];
        if (w == null or w.? != entry.weight) return false;
    }
    return true;
}

fn u32Index(index: usize) !u32 {
    if (index > std.math.maxInt(u32)) return error.IndexTooLarge;
    return @intCast(index);
}

test "rainbow distinct flop has no suit symmetry without symmetric ranges" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(10, 1),
        card.makeCard(7, 2),
    };
    const ranges: [2][]const WeightedCombo = .{ &.{}, &.{} };

    var tables = try buildRunoutTables(std.testing.allocator, flop, ranges);
    defer tables.deinit();

    try std.testing.expectEqual(@as(usize, 1), tables.valid_permutations.len);
    try std.testing.expectEqual(@as(usize, 49), tables.canonical_turns.len);
    try std.testing.expectEqual(@as(usize, 2352), tables.canonical_rivers.len);
    try std.testing.expectEqual(@as(u64, 49), tables.weightedTurnCount());
    try std.testing.expectEqual(@as(u64, 2352), tables.weightedRiverPairCount());
}

test "monotone flop collapses interchangeable off-suits" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(10, 0),
        card.makeCard(7, 0),
    };
    const ranges: [2][]const WeightedCombo = .{ &.{}, &.{} };

    var tables = try buildRunoutTables(std.testing.allocator, flop, ranges);
    defer tables.deinit();

    try std.testing.expectEqual(@as(usize, 6), tables.valid_permutations.len);
    try std.testing.expect(tables.canonical_turns.len < 49);
    try std.testing.expect(tables.canonical_rivers.len < 2352);
    try std.testing.expectEqual(@as(u64, 49), tables.weightedTurnCount());
    try std.testing.expectEqual(@as(u64, 2352), tables.weightedRiverPairCount());
}

test "range asymmetry removes otherwise valid suit swaps" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(10, 0),
        card.makeCard(7, 0),
    };
    const oop_range = [_]WeightedCombo{
        .{
            .combo = try card.Combo.init(card.makeCard(0, 1), card.makeCard(1, 1)),
            .weight = 1.0,
        },
    };
    const ranges: [2][]const WeightedCombo = .{ oop_range[0..], &.{} };

    var tables = try buildRunoutTables(std.testing.allocator, flop, ranges);
    defer tables.deinit();

    try std.testing.expectEqual(@as(usize, 2), tables.valid_permutations.len);
    try std.testing.expectEqual(@as(u64, 49), tables.weightedTurnCount());
    try std.testing.expectEqual(@as(u64, 2352), tables.weightedRiverPairCount());
}

test "duplicate flop cards are rejected" {
    const c = card.makeCard(12, 0);
    const flop = [_]Card{ c, c, card.makeCard(7, 1) };
    const ranges: [2][]const WeightedCombo = .{ &.{}, &.{} };

    try std.testing.expectError(error.DuplicateBoardCard, buildRunoutTables(std.testing.allocator, flop, ranges));
}
