const std = @import("std");
const Io = std.Io;

const builtin = @import("builtin");
const PokerEval = @import("PokerEval");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var da = std.heap.DebugAllocator(.{}){};
    const allocator = if (builtin.mode == .Debug) da.allocator() else std.heap.smp_allocator;
    defer _ = da.deinit();
    _ = allocator;
    _ = io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |i| {
        std.debug.print("{s}\n", .{i});
    }

    // 1. Initialize the Evaluator
    var eval = try PokerEval.Evaluator.init();

    // 2. Create a Royal Flush (Ace-high Straight Flush in Spades)
    const royal_flush = [7]u32{
        PokerEval.Card.makeCard(12, 0), // Ace of Spades
        PokerEval.Card.makeCard(11, 0), // King of Spades
        PokerEval.Card.makeCard(10, 0), // Queen of Spades
        PokerEval.Card.makeCard(9, 0), // Jack of Spades
        PokerEval.Card.makeCard(8, 0), // Ten of Spades
        PokerEval.Card.makeCard(0, 1), // 2 of Hearts (kicker)
        PokerEval.Card.makeCard(1, 2), // 3 of Diamonds (kicker)
    };

    // 3. Create a High Card hand
    const high_card = [7]u32{
        PokerEval.Card.makeCard(12, 0), // Ace of Spades
        PokerEval.Card.makeCard(7, 1), // 9 of Hearts
        PokerEval.Card.makeCard(5, 2), // 7 of Diamonds
        PokerEval.Card.makeCard(3, 3), // 5 of Clubs
        PokerEval.Card.makeCard(1, 0), // 3 of Spades
        PokerEval.Card.makeCard(0, 1), // 2 of Hearts
        PokerEval.Card.makeCard(4, 2), // 6 of Diamonds
    };

    // 4. Evaluate strengths
    const rf_strength = eval.handStrength(royal_flush);
    const hc_strength = eval.handStrength(high_card);

    std.debug.print("\n--- Poker Evaluation Test ---\n", .{});
    std.debug.print("Royal Flush Strength: {d}\n", .{rf_strength});
    std.debug.print("High Card Strength:  {d}\n", .{hc_strength});

    if (rf_strength > hc_strength) {
        std.debug.print("Result: Royal Flush beats High Card (as expected!)\n", .{});
    } else {
        std.debug.print("Result: Something is wrong with the evaluation.\n", .{});
    }
    std.debug.print("-----------------------------\n\n", .{});
}
