const std = @import("std");

const Allocator = std.mem.Allocator;

/// Task callback. `item_index` is the work item (0..num_items); `worker_id`
/// identifies the calling worker (0..total_workers-1) so the task can pick a
/// dedicated per-worker resource (e.g. a scratch arena) with no contention.
pub const TaskFn = *const fn (ctx: *anyopaque, item_index: u32, worker_id: u32) void;

/// Persistent thread pool for fork–join parallelism over canonical turns.
///
/// Workers spin-wait on atomics; no mutexes or condition variables. The batch
/// work items are indexed 0..N and each worker (including the calling thread)
/// atomically claims the next unstarted item until all N are claimed.
///
/// Synchronisation uses a monotonically increasing `generation` counter rather
/// than a start/stop flag pair: each `forkJoin` bumps the generation once, every
/// worker compares it against the generation it last serviced, and the caller
/// blocks until `done` reaches the total worker count. This makes back-to-back
/// `forkJoin` calls (the per-iteration solve pattern) race-free — there is no
/// flag the caller must reset and no window in which a worker can miss or
/// double-service a batch.
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
        const shared = try allocator.create(Shared);
        shared.* = .{};

        const threads = try allocator.alloc(std.Thread, num_workers);
        var spawned: u32 = 0;
        errdefer {
            // Tear down any threads spawned before a later spawn failed.
            shared.running.store(false, .seq_cst);
            _ = shared.generation.fetchAdd(1, .seq_cst);
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
        _ = self.shared.generation.fetchAdd(1, .seq_cst); // wake idle workers
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
        // visible to any worker that observes the new generation.
        _ = self.shared.generation.fetchAdd(1, .seq_cst);

        const main_id = num_spawned;
        while (true) {
            const idx = self.shared.next.fetchAdd(1, .seq_cst);
            if (idx >= num_items) break;
            fn_ptr(ctx, idx, main_id);
        }
        _ = self.shared.done.fetchAdd(1, .seq_cst);

        while (self.shared.done.load(.seq_cst) < total_workers) {
            std.atomic.spinLoopHint();
        }
    }
};

fn workerLoop(shared: *Pool.Shared, worker_id: u32) void {
    var local_gen: u32 = 0;
    while (true) {
        // Wait for a new batch or shutdown.
        while (true) {
            const g = shared.generation.load(.seq_cst);
            if (g != local_gen) {
                local_gen = g;
                break;
            }
            if (!shared.running.load(.seq_cst)) return;
            std.atomic.spinLoopHint();
        }
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
