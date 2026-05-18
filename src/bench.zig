const std = @import("std");
const builtin = @import("builtin");

const card_mod = @import("card.zig");
const range_mod = @import("range.zig");
const node_mod = @import("node.zig");
const gamestate_mod = @import("gamestate.zig");
const cfr = @import("cfr.zig");

const Card = u32;
const Range = range_mod.Range;
const HandTable = range_mod.HandTable;
const Hand = range_mod.Hand;
const Edge = node_mod.Edge;
const Solver = cfr.Solver;
const NUM_HANDS = cfr.NUM_HANDS;

const Scenario = struct {
    name: []const u8,
    street: gamestate_mod.Street,
    truncate_after: ?gamestate_mod.Street,
    pot: f32,
    stack1: f32,
    stack2: f32,
    iters: usize,
    warmup: usize,
    build: *const fn (std.mem.Allocator) anyerror!Built,
};

const Built = struct {
    board: [5]Card,
    p1: Range,
    p2: Range,

    fn deinit(self: *Built, allocator: std.mem.Allocator) void {
        self.p1.deinit(allocator);
        self.p2.deinit(allocator);
    }
};

fn buildPolarizedRiver(allocator: std.mem.Allocator) !Built {
    const ht = HandTable.init();
    const board = [5]Card{
        card_mod.makeCard(12, 0),
        card_mod.makeCard(11, 0),
        card_mod.makeCard(0, 1),
        card_mod.makeCard(1, 2),
        card_mod.makeCard(5, 3),
    };

    var p1 = try Range.initEmpty(allocator, 3);
    p1.active_indices[0] = ht.getIndex(Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(12, 2))).?;
    p1.active_indices[1] = ht.getIndex(Hand.init(card_mod.makeCard(11, 1), card_mod.makeCard(11, 2))).?;
    p1.active_indices[2] = ht.getIndex(Hand.init(card_mod.makeCard(5, 0), card_mod.makeCard(0, 3))).?;
    p1.probs[0] = 0.2;
    p1.probs[1] = 0.2;
    p1.probs[2] = 0.6;
    p1.normalize();

    var p2 = try Range.initEmpty(allocator, 3);
    p2.active_indices[0] = ht.getIndex(Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(10, 2))).?;
    p2.active_indices[1] = ht.getIndex(Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(9, 2))).?;
    p2.active_indices[2] = ht.getIndex(Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(8, 2))).?;
    p2.probs[0] = 0.33;
    p2.probs[1] = 0.33;
    p2.probs[2] = 0.34;
    p2.normalize();

    return .{ .board = board, .p1 = p1, .p2 = p2 };
}

fn buildFullRangeTurn(allocator: std.mem.Allocator) !Built {
    // Dry-ish turn board.
    const board = [5]Card{
        card_mod.makeCard(12, 0),
        card_mod.makeCard(7, 1),
        card_mod.makeCard(2, 2),
        card_mod.makeCard(10, 3),
        0,
    };
    return fullRangeFor(allocator, board);
}

fn buildFullRangeFlop(allocator: std.mem.Allocator) !Built {
    const board = [5]Card{
        card_mod.makeCard(12, 0),
        card_mod.makeCard(7, 1),
        card_mod.makeCard(2, 2),
        0,
        0,
    };
    return fullRangeFor(allocator, board);
}

fn fullRangeFor(allocator: std.mem.Allocator, board: [5]Card) !Built {
    var p1 = try Range.initEmpty(allocator, NUM_HANDS);
    var p2 = try Range.initEmpty(allocator, NUM_HANDS);
    var i: u16 = 0;
    while (i < NUM_HANDS) : (i += 1) {
        p1.active_indices[i] = i;
        p1.probs[i] = 1.0;
        p2.active_indices[i] = i;
        p2.probs[i] = 1.0;
    }
    p1.normalize();
    p2.normalize();
    return .{ .board = board, .p1 = p1, .p2 = p2 };
}

// Iter counts are tuned so the full bench runs in <30s in ReleaseFast. The
// flop scenario is dominated by allInEquityLeaf's 2,352-runout enumeration;
// 1 iter is plenty to measure iters/s, and we skip warmup there to avoid
// paying the same 15s cost twice.
const scenarios = [_]Scenario{
    .{
        .name = "river-polarized",
        .street = .RIVER,
        .truncate_after = null,
        .pot = 100,
        .stack1 = 500,
        .stack2 = 500,
        .iters = 200,
        .warmup = 1,
        .build = buildPolarizedRiver,
    },
    .{
        .name = "turn-fullrange",
        .street = .TURN,
        .truncate_after = null,
        .pot = 50,
        .stack1 = 400,
        .stack2 = 400,
        .iters = 50,
        .warmup = 1,
        .build = buildFullRangeTurn,
    },
    .{
        .name = "flop-fullrange-trunc",
        .street = .FLOP,
        .truncate_after = .FLOP,
        .pot = 20,
        .stack1 = 200,
        .stack2 = 200,
        .iters = 1,
        .warmup = 0,
        .build = buildFullRangeFlop,
    },
};

fn runScenario(allocator: std.mem.Allocator, io: std.Io, s: Scenario) !void {
    var built = try s.build(allocator);
    defer built.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var root_state = gamestate_mod.GameState.init(s.street, true, s.pot, s.stack1, s.stack2);
    var arr = std.ArrayList(Edge).empty;
    defer arr.deinit(allocator);

    if (s.truncate_after) |street| {
        try node_mod.buildTreeTruncated(&root_state, &arr, arena_allocator, allocator, NUM_HANDS, NUM_HANDS, street);
    } else {
        try node_mod.buildTree(&root_state, &arr, arena_allocator, allocator, NUM_HANDS, NUM_HANDS);
    }
    const root = arr.items[0].child.?;
    const n_nodes = node_mod.assignIds(root);

    var solver = try Solver.init(built.board, &built.p1, &built.p2, s.stack1, s.stack2, s.pot);
    defer solver.deinit();

    var cfv_p1: [NUM_HANDS]f32 = undefined;
    var cfv_p2: [NUM_HANDS]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(42);

    if (s.warmup > 0) {
        try cfr.solve(&solver, allocator, root, s.warmup, prng.random(), &cfv_p1, &cfv_p2);
    }

    const start = std.Io.Timestamp.now(io, .awake);
    try cfr.solve(&solver, allocator, root, s.iters, prng.random(), &cfv_p1, &cfv_p2);
    const end = std.Io.Timestamp.now(io, .awake);

    const elapsed_ns: i128 = @as(i128, end.nanoseconds) - @as(i128, start.nanoseconds);
    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const iters_per_s: f64 = @as(f64, @floatFromInt(s.iters)) / elapsed_s;

    std.debug.print(
        "{s:<26} iters={d:<5} nodes={d:<6} time={d:>7.3}s  iters/s={d:>9.2}\n",
        .{ s.name, s.iters, n_nodes, elapsed_s, iters_per_s },
    );
}

pub fn main(init: std.process.Init) !void {
    var da = std.heap.DebugAllocator(.{}){};
    const allocator = if (builtin.mode == .Debug) da.allocator() else std.heap.smp_allocator;
    defer _ = da.deinit();

    const io = init.io;
    const cpu_count: usize = std.Thread.getCpuCount() catch 1;
    std.debug.print(
        "Poker bench  optimize={s}  cpus={d}\n",
        .{ @tagName(builtin.mode), cpu_count },
    );
    std.debug.print("{s}\n", .{"-" ** 72});

    for (scenarios) |s| {
        try runScenario(allocator, io, s);
    }
}
