// CSV export for `poker resolve` outputs.
//
// Schema (root only, actor's active hands only):
//
//   hand,reach,<TAG>@<amount>,<TAG>@<amount>,...
//   AsAh,0.500,0.967,0.016,0.014,0.003
//   ...
//
// Hand label: card1+card2 via `card.get_card_str` (uppercase suits today —
// matches the existing convention in this codebase).
// Action columns: one per root edge, labeled `<TAG>@<amount:.2>`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const card_mod = @import("card.zig");
const cfr = @import("cfr.zig");
const node_mod = @import("node.zig");
const range_mod = @import("range.zig");

pub const ExportError = error{
    RootIsChance,
};

/// Writes the root-level strategy as CSV to `writer`. `actor_reach` must be
/// the reach probabilities of whichever player is to act at `root` (length
/// `cfr.NUM_HANDS`).
pub fn writeRootStrategyCsv(
    allocator: Allocator,
    writer: *std.Io.Writer,
    root: *const node_mod.Node,
    actor_reach: []const f32,
) !void {
    if (root.is_chance) return error.RootIsChance;

    const n_actions = root.edges.len;
    const strat_buf = try allocator.alloc(f32, n_actions * cfr.NUM_HANDS);
    defer allocator.free(strat_buf);
    cfr.averageStrategy(@constCast(root), strat_buf);

    // Header.
    try writer.writeAll("hand,reach");
    for (root.edges) |*edge| {
        try writer.print(",{s}@{d:.2}", .{ @tagName(edge.action), edge.amount });
    }
    try writer.writeByte('\n');

    // Body: one row per hand with non-zero actor reach.
    const table = range_mod.HandTable.init();
    var idx: usize = 0;
    while (idx < cfr.NUM_HANDS) : (idx += 1) {
        const reach = actor_reach[idx];
        if (reach == 0) continue;

        const hand = table.all_hands[idx];
        const s1 = card_mod.get_card_str(hand.card1) catch [2]u8{ '?', '?' };
        const s2 = card_mod.get_card_str(hand.card2) catch [2]u8{ '?', '?' };

        try writer.print("{s}{s},{d:.6}", .{ s1, s2, reach });
        var a: usize = 0;
        while (a < n_actions) : (a += 1) {
            const freq = strat_buf[a * cfr.NUM_HANDS + idx];
            try writer.print(",{d:.6}", .{freq});
        }
        try writer.writeByte('\n');
    }
}

test "writeRootStrategyCsv emits a header + one row per active hand" {
    const allocator = std.testing.allocator;
    const NUM_HANDS = cfr.NUM_HANDS;

    // Synthesize a 2-edge decision root with a uniform strategy: P1 to act,
    // strategy_sum is initialized so cfr.averageStrategy returns 0.5/0.5 for
    // each hand. (averageStrategy on zero strategy_sum falls back to uniform.)
    var regrets: [2 * NUM_HANDS]f32 = undefined;
    var strategy_sum: [2 * NUM_HANDS]f32 = undefined;
    @memset(&regrets, 0);
    @memset(&strategy_sum, 0);

    var edges = [_]node_mod.Edge{
        .{ .action = .CHECK, .amount = 50, .stack1 = 100, .stack2 = 100, .child = null },
        .{ .action = .BET, .amount = 75, .stack1 = 75, .stack2 = 100, .child = null },
    };
    var root = node_mod.Node{
        .is_chance = false,
        .is_leaf = false,
        .isp1 = true,
        .id = node_mod.UNASSIGNED_ID,
        .regrets = regrets[0..],
        .strategy_sum = strategy_sum[0..],
        .edges = edges[0..],
    };

    var actor_reach: [NUM_HANDS]f32 = undefined;
    @memset(&actor_reach, 0);
    const table = range_mod.HandTable.init();
    const aa_idx = table.getIndex(range_mod.Hand.init(
        card_mod.makeCard(12, 0),
        card_mod.makeCard(12, 1),
    )).?;
    actor_reach[aa_idx] = 1.0;

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();
    try writeRootStrategyCsv(allocator, &alloc_writer.writer, &root, &actor_reach);

    const got = alloc_writer.writer.buffered();
    const aa = table.all_hands[aa_idx];
    const s1 = try card_mod.get_card_str(aa.card1);
    const s2 = try card_mod.get_card_str(aa.card2);

    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf,
        "hand,reach,CHECK@50.00,BET@75.00\n" ++
        "{s}{s},1.000000,0.500000,0.500000\n",
        .{ s1, s2 },
    );

    try std.testing.expectEqualStrings(expected, got);
}

test "writeRootStrategyCsv refuses a chance root" {
    const allocator = std.testing.allocator;

    var edges = [_]node_mod.Edge{
        .{ .action = .CHANCE, .amount = 50, .stack1 = 100, .stack2 = 100, .child = null },
    };
    var root = node_mod.Node{
        .is_chance = true,
        .is_leaf = true,
        .isp1 = true,
        .id = node_mod.UNASSIGNED_ID,
        .regrets = &.{},
        .strategy_sum = &.{},
        .edges = edges[0..],
    };
    var reach: [cfr.NUM_HANDS]f32 = undefined;
    @memset(&reach, 0);

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();
    try std.testing.expectError(error.RootIsChance, writeRootStrategyCsv(allocator, &alloc_writer.writer, &root, &reach));
}
