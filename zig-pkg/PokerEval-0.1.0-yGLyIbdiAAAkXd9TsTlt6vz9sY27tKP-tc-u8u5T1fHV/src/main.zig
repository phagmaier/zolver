const std = @import("std");
const Evaluator = @import("evaluator.zig").Evaluator;
const Card = @import("card.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout_writer.interface;

    var eval = try Evaluator.init();

    const NUM_HANDS = 10_000_000;
    try out.print("Generating {d} hands for benchmark...\n", .{NUM_HANDS});

    const hands = try allocator.alloc([7]u32, NUM_HANDS);

    var prng = std.Random.DefaultPrng.init(0x12345678);
    const random = prng.random();

    var deck = Card.makeDeck();
    for (hands) |*hand| {
        // Fisher-Yates over the first 7 slots: produces a 7-card draw without
        // replacement, which is what the solver actually evaluates.
        var k: usize = 0;
        while (k < 7) : (k += 1) {
            const j = k + random.uintLessThan(usize, 52 - k);
            const tmp = deck[k];
            deck[k] = deck[j];
            deck[j] = tmp;
            hand[k] = deck[k];
        }
    }

    try out.print("Starting benchmark...\n", .{});
    const start = std.Io.Clock.now(.awake, io);

    var total_score: u64 = 0;
    for (hands) |hand| {
        const score = eval.handStrength(hand);
        total_score += score;
    }

    const end = std.Io.Clock.now(.awake, io);
    const elapsed_ns: i96 = end.nanoseconds - start.nanoseconds;

    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const hands_per_sec = @as(f64, @floatFromInt(NUM_HANDS)) / seconds;

    try out.print("Evaluated {d} hands in {d:.4} seconds\n", .{ NUM_HANDS, seconds });
    try out.print("Speed: {d:.2} million hands/sec\n", .{hands_per_sec / 1_000_000.0});
    try out.print("checksum: {d}\n", .{total_score});
    try out.flush();
}
