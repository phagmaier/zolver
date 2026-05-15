const std = @import("std");

pub const Card = u32;

pub const SPADE: u32 = 0b0001;
pub const HEART: u32 = 0b0010;
pub const DIAMOND: u32 = 0b0100;
pub const CLUB: u32 = 0b1000;

pub const PRIMES = [13]u32{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41 };

pub fn makeCard(rank: u32, suit: u32) Card {
    const prime = PRIMES[rank];
    const rank_bits = rank << 8;
    const suit_bits = (@as(u32, 1) << @intCast(suit)) << 12;
    const pattern_bit = @as(u32, 1) << @intCast(16 + rank);
    return prime | rank_bits | suit_bits | pattern_bit;
}

pub fn makeDeck() [52]Card {
    var deck: [52]Card = undefined;
    var idx: usize = 0;
    var rank: u32 = 0;
    while (rank < 13) : (rank += 1) {
        var suit: u32 = 0;
        while (suit < 4) : (suit += 1) {
            deck[idx] = makeCard(rank, suit);
            idx += 1;
        }
    }
    return deck;
}

pub fn print_card(card: u32) !void {
    const prime = card & 0xFF;
    const rank: u8 = switch (prime) {
        2 => '2',
        3 => '3',
        5 => '4',
        7 => '5',
        11 => '6',
        13 => '7',
        17 => '8',
        19 => '9',
        23 => 'T',
        29 => 'J',
        31 => 'Q',
        37 => 'K',
        41 => 'A',
        else => {
            std.debug.print("Error: invalid card prime value: {d}\n", .{prime});
            return error.InvalidCard;
        },
    };

    const suit_bits = (card >> 12) & 0xF;
    const suit: u8 = switch (suit_bits) {
        SPADE => 'S',
        HEART => 'H',
        DIAMOND => 'D',
        CLUB => 'C',
        else => {
            std.debug.print("Error: invalid suit bits: {b}\n", .{suit_bits});
            return error.InvalidCard;
        },
    };

    std.debug.print("{c}{c}\n", .{ rank, suit });
}

pub fn get_card_str(card: u32) ![2]u8 {
    var str: [2]u8 = undefined;
    const prime = card & 0xFF;
    str[0] = switch (prime) {
        2 => '2',
        3 => '3',
        5 => '4',
        7 => '5',
        11 => '6',
        13 => '7',
        17 => '8',
        19 => '9',
        23 => 'T',
        29 => 'J',
        31 => 'Q',
        37 => 'K',
        41 => 'A',
        else => {
            std.debug.print("Error: invalid card prime value: {d}\n", .{prime});
            return error.InvalidCard;
        },
    };

    const suit_bits = (card >> 12) & 0xF;
    str[1] = switch (suit_bits) {
        SPADE => 'S',
        HEART => 'H',
        DIAMOND => 'D',
        CLUB => 'C',
        else => {
            std.debug.print("Error: invalid suit bits: {b}\n", .{suit_bits});
            return error.InvalidCard;
        },
    };
    return str;
}
