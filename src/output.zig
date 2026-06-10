//! Phase 10 — JSON output of solved strategies (Task 1).
//!
//! Walks the tree's action nodes (`game_tree.walkActionNodes`) and emits, per
//! node, the acting player, the line taken from the root, the legal actions,
//! and per-hand average strategies + EVs. Output is grouped by street:
//!
//!   - The flop tree is always emitted; it is runout-independent (one storage
//!     block, identity suit permutation).
//!   - A turn/river subtree is emitted only for a *concrete* runout — either a
//!     specific real `(turn[, river])` card, or every canonical runout under
//!     `all_runouts`.
//!
//! Strategy grids are cheap (a normalized read of stored strategy). Per-hand
//! EVs cost one full average-profile pass per node (`captureNodeValues`), so
//! they are computed for the bounded targeted dumps but skipped (emitted as
//! `null`) under `all_runouts`, where the node × runout count makes per-node
//! passes infeasible.

const std = @import("std");
const card = @import("card.zig");
const game_tree = @import("game_tree.zig");
const cfr = @import("cfr.zig");
const extract = @import("extract.zig");
const init_mod = @import("init.zig");

const Card = card.Card;
const Street = game_tree.Street;
const Action = game_tree.Action;
const Player = game_tree.Player;
const ActionNodeVisit = game_tree.ActionNodeVisit;
const Solver = cfr.Solver;
const SolverInit = init_mod.SolverInit;
const Writer = std.Io.Writer;

pub const Options = struct {
    turn: ?Card = null,
    river: ?Card = null,
    all_runouts: bool = false,
};

/// Solve summary written into the JSON `meta` object.
pub const Meta = struct {
    flop: [3]Card,
    effective_stack: u32,
    iterations: u32,
    exploitability_pct: f32,
    exploitability_chips: f32,
    ev_oop: f32,
    ev_ip: f32,
    converged: bool,
};

pub const OutputError = error{RiverRequiresTurn};

/// Render the full solved result as JSON to `w`. `build_config` must be the
/// same configuration the tree was built from (it re-derives action labels).
pub fn writeJson(
    allocator: std.mem.Allocator,
    w: *Writer,
    solver: *Solver,
    build_config: game_tree.BuildConfig,
    meta: Meta,
    options: Options,
) !void {
    if (options.river != null and options.turn == null) return OutputError.RiverRequiresTurn;

    const n_max = @max(solver.N[0], solver.N[1]);
    const grid = try allocator.alloc(f32, 8 * n_max); // A ≤ 8 children per node
    defer allocator.free(grid);
    const evs = try allocator.alloc(f32, n_max);
    defer allocator.free(evs);

    try w.writeAll("{\n");
    try writeMeta(w, solver, meta);
    try w.writeAll(",\n  \"streets\": [\n");

    var first_street = true;

    // Flop — always; runout-independent.
    try emitStreet(w, solver, build_config, meta.flop, null, null, true, grid, evs, &first_street);

    if (options.all_runouts) {
        const rt = &solver.init_state.runout_tables;
        for (rt.canonical_turns, 0..) |ct, ti| {
            try emitStreet(w, solver, build_config, meta.flop, ct.card, null, false, grid, evs, &first_street);
            for (rt.riversForTurn(ti)) |cr| {
                try emitStreet(w, solver, build_config, meta.flop, ct.card, cr.card, false, grid, evs, &first_street);
            }
        }
    } else if (options.turn) |t| {
        try emitStreet(w, solver, build_config, meta.flop, t, null, true, grid, evs, &first_street);
        if (options.river) |rv| {
            try emitStreet(w, solver, build_config, meta.flop, t, rv, true, grid, evs, &first_street);
        }
    }

    try w.writeAll("\n  ]\n}\n");
}

fn writeMeta(w: *Writer, solver: *Solver, meta: Meta) !void {
    try w.writeAll("  \"meta\": {\n    \"flop\": \"");
    try writeBoard(w, meta.flop, null, null);
    try w.writeAll("\",\n");
    try w.print("    \"initial_pot\": {d},\n", .{solver.init_state.tree.initial_pot});
    try w.print("    \"effective_stack\": {d},\n", .{meta.effective_stack});
    try w.print("    \"iterations\": {d},\n", .{meta.iterations});
    try w.print("    \"exploitability_pct\": {d:.4},\n", .{meta.exploitability_pct});
    try w.print("    \"exploitability_chips\": {d:.4},\n", .{meta.exploitability_chips});
    try w.print("    \"ev_oop\": {d:.4},\n", .{meta.ev_oop});
    try w.print("    \"ev_ip\": {d:.4},\n", .{meta.ev_ip});
    try w.print("    \"converged\": {}\n", .{meta.converged});
    try w.writeAll("  }");
}

/// Emit one street object: all action nodes at the resolved street for the
/// given (turn, river) runout, each with per-hand strategies (+ EVs if `with_ev`).
fn emitStreet(
    w: *Writer,
    solver: *Solver,
    build_config: game_tree.BuildConfig,
    flop: [3]Card,
    turn: ?Card,
    river: ?Card,
    with_ev: bool,
    grid: []f32,
    evs: []f32,
    first_street: *bool,
) !void {
    const is = solver.init_state;
    const res = try extract.resolveRunout(is, turn, river);

    if (!first_street.*) try w.writeAll(",\n");
    first_street.* = false;

    try w.writeAll("    { \"street\": \"");
    try w.writeAll(streetName(res.street));
    try w.writeAll("\", \"board\": \"");
    try writeBoard(w, flop, turn, river);
    try w.writeAll("\", \"nodes\": [\n");

    var board_mask = card.boardMask(&flop);
    if (turn) |t| board_mask |= card.mask(t);
    if (river) |rv| board_mask |= card.mask(rv);

    var emitter = StreetEmitter{
        .w = w,
        .solver = solver,
        .is = is,
        .res = res,
        .runout_id = res.runoutId(),
        .target = res.street,
        .board_mask = board_mask,
        .with_ev = with_ev,
        .grid = grid,
        .evs = evs,
    };
    try game_tree.walkActionNodes(&is.tree, build_config, &emitter);

    try w.writeAll("\n    ] }");
}

const StreetEmitter = struct {
    w: *Writer,
    solver: *Solver,
    is: *SolverInit,
    res: extract.RunoutResolution,
    runout_id: u32,
    target: Street,
    board_mask: u64,
    with_ev: bool,
    grid: []f32,
    evs: []f32,
    first_node: bool = true,

    pub fn visitActionNode(self: *StreetEmitter, v: ActionNodeVisit) !void {
        if (v.street != self.target) return; // only the street we are dumping
        try self.emitNode(v);
    }

    fn emitNode(self: *StreetEmitter, v: ActionNodeVisit) !void {
        const w = self.w;
        const player: u8 = @intFromEnum(v.player);
        const a = v.actions.len;
        const n = self.solver.N[player];

        // Strategy grid, action-major: grid[ai*n + h].
        self.solver.averageStrategy(self.target, self.runout_id, v.ref, self.grid[0 .. a * n]);

        var have_ev = false;
        if (self.with_ev) {
            have_ev = self.solver.captureNodeValues(player, v.ref, self.runout_id, self.evs[0..n]);
        }

        if (!self.first_node) try w.writeAll(",\n");
        self.first_node = false;

        try w.writeAll("      { \"id\": ");
        try w.print("{d}", .{v.ref});
        try w.writeAll(", \"player\": \"");
        try w.writeAll(playerName(v.player));
        try w.writeAll("\", \"line\": [");
        try writeActionArray(w, v.path);
        try w.writeAll("], \"actions\": [");
        try writeActionArray(w, v.actions);
        try w.writeAll("], \"hands\": [\n");

        var first_hand = true;
        for (self.is.ranges[player].hands) |hand| {
            if ((hand.cardMask() & self.board_mask) != 0) continue; // hand uses a board card
            const ci = extract.canonicalHandIndex(self.is, player, hand, self.res) orelse continue;

            if (!first_hand) try w.writeAll(",\n");
            first_hand = false;

            try w.writeAll("        { \"combo\": \"");
            try writeCard(w, hand.first);
            try writeCard(w, hand.second);
            try w.writeAll("\", \"strategy\": [");
            for (0..a) |ai| {
                if (ai != 0) try w.writeAll(", ");
                try w.print("{d:.6}", .{self.grid[ai * n + ci]});
            }
            try w.writeAll("], \"ev\": ");
            if (have_ev) {
                try w.print("{d:.4}", .{self.evs[ci]});
            } else {
                try w.writeAll("null");
            }
            try w.writeAll(" }");
        }
        try w.writeAll("\n      ] }");
    }
};

fn writeActionArray(w: *Writer, actions: []const Action) !void {
    for (actions, 0..) |a, i| {
        if (i != 0) try w.writeAll(", ");
        try w.writeAll("\"");
        try writeAction(w, a);
        try w.writeAll("\"");
    }
}

/// Human-readable action label. Bet/raise amounts are in chips.
fn writeAction(w: *Writer, a: Action) !void {
    switch (a.kind) {
        .check => try w.writeAll("check"),
        .fold => try w.writeAll("fold"),
        .call => try w.writeAll("call"),
        .all_in => try w.writeAll("all-in"),
        .bet => try w.print("bet {d}", .{a.amount}),
        .raise => try w.print("raise {d}", .{a.amount}),
    }
}

fn writeCard(w: *Writer, c: Card) !void {
    const s = card.cardStr(c);
    try w.writeAll(&s);
}

fn writeBoard(w: *Writer, flop: [3]Card, turn: ?Card, river: ?Card) !void {
    try writeCard(w, flop[0]);
    try w.writeAll(" ");
    try writeCard(w, flop[1]);
    try w.writeAll(" ");
    try writeCard(w, flop[2]);
    if (turn) |t| {
        try w.writeAll(" ");
        try writeCard(w, t);
    }
    if (river) |rv| {
        try w.writeAll(" ");
        try writeCard(w, rv);
    }
}

fn playerName(p: Player) []const u8 {
    return switch (p) {
        .oop => "oop",
        .ip => "ip",
    };
}

fn streetName(s: Street) []const u8 {
    return switch (s) {
        .flop => "flop",
        .turn => "turn",
        .river => "river",
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const range = @import("range.zig");
const WeightedCombo = range.WeightedCombo;
const Combo = card.Combo;

fn wc(a: Card, b: Card) !WeightedCombo {
    return .{ .combo = try Combo.init(a, b), .weight = 1.0 };
}

const one_sizing = [_]game_tree.Sizing{game_tree.Sizing.init(50, 100)};
const test_sizings: [3][]const game_tree.Sizing = .{ &one_sizing, &one_sizing, &one_sizing };

fn buildTestInit(allocator: std.mem.Allocator) !SolverInit {
    // Rainbow flop so canonical runouts are simple; small symmetric ranges.
    const flop = [_]Card{ card.makeCard(12, 0), card.makeCard(10, 1), card.makeCard(7, 2) };
    const oop = [_]WeightedCombo{
        try wc(card.makeCard(11, 0), card.makeCard(9, 0)),
        try wc(card.makeCard(8, 3), card.makeCard(6, 3)),
    };
    const ip = [_]WeightedCombo{
        try wc(card.makeCard(11, 1), card.makeCard(9, 1)),
        try wc(card.makeCard(8, 0), card.makeCard(6, 0)),
    };
    const config = init_mod.Config{
        .flop = flop,
        .initial_pot = 10,
        .effective_stack = 16,
        .min_bet = 2,
        .sizings = test_sizings,
        .raise_cap = .{ 0, 0, 0 },
        .oop_range = &oop,
        .ip_range = &ip,
        .max_budget_bytes = std.math.maxInt(u64),
    };
    return SolverInit.init(allocator, config);
}

fn testBuildConfig(is: *const SolverInit) game_tree.BuildConfig {
    return .{
        .initial_pot = is.tree.initial_pot,
        .effective_stack = 16,
        .min_bet = 2,
        .sizings = test_sizings,
        .raise_cap = .{ 0, 0, 0 },
        .range_sizes = .{ is.ranges[0].N(), is.ranges[1].N() },
    };
}

fn renderToBuf(allocator: std.mem.Allocator, solver: *Solver, bc: game_tree.BuildConfig, opts: Options) ![]u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const meta = Meta{
        .flop = .{ card.makeCard(12, 0), card.makeCard(10, 1), card.makeCard(7, 2) },
        .effective_stack = 16,
        .iterations = solver.t,
        .exploitability_pct = 0,
        .exploitability_chips = 0,
        .ev_oop = solver.averageEV(0),
        .ev_ip = solver.averageEV(1),
        .converged = false,
    };
    try writeJson(allocator, &aw.writer, solver, bc, meta, opts);
    return allocator.dupe(u8, aw.written());
}

test "writeJson emits parseable JSON with a flop street" {
    const alloc = testing.allocator;
    var is = try buildTestInit(alloc);
    defer is.deinit();
    var solver = try Solver.init(alloc, &is, .{});
    defer solver.deinit();
    solver.iterate(20);

    const json = try renderToBuf(alloc, &solver, testBuildConfig(&is), .{});
    defer alloc.free(json);

    // Valid JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expect(root.contains("meta"));
    const streets = root.get("streets").?.array;
    // Default dump: exactly one street (flop).
    try testing.expectEqual(@as(usize, 1), streets.items.len);
    const flop = streets.items[0].object;
    try testing.expectEqualStrings("flop", flop.get("street").?.string);
    const nodes = flop.get("nodes").?.array;
    try testing.expect(nodes.items.len >= 1);

    // The root node: every strategy row sums to ~1 and has one entry per action.
    const node0 = nodes.items[0].object;
    const actions = node0.get("actions").?.array;
    const hands = node0.get("hands").?.array;
    try testing.expect(hands.items.len >= 1);
    for (hands.items) |h| {
        const strat = h.object.get("strategy").?.array;
        try testing.expectEqual(actions.items.len, strat.items.len);
        var s: f64 = 0;
        for (strat.items) |p| s += p.float;
        try testing.expectApproxEqAbs(@as(f64, 1.0), s, 1e-4);
        // EV present (flop dump computes EVs).
        try testing.expect(h.object.get("ev").? == .float or h.object.get("ev").? == .integer);
    }
}

test "writeJson with a turn card adds a turn street" {
    const alloc = testing.allocator;
    var is = try buildTestInit(alloc);
    defer is.deinit();
    var solver = try Solver.init(alloc, &is, .{});
    defer solver.deinit();
    solver.iterate(20);

    const turn = is.runout_tables.canonical_turns[0].card;
    const json = try renderToBuf(alloc, &solver, testBuildConfig(&is), .{ .turn = turn });
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const streets = parsed.value.object.get("streets").?.array;
    try testing.expectEqual(@as(usize, 2), streets.items.len);
    try testing.expectEqualStrings("flop", streets.items[0].object.get("street").?.string);
    try testing.expectEqualStrings("turn", streets.items[1].object.get("street").?.string);
}

test "writeJson all_runouts emits every canonical runout with null EVs" {
    const alloc = testing.allocator;
    var is = try buildTestInit(alloc);
    defer is.deinit();
    var solver = try Solver.init(alloc, &is, .{});
    defer solver.deinit();
    solver.iterate(8);

    const json = try renderToBuf(alloc, &solver, testBuildConfig(&is), .{ .all_runouts = true });
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const streets = parsed.value.object.get("streets").?.array;

    // flop + every canonical turn + every canonical river.
    const rt = &is.runout_tables;
    const expected = 1 + rt.canonical_turns.len + rt.canonical_rivers.len;
    try testing.expectEqual(expected, streets.items.len);
    try testing.expectEqualStrings("flop", streets.items[0].object.get("street").?.string);

    // EVs are skipped under all_runouts: every non-flop hand has ev == null.
    var checked_null = false;
    for (streets.items[1..]) |s| {
        for (s.object.get("nodes").?.array.items) |nd| {
            for (nd.object.get("hands").?.array.items) |h| {
                try testing.expect(h.object.get("ev").? == .null);
                checked_null = true;
            }
        }
    }
    try testing.expect(checked_null);
}

test "writeJson rejects a river without a turn" {
    const alloc = testing.allocator;
    var is = try buildTestInit(alloc);
    defer is.deinit();
    var solver = try Solver.init(alloc, &is, .{});
    defer solver.deinit();
    solver.iterate(2);

    var aw = Writer.Allocating.init(alloc);
    defer aw.deinit();
    const meta = Meta{
        .flop = .{ card.makeCard(12, 0), card.makeCard(10, 1), card.makeCard(7, 2) },
        .effective_stack = 16,
        .iterations = 2,
        .exploitability_pct = 0,
        .exploitability_chips = 0,
        .ev_oop = 0,
        .ev_ip = 0,
        .converged = false,
    };
    const river = is.runout_tables.canonical_rivers[0].card;
    try testing.expectError(
        OutputError.RiverRequiresTurn,
        writeJson(alloc, &aw.writer, &solver, testBuildConfig(&is), meta, .{ .river = river }),
    );
}
