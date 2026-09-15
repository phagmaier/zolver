//! Exact all-in equity matrices for modest ranges. Construction uses the
//! existing blocker-aware river sweep on basis vectors; solves then multiply
//! by the current opponent reach. Wide ranges retain the sweep implementation
//! to avoid excessive initialization work. The cache is optional and budgeted.
const std = @import("std");
const init_mod = @import("init.zig");
const terminal = @import("terminal_eval.zig");
const Scratch = @import("scratch.zig").Scratch;

pub const Cache = struct {
    allocator: std.mem.Allocator,
    n: [2]usize,
    data: []f32,
    boards: usize,

    pub const Plan = struct {
        boards: usize = 0,
        retained: u64 = 0,
    };

    /// Account for temporary equity accumulation as well as retained matrices.
    pub fn plan(is: *const init_mod.SolverInit, budget: u64) Plan {
        const pairs = @as(u64, is.ranges[0].N()) * is.ranges[1].N();
        if (pairs == 0 or pairs > 65_536 or budget < pairs * 16) return .{};
        const boards = 1 + is.runout_tables.canonical_turns.len;
        if (pairs * (4 * boards + 8) <= budget) return .{ .boards = boards, .retained = pairs * 4 * boards };
        return .{ .boards = 1, .retained = pairs * 4 };
    }

    pub fn init(allocator: std.mem.Allocator, is: *const init_mod.SolverInit, budget: u64, scratch: *Scratch) !?Cache {
        const p = plan(is, budget);
        if (p.boards == 0) return null;
        const n0 = is.ranges[0].hands.len;
        const n1 = is.ranges[1].hands.len;
        const pairs = n0 * n1;
        const data = try allocator.alloc(f32, pairs * p.boards);
        errdefer allocator.free(data);
        const flop = try allocator.alloc(f64, pairs);
        defer allocator.free(flop);
        @memset(flop, 0);
        const temp: []f32 = if (p.boards == 1) try allocator.alloc(f32, pairs) else &.{};
        defer if (temp.len != 0) allocator.free(temp);
        const basis = scratch.reachOpp(0, @intCast(n1));
        const values = scratch.nodeValues(0, @intCast(n0));
        const ctx = terminal.AllInContext{
            .u = 0,
            .sd = &is.showdown,
            .rt = &is.runout_tables,
            .card_idx = .{ is.card_idx[0], is.card_idx[1] },
            .u_hands = is.ranges[0].hands,
            .opp_hands = is.ranges[1].hands,
            .mask_river = .{ is.mask_river[0], is.mask_river[1] },
            .weight_rivers = is.weight_rivers,
            .weight_turns = is.weight_turns,
            .same_combo_idx = is.same_combo_idx[0],
            .win_amount = 1,
            .loss_amount = 0,
            .tie_amount = 0.5,
            .rm = if (is.compress_suits) &is.remap.? else null,
        };
        for (is.runout_tables.canonical_turns, 0..) |_, t| {
            const matrix = if (p.boards == 1) temp else data[(t + 1) * pairs ..][0..pairs];
            for (0..n1) |j| {
                @memset(basis, 0);
                basis[j] = 1;
                if (is.compress_suits) {
                    terminal.allInEvalTurnRemapped(values, basis, t, ctx, scratch.allInScratch(@intCast(n0), @intCast(n1)));
                } else {
                    terminal.allInEvalTurn(values, basis, t, ctx, scratch.allInScratch(@intCast(n0), @intCast(n1)));
                }
                for (values, 0..) |v, h| matrix[h * n1 + j] = std.math.clamp(v, 0, 1);
            }
            if (is.remap) |rm| {
                for (rm.turn_members[t]) |member| {
                    const hp = rm.hand_perms[member.perm_index];
                    for (0..n0) |h| for (0..n1) |j| {
                        flop[h * n1 + j] += @as(f64, matrix[hp.to_canon[0][h] * n1 + hp.to_canon[1][j]]) / 45.0;
                    };
                }
            } else {
                for (matrix, flop) |e, *sum| sum.* += @as(f64, e) / 45.0;
            }
            if (p.boards > 1) markIncompatible(matrix, is, t);
        }
        for (data[0..pairs], flop) |*v, e| v.* = @floatCast(std.math.clamp(e, 0, 1));
        markIncompatible(data[0..pairs], is, null);
        return .{ .allocator = allocator, .n = .{ n0, n1 }, .data = data, .boards = p.boards };
    }

    fn markIncompatible(matrix: []f32, is: *const init_mod.SolverInit, turn: ?usize) void {
        const n0 = is.ranges[0].hands.len;
        const n1 = is.ranges[1].hands.len;
        const m0 = if (turn) |t| is.mask_turn[0][t * n0 ..][0..n0] else is.mask_flop[0];
        const m1 = if (turn) |t| is.mask_turn[1][t * n1 ..][0..n1] else is.mask_flop[1];
        for (is.ranges[0].hands, 0..) |a, h| for (is.ranges[1].hands, 0..) |b, j| {
            if (m0[h] == 0 or m1[j] == 0 or a.cardMask() & b.cardMask() != 0) matrix[h * n1 + j] = -1;
        };
    }

    pub fn deinit(self: *Cache) void {
        self.allocator.free(self.data);
    }

    pub fn memoryBytes(self: Cache) u64 {
        return self.data.len * @sizeOf(f32);
    }

    /// The sentinel distinguishes incompatible pairs from valid zero-equity
    /// hands. Return false when the requested turn matrix was not retained.
    pub fn evaluate(self: *const Cache, u: u8, turn: ?u32, reach: []const f32, pot: u32, initial_pot: u32, out: []f32) bool {
        const board: usize = if (turn) |t| @as(usize, t) + 1 else 0;
        if (board >= self.boards) return false;
        const matrix = self.data[board * self.n[0] * self.n[1] ..];
        const pf: f64 = @floatFromInt(pot);
        const contribution = (pf - @as(f64, @floatFromInt(initial_pot))) / 2;
        for (out, 0..) |*v, h| {
            var total: f64 = 0;
            for (reach, 0..) |r, j| {
                const e = matrix[if (u == 0) h * self.n[1] + j else j * self.n[1] + h];
                if (e < 0) continue;
                const equity: f64 = if (u == 0) @as(f64, e) else 1 - @as(f64, e);
                total += @as(f64, r) * (pf * equity - contribution);
            }
            v.* = @floatCast(total);
        }
        return true;
    }
};
