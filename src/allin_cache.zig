//! Budgeted exact-runout equity cache. Integer win/tie counts avoid repeated
//! basis-vector showdown sweeps. Both players read contiguous matrix rows.
const std = @import("std");
const init_mod = @import("init.zig");
const Scratch = @import("scratch.zig").Scratch;

pub const Cache = struct {
    allocator: std.mem.Allocator,
    n: [2]usize,
    data: []f32,
    boards: usize,

    pub const Plan = struct { boards: usize = 0, retained: u64 = 0 };

    pub fn plan(is: *const init_mod.SolverInit, budget: u64) Plan {
        return planForIterations(is, budget, 1000);
    }

    /// Rough break-even model: construction visits every matchup; a sweep
    /// visits each hand. Memory includes two orientations, f64 flop sums and
    /// integer counts. A short solve can deliberately retain the sweep path.
    pub fn planForIterations(is: *const init_mod.SolverInit, budget: u64, iterations: u32) Plan {
        if (is.root_street == .river) return .{};
        const pairs = @as(u64, is.ranges[0].N()) * is.ranges[1].N();
        const hands = @as(u64, is.ranges[0].N()) + is.ranges[1].N();
        if (pairs == 0 or pairs > @as(u64, iterations) * hands or budget < pairs * 18) return .{};
        const boards = 1 + is.runout_tables.canonical_turns.len;
        if (pairs * (8 * boards + 10) <= budget) return .{ .boards = boards, .retained = pairs * 8 * boards };
        // On a turn root slot zero is unused; do not construct an unusable cache.
        if (is.root_street == .turn) return .{};
        return .{ .boards = 1, .retained = pairs * 8 };
    }

    pub fn init(allocator: std.mem.Allocator, is: *const init_mod.SolverInit, budget: u64, scratch: *Scratch) !?Cache {
        return initForIterations(allocator, is, budget, scratch, 1000);
    }

    pub fn initForIterations(allocator: std.mem.Allocator, is: *const init_mod.SolverInit, budget: u64, scratch: *Scratch, iterations: u32) !?Cache {
        _ = scratch;
        const p = planForIterations(is, budget, iterations);
        if (p.boards == 0) return null;
        const n0 = is.ranges[0].hands.len;
        const n1 = is.ranges[1].hands.len;
        const pairs = n0 * n1;
        const data = try allocator.alloc(f32, 2 * pairs * p.boards);
        errdefer allocator.free(data);
        const flop = try allocator.alloc(f64, pairs);
        defer allocator.free(flop);
        @memset(flop, 0);
        const counts = try allocator.alloc(u16, pairs);
        defer allocator.free(counts);
        for (is.runout_tables.canonical_turns, 0..) |turn, t| {
            @memset(counts, 0);
            for (0..turn.num_rivers) |r| {
                const full = turn.first_river + r;
                if (is.remap) |rm| {
                    for (rm.river_members[full]) |member| {
                        const hp = rm.hand_perms[member.perm_index];
                        countRiver(counts, is, full, hp.to_canon[0], hp.to_canon[1]);
                    }
                } else countRiver(counts, is, full, null, null);
            }
            if (is.root_street == .flop) {
                if (is.remap) |rm| {
                    for (rm.turn_members[t]) |member| {
                        const hp = rm.hand_perms[member.perm_index];
                        for (0..n0) |h| for (0..n1) |j| {
                            flop[h * n1 + j] += @as(f64, @floatFromInt(counts[hp.to_canon[0][h] * n1 + hp.to_canon[1][j]])) / (88.0 * 45.0);
                        };
                    }
                } else {
                    for (counts, flop) |e, *sum| sum.* += @as(f64, @floatFromInt(e)) / (88.0 * 45.0);
                }
            }
            if (p.boards > 1) {
                const matrix = data[2 * (t + 1) * pairs ..][0..pairs];
                for (matrix, counts) |*v, c| v.* = @as(f32, @floatFromInt(c)) / 88.0;
                markIncompatible(matrix, is, t);
                transpose(matrix, data[(2 * (t + 1) + 1) * pairs ..][0..pairs], n0, n1);
            }
        }
        for (data[0..pairs], flop) |*v, e| v.* = @floatCast(e);
        markIncompatible(data[0..pairs], is, null);
        transpose(data[0..pairs], data[pairs..][0..pairs], n0, n1);
        return .{ .allocator = allocator, .n = .{ n0, n1 }, .data = data, .boards = p.boards };
    }

    fn countRiver(counts: []u16, is: *const init_mod.SolverInit, full: usize, map0: ?[]const u32, map1: ?[]const u32) void {
        const n0 = is.ranges[0].hands.len;
        const n1 = is.ranges[1].hands.len;
        const s0 = is.showdown.strengths[0][full * n0 ..][0..n0];
        const s1 = is.showdown.strengths[1][full * n1 ..][0..n1];
        for (0..n0) |h| {
            const a = s0[if (map0) |m| m[h] else h];
            if (a == 0) continue;
            for (0..n1) |j| {
                const b = s1[if (map1) |m| m[j] else j];
                if (b != 0) counts[h * n1 + j] += if (a > b) @as(u16, 2) else if (a == b) @as(u16, 1) else 0;
            }
        }
    }

    fn transpose(src: []const f32, dst: []f32, n0: usize, n1: usize) void {
        for (0..n0) |h| for (0..n1) |j| {
            dst[j * n0 + h] = src[h * n1 + j];
        };
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

    pub fn evaluate(self: *const Cache, u: u8, turn: ?u32, reach: []const f32, pot: u32, initial_pot: u32, out: []f32) bool {
        const board: usize = if (turn) |t| @as(usize, t) + 1 else 0;
        if (board >= self.boards) return false;
        const matrix = self.data[(2 * board + u) * self.n[0] * self.n[1] ..];
        const pf: f64 = @floatFromInt(pot);
        const contribution = (pf - @as(f64, @floatFromInt(initial_pot))) / 2;
        for (out, 0..) |*v, h| {
            var total: f64 = 0;
            const row = matrix[h * reach.len ..][0..reach.len];
            for (reach, row) |r, e| {
                if (e < 0) continue;
                const equity: f64 = if (u == 0) @as(f64, e) else 1 - @as(f64, e);
                total += @as(f64, r) * (pf * equity - contribution);
            }
            v.* = @floatCast(total);
        }
        return true;
    }
};
