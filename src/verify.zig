//! Independent correctness oracle: physical cards, f64 reaches/values, pairwise
//! terminal evaluation. Intentionally slower than training; no all-in cache,
//! suit-orbit value reuse, or production terminal/CFR walk is used.
const std = @import("std");
const cfr = @import("cfr.zig");
const card = @import("card.zig");
const tree = @import("game_tree.zig");
const extract = @import("extract.zig");
const evaluator = @import("evaluator.zig");
const scratch = @import("scratch.zig");

pub const Result = struct {
    chips: f64,
    pct: f64,
    /// Conditional chip EVs, already divided by compatible range mass.
    br: [2]f64,
    ev: [2]f64,
    compatible_mass: f64,
    constant_sum_error: f64,
};

const Board = struct {
    flop: [3]card.Card,
    turn: ?card.Card,
    river: ?card.Card,
    fn mask(self: Board) u64 {
        return card.boardMask(&self.flop) | (if (self.turn) |c| card.mask(c) else 0) | (if (self.river) |c| card.mask(c) else 0);
    }
    fn street(self: Board) tree.Street {
        return if (self.river != null) .river else if (self.turn != null) .turn else .flop;
    }
};

const Walk = struct {
    solver: *cfr.Solver,
    u: usize,
    best: bool,
    n: usize,
    reaches: []f64,
    values: []f64,
    strategies: []f64,

    fn visit(self: *Walk, ref: tree.NodeRef, board: Board, reach: []const f64, depth: usize) ![]f64 {
        const is = self.solver.init_state;
        const nu = self.solver.N[self.u];
        const no = self.solver.N[1 - self.u];
        const out = self.values[depth * self.n ..][0..nu];
        @memset(out, 0);
        switch (try tree.refTag(ref)) {
            .terminal => {
                const term = is.tree.terminal_nodes.items[tree.refIndex(ref)];
                if (term.kind == .showdown and board.river == null) {
                    // Terminal runouts do not consume betting-tree depth. Use
                    // a separate pairwise evaluator, avoiding arena aliasing.
                    self.terminalRunouts(out, term, board, reach, 1);
                } else self.terminal(out, term, board, reach, 1);
            },
            .chance => {
                const child = is.tree.chance_nodes.items[tree.refIndex(ref)].child;
                const weight: f64 = if (board.turn == null) 1.0 / 45.0 else 1.0 / 44.0;
                const next_reach = self.reaches[(depth + 1) * self.n ..][0..no];
                for (0..52) |ci| {
                    const c = try card.fromIndex(@intCast(ci));
                    if (board.mask() & card.mask(c) != 0) continue;
                    var next = board;
                    if (board.turn == null) next.turn = c else next.river = c;
                    for (next_reach, reach, is.ranges[1 - self.u].hands) |*r, old, h| r.* = if (h.cardMask() & card.mask(c) == 0) old * weight else 0;
                    const v = try self.visit(child, next, next_reach, depth + 1);
                    for (out, v, is.ranges[self.u].hands) |*dst, value, h| if (h.cardMask() & card.mask(c) == 0) {
                        dst.* += value;
                    };
                }
            },
            .action => {
                const node = is.tree.action_nodes.items[tree.refIndex(ref)];
                const na = self.solver.N[node.player];
                const a = node.num_children;
                const sigma = self.strategies[depth * 8 * self.n ..][0 .. a * na];
                const resolution = try extract.resolveRunout(is, board.turn, board.river);
                const sums = switch (board.street()) {
                    .flop => is.storage.strategies_flop,
                    .turn => is.storage.strategies_turn,
                    .river => is.storage.strategies_river,
                };
                const base = resolution.runoutId() * is.tree.slots_per_runout[board.street().index()] + node.base;
                for (is.ranges[node.player].hands, 0..) |hand, h| {
                    const mapped = extract.canonicalHandIndex(is, node.player, hand, resolution).?;
                    var total: f64 = 0;
                    for (0..a) |ai| {
                        const value = sums[base + ai * na + mapped];
                        if (!std.math.isFinite(value) or value < 0) return error.InvalidPolicy;
                        total += value;
                    }
                    for (0..a) |ai| sigma[ai * na + h] = if (total > 0) @as(f64, sums[base + ai * na + mapped]) / total else 1.0 / @as(f64, @floatFromInt(a));
                }
                for (0..a) |ai| {
                    const edge = is.tree.edges.items[node.first_child_edge + ai];
                    if (node.player == self.u) {
                        const v = try self.visit(edge, board, reach, depth + 1);
                        for (out, v, 0..) |*dst, value, h| {
                            if (self.best) dst.* = if (ai == 0) value else @max(dst.*, value) else dst.* += sigma[ai * na + h] * value;
                        }
                    } else {
                        const next_reach = self.reaches[(depth + 1) * self.n ..][0..no];
                        for (next_reach, reach, 0..) |*r, old, h| r.* = old * sigma[ai * na + h];
                        const v = try self.visit(edge, board, next_reach, depth + 1);
                        for (out, v) |*dst, value| dst.* += value;
                    }
                }
            },
        }
        return out;
    }

    fn terminalRunouts(self: *Walk, out: []f64, term: tree.TerminalNode, board: Board, reach: []const f64, weight: f64) void {
        if (board.river != null) return self.terminal(out, term, board, reach, weight);
        for (0..52) |ci| {
            const c = card.fromIndex(@intCast(ci)) catch unreachable;
            if (board.mask() & card.mask(c) != 0) continue;
            var next = board;
            if (board.turn == null) next.turn = c else next.river = c;
            self.terminalRunouts(out, term, next, reach, weight / (if (board.turn == null) @as(f64, 45) else 44));
        }
    }

    fn terminal(self: *Walk, out: []f64, term: tree.TerminalNode, board: Board, reach: []const f64, weight: f64) void {
        const is = self.solver.init_state;
        const pot: f64 = @floatFromInt(is.tree.initial_pot);
        const committed = (@as(f64, @floatFromInt(term.pot)) - pot) / 2;
        const dead = board.mask();
        const eval = evaluator.Evaluator{};
        var ranks: [2][1326]u32 = undefined;
        if (term.kind == .showdown) for (0..2) |p| {
            for (is.ranges[p].hands, 0..) |h, j| {
                ranks[p][j] = if (h.cardMask() & dead != 0) 0 else eval.handStrength(.{ board.flop[0], board.flop[1], board.flop[2], board.turn.?, board.river.?, h.first, h.second });
            }
        };
        for (is.ranges[self.u].hands, out, 0..) |h, *value, i| {
            if (h.cardMask() & dead != 0) continue;
            for (is.ranges[1 - self.u].hands, reach, 0..) |opp, r, j| {
                if (r == 0 or opp.cardMask() & (dead | h.cardMask()) != 0) continue;
                const payoff = if (term.kind == .fold)
                    (if (term.who_folded == self.u) -@as(f64, @floatFromInt(term.folder_committed)) else pot + @as(f64, @floatFromInt(term.folder_committed)))
                else if (ranks[self.u][i] > ranks[1 - self.u][j]) pot + committed else if (ranks[self.u][i] < ranks[1 - self.u][j]) -committed else pot / 2;
                value.* += r * weight * payoff;
            }
        }
    }
};

pub fn exploitability(allocator: std.mem.Allocator, solver: *cfr.Solver) !Result {
    const is = solver.init_state;
    const n = @max(solver.N[0], solver.N[1]);
    const depth = try scratch.maxDepth(&is.tree);
    const temporary_bytes = @as(u64, depth) * n * 10 * @sizeOf(f64);
    const available = is.max_budget_bytes -| (try is.memoryBytes()) -| solver.workingMemoryBytes();
    if (temporary_bytes > available) return error.VerificationBudgetExceeded;
    const reaches = try allocator.alloc(f64, depth * n);
    defer allocator.free(reaches);
    const values = try allocator.alloc(f64, depth * n);
    defer allocator.free(values);
    const strategies = try allocator.alloc(f64, depth * n * 8);
    defer allocator.free(strategies);
    const board = Board{ .flop = is.flop, .turn = is.root_turn, .river = is.root_river };
    var mass: f64 = 0;
    for (is.ranges[0].hands, is.ranges[0].weights) |a, wa| for (is.ranges[1].hands, is.ranges[1].weights) |b, wb| {
        if ((a.cardMask() | b.cardMask()) & board.mask() == 0 and a.cardMask() & b.cardMask() == 0) mass += @as(f64, wa) * wb;
    };
    if (mass <= 0) return error.NoCompatibleHands;
    var result: Result = .{ .chips = 0, .pct = 0, .br = undefined, .ev = undefined, .compatible_mass = mass, .constant_sum_error = 0 };
    for (0..2) |u| {
        for ([_]bool{ false, true }) |best| {
            for (reaches[0..solver.N[1 - u]], is.ranges[1 - u].weights) |*r, w| r.* = w;
            var walk = Walk{ .solver = solver, .u = u, .best = best, .n = n, .reaches = reaches, .values = values, .strategies = strategies };
            const v = try walk.visit(is.tree.root, board, reaches[0..solver.N[1 - u]], 0);
            var ev: f64 = 0;
            for (v, is.ranges[u].weights) |value, w| ev += value * w;
            if (best) result.br[u] = ev / mass else result.ev[u] = ev / mass;
        }
    }
    result.chips = ((result.br[0] - result.ev[0]) + (result.br[1] - result.ev[1])) / 2;
    const pot: f64 = @floatFromInt(is.tree.initial_pot);
    result.pct = result.chips / pot * 100;
    result.constant_sum_error = @abs(result.ev[0] + result.ev[1] - pot);
    return result;
}

test "independent physical f64 verification covers every root street and algorithm" {
    const alloc = std.testing.allocator;
    const wc = @import("range.zig").WeightedCombo;
    const init_mod = @import("init.zig");
    const flop = [3]card.Card{ card.makeCard(12, 0), card.makeCard(6, 0), card.makeCard(4, 0) };
    var oop: [3]wc = undefined;
    var ip: [3]wc = undefined;
    for (1..4) |s| {
        oop[s - 1] = .{ .combo = try card.Combo.init(card.makeCard(12, @intCast(s)), card.makeCard(11, @intCast(s))), .weight = 1 };
        ip[s - 1] = .{ .combo = try card.Combo.init(card.makeCard(8, @intCast(s)), card.makeCard(7, @intCast(s))), .weight = 1 };
    }
    for ([_]tree.Street{ .flop, .turn, .river }) |street| {
        for ([_]cfr.Algorithm{ .dcfr, .cfr_plus, .dcfr_plus, .pdcfr_plus }) |algo| {
            var cfg = init_mod.Config.default(flop, &oop, &ip);
            cfg.initial_pot = 10;
            cfg.effective_stack = 8;
            cfg.sizings = .{ &.{}, &.{}, &.{} };
            if (street != .flop) cfg.turn = card.makeCard(0, 1);
            if (street == .river) cfg.river = card.makeCard(1, 2);
            var is = try init_mod.SolverInit.init(alloc, cfg);
            defer is.deinit();
            var solver = try cfr.Solver.init(alloc, &is, .{ .algorithm = algo });
            defer solver.deinit();
            const initial = @import("best_response.zig").exploitabilityGap(&solver).pct;
            solver.iterate(if (street == .flop) 8 else 32);
            const reference = try exploitability(alloc, &solver);
            const fast = @import("best_response.zig").exploitability(&solver);
            try std.testing.expectApproxEqAbs(reference.pct, @as(f64, fast.pct), 0.0001);
            try std.testing.expect(reference.constant_sum_error < 1e-9);
            try std.testing.expect(reference.pct < initial);
            try std.testing.expectEqual(street, is.root_street);
            if (street == .river) {
                try std.testing.expectEqual(@as(usize, 1), is.runout_tables.canonical_rivers.len);
                try std.testing.expectEqual(@as(u64, 0), is.tree.slots_per_runout[0]);
                try std.testing.expectEqual(@as(u64, 0), is.tree.slots_per_runout[1]);
            }
            // Evaluate the same stored profile without the cache too.
            const cache = solver.allin_cache;
            solver.allin_cache = null;
            const uncached = @import("best_response.zig").exploitability(&solver);
            solver.allin_cache = cache;
            try std.testing.expectApproxEqAbs(reference.pct, @as(f64, uncached.pct), 0.0002);
        }
    }
}

const ExportHand = struct { combo: []const u8, strategy: []const f64 };
const ExportNode = struct { id: u32, player: []const u8, line: []const []const u8, actions: []const []const u8, hands: []const ExportHand };
const ExportStreet = struct { street: []const u8, board: []const u8, nodes: []const ExportNode };
const Export = struct {
    meta: struct { root_street: []const u8, root_board: []const u8, initial_pot: u32, effective_stack: u32 },
    streets: []const ExportStreet,
};

fn parseBoard(text: []const u8) !Board {
    var cards: [5]card.Card = undefined;
    var count: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, text, " ,\t");
    var mask: u64 = 0;
    while (tokens.next()) |token| {
        if (count == 5) return error.InvalidExportBoard;
        const c = try @import("parse.zig").parseCard(token);
        if (mask & card.mask(c) != 0) return error.InvalidExportBoard;
        mask |= card.mask(c);
        cards[count] = c;
        count += 1;
    }
    if (count < 3) return error.InvalidExportBoard;
    return .{ .flop = cards[0..3].*, .turn = if (count > 3) cards[3] else null, .river = if (count > 4) cards[4] else null };
}

fn checkLabels(labels: []const []const u8, actions: []const tree.Action) !void {
    if (labels.len != actions.len) return error.ExportTreeMismatch;
    for (labels, actions) |label, action| {
        var buf: [64]u8 = undefined;
        const expected = switch (action.kind) {
            .check => "check",
            .fold => "fold",
            .call => "call",
            .all_in => "all-in",
            .bet => try std.fmt.bufPrint(&buf, "bet {d}", .{action.amount}),
            .raise => try std.fmt.bufPrint(&buf, "raise {d}", .{action.amount}),
        };
        if (!std.mem.eql(u8, label, expected)) return error.ExportTreeMismatch;
    }
}

const ImportStreet = struct {
    solver: *cfr.Solver,
    resolution: extract.RunoutResolution,
    board: Board,
    nodes: []?*const ExportNode,
    consumed: usize = 0,
    pub fn visitActionNode(self: *ImportStreet, visit: tree.ActionNodeVisit) !void {
        if (visit.street != self.resolution.street) return;
        const node = self.nodes[tree.refIndex(visit.ref)] orelse return error.IncompleteExport;
        self.consumed += 1;
        if (!std.mem.eql(u8, node.player, if (visit.player == .oop) "oop" else "ip")) return error.ExportTreeMismatch;
        try checkLabels(node.line, visit.path);
        try checkLabels(node.actions, visit.actions);
        const is = self.solver.init_state;
        const p: usize = @intFromEnum(visit.player);
        const n = self.solver.N[p];
        const action = is.tree.action_nodes.items[tree.refIndex(visit.ref)];
        const sums = switch (visit.street) {
            .flop => is.storage.strategies_flop,
            .turn => is.storage.strategies_turn,
            .river => is.storage.strategies_river,
        };
        const base = self.resolution.runoutId() * is.tree.slots_per_runout[visit.street.index()] + action.base;
        var seen = [_]bool{false} ** 1326;
        for (node.hands) |hand| {
            if (hand.combo.len != 4 or hand.strategy.len != visit.actions.len) return error.InvalidExportPolicy;
            const combo = try card.Combo.init(try @import("parse.zig").parseCard(hand.combo[0..2]), try @import("parse.zig").parseCard(hand.combo[2..4]));
            if (combo.cardMask() & self.board.mask() != 0) return error.InvalidExportPolicy;
            const h = extract.canonicalHandIndex(is, @intCast(p), combo, self.resolution) orelse return error.InvalidExportPolicy;
            if (seen[h]) return error.DuplicateExportEntry;
            seen[h] = true;
            var total: f64 = 0;
            for (hand.strategy) |prob| {
                if (!std.math.isFinite(prob) or prob < 0 or prob > 1) return error.InvalidExportPolicy;
                total += prob;
            }
            // Output rounds each action to six decimal places. Normalize only
            // that bounded rounding error, never repair malformed policies.
            if (@abs(total - 1) > 0.000005) return error.InvalidExportPolicy;
            for (hand.strategy, 0..) |prob, ai| sums[base + ai * n + h] = @floatCast(prob / total);
        }
        for (is.ranges[p].hands) |hand| {
            if (hand.cardMask() & self.board.mask() != 0) continue;
            const h = extract.canonicalHandIndex(is, @intCast(p), hand, self.resolution).?;
            if (!seen[h]) return error.IncompleteExport;
        }
    }
};

/// Verify a complete canonical JSON export against its original game config.
/// Uses a fresh solver, so malformed input cannot change a caller's trained state.
/// Range weights come from the supplied config, not the JSON export.
pub fn verifyExport(allocator: std.mem.Allocator, config: @import("init.zig").Config, json: []const u8) !Result {
    const parsed = try std.json.parseFromSlice(Export, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const data = parsed.value;
    const root = try parseBoard(data.meta.root_board);
    if (!std.meta.eql(root.flop, config.flop) or root.turn != config.turn or root.river != config.river or
        !std.mem.eql(u8, data.meta.root_street, @tagName(config.startStreet())) or
        data.meta.initial_pot != config.initial_pot or data.meta.effective_stack != config.effective_stack) return error.ExportGameMismatch;
    var is = try @import("init.zig").SolverInit.init(allocator, config);
    defer is.deinit();
    var solver = try cfr.Solver.init(allocator, &is, .{ .allin_cache_max_bytes = 0 });
    defer solver.deinit();
    const counts = [3]usize{ if (is.root_street == .flop) 1 else 0, if (is.root_street != .river) is.runout_tables.canonical_turns.len else 0, is.runout_tables.canonical_rivers.len };
    const seen = try allocator.alloc(bool, counts[0] + counts[1] + counts[2]);
    defer allocator.free(seen);
    @memset(seen, false);
    const nodes = try allocator.alloc(?*const ExportNode, is.tree.action_nodes.items.len);
    defer allocator.free(nodes);
    const bc = tree.BuildConfig{ .start_street = config.startStreet(), .initial_pot = config.initial_pot, .effective_stack = config.effective_stack, .min_bet = config.min_bet, .sizings = config.sizings, .raise_cap = config.raise_cap, .range_sizes = solver.N };
    for (data.streets) |street| {
        const board = try parseBoard(street.board);
        if (!std.meta.eql(board.flop, config.flop) or !std.mem.eql(u8, street.street, @tagName(board.street()))) return error.InvalidExportBoard;
        const resolution = try extract.resolveRunout(&is, board.turn, board.river);
        const si = resolution.street.index();
        if (resolution.runoutId() >= counts[si]) return error.InvalidExportBoard;
        var offset: usize = resolution.runoutId();
        for (counts[0..si]) |count| offset += count;
        if (seen[offset]) return error.DuplicateExportEntry;
        seen[offset] = true;
        @memset(nodes, null);
        for (street.nodes) |*node| {
            if (try tree.refTag(node.id) != .action or tree.refIndex(node.id) >= nodes.len) return error.ExportTreeMismatch;
            const idx = tree.refIndex(node.id);
            if (nodes[idx] != null) return error.DuplicateExportEntry;
            nodes[idx] = node;
        }
        var visitor = ImportStreet{ .solver = &solver, .resolution = resolution, .board = board, .nodes = nodes };
        try tree.walkActionNodes(&is.tree, bc, &visitor);
        if (visitor.consumed != street.nodes.len) return error.ExportTreeMismatch;
    }
    for (seen) |present| if (!present) return error.IncompleteExport;
    return exploitability(allocator, &solver);
}

test "export verification requires complete coverage and matching action amounts" {
    const alloc = std.testing.allocator;
    const init_mod = @import("init.zig");
    const output = @import("output.zig");
    const parse = @import("parse.zig");
    const wc = @import("range.zig").WeightedCombo;
    const oop = [_]wc{.{ .combo = try card.Combo.init(try parse.parseCard("Ah"), try parse.parseCard("Kh")), .weight = 1 }};
    const ip = [_]wc{.{ .combo = try card.Combo.init(try parse.parseCard("Qd"), try parse.parseCard("Jd")), .weight = 1 }};
    var cfg = init_mod.Config.default(try parse.parseFlop(alloc, "As 8s 6s"), &oop, &ip);
    cfg.initial_pot = 10;
    cfg.effective_stack = 8;
    cfg.sizings = .{ &.{}, &.{}, &.{} };
    for ([_]bool{ false, true }) |river_root| {
        if (river_root) {
            cfg.turn = try parse.parseCard("2c");
            cfg.river = try parse.parseCard("3d");
        }
        var is = try init_mod.SolverInit.init(alloc, cfg);
        defer is.deinit();
        var solver = try cfr.Solver.init(alloc, &is, .{});
        defer solver.deinit();
        solver.iterate(16);
        const reference = try exploitability(alloc, &solver);
        var writer = std.Io.Writer.Allocating.init(alloc);
        defer writer.deinit();
        const bc = tree.BuildConfig{ .start_street = cfg.startStreet(), .initial_pot = cfg.initial_pot, .effective_stack = cfg.effective_stack, .min_bet = cfg.min_bet, .sizings = cfg.sizings, .raise_cap = cfg.raise_cap, .range_sizes = solver.N };
        const meta = output.Meta{ .flop = cfg.flop, .effective_stack = cfg.effective_stack, .iterations = 16, .exploitability_pct = 0, .exploitability_chips = 0, .ev_oop = 0, .ev_ip = 0, .converged = false };
        try output.writeJson(alloc, &writer.writer, &solver, bc, meta, .{ .all_runouts = true });
        const checked = try verifyExport(alloc, cfg, writer.written());
        try std.testing.expectApproxEqAbs(reference.pct, checked.pct, 0.001);
        const corrupted = try alloc.dupe(u8, writer.written());
        defer alloc.free(corrupted);
        const pos = std.mem.indexOf(u8, corrupted, "all-in").?;
        corrupted[pos] = 'b';
        try std.testing.expectError(error.ExportTreeMismatch, verifyExport(alloc, cfg, corrupted));
        if (!river_root) {
            var partial = std.Io.Writer.Allocating.init(alloc);
            defer partial.deinit();
            try output.writeJson(alloc, &partial.writer, &solver, bc, meta, .{});
            try std.testing.expectError(error.IncompleteExport, verifyExport(alloc, cfg, partial.written()));
        }
    }
}
