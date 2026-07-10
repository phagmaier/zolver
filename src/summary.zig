//! Task 3 — human-readable strategy summary for the terminal.
//!
//! Prints the solved strategy at the key flop decision points (OOP's opening
//! action and IP's immediate responses), broken down by made-hand class on the
//! flop. Frequencies are range-weighted averages over the combos in each class.
//!
//! Hand classes are the current made hand on the 5-card flop (2 hole + 3 board):
//! `set+` (trips or better, or a made straight/flush), `two pair`, `pair`, and
//! `high card`. This is objective and needs no draw heuristics; it does not
//! distinguish top- from middle-pair.

const std = @import("std");
const card = @import("card.zig");
const game_tree = @import("game_tree.zig");
const cfr = @import("cfr.zig");

const Card = card.Card;
const Combo = card.Combo;
const Action = game_tree.Action;
const ActionNodeVisit = game_tree.ActionNodeVisit;
const Solver = cfr.Solver;
const Writer = std.Io.Writer;

pub const HandClass = enum {
    set_plus,
    two_pair,
    pair,
    high_card,

    pub fn label(self: HandClass) []const u8 {
        return switch (self) {
            .set_plus => "set+",
            .two_pair => "two pair",
            .pair => "pair",
            .high_card => "high card",
        };
    }
};

const class_order = [_]HandClass{ .set_plus, .two_pair, .pair, .high_card };

/// Straight rank masks (bit r set ⇒ rank index r present). Indices 0..8 are the
/// nine "normal" straights 2-6 … T-A; index 9 is the wheel (A-2-3-4-5).
const straight_masks = blk: {
    var m: [10]u16 = undefined;
    for (0..9) |i| m[i] = @as(u16, 0b11111) << @intCast(i);
    m[9] = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 12);
    break :blk m;
};

/// Classify a hand's current made hand on the flop (2 hole + 3 board cards).
pub fn classifyFlop(hole: Combo, flop: [3]Card) HandClass {
    const cards = [5]Card{ hole.first, hole.second, flop[0], flop[1], flop[2] };

    var rank_counts = [_]u8{0} ** 13;
    var suit_counts = [_]u8{0} ** 4;
    var rank_present: u16 = 0;
    for (cards) |c| {
        rank_counts[card.rankIndex(c)] += 1;
        suit_counts[card.suitIndex(c)] += 1;
        rank_present |= @as(u16, 1) << @intCast(card.rankIndex(c));
    }

    var max_count: u8 = 0;
    var pair_count: u8 = 0;
    for (rank_counts) |rc| {
        if (rc > max_count) max_count = rc;
        if (rc == 2) pair_count += 1;
    }

    if (max_count >= 3) return .set_plus; // trips, full house, quads
    if (pair_count >= 2) return .two_pair;
    if (pair_count == 1) return .pair;

    // Five distinct ranks: a made straight or flush counts as a strong hand.
    for (suit_counts) |sc| {
        if (sc >= 5) return .set_plus; // flush (monotone board + suited hole)
    }
    for (straight_masks) |m| {
        if (rank_present == m) return .set_plus;
    }
    return .high_card;
}

/// Per-class accumulator for one node. `sum[c][a]` is the range-weighted mass of
/// action `a` from class `c`; dividing by `total[c]` yields the frequency.
const ClassStats = struct {
    count: [class_order.len]u32 = .{0} ** class_order.len,
    total: [class_order.len]f32 = .{0} ** class_order.len,
    sum: [class_order.len][8]f32 = .{.{0} ** 8} ** class_order.len,
};

/// Print the flop strategy summary (OOP opening + IP responses) to `w`.
pub fn printSummary(
    allocator: std.mem.Allocator,
    w: *Writer,
    solver: *Solver,
    build_config: game_tree.BuildConfig,
    flop: [3]Card,
) !void {
    const n_max = @max(solver.N[0], solver.N[1]);
    const grid = try allocator.alloc(f32, 8 * n_max);
    defer allocator.free(grid);

    try w.writeAll("\nStrategy summary — flop ");
    try writeBoard(w, flop);
    try w.writeAll("\n");

    var printer = Printer{ .w = w, .solver = solver, .flop = flop, .grid = grid };
    try game_tree.walkActionNodes(&solver.init_state.tree, build_config, &printer);
}

const Printer = struct {
    w: *Writer,
    solver: *Solver,
    flop: [3]Card,
    grid: []f32,

    pub fn visitActionNode(self: *Printer, v: ActionNodeVisit) !void {
        // Key decision points: OOP's opening node (root) and IP's immediate
        // responses — i.e. flop-street nodes reached in at most one action.
        if (v.street != .flop) return;
        if (v.path.len > 1) return;
        try self.printNode(v);
    }

    fn printNode(self: *Printer, v: ActionNodeVisit) !void {
        const w = self.w;
        const player: u8 = @intFromEnum(v.player);
        const a = v.actions.len;
        const n = self.solver.N[player];
        const is = self.solver.init_state;

        self.solver.averageStrategy(.flop, 0, v.ref, self.grid[0 .. a * n]);

        // Node title.
        try w.writeAll("\n");
        try w.writeAll(if (v.player == .oop) "OOP" else "IP");
        if (v.path.len == 0) {
            try w.writeAll(" to act:\n");
        } else {
            try w.writeAll(" vs ");
            try writeAction(w, v.path[0]);
            try w.writeAll(":\n");
        }

        // Accumulate range-weighted action mass per made-hand class.
        const flop_mask = card.boardMask(&self.flop);
        var stats = ClassStats{};
        const hands = is.ranges[player].hands;
        const weights = is.ranges[player].weights;
        for (hands, weights, 0..) |hand, weight, h| {
            if ((hand.cardMask() & flop_mask) != 0) continue; // blocked by the flop
            const cls = @intFromEnum(classifyFlop(hand, self.flop));
            stats.count[cls] += 1;
            stats.total[cls] += weight;
            for (0..a) |ai| stats.sum[cls][ai] += weight * self.grid[ai * n + h];
        }

        // Header.
        try w.writeAll("  hand class    combos");
        for (v.actions) |act| {
            var buf: [16]u8 = undefined;
            try w.print(" {s:>10}", .{actionLabel(act, &buf)});
        }
        try w.writeAll("\n");

        // One row per non-empty class, strongest first.
        for (class_order) |cls| {
            const ci = @intFromEnum(cls);
            if (stats.count[ci] == 0) continue;
            try w.print("  {s:<12}{d:>6}", .{ cls.label(), stats.count[ci] });
            const tot = stats.total[ci];
            for (0..a) |ai| {
                const pct: f32 = if (tot > 0) stats.sum[ci][ai] / tot * 100.0 else 0.0;
                try w.print(" {d:>9.1}%", .{pct});
            }
            try w.writeAll("\n");
        }
    }
};

fn writeBoard(w: *Writer, flop: [3]Card) !void {
    const a = card.cardStr(flop[0]);
    const b = card.cardStr(flop[1]);
    const c = card.cardStr(flop[2]);
    try w.print("{s} {s} {s}", .{ &a, &b, &c });
}

fn writeAction(w: *Writer, action: Action) !void {
    var buf: [16]u8 = undefined;
    try w.writeAll(actionLabel(action, &buf));
}

/// Format an action label into `buf`, returning the written slice.
fn actionLabel(action: Action, buf: []u8) []const u8 {
    return switch (action.kind) {
        .check => "check",
        .fold => "fold",
        .call => "call",
        .all_in => "all-in",
        .bet => std.fmt.bufPrint(buf, "bet {d}", .{action.amount}) catch "bet",
        .raise => std.fmt.bufPrint(buf, "raise {d}", .{action.amount}) catch "raise",
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn cc(rank: u32, suit: u32) Card {
    return card.makeCard(rank, suit);
}

test "classifyFlop: made-hand categories on As Kd 7h" {
    const flop = [3]Card{ cc(12, 0), cc(11, 2), cc(5, 1) }; // As Kd 7h

    // Set of sevens (7s7c + 7h on board).
    try testing.expectEqual(HandClass.set_plus, classifyFlop(try Combo.init(cc(5, 0), cc(5, 3)), flop));
    // Two pair: A and K both pair the board.
    try testing.expectEqual(HandClass.two_pair, classifyFlop(try Combo.init(cc(12, 1), cc(11, 0)), flop));
    // One pair: aces.
    try testing.expectEqual(HandClass.pair, classifyFlop(try Combo.init(cc(12, 1), cc(2, 3)), flop));
    // High card: Q-J, no pair, no draw made.
    try testing.expectEqual(HandClass.high_card, classifyFlop(try Combo.init(cc(10, 0), cc(9, 3)), flop));
}

test "classifyFlop: pocket pair over/under the board is one pair" {
    const flop = [3]Card{ cc(12, 0), cc(11, 2), cc(5, 1) };
    // QQ (under aces/kings) — still just one pair.
    try testing.expectEqual(HandClass.pair, classifyFlop(try Combo.init(cc(10, 1), cc(10, 3)), flop));
    // A pocket pair that matches the board makes a set.
    try testing.expectEqual(HandClass.set_plus, classifyFlop(try Combo.init(cc(11, 0), cc(11, 1)), flop));
}

test "classifyFlop: straight and flush count as set+" {
    // Made straight: flop T-9-8, hole Q-J → Q J T 9 8.
    const straight_flop = [3]Card{ cc(8, 0), cc(7, 1), cc(6, 2) }; // T 9 8
    try testing.expectEqual(HandClass.set_plus, classifyFlop(try Combo.init(cc(10, 3), cc(9, 3)), straight_flop)); // Q J
    // Wheel straight A-2-3-4-5: flop 3-4-5, hole A-2.
    const wheel_flop = [3]Card{ cc(1, 0), cc(2, 1), cc(3, 2) }; // 3 4 5
    try testing.expectEqual(HandClass.set_plus, classifyFlop(try Combo.init(cc(12, 3), cc(0, 3)), wheel_flop)); // A 2
    // Monotone flop + suited hole = flush.
    const mono = [3]Card{ cc(12, 0), cc(9, 0), cc(2, 0) }; // all spades
    try testing.expectEqual(HandClass.set_plus, classifyFlop(try Combo.init(cc(7, 0), cc(5, 0)), mono));
}

const init_mod = @import("init.zig");
const range = @import("range.zig");
const WeightedCombo = range.WeightedCombo;

fn wc(x: Card, y: Card) !WeightedCombo {
    return .{ .combo = try Combo.init(x, y), .weight = 1.0 };
}

test "printSummary renders the root and IP responses" {
    const alloc = testing.allocator;
    const flop = [3]Card{ cc(12, 0), cc(10, 1), cc(7, 2) }; // As Qh 9d (rainbow)
    const one_sizing = [_]game_tree.Sizing{game_tree.Sizing.init(50, 100)};
    const sizings: [3][]const game_tree.Sizing = .{ &one_sizing, &one_sizing, &one_sizing };
    const oop = [_]WeightedCombo{ try wc(cc(12, 1), cc(12, 2)), try wc(cc(11, 0), cc(9, 0)) };
    const ip = [_]WeightedCombo{ try wc(cc(10, 0), cc(10, 3)), try wc(cc(8, 3), cc(6, 3)) };

    const config = init_mod.Config{
        .flop = flop,
        .initial_pot = 10,
        .effective_stack = 16,
        .min_bet = 2,
        .sizings = sizings,
        .raise_cap = .{ 0, 0, 0 },
        .oop_range = &oop,
        .ip_range = &ip,
        .max_budget_bytes = std.math.maxInt(u64),
    };
    var is = try init_mod.SolverInit.init(alloc, config);
    defer is.deinit();
    var solver = try Solver.init(alloc, &is, .{});
    defer solver.deinit();
    solver.iterate(20);

    const bc = game_tree.BuildConfig{
        .initial_pot = 10,
        .effective_stack = 16,
        .min_bet = 2,
        .sizings = sizings,
        .raise_cap = .{ 0, 0, 0 },
        .range_sizes = .{ is.ranges[0].N(), is.ranges[1].N() },
    };

    var aw = Writer.Allocating.init(alloc);
    defer aw.deinit();
    try printSummary(alloc, &aw.writer, &solver, bc, flop);
    const out = aw.written();

    // Headline, both actors, and at least one class row appear.
    try testing.expect(std.mem.indexOf(u8, out, "Strategy summary") != null);
    try testing.expect(std.mem.indexOf(u8, out, "OOP to act") != null);
    try testing.expect(std.mem.indexOf(u8, out, "IP vs ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "hand class") != null);
    // The OOP opening node has no path, so it is the first node printed.
    const oop_pos = std.mem.indexOf(u8, out, "OOP to act").?;
    const ip_pos = std.mem.indexOf(u8, out, "IP vs ").?;
    try testing.expect(oop_pos < ip_pos);
}
