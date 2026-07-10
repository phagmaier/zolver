const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const Allocator = std.mem.Allocator;

/// Task callback. `item_index` is the work item (0..num_items); `worker_id`
/// identifies the calling worker (0..total_workers-1) so the task can pick a
/// dedicated per-worker resource (e.g. a scratch arena) with no contention.
pub const TaskFn = *const fn (ctx: *anyopaque, item_index: u32, worker_id: u32) void;

/// How long an idle worker keeps spinning before parking on `generation`.
///
/// One solve iteration issues many `forkJoin` calls with sub-millisecond serial
/// gaps between batches. Parking on every gap would syscall thousands of times
/// per iteration and regress the hot path. This budget is sized to bridge those
/// gaps so workers only park on the seconds-long serial phases (exploitability,
/// JSON output). Tune against `zig build bench-threads`: solve `ms/iter` and
/// `cores_busy` (~7.9 at 8t) must stay flat while exploit/output `cores_busy`
/// drop toward ~1.0.
///
/// On a ~3 GHz core with `pause` ≈ 40 cycles, 100_000 spins is ~1 ms of busy
/// wait — enough for inter-batch gaps, negligible against multi-second serial
/// work.
const spin_before_park: u32 = 100_000;

/// Persistent thread pool for fork–join parallelism over canonical turns.
///
/// Workers use adaptive spin-then-park on a generation counter: a short busy
/// spin covers the sub-ms gaps between the many `forkJoin` calls inside one
/// solve iteration, then workers park via a Linux futex on `generation` until
/// the next batch (or shutdown). The calling thread always participates and
/// only does a short spin wait on `done` at the end of each batch.
///
/// Parking tradeoff (deliberately Linux futex, not `std.Io.Condition`):
/// Zig 0.16 moved Mutex/Condition/Futex onto `std.Io`, which would require
/// threading an `io` handle through `Pool.init` and `Solver.init` (CLI already
/// has one; every test would need to construct one). Direct `std.os.linux`
/// futex wait/wake on `generation` needs no `io` plumbing and matches the
/// existing `std.os.linux.clock_gettime` usage in the bench/threading code.
/// Cost: Linux-only (same as the rest of the solver's timing path).
///
/// The batch work items are indexed 0..N and each worker (including the calling
/// thread) atomically claims the next unstarted item until all N are claimed.
///
/// Synchronisation uses a monotonically increasing `generation` counter rather
/// than a start/stop flag pair: each `forkJoin` bumps the generation once,
/// wakes any parked workers, every worker compares it against the generation it
/// last serviced, and the caller blocks until `done` reaches the total worker
/// count. This makes back-to-back `forkJoin` calls (the per-iteration solve
/// pattern) race-free — there is no flag the caller must reset and no window in
/// which a worker can miss or double-service a batch. Parking only changes
/// *when* workers wake, not which item they claim or the canonical reduction
/// order, so serial and N-threaded solves stay byte-identical.
///
/// Shared state lives in a heap-allocated `Shared` struct so worker threads
/// always reference valid memory even if the `Pool` value is moved.
pub const Pool = struct {
    allocator: Allocator,
    threads: []std.Thread,
    shared: *Shared,

    const Shared = struct {
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        /// Bumped once per batch; workers wake when it differs from their local copy.
        /// Also the futex word parked workers block on (Linux FUTEX_WAIT/WAKE).
        generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        num: u32 = 0,
        next: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        fn_ptr: ?TaskFn = null,
        ctx: ?*anyopaque = null,
    };

    /// Spawn `num_workers` persistent threads. The caller (main thread)
    /// participates in every batch, so total workers = num_workers + 1.
    /// Pass 0 to run everything on the calling thread (no background threads).
    pub fn init(allocator: Allocator, num_workers: u32) !Pool {
        if (builtin.os.tag != .linux) {
            @compileError("threading.Pool spin-then-park requires Linux futex");
        }

        const shared = try allocator.create(Shared);
        shared.* = .{};

        const threads = try allocator.alloc(std.Thread, num_workers);
        var spawned: u32 = 0;
        errdefer {
            // Tear down any threads spawned before a later spawn failed.
            shared.running.store(false, .seq_cst);
            publishGeneration(shared);
            for (threads[0..spawned]) |t| t.join();
            allocator.free(threads);
            allocator.destroy(shared);
        }
        while (spawned < num_workers) : (spawned += 1) {
            threads[spawned] = try std.Thread.spawn(.{}, workerLoop, .{ shared, spawned });
        }
        return .{
            .allocator = allocator,
            .threads = threads,
            .shared = shared,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.shared.running.store(false, .seq_cst);
        publishGeneration(self.shared); // wake parked workers for shutdown
        for (self.threads) |t| t.join();
        self.allocator.free(self.threads);
        self.allocator.destroy(self.shared);
    }

    /// Execute `fn_ptr(ctx, i, worker_id)` for i in 0..num_items across all
    /// workers. Blocks until every item has been processed. The calling thread
    /// runs as the highest-numbered worker.
    pub fn forkJoin(self: *Pool, fn_ptr: TaskFn, ctx: *anyopaque, num_items: u32) void {
        if (num_items == 0) return;
        const num_spawned: u32 = @intCast(self.threads.len);
        const total_workers: u32 = num_spawned + 1; // +calling thread

        self.shared.fn_ptr = fn_ptr;
        self.shared.ctx = ctx;
        self.shared.num = num_items;
        self.shared.next.store(0, .seq_cst);
        self.shared.done.store(0, .seq_cst);
        // Publish the batch. The release on `generation` makes the writes above
        // visible to any worker that observes the new generation; the futex wake
        // unparks anyone who already finished spinning.
        publishGeneration(self.shared);

        const main_id = num_spawned;
        while (true) {
            const idx = self.shared.next.fetchAdd(1, .seq_cst);
            if (idx >= num_items) break;
            fn_ptr(ctx, idx, main_id);
        }
        _ = self.shared.done.fetchAdd(1, .seq_cst);

        // Caller-side wait is genuinely short (workers finish within the same
        // batch); a pure spin is fine and avoids a second parking path.
        while (self.shared.done.load(.seq_cst) < total_workers) {
            std.atomic.spinLoopHint();
        }
    }
};

/// Bump `generation` and wake every worker parked on that word.
fn publishGeneration(shared: *Pool.Shared) void {
    _ = shared.generation.fetchAdd(1, .seq_cst);
    futexWakeAll(&shared.generation.raw);
}

fn futexWakeAll(ptr: *const u32) void {
    // FUTEX_WAKE with no waiters is cheap; always waking keeps the path simple
    // and avoids a separate "anyone parked?" flag that would race with spin-then-park.
    switch (linux.errno(linux.futex_3arg(
        ptr,
        .{ .cmd = .WAKE, .private = true },
        std.math.maxInt(i32),
    ))) {
        .SUCCESS => {},
        .INVAL => {}, // stray wait elsewhere; not fatal for our private word
        .FAULT => {}, // pointer became invalid during teardown races — ignore
        else => {},
    }
}

fn futexWait(ptr: *const u32, expected: u32) void {
    // Returns immediately with EAGAIN if *ptr != expected (generation already
    // advanced), so the classic check-then-wait race is safe.
    switch (linux.errno(linux.futex_4arg(
        ptr,
        .{ .cmd = .WAIT, .private = true },
        expected,
        null,
    ))) {
        .SUCCESS => {}, // woken by publishGeneration
        .INTR => {}, // signal; caller rechecks generation
        .AGAIN => {}, // *ptr != expected already
        .INVAL => {},
        .FAULT => {},
        else => {},
    }
}

fn workerLoop(shared: *Pool.Shared, worker_id: u32) void {
    var local_gen: u32 = 0;
    while (true) {
        // Wait for a new batch or shutdown: spin briefly, then park on generation.
        waitForGeneration(shared, &local_gen);
        // A generation bump with `running == false` is the shutdown signal, not
        // a real batch (fn_ptr/ctx are stale). The release/acquire on
        // `generation` guarantees we observe the `running` store that preceded it.
        if (!shared.running.load(.seq_cst)) return;

        const fn_ptr = shared.fn_ptr.?;
        const ctx = shared.ctx.?;
        const num_items = shared.num;

        while (true) {
            const idx = shared.next.fetchAdd(1, .seq_cst);
            if (idx >= num_items) break;
            fn_ptr(ctx, idx, worker_id);
        }
        _ = shared.done.fetchAdd(1, .seq_cst);
    }
}

/// Spin up to `spin_before_park` times looking for a new generation, then park
/// on the futex until `publishGeneration` wakes us. Updates `local_gen` to the
/// observed generation before returning.
fn waitForGeneration(shared: *Pool.Shared, local_gen: *u32) void {
    while (true) {
        var spins: u32 = 0;
        while (spins < spin_before_park) : (spins += 1) {
            const g = shared.generation.load(.seq_cst);
            if (g != local_gen.*) {
                local_gen.* = g;
                return;
            }
            if (!shared.running.load(.seq_cst)) return;
            std.atomic.spinLoopHint();
        }

        // Spin budget exhausted. Re-check once more before parking so a bump
        // that landed in the last pause doesn't force a needless syscall.
        const g = shared.generation.load(.seq_cst);
        if (g != local_gen.*) {
            local_gen.* = g;
            return;
        }
        if (!shared.running.load(.seq_cst)) return;

        // Park until generation changes from the value we last observed.
        futexWait(&shared.generation.raw, local_gen.*);
        // Loop: re-evaluate (handles spurious wake / EINTR / EAGAIN).
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Pool: forkJoin processes all items" {
    const alloc = testing.allocator;
    var pool = try Pool.init(alloc, 2);
    defer pool.deinit();

    const ItemCtx = struct {
        counters: []std.atomic.Value(u32),
        fn task(ctx: *anyopaque, idx: u32, _: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.counters[idx].fetchAdd(1, .seq_cst);
        }
    };

    const num_items: u32 = 100;
    const counters = try alloc.alloc(std.atomic.Value(u32), num_items);
    defer alloc.free(counters);
    for (counters) |*c| c.* = std.atomic.Value(u32).init(0);

    var ctx = ItemCtx{ .counters = counters };
    pool.forkJoin(ItemCtx.task, @ptrCast(&ctx), num_items);

    for (counters) |c| {
        try testing.expectEqual(@as(u32, 1), c.load(.seq_cst));
    }
}

test "Pool: repeated forkJoin batches are race-free" {
    const alloc = testing.allocator;
    var pool = try Pool.init(alloc, 3);
    defer pool.deinit();

    const num_items: u32 = 64;
    const counters = try alloc.alloc(std.atomic.Value(u32), num_items);
    defer alloc.free(counters);
    for (counters) |*c| c.* = std.atomic.Value(u32).init(0);

    const ItemCtx = struct {
        counters: []std.atomic.Value(u32),
        fn task(ctx: *anyopaque, idx: u32, _: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.counters[idx].fetchAdd(1, .seq_cst);
        }
    };
    var ctx = ItemCtx{ .counters = counters };

    // Hammer the pool with many back-to-back batches; every item must be hit
    // exactly once per batch.
    const batches: u32 = 200;
    var b: u32 = 0;
    while (b < batches) : (b += 1) {
        pool.forkJoin(ItemCtx.task, @ptrCast(&ctx), num_items);
    }
    for (counters) |c| {
        try testing.expectEqual(batches, c.load(.seq_cst));
    }
}

test "Pool: worker ids are within range and stable" {
    const alloc = testing.allocator;
    const num_workers: u32 = 3;
    var pool = try Pool.init(alloc, num_workers);
    defer pool.deinit();

    const total: u32 = num_workers + 1;
    const seen = try alloc.alloc(std.atomic.Value(u32), total);
    defer alloc.free(seen);
    for (seen) |*s| s.* = std.atomic.Value(u32).init(0);

    const Ctx = struct {
        seen: []std.atomic.Value(u32),
        total: u32,
        fn task(ctx: *anyopaque, _: u32, worker_id: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            std.debug.assert(worker_id < self.total);
            _ = self.seen[worker_id].fetchAdd(1, .seq_cst);
        }
    };
    var ctx = Ctx{ .seen = seen, .total = total };
    pool.forkJoin(Ctx.task, @ptrCast(&ctx), 10_000);

    // The guarantees are: every worker id stayed in range (asserted inside the
    // task) and every item was claimed exactly once. We deliberately do NOT
    // require an even split across workers — with trivially cheap items a single
    // fast thread can drain the whole batch before another worker wakes, so
    // "every worker ran" is scheduler-dependent, not an invariant (it flakes on
    // faster machines / some platforms). Assert exact, race-free coverage.
    var sum: u32 = 0;
    for (seen) |s| sum += s.load(.seq_cst);
    try testing.expectEqual(@as(u32, 10_000), sum);
}

test "Pool: zero items returns immediately" {
    const alloc = testing.allocator;
    var pool = try Pool.init(alloc, 1);
    defer pool.deinit();

    pool.forkJoin(struct {
        fn nop(_: *anyopaque, _: u32, _: u32) void {}
    }.nop, @ptrCast(@constCast(&{})), 0);
}

test "Pool: single-threaded (0 workers) works" {
    const alloc = testing.allocator;
    var pool = try Pool.init(alloc, 0);
    defer pool.deinit();

    const Ctx = struct {
        sum: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        fn task(ctx: *anyopaque, idx: u32, _: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.sum.fetchAdd(idx + 1, .seq_cst);
        }
    };

    var ctx = Ctx{};
    pool.forkJoin(Ctx.task, @ptrCast(&ctx), 10);

    try testing.expectEqual(@as(u32, 55), ctx.sum.load(.seq_cst));
}

test "Pool: workers park across a long serial gap" {
    // Exercise the park path: one batch, then a multi-spin_before_park sleep on
    // the main thread, then another batch. Workers must wake via futex, not
    // spin the whole gap. Correctness-only — we don't assert CPU here.
    const alloc = testing.allocator;
    var pool = try Pool.init(alloc, 2);
    defer pool.deinit();

    const Ctx = struct {
        hits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        fn task(ctx: *anyopaque, _: u32, _: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.hits.fetchAdd(1, .seq_cst);
        }
    };
    var ctx = Ctx{};

    pool.forkJoin(Ctx.task, @ptrCast(&ctx), 8);
    // ~5 ms sleep — well past the ~1 ms spin budget — so workers park.
    const req = linux.timespec{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
    _ = linux.nanosleep(&req, null);
    pool.forkJoin(Ctx.task, @ptrCast(&ctx), 8);

    try testing.expectEqual(@as(u32, 16), ctx.hits.load(.seq_cst));
}
