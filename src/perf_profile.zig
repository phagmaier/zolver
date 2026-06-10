//! Dedicated profiling target for `perf` (and friends).
//!
//! Unlike `bench.zig`, this runs *only* the full CFR solve hot path in a tight
//! loop so the profile isn't polluted by the kernel micro-benchmarks or the
//! showdown-sweep harness. Build it as a standalone optimized binary with frame
//! pointers + debug info, then run it under `perf record`:
//!
//!     zig build-exe -OReleaseFast -fno-omit-frame-pointer \
//!         -femit-bin=zig-out/perf_profile src/perf_profile.zig
//!     perf record --call-graph dwarf -- ./zig-out/perf_profile
//!     perf report --stdio
//!
//! Tunables via env vars (defaults: 40 iterations, serial):
//!     PERF_ITERS=40 PERF_THREADS=0 ./zig-out/perf_profile
//! PERF_THREADS=0 means serial (no thread pool).
//!
//! Uses the same 300-combo rainbow-flop config as bench.zig's benchSolve so the
//! numbers are comparable.

const std = @import("std");
const card = @import("card.zig");
const game_tree = @import("game_tree.zig");
const init_mod = @import("init.zig");
const cfr = @import("cfr.zig");
const storage = @import("storage.zig");

const WeightedCombo = @import("range.zig").WeightedCombo;
const Combo = card.Combo;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn buildRange(allocator: std.mem.Allocator, flop: [3]card.Card, min_rank: u32) ![]WeightedCombo {
    var list: std.ArrayList(WeightedCombo) = .empty;
    errdefer list.deinit(allocator);
    var a: u32 = 0;
    while (a < 52) : (a += 1) {
        const ra = a / 4;
        if (ra < min_rank) continue;
        const ca = card.makeCard(ra, a % 4);
        if (ca == flop[0] or ca == flop[1] or ca == flop[2]) continue;
        var b: u32 = a + 1;
        while (b < 52) : (b += 1) {
            const rb = b / 4;
            if (rb < min_rank) continue;
            const cb = card.makeCard(rb, b % 4);
            if (cb == flop[0] or cb == flop[1] or cb == flop[2]) continue;
            try list.append(allocator, .{ .combo = Combo.init(ca, cb) catch continue, .weight = 1.0 });
        }
    }
    return list.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;

    const iters: u32 = if (init.environ.getPosix("PERF_ITERS")) |s| (std.fmt.parseInt(u32, s, 10) catch 40) else 40;
    const num_threads: u32 = if (init.environ.getPosix("PERF_THREADS")) |s| (std.fmt.parseInt(u32, s, 10) catch 0) else 0;

    const flop = [3]card.Card{ card.makeCard(12, 0), card.makeCard(11, 1), card.makeCard(6, 2) };
    const range = try buildRange(allocator, flop, 6);
    defer allocator.free(range);

    const one_sizing = [_]game_tree.Sizing{game_tree.Sizing.init(75, 100)};
    const sizings: [3][]const game_tree.Sizing = .{ &one_sizing, &one_sizing, &one_sizing };
    const config = init_mod.Config{
        .flop = flop,
        .initial_pot = 20,
        .effective_stack = 20,
        .min_bet = 2,
        .sizings = sizings,
        .raise_cap = .{ 1, 1, 1 },
        .oop_range = range,
        .ip_range = range,
        .max_budget_bytes = std.math.maxInt(u64),
    };
    var is = try init_mod.SolverInit.init(allocator, config);
    defer is.deinit();

    const total_bytes = storage.memoryEstimate(is.tree.slots_per_runout, is.runout_tables.runoutCounts());
    std.debug.print(
        "perf_profile: N0={d} N1={d} | storage={d:.1} MiB | iters={d} threads={d}\n",
        .{ is.ranges[0].N(), is.ranges[1].N(), @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0), iters, num_threads },
    );

    var solver = try cfr.Solver.init(allocator, &is, .{
        .num_threads = num_threads,
        .debug_invariants = false,
    });
    defer solver.deinit();

    solver.iterate(2); // warm caches / push discount factors past t=0

    const start = nowNs();
    solver.iterate(iters);
    const ns = nowNs() - start;
    const ms_per_iter = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters)) / 1.0e6;
    std.debug.print("done: {d:.2} ms/iter over {d} iters\n", .{ ms_per_iter, iters });
}
