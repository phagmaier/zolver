const std = @import("std");
const Card = @import("card.zig");

const HIGH_CARD_BASE: u32 = 1;
const PAIR_BASE: u32 = 2;
const TWO_PAIR_BASE: u32 = 3;
const TRIPS_BASE: u32 = 4;
const STRAIGHT_BASE: u32 = 5;
const FLUSH_BASE: u32 = 6;
const FULL_HOUSE_BASE: u32 = 7;
const FOUR_OF_A_KIND_BASE: u32 = 8;
const STRAIGHT_FLUSH_BASE: u32 = 9;

// Index i -> straight value (10 - i): A-high=10 down to wheel=1.
const STRAIGHTS = [_]u16{
    0b1111100000000, // A-high (royal high)
    0b0111110000000, // K-high
    0b0011111000000, // Q-high
    0b0001111100000, // J-high
    0b0000111110000, // T-high
    0b0000011111000, // 9-high
    0b0000001111100, // 8-high
    0b0000000111110, // 7-high
    0b0000000011111, // 6-high
    0b1000000001111, // 5-high (wheel)
};

const NONE: u32 = 16; // sentinel: no rank found

inline fn highBit(bits: u16) u32 {
    // Position of the highest set bit. Caller must ensure bits != 0.
    return 15 - @as(u32, @clz(bits));
}

pub const Evaluator = struct {
    const Self = @This();

    pub fn init() !Self {
        return Self{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn handStrength(_: *const Self, hand: [7]u32) u32 {
        var ranks: u16 = 0;
        var suit_ranks = [4]u16{ 0, 0, 0, 0 };
        var suit_counts = [4]u8{ 0, 0, 0, 0 };
        var counts = [_]u8{0} ** 13;

        inline for (hand) |card| {
            if (card != 0) {
                const suit_nibble: u4 = @intCast((card >> 12) & 0xF);
                const s_idx: usize = @ctz(suit_nibble);
                const r: usize = (card >> 8) & 0xF;
                const rb: u16 = @as(u16, 1) << @intCast(r);
                ranks |= rb;
                suit_ranks[s_idx] |= rb;
                suit_counts[s_idx] += 1;
                counts[r] += 1;
            }
        }

        // Flush check (categories Flush=6 and Straight Flush=9, both > any non-flush hand
        // reachable with 7 cards, so we can return immediately).
        inline for (suit_counts, 0..) |count, i| {
            if (count >= 5) {
                // Straight flush must be tested against the full suit bitmap:
                // with 6+ suited cards, higher non-consecutive ranks can occupy
                // the top-5 slots and hide a lower SF (e.g. a wheel SF behind
                // two over-suited kickers).
                inline for (STRAIGHTS, 0..) |sm, j| {
                    if ((suit_ranks[i] & sm) == sm) {
                        return (STRAIGHT_FLUSH_BASE << 26) | @as(u32, @intCast(10 - j));
                    }
                }
                var flush_bits = suit_ranks[i];
                while (@popCount(flush_bits) > 5) flush_bits &= flush_bits - 1;
                return (FLUSH_BASE << 26) | @as(u32, flush_bits);
            }
        }

        // Straight (cannot co-exist with a higher non-flush category in 7 cards).
        inline for (STRAIGHTS, 0..) |mask, i| {
            if ((ranks & mask) == mask) {
                return (STRAIGHT_BASE << 26) | @as(u32, @intCast(10 - i));
            }
        }

        // Rank-histogram analysis. Scan ranks descending so first hits are highest.
        var quad: u32 = NONE;
        var trip1: u32 = NONE;
        var trip2: u32 = NONE;
        var pair1: u32 = NONE;
        var pair2: u32 = NONE;

        var ri: usize = 13;
        while (ri > 0) {
            ri -= 1;
            const c = counts[ri];
            // In a real poker deck c is in 0..4. We clamp >=4 to quads and
            // >=3 to trips defensively so callers that pass duplicate cards
            // (e.g. random sampling with replacement) still get sensible output.
            if (c >= 4) {
                if (quad == NONE) quad = @intCast(ri);
            } else if (c == 3) {
                if (trip1 == NONE) {
                    trip1 = @intCast(ri);
                } else if (trip2 == NONE) {
                    trip2 = @intCast(ri);
                }
            } else if (c == 2) {
                if (pair1 == NONE) {
                    pair1 = @intCast(ri);
                } else if (pair2 == NONE) {
                    pair2 = @intCast(ri);
                }
            }
        }

        // Four of a kind: quads + highest other rank as kicker.
        if (quad != NONE) {
            const kbits = ranks & ~(@as(u16, 1) << @intCast(quad));
            return (FOUR_OF_A_KIND_BASE << 26) | (quad << 13) | highBit(kbits);
        }

        // Full house: a trip exists and either a second trip or a pair exists.
        // Two trips in 7 cards leaves no room for a pair, so trip2 and pair1
        // are mutually exclusive when both can drive a full house.
        if (trip1 != NONE and (trip2 != NONE or pair1 != NONE)) {
            const pr: u32 = if (trip2 != NONE) trip2 else pair1;
            return (FULL_HOUSE_BASE << 26) | (trip1 << 13) | pr;
        }

        // Trips: trip rank + top two other-rank kickers.
        if (trip1 != NONE) {
            var kbits = ranks & ~(@as(u16, 1) << @intCast(trip1));
            const k1 = highBit(kbits);
            kbits &= ~(@as(u16, 1) << @intCast(k1));
            const k2 = highBit(kbits);
            return (TRIPS_BASE << 26) | (trip1 << 13) | (k1 << 4) | k2;
        }

        // Two pair: highest two pairs + highest remaining kicker.
        if (pair2 != NONE) {
            const kbits = ranks
                & ~(@as(u16, 1) << @intCast(pair1))
                & ~(@as(u16, 1) << @intCast(pair2));
            return (TWO_PAIR_BASE << 26) | (pair1 << 13) | (pair2 << 9) | highBit(kbits);
        }

        // Pair: pair rank + 3-bit mask of top three kicker ranks.
        if (pair1 != NONE) {
            var kbits = ranks & ~(@as(u16, 1) << @intCast(pair1));
            const k1 = highBit(kbits);
            kbits &= ~(@as(u16, 1) << @intCast(k1));
            const k2 = highBit(kbits);
            kbits &= ~(@as(u16, 1) << @intCast(k2));
            const k3 = highBit(kbits);
            const k_mask: u32 = (@as(u32, 1) << @intCast(k1)) |
                (@as(u32, 1) << @intCast(k2)) |
                (@as(u32, 1) << @intCast(k3));
            return (PAIR_BASE << 26) | (pair1 << 13) | k_mask;
        }

        // High card: 7 distinct ranks; strip the two lowest to keep the top 5.
        var bits = ranks;
        bits &= bits - 1;
        bits &= bits - 1;
        return (HIGH_CARD_BASE << 26) | @as(u32, bits);
    }
};

test "Poker Hand Correctness" {
    var eval = try Evaluator.init();

    const royal = [_]u32{ Card.makeCard(12, 0), Card.makeCard(11, 0), Card.makeCard(10, 0), Card.makeCard(9, 0), Card.makeCard(8, 0), Card.makeCard(2, 1), Card.makeCard(3, 2) };

    const s_flush = [_]u32{ Card.makeCard(9, 0), Card.makeCard(8, 0), Card.makeCard(7, 0), Card.makeCard(6, 0), Card.makeCard(5, 0), Card.makeCard(12, 1), Card.makeCard(12, 2) };

    try std.testing.expect(eval.handStrength(royal) > eval.handStrength(s_flush));

    const quads = [_]u32{ Card.makeCard(5, 0), Card.makeCard(5, 1), Card.makeCard(5, 2), Card.makeCard(5, 3), Card.makeCard(12, 0), Card.makeCard(2, 0), Card.makeCard(3, 0) };
    const boat = [_]u32{ Card.makeCard(12, 0), Card.makeCard(12, 1), Card.makeCard(12, 2), Card.makeCard(11, 0), Card.makeCard(11, 1), Card.makeCard(2, 0), Card.makeCard(3, 0) };

    try std.testing.expect(eval.handStrength(quads) > eval.handStrength(boat));

    const wheel = [_]u32{ Card.makeCard(12, 0), Card.makeCard(0, 1), Card.makeCard(1, 2), Card.makeCard(2, 3), Card.makeCard(3, 0), Card.makeCard(11, 1), Card.makeCard(11, 2) };
    const pair_aces = [_]u32{ Card.makeCard(12, 0), Card.makeCard(12, 1), Card.makeCard(8, 2), Card.makeCard(7, 3), Card.makeCard(4, 0), Card.makeCard(2, 1), Card.makeCard(2, 2) };

    try std.testing.expect(eval.handStrength(wheel) > eval.handStrength(pair_aces));

    const board = [_]u32{ Card.makeCard(11, 0), Card.makeCard(11, 1), Card.makeCard(6, 2), Card.makeCard(6, 3), Card.makeCard(2, 0) };

    var p1_hand: [7]u32 = undefined;
    @memcpy(p1_hand[0..5], board[0..]);
    p1_hand[5] = Card.makeCard(12, 1); // Ace
    p1_hand[6] = Card.makeCard(0, 1); // 2

    var p2_hand: [7]u32 = undefined;
    @memcpy(p2_hand[0..5], board[0..]);
    p2_hand[5] = Card.makeCard(10, 1); // Queen
    p2_hand[6] = Card.makeCard(0, 2); // 2

    try std.testing.expect(eval.handStrength(p1_hand) > eval.handStrength(p2_hand));
}

test "Histogram categorization vs prime-product oracle" {
    // For every 7-card hand that is neither a flush nor a straight, the new
    // histogram path must produce the same hand-category ordering as a
    // brute-force best-of-21 evaluation. We sanity-check a handful of edge
    // cases here; a full sweep is impractical inside a unit test.
    var eval = try Evaluator.init();

    // Quads beat full house
    const quads = [_]u32{
        Card.makeCard(5, 0), Card.makeCard(5, 1), Card.makeCard(5, 2),
        Card.makeCard(5, 3), Card.makeCard(12, 0), Card.makeCard(12, 1),
        Card.makeCard(2, 0),
    };
    const fh = [_]u32{
        Card.makeCard(12, 0), Card.makeCard(12, 1), Card.makeCard(12, 2),
        Card.makeCard(11, 0), Card.makeCard(11, 1), Card.makeCard(2, 0),
        Card.makeCard(3, 0),
    };
    try std.testing.expect(eval.handStrength(quads) > eval.handStrength(fh));

    // Full house from two trips: trips of 7s and trips of 3s -> 777 33
    const two_trips = [_]u32{
        Card.makeCard(5, 0), Card.makeCard(5, 1), Card.makeCard(5, 2),
        Card.makeCard(1, 0), Card.makeCard(1, 1), Card.makeCard(1, 2),
        Card.makeCard(12, 0),
    };
    const fh2 = eval.handStrength(two_trips);
    // Category bits should equal FULL_HOUSE_BASE (7).
    try std.testing.expectEqual(@as(u32, FULL_HOUSE_BASE), fh2 >> 26);
    // Trip rank should be 5 (higher of the two trips).
    try std.testing.expectEqual(@as(u32, 5), (fh2 >> 13) & 0x1F);
    // Pair rank should be 1.
    try std.testing.expectEqual(@as(u32, 1), fh2 & 0x1F);

    // High card: 7 distinct ranks A,K,J,9,7,5,3 (no straight, no flush)
    const high_card = [_]u32{
        Card.makeCard(12, 0), Card.makeCard(11, 1), Card.makeCard(9, 2),
        Card.makeCard(7, 3), Card.makeCard(5, 0), Card.makeCard(3, 1),
        Card.makeCard(1, 2),
    };
    const hc = eval.handStrength(high_card);
    try std.testing.expectEqual(@as(u32, HIGH_CARD_BASE), hc >> 26);
    // Top 5 ranks: A(12), K(11), J(9), 9(7), 7(5). Bitmask = bits {5,7,9,11,12}.
    const expected_bits: u32 = (1 << 5) | (1 << 7) | (1 << 9) | (1 << 11) | (1 << 12);
    try std.testing.expectEqual(expected_bits, hc & 0x3FFFFFF);
}

test "wheel straight flush hidden behind suited over-kickers" {
    // Regression: with 6+ same-suit cards, an SF whose run is below two higher
    // suited kickers used to be missed because the popcount-strip dropped the
    // wheel's low bits before the STRAIGHTS check ran.
    // Hand: A♠ K♠ 5♠ 4♠ 3♠ 2♠ 9♣ — contains A-2-3-4-5 straight flush.
    var eval = try Evaluator.init();
    const wheel_sf = [_]u32{
        Card.makeCard(12, 0), Card.makeCard(11, 0), Card.makeCard(3, 0),
        Card.makeCard(2, 0),  Card.makeCard(1, 0),  Card.makeCard(0, 0),
        Card.makeCard(7, 3),
    };
    const sf = eval.handStrength(wheel_sf);
    try std.testing.expectEqual(@as(u32, STRAIGHT_FLUSH_BASE), sf >> 26);
    // STRAIGHTS index 9 = wheel → value 10 - 9 = 1.
    try std.testing.expectEqual(@as(u32, 1), sf & 0x3FFFFFF);
}
