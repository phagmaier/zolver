//! Thread-pool characterization benchmark (follow-up work item 2).
//!
//! Measures the three thread-pool consumers — the CFR solve iteration, the
//! exploitability pass, and the JSON output pass — at 1/2/4/8 threads on a real
//! benchmark spot, reporting BOTH wall time and total process CPU time for each.
//!
//! Why CPU time matters here: the persistent pool busy-spins its background
//! workers while idle (see `threading.zig` `workerLoop`). Wall time alone hides
//! that cost. During a *serial* phase (exploitability and output are single-
//! threaded useful work) the N-1 idle workers still burn 100% CPU each, so the
//! CPU-time/wall-time ratio climbs toward the thread count for zero speedup —
//! that ratio is the quantity item 2 needs to decide whether a spin-then-park
//! pool is worth building. For the solve phase the same ratio measures how much
//! of the fanned-out CPU is actually productive.
//!
//! This binary times work; it asserts nothing. Correctness of the parallel path
//! is guarded by the determinism tests in `cfr.zig`. It emits a machine-readable
//! JSON object on stdout (redirect it to a file) and a human table on stderr.
//!
//! Run via the build step (ReleaseFast) so the numbers mean something:
//!
//!     zig build bench-threads -Doptimize=ReleaseFast -- bench/spots/1_srp_dry.toml \
//!         > bench/out/threads/1_srp_dry.json
//!
//! Optional flags after the config path: --iters N, --warmup N,
//! --exploit-reps N, --output-reps N.

const std = @import("std");
const Zolver = @import("zolver");

const config_mod = Zolver.config;
const init_mod = Zolver.init;
const cfr_mod = Zolver.cfr;
const best_response = Zolver.best_response;
const game_tree = Zolver.game_tree;
const output_mod = Zolver.output;

const Writer = std.Io.Writer;

/// Monotonic wall clock in nanoseconds.
fn wallNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Total CPU time consumed by the whole process (all threads: main + every
/// pool worker), user + system, in nanoseconds. The delta across a phase is the
/// aggregate CPU those threads burned, spinning included.
fn cpuNs() u64 {
    const ru = std.posix.getrusage(std.posix.rusage.SELF);
    const u = @as(u64, @intCast(ru.utime.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ru.utime.usec)) * std.time.ns_per_us;
    const s = @as(u64, @intCast(ru.stime.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ru.stime.usec)) * std.time.ns_per_us;
    return u + s;
}

const thread_counts = [_]u32{ 1, 2, 4, 8 };

const Phase = struct {
    wall_ns: u64 = 0,
    cpu_ns: u64 = 0,
    reps: u64 = 1,

    fn wallMs(self: Phase) f64 {
        return @as(f64, @floatFromInt(self.wall_ns)) / @as(f64, @floatFromInt(self.reps)) / 1.0e6;
    }
    fn cpuMs(self: Phase) f64 {
        return @as(f64, @floatFromInt(self.cpu_ns)) / @as(f64, @floatFromInt(self.reps)) / 1.0e6;
    }
    /// Average cores busy = CPU time / wall time. ~1.0 means single-core-bound;
    /// approaching the thread count means every worker was busy (or spinning).
    fn util(self: Phase) f64 {
        if (self.wall_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.cpu_ns)) / @as(f64, @floatFromInt(self.wall_ns));
    }
};

const Result = struct {
    threads: u32,
    memory_mb: f64,
    solve: Phase,
    exploit: Phase,
    output: Phase,
};

const Params = struct {
    config_path: []const u8,
    // Deliberately modest: each phase call on the full physical runout space is
    // expensive (a solve iter ~0.2–1s, an exploitability pass ~2–3s, an output
    // pass ~20s+), and the quantity of interest — cores-busy / busy-spin waste —
    // is stable even at a single long sample. Bump via flags for tighter wall
    // numbers when you have the time.
    iters: u32 = 16,
    warmup: u32 = 4,
    exploit_reps: u32 = 3,
    output_reps: u32 = 1,
};

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stderr().writeStreamingAll(io, s) catch {};
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        printErr(io, "usage: bench-threads <config.toml> [--iters N] [--warmup N] [--exploit-reps N] [--output-reps N]\n", .{});
        return;
    }

    var params = Params{ .config_path = args[1] };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const field: ?*u32 =
            if (std.mem.eql(u8, a, "--iters")) &params.iters
            else if (std.mem.eql(u8, a, "--warmup")) &params.warmup
            else if (std.mem.eql(u8, a, "--exploit-reps")) &params.exploit_reps
            else if (std.mem.eql(u8, a, "--output-reps")) &params.output_reps
            else null;
        if (field) |f| {
            i += 1;
            if (i >= args.len) {
                printErr(io, "error: flag '{s}' requires a value\n", .{a});
                return;
            }
            f.* = std.fmt.parseInt(u32, args[i], 10) catch {
                printErr(io, "error: expected an integer for '{s}', got '{s}'\n", .{ a, args[i] });
                return;
            };
        } else {
            printErr(io, "error: unknown flag '{s}'\n", .{a});
            return;
        }
    }

    const content = std.Io.Dir.cwd().readFileAlloc(io, params.config_path, arena, .limited(std.math.maxInt(u32))) catch |err| {
        printErr(io, "error: failed to read config '{s}': {}\n", .{ params.config_path, err });
        return;
    };

    var diag = config_mod.Diagnostic{};
    // Kept alive for the whole run: SolverInit and the output BuildConfig
    // reference the bundle's sizings/ranges by pointer.
    const bundle = config_mod.parseConfigDiag(arena, content, &diag) catch |err| {
        if (diag.message().len > 0) {
            printErr(io, "{s}: {s}\n", .{ params.config_path, diag.message() });
        } else {
            printErr(io, "error: failed to parse config '{s}': {}\n", .{ params.config_path, err });
        }
        return;
    };

    var is = init_mod.SolverInit.init(arena, bundle.game) catch |err| {
        printErr(io, "error: failed to initialize solver: {}\n", .{err});
        return;
    };
    defer is.deinit();

    const n0 = is.ranges[0].N();
    const n1 = is.ranges[1].N();
    const turns = is.runout_tables.canonical_turns.len;
    const rivers = is.runout_tables.canonical_rivers.len;
    const cpu_count = std.Thread.getCpuCount() catch 0;

    const build_config = game_tree.BuildConfig{
        .initial_pot = bundle.game.initial_pot,
        .effective_stack = bundle.game.effective_stack,
        .min_bet = bundle.game.min_bet,
        .sizings = bundle.game.sizings,
        .raise_cap = bundle.game.raise_cap,
        .range_sizes = .{ n0, n1 },
    };

    printErr(io,
        "bench-threads: {s}\n  ranges {d}/{d}  runouts {d} turns / {d} rivers  compress_suits={}  cpu_count={d}\n" ++
        "  iters/sample={d} warmup={d} exploit-reps={d} output-reps={d}\n\n",
        .{ params.config_path, n0, n1, turns, rivers, bundle.game.compress_suits, cpu_count, params.iters, params.warmup, params.exploit_reps, params.output_reps },
    );
    printErr(io, "{s:>8} {s:>10} | {s:>11} {s:>11} {s:>7} {s:>8} | {s:>10} {s:>10} {s:>7} | {s:>10} {s:>10} {s:>7}\n", .{
        "threads", "mem(MB)",
        "solve", "cpu", "cores", "speedup",
        "exploit", "cpu", "cores",
        "output", "cpu", "cores",
    });
    printErr(io, "{s:>8} {s:>10} | {s:>11} {s:>11} {s:>7} {s:>8} | {s:>10} {s:>10} {s:>7} | {s:>10} {s:>10} {s:>7}\n", .{
        "", "", "ms/iter", "ms/iter", "", "vs 1t", "ms", "ms", "", "ms", "ms", "",
    });

    var results: [thread_counts.len]Result = undefined;

    for (thread_counts, 0..) |nt, ri| {
        var solver_config = bundle.solver;
        solver_config.num_threads = nt;

        var solver = cfr_mod.Solver.init(arena, &is, solver_config) catch |err| {
            printErr(io, "error: failed to create solver at {d} threads: {}\n", .{ nt, err });
            return;
        };
        defer solver.deinit();

        const mem_bytes = (try is.memoryBytes()) + solver.workingMemoryBytes();

        // ── Solve phase ────────────────────────────────────────────────────
        // Warm caches/branch predictors and give the strategy real mass so the
        // downstream exploitability/output passes do representative work.
        solver.iterate(params.warmup);
        var solve = Phase{ .reps = params.iters };
        {
            const w0 = wallNs();
            const c0 = cpuNs();
            solver.iterate(params.iters);
            solve.wall_ns = wallNs() - w0;
            solve.cpu_ns = cpuNs() - c0;
        }

        // ── Exploitability phase ───────────────────────────────────────────
        var exploit = Phase{ .reps = params.exploit_reps };
        {
            const w0 = wallNs();
            const c0 = cpuNs();
            var k: u32 = 0;
            while (k < params.exploit_reps) : (k += 1) {
                const e = best_response.exploitability(&solver);
                std.mem.doNotOptimizeAway(e);
            }
            exploit.wall_ns = wallNs() - w0;
            exploit.cpu_ns = cpuNs() - c0;
        }

        // ── Output phase ───────────────────────────────────────────────────
        // Default JSON dump (runout-independent flop tree with per-hand EVs) to
        // a discarding writer, matching the CLI's default output pass.
        var output = Phase{ .reps = params.output_reps };
        {
            const meta = output_mod.Meta{
                .flop = bundle.game.flop,
                .effective_stack = bundle.game.effective_stack,
                .iterations = solver.t,
                .exploitability_pct = 0,
                .exploitability_chips = 0,
                .ev_oop = solver.averageEV(0),
                .ev_ip = solver.averageEV(1),
                .converged = false,
            };
            var sink_buf: [8 * 1024]u8 = undefined;
            const w0 = wallNs();
            const c0 = cpuNs();
            var k: u32 = 0;
            while (k < params.output_reps) : (k += 1) {
                var sink = Writer.Discarding.init(&sink_buf);
                output_mod.writeJson(arena, &sink.writer, &solver, build_config, meta, .{}) catch |err| {
                    printErr(io, "error: output pass failed at {d} threads: {}\n", .{ nt, err });
                    return;
                };
            }
            output.wall_ns = wallNs() - w0;
            output.cpu_ns = cpuNs() - c0;
        }

        results[ri] = .{
            .threads = nt,
            .memory_mb = @as(f64, @floatFromInt(mem_bytes)) / (1024.0 * 1024.0),
            .solve = solve,
            .exploit = exploit,
            .output = output,
        };

        const speedup = results[0].solve.wallMs() / solve.wallMs();
        printErr(io, "{d:>8} {d:>10.1} | {d:>11.3} {d:>11.3} {d:>7.2} {d:>7.2}x | {d:>10.4} {d:>10.4} {d:>7.2} | {d:>10.4} {d:>10.4} {d:>7.2}\n", .{
            nt, results[ri].memory_mb,
            solve.wallMs(),   solve.cpuMs(),   solve.util(),   speedup,
            exploit.wallMs(), exploit.cpuMs(), exploit.util(),
            output.wallMs(),  output.cpuMs(),  output.util(),
        });
    }

    // ── Machine-readable results on stdout ─────────────────────────────────
    var out_buf: [8 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout_writer.interface;
    try w.writeAll("{\n");
    try w.print("  \"config\": \"{s}\",\n", .{params.config_path});
    try w.print("  \"compress_suits\": {},\n", .{bundle.game.compress_suits});
    try w.print("  \"n_oop\": {d}, \"n_ip\": {d},\n", .{ n0, n1 });
    try w.print("  \"canonical_turns\": {d}, \"canonical_rivers\": {d},\n", .{ turns, rivers });
    try w.print("  \"cpu_count\": {d},\n", .{cpu_count});
    try w.print("  \"iters_per_sample\": {d}, \"warmup\": {d}, \"exploit_reps\": {d}, \"output_reps\": {d},\n", .{
        params.iters, params.warmup, params.exploit_reps, params.output_reps,
    });
    try w.writeAll("  \"results\": [\n");
    for (results, 0..) |r, idx| {
        const speedup = results[0].solve.wallMs() / r.solve.wallMs();
        try w.print(
            "    {{\"threads\": {d}, \"memory_mb\": {d:.2}, \"solve_speedup_vs_1t\": {d:.4},\n" ++
            "     \"solve\":   {{\"wall_ms_per_iter\": {d:.4}, \"cpu_ms_per_iter\": {d:.4}, \"cores_busy\": {d:.4}}},\n" ++
            "     \"exploit\": {{\"wall_ms\": {d:.5}, \"cpu_ms\": {d:.5}, \"cores_busy\": {d:.4}}},\n" ++
            "     \"output\":  {{\"wall_ms\": {d:.5}, \"cpu_ms\": {d:.5}, \"cores_busy\": {d:.4}}}}}{s}\n",
            .{
                r.threads, r.memory_mb, speedup,
                r.solve.wallMs(),   r.solve.cpuMs(),   r.solve.util(),
                r.exploit.wallMs(), r.exploit.cpuMs(), r.exploit.util(),
                r.output.wallMs(),  r.output.cpuMs(),  r.output.util(),
                if (idx + 1 < results.len) "," else "",
            },
        );
    }
    try w.writeAll("  ]\n}\n");
    try w.flush();
}
