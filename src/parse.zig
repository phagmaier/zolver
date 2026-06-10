const std = @import("std");
const card = @import("card.zig");
const isomorphism = @import("isomorphism.zig");
const game_tree = @import("game_tree.zig");

const Allocator = std.mem.Allocator;
const WeightedCombo = isomorphism.WeightedCombo;
const Sizing = game_tree.Sizing;

const suits = [_]u32{ 0, 1, 2, 3 };

fn rankCharToIndex(c: u8) !u32 {
    return switch (c) {
        '2', '3', '4', '5', '6', '7', '8', '9' => @as(u32, c - '2'),
        'T', 't' => 8,
        'J', 'j' => 9,
        'Q', 'q' => 10,
        'K', 'k' => 11,
        'A', 'a' => 12,
        else => error.InvalidRankChar,
    };
}

fn suitCharToIndex(c: u8) !u32 {
    return switch (c) {
        's', 'S' => 0,
        'h', 'H' => 1,
        'd', 'D' => 2,
        'c', 'C' => 3,
        else => error.InvalidSuitChar,
    };
}

pub fn parseCard(s: []const u8) !card.Card {
    if (s.len != 2) return error.InvalidCardString;
    const rank = try rankCharToIndex(s[0]);
    const suit = try suitCharToIndex(s[1]);
    return card.makeCard(rank, suit);
}

pub fn parseFlop(allocator: Allocator, s: []const u8) ![3]card.Card {
    var cards: [3]card.Card = undefined;
    var it = std.mem.tokenizeAny(u8, s, " ,\t");
    var i: usize = 0;
    while (it.next()) |token| : (i += 1) {
        if (i >= 3) return error.TooManyFlopCards;
        cards[i] = try parseCard(token);
    }
    if (i != 3) return error.NotEnoughFlopCards;
    _ = allocator;
    return cards;
}

pub fn parseSizingPct(pct: u32) Sizing {
    return Sizing.init(pct, 100);
}

pub fn parseSizingList(allocator: Allocator, pcts: []const u32) ![]Sizing {
    const result = try allocator.alloc(Sizing, pcts.len);
    for (pcts, 0..) |p, i| {
        result[i] = parseSizingPct(p);
    }
    return result;
}

/// A single parsed hand class, e.g. AKs / AKo / 88 / AK. Ranks are 0..12
/// (2..A); `suffix` is normalized to 's' (suited), 'o' (offsuit), or null
/// (both). For pairs (`rank1 == rank2`) the suffix is ignored.
const HandSpec = struct { rank1: u32, rank2: u32, suffix: ?u8 };

/// Parse one base hand token ("AKs", "88", "AK") into a `HandSpec`. Does not
/// handle `+` / `-` modifiers — strip those first.
fn parseBaseHand(s: []const u8) !HandSpec {
    if (s.len < 2 or s.len > 3) return error.InvalidHandToken;
    const rank1 = try rankCharToIndex(s[0]);
    const rank2 = try rankCharToIndex(s[1]);
    const suffix: ?u8 = if (s.len == 3) switch (s[2]) {
        's', 'S' => @as(u8, 's'),
        'o', 'O' => @as(u8, 'o'),
        else => return error.InvalidHandSuffix,
    } else null;
    return .{ .rank1 = rank1, .rank2 = rank2, .suffix = suffix };
}

/// Expand a `+` range into its member hand specs, written into `out`.
///
/// Rules (Equilab/Flopzilla convention):
///   - Pairs (`QQ+`): every pair from the given rank up to AA.
///   - Ace-high (`ATs+`, `A2s+`): the Ace is fixed; the kicker climbs to the King.
///   - Otherwise (`T9s+`, `T8s+`): the gap between the two ranks is preserved
///     and both ranks climb together until the top rank reaches the Ace.
fn expandPlus(base: HandSpec, out: *[13]HandSpec) usize {
    var n: usize = 0;
    if (base.rank1 == base.rank2) {
        var r = base.rank1;
        while (r <= 12) : (r += 1) {
            out[n] = .{ .rank1 = r, .rank2 = r, .suffix = null };
            n += 1;
        }
        return n;
    }
    const hi = @max(base.rank1, base.rank2);
    const lo = @min(base.rank1, base.rank2);
    if (hi == 12) {
        var k = lo;
        while (k <= 11) : (k += 1) {
            out[n] = .{ .rank1 = 12, .rank2 = k, .suffix = base.suffix };
            n += 1;
        }
    } else {
        const gap = hi - lo;
        var top = hi;
        while (top <= 12) : (top += 1) {
            out[n] = .{ .rank1 = top, .rank2 = top - gap, .suffix = base.suffix };
            n += 1;
        }
    }
    return n;
}

/// Expand a `A-B` dash range into its member hand specs, written into `out`.
///
/// Both endpoints must describe the same family:
///   - Pairs (`99-66`): every pair between the two ranks.
///   - Same high card (`A5s-A2s`): the high card is fixed, the kicker spans the range.
///   - Same gap (`JTs-87s`): the gap is preserved, the run spans the range.
/// Mismatched families (pair vs non-pair, different suffix, or neither shared
/// high card nor shared gap) are rejected.
fn expandDash(a: HandSpec, b: HandSpec, out: *[13]HandSpec) !usize {
    const a_pair = a.rank1 == a.rank2;
    const b_pair = b.rank1 == b.rank2;
    if (a_pair != b_pair) return error.InvalidHandToken;

    var n: usize = 0;
    if (a_pair) {
        var r = @min(a.rank1, b.rank1);
        const hi = @max(a.rank1, b.rank1);
        while (r <= hi) : (r += 1) {
            out[n] = .{ .rank1 = r, .rank2 = r, .suffix = null };
            n += 1;
        }
        return n;
    }

    if (a.suffix != b.suffix) return error.InvalidHandToken;
    const suffix = a.suffix;
    const hiA = @max(a.rank1, a.rank2);
    const loA = @min(a.rank1, a.rank2);
    const hiB = @max(b.rank1, b.rank2);
    const loB = @min(b.rank1, b.rank2);

    if (hiA == hiB) {
        var k = @min(loA, loB);
        const khi = @max(loA, loB);
        while (k <= khi) : (k += 1) {
            out[n] = .{ .rank1 = hiA, .rank2 = k, .suffix = suffix };
            n += 1;
        }
        return n;
    }

    const gap = hiA - loA;
    if (gap != hiB - loB) return error.InvalidHandToken;
    var top = @min(hiA, hiB);
    const top_hi = @max(hiA, hiB);
    while (top <= top_hi) : (top += 1) {
        out[n] = .{ .rank1 = top, .rank2 = top - gap, .suffix = suffix };
        n += 1;
    }
    return n;
}

/// Emit every concrete combo of a hand class into `list` at the given weight.
fn emitCombos(
    list: *std.ArrayList(WeightedCombo),
    allocator: Allocator,
    rank1: u32,
    rank2: u32,
    suffix: ?u8,
    weight: f32,
) !void {
    var count: u32 = 0;
    var combos: [16]card.Card = undefined;
    var combos2: [16]card.Card = undefined;

    if (rank1 == rank2) {
        count = 6;
        var idx: u32 = 0;
        for (suits[0..3], 0..) |s1, si| {
            for (suits[si + 1 ..]) |s2| {
                combos[idx] = card.makeCard(rank1, s1);
                combos2[idx] = card.makeCard(rank1, s2);
                idx += 1;
            }
        }
    } else if (suffix) |suf| {
        if (suf == 's') {
            count = 4;
            for (suits, 0..) |suit, i| {
                combos[i] = card.makeCard(rank1, suit);
                combos2[i] = card.makeCard(rank2, suit);
            }
        } else { // 'o'
            count = 12;
            var idx: u32 = 0;
            for (suits) |s1| {
                for (suits) |s2| {
                    if (s1 == s2) continue;
                    combos[idx] = card.makeCard(rank1, s1);
                    combos2[idx] = card.makeCard(rank2, s2);
                    idx += 1;
                }
            }
        }
    } else {
        count = 16;
        var idx: u32 = 0;
        for (suits) |s1| {
            for (suits) |s2| {
                combos[idx] = card.makeCard(rank1, s1);
                combos2[idx] = card.makeCard(rank2, s2);
                idx += 1;
            }
        }
    }

    for (0..count) |i| {
        const combo = try card.Combo.init(combos[i], combos2[i]);
        try list.append(allocator, .{ .combo = combo, .weight = weight });
    }
}

pub fn parseRange(allocator: Allocator, s: []const u8) ![]WeightedCombo {
    var list = try std.ArrayList(WeightedCombo).initCapacity(allocator, 16);
    errdefer list.deinit(allocator);

    var it = std.mem.tokenizeScalar(u8, s, ',');
    while (it.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t");
        if (token.len == 0) continue;

        const colon_pos = std.mem.indexOfScalar(u8, token, ':');
        const hand_part = std.mem.trim(u8, if (colon_pos) |pos| token[0..pos] else token, " \t");
        const weight_str = if (colon_pos) |pos| token[pos + 1 ..] else null;

        const weight: f32 = if (weight_str) |ws| blk: {
            const w = try std.fmt.parseFloat(f32, ws);
            if (!std.math.isFinite(w) or w < 0) return error.InvalidWeight;
            if (w > 1.0) return error.InvalidWeight;
            break :blk w;
        } else 1.0;

        if (weight <= 0) continue;

        // Expand the hand class (single, `+`, or `-`) into its member specs.
        var specs: [13]HandSpec = undefined;
        var nspecs: usize = 0;
        if (hand_part.len > 0 and hand_part[hand_part.len - 1] == '+') {
            const base = try parseBaseHand(hand_part[0 .. hand_part.len - 1]);
            nspecs = expandPlus(base, &specs);
        } else if (std.mem.indexOfScalar(u8, hand_part, '-')) |dash| {
            const lhs = try parseBaseHand(std.mem.trim(u8, hand_part[0..dash], " \t"));
            const rhs = try parseBaseHand(std.mem.trim(u8, hand_part[dash + 1 ..], " \t"));
            nspecs = try expandDash(lhs, rhs, &specs);
        } else {
            specs[0] = try parseBaseHand(hand_part);
            nspecs = 1;
        }

        for (specs[0..nspecs]) |sp| {
            try emitCombos(&list, allocator, sp.rank1, sp.rank2, sp.suffix, weight);
        }
    }

    return list.toOwnedSlice(allocator);
}

test "parseCard valid" {
    const c = try parseCard("As");
    try std.testing.expectEqual(@as(u32, 12), card.rankIndex(c));
    try std.testing.expectEqual(@as(u32, 0), card.suitIndex(c));

    const c2 = try parseCard("2c");
    try std.testing.expectEqual(@as(u32, 0), card.rankIndex(c2));
    try std.testing.expectEqual(@as(u32, 3), card.suitIndex(c2));

    const c3 = try parseCard("Th");
    try std.testing.expectEqual(@as(u32, 8), card.rankIndex(c3));
    try std.testing.expectEqual(@as(u32, 1), card.suitIndex(c3));
}

test "parseCard case insensitive" {
    const c1 = try parseCard("as");
    try std.testing.expectEqual(@as(u32, 12), card.rankIndex(c1));
    try std.testing.expectEqual(@as(u32, 0), card.suitIndex(c1));

    const c2 = try parseCard("AS");
    try std.testing.expectEqual(@as(u32, 12), card.rankIndex(c2));
    try std.testing.expectEqual(@as(u32, 0), card.suitIndex(c2));
}

test "parseCard invalid" {
    try std.testing.expectError(error.InvalidCardString, parseCard("A"));
    try std.testing.expectError(error.InvalidCardString, parseCard("AsKd"));
    try std.testing.expectError(error.InvalidRankChar, parseCard("Xs"));
    try std.testing.expectError(error.InvalidSuitChar, parseCard("Ax"));
    try std.testing.expectError(error.InvalidRankChar, parseCard("1s"));
}

test "parseFlop valid" {
    const flop = try parseFlop(std.testing.allocator, "As Kh 7d");
    try std.testing.expectEqual(@as(u32, 12), card.rankIndex(flop[0]));
    try std.testing.expectEqual(@as(u32, 0), card.suitIndex(flop[0]));
    try std.testing.expectEqual(@as(u32, 11), card.rankIndex(flop[1]));
    try std.testing.expectEqual(@as(u32, 1), card.suitIndex(flop[1]));
    try std.testing.expectEqual(@as(u32, 5), card.rankIndex(flop[2]));
    try std.testing.expectEqual(@as(u32, 2), card.suitIndex(flop[2]));
}

test "parseFlop comma separated" {
    const flop = try parseFlop(std.testing.allocator, "As,Kh,7d");
    try std.testing.expectEqual(@as(u32, 12), card.rankIndex(flop[0]));
    try std.testing.expectEqual(@as(u32, 11), card.rankIndex(flop[1]));
    try std.testing.expectEqual(@as(u32, 5), card.rankIndex(flop[2]));
}

test "parseFlop too few" {
    try std.testing.expectError(error.NotEnoughFlopCards, parseFlop(std.testing.allocator, "As Kh"));
}

test "parseFlop too many" {
    try std.testing.expectError(error.TooManyFlopCards, parseFlop(std.testing.allocator, "As Kh 7d 2c"));
}

test "parseSizingPct" {
    const s = parseSizingPct(25);
    try std.testing.expectEqual(@as(u32, 25), s.numerator);
    try std.testing.expectEqual(@as(u32, 100), s.denominator);

    const s2 = parseSizingPct(150);
    try std.testing.expectEqual(@as(u32, 150), s2.numerator);
    try std.testing.expectEqual(@as(u32, 100), s2.denominator);
}

test "parseRange pocket pair" {
    const results = try parseRange(std.testing.allocator, "AA:0.5");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 6), results.len);
    for (results) |r| {
        try std.testing.expectEqual(@as(f32, 0.5), r.weight);
        try std.testing.expectEqual(@as(u32, 12), card.rankIndex(r.combo.first));
        try std.testing.expectEqual(@as(u32, 12), card.rankIndex(r.combo.second));
    }
}

test "parseRange suited" {
    const results = try parseRange(std.testing.allocator, "AKs:0.75");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 4), results.len);
    for (results) |r| {
        try std.testing.expectEqual(@as(f32, 0.75), r.weight);
        const ranks = [_]u32{ card.rankIndex(r.combo.first), card.rankIndex(r.combo.second) };
        try std.testing.expect((ranks[0] == 12 and ranks[1] == 11) or (ranks[0] == 11 and ranks[1] == 12));
        try std.testing.expectEqual(card.suitIndex(r.combo.first), card.suitIndex(r.combo.second));
    }
}

test "parseRange offsuit" {
    const results = try parseRange(std.testing.allocator, "AKo:0.5");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 12), results.len);
    for (results) |r| {
        try std.testing.expectEqual(@as(f32, 0.5), r.weight);
        const ranks = [_]u32{ card.rankIndex(r.combo.first), card.rankIndex(r.combo.second) };
        try std.testing.expect((ranks[0] == 12 and ranks[1] == 11) or (ranks[0] == 11 and ranks[1] == 12));
        try std.testing.expect(card.suitIndex(r.combo.first) != card.suitIndex(r.combo.second));
    }
}

test "parseRange unsuffixed non-pair" {
    const results = try parseRange(std.testing.allocator, "AK");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 16), results.len);
    for (results) |r| {
        try std.testing.expectEqual(@as(f32, 1.0), r.weight);
        const ranks = [_]u32{ card.rankIndex(r.combo.first), card.rankIndex(r.combo.second) };
        try std.testing.expect((ranks[0] == 12 and ranks[1] == 11) or (ranks[0] == 11 and ranks[1] == 12));
    }
}

test "parseRange unsuffixed pair" {
    const results = try parseRange(std.testing.allocator, "88");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 6), results.len);
    for (results) |r| {
        try std.testing.expectEqual(@as(f32, 1.0), r.weight);
        try std.testing.expectEqual(@as(u32, 6), card.rankIndex(r.combo.first));
        try std.testing.expectEqual(@as(u32, 6), card.rankIndex(r.combo.second));
    }
}

test "parseRange default weight" {
    const results = try parseRange(std.testing.allocator, "AKs");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 4), results.len);
    for (results) |r| {
        try std.testing.expectEqual(@as(f32, 1.0), r.weight);
    }
}

test "parseRange multiple hands" {
    const results = try parseRange(std.testing.allocator, "AJo:0.75, ATo:0.12, 88:0.5");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 30), results.len);
}

test "parseRange with spaces" {
    const results = try parseRange(std.testing.allocator, " AJo:0.75 , ATo , 88:0.5 ");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 30), results.len);
}

test "parseRange zero weight" {
    const results = try parseRange(std.testing.allocator, "AK:0.0, QQ:0.5");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 6), results.len);
    for (results) |r| {
        try std.testing.expectEqual(@as(u32, 10), card.rankIndex(r.combo.first));
        try std.testing.expectEqual(@as(u32, 10), card.rankIndex(r.combo.second));
        try std.testing.expectEqual(@as(f32, 0.5), r.weight);
    }
}

test "parseRange empty" {
    const results = try parseRange(std.testing.allocator, "");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "parseRange pair with suffix ignored" {
    const results = try parseRange(std.testing.allocator, "AAs:0.5");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 6), results.len);
    for (results) |r| {
        try std.testing.expectEqual(@as(f32, 0.5), r.weight);
        try std.testing.expectEqual(@as(u32, 12), card.rankIndex(r.combo.first));
        try std.testing.expectEqual(@as(u32, 12), card.rankIndex(r.combo.second));
    }
}

test "parseRange lower rank first" {
    const results = try parseRange(std.testing.allocator, "KA:0.5");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 16), results.len);
    for (results) |r| {
        try std.testing.expectEqual(@as(f32, 0.5), r.weight);
    }
}

test "parseRange weight out of range" {
    try std.testing.expectError(error.InvalidWeight, parseRange(std.testing.allocator, "AK:1.5"));
    try std.testing.expectError(error.InvalidWeight, parseRange(std.testing.allocator, "AK:-0.5"));
    try std.testing.expectError(error.InvalidWeight, parseRange(std.testing.allocator, "AK:inf"));
}

test "parseRange invalid hand" {
    try std.testing.expectError(error.InvalidHandSuffix, parseRange(std.testing.allocator, "AKx:0.5"));
    try std.testing.expectError(error.InvalidRankChar, parseRange(std.testing.allocator, "XY:0.5"));
    try std.testing.expectError(error.InvalidHandToken, parseRange(std.testing.allocator, "A"));
}

test "parseRange duplicate combos get last weight" {
    const results = try parseRange(std.testing.allocator, "AKs, AKs:0.5");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 8), results.len);
    try std.testing.expectEqual(@as(f32, 1.0), results[0].weight);
    try std.testing.expectEqual(@as(f32, 0.5), results[4].weight);
}

test "parseRange plus: pairs" {
    const results = try parseRange(std.testing.allocator, "QQ+");
    defer std.testing.allocator.free(results);
    // QQ, KK, AA = 3 pairs * 6 combos.
    try std.testing.expectEqual(@as(usize, 18), results.len);
    for (results) |r| {
        try std.testing.expectEqual(card.rankIndex(r.combo.first), card.rankIndex(r.combo.second));
        const rk = card.rankIndex(r.combo.first);
        try std.testing.expect(rk == 10 or rk == 11 or rk == 12);
    }
}

test "parseRange plus: all pairs" {
    const results = try parseRange(std.testing.allocator, "22+");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 13 * 6), results.len);
}

test "parseRange plus: ace-high suited fixes the ace" {
    const results = try parseRange(std.testing.allocator, "ATs+");
    defer std.testing.allocator.free(results);
    // ATs, AJs, AQs, AKs = 4 suited * 4 combos.
    try std.testing.expectEqual(@as(usize, 16), results.len);
    for (results) |r| {
        const r1 = card.rankIndex(r.combo.first);
        const r2 = card.rankIndex(r.combo.second);
        const hi = @max(r1, r2);
        const lo = @min(r1, r2);
        try std.testing.expectEqual(@as(u32, 12), hi);
        try std.testing.expect(lo >= 8 and lo <= 11);
        try std.testing.expectEqual(card.suitIndex(r.combo.first), card.suitIndex(r.combo.second));
    }
}

test "parseRange plus: ace-low suited spans to the king" {
    const results = try parseRange(std.testing.allocator, "A2s+");
    defer std.testing.allocator.free(results);
    // A2s..AKs = 12 suited * 4 combos.
    try std.testing.expectEqual(@as(usize, 48), results.len);
}

test "parseRange plus: offsuit" {
    const results = try parseRange(std.testing.allocator, "AJo+");
    defer std.testing.allocator.free(results);
    // AJo, AQo, AKo = 3 offsuit * 12 combos.
    try std.testing.expectEqual(@as(usize, 36), results.len);
}

test "parseRange plus: connectors preserve the gap" {
    const results = try parseRange(std.testing.allocator, "T9s+");
    defer std.testing.allocator.free(results);
    // T9s, JTs, QJs, KQs, AKs = 5 suited * 4 combos.
    try std.testing.expectEqual(@as(usize, 20), results.len);
    for (results) |r| {
        const r1 = card.rankIndex(r.combo.first);
        const r2 = card.rankIndex(r.combo.second);
        try std.testing.expectEqual(@as(u32, 1), @max(r1, r2) - @min(r1, r2));
    }
}

test "parseRange plus: one-gappers preserve the gap" {
    const results = try parseRange(std.testing.allocator, "T8s+");
    defer std.testing.allocator.free(results);
    // T8s, J9s, QTs, KJs, AQs = 5 suited * 4 combos.
    try std.testing.expectEqual(@as(usize, 20), results.len);
    for (results) |r| {
        const r1 = card.rankIndex(r.combo.first);
        const r2 = card.rankIndex(r.combo.second);
        try std.testing.expectEqual(@as(u32, 2), @max(r1, r2) - @min(r1, r2));
    }
}

test "parseRange plus: carries weight" {
    const results = try parseRange(std.testing.allocator, "QQ+:0.5");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 18), results.len);
    for (results) |r| try std.testing.expectEqual(@as(f32, 0.5), r.weight);
}

test "parseRange dash: pairs" {
    const results = try parseRange(std.testing.allocator, "99-66");
    defer std.testing.allocator.free(results);
    // 66, 77, 88, 99 = 4 pairs * 6 combos.
    try std.testing.expectEqual(@as(usize, 24), results.len);
    for (results) |r| {
        const rk = card.rankIndex(r.combo.first);
        try std.testing.expect(rk >= 4 and rk <= 7);
    }
}

test "parseRange dash: pairs reversed bounds" {
    const results = try parseRange(std.testing.allocator, "66-99");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 24), results.len);
}

test "parseRange dash: same high card varies the kicker" {
    const results = try parseRange(std.testing.allocator, "A5s-A2s");
    defer std.testing.allocator.free(results);
    // A2s, A3s, A4s, A5s = 4 suited * 4 combos.
    try std.testing.expectEqual(@as(usize, 16), results.len);
    for (results) |r| {
        const r1 = card.rankIndex(r.combo.first);
        const r2 = card.rankIndex(r.combo.second);
        try std.testing.expectEqual(@as(u32, 12), @max(r1, r2));
        try std.testing.expect(@min(r1, r2) >= 0 and @min(r1, r2) <= 3);
    }
}

test "parseRange dash: connector run preserves the gap" {
    const results = try parseRange(std.testing.allocator, "JTs-87s");
    defer std.testing.allocator.free(results);
    // JTs, T9s, 98s, 87s = 4 suited * 4 combos.
    try std.testing.expectEqual(@as(usize, 16), results.len);
    for (results) |r| {
        const r1 = card.rankIndex(r.combo.first);
        const r2 = card.rankIndex(r.combo.second);
        try std.testing.expectEqual(@as(u32, 1), @max(r1, r2) - @min(r1, r2));
    }
}

test "parseRange dash: invalid combinations" {
    // Pair vs non-pair.
    try std.testing.expectError(error.InvalidHandToken, parseRange(std.testing.allocator, "88-AKs"));
    // Suffix mismatch.
    try std.testing.expectError(error.InvalidHandToken, parseRange(std.testing.allocator, "87s-AKo"));
    // Neither shared high card nor shared gap.
    try std.testing.expectError(error.InvalidHandToken, parseRange(std.testing.allocator, "T9s-A8s"));
}

test "parseRange mixed standard export line" {
    const results = try parseRange(std.testing.allocator, "QQ+, AKs, AQs+, AJo+, T9s+");
    defer std.testing.allocator.free(results);
    // QQ+ (18) + AKs (4) + AQs+ {AQs,AKs} (8) + AJo+ {AJo,AQo,AKo} (36) + T9s+ (20).
    try std.testing.expectEqual(@as(usize, 18 + 4 + 8 + 36 + 20), results.len);
}

test "parseSizingList" {
    const list = try parseSizingList(std.testing.allocator, &.{ 25, 50, 75 });
    defer std.testing.allocator.free(list);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(@as(u32, 25), list[0].numerator);
    try std.testing.expectEqual(@as(u32, 50), list[1].numerator);
    try std.testing.expectEqual(@as(u32, 75), list[2].numerator);
}
