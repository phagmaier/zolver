const std = @import("std");

const Zolver = @import("zolver");

const config_mod = Zolver.config;
const init_mod = Zolver.init;
const cfr_mod = Zolver.cfr;
const best_response = Zolver.best_response;
const game_tree = Zolver.game_tree;
const output_mod = Zolver.output;
const summary_mod = Zolver.summary;
const parse = Zolver.parse;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    if (args.len < 2) {
        try runConfig(io);
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "solve")) {
        if (args.len < 3) {
            try printToStderr(io, "usage: zolver solve <config.toml> [--summary] [--output <path>] [--turn <card>] [--river <card>] [--all-runouts]\n");
            return;
        }
        const config_path = args[2];
        var output_path: ?[]const u8 = null;
        var options = output_mod.Options{};
        var print_summary = false;

        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--output") or std.mem.eql(u8, a, "-o")) {
                i += 1;
                if (i >= args.len) {
                    try printToStderr(io, "error: --output requires a path\n");
                    return;
                }
                output_path = args[i];
            } else if (std.mem.eql(u8, a, "--turn")) {
                i += 1;
                if (i >= args.len) {
                    try printToStderr(io, "error: --turn requires a card (e.g. 2c)\n");
                    return;
                }
                options.turn = parse.parseCard(args[i]) catch {
                    try printFormatted(io, "error: invalid turn card '{s}'\n", .{args[i]});
                    return;
                };
            } else if (std.mem.eql(u8, a, "--river")) {
                i += 1;
                if (i >= args.len) {
                    try printToStderr(io, "error: --river requires a card (e.g. Ah)\n");
                    return;
                }
                options.river = parse.parseCard(args[i]) catch {
                    try printFormatted(io, "error: invalid river card '{s}'\n", .{args[i]});
                    return;
                };
            } else if (std.mem.eql(u8, a, "--all-runouts")) {
                options.all_runouts = true;
            } else if (std.mem.eql(u8, a, "--summary")) {
                print_summary = true;
            } else {
                try printFormatted(io, "error: unknown solve option '{s}'\n", .{a});
                return;
            }
        }

        if (options.river != null and options.turn == null) {
            try printToStderr(io, "error: --river requires --turn\n");
            return;
        }

        try runSolve(arena, io, config_path, output_path, options, print_summary);
    } else if (std.mem.eql(u8, cmd, "example")) {
        var output_path: ?[]const u8 = null;
        if (args.len >= 3) {
            if (std.mem.eql(u8, args[2], "--output")) {
                if (args.len >= 4) output_path = args[3];
            } else {
                output_path = args[2];
            }
        }
        try runExample(arena, io, output_path);
    } else if (std.mem.eql(u8, cmd, "view")) {
        if (args.len < 3) {
            try printToStderr(io, "usage: zolver view <results.json>\n");
            return;
        }
        try runView(arena, io, args[2]);
    } else if (std.mem.eql(u8, cmd, "config")) {
        try runConfig(io);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printUsage(io);
    } else {
        try printToStderr(io, "unknown command: ");
        try printToStderr(io, cmd);
        try printToStderr(io, "\n");
        try printUsage(io);
    }
}

fn printUsage(io: std.Io) !void {
    try printToStderr(io,
        \\Zolver — heads-up post-flop Texas Hold'em solver
        \\
        \\Usage:
        \\  zolver               opens the visual config builder
        \\  zolver solve  <config.toml> [flags]
        \\  zolver view   <results.json>
        \\  zolver config
        \\  zolver example [--output <path>]
        \\  zolver help
        \\
        \\  --summary        print a human-readable flop strategy overview to the terminal
        \\
        \\Output (JSON via --output / -o):
        \\  default          per-hand flop strategy tree + EVs (runout-independent)
        \\  --turn <card>    also dump the turn subtree for that runout, e.g. --turn 2c
        \\  --river <card>   also dump the river subtree (requires --turn), e.g. --river Ah
        \\  --all-runouts    dump every canonical turn/river runout (large; EVs omitted)
        \\
    );
}

fn printToStderr(io: std.Io, msg: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, msg);
}

fn printFormatted(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, args);
    try std.Io.File.stderr().writeStreamingAll(io, s);
}

fn runSolve(
    arena: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    output_path: ?[]const u8,
    options: output_mod.Options,
    print_summary: bool,
) !void {
    const start_ts = std.Io.Clock.now(.awake, io);

    const content = std.Io.Dir.cwd().readFileAlloc(io, config_path, arena, .limited(std.math.maxInt(u32))) catch |err| {
        try printFormatted(io, "error: failed to read config '{s}': {}\n", .{ config_path, err });
        return;
    };

    var diag = config_mod.Diagnostic{};
    var bundle = config_mod.parseConfigDiag(arena, content, &diag) catch |err| {
        if (diag.message().len > 0) {
            if (diag.line > 0) {
                try printFormatted(io, "{s}:{d}: {s}\n", .{ config_path, diag.line, diag.message() });
            } else {
                try printFormatted(io, "{s}: {s}\n", .{ config_path, diag.message() });
            }
        } else {
            try printFormatted(io, "error: failed to parse config '{s}': {}\n", .{ config_path, err });
        }
        return;
    };

    var is = init_mod.SolverInit.init(arena, bundle.game) catch |err| {
        try printFormatted(io, "error: failed to initialize solver: {}\n", .{err});
        return;
    };
    defer is.deinit();

    const solver_config = bundle.solver;

    // Capture everything the JSON output walk needs before the config arena is
    // freed: the betting structure (to re-derive action labels) and the flop.
    const flop = bundle.game.flop;
    const effective_stack = bundle.game.effective_stack;
    var owned_sizings: [3][]const game_tree.Sizing = undefined;
    for (0..3) |s| owned_sizings[s] = try arena.dupe(game_tree.Sizing, bundle.game.sizings[s]);
    const build_config = game_tree.BuildConfig{
        .initial_pot = bundle.game.initial_pot,
        .effective_stack = effective_stack,
        .min_bet = bundle.game.min_bet,
        .sizings = owned_sizings,
        .raise_cap = bundle.game.raise_cap,
        .range_sizes = .{ is.ranges[0].N(), is.ranges[1].N() },
    };

    bundle.deinit();

    const n0 = is.ranges[0].N();
    const n1 = is.ranges[1].N();
    const action_count = is.tree.action_nodes.items.len;
    const terminal_count = is.tree.terminal_nodes.items.len;
    const turns = is.runout_tables.canonical_turns.len;
    const rivers = is.runout_tables.canonical_rivers.len;

    var solver = cfr_mod.Solver.init(arena, &is, solver_config) catch |err| {
        try printFormatted(io, "error: failed to create solver: {}\n", .{err});
        return;
    };
    // Joins the worker thread pool on exit; without this a threaded solve
    // segfaults at process teardown (threads outlive the data they reference).
    defer solver.deinit();

    const mem_bytes = (try is.memoryBytes()) + solver.workingMemoryBytes();
    try printFormatted(io, "loaded '{s}'\n", .{config_path});
    try printFormatted(io, "  ranges: {d}/{d} combos  tree: {d} actions, {d} terminals  runouts: {d} turns, {d} rivers\n", .{
        n0, n1, action_count, terminal_count, turns, rivers,
    });
    try printFormatted(io, "  memory: {d:.1} MB  threads: {d}\n", .{
        @as(f32, @floatFromInt(mem_bytes)) / (1024 * 1024), solver_config.num_threads,
    });

    try printToStderr(io, "solving...\n");

    var last_exp = best_response.exploitability(&solver);
    try printFormatted(io, "  start  exploitability: {d:.3}% ({d:.3} chips)\n", .{ last_exp.pct, last_exp.chips });

    const cfg = solver.config;
    const solve_start = std.Io.Clock.now(.awake, io);

    while (solver.t < cfg.max_iterations) {
        solver.iterate(1);
        if (best_response.shouldCheck(solver.t, cfg.check_interval)) {
            last_exp = best_response.exploitability(&solver);
            const now = std.Io.Clock.now(.awake, io);
            const elapsed_s = @as(f32, @floatFromInt(now.nanoseconds - solve_start.nanoseconds)) / @as(f32, @floatFromInt(std.time.ns_per_s));
            try printFormatted(io, "  iter {d:>6}  exploitability: {d:6.3}% ({d:.3} chips)  {d:.1}s\n", .{
                solver.t, last_exp.pct, last_exp.chips, elapsed_s,
            });
            // Defense-in-depth: a non-finite exploitability means the solver
            // diverged (e.g. an accumulator overflowed). Surface it loudly and
            // stop rather than running on and emitting NaN results. This check
            // runs in every build, unlike the Debug-only invariant sweeps.
            if (!std.math.isFinite(last_exp.pct)) {
                try printToStderr(io, "  error: exploitability became non-finite (NaN/Inf) — solver diverged; stopping\n");
                break;
            }
            if (last_exp.pct <= cfg.target_exploitability_pct) break;
        }
    }

    const end_ts = std.Io.Clock.now(.awake, io);
    const total_secs = @as(f32, @floatFromInt(end_ts.nanoseconds - start_ts.nanoseconds)) / @as(f32, @floatFromInt(std.time.ns_per_s));

    try printFormatted(io, "solve complete: {d} iterations, {d:.3}% exploitability, {d:.1}s elapsed\n", .{
        solver.t, last_exp.pct, total_secs,
    });

    const z = if (last_exp.z > 0) last_exp.z else 1.0;
    const ev0 = solver.averageEV(0) / z;
    const ev1 = solver.averageEV(1) / z;

    {
        var buf: [1024]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &buf);
        try stdout_writer.interface.print("iterations: {d}\n", .{solver.t});
        try stdout_writer.interface.print("exploitability_pct: {d:.4}\n", .{last_exp.pct});
        try stdout_writer.interface.print("exploitability_chips: {d:.4}\n", .{last_exp.chips});
        try stdout_writer.interface.print("avg_ev_oop: {d:.4}\n", .{ev0});
        try stdout_writer.interface.print("avg_ev_ip: {d:.4}\n", .{ev1});
        try stdout_writer.interface.print("initial_pot: {d}\n", .{is.tree.initial_pot});
        try stdout_writer.interface.print("elapsed_s: {d:.2}\n", .{total_secs});
        try stdout_writer.interface.print("converged: {}\n", .{last_exp.pct <= cfg.target_exploitability_pct});
        try stdout_writer.interface.flush();
    }

    if (print_summary) {
        var sbuf: [16 * 1024]u8 = undefined;
        var summary_writer = std.Io.File.stdout().writer(io, &sbuf);
        summary_mod.printSummary(arena, &summary_writer.interface, &solver, build_config, flop) catch |err| {
            try printFormatted(io, "error: failed to print summary: {}\n", .{err});
            return;
        };
        try summary_writer.interface.flush();
    }

    if (output_path) |path| {
        // Never emit invalid JSON (e.g. `-nan`) — a non-finite result means the
        // solve diverged and the strategy is meaningless.
        if (!std.math.isFinite(last_exp.pct) or !std.math.isFinite(last_exp.chips) or
            !std.math.isFinite(ev0) or !std.math.isFinite(ev1))
        {
            try printFormatted(io, "error: refusing to write '{s}': solve produced non-finite results (NaN/Inf)\n", .{path});
            return;
        }
        if (options.all_runouts) {
            try printToStderr(io, "  --all-runouts: dumping every canonical runout (this can be very large; per-hand EVs are omitted)\n");
        }

        const meta = output_mod.Meta{
            .flop = flop,
            .effective_stack = effective_stack,
            .iterations = solver.t,
            .exploitability_pct = last_exp.pct,
            .exploitability_chips = last_exp.chips,
            .ev_oop = ev0,
            .ev_ip = ev1,
            .converged = last_exp.pct <= cfg.target_exploitability_pct,
        };

        const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
            try printFormatted(io, "error: failed to create output '{s}': {}\n", .{ path, err });
            return;
        };
        defer file.close(io);

        var out_buf: [64 * 1024]u8 = undefined;
        var file_writer = file.writer(io, &out_buf);
        output_mod.writeJson(arena, &file_writer.interface, &solver, build_config, meta, options) catch |err| {
            try printFormatted(io, "error: failed to write output '{s}': {}\n", .{ path, err });
            return;
        };
        try file_writer.interface.flush();

        try printFormatted(io, "output written to '{s}'\n", .{path});
    }
}

fn runExample(arena: std.mem.Allocator, io: std.Io, output_path: ?[]const u8) !void {
    _ = arena;
    const example =
        \\# Zolver solver configuration
        \\# See README for full documentation
        \\
        \\[game]
        \\# Three flop cards (rank + suit: 2-9,T,J,Q,K,A + s,h,d,c)
        \\flop = "As Kd 7h"
        \\# Pot size at the start of flop betting
        \\initial_pot = 100
        \\# Smaller of the two remaining stacks
        \\effective_stack = 150
        \\# Minimum bet increment (optional, default: 1)
        \\min_bet = 1
        \\# Max memory budget in bytes (optional, default: 8 GB)
        \\# Increase for large trees with many sizings/raises; lower to avoid swap
        \\max_budget_bytes = 8589934592
        \\
        \\[game.sizings]
        \\# Bet size fractions as percentages of the pot
        \\# Empty list [] means check/all-in only
        \\# This starter uses a small tree so it solves in a few seconds; add more
        \\# sizings / raises (and raise the effective stack) for a richer solve.
        \\flop = [33, 75]
        \\turn = [66]
        \\river = [75]
        \\
        \\[game.raise_cap]
        \\# Max number of raises per street (omit or "none"/"unlimited" for no cap)
        \\flop = 1
        \\turn = 1
        \\river = 0
        \\
        \\[ranges]
        \\# Range format: HAND[SUFFIX][:WEIGHT], comma-separated
        \\#   AK       = all 16 combos (suited + offsuit)
        \\#   AKs      = suited only (4 combos)
        \\#   AKo      = offsuit only (12 combos)
        \\#   88       = pocket pair (6 combos, suffix ignored)
        \\#   :0.75    = frequency weight (default: 1.0)
        \\# Plus/dash ranges (Equilab/Flopzilla style):
        \\#   QQ+      = QQ, KK, AA            (pairs up to AA)
        \\#   ATs+     = ATs, AJs, AQs, AKs    (ace fixed, kicker climbs)
        \\#   T9s+     = T9s, JTs, ... AKs      (gap preserved, climbs to A)
        \\#   99-66    = 99, 88, 77, 66        (pair run)
        \\#   A5s-A2s  = A5s, A4s, A3s, A2s    (kicker run, ace fixed)
        \\#   JTs-87s  = JTs, T9s, 98s, 87s    (connector run)
        \\oop = "AJo:0.75, ATo:0.12, 88:0.5, AKs, KQs:0.3"
        \\ip = "AA:0.8, KK:0.8, QQ:0.5, JTs:0.6, T9s:0.6"
        \\
        \\[solver]
        \\# Algorithm: "dcfr" (default) or "cfr_plus"
        \\algorithm = "dcfr"
        \\# Max solve iterations (default: 1000)
        \\max_iterations = 1000
        \\# Stop when exploitability reaches this % of initial pot (default: 0.5)
        \\target_exploitability_pct = 0.5
        \\# Number of worker threads, 0 = serial (default: 0)
        \\num_threads = 4
        \\# Skip subtrees with zero opponent reach (default: false)
        \\prune_zero_reach = false
        \\# Use SIMD kernels (default: true)
        \\use_simd = true
        \\# Interval between exploitability checks after 128 iters (default: 64)
        \\check_interval = 64
        \\
        \\[solver.dcfr]
        \\# DCFR discounting parameters (defaults shown)
        \\alpha = 1.5
        \\beta = 0.0
        \\gamma = 2.0
    ;

    if (output_path) |path| {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, example);
        try printFormatted(io, "example config written to '{s}'\n", .{path});
    } else {
        var buf: [1024]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &buf);
        try stdout_writer.interface.writeAll(example);
    }
}

fn runView(arena: std.mem.Allocator, io: std.Io, json_path: []const u8) !void {
    const viewer_template = @embedFile("web/viewer.html");
    const sentinel = "__ZV_DATA_PLACEHOLDER__";

    const idx = std.mem.indexOf(u8, viewer_template, sentinel) orelse {
        try printToStderr(io, "error: viewer template is malformed\n");
        return;
    };
    const prefix = viewer_template[0..idx];
    const suffix = viewer_template[idx + sentinel.len ..];

    const json = std.Io.Dir.cwd().readFileAlloc(io, json_path, arena, .limited(std.math.maxInt(u32))) catch |err| {
        try printFormatted(io, "error: failed to read '{s}': {}\n", .{ json_path, err });
        return;
    };

    const total_len = prefix.len + json.len + suffix.len;
    const output = try arena.alloc(u8, total_len);
    @memcpy(output[0..prefix.len], prefix);
    @memcpy(output[prefix.len..][0..json.len], json);
    @memcpy(output[prefix.len + json.len ..], suffix);

    const temp_dir = std.fs.path.dirname(json_path) orelse ".";
    const temp_path = try std.fs.path.join(arena, &.{ temp_dir, "zolver-viewer.html" });

    const file = std.Io.Dir.cwd().createFile(io, temp_path, .{}) catch |err| {
        try printFormatted(io, "error: failed to create '{s}': {}\n", .{ temp_path, err });
        return;
    };
    defer file.close(io);
    file.writeStreamingAll(io, output) catch |err| {
        try printFormatted(io, "error: failed to write viewer to '{s}': {}\n", .{ temp_path, err });
        return;
    };

    try printFormatted(io, "viewer written to '{s}'\n", .{temp_path});
    openBrowser(io, temp_path);
}

fn runConfig(io: std.Io) !void {
    const config_html = @embedFile("web/config.html");

    const temp_path = "zolver-config.html";
    const file = std.Io.Dir.cwd().createFile(io, temp_path, .{}) catch |err| {
        try printFormatted(io, "error: failed to create '{s}': {}\n", .{ temp_path, err });
        return;
    };
    defer file.close(io);
    file.writeStreamingAll(io, config_html) catch |err| {
        try printFormatted(io, "error: failed to write config builder to '{s}': {}\n", .{ temp_path, err });
        return;
    };

    try printFormatted(io, "config builder written to '{s}'\n", .{temp_path});
    openBrowser(io, temp_path);
}

fn openBrowser(io: std.Io, path: []const u8) void {
    const builtin = @import("builtin");
    const cmd: []const u8 = switch (builtin.os.tag) {
        .windows => "start",
        .macos, .ios => "open",
        else => "xdg-open",
    };

    _ = std.process.spawn(io, .{
        .argv = &.{ cmd, path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
}
