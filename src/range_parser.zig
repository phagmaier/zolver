// PokerStove-style range and board parser.
//
// Accepts the subset of PokerStove notation that ~every solver speaks. Tokens
// are separated by commas and/or whitespace; `#` starts a line comment.
//
//   Pairs:           AA, KK, ..., 22
//   Suited:          AKs, T9s
//   Offsuit:         AKo, KJo
//   Plus modifier:   JJ+, T9s+, KQo+
//   Range modifier:  22-77, T9s-65s, KQo-J9o
//   Specific combo:  AhKs, 7d7c   (suits are case-insensitive)
//   Weight suffix:   AA:0.75, AKs:0.5  (default 1.0; last write wins)
//
// Deliberately rejected:
//
//   * Bare two-rank tokens without an `s`/`o` suffix (e.g. `AK`). The
//     ambiguity between "suited + offsuit" and "just one" trips users up;
//     forcing `AKs` / `AKo` keeps intent explicit.
//
// Duplicate-token semantics: last write wins. `"AA, AA:0.5"` ends up with
// AA at weight 0.5. Combos that resolve to weight 0 are dropped from the
// returned sparse `Range`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const card_mod = @import("card.zig");
const Card = card_mod.Card;

const range_mod = @import("range.zig");
const Range = range_mod.Range;
const Hand = range_mod.Hand;
const HandTable = range_mod.HandTable;

const NUM_HANDS: usize = 1326;
const NUM_RANKS: u8 = 13;
const NUM_SUITS: u8 = 4;

pub const ParseError = error{
    EmptyInput,
    InvalidRank,
    InvalidSuit,
    InvalidCardLiteral,
    AmbiguousBareHand, // e.g. "AK" without s/o suffix
    UnknownToken,
    InvalidWeight,
    WeightOutOfRange,
    DuplicateCardInHand,        // e.g. "AhAh" or "AhKs" with same card twice
    PlusModifierOnSpecificCombo, // "AhKs+" doesn't make sense
    PlusModifierOnHighestPair,  // "AA+" has nothing above it
    RangeEndpointMismatch,      // "T9s-AKs" — different gaps; "22-AKs" — different shapes
    RangeEndpointInverted,      // "77-22" — high then low
    BoardWrongLength,           // parseBoard expects 3/4/5 cards
    OutOfMemory,
};

// -----------------------------------------------------------------------------
// Public API
// -----------------------------------------------------------------------------

/// Parse a range expression into a sparse `Range`. The `HandTable` provides
/// the canonical hand→index map and is borrowed (not retained).
pub fn parseRange(text: []const u8, hand_table: *const HandTable, allocator: Allocator) ParseError!Range {
    // Dense scratch buffer over canonical hand indices. We do last-write-wins
    // here and compact to a sparse Range at the end. A 1326-byte presence
    // mask sits alongside so weight=0 entries written by the user are
    // distinguishable from "untouched" — but in our compact step we drop
    // weight=0 entries anyway, so the presence mask is just for paranoia.
    var weights: [NUM_HANDS]f32 = @splat(0);

    var it = Tokenizer{ .text = text, .pos = 0 };
    var saw_any: bool = false;
    while (try it.next()) |tok| {
        saw_any = true;
        try applyToken(tok, hand_table, &weights);
    }
    if (!saw_any) return ParseError.EmptyInput;

    // Compact dense → sparse. Stable order: ascending canonical hand index.
    var count: usize = 0;
    for (weights) |w| {
        if (w > 0) count += 1;
    }

    var range = try Range.initEmpty(allocator, count);
    errdefer range.deinit(allocator);

    var out_idx: usize = 0;
    for (weights, 0..) |w, i| {
        if (w > 0) {
            range.active_indices[out_idx] = @intCast(i);
            range.probs[out_idx] = w;
            out_idx += 1;
        }
    }
    std.debug.assert(out_idx == count);
    return range;
}

/// Parse a single card literal like "Ah", "Ks", "tD" (case-insensitive suit).
pub fn parseCard(text: []const u8) ParseError!Card {
    if (text.len != 2) return ParseError.InvalidCardLiteral;
    const rank = try parseRank(text[0]);
    const suit = try parseSuit(text[1]);
    return card_mod.makeCard(rank, suit);
}

/// Parse a board string of 6/8/10 hex-ish chars (3, 4, or 5 cards
/// concatenated, e.g. "AhKsQd" or "AhKsQd2c" or "AhKsQd2c5h"). Returns a
/// fixed `[5]Card` array; trailing slots are zero-filled for partial boards
/// (matching the engine's representation).
pub fn parseBoard(text: []const u8) ParseError![5]Card {
    if (text.len != 6 and text.len != 8 and text.len != 10) {
        return ParseError.BoardWrongLength;
    }
    var board: [5]Card = .{ 0, 0, 0, 0, 0 };
    var i: usize = 0;
    var slot: usize = 0;
    while (i < text.len) : (i += 2) {
        board[slot] = try parseCard(text[i .. i + 2]);
        slot += 1;
    }
    return board;
}

// -----------------------------------------------------------------------------
// Tokenizer
// -----------------------------------------------------------------------------

const Token = struct {
    range_expr: []const u8, // the part before any `:` weight
    weight: f32,
};

const Tokenizer = struct {
    text: []const u8,
    pos: usize,

    fn next(self: *Tokenizer) ParseError!?Token {
        self.skipSeparators();
        if (self.pos >= self.text.len) return null;

        const start = self.pos;
        while (self.pos < self.text.len) : (self.pos += 1) {
            const c = self.text[self.pos];
            if (isSeparator(c) or c == '#') break;
        }
        const raw = self.text[start..self.pos];

        // Split off optional `:weight`. We only treat the FIRST colon as the
        // separator — there's no nested syntax that uses colons.
        var range_expr: []const u8 = raw;
        var weight: f32 = 1.0;
        if (std.mem.indexOfScalar(u8, raw, ':')) |colon_idx| {
            range_expr = raw[0..colon_idx];
            const weight_text = raw[colon_idx + 1 ..];
            weight = std.fmt.parseFloat(f32, weight_text) catch return ParseError.InvalidWeight;
            if (!(weight >= 0.0 and weight <= 1.0)) return ParseError.WeightOutOfRange;
        }
        if (range_expr.len == 0) return ParseError.UnknownToken;

        return Token{ .range_expr = range_expr, .weight = weight };
    }

    fn skipSeparators(self: *Tokenizer) void {
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (c == '#') {
                // Comment: skip to newline or EOF.
                while (self.pos < self.text.len and self.text[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else if (isSeparator(c)) {
                self.pos += 1;
            } else {
                break;
            }
        }
    }
};

fn isSeparator(c: u8) bool {
    return c == ',' or c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

// -----------------------------------------------------------------------------
// Token → combo expansion
// -----------------------------------------------------------------------------

const HandShape = enum { pair, suited, offsuit, specific };

const ParsedHand = union(HandShape) {
    pair: u8, // rank 0-12
    suited: struct { hi: u8, lo: u8 }, // hi > lo, ranks 0-12
    offsuit: struct { hi: u8, lo: u8 },
    specific: struct { c1: Card, c2: Card }, // already canonicalized via Hand.init
};

fn applyToken(tok: Token, hand_table: *const HandTable, weights: *[NUM_HANDS]f32) ParseError!void {
    const raw = tok.range_expr;
    if (raw.len == 0) return ParseError.UnknownToken;

    // Range modifier: `XY-ZW`. Detect by interior `-` (not leading minus on a
    // weight, since that's caught at the weight parser).
    if (std.mem.indexOfScalar(u8, raw, '-')) |dash_idx| {
        if (dash_idx == 0 or dash_idx == raw.len - 1) return ParseError.UnknownToken;
        const lhs = raw[0..dash_idx];
        const rhs = raw[dash_idx + 1 ..];
        return applyRangeModifier(lhs, rhs, tok.weight, hand_table, weights);
    }

    // Plus modifier: `XY+`.
    if (raw[raw.len - 1] == '+') {
        return applyPlusModifier(raw[0 .. raw.len - 1], tok.weight, hand_table, weights);
    }

    // Single hand / specific combo. Resolve and emit.
    const parsed = try parseHandExpr(raw);
    try emitHand(parsed, tok.weight, hand_table, weights);
}

fn parseHandExpr(raw: []const u8) ParseError!ParsedHand {
    // 4-char specific combo: rank suit rank suit (e.g. "AhKs").
    if (raw.len == 4) {
        const c1 = try parseCard(raw[0..2]);
        const c2 = try parseCard(raw[2..4]);
        if (c1 == c2) return ParseError.DuplicateCardInHand;
        return ParsedHand{ .specific = .{ .c1 = c1, .c2 = c2 } };
    }

    // 2/3-char rank-only forms.
    if (raw.len == 2) {
        const r1 = try parseRank(raw[0]);
        const r2 = try parseRank(raw[1]);
        if (r1 != r2) return ParseError.AmbiguousBareHand;
        return ParsedHand{ .pair = r1 };
    }
    if (raw.len == 3) {
        const r1 = try parseRank(raw[0]);
        const r2 = try parseRank(raw[1]);
        if (r1 == r2) return ParseError.UnknownToken; // "AAs" is nonsense
        const suffix = std.ascii.toLower(raw[2]);
        const hi = @max(r1, r2);
        const lo = @min(r1, r2);
        return switch (suffix) {
            's' => ParsedHand{ .suited = .{ .hi = hi, .lo = lo } },
            'o' => ParsedHand{ .offsuit = .{ .hi = hi, .lo = lo } },
            else => ParseError.UnknownToken,
        };
    }

    return ParseError.UnknownToken;
}

fn applyPlusModifier(
    base_raw: []const u8,
    weight: f32,
    hand_table: *const HandTable,
    weights: *[NUM_HANDS]f32,
) ParseError!void {
    const base = try parseHandExpr(base_raw);
    switch (base) {
        .specific => return ParseError.PlusModifierOnSpecificCombo,
        .pair => |r| {
            // "JJ+" → JJ, QQ, KK, AA.
            if (r > 12) unreachable;
            var x: u8 = r;
            while (x <= 12) : (x += 1) {
                try emitHand(.{ .pair = x }, weight, hand_table, weights);
            }
        },
        .suited => |s| try emitPlusSuited(s.hi, s.lo, weight, hand_table, weights, true),
        .offsuit => |s| try emitPlusSuited(s.hi, s.lo, weight, hand_table, weights, false),
    }
}

// PokerStove `+` semantics for non-pair tokens:
//
//   * Hi-rank == A (ace-high special case): hold A fixed, raise the low card.
//     "AJs+" → {AJs, AQs, AKs}.  This is what users actually want when they
//     write "ace-rag plus" — the alternative (gap-fixed) would give just AJs
//     and make the `+` pointless.
//
//   * Hi-rank < A (gap-fixed): hold the lo-hi gap and raise the hi-rank.
//     "T9s+" → {T9s, JTs, QJs, KQs, AKs}.  "KJs+" → {KJs, AQs} (gap 2).
//
// Users who want "K fixed, raise lo" (e.g. {KJs, KQs}) must list them out.
fn emitPlusSuited(
    hi: u8,
    lo: u8,
    weight: f32,
    hand_table: *const HandTable,
    weights: *[NUM_HANDS]f32,
    is_suited: bool,
) ParseError!void {
    if (hi == 12) {
        // Ace-high: raise lo to A-1.
        var l: u8 = lo;
        while (l < 12) : (l += 1) {
            if (is_suited) {
                try emitHand(.{ .suited = .{ .hi = 12, .lo = l } }, weight, hand_table, weights);
            } else {
                try emitHand(.{ .offsuit = .{ .hi = 12, .lo = l } }, weight, hand_table, weights);
            }
        }
    } else {
        // Non-ace: gap-fixed, raise hi to A.
        const gap = hi - lo;
        var h: u8 = hi;
        while (h <= 12) : (h += 1) {
            if (is_suited) {
                try emitHand(.{ .suited = .{ .hi = h, .lo = h - gap } }, weight, hand_table, weights);
            } else {
                try emitHand(.{ .offsuit = .{ .hi = h, .lo = h - gap } }, weight, hand_table, weights);
            }
        }
    }
}

fn applyRangeModifier(
    lhs_raw: []const u8,
    rhs_raw: []const u8,
    weight: f32,
    hand_table: *const HandTable,
    weights: *[NUM_HANDS]f32,
) ParseError!void {
    const lhs = try parseHandExpr(lhs_raw);
    const rhs = try parseHandExpr(rhs_raw);

    // Shapes must match: pair-pair, suited-suited, or offsuit-offsuit.
    // Specific-combo endpoints aren't meaningful for ranges.
    if (@as(HandShape, lhs) != @as(HandShape, rhs)) {
        return ParseError.RangeEndpointMismatch;
    }
    switch (lhs) {
        .pair => |lo_rank| {
            // "22-77": ascending pair list. Allow inverted order ("77-22")?
            // Convention says always low-to-high; reject inverted.
            const hi_rank = rhs.pair;
            if (hi_rank < lo_rank) return ParseError.RangeEndpointInverted;
            var r: u8 = lo_rank;
            while (r <= hi_rank) : (r += 1) {
                try emitHand(.{ .pair = r }, weight, hand_table, weights);
            }
        },
        .suited => |hi_pair| {
            // "T9s-65s": same gap, descending hi-rank. Endpoint with the
            // larger hi-rank goes first by convention.
            const lo_pair = rhs.suited;
            const lhs_gap = hi_pair.hi - hi_pair.lo;
            const rhs_gap = lo_pair.hi - lo_pair.lo;
            if (lhs_gap != rhs_gap) return ParseError.RangeEndpointMismatch;
            if (hi_pair.hi < lo_pair.hi) return ParseError.RangeEndpointInverted;
            var hi: u8 = lo_pair.hi;
            while (hi <= hi_pair.hi) : (hi += 1) {
                try emitHand(.{ .suited = .{ .hi = hi, .lo = hi - lhs_gap } }, weight, hand_table, weights);
            }
        },
        .offsuit => |hi_pair| {
            const lo_pair = rhs.offsuit;
            const lhs_gap = hi_pair.hi - hi_pair.lo;
            const rhs_gap = lo_pair.hi - lo_pair.lo;
            if (lhs_gap != rhs_gap) return ParseError.RangeEndpointMismatch;
            if (hi_pair.hi < lo_pair.hi) return ParseError.RangeEndpointInverted;
            var hi: u8 = lo_pair.hi;
            while (hi <= hi_pair.hi) : (hi += 1) {
                try emitHand(.{ .offsuit = .{ .hi = hi, .lo = hi - lhs_gap } }, weight, hand_table, weights);
            }
        },
        .specific => return ParseError.RangeEndpointMismatch,
    }
}

fn emitHand(
    hand: ParsedHand,
    weight: f32,
    hand_table: *const HandTable,
    weights: *[NUM_HANDS]f32,
) ParseError!void {
    switch (hand) {
        .pair => |r| {
            // 6 combos: pick two distinct suits.
            var s1: u8 = 0;
            while (s1 < NUM_SUITS) : (s1 += 1) {
                var s2: u8 = s1 + 1;
                while (s2 < NUM_SUITS) : (s2 += 1) {
                    try setOne(r, s1, r, s2, weight, hand_table, weights);
                }
            }
        },
        .suited => |s| {
            // 4 combos: same suit on both cards.
            var su: u8 = 0;
            while (su < NUM_SUITS) : (su += 1) {
                try setOne(s.hi, su, s.lo, su, weight, hand_table, weights);
            }
        },
        .offsuit => |s| {
            // 12 combos: 4 hi-suits × 3 different lo-suits.
            var s1: u8 = 0;
            while (s1 < NUM_SUITS) : (s1 += 1) {
                var s2: u8 = 0;
                while (s2 < NUM_SUITS) : (s2 += 1) {
                    if (s1 == s2) continue;
                    try setOne(s.hi, s1, s.lo, s2, weight, hand_table, weights);
                }
            }
        },
        .specific => |sp| {
            const h = Hand.init(sp.c1, sp.c2);
            const idx = hand_table.getIndex(h) orelse return ParseError.InvalidCardLiteral;
            weights[idx] = weight;
        },
    }
}

fn setOne(
    r1: u8,
    s1: u8,
    r2: u8,
    s2: u8,
    weight: f32,
    hand_table: *const HandTable,
    weights: *[NUM_HANDS]f32,
) ParseError!void {
    const c1 = card_mod.makeCard(r1, s1);
    const c2 = card_mod.makeCard(r2, s2);
    if (c1 == c2) return ParseError.DuplicateCardInHand;
    const h = Hand.init(c1, c2);
    const idx = hand_table.getIndex(h) orelse return ParseError.InvalidCardLiteral;
    weights[idx] = weight;
}

fn parseRank(c: u8) ParseError!u8 {
    return switch (std.ascii.toUpper(c)) {
        '2' => 0,
        '3' => 1,
        '4' => 2,
        '5' => 3,
        '6' => 4,
        '7' => 5,
        '8' => 6,
        '9' => 7,
        'T' => 8,
        'J' => 9,
        'Q' => 10,
        'K' => 11,
        'A' => 12,
        else => ParseError.InvalidRank,
    };
}

fn parseSuit(c: u8) ParseError!u8 {
    return switch (std.ascii.toLower(c)) {
        's' => 0, // SPADE — see card.zig
        'h' => 1, // HEART
        'd' => 2, // DIAMOND
        'c' => 3, // CLUB
        else => ParseError.InvalidSuit,
    };
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

fn rangeWeight(r: Range, hand_idx: u16) f32 {
    for (r.active_indices, r.probs) |i, p| {
        if (i == hand_idx) return p;
    }
    return 0.0;
}

test "parseCard accepts lower- and uppercase suits" {
    const a = try parseCard("Ah");
    const b = try parseCard("AH");
    try testing.expectEqual(a, b);
}

test "parseCard rejects bad input" {
    try testing.expectError(ParseError.InvalidCardLiteral, parseCard("A"));
    try testing.expectError(ParseError.InvalidCardLiteral, parseCard("AKs"));
    try testing.expectError(ParseError.InvalidRank, parseCard("Xh"));
    try testing.expectError(ParseError.InvalidSuit, parseCard("Az"));
}

test "parseBoard handles flop / turn / river boards" {
    const flop = try parseBoard("AhKsQd");
    try testing.expect(flop[0] != 0 and flop[1] != 0 and flop[2] != 0);
    try testing.expectEqual(@as(Card, 0), flop[3]);
    try testing.expectEqual(@as(Card, 0), flop[4]);

    const turn = try parseBoard("AhKsQd2c");
    try testing.expect(turn[3] != 0);
    try testing.expectEqual(@as(Card, 0), turn[4]);

    const river = try parseBoard("AhKsQd2c5h");
    try testing.expect(river[4] != 0);

    try testing.expectError(ParseError.BoardWrongLength, parseBoard(""));
    try testing.expectError(ParseError.BoardWrongLength, parseBoard("Ah"));
    try testing.expectError(ParseError.BoardWrongLength, parseBoard("AhKs"));
}

test "parseRange: AA expands to 6 combos at weight 1" {
    const ht = HandTable.init();
    var r = try parseRange("AA", &ht, testing.allocator);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6), r.active_indices.len);
    for (r.probs) |p| try testing.expectEqual(@as(f32, 1.0), p);
}

test "parseRange: AKs is 4 combos, AKo is 12, JJ+ is 24" {
    const ht = HandTable.init();
    {
        var r = try parseRange("AKs", &ht, testing.allocator);
        defer r.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 4), r.active_indices.len);
    }
    {
        var r = try parseRange("AKo", &ht, testing.allocator);
        defer r.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 12), r.active_indices.len);
    }
    {
        // JJ+ = {JJ, QQ, KK, AA} = 4 pairs × 6 combos.
        var r = try parseRange("JJ+", &ht, testing.allocator);
        defer r.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 24), r.active_indices.len);
    }
}

test "parseRange: bare AK is rejected as ambiguous" {
    const ht = HandTable.init();
    try testing.expectError(ParseError.AmbiguousBareHand, parseRange("AK", &ht, testing.allocator));
}

test "parseRange: T9s+ enumerates connectors up to AKs" {
    const ht = HandTable.init();
    var r = try parseRange("T9s+", &ht, testing.allocator);
    defer r.deinit(testing.allocator);
    // T9s, JTs, QJs, KQs, AKs = 5 suited hands × 4 combos.
    try testing.expectEqual(@as(usize, 20), r.active_indices.len);
}

test "parseRange: ace-high + holds A and raises lo" {
    // PokerStove convention: AJs+ → {AJs, AQs, AKs}, not just {AJs}.
    const ht = HandTable.init();
    {
        var r = try parseRange("AJs+", &ht, testing.allocator);
        defer r.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 12), r.active_indices.len); // 3 hands × 4 combos
    }
    {
        var r = try parseRange("ATo+", &ht, testing.allocator);
        defer r.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 48), r.active_indices.len); // 4 hands (ATo, AJo, AQo, AKo) × 12
    }
}

test "parseRange: range modifier 22-77 expands ascending" {
    const ht = HandTable.init();
    var r = try parseRange("22-77", &ht, testing.allocator);
    defer r.deinit(testing.allocator);
    // 22, 33, 44, 55, 66, 77 = 6 pairs × 6 combos.
    try testing.expectEqual(@as(usize, 36), r.active_indices.len);
}

test "parseRange: T9s-65s same-gap range" {
    const ht = HandTable.init();
    var r = try parseRange("T9s-65s", &ht, testing.allocator);
    defer r.deinit(testing.allocator);
    // T9s, 98s, 87s, 76s, 65s = 5 suited × 4 combos.
    try testing.expectEqual(@as(usize, 20), r.active_indices.len);
}

test "parseRange: range modifier rejects mismatched shapes/gaps" {
    const ht = HandTable.init();
    try testing.expectError(ParseError.RangeEndpointMismatch, parseRange("22-AKs", &ht, testing.allocator));
    try testing.expectError(ParseError.RangeEndpointMismatch, parseRange("T9s-65o", &ht, testing.allocator));
    try testing.expectError(ParseError.RangeEndpointMismatch, parseRange("T9s-J9s", &ht, testing.allocator)); // gap 1 vs gap 2
    try testing.expectError(ParseError.RangeEndpointInverted, parseRange("77-22", &ht, testing.allocator));
}

test "parseRange: specific combo AhKs is exactly one hand" {
    const ht = HandTable.init();
    var r = try parseRange("AhKs", &ht, testing.allocator);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.active_indices.len);
    try testing.expectEqual(@as(f32, 1.0), r.probs[0]);

    const ah = card_mod.makeCard(12, 1);
    const ks = card_mod.makeCard(11, 0);
    const expected_idx = ht.getIndex(Hand.init(ah, ks)).?;
    try testing.expectEqual(expected_idx, r.active_indices[0]);
}

test "parseRange: weights and last-write-wins" {
    const ht = HandTable.init();

    {
        var r = try parseRange("AA:0.5", &ht, testing.allocator);
        defer r.deinit(testing.allocator);
        for (r.probs) |p| try testing.expectEqual(@as(f32, 0.5), p);
    }
    {
        // First sets to 1.0, second overwrites the same combos to 0.25.
        var r = try parseRange("AA, AA:0.25", &ht, testing.allocator);
        defer r.deinit(testing.allocator);
        for (r.probs) |p| try testing.expectEqual(@as(f32, 0.25), p);
    }
    {
        // Weight 0 drops the hand from the sparse output.
        var r = try parseRange("AA, AA:0", &ht, testing.allocator);
        defer r.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), r.active_indices.len);
    }
}

test "parseRange: weights reject out-of-range and malformed" {
    const ht = HandTable.init();
    try testing.expectError(ParseError.WeightOutOfRange, parseRange("AA:1.5", &ht, testing.allocator));
    try testing.expectError(ParseError.WeightOutOfRange, parseRange("AA:-0.1", &ht, testing.allocator));
    try testing.expectError(ParseError.InvalidWeight, parseRange("AA:foo", &ht, testing.allocator));
}

test "parseRange: comma and whitespace separators are interchangeable" {
    const ht = HandTable.init();
    var a = try parseRange("AA,KK,QQ", &ht, testing.allocator);
    defer a.deinit(testing.allocator);
    var b = try parseRange("AA KK\tQQ\n", &ht, testing.allocator);
    defer b.deinit(testing.allocator);
    var c = try parseRange("AA, KK\nQQ", &ht, testing.allocator);
    defer c.deinit(testing.allocator);
    try testing.expectEqual(a.active_indices.len, b.active_indices.len);
    try testing.expectEqual(a.active_indices.len, c.active_indices.len);
    try testing.expectEqual(@as(usize, 18), a.active_indices.len);
}

test "parseRange: # comments strip to EOL" {
    const ht = HandTable.init();
    var r = try parseRange("AA # premiums\nKK # also premiums", &ht, testing.allocator);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 12), r.active_indices.len);
}

test "parseRange: empty input is an error" {
    const ht = HandTable.init();
    try testing.expectError(ParseError.EmptyInput, parseRange("", &ht, testing.allocator));
    try testing.expectError(ParseError.EmptyInput, parseRange("   \n\t  ", &ht, testing.allocator));
    try testing.expectError(ParseError.EmptyInput, parseRange("# only a comment", &ht, testing.allocator));
}

test "parseRange: duplicate card in specific combo is rejected" {
    const ht = HandTable.init();
    try testing.expectError(ParseError.DuplicateCardInHand, parseRange("AhAh", &ht, testing.allocator));
}

test "parseRange: plus on highest pair is fine (just expands to itself)" {
    // AA+ legally expands to {AA}; not an error since users do write this.
    const ht = HandTable.init();
    var r = try parseRange("AA+", &ht, testing.allocator);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6), r.active_indices.len);
}

test "parseRange: plus on specific combo is rejected" {
    const ht = HandTable.init();
    try testing.expectError(ParseError.PlusModifierOnSpecificCombo, parseRange("AhKs+", &ht, testing.allocator));
}

test "parseRange: complex realistic range parses" {
    const ht = HandTable.init();
    const text =
        \\# UTG opening range
        \\99+, AJs+, KQs, AKo
        \\AhKh:0.5
    ;
    var r = try parseRange(text, &ht, testing.allocator);
    defer r.deinit(testing.allocator);
    // 99+ = 6 pairs × 6 = 36
    // AJs+ = AJs, AQs, AKs = 3 × 4 = 12
    // KQs = 4
    // AKo = 12
    // AhKh:0.5 overwrites that one combo (was in AKs from neither? AKs is suited, AhKh is suited — yes overwrites)
    // Wait — AhKh is in AKs (suited AK). Last write wins → AhKh becomes 0.5, others stay 1.0.
    // Counts still 36+12+4+12 = 64.
    try testing.expectEqual(@as(usize, 64), r.active_indices.len);

    const ahkh_idx = ht.getIndex(Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(11, 1))).?;
    try testing.expectEqual(@as(f32, 0.5), rangeWeight(r, ahkh_idx));
}
