//! Lightweight performance benchmarks (Phase 10, spec §13 / plan §10.3).
//!
//!     zig run -OReleaseFast src/bench.zig
//!
//! Not part of `zig build test` — it times work rather than asserting
//! correctness. Each measurement is sized to run well under a second so it can
//! be used during development to spot regressions in the hot paths:
//! regret matching, the DCFR regret update, strategy accumulation, the showdown
//! sweep, and a full single CFR iteration (with a derived memory-bandwidth
//! figure to compare against the spec's bandwidth-bound model, §6).

const std = @import("std");
const card = @import("card.zig");
const game_tree = @import("game_tree.zig");
const init_mod = @import("init.zig");
const cfr = @import("cfr.zig");
const kernels = @import("kernels.zig");
const terminal_eval = @import("terminal_eval.zig");
const storage = @import("storage.zig");

const WeightedCombo = @import("range.zig").WeightedCombo;
const Combo = card.Combo;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Run `body` `reps` times, return ns/rep. `body` takes the rep index so the
/// optimizer can't hoist it; callers also consume an output to prevent DCE.
fn timed(reps: u64, ctx: anytype, comptime body: fn (@TypeOf(ctx), u64) void) f64 {
    const start = nowNs();
    var i: u64 = 0;
    while (i < reps) : (i += 1) body(ctx, i);
    const ns = nowNs() - start;
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(reps));
}

var sink: f32 = 0;

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

// ── Kernel micro-benchmarks ──────────────────────────────────────────────────

fn benchKernels(allocator: std.mem.Allocator) !void {
    const N: u32 = 1326; // a full hold'em range size — realistic lane count
    const A: u32 = 4;
    const len = @as(usize, A) * N;

    const regrets = try allocator.alloc(f32, len);
    defer allocator.free(regrets);
    const strat = try allocator.alloc(f32, len);
    defer allocator.free(strat);
    const child_v = try allocator.alloc(f32, len);
    defer allocator.free(child_v);
    const node_v = try allocator.alloc(f32, N);
    defer allocator.free(node_v);
    const reach = try allocator.alloc(f32, N);
    defer allocator.free(reach);
    const cumul = try allocator.alloc(f16, len);
    defer allocator.free(cumul);

    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rng = prng.random();
    for (regrets) |*x| x.* = rng.float(f32) * 2 - 1;
    for (child_v) |*x| x.* = rng.float(f32);
    for (node_v) |*x| x.* = rng.float(f32);
    for (reach) |*x| x.* = rng.float(f32);
    @memset(cumul, 0);

    const reps: u64 = 20_000;
    const slots: f64 = @floatFromInt(len);

    const Ctx = struct { regrets: []f32, strat: []f32, child_v: []f32, node_v: []f32, reach: []f32, cumul: []f16, n: u32, a: u32 };
    const ctx = Ctx{ .regrets = regrets, .strat = strat, .child_v = child_v, .node_v = node_v, .reach = reach, .cumul = cumul, .n = N, .a = A };

    std.debug.print("\nKernel throughput (N={d}, A={d}, {d} reps) — Mslots/s:\n", .{ N, A, reps });

    inline for (.{ .{ "regretMatching     ", false }, .{ "regretMatchingSimd ", true } }) |k| {
        const f = struct {
            fn body(c: Ctx, _: u64) void {
                if (k[1]) kernels.regretMatchingSimd(c.regrets, c.strat, c.n, c.a) else kernels.regretMatching(c.regrets, c.strat, c.n, c.a);
                sink += c.strat[0];
            }
        }.body;
        const ns = timed(reps, ctx, f);
        std.debug.print("  {s} {d:>8.1}\n", .{ k[0], slots / ns * 1000.0 });
    }

    inline for (.{ .{ "dcfrRegretUpdate    ", false }, .{ "dcfrRegretUpdateSimd", true } }) |k| {
        const f = struct {
            fn body(c: Ctx, _: u64) void {
                if (k[1]) kernels.dcfrRegretUpdateSimd(c.regrets, c.child_v, c.node_v, 0.6, 0.5, c.n, c.a) else kernels.dcfrRegretUpdate(c.regrets, c.child_v, c.node_v, 0.6, 0.5, c.n, c.a);
                sink += c.regrets[0];
            }
        }.body;
        const ns = timed(reps, ctx, f);
        std.debug.print("  {s} {d:>8.1}\n", .{ k[0], slots / ns * 1000.0 });
    }

    inline for (.{ .{ "accumulateStrategy    ", false }, .{ "accumulateStrategySimd", true } }) |k| {
        const f = struct {
            fn body(c: Ctx, _: u64) void {
                if (k[1]) kernels.accumulateStrategySimd(c.cumul, c.reach, c.strat, 0.9, c.n, c.a) else kernels.accumulateStrategy(c.cumul, c.reach, c.strat, 0.9, c.n, c.a);
                sink += @floatCast(c.cumul[0]);
            }
        }.body;
        const ns = timed(reps, ctx, f);
        std.debug.print("  {s} {d:>8.1}\n", .{ k[0], slots / ns * 1000.0 });
    }
}

// ── Showdown sweep + full iteration ──────────────────────────────────────────

fn benchSolve(allocator: std.mem.Allocator) !void {
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

    const n0 = is.ranges[0].N();
    const n1 = is.ranges[1].N();
    const total_bytes = storage.memoryEstimate(is.tree.slots_per_runout, is.runout_tables.runoutCounts());

    std.debug.print("\nSolve config: N0={d} N1={d} | storage={d:.1} MiB\n", .{ n0, n1, @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0) });

    // Showdown sweep: time one river runout's two-sided evaluation.
    {
        const n_max = @max(n0, n1);
        const v = try allocator.alloc(f32, n_max);
        defer allocator.free(v);
        const r = try allocator.alloc(f32, n_max);
        defer allocator.free(r);
        @memset(r, 1.0);
        var lo = [_]f32{0} ** 52;
        var eq = [_]f32{0} ** 52;
        var cs = [_]f32{0} ** 52;
        const comp = try allocator.alloc(f32, n_max);
        defer allocator.free(comp);
        const sr = try allocator.alloc(f32, n_max);
        defer allocator.free(sr);
        const sd = &is.showdown;

        const u_ci = is.card_idx[0];
        const opp_ci = is.card_idx[1];

        const Ctx = struct {
            is: *init_mod.SolverInit, v: []f32, r: []f32,
            lo: []f32, eq: []f32, cs: []f32, comp: []f32, sr: []f32,
            n0: u32, n1: u32,
            u_ci: []const u8, opp_ci: []const u8,
            sd: *const @TypeOf(is.showdown),
        };
        const ctx = Ctx{
            .is = &is, .v = v, .r = r,
            .lo = &lo, .eq = &eq, .cs = &cs, .comp = comp, .sr = sr,
            .n0 = n0, .n1 = n1,
            .u_ci = u_ci, .opp_ci = opp_ci,
            .sd = sd,
        };
        const reps: u64 = 50_000;
        const f = struct {
            fn body(c: Ctx, _: u64) void {
                @memset(c.lo, 0);
                @memset(c.eq, 0);
                @memset(c.cs, 0);
                const total = terminal_eval.computeCardSum(c.cs, c.r[0..c.n1], c.opp_ci);
                for (0..c.n0) |h| {
                    const s = c.is.same_combo_idx[0][h];
                    c.sr[h] = if (s != std.math.maxInt(u32)) c.r[s] else 0.0;
                }
                terminal_eval.showdownEval(
                    c.v[0..c.n0], c.r[0..c.n1],
                    c.u_ci, c.opp_ci,
                    c.sd.order[0][0..c.n0], c.sd.strengths[0][0..c.n0],
                    c.sd.order[1][0..c.n1], c.sd.strengths[1][0..c.n1],
                    20, 5, 10,
                    c.cs, total, c.sr,
                    c.lo, c.eq, c.comp,
                );
                sink += c.v[0];
            }
        }.body;
        const ns = timed(reps, ctx, f);
        const hands: f64 = @floatFromInt(n0 + n1);
        std.debug.print("showdown sweep: {d:.0} ns/runout ({d:.1} Mhands/s)\n", .{ ns, hands / ns * 1000.0 });
    }

    // Full single CFR iteration (serial) + derived bandwidth. One iteration is
    // two passes; the dominant traffic is regrets read≈twice + written once and
    // strategies read-modify-written once (spec §6) ≈ 3·regret + 2·strategy bytes.
    {
        var solver = try cfr.Solver.init(allocator, &is, .{ .debug_invariants = false });
        defer solver.deinit();
        solver.iterate(2); // warm caches / discount factors past t=0

        const reps: u64 = 4;
        const start = nowNs();
        solver.iterate(@intCast(reps));
        const ns_per_iter = @as(f64, @floatFromInt(nowNs() - start)) / @as(f64, @floatFromInt(reps));

        const regret_bytes: f64 = @floatFromInt(total_bytes / storage.bytes_per_slot * storage.bytes_per_regret);
        const strat_bytes: f64 = @floatFromInt(total_bytes / storage.bytes_per_slot * storage.bytes_per_strategy);
        const traffic = 3.0 * regret_bytes + 2.0 * strat_bytes;
        const gbps = traffic / ns_per_iter; // bytes/ns == GB/s
        std.debug.print("single iteration: {d:.2} ms/iter (~{d:.1} GB/s effective storage bandwidth)\n", .{ ns_per_iter / 1.0e6, gbps });
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    try benchKernels(allocator);
    try benchSolve(allocator);
    if (sink == 12345.678) std.debug.print("", .{}); // keep `sink` live
}
