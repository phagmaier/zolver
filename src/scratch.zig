const std = @import("std");
const game_tree = @import("game_tree.zig");
const terminal_eval = @import("terminal_eval.zig");

const Allocator = std.mem.Allocator;
const Tree = game_tree.Tree;
const NodeRef = game_tree.NodeRef;

/// Length of the per-thread 52-card scratch buffers used by the terminal kernels.
pub const card_scratch_len: usize = 52;

// ── Tree-derived bounds ───────────────────────────────────────────────────

/// Longest root-to-terminal path, measured in recursion levels (node count).
/// The walk indexes scratch by `depth` in the range `0..maxDepth-1`, so this is
/// exactly the number of depth levels the arena must provide.
pub fn maxDepth(tree: *const Tree) !u32 {
    return nodeDepth(tree, tree.root);
}

fn nodeDepth(tree: *const Tree, ref: NodeRef) error{ InvalidNodeTag, DepthOverflow }!u32 {
    switch (try game_tree.refTag(ref)) {
        .terminal => return 1,
        .chance => {
            const c = tree.chance_nodes.items[game_tree.refIndex(ref)];
            return try addDepth(1, try nodeDepth(tree, c.child));
        },
        .action => {
            const node = tree.action_nodes.items[game_tree.refIndex(ref)];
            var best: u32 = 0;
            var i: u32 = 0;
            while (i < node.num_children) : (i += 1) {
                const child = tree.edges.items[node.first_child_edge + i];
                const d = try nodeDepth(tree, child);
                if (d > best) best = d;
            }
            return try addDepth(1, best);
        },
    }
}

fn addDepth(a: u32, b: u32) error{DepthOverflow}!u32 {
    return std.math.add(u32, a, b) catch error.DepthOverflow;
}

/// Maximum number of children at any action node (A_max). Zero if the tree has
/// no action nodes.
pub fn maxChildren(tree: *const Tree) u32 {
    var m: u32 = 0;
    for (tree.action_nodes.items) |node| {
        if (node.num_children > m) m = node.num_children;
    }
    return m;
}

// ── Per-thread scratch arena ──────────────────────────────────────────────

/// Depth-indexed, pre-allocated scratch for one solver thread. All buffers live
/// in a single f32 slab; accessors hand out fixed sub-slices, so the hot path
/// performs zero allocations. One arena is owned per worker thread.
///
/// Per depth level the arena holds: `reach_u`, `reach_opp`, and `values`
/// (n_max floats each), plus an `a_max × n_max` strategy buffer and an
/// `a_max × n_max` child-value buffer. Per thread (shared across depths, since
/// only one terminal is evaluated at a time on a given path) it holds the
/// all-in kernel's `reach_opp` / `child_values` staging buffers and the three
/// 52-float card buffers used by every terminal kernel.
///
/// Total: `max_depth × (3 + 2·a_max) × n_max + 5·n_max + 3·52` floats.
pub const Scratch = struct {
    allocator: Allocator,
    max_depth: u32,
    n_max: u32,
    a_max: u32,

    /// Backing storage; every other slice below is a view into this.
    slab: []f32,

    reach_u_blk: []f32,
    reach_opp_blk: []f32,
    values_blk: []f32,
    strategy_blk: []f32,
    child_blk: []f32,

    term_reach_opp: []f32,
    term_child_values: []f32,
    cardsum: []f32,
    lo_card: []f32,
    eq_card: []f32,
    /// Precomputed per-hand same_reach scratch for showdownEval (Section 4.2).
    /// same_reach[h] = reach_opp[same_combo_idx[h]] or 0.0. Sized to n_max.
    same_reach: []f32,
    /// Precomputed per-hand compat scratch for showdownEval (Section 4.2),
    /// populated once before the sorted sweep. Sized to n_max per thread.
    compat: []f32,
    /// Per-canonical-turn partial-sum buffer for the compressed flop all-in
    /// reduction (`allInEvalFlopRemapped`), so it accumulates in the same
    /// two-level order as the physical path. Sized to n_max.
    term_partial: []f32,

    /// Build an arena sized directly to `tree`'s depth and branching factor.
    /// `n_max` must be the larger of the two players' range sizes.
    pub fn forTree(allocator: Allocator, tree: *const Tree, n_max: u32) !Scratch {
        return init(allocator, try maxDepth(tree), n_max, maxChildren(tree));
    }

    /// Exact slab allocation required by `forTree`, without allocating it.
    pub fn memoryBytesForTree(tree: *const Tree, n_max: u32) !u64 {
        const floats = try slabLen(try maxDepth(tree), n_max, maxChildren(tree));
        return std.math.mul(u64, @intCast(floats), @sizeOf(f32));
    }

    pub fn init(allocator: Allocator, max_depth: u32, n_max: u32, a_max: u32) !Scratch {
        const d: usize = max_depth;
        const n: usize = n_max;
        const a: usize = a_max;
        const small = try std.math.mul(usize, d, n); // each of reach_u, reach_opp, values
        const wide = try std.math.mul(usize, small, a); // each of strategy, child_values
        const total = try slabLen(max_depth, n_max, a_max);

        const slab = try allocator.alloc(f32, total);

        var off: usize = 0;
        const reach_u_blk = slab[off..][0..small];
        off += small;
        const reach_opp_blk = slab[off..][0..small];
        off += small;
        const values_blk = slab[off..][0..small];
        off += small;
        const strategy_blk = slab[off..][0..wide];
        off += wide;
        const child_blk = slab[off..][0..wide];
        off += wide;
        const term_reach_opp = slab[off..][0..n];
        off += n;
        const term_child_values = slab[off..][0..n];
        off += n;
        const cardsum = slab[off..][0..card_scratch_len];
        off += card_scratch_len;
        const lo_card = slab[off..][0..card_scratch_len];
        off += card_scratch_len;
        const eq_card = slab[off..][0..card_scratch_len];
        off += card_scratch_len;
        const same_reach = slab[off..][0..n];
        off += n;
        const compat = slab[off..][0..n];
        off += n;
        const term_partial = slab[off..][0..n];
        off += n;
        std.debug.assert(off == total);

        return .{
            .allocator = allocator,
            .max_depth = max_depth,
            .n_max = n_max,
            .a_max = a_max,
            .slab = slab,
            .reach_u_blk = reach_u_blk,
            .reach_opp_blk = reach_opp_blk,
            .values_blk = values_blk,
            .strategy_blk = strategy_blk,
            .child_blk = child_blk,
            .term_reach_opp = term_reach_opp,
            .term_child_values = term_child_values,
            .cardsum = cardsum,
            .lo_card = lo_card,
            .eq_card = eq_card,
            .same_reach = same_reach,
            .compat = compat,
            .term_partial = term_partial,
        };
    }

    pub fn deinit(self: *Scratch) void {
        self.allocator.free(self.slab);
        self.* = undefined;
    }

    /// Bytes of backing storage (for budgeting / reporting).
    pub fn memoryBytes(self: *const Scratch) usize {
        return self.slab.len * @sizeOf(f32);
    }

    // ── Per-depth accessors (each returns the first `n` floats of the level) ──

    /// Updating player's reach vector buffer at `depth`.
    pub fn reachU(self: *const Scratch, depth: u32, n: u32) []f32 {
        const base = @as(usize, depth) * self.n_max;
        return self.reach_u_blk[base..][0..n];
    }

    /// Opponent reach vector buffer at `depth`.
    pub fn reachOpp(self: *const Scratch, depth: u32, n: u32) []f32 {
        const base = @as(usize, depth) * self.n_max;
        return self.reach_opp_blk[base..][0..n];
    }

    /// Node value (returned CFV) buffer at `depth`.
    pub fn nodeValues(self: *const Scratch, depth: u32, n: u32) []f32 {
        const base = @as(usize, depth) * self.n_max;
        return self.values_blk[base..][0..n];
    }

    /// Strategy buffer at `depth`: action-major `[a * n]`, i.e. `sigma[a][h]`
    /// at index `a * n + h`. Matches the kernels' action-major layout.
    pub fn strategy(self: *const Scratch, depth: u32, n: u32, a: u32) []f32 {
        const stride = @as(usize, self.a_max) * self.n_max;
        const base = @as(usize, depth) * stride;
        return self.strategy_blk[base..][0 .. @as(usize, a) * n];
    }

    /// Child-value buffer at `depth`: action-major `[a * n]`, `child_v[a][h]`
    /// at index `a * n + h`.
    pub fn childValues(self: *const Scratch, depth: u32, n: u32, a: u32) []f32 {
        const stride = @as(usize, self.a_max) * self.n_max;
        const base = @as(usize, depth) * stride;
        return self.child_blk[base..][0 .. @as(usize, a) * n];
    }

    /// Single action's child-value slice (`child_v[action_idx]`) at `depth`.
    pub fn childValue(self: *const Scratch, depth: u32, n: u32, action_idx: u32) []f32 {
        const stride = @as(usize, self.a_max) * self.n_max;
        const base = @as(usize, depth) * stride + @as(usize, action_idx) * n;
        return self.child_blk[base..][0..n];
    }

    /// Staging buffers for the all-in terminal kernel (shared per thread).
    pub fn allInScratch(self: *const Scratch, n_u: u32, n_opp: u32) terminal_eval.AllInScratch {
        return .{
            .reach_opp = self.term_reach_opp[0..n_opp],
            .child_values = self.term_child_values[0..n_u],
            .same_reach = self.same_reach[0..n_u],
            .compat = self.compat[0..n_u],
            .lo_card = self.lo_card,
            .eq_card = self.eq_card,
            .cardsum = self.cardsum,
            .term_partial = self.term_partial[0..n_u],
        };
    }
};

fn slabLen(max_depth: u32, n_max: u32, a_max: u32) !usize {
    const d: usize = max_depth;
    const n: usize = n_max;
    const a: usize = a_max;
    const small = try std.math.mul(usize, d, n);
    const wide = try std.math.mul(usize, small, a);
    var total = try std.math.mul(usize, small, 3);
    total = try std.math.add(usize, total, try std.math.mul(usize, wide, 2));
    total = try std.math.add(usize, total, try std.math.mul(usize, n, 5));
    return std.math.add(usize, total, card_scratch_len * 3);
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "maxChildren and maxDepth on a built tree" {
    const config = game_tree.BuildConfig.default(100, 1000, 1, .{ 4, 4 });
    var tree = try game_tree.buildGameTree(testing.allocator, config);
    defer tree.deinit();

    const a_max = maxChildren(&tree);
    const d = try maxDepth(&tree);

    // Root is an action node and the tree has at least one terminal, so the
    // shallowest possible deepest-path is action→terminal = 2 levels.
    try testing.expect(d >= 2);
    // Every action node offers at least fold + one more action.
    try testing.expect(a_max >= 2);
    // maxChildren must equal the true maximum over all action nodes.
    var brute: u32 = 0;
    for (tree.action_nodes.items) |node| {
        if (node.num_children > brute) brute = node.num_children;
    }
    try testing.expectEqual(brute, a_max);
}

test "nodeDepth: hand-built shapes" {
    // Build a trivial tree by hand: root action with two terminal children.
    var tree = Tree.init(testing.allocator, 2);
    defer tree.deinit();

    const t0 = try game_tree.makeRef(.terminal, 0);
    const t1 = try game_tree.makeRef(.terminal, 1);
    try tree.terminal_nodes.append(testing.allocator, .{ .kind = .showdown, .who_folded = 0, .pot = 2, .folder_committed = 0 });
    try tree.terminal_nodes.append(testing.allocator, .{ .kind = .fold, .who_folded = 0, .pot = 2, .folder_committed = 1 });

    const first_edge: u32 = @intCast(tree.edges.items.len);
    try tree.edges.append(testing.allocator, t0);
    try tree.edges.append(testing.allocator, t1);
    try tree.action_nodes.append(testing.allocator, .{ .player = 0, .first_child_edge = first_edge, .num_children = 2, .base = 0 });
    tree.root = try game_tree.makeRef(.action, 0);

    // action(root) → terminal = 2 levels.
    try testing.expectEqual(@as(u32, 2), try maxDepth(&tree));
    try testing.expectEqual(@as(u32, 2), maxChildren(&tree));

    // Insert a chance node above to make action → chance → action → terminal.
    try tree.chance_nodes.append(testing.allocator, .{ .next_street = 1, .child = tree.root });
    const chance_ref = try game_tree.makeRef(.chance, 0);
    const e2: u32 = @intCast(tree.edges.items.len);
    try tree.edges.append(testing.allocator, chance_ref);
    try tree.edges.append(testing.allocator, t0);
    try tree.action_nodes.append(testing.allocator, .{ .player = 1, .first_child_edge = e2, .num_children = 2, .base = 0 });
    tree.root = try game_tree.makeRef(.action, 1);

    // action → chance → action → terminal = 4 levels.
    try testing.expectEqual(@as(u32, 4), try maxDepth(&tree));
}

test "Scratch: layout sizes and total memory" {
    const max_depth: u32 = 5;
    const n_max: u32 = 10;
    const a_max: u32 = 3;
    var s = try Scratch.init(testing.allocator, max_depth, n_max, a_max);
    defer s.deinit();

    const expected_floats: usize =
        @as(usize, max_depth) * (3 + 2 * a_max) * n_max + 2 * n_max + 3 * card_scratch_len + n_max * 3;
    try testing.expectEqual(expected_floats, s.slab.len);
    try testing.expectEqual(expected_floats * @sizeOf(f32), s.memoryBytes());
}

test "Scratch: per-depth buffers are independent (no aliasing)" {
    var s = try Scratch.init(testing.allocator, 4, 8, 3);
    defer s.deinit();

    // Distinct writes at different depths must not clobber each other.
    const r0 = s.reachU(0, 8);
    const r1 = s.reachU(1, 8);
    @memset(r0, 1.0);
    @memset(r1, 2.0);
    for (r0) |v| try testing.expectEqual(@as(f32, 1.0), v);
    for (r1) |v| try testing.expectEqual(@as(f32, 2.0), v);

    // reach_u, reach_opp, values at the same depth are distinct buffers.
    const ru = s.reachU(2, 8);
    const ro = s.reachOpp(2, 8);
    const nv = s.nodeValues(2, 8);
    @memset(ru, 3.0);
    @memset(ro, 4.0);
    @memset(nv, 5.0);
    for (ru) |v| try testing.expectEqual(@as(f32, 3.0), v);
    for (ro) |v| try testing.expectEqual(@as(f32, 4.0), v);
    for (nv) |v| try testing.expectEqual(@as(f32, 5.0), v);
}

test "Scratch: strategy and child-value slices have action-major layout" {
    var s = try Scratch.init(testing.allocator, 3, 6, 4);
    defer s.deinit();

    const n: u32 = 5; // use fewer than n_max
    const a: u32 = 3; // use fewer than a_max

    const strat = s.strategy(1, n, a);
    try testing.expectEqual(@as(usize, a * n), strat.len);

    // Writing per-action via childValue must be visible through the flat view.
    var act: u32 = 0;
    while (act < a) : (act += 1) {
        const slot = s.childValue(1, n, act);
        try testing.expectEqual(@as(usize, n), slot.len);
        @memset(slot, @floatFromInt(act + 1));
    }
    const flat = s.childValues(1, n, a);
    try testing.expectEqual(@as(usize, a * n), flat.len);
    act = 0;
    while (act < a) : (act += 1) {
        for (0..n) |h| {
            try testing.expectEqual(@as(f32, @floatFromInt(act + 1)), flat[act * n + h]);
        }
    }
}

test "Scratch: allInScratch wires terminal buffers at requested sizes" {
    var s = try Scratch.init(testing.allocator, 2, 12, 2);
    defer s.deinit();

    const ais = s.allInScratch(7, 9);
    try testing.expectEqual(@as(usize, 7), ais.child_values.len);
    try testing.expectEqual(@as(usize, 9), ais.reach_opp.len);
    try testing.expectEqual(card_scratch_len, ais.cardsum.len);
    try testing.expectEqual(card_scratch_len, ais.lo_card.len);
    try testing.expectEqual(card_scratch_len, ais.eq_card.len);
}

test "Scratch: forTree sizes from a real tree" {
    const config = game_tree.BuildConfig.default(100, 1000, 1, .{ 6, 4 });
    var tree = try game_tree.buildGameTree(testing.allocator, config);
    defer tree.deinit();

    var s = try Scratch.forTree(testing.allocator, &tree, 6);
    defer s.deinit();

    try testing.expectEqual(try maxDepth(&tree), s.max_depth);
    try testing.expectEqual(maxChildren(&tree), s.a_max);
    try testing.expectEqual(@as(u32, 6), s.n_max);
    try testing.expect(s.memoryBytes() > 0);
}
