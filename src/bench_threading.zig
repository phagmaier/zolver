//! Lightweight threading benchmark: serial vs N-thread wall-clock per CFR
//! iteration on a mid-size config. Run with:
//!
//!     zig run -OReleaseFast src/bench_threading.zig
//!
//! It is intentionally not part of `zig build test` (it times work rather than
//! asserting correctness — the determinism test in cfr.zig is the correctness
//! guard for the parallel path). Keep the config modest so a run stays well
//! under a few seconds.

const std = @import("std");
const card = @import("card.zig");
const game_tree = @import("game_tree.zig");
const init_mod = @import("init.zig");
const cfr = @import("cfr.zig");

const WeightedCombo = @import("range.zig").WeightedCombo;
const Combo = card.Combo;

/// Build a range of every two-card combo whose ranks are >= `min_rank` and that
/// is not blocked by the flop. Gives a few-hundred-combo range — enough work to
/// expose threading speedup without a heavyweight solve.
fn buildRange(allocator: std.mem.Allocator, flop: [3]card.Card, min_rank: u32) ![]WeightedCombo {
    var list: std.ArrayList(WeightedCombo) = .empty;
    errdefer list.deinit(allocator);

    var a: u32 = 0;
    while (a < 52) : (a += 1) {
        const ra = a / 4;
        const sa = a % 4;
        if (ra < min_rank) continue;
        const ca = card.makeCard(ra, sa);
        if (ca == flop[0] or ca == flop[1] or ca == flop[2]) continue;
        var b: u32 = a + 1;
        while (b < 52) : (b += 1) {
            const rb = b / 4;
            const sb = b % 4;
            if (rb < min_rank) continue;
            const cb = card.makeCard(rb, sb);
            if (cb == flop[0] or cb == flop[1] or cb == flop[2]) continue;
            const combo = Combo.init(ca, cb) catch continue;
            try list.append(allocator, .{ .combo = combo, .weight = 1.0 });
        }
    }
    return list.toOwnedSlice(allocator);
}

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn timeIterations(
    allocator: std.mem.Allocator,
    is: *init_mod.SolverInit,
    num_threads: u32,
    iterations: u32,
) !u64 {
    var solver = try cfr.Solver.init(allocator, is, .{ .num_threads = num_threads });
    defer solver.deinit();

    const start = nowNs();
    solver.iterate(iterations);
    return nowNs() - start;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Rainbow flop → many distinct canonical turns → meaningful parallel fan-out.
    const flop = [3]card.Card{
        card.makeCard(12, 0), // As
        card.makeCard(11, 1), // Kd
        card.makeCard(6, 2), //  7h
    };
    const min_rank: u32 = 6; // ranks 6..12 → a few hundred combos
    const range = try buildRange(allocator, flop, min_rank);
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

    const n0 = is.ranges[0].N();
    const n1 = is.ranges[1].N();
    const num_turns = is.runout_tables.canonical_turns.len;

    const iterations: u32 = 20;
    const thread_counts = [_]u32{ 0, 1, 2, 4, 8 };

    std.debug.print("range: OOP N={d}, IP N={d} | canonical turns={d} | {d} iterations\n", .{ n0, n1, num_turns, iterations });
    std.debug.print("{s:>10} {s:>14} {s:>12} {s:>10}\n", .{ "threads", "total (ms)", "ms/iter", "speedup" });

    var baseline_ns: u64 = 0;
    for (thread_counts) |nt| {
        const ns = try timeIterations(allocator, &is, nt, iterations);
        if (nt == 0) baseline_ns = ns;
        const total_ms = @as(f64, @floatFromInt(ns)) / 1.0e6;
        const ms_iter = total_ms / @as(f64, @floatFromInt(iterations));
        const speedup = @as(f64, @floatFromInt(baseline_ns)) / @as(f64, @floatFromInt(ns));
        const label = if (nt == 0) "serial" else "      ";
        std.debug.print("{d:>10} {d:>14.2} {d:>12.3} {d:>9.2}x {s}\n", .{ nt, total_ms, ms_iter, speedup, label });
    }
}
