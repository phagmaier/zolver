const std = @import("std");
const builtin = @import("builtin");

const node_mod = @import("node.zig");
const gamestate_mod = @import("gamestate.zig");
const cfr = @import("cfr.zig");
const scenarios_mod = @import("bench_scenarios.zig");

const Edge = node_mod.Edge;
const Solver = cfr.Solver;
const NUM_HANDS = cfr.NUM_HANDS;
const Scenario = scenarios_mod.Scenario;
const scenarios = scenarios_mod.scenarios;

// Per-(scenario, worker-count) run. Each call fully reinitializes the solver
// and rebuilds the tree so strategy / regret state starts fresh — otherwise a
// worker-count sweep would conflate per-iter speedup with accumulated state.
fn runScenarioAtWorkers(
    allocator: std.mem.Allocator,
    io: std.Io,
    s: Scenario,
    max_workers: usize,
) !void {
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

    var solver = try Solver.init(io, built.board, &built.p1, &built.p2, s.stack1, s.stack2, s.pot);
    defer solver.deinit();
    solver.max_workers = max_workers;
    solver.record_timings = true;

    var cfv_p1: [NUM_HANDS]f32 = undefined;
    var cfv_p2: [NUM_HANDS]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(42);

    if (s.warmup > 0) {
        try cfr.solve(&solver, allocator, root, s.warmup, prng.random(), &cfv_p1, &cfv_p2);
    }

    // Reset accumulator so per-(scenario, workers) runs report only their own
    // iters — bench reuses the same Solver shape but a fresh one per run.
    solver.timings = .{};

    const start = std.Io.Timestamp.now(io, .awake);
    try cfr.solve(&solver, allocator, root, s.iters, prng.random(), &cfv_p1, &cfv_p2);
    const end = std.Io.Timestamp.now(io, .awake);

    const elapsed_ns: i128 = @as(i128, end.nanoseconds) - @as(i128, start.nanoseconds);
    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const iters_per_s: f64 = @as(f64, @floatFromInt(s.iters)) / elapsed_s;
    // samples/s = strategy-update rate × walks-per-update. The right metric
    // for parallel scaling: each parallel iter dispatches `max_workers`
    // walks, so adding workers raises samples/s even when iters/s falls.
    const samples_per_s: f64 = iters_per_s * @as(f64, @floatFromInt(@max(@as(usize, 1), max_workers)));

    // Per-iter breakdown (parallel path only; serial path leaves timings at
    // zero, so the breakdown line is skipped for workers=1).
    if (solver.timings.iter_count > 0) {
        const n = @as(f64, @floatFromInt(solver.timings.iter_count));
        const spawn_us = @as(f64, @floatFromInt(solver.timings.spawn_ns)) / 1e3 / n;
        const join_us = @as(f64, @floatFromInt(solver.timings.join_ns)) / 1e3 / n;
        const merge_us = @as(f64, @floatFromInt(solver.timings.merge_ns)) / 1e3 / n;
        std.debug.print(
            "{s:<26} workers={d:<2} iters={d:<5} nodes={d:<6} time={d:>7.3}s  iters/s={d:>8.2}  samples/s={d:>9.2}  spawn/join/merge us/iter = {d:>7.1} / {d:>9.1} / {d:>7.1}\n",
            .{ s.name, max_workers, s.iters, n_nodes, elapsed_s, iters_per_s, samples_per_s, spawn_us, join_us, merge_us },
        );
    } else {
        std.debug.print(
            "{s:<26} workers={d:<2} iters={d:<5} nodes={d:<6} time={d:>7.3}s  iters/s={d:>8.2}  samples/s={d:>9.2}\n",
            .{ s.name, max_workers, s.iters, n_nodes, elapsed_s, iters_per_s, samples_per_s },
        );
    }
}

// Full worker sweep: surfaces parallel scaling at a glance (rule of thumb is
// 8x at 8 workers; well below that means thread overhead or work imbalance).
// Opt in with `--scaling`. Default runs only at cpu_count, which is what you
// actually care about during day-to-day perf work.
const WORKER_SWEEP_FULL = [_]usize{ 1, 2, 4, 8 };

fn runScenario(allocator: std.mem.Allocator, io: std.Io, s: Scenario, workers_list: []const usize) !void {
    for (workers_list) |w| {
        try runScenarioAtWorkers(allocator, io, s, w);
    }
}

pub fn main(init: std.process.Init) !void {
    var da = std.heap.DebugAllocator(.{}){};
    const allocator = if (builtin.mode == .Debug) da.allocator() else std.heap.smp_allocator;
    defer _ = da.deinit();

    const io = init.io;
    const cpu_count: usize = std.Thread.getCpuCount() catch 1;

    // Argument parsing: `--scaling` runs the full {1,2,4,8} worker sweep,
    // `--quick` skips the slow flop scenarios entirely. Default is one run
    // per scenario at cpu_count workers.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var scaling: bool = false;
    var quick: bool = false;
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--scaling")) {
            scaling = true;
        } else if (std.mem.eql(u8, arg, "--quick")) {
            quick = true;
        }
    }

    var default_workers_buf: [1]usize = .{@min(cpu_count, 8)};
    const workers_list: []const usize = if (scaling) &WORKER_SWEEP_FULL else default_workers_buf[0..];

    std.debug.print(
        "Poker bench  optimize={s}  cpus={d}  mode={s}{s}\n",
        .{
            @tagName(builtin.mode),
            cpu_count,
            if (scaling) "scaling" else "default",
            if (quick) " quick" else "",
        },
    );
    std.debug.print("{s}\n", .{"-" ** 72});

    for (scenarios) |s| {
        // The flop-trunc scenarios pay a multi-second per-iter cost (full
        // (turn, river) enumeration at every leaf). Skip them in --quick.
        if (quick and s.street == .FLOP) continue;
        try runScenario(allocator, io, s, workers_list);
    }
}
