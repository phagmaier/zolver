const std = @import("std");
const game_tree = @import("game_tree.zig");
const init_mod = @import("init.zig");
const scratch_mod = @import("scratch.zig");
const kernels = @import("kernels.zig");
const terminal_eval = @import("terminal_eval.zig");
const threading = @import("threading.zig");

const Allocator = std.mem.Allocator;
const SolverInit = init_mod.SolverInit;
const Scratch = scratch_mod.Scratch;
const Tree = game_tree.Tree;
const Street = game_tree.Street;
const NodeRef = game_tree.NodeRef;
const TerminalNode = game_tree.TerminalNode;
const DcfrParams = kernels.DcfrParams;

pub const Algorithm = enum { dcfr, cfr_plus };

pub const WalkMode = enum {
    solve,
    evaluate,
    best_response,
    average,

    fn maximizes(self: WalkMode) bool {
        return self == .best_response;
    }
    fn usesAverage(self: WalkMode) bool {
        return self == .best_response or self == .average;
    }
    fn writes(self: WalkMode) bool {
        return self == .solve;
    }
    fn parallel(self: WalkMode) bool {
        return self == .solve or self == .best_response;
    }
};

pub const SolverConfig = struct {
    algorithm: Algorithm = .dcfr,
    dcfr: DcfrParams = .{},
    prune_zero_reach: bool = false,
    use_simd: bool = true,
    max_iterations: u32 = 1000,
    target_exploitability_pct: f32 = 0.5,
    check_interval: u32 = 64,
    num_threads: u32 = 0,
    /// When true, run debug invariant sweeps (NaN/Inf scan of the regret arrays)
    /// after every pass. Defaults on in Debug builds, off otherwise; the spec
    /// (§9, §13) calls for these only in debug builds. Has no effect on the
    /// solved result — purely a correctness tripwire.
    debug_invariants: bool = (@import("builtin").mode == .Debug),

    /// Reject configurations that would produce undefined or nonsensical solves.
    pub fn validate(self: SolverConfig) error{InvalidSolverConfig}!void {
        if (!std.math.isFinite(self.dcfr.alpha) or self.dcfr.alpha < 0) return error.InvalidSolverConfig;
        if (!std.math.isFinite(self.dcfr.beta) or self.dcfr.beta < 0) return error.InvalidSolverConfig;
        if (!std.math.isFinite(self.dcfr.gamma) or self.dcfr.gamma < 0) return error.InvalidSolverConfig;
        if (self.max_iterations == 0) return error.InvalidSolverConfig;
        if (!std.math.isFinite(self.target_exploitability_pct) or self.target_exploitability_pct < 0) return error.InvalidSolverConfig;
    }
};

/// Lightweight context carrying all the solver state a recursive walk needs.
/// Multiple WalkCtx instances can exist concurrently (one per thread), each
/// with its own `scratch`, while sharing the read-only `is`.
pub const WalkCtx = struct {
    is: *const SolverInit,
    scratch: *Scratch,
    allocator: Allocator,
    N: [2]u32,
    u: u8,
    opp: u8,
    pos_discount: f32,
    neg_discount: f32,
    strat_scale: f32,
    t: u32,
    probe: bool,
    use_simd: bool,
    prune_zero_reach: bool,
    algorithm: Algorithm,
    /// If non-null, used to parallelise flop→turn chance nodes.
    pool: ?*threading.Pool = null,
    /// Worker scratches (borrowed); only accessed when `pool != null`. Indexed
    /// by the pool's `worker_id`, so each physical worker owns one arena.
    worker_scratches: []Scratch = &.{},
    /// Pre-allocated `num_turns × N_max` reduction buffer for the parallel
    /// flop→turn dispatch (borrowed). Only one flop→turn section is ever live at
    /// a time — the flop descent is serial — so a single buffer is reused across
    /// all such nodes, passes, and iterations. Empty when `pool == null`.
    turn_results: []f32 = &.{},
    /// Optional per-node value capture, used only by the `.average` query pass
    /// (`Solver.captureNodeValues`). The matching/copy code compiles only into
    /// the `.average` specialization of `walk`, so the `.solve` hot path is
    /// unaffected.
    capture: ?Capture = null,

    pub const Capture = struct {
        node_ref: NodeRef,
        runout_id: u32,
        out: []f32,
        found: *bool,
    };

    /// Copy this node's CFV vector into the capture buffer if it is the target.
    /// `node_ref` is globally unique and `runout_id` selects the runout instance,
    /// so the pair identifies a single node visit (no `street` needed).
    fn tryCapture(self: *WalkCtx, node_ref: NodeRef, runout_id: u32, node_v: []const f32) void {
        const cap = self.capture orelse return;
        if (node_ref == cap.node_ref and runout_id == cap.runout_id) {
            @memcpy(cap.out[0..node_v.len], node_v);
            cap.found.* = true;
        }
    }

    // ── The recursive walk ───────────────────────────────────────────────

    fn walk(
        self: *WalkCtx,
        node_ref: NodeRef,
        street: Street,
        runout_id: u32,
        reach_u: []f32,
        reach_opp: []f32,
        depth: u32,
        comptime mode: WalkMode,
    ) []f32 {
        if (self.prune_zero_reach and sum(reach_opp) == 0.0) {
            const nv = self.scratch.nodeValues(depth, self.N[self.u]);
            @memset(nv, 0);
            if (comptime mode == .average) self.tryCapture(node_ref, runout_id, nv);
            return nv;
        }
        const v = switch (game_tree.refTag(node_ref) catch unreachable) {
            .terminal => self.evalTerminal(
                self.is.tree.terminal_nodes.items[game_tree.refIndex(node_ref)],
                street,
                runout_id,
                reach_u,
                reach_opp,
                depth,
            ),
            .chance => self.walkChance(node_ref, street, runout_id, reach_u, reach_opp, depth, mode),
            .action => self.walkAction(node_ref, street, runout_id, reach_u, reach_opp, depth, mode),
        };
        if (comptime mode == .average) self.tryCapture(node_ref, runout_id, v);
        return v;
    }

    pub fn walkRuntime(
        self: *WalkCtx,
        node_ref: NodeRef,
        street: Street,
        runout_id: u32,
        reach_u: []f32,
        reach_opp: []f32,
        depth: u32,
        mode: WalkMode,
    ) []f32 {
        return switch (mode) {
            .solve => self.walk(node_ref, street, runout_id, reach_u, reach_opp, depth, .solve),
            .best_response => self.walk(node_ref, street, runout_id, reach_u, reach_opp, depth, .best_response),
            .evaluate => self.walk(node_ref, street, runout_id, reach_u, reach_opp, depth, .evaluate),
            .average => self.walk(node_ref, street, runout_id, reach_u, reach_opp, depth, .average),
        };
    }

    fn walkAction(
        self: *WalkCtx,
        node_ref: NodeRef,
        street: Street,
        runout_id: u32,
        reach_u: []f32,
        reach_opp: []f32,
        depth: u32,
        comptime mode: WalkMode,
    ) []f32 {
        const tree = &self.is.tree;
        const node = tree.action_nodes.items[game_tree.refIndex(node_ref)];
        const a: u32 = node.num_children;
        const player = node.player;
        const n_act = self.N[player];
        const edges = tree.edges.items;
        const n_u = self.N[self.u];

        const spr = tree.slots_per_runout[street.index()];
        const block: usize = @intCast(@as(u64, runout_id) * spr + node.base);
        const len: usize = @as(usize, a) * n_act;

        if (mode.maximizes() and player == self.u) {
            const node_v = self.scratch.nodeValues(depth, n_u);
            var ai: u32 = 0;
            while (ai < a) : (ai += 1) {
                const child_v = self.walk(edges[node.first_child_edge + ai], street, runout_id, reach_u, reach_opp, depth + 1, mode);
                if (ai == 0) {
                    @memcpy(node_v, child_v);
                } else {
                    for (node_v, child_v) |*m, v| m.* = @max(m.*, v);
                }
            }
            return node_v;
        }

        const strat = self.scratch.strategy(depth, n_act, a);
        if (mode.usesAverage()) {
            self.averageStrategy(street, runout_id, node_ref, strat);
        } else if (self.use_simd) {
            kernels.regretMatchingSimd(self.streetRegrets(street)[block .. block + len], strat, n_act, a);
        } else {
            kernels.regretMatching(self.streetRegrets(street)[block .. block + len], strat, n_act, a);
        }

        if (player == self.u) {
            var ai: u32 = 0;
            while (ai < a) : (ai += 1) {
                const child_ru = self.scratch.reachU(depth + 1, n_act);
                const sigma_a = strat[@as(usize, ai) * n_act ..][0..n_act];
                for (child_ru, reach_u, sigma_a) |*dst, ru, s| dst.* = ru * s;
                const child_v = self.walk(edges[node.first_child_edge + ai], street, runout_id, child_ru, reach_opp, depth + 1, mode);
                @memcpy(self.scratch.childValue(depth, n_act, ai), child_v);
            }

            const node_v = self.scratch.nodeValues(depth, n_act);
            @memset(node_v, 0);
            ai = 0;
            while (ai < a) : (ai += 1) {
                const sigma_a = strat[@as(usize, ai) * n_act ..][0..n_act];
                if (self.use_simd) {
                    kernels.weightedAccumulateSimd(node_v, sigma_a, self.scratch.childValue(depth, n_act, ai));
                } else {
                    kernels.weightedAccumulate(node_v, sigma_a, self.scratch.childValue(depth, n_act, ai));
                }
            }

            if (mode.writes()) {
                const child_values = self.scratch.childValues(depth, n_act, a);
                const strat_store = self.streetStrategies(street)[block .. block + len];
                const regret_block = self.streetRegrets(street)[block .. block + len];
                switch (self.algorithm) {
                    .dcfr => {
                        if (self.use_simd) {
                            kernels.dcfrRegretUpdateSimd(regret_block, child_values, node_v, self.pos_discount, self.neg_discount, n_act, a);
                            kernels.accumulateStrategySimd(strat_store, reach_u, strat, self.strat_scale, n_act, a);
                        } else {
                            kernels.dcfrRegretUpdate(regret_block, child_values, node_v, self.pos_discount, self.neg_discount, n_act, a);
                            kernels.accumulateStrategy(strat_store, reach_u, strat, self.strat_scale, n_act, a);
                        }
                    },
                    .cfr_plus => {
                        if (self.use_simd) {
                            kernels.cfrRegretUpdateSimd(regret_block, child_values, node_v, n_act, a);
                            kernels.cfrAccumulateStrategySimd(strat_store, reach_u, strat, self.t, n_act, a);
                        } else {
                            kernels.cfrRegretUpdate(regret_block, child_values, node_v, n_act, a);
                            kernels.cfrAccumulateStrategy(strat_store, reach_u, strat, self.t, n_act, a);
                        }
                    },
                }
            }
            return node_v;
        } else {
            const node_v = self.scratch.nodeValues(depth, n_u);
            @memset(node_v, 0);
            var ai: u32 = 0;
            while (ai < a) : (ai += 1) {
                const child_ro = self.scratch.reachOpp(depth + 1, n_act);
                const sigma_a = strat[@as(usize, ai) * n_act ..][0..n_act];
                for (child_ro, reach_opp, sigma_a) |*dst, ro, s| dst.* = ro * s;
                const child_v = self.walk(edges[node.first_child_edge + ai], street, runout_id, reach_u, child_ro, depth + 1, mode);
                if (self.use_simd) {
                    kernels.unweightedAccumulateSimd(node_v, child_v);
                } else {
                    kernels.unweightedAccumulate(node_v, child_v);
                }
            }
            return node_v;
        }
    }

    fn walkChance(
        self: *WalkCtx,
        node_ref: NodeRef,
        street: Street,
        runout_id: u32,
        reach_u: []f32,
        reach_opp: []f32,
        depth: u32,
        comptime mode: WalkMode,
    ) []f32 {
        _ = street;
        const node = self.is.tree.chance_nodes.items[game_tree.refIndex(node_ref)];
        const next_street: Street = @enumFromInt(node.next_street);
        const n_u = self.N[self.u];
        const n_opp = self.N[self.opp];

        const node_v = self.scratch.nodeValues(depth, n_u);
        @memset(node_v, 0);

        switch (next_street) {
            .turn => {
                if (comptime mode.parallel()) {
                    if (self.pool) |pool| {
                        self.walkChanceTurnParallel(node.child, n_u, n_opp, reach_u, reach_opp, node_v, depth, mode, pool);
                        return node_v;
                    }
                }
                for (self.is.runout_tables.canonical_turns, 0..) |_, t| {
                    const child_runout: u32 = @intCast(t);
                    self.descendChance(
                        node.child, .turn, child_runout,
                        self.is.mask_turn[self.u][child_runout * n_u ..][0..n_u],
                        self.is.mask_turn[self.opp][child_runout * n_opp ..][0..n_opp],
                        self.is.weight_turns[t],
                        reach_u, reach_opp, node_v, depth, mode,
                    );
                }
            },
            .river => {
                const turn = self.is.runout_tables.canonical_turns[runout_id];
                var r: u32 = 0;
                while (r < turn.num_rivers) : (r += 1) {
                    const full = turn.first_river + r;
                    self.descendChance(
                        node.child, .river, full,
                        self.is.mask_river[self.u][full * n_u ..][0..n_u],
                        self.is.mask_river[self.opp][full * n_opp ..][0..n_opp],
                        self.is.weight_rivers[full],
                        reach_u, reach_opp, node_v, depth, mode,
                    );
                }
            },
            .flop => unreachable,
        }
        return node_v;
    }

    fn descendChance(
        self: *WalkCtx,
        child_ref: NodeRef,
        child_street: Street,
        child_runout: u32,
        m_u: []const f32,
        m_opp: []const f32,
        weight: f32,
        reach_u: []f32,
        reach_opp: []f32,
        node_v: []f32,
        depth: u32,
        comptime mode: WalkMode,
    ) void {
        const n_u = self.N[self.u];
        const n_opp = self.N[self.opp];
        const child_ru = self.scratch.reachU(depth + 1, n_u);
        const child_ro = self.scratch.reachOpp(depth + 1, n_opp);
        if (self.use_simd) {
            kernels.maskMultiplySimd(child_ru, reach_u, m_u);
            kernels.maskedScaleSimd(child_ro, reach_opp, m_opp, weight);
        } else {
            kernels.maskMultiply(child_ru, reach_u, m_u);
            kernels.maskedScale(child_ro, reach_opp, m_opp, weight);
        }

        const child_v = self.walk(child_ref, child_street, child_runout, child_ru, child_ro, depth + 1, mode);

        if (self.use_simd) {
            kernels.weightedAccumulateSimd(node_v, m_u, child_v);
        } else {
            kernels.weightedAccumulate(node_v, m_u, child_v);
        }
    }

    /// Per-turn task context for the parallel flop→turn dispatch. The pool calls
    /// `process(ctx, turn_index, worker_id)`; each invocation evaluates exactly
    /// one canonical turn into its own `results` slot using the scratch arena
    /// dedicated to `worker_id`, so there is no contention and no aliasing.
    const TurnTask = struct {
        wc: *WalkCtx,
        child_ref: NodeRef,
        n_u: u32,
        n_opp: u32,
        parent_ru: []const f32,
        parent_ro: []const f32,
        results: []f32,
        mask_u_all: []const f32,
        mask_opp_all: []const f32,
        weights: []const f32,
        depth: u32,
        use_simd: bool,
        mode: WalkMode,
        worker_scratches: []Scratch,

        fn process(ctx_ptr: *anyopaque, t: u32, worker_id: u32) void {
            const ctx: *TurnTask = @ptrCast(@alignCast(ctx_ptr));
            // Per-thread copy of the walk context with its own scratch arena.
            var worker_ctx = ctx.wc.*;
            worker_ctx.scratch = &ctx.worker_scratches[worker_id];

            const child_depth = ctx.depth + 1;
            const m_u = ctx.mask_u_all[t * ctx.n_u ..][0..ctx.n_u];
            const m_opp = ctx.mask_opp_all[t * ctx.n_opp ..][0..ctx.n_opp];

            const child_ru = worker_ctx.scratch.reachU(child_depth, ctx.n_u);
            const child_ro = worker_ctx.scratch.reachOpp(child_depth, ctx.n_opp);
            if (ctx.use_simd) {
                kernels.maskMultiplySimd(child_ru, ctx.parent_ru, m_u);
                kernels.maskedScaleSimd(child_ro, ctx.parent_ro, m_opp, ctx.weights[t]);
            } else {
                kernels.maskMultiply(child_ru, ctx.parent_ru, m_u);
                kernels.maskedScale(child_ro, ctx.parent_ro, m_opp, ctx.weights[t]);
            }

            const child_v = worker_ctx.walkRuntime(ctx.child_ref, .turn, t, child_ru, child_ro, child_depth, ctx.mode);

            // Mask the returned CFVs (3.3) straight into this turn's result slot;
            // overwrites in full, so no pre-zeroing of `results` is needed.
            const result_slot = ctx.results[t * ctx.n_u ..][0..ctx.n_u];
            if (ctx.use_simd) {
                kernels.maskMultiplySimd(result_slot, child_v, m_u);
            } else {
                kernels.maskMultiply(result_slot, child_v, m_u);
            }
        }
    };

    /// Parallel flop→turn dispatch using the persistent pool. Each canonical
    /// turn is one work item; the pool's atomic counter hands items to workers
    /// dynamically (good load balance), each writing its own `results` slot.
    /// Results are then reduced in canonical-turn order for byte-for-byte
    /// determinism regardless of which worker processed which turn. No hot-path
    /// allocation and no per-node thread spawning.
    fn walkChanceTurnParallel(
        self: *WalkCtx,
        child_ref: NodeRef,
        n_u: u32,
        n_opp: u32,
        reach_u: []f32,
        reach_opp: []f32,
        node_v: []f32,
        depth: u32,
        comptime mode: WalkMode,
        pool: *threading.Pool,
    ) void {
        const is = self.is;
        const num_turns: u32 = @intCast(is.runout_tables.canonical_turns.len);
        const needed: usize = @as(usize, num_turns) * n_u;
        std.debug.assert(needed <= self.turn_results.len);
        const results = self.turn_results[0..needed];

        var task = TurnTask{
            .wc = self,
            .child_ref = child_ref,
            .n_u = n_u,
            .n_opp = n_opp,
            .parent_ru = reach_u,
            .parent_ro = reach_opp,
            .results = results,
            .mask_u_all = is.mask_turn[self.u],
            .mask_opp_all = is.mask_turn[self.opp],
            .weights = is.weight_turns,
            .depth = depth,
            .use_simd = self.use_simd,
            .mode = mode,
            .worker_scratches = self.worker_scratches,
        };

        pool.forkJoin(TurnTask.process, @ptrCast(&task), num_turns);

        // Reduce in canonical-turn order → fixed summation order → deterministic.
        for (0..num_turns) |t| {
            const r = results[t * n_u ..][0..n_u];
            if (self.use_simd) {
                kernels.unweightedAccumulateSimd(node_v, r);
            } else {
                kernels.unweightedAccumulate(node_v, r);
            }
        }
    }

    const AllInFlopTask = struct {
        wc: *WalkCtx,
        n_u: u32,
        n_opp: u32,
        reach_opp: []const f32,
        ctx: terminal_eval.AllInContext,
        results: []f32,

        fn process(ctx_ptr: *anyopaque, t: u32, worker_id: u32) void {
            const task: *AllInFlopTask = @ptrCast(@alignCast(ctx_ptr));
            const worker_scratch = if (task.wc.pool != null)
                &task.wc.worker_scratches[worker_id]
            else
                task.wc.scratch;
            const ais = worker_scratch.allInScratch(task.n_u, task.n_opp);

            const result_slot = task.results[t * task.n_u ..][0..task.n_u];
            @memset(result_slot, 0);

            const turn = task.ctx.rt.canonical_turns[t];
            terminal_eval.accumulateTurnRivers(
                result_slot, task.reach_opp, turn, task.ctx.weight_turns[t], false, task.ctx, ais
            );
        }
    };

    fn allInEvalFlopParallel(
        self: *WalkCtx,
        n_u: u32,
        n_opp: u32,
        reach_opp: []const f32,
        node_v: []f32,
        ctx: terminal_eval.AllInContext,
    ) void {
        const num_turns: u32 = @intCast(ctx.rt.canonical_turns.len);
        const needed: usize = @as(usize, num_turns) * n_u;
        std.debug.assert(needed <= self.turn_results.len);
        const results = self.turn_results[0..needed];

        var task = AllInFlopTask{
            .wc = self,
            .n_u = n_u,
            .n_opp = n_opp,
            .reach_opp = reach_opp,
            .ctx = ctx,
            .results = results,
        };

        if (self.pool) |pool| {
            pool.forkJoin(AllInFlopTask.process, @ptrCast(&task), num_turns);
        } else {
            for (0..num_turns) |t| {
                AllInFlopTask.process(&task, @intCast(t), 0);
            }
        }

        @memset(node_v, 0);
        for (0..num_turns) |t| {
            const r = results[t * n_u ..][0..n_u];
            if (self.use_simd) {
                kernels.unweightedAccumulateSimd(node_v, r);
            } else {
                kernels.unweightedAccumulate(node_v, r);
            }
        }
    }

    fn evalTerminal(
        self: *WalkCtx,
        term: TerminalNode,
        street: Street,
        runout_id: u32,
        reach_u: []f32,
        reach_opp: []f32,
        depth: u32,
    ) []f32 {
        _ = reach_u;
        const is = self.is;
        const u = self.u;
        const opp = self.opp;
        const n_u = self.N[u];
        const n_opp = self.N[opp];
        const node_v = self.scratch.nodeValues(depth, n_u);
        const u_hands = is.ranges[u].hands;
        const opp_hands = is.ranges[opp].hands;
        const u_ci = is.card_idx[u];
        const opp_ci = is.card_idx[opp];

        const ip_f: f32 = @floatFromInt(is.tree.initial_pot);

        switch (term.kind) {
            .fold => {
                const amount = if (self.probe) ip_f else foldUtility(is.tree.initial_pot, term, self.u);
                @memset(self.scratch.cardsum, 0);
                terminal_eval.foldEval(
                    node_v, reach_opp,
                    u_ci, opp_ci,
                    is.same_combo_idx[u], amount, self.scratch.cardsum,
                );
            },
            .showdown => {
                const c = if (self.probe)
                    ShowdownCoeffs{ .win = ip_f, .loss = -ip_f, .tie = ip_f }
                else
                    showdownCoeffsFor(is.tree.initial_pot, term.pot);
                if (street == .river) {
                    @memset(self.scratch.cardsum, 0);
                    @memset(self.scratch.lo_card, 0);
                    const sd = &is.showdown;

                    // Precompute cardsum + total (was computeCardSum inside showdownEval).
                    const total = terminal_eval.computeCardSum(self.scratch.cardsum, reach_opp, opp_ci);

                    // Precompute same_reach[h] = reach_opp[same] for each u-hand.
                    const same_idx = is.same_combo_idx[u];
                    const same_reach = self.scratch.same_reach[0..n_u];
                    for (0..n_u) |h| {
                        const s = same_idx[h];
                        same_reach[h] = if (s != std.math.maxInt(u32)) reach_opp[s] else 0.0;
                    }

                    terminal_eval.showdownEval(
                        node_v, reach_opp,
                        u_ci, opp_ci,
                        sd.order[u][runout_id * n_u ..][0..n_u],
                        sd.strengths[u][runout_id * n_u ..][0..n_u],
                        sd.order[opp][runout_id * n_opp ..][0..n_opp],
                        sd.strengths[opp][runout_id * n_opp ..][0..n_opp],
                        c.win, c.loss, c.tie,
                        self.scratch.cardsum, total, same_reach,
                        self.scratch.lo_card, self.scratch.eq_card,
                        self.scratch.compat,
                    );
                } else {
                    const ctx = terminal_eval.AllInContext{
                        .u = u,
                        .sd = &is.showdown,
                        .rt = &is.runout_tables,
                        .card_idx = .{ is.card_idx[0], is.card_idx[1] },
                        .u_hands = u_hands,
                        .opp_hands = opp_hands,
                        .mask_river = .{ is.mask_river[0], is.mask_river[1] },
                        .weight_rivers = is.weight_rivers,
                        .weight_turns = is.weight_turns,
                        .same_combo_idx = is.same_combo_idx[u],
                        .win_amount = c.win,
                        .loss_amount = c.loss,
                        .tie_amount = c.tie,
                    };
                    const ais = self.scratch.allInScratch(n_u, n_opp);
                    if (street == .turn) {
                        terminal_eval.allInEvalTurn(node_v, reach_opp, runout_id, ctx, ais);
                    } else {
                        self.allInEvalFlopParallel(n_u, n_opp, reach_opp, node_v, ctx);
                    }
                }
            },
        }
        return node_v;
    }

    fn streetRegrets(self: *WalkCtx, street: Street) []f32 {
        return switch (street) {
            .flop => self.is.storage.regrets_flop,
            .turn => self.is.storage.regrets_turn,
            .river => self.is.storage.regrets_river,
        };
    }

    fn streetStrategies(self: *WalkCtx, street: Street) []f32 {
        return switch (street) {
            .flop => self.is.storage.strategies_flop,
            .turn => self.is.storage.strategies_turn,
            .river => self.is.storage.strategies_river,
        };
    }

    pub fn averageStrategy(self: *WalkCtx, street: Street, runout_id: u32, node_ref: NodeRef, out: []f32) void {
        const tree = &self.is.tree;
        const node = tree.action_nodes.items[game_tree.refIndex(node_ref)];
        const a: u32 = node.num_children;
        const n = self.N[node.player];
        const spr = tree.slots_per_runout[street.index()];
        const block: usize = @intCast(@as(u64, runout_id) * spr + node.base);
        const strat = self.streetStrategies(street);

        const inv_a: f32 = 1.0 / @as(f32, @floatFromInt(a));
        var h: u32 = 0;
        while (h < n) : (h += 1) {
            var total: f32 = 0;
            var ai: u32 = 0;
            while (ai < a) : (ai += 1) {
                total += @floatCast(strat[block + @as(usize, ai) * n + h]);
            }
            ai = 0;
            while (ai < a) : (ai += 1) {
                const idx = @as(usize, ai) * n + h;
                out[idx] = if (total > 0)
                    @as(f32, @floatCast(strat[block + idx])) / total
                else
                    inv_a;
            }
        }
    }

    /// Normalized average strategy for a single hand `h` at an action node.
    /// Writes the `A` action probabilities to `out[0..A]`. Uniform where the
    /// cumulative strategy sums to zero (a never-reached infoset).
    pub fn averageStrategyHand(self: *WalkCtx, street: Street, runout_id: u32, node_ref: NodeRef, h: u32, out: []f32) void {
        const tree = &self.is.tree;
        const node = tree.action_nodes.items[game_tree.refIndex(node_ref)];
        const a: u32 = node.num_children;
        const n = self.N[node.player];
        const spr = tree.slots_per_runout[street.index()];
        const block: usize = @intCast(@as(u64, runout_id) * spr + node.base);
        const strat = self.streetStrategies(street);

        var total: f32 = 0;
        var ai: u32 = 0;
        while (ai < a) : (ai += 1) total += @floatCast(strat[block + @as(usize, ai) * n + h]);

        const inv_a: f32 = 1.0 / @as(f32, @floatFromInt(a));
        ai = 0;
        while (ai < a) : (ai += 1) {
            const s: f32 = @floatCast(strat[block + @as(usize, ai) * n + h]);
            out[ai] = if (total > 0) s / total else inv_a;
        }
    }
};

/// Single-threaded (or pooled multi-threaded) discounted-CFR solver.
pub const Solver = struct {
    init_state: *SolverInit,
    config: SolverConfig,
    allocator: Allocator,
    scratch: Scratch,

    N: [2]u32,
    t: u32,

    u: u8,
    opp: u8,
    pos_discount: f32,
    neg_discount: f32,
    strat_scale: f32,
    probe: bool,

    pool: ?threading.Pool,
    worker_scratches: std.ArrayList(Scratch),
    /// `num_turns × N_max` reduction buffer for parallel flop→turn dispatch.
    /// Allocated once (empty when running serially); see `WalkCtx.turn_results`.
    turn_results: []f32,

    pub fn init(allocator: Allocator, init_state: *SolverInit, config: SolverConfig) !Solver {
        try config.validate();
        const n0 = init_state.ranges[0].N();
        const n1 = init_state.ranges[1].N();
        const n_max = @max(n0, n1);
        const scratch = try Scratch.forTree(allocator, &init_state.tree, n_max);
        errdefer {
            var s = scratch;
            s.deinit();
        }

        const pool: ?threading.Pool = if (config.num_threads > 0)
            try threading.Pool.init(allocator, config.num_threads -| 1)
        else
            null;
        errdefer if (pool) |p| {
            var pp = p;
            pp.deinit();
        };

        var worker_scratches = try std.ArrayList(Scratch).initCapacity(allocator, config.num_threads);
        errdefer {
            for (worker_scratches.items) |*ws| ws.deinit();
            worker_scratches.deinit(allocator);
        }

        if (config.num_threads > 0) {
            var i: u32 = 0;
            while (i < config.num_threads) : (i += 1) {
                const ws = try Scratch.forTree(allocator, &init_state.tree, n_max);
                worker_scratches.appendAssumeCapacity(ws);
            }
        }

        const turn_results = try allocator.alloc(f32, @as(usize, init_state.runout_tables.canonical_turns.len) * n_max);

        return .{
            .init_state = init_state,
            .config = config,
            .allocator = allocator,
            .scratch = scratch,
            .N = .{ n0, n1 },
            .t = 0,
            .u = 0,
            .opp = 1,
            .pos_discount = 0,
            .neg_discount = 0,
            .strat_scale = 0,
            .probe = false,
            .pool = pool,
            .worker_scratches = worker_scratches,
            .turn_results = turn_results,
        };
    }

    pub fn deinit(self: *Solver) void {
        if (self.pool) |*p| p.deinit();
        for (self.worker_scratches.items) |*ws| ws.deinit();
        self.worker_scratches.deinit(self.allocator);
        if (self.turn_results.len > 0) self.allocator.free(self.turn_results);
        self.scratch.deinit();
    }

    // ── Iterate loop ──────────────────────────────────────────────────────

    pub fn iterate(self: *Solver, iterations: u32) void {
        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            self.t += 1;
            self.runPass(0);
            self.runPass(1);
        }
    }

    fn runPass(self: *Solver, u: u8) void {
        self.setPassFactors(u);
        var ctx = self.makeCtx(&self.scratch);
        const root = self.init_state.tree.root;
        const ru, const ro = self.initRootReaches(u);
        _ = ctx.walk(root, .flop, 0, ru, ro, 0, .solve);
        if (self.config.debug_invariants) self.assertRegretsFinite();
    }

    /// Debug invariant sweep (§9): the regret arrays must never contain NaN/Inf.
    /// Cheap relative to a pass and gated by `config.debug_invariants`.
    fn assertRegretsFinite(self: *Solver) void {
        const s = &self.init_state.storage;
        for (s.regrets_flop) |r| std.debug.assert(std.math.isFinite(r));
        for (s.regrets_turn) |r| std.debug.assert(std.math.isFinite(r));
        for (s.regrets_river) |r| std.debug.assert(std.math.isFinite(r));
    }

    fn rootValue(self: *Solver, u: u8, comptime mode: WalkMode) f32 {
        self.setPassFactors(u);
        var ctx = self.makeCtx(&self.scratch);
        const root = self.init_state.tree.root;
        const ru, const ro = self.initRootReaches(u);
        const v = ctx.walk(root, .flop, 0, ru, ro, 0, mode);
        var ev: f32 = 0;
        for (ru, v) |r, val| ev += r * val;
        return ev;
    }

    pub fn rootEV(self: *Solver, u: u8) f32 {
        return self.rootValue(u, .evaluate);
    }

    pub fn averageEV(self: *Solver, u: u8) f32 {
        return self.rootValue(u, .average);
    }

    pub fn bestResponseEV(self: *Solver, u: u8) f32 {
        return self.rootValue(u, .best_response);
    }

    pub fn averageStrategy(self: *Solver, street: Street, runout_id: u32, node_ref: NodeRef, out: []f32) void {
        var ctx = self.makeCtx(&self.scratch);
        ctx.averageStrategy(street, runout_id, node_ref, out);
    }

    /// Normalized average strategy (A action probabilities → `out[0..A]`) for a
    /// single hand index `h` at an action node on the given canonical runout.
    pub fn averageStrategyHand(self: *Solver, street: Street, runout_id: u32, node_ref: NodeRef, h: u32, out: []f32) void {
        var ctx = self.makeCtx(&self.scratch);
        ctx.averageStrategyHand(street, runout_id, node_ref, h, out);
    }

    /// Run an average-profile pass as player `u` and capture the per-hand CFV
    /// vector at `(node_ref, runout_id)` into `out` (length `N[u]`). Returns
    /// true if the node was reached during the walk (false ⇒ unreachable, e.g.
    /// inconsistent runout for the node's street, or a zero-reach prune).
    pub fn captureNodeValues(self: *Solver, u: u8, node_ref: NodeRef, runout_id: u32, out: []f32) bool {
        self.setPassFactors(u);
        var ctx = self.makeCtx(&self.scratch);
        var found = false;
        ctx.capture = .{ .node_ref = node_ref, .runout_id = runout_id, .out = out, .found = &found };
        const root = self.init_state.tree.root;
        const ru, const ro = self.initRootReaches(u);
        _ = ctx.walk(root, .flop, 0, ru, ro, 0, .average);
        return found;
    }

    fn makeCtx(self: *Solver, scratch: *Scratch) WalkCtx {
        const pool_ptr: ?*threading.Pool = if (self.pool) |*p| p else null;
        return .{
            .is = self.init_state,
            .scratch = scratch,
            .allocator = self.allocator,
            .N = self.N,
            .u = self.u,
            .opp = self.opp,
            .pos_discount = self.pos_discount,
            .neg_discount = self.neg_discount,
            .strat_scale = self.strat_scale,
            .t = self.t,
            .probe = self.probe,
            .use_simd = self.config.use_simd,
            .prune_zero_reach = self.config.prune_zero_reach,
            .algorithm = self.config.algorithm,
            .pool = pool_ptr,
            .worker_scratches = self.worker_scratches.items,
            .turn_results = self.turn_results,
        };
    }

    fn setPassFactors(self: *Solver, u: u8) void {
        self.u = u;
        self.opp = 1 - u;
        const tf: f32 = @floatFromInt(self.t);
        const ta = std.math.pow(f32, tf, self.config.dcfr.alpha);
        self.pos_discount = ta / (ta + 1.0);
        const tb = std.math.pow(f32, tf, self.config.dcfr.beta);
        self.neg_discount = tb / (tb + 1.0);
        self.strat_scale = std.math.pow(f32, tf / (tf + 1.0), self.config.dcfr.gamma);
    }

    fn initRootReaches(self: *Solver, u: u8) struct { []f32, []f32 } {
        const opp = 1 - u;
        const n_u = self.N[u];
        const n_opp = self.N[opp];
        const ru = self.scratch.reachU(0, n_u);
        const ro = self.scratch.reachOpp(0, n_opp);
        const wu = self.init_state.ranges[u].weights;
        const wo = self.init_state.ranges[opp].weights;
        const mfu = self.init_state.mask_flop[u];
        const mfo = self.init_state.mask_flop[opp];
        for (ru, wu, mfu) |*dst, w, m| dst.* = w * m;
        for (ro, wo, mfo) |*dst, w, m| dst.* = w * m;
        return .{ ru, ro };
    }
};

fn sum(xs: []const f32) f32 {
    var s: f32 = 0;
    for (xs) |x| s += x;
    return s;
}

const ShowdownCoeffs = struct { win: f32, loss: f32, tie: f32 };

pub fn foldUtility(initial_pot: u32, term: TerminalNode, u: u8) f32 {
    const ip: f32 = @floatFromInt(initial_pot);
    const fc: f32 = @floatFromInt(term.folder_committed);
    return if (term.who_folded == u) -fc else ip + fc;
}

fn showdownCoeffsFor(initial_pot: u32, pot: u32) ShowdownCoeffs {
    const ip: f32 = @floatFromInt(initial_pot);
    const p: f32 = @floatFromInt(pot);
    const c = (p - ip) / 2.0;
    return .{ .win = ip + c, .loss = c, .tie = ip / 2.0 };
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;
const card = @import("card.zig");
const Combo = card.Combo;
const WeightedCombo = @import("range.zig").WeightedCombo;

const mono_flop = [_]card.Card{ card.makeCard(12, 0), card.makeCard(11, 0), card.makeCard(10, 0) };
const one_sizing = [_]game_tree.Sizing{game_tree.Sizing.init(50, 100)};
const test_sizings: [3][]const game_tree.Sizing = .{ &one_sizing, &one_sizing, &one_sizing };

fn buildInit(allocator: Allocator, flop: [3]card.Card, oop: []const WeightedCombo, ip: []const WeightedCombo) !SolverInit {
    const config = init_mod.Config{
        .flop = flop,
        .initial_pot = 10,
        .effective_stack = 16,
        .min_bet = 2,
        .sizings = test_sizings,
        .raise_cap = .{ 0, 0, 0 },
        .oop_range = oop,
        .ip_range = ip,
        .max_budget_bytes = std.math.maxInt(u64),
    };
    return init_mod.SolverInit.init(allocator, config);
}

fn wc(a: card.Card, b: card.Card) !WeightedCombo {
    return .{ .combo = try Combo.init(a, b), .weight = 1.0 };
}

fn spade(rank: u32) card.Card {
    return card.makeCard(rank, 0);
}

fn checkConstantSum(solver: *Solver, tol: f32) !void {
    solver.probe = false;
    const ev0 = solver.rootEV(0);
    const ev1 = solver.rootEV(1);
    solver.probe = true;
    const p0 = solver.rootEV(0);
    const p1 = solver.rootEV(1);
    solver.probe = false;

    try testing.expect(@abs(p0 - p1) < tol);
    try testing.expect(@abs((ev0 + ev1) - p0) < tol);
}

test "fold utility conventions (signs and magnitudes)" {
    const initial_pot: u32 = 10;
    const term = TerminalNode{ .kind = .fold, .who_folded = 0, .pot = 22, .folder_committed = 6 };
    try testing.expectEqual(@as(f32, -6.0), foldUtility(initial_pot, term, 0));
    try testing.expectEqual(@as(f32, 16.0), foldUtility(initial_pot, term, 1));
    try testing.expectEqual(@as(f32, 10.0), foldUtility(initial_pot, term, 0) + foldUtility(initial_pot, term, 1));
}

test "showdown coefficients (win/loss/tie and constant-sum)" {
    const c = showdownCoeffsFor(10, 30);
    try testing.expectEqual(@as(f32, 20.0), c.win);
    try testing.expectEqual(@as(f32, 10.0), c.loss);
    try testing.expectEqual(@as(f32, 5.0), c.tie);
    try testing.expectEqual(@as(f32, 10.0), c.win - c.loss);
    try testing.expectEqual(@as(f32, 10.0), c.tie + c.tie);
}

test "constant-sum invariant holds at the initial (uniform) profile" {
    const alloc = testing.allocator;
    const oop = [_]WeightedCombo{ try wc(spade(9), spade(8)), try wc(spade(4), spade(3)) };
    const ip = [_]WeightedCombo{ try wc(spade(9), spade(8)), try wc(spade(6), spade(5)) };

    var is = try buildInit(alloc, mono_flop, &oop, &ip);
    defer is.deinit();

    var solver = try Solver.init(alloc, &is, .{});
    defer solver.deinit();

    try checkConstantSum(&solver, 1e-2);
}

test "constant-sum invariant still holds after DCFR iterations" {
    const alloc = testing.allocator;
    const oop = [_]WeightedCombo{ try wc(spade(9), spade(8)), try wc(spade(4), spade(3)) };
    const ip = [_]WeightedCombo{ try wc(spade(7), spade(6)), try wc(spade(2), spade(1)) };

    var is = try buildInit(alloc, mono_flop, &oop, &ip);
    defer is.deinit();

    var solver = try Solver.init(alloc, &is, .{});
    defer solver.deinit();

    solver.iterate(3);
    try checkConstantSum(&solver, 1e-2);
}

test "regrets stay finite and strategies are valid distributions" {
    const alloc = testing.allocator;
    const oop = [_]WeightedCombo{ try wc(spade(9), spade(8)), try wc(spade(4), spade(3)) };
    const ip = [_]WeightedCombo{ try wc(spade(7), spade(6)), try wc(spade(2), spade(1)) };

    var is = try buildInit(alloc, mono_flop, &oop, &ip);
    defer is.deinit();

    var solver = try Solver.init(alloc, &is, .{});
    defer solver.deinit();

    solver.iterate(4);

    var any_nonzero = false;
    for (is.storage.regrets_flop) |r| {
        try testing.expect(std.math.isFinite(r));
        if (r != 0) any_nonzero = true;
    }
    for (is.storage.regrets_turn) |r| try testing.expect(std.math.isFinite(r));
    for (is.storage.regrets_river) |r| try testing.expect(std.math.isFinite(r));
    try testing.expect(any_nonzero);

    const root = is.tree.root;
    const node = is.tree.action_nodes.items[game_tree.refIndex(root)];
    const a = node.num_children;
    const n = solver.N[node.player];
    const out = try alloc.alloc(f32, @as(usize, a) * n);
    defer alloc.free(out);
    solver.averageStrategy(.flop, 0, root, out);

    var h: u32 = 0;
    while (h < n) : (h += 1) {
        var s: f32 = 0;
        var ai: u32 = 0;
        while (ai < a) : (ai += 1) {
            const p = out[ai * n + h];
            try testing.expect(p >= -1e-6 and p <= 1.0 + 1e-6);
            s += p;
        }
        try testing.expect(@abs(s - 1.0) < 1e-4);
    }
}

test "zero-reach pruning produces the same root EV as the full walk" {
    const alloc = testing.allocator;
    const oop = [_]WeightedCombo{ try wc(spade(9), spade(8)), try wc(spade(4), spade(3)) };
    const ip = [_]WeightedCombo{ try wc(spade(7), spade(6)), try wc(spade(2), spade(1)) };

    var is = try buildInit(alloc, mono_flop, &oop, &ip);
    defer is.deinit();

    var full = try Solver.init(alloc, &is, .{ .prune_zero_reach = false });
    defer full.deinit();
    const ev_full = full.rootEV(0);

    var pruned = try Solver.init(alloc, &is, .{ .prune_zero_reach = true });
    defer pruned.deinit();
    const ev_pruned = pruned.rootEV(0);

    try testing.expect(@abs(ev_full - ev_pruned) < 1e-3);
}

test "parallel solve matches serial solve" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const alloc = testing.allocator;
    const oop = [_]WeightedCombo{ try wc(spade(9), spade(8)), try wc(spade(4), spade(3)) };
    const ip = [_]WeightedCombo{ try wc(spade(7), spade(6)), try wc(spade(2), spade(1)) };

    // Two serial solves should be byte-identical (base check)
    var is_a = try buildInit(alloc, mono_flop, &oop, &ip);
    defer is_a.deinit();
    var a = try Solver.init(alloc, &is_a, .{});
    defer a.deinit();
    a.iterate(3);

    var is_b = try buildInit(alloc, mono_flop, &oop, &ip);
    defer is_b.deinit();
    var b = try Solver.init(alloc, &is_b, .{});
    defer b.deinit();
    b.iterate(3);

    try testing.expectEqualSlices(f32, is_a.storage.regrets_flop, is_b.storage.regrets_flop);

    // 1-thread "parallel" (pool with 0 workers) should match serial
    var is_1t = try buildInit(alloc, mono_flop, &oop, &ip);
    defer is_1t.deinit();
    var p1 = try Solver.init(alloc, &is_1t, .{ .num_threads = 1 });
    defer p1.deinit();
    p1.iterate(3);

    try testing.expectEqualSlices(f32, is_a.storage.regrets_flop, is_1t.storage.regrets_flop);

    // 2-thread parallel solve
    var is_2t = try buildInit(alloc, mono_flop, &oop, &ip);
    defer is_2t.deinit();
    var p2 = try Solver.init(alloc, &is_2t, .{ .num_threads = 2 });
    defer p2.deinit();
    p2.iterate(3);

    try testing.expectEqualSlices(f32, is_a.storage.regrets_flop, is_2t.storage.regrets_flop);
}

fn expectIdenticalStorage(ref: *const SolverInit, got: *const SolverInit) !void {
    try testing.expectEqualSlices(f32, ref.storage.regrets_flop, got.storage.regrets_flop);
    try testing.expectEqualSlices(f32, ref.storage.regrets_turn, got.storage.regrets_turn);
    try testing.expectEqualSlices(f32, ref.storage.regrets_river, got.storage.regrets_river);
    try testing.expectEqualSlices(f32, ref.storage.strategies_flop, got.storage.strategies_flop);
    try testing.expectEqualSlices(f32, ref.storage.strategies_turn, got.storage.strategies_turn);
    try testing.expectEqualSlices(f32, ref.storage.strategies_river, got.storage.strategies_river);
}

test "parallel solve is byte-identical to serial across worker counts" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const alloc = testing.allocator;

    // A larger range (multiple suits/ranks) so each pass fans many canonical
    // turns out across the worker pool and the dynamic work-claim ordering is
    // genuinely exercised — yet the canonical-order reduction must still yield
    // bit-identical regret and strategy arrays for every thread count.
    const oop = [_]WeightedCombo{
        try wc(spade(9), spade(8)), try wc(spade(4), spade(3)),
        try wc(spade(11), spade(7)), try wc(spade(6), spade(2)),
        try wc(spade(10), spade(5)),
    };
    const ip = [_]WeightedCombo{
        try wc(spade(7), spade(6)),  try wc(spade(2), spade(1)),
        try wc(spade(12), spade(8)), try wc(spade(5), spade(0)),
        try wc(spade(11), spade(3)),
    };

    var is_ref = try buildInit(alloc, mono_flop, &oop, &ip);
    defer is_ref.deinit();
    var ref = try Solver.init(alloc, &is_ref, .{});
    defer ref.deinit();
    ref.iterate(4);

    for ([_]u32{ 1, 2, 4, 8 }) |nt| {
        var is_p = try buildInit(alloc, mono_flop, &oop, &ip);
        defer is_p.deinit();
        var p = try Solver.init(alloc, &is_p, .{ .num_threads = nt });
        defer p.deinit();
        p.iterate(4);
        try expectIdenticalStorage(&is_ref, &is_p);
    }
}
