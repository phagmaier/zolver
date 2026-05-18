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
const subgame_mod = @import("subgame.zig");
const spec_mod = @import("spec.zig");
const export_mod = @import("export.zig");

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
    } else if (std.mem.eql(u8, sub, "resolve")) {
        try cmdResolve(init, allocator, args[2..]);
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
        \\  solve     Run CFR on a postflop spot.
        \\  resolve   Re-solve a turn or river subgame from a ZON spec file.
        \\  help      Show this message.
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
        \\poker resolve <SPEC>: read a ZON spec file describing the spot,
        \\flop action path, turn card, and (optionally) river path + card.
        \\Path tokens: x=check, c=call, f=fold, j=allin, b<pct>=bet (e.g. b50, b100).
        \\See examples/turn.zon and examples/river.zon.
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
    var solver = try Solver.init(init.io, board, &p1, &p2, sa.stack.?, sa.stack.?, sa.pot.?);
    defer solver.deinit();
    solver.record_timings = true;

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

    // Root-level strategy: average over the actor's reach to give a per-action
    // mass at the root decision node.
    var reach_p1: [NUM_HANDS]f32 = undefined;
    var reach_p2: [NUM_HANDS]f32 = undefined;
    @memset(&reach_p1, 0);
    @memset(&reach_p2, 0);
    for (p1.active_indices, p1.probs) |idx, w| reach_p1[idx] = w;
    for (p2.active_indices, p2.probs) |idx, w| reach_p2[idx] = w;
    try printRootStrategy(allocator, root, &reach_p1, &reach_p2);
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
    reach_p1: []const f32,
    reach_p2: []const f32,
) !void {
    if (root.is_chance) {
        std.debug.print("Root is a chance node — no actor strategy at root.\n", .{});
        return;
    }
    const n_actions = root.edges.len;
    const strat_buf = try allocator.alloc(f32, n_actions * NUM_HANDS);
    defer allocator.free(strat_buf);
    cfr.averageStrategy(root, strat_buf);

    const actor_reach = if (root.isp1) reach_p1 else reach_p2;

    var mass = try allocator.alloc(f32, n_actions);
    defer allocator.free(mass);
    @memset(mass, 0);
    var total: f32 = 0;
    for (actor_reach, 0..) |w, idx| {
        if (w == 0) continue;
        total += w;
        for (0..n_actions) |a| {
            mass[a] += w * strat_buf[a * NUM_HANDS + idx];
        }
    }
    if (total == 0) total = 1;

    std.debug.print("Root strategy (reach-weighted over {s}'s range):\n", .{if (root.isp1) "P1" else "P2"});
    for (root.edges, 0..) |*edge, a| {
        std.debug.print("  {s:<6} amount={d:>8.2}  freq={d:>6.3}\n", .{
            @tagName(edge.action),
            edge.amount,
            mass[a] / total,
        });
    }
}

fn cmdResolve(init: std.process.Init, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("usage: poker resolve <spec.zon>\n", .{});
        return error.MissingArgs;
    }

    const spec = try spec_mod.loadSpec(allocator, init.io, args[0]);
    defer spec_mod.freeSpec(allocator, spec);

    // Board must be a flop (3 cards) — the spec's .turn / .river sections own
    // the rest of the runout.
    const flop_board = try range_parser.parseBoard(spec.board);
    var flop_card_count: usize = 0;
    for (flop_board) |c| if (c != 0) {
        flop_card_count += 1;
    };
    if (flop_card_count != 3) {
        std.debug.print("resolve: --board must be a 3-card flop, got {d} cards\n", .{flop_card_count});
        return error.BadBoard;
    }

    var hand_table = HandTable.init();
    const p1_text = try loadRangeText(allocator, init.io, spec.p1);
    defer freeIfOwned(allocator, spec.p1, p1_text);
    const p2_text = try loadRangeText(allocator, init.io, spec.p2);
    defer freeIfOwned(allocator, spec.p2, p2_text);

    var p1 = try range_parser.parseRange(p1_text, &hand_table, allocator);
    defer p1.deinit(allocator);
    var p2 = try range_parser.parseRange(p2_text, &hand_table, allocator);
    defer p2.deinit(allocator);

    var reach = subgame_mod.ReachProbs.zero();
    for (p1.active_indices, p1.probs) |idx, w| reach.p1[idx] = w;
    for (p2.active_indices, p2.probs) |idx, w| reach.p2[idx] = w;

    const turn_card = try range_parser.parseCard(spec.turn.card);

    var manager = subgame_mod.SubgameManager.init(init.io, allocator);
    defer manager.deinit();

    var prng = std.Random.DefaultPrng.init(42);

    const t_start = std.Io.Clock.Timestamp.now(init.io, .awake);

    // Flop solve → chance seeds.
    const flop_state = gamestate_mod.GameState.init(.FLOP, true, spec.pot, spec.stack, spec.stack);
    try manager.solveFlop(flop_state, flop_board, &reach, spec.iters, prng.random());

    // Walk the flop path tokens into PathSteps, then locate the matching seed.
    const flop_tokens = try spec_mod.parsePathTokens(allocator, spec.flop.path);
    defer allocator.free(flop_tokens);
    const flop_steps = try spec_mod.buildPathSteps(allocator, flop_state, flop_tokens);
    defer allocator.free(flop_steps);

    var turn = manager.solveTurnByPath(flop_steps, turn_card, spec.iters, prng.random()) catch |err| {
        if (err == error.InvalidChanceSeed) {
            std.debug.print("resolve: flop path \"{s}\" did not match any chance seed\n", .{spec.flop.path});
        }
        return err;
    };
    defer turn.deinit();

    if (spec.river) |river_spec| {
        const river_card = try range_parser.parseCard(river_spec.card);

        // Seeds from the turn subgame describe the post-turn chance fan-out.
        var turn_seeds = try turn.collectChanceSeeds(allocator);
        defer turn_seeds.deinit(allocator);

        const turn_tokens = try spec_mod.parsePathTokens(allocator, river_spec.path);
        defer allocator.free(turn_tokens);
        const turn_steps = try spec_mod.buildPathSteps(allocator, turn.root_state, turn_tokens);
        defer allocator.free(turn_steps);

        var river = subgame_mod.solveRiverFromPath(
            init.io,
            allocator,
            turn_seeds.items,
            turn_steps,
            turn.board,
            river_card,
            spec.iters,
            prng.random(),
        ) catch |err| {
            if (err == error.InvalidChanceSeed) {
                std.debug.print("resolve: turn path \"{s}\" did not match any chance seed\n", .{river_spec.path});
            }
            return err;
        };
        defer river.deinit();

        const exploit: ?f32 = if (spec.output.exploitability) try river.exploitability() else null;
        const t_end = std.Io.Clock.Timestamp.now(init.io, .awake);
        try printResolveSummary(allocator, t_start, t_end, spec, &p1, &p2, &river, .river, exploit);
        try writeStrategyCsvIfRequested(allocator, init.io, spec, &river);
    } else {
        const exploit: ?f32 = if (spec.output.exploitability) try turn.exploitability() else null;
        const t_end = std.Io.Clock.Timestamp.now(init.io, .awake);
        try printResolveSummary(allocator, t_start, t_end, spec, &p1, &p2, &turn, .turn, exploit);
        try writeStrategyCsvIfRequested(allocator, init.io, spec, &turn);
    }
}

fn writeStrategyCsvIfRequested(
    allocator: std.mem.Allocator,
    io: std.Io,
    spec: spec_mod.Spec,
    sub: *const subgame_mod.Subgame,
) !void {
    const path = spec.output.strategy_csv orelse return;

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    const actor_reach: []const f32 = if (sub.root.isp1) &sub.solver.p1_reach else &sub.solver.p2_reach;
    export_mod.writeRootStrategyCsv(allocator, &alloc_writer.writer, sub.root, actor_reach) catch |err| switch (err) {
        error.RootIsChance => {
            std.debug.print("resolve: root is a chance node; skipping strategy CSV\n", .{});
            return;
        },
        else => return err,
    };

    const bytes = alloc_writer.writer.buffered();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    std.debug.print("resolve: wrote strategy CSV ({d} bytes) to {s}\n", .{ bytes.len, path });
}

const ResolveKind = enum { turn, river };

fn printResolveSummary(
    allocator: std.mem.Allocator,
    t_start: std.Io.Clock.Timestamp,
    t_end: std.Io.Clock.Timestamp,
    spec: spec_mod.Spec,
    p1: *const Range,
    p2: *const Range,
    sub: *const subgame_mod.Subgame,
    kind: ResolveKind,
    exploit: ?f32,
) !void {
    const elapsed_ns: i96 = t_end.raw.nanoseconds - t_start.raw.nanoseconds;
    const elapsed_s: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(@max(@as(i96, 0), elapsed_ns))))) / 1e9;

    var board_buf: [10]u8 = undefined;
    const board_str = try formatBoard(&board_buf, sub.board);

    std.debug.print(
        \\
        \\Resolve complete ({s}).
        \\  flop:          {s}
        \\  full board:    {s}
        \\  flop path:     {s}
        \\  turn card:     {s}
        \\
    , .{
        @tagName(kind),
        spec.board,
        board_str,
        spec.flop.path,
        spec.turn.card,
    });

    if (spec.river) |r| {
        std.debug.print(
            \\  turn path:     {s}
            \\  river card:    {s}
            \\
        , .{ r.path, r.card });
    }

    std.debug.print(
        \\  pot:           {d:.2}
        \\  stack:         {d:.2}
        \\  p1 hands:      {d}
        \\  p2 hands:      {d}
        \\  iters:         {d}
        \\  wall-clock:    {d:.3}s
        \\
    , .{
        spec.pot,
        spec.stack,
        p1.active_indices.len,
        p2.active_indices.len,
        spec.iters,
        elapsed_s,
    });

    if (exploit) |e| {
        std.debug.print("  exploitability: {d:.6}\n", .{e});
    }
    std.debug.print("\n", .{});

    try printRootStrategy(allocator, sub.root, &sub.solver.p1_reach, &sub.solver.p2_reach);
}

fn formatBoard(buf: []u8, board: [5]card_mod.Card) ![]const u8 {
    var w: usize = 0;
    for (board) |c| {
        if (c == 0) continue;
        const s = try card_mod.get_card_str(c);
        buf[w] = s[0];
        buf[w + 1] = s[1];
        w += 2;
    }
    return buf[0..w];
}
