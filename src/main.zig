// `poker solve` CLI. Minimal first-cut: parse PokerStove-style ranges,
// build a betting tree, run CFR for the requested iter count, print
// the root strategy and a few summary numbers.
//
//   poker solve --board AhKsQd \
//               --pot 100 --stack 500 \
//               --p1 "AA, KK, QQ, AKs" \
//               --p2 "@ranges/bb.txt" \
//               --iters 100 \
//               [--truncate flop|turn]
//
// Range strings prefixed with `@` are read from a file (`@-` reads stdin).
// All numeric args are floats; `--iters` is an unsigned int.

const std = @import("std");
const builtin = @import("builtin");

const card_mod = @import("card.zig");
const range_mod = @import("range.zig");
const range_parser = @import("range_parser.zig");
const node_mod = @import("node.zig");
const gamestate_mod = @import("gamestate.zig");
const cfr = @import("cfr.zig");

const Range = range_mod.Range;
const HandTable = range_mod.HandTable;
const Solver = cfr.Solver;
const NUM_HANDS = cfr.NUM_HANDS;
const Edge = node_mod.Edge;

pub fn main(init: std.process.Init) !void {
    var da = std.heap.DebugAllocator(.{}){};
    const allocator = if (builtin.mode == .Debug) da.allocator() else std.heap.smp_allocator;
    defer _ = da.deinit();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        try printUsage();
        return;
    }

    const sub = args[1];
    if (std.mem.eql(u8, sub, "solve")) {
        try cmdSolve(init, allocator, args[2..]);
    } else if (std.mem.eql(u8, sub, "help") or std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        try printUsage();
    } else {
        std.debug.print("unknown subcommand: {s}\n\n", .{sub});
        try printUsage();
        return error.UnknownSubcommand;
    }
}

fn printUsage() !void {
    const usage =
        \\Usage: poker <subcommand> [args]
        \\
        \\Subcommands:
        \\  solve   Run CFR on a postflop spot.
        \\  help    Show this message.
        \\
        \\poker solve flags:
        \\  --board <STR>       Board cards, e.g. AhKsQd, AhKsQd2c, AhKsQd2c5h.
        \\  --pot <FLOAT>       Pot size at the start of the spot.
        \\  --stack <FLOAT>     Effective stack size (per player).
        \\  --p1 <RANGE|@PATH>  P1 range string, or @path to load from file.
        \\  --p2 <RANGE|@PATH>  P2 range string, or @path to load from file.
        \\  --iters <N>         Number of CFR iterations (default 100).
        \\  --truncate <S>      Truncate the tree at street boundary: flop|turn.
        \\                      Omit for a full tree.
        \\
    ;
    std.debug.print("{s}", .{usage});
}

const SolveArgs = struct {
    board_str: ?[]const u8 = null,
    p1_str: ?[]const u8 = null,
    p2_str: ?[]const u8 = null,
    pot: ?f32 = null,
    stack: ?f32 = null,
    iters: u32 = 100,
    truncate_after: ?gamestate_mod.Street = null,
};

fn cmdSolve(init: std.process.Init, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var sa: SolveArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--board")) {
            sa.board_str = try requireNext(args, &i, "--board");
        } else if (std.mem.eql(u8, a, "--p1")) {
            sa.p1_str = try requireNext(args, &i, "--p1");
        } else if (std.mem.eql(u8, a, "--p2")) {
            sa.p2_str = try requireNext(args, &i, "--p2");
        } else if (std.mem.eql(u8, a, "--pot")) {
            const v = try requireNext(args, &i, "--pot");
            sa.pot = try std.fmt.parseFloat(f32, v);
        } else if (std.mem.eql(u8, a, "--stack")) {
            const v = try requireNext(args, &i, "--stack");
            sa.stack = try std.fmt.parseFloat(f32, v);
        } else if (std.mem.eql(u8, a, "--iters")) {
            const v = try requireNext(args, &i, "--iters");
            sa.iters = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--truncate")) {
            const v = try requireNext(args, &i, "--truncate");
            if (std.mem.eql(u8, v, "flop")) {
                sa.truncate_after = .FLOP;
            } else if (std.mem.eql(u8, v, "turn")) {
                sa.truncate_after = .TURN;
            } else {
                std.debug.print("--truncate must be flop or turn, got {s}\n", .{v});
                return error.BadTruncate;
            }
        } else {
            std.debug.print("unknown flag: {s}\n\n", .{a});
            try printUsage();
            return error.UnknownFlag;
        }
    }

    // Required-flag check, all at once so users see every missing piece.
    var missing: usize = 0;
    if (sa.board_str == null) {
        std.debug.print("missing --board\n", .{});
        missing += 1;
    }
    if (sa.p1_str == null) {
        std.debug.print("missing --p1\n", .{});
        missing += 1;
    }
    if (sa.p2_str == null) {
        std.debug.print("missing --p2\n", .{});
        missing += 1;
    }
    if (sa.pot == null) {
        std.debug.print("missing --pot\n", .{});
        missing += 1;
    }
    if (sa.stack == null) {
        std.debug.print("missing --stack\n", .{});
        missing += 1;
    }
    if (missing > 0) return error.MissingArgs;

    // Parse the board to validate before kicking off solver setup.
    const board = try range_parser.parseBoard(sa.board_str.?);
    const num_board_cards = blk: {
        var n: usize = 0;
        for (board) |c| if (c != 0) {
            n += 1;
        };
        break :blk n;
    };
    const street: gamestate_mod.Street = switch (num_board_cards) {
        3 => .FLOP,
        4 => .TURN,
        5 => .RIVER,
        else => unreachable, // parseBoard rejects other lengths
    };

    // Load ranges (supports @path).
    var hand_table = HandTable.init();
    const p1_text = try loadRangeText(allocator, init.io, sa.p1_str.?);
    defer freeIfOwned(allocator, sa.p1_str.?, p1_text);
    const p2_text = try loadRangeText(allocator, init.io, sa.p2_str.?);
    defer freeIfOwned(allocator, sa.p2_str.?, p2_text);

    var p1 = try range_parser.parseRange(p1_text, &hand_table, allocator);
    defer p1.deinit(allocator);
    var p2 = try range_parser.parseRange(p2_text, &hand_table, allocator);
    defer p2.deinit(allocator);

    // Build the betting tree.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var root_state = gamestate_mod.GameState.init(street, true, sa.pot.?, sa.stack.?, sa.stack.?);
    var arr = std.ArrayList(Edge).empty;
    defer arr.deinit(allocator);
    if (sa.truncate_after) |t| {
        try node_mod.buildTreeTruncated(&root_state, &arr, arena.allocator(), allocator, NUM_HANDS, NUM_HANDS, t);
    } else {
        try node_mod.buildTree(&root_state, &arr, arena.allocator(), allocator, NUM_HANDS, NUM_HANDS);
    }
    const root = arr.items[0].child orelse return error.EmptyTree;
    const n_nodes = node_mod.assignIds(root);

    // Run CFR.
    var solver = try Solver.init(board, &p1, &p2, sa.stack.?, sa.stack.?, sa.pot.?);
    defer solver.deinit();
    solver.timings_io = init.io;

    var cfv_p1: [NUM_HANDS]f32 = undefined;
    var cfv_p2: [NUM_HANDS]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(42);

    const t_start = std.Io.Clock.Timestamp.now(init.io, .awake);
    try cfr.solve(&solver, allocator, root, sa.iters, prng.random(), &cfv_p1, &cfv_p2);
    const t_end = std.Io.Clock.Timestamp.now(init.io, .awake);
    const elapsed_ns: i96 = t_end.raw.nanoseconds - t_start.raw.nanoseconds;
    const elapsed_s: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(@max(@as(i96, 0), elapsed_ns))))) / 1e9;

    // Summary.
    std.debug.print(
        \\
        \\Solve complete.
        \\  board:        {s}
        \\  street:       {s}
        \\  pot:          {d:.2}
        \\  stack:        {d:.2}
        \\  p1 hands:     {d}
        \\  p2 hands:     {d}
        \\  tree nodes:   {d}
        \\  iters:        {d}
        \\  wall-clock:   {d:.3}s  ({d:.2} iters/s)
        \\
        \\
    , .{
        sa.board_str.?,
        @tagName(street),
        sa.pot.?,
        sa.stack.?,
        p1.active_indices.len,
        p2.active_indices.len,
        n_nodes,
        sa.iters,
        elapsed_s,
        @as(f64, @floatFromInt(sa.iters)) / @max(elapsed_s, 1e-9),
    });

    // Root-level strategy: average over P1's reach to give a per-action
    // mass at the root decision node.
    try printRootStrategy(allocator, root, &p1, &p2);
}

fn requireNext(args: []const []const u8, i: *usize, flag: []const u8) ![]const u8 {
    if (i.* + 1 >= args.len) {
        std.debug.print("flag {s} requires a value\n", .{flag});
        return error.MissingValue;
    }
    i.* += 1;
    return args[i.*];
}

// `@path` reads the range from a file. Anything else is returned as-is.
// Caller frees via `freeIfOwned` to handle both cases.
//
// Stdin support was considered but std.fs's reader is in flux in 0.16 — skip
// for now; users can pass ranges via files or inline strings.
fn loadRangeText(
    allocator: std.mem.Allocator,
    io: std.Io,
    spec: []const u8,
) ![]const u8 {
    if (spec.len < 1 or spec[0] != '@') return spec;
    const path = spec[1..];
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(16 * 1024 * 1024));
}

fn freeIfOwned(allocator: std.mem.Allocator, spec: []const u8, text: []const u8) void {
    if (spec.len < 1 or spec[0] != '@') return;
    allocator.free(text);
}

fn printRootStrategy(
    allocator: std.mem.Allocator,
    root: *node_mod.Node,
    p1: *const Range,
    p2: *const Range,
) !void {
    _ = p2;
    if (root.is_chance) {
        std.debug.print("Root is a chance node — no actor strategy at root.\n", .{});
        return;
    }
    const n_actions = root.edges.len;
    const strat_buf = try allocator.alloc(f32, n_actions * NUM_HANDS);
    defer allocator.free(strat_buf);
    cfr.averageStrategy(root, strat_buf);

    // Reach-weighted action mass over the actor's range, so a single number
    // per action gives a quick sanity readout.
    var mass = try allocator.alloc(f32, n_actions);
    defer allocator.free(mass);
    @memset(mass, 0);
    var total: f32 = 0;
    for (p1.active_indices, p1.probs) |idx, w| {
        total += w;
        for (0..n_actions) |a| {
            mass[a] += w * strat_buf[a * NUM_HANDS + idx];
        }
    }
    if (total == 0) total = 1;

    std.debug.print("Root strategy (reach-weighted over P1's range):\n", .{});
    for (root.edges, 0..) |*edge, a| {
        std.debug.print("  {s:<6} amount={d:>8.2}  freq={d:>6.3}\n", .{
            @tagName(edge.action),
            edge.amount,
            mass[a] / total,
        });
    }
}
