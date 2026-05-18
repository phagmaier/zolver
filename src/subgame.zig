const std = @import("std");
const Allocator = std.mem.Allocator;

const card_mod = @import("card.zig");
const Card = card_mod.Card;
const cfr = @import("cfr.zig");
const gamestate_mod = @import("gamestate.zig");
const Action = gamestate_mod.Action;
const GameState = gamestate_mod.GameState;
const Street = gamestate_mod.Street;
const node_mod = @import("node.zig");
const Edge = node_mod.Edge;
const Node = node_mod.Node;
const range_mod = @import("range.zig");
const Range = range_mod.Range;

pub const NUM_HANDS = cfr.NUM_HANDS;
pub const MAX_ACTION_PATH: usize = 16;

pub const PathStep = struct {
    action: Action,
    amount: f32,

    pub fn fromEdge(edge: *const Edge) PathStep {
        return .{ .action = edge.action, .amount = edge.amount };
    }

    pub fn eql(self: PathStep, other: PathStep) bool {
        return self.action == other.action and approxEq(self.amount, other.amount);
    }
};

pub const ActionPath = struct {
    steps: [MAX_ACTION_PATH]PathStep,
    len: u8,

    pub fn empty() ActionPath {
        return .{
            .steps = undefined,
            .len = 0,
        };
    }

    pub fn with(self: *const ActionPath, edge: *const Edge) !ActionPath {
        if (self.len >= MAX_ACTION_PATH) return error.ActionPathTooLong;
        var next = self.*;
        next.steps[next.len] = PathStep.fromEdge(edge);
        next.len += 1;
        return next;
    }

    pub fn slice(self: *const ActionPath) []const PathStep {
        return self.steps[0..self.len];
    }

    pub fn eql(self: *const ActionPath, expected: []const PathStep) bool {
        if (self.len != expected.len) return false;
        for (self.slice(), expected) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }
};

pub const ReachProbs = struct {
    p1: [NUM_HANDS]f32,
    p2: [NUM_HANDS]f32,

    pub fn zero() ReachProbs {
        var self: ReachProbs = undefined;
        @memset(&self.p1, 0);
        @memset(&self.p2, 0);
        return self;
    }

    pub fn fromSolver(solver: *const cfr.Solver) ReachProbs {
        return .{
            .p1 = solver.p1_reach,
            .p2 = solver.p2_reach,
        };
    }
};

pub const BuildOptions = struct {
    truncate_after: ?Street = null,
};

pub const Subgame = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    solver: cfr.Solver,
    root: *Node,
    root_state: GameState,
    board: [5]Card,
    root_reach: ReachProbs,
    cfv_p1: [NUM_HANDS]f32,
    cfv_p2: [NUM_HANDS]f32,

    pub fn init(
        allocator: Allocator,
        root_state: GameState,
        board: [5]Card,
        reach: *const ReachProbs,
        options: BuildOptions,
    ) !Subgame {
        if (root_state.isTerm) return error.TerminalRootState;
        if (root_state.is_chance) return error.ChanceRootState;

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        var root_state_copy = root_state;
        var root_edges = std.ArrayList(Edge).empty;
        defer root_edges.deinit(allocator);

        if (options.truncate_after) |street| {
            try node_mod.buildTreeTruncated(&root_state_copy, &root_edges, arena_allocator, allocator, NUM_HANDS, NUM_HANDS, street);
        } else {
            try node_mod.buildTree(&root_state_copy, &root_edges, arena_allocator, allocator, NUM_HANDS, NUM_HANDS);
        }

        if (root_edges.items.len == 0) return error.EmptyTree;
        const root = root_edges.items[0].child orelse return error.TerminalRootState;

        var p1_range = try rangeFromDense(allocator, &reach.p1);
        defer p1_range.deinit(allocator);
        var p2_range = try rangeFromDense(allocator, &reach.p2);
        defer p2_range.deinit(allocator);

        var solver = try cfr.Solver.init(board, &p1_range, &p2_range, root_state.stack1, root_state.stack2, root_state.pot);
        errdefer solver.deinit();

        return .{
            .allocator = allocator,
            .arena = arena,
            .solver = solver,
            .root = root,
            .root_state = root_state,
            .board = board,
            .root_reach = ReachProbs.fromSolver(&solver),
            .cfv_p1 = undefined,
            .cfv_p2 = undefined,
        };
    }

    pub fn deinit(self: *Subgame) void {
        self.solver.deinit();
        self.arena.deinit();
    }

    pub fn solve(self: *Subgame, iterations: usize, random: std.Random) !void {
        try cfr.solve(&self.solver, self.allocator, self.root, iterations, random, &self.cfv_p1, &self.cfv_p2);
    }

    pub fn exploitability(self: *Subgame) !f32 {
        return cfr.exploitability(&self.solver, self.root);
    }

    pub fn collectChanceSeeds(self: *Subgame, allocator: Allocator) !std.ArrayList(ChanceSeed) {
        var seeds = std.ArrayList(ChanceSeed).empty;
        errdefer seeds.deinit(allocator);
        try collectChanceSeedsRecursive(allocator, self.root, self.root_state, ActionPath.empty(), &self.root_reach.p1, &self.root_reach.p2, &seeds);
        return seeds;
    }
};


pub const ChanceSeed = struct {
    state: GameState,
    path: ActionPath,
    reach: ReachProbs,

    pub fn buildNextStreetSubgame(
        self: *const ChanceSeed,
        allocator: Allocator,
        board: [5]Card,
        public_card: Card,
        options: BuildOptions,
    ) !Subgame {
        if (!self.state.is_chance) return error.NotAChanceSeed;

        const next_board = try boardWithPublicCard(board, public_card);
        var next_reach = self.reach;
        maskReachForCard(&next_reach, public_card);

        const post_chance = self.state.applyChance();
        return Subgame.init(allocator, post_chance, next_board, &next_reach, options);
    }
};

pub const SubgameManager = struct {
    allocator: Allocator,
    flop: ?Subgame,
    chance_seeds: std.ArrayList(ChanceSeed),

    pub fn init(allocator: Allocator) SubgameManager {
        return .{
            .allocator = allocator,
            .flop = null,
            .chance_seeds = .empty,
        };
    }

    pub fn deinit(self: *SubgameManager) void {
        if (self.flop) |*flop| flop.deinit();
        self.chance_seeds.deinit(self.allocator);
    }

    pub fn solveFlop(
        self: *SubgameManager,
        root_state: GameState,
        board: [5]Card,
        reach: *const ReachProbs,
        iterations: usize,
        random: std.Random,
    ) !void {
        if (root_state.street != .FLOP) return error.ExpectedFlopRoot;

        if (self.flop) |*old| old.deinit();
        self.flop = null;
        self.chance_seeds.clearRetainingCapacity();

        var flop = try Subgame.init(self.allocator, root_state, board, reach, .{ .truncate_after = .FLOP });
        errdefer flop.deinit();
        try flop.solve(iterations, random);

        self.flop = flop;
        try self.refreshChanceSeeds();
    }

    pub fn refreshChanceSeeds(self: *SubgameManager) !void {
        self.chance_seeds.clearRetainingCapacity();
        const flop = if (self.flop) |*value| value else return error.NoFlopSolution;
        try collectChanceSeedsRecursive(
            self.allocator,
            flop.root,
            flop.root_state,
            ActionPath.empty(),
            &flop.root_reach.p1,
            &flop.root_reach.p2,
            &self.chance_seeds,
        );
    }

    pub fn chanceSeeds(self: *const SubgameManager) []const ChanceSeed {
        return self.chance_seeds.items;
    }

    pub fn findSeedByPath(self: *const SubgameManager, path: []const PathStep) ?usize {
        return findSeedByPathIn(self.chance_seeds.items, path);
    }


    pub fn solveTurn(
        self: *SubgameManager,
        seed_index: usize,
        turn_card: Card,
        iterations: usize,
        random: std.Random,
    ) !Subgame {
        const flop = if (self.flop) |*value| value else return error.NoFlopSolution;
        if (seed_index >= self.chance_seeds.items.len) return error.InvalidChanceSeed;

        var turn = try self.chance_seeds.items[seed_index].buildNextStreetSubgame(
            self.allocator,
            flop.board,
            turn_card,
            .{ .truncate_after = .TURN },
        );
        errdefer turn.deinit();
        try turn.solve(iterations, random);
        return turn;
    }

    pub fn solveTurnByPath(
        self: *SubgameManager,
        path: []const PathStep,
        turn_card: Card,
        iterations: usize,
        random: std.Random,
    ) !Subgame {
        const seed_index = self.findSeedByPath(path) orelse return error.InvalidChanceSeed;
        return self.solveTurn(seed_index, turn_card, iterations, random);
    }
};

pub fn findSeedByPathIn(seeds: []const ChanceSeed, path: []const PathStep) ?usize {
    for (seeds, 0..) |*seed, i| {
        if (seed.path.eql(path)) return i;
    }
    return null;
}

pub fn solveRiverFromPath(
    allocator: Allocator,
    seeds: []const ChanceSeed,
    path: []const PathStep,
    turn_board: [5]Card,
    river_card: Card,
    iterations: usize,
    random: std.Random,
) !Subgame {
    const idx = findSeedByPathIn(seeds, path) orelse return error.InvalidChanceSeed;
    return solveRiverFromSeed(allocator, &seeds[idx], turn_board, river_card, iterations, random);
}

pub fn solveRiverFromSeed(
    allocator: Allocator,
    seed: *const ChanceSeed,
    turn_board: [5]Card,
    river_card: Card,
    iterations: usize,
    random: std.Random,
) !Subgame {
    var river = try seed.buildNextStreetSubgame(allocator, turn_board, river_card, .{});
    errdefer river.deinit();
    try river.solve(iterations, random);
    return river;
}

fn rangeFromDense(allocator: Allocator, dense: *const [NUM_HANDS]f32) !Range {
    var count: usize = 0;
    for (dense) |p| {
        if (p != 0) count += 1;
    }

    var range = try Range.initEmpty(allocator, count);
    errdefer range.deinit(allocator);

    var out: usize = 0;
    for (dense, 0..) |p, i| {
        if (p == 0) continue;
        range.active_indices[out] = @intCast(i);
        range.probs[out] = p;
        out += 1;
    }
    return range;
}

fn collectChanceSeedsRecursive(
    allocator: Allocator,
    node: *const Node,
    state: GameState,
    path: ActionPath,
    p1_reach: []const f32,
    p2_reach: []const f32,
    seeds: *std.ArrayList(ChanceSeed),
) !void {
    if (node.is_chance) {
        var seed = ChanceSeed{
            .state = state,
            .path = path,
            .reach = undefined,
        };
        std.debug.assert(state.is_chance);
        @memcpy(&seed.reach.p1, p1_reach);
        @memcpy(&seed.reach.p2, p2_reach);
        try seeds.append(allocator, seed);
        return;
    }

    const n_actions = node.edges.len;
    const avg_strategy = try allocator.alloc(f32, n_actions * NUM_HANDS);
    defer allocator.free(avg_strategy);
    cfr.averageStrategy(node, avg_strategy);

    var next_p1: [NUM_HANDS]f32 = undefined;
    var next_p2: [NUM_HANDS]f32 = undefined;

    for (node.edges, 0..) |*edge, action_index| {
        if (edge.child == null) continue;

        const next_state = try stateForEdge(&state, edge);
        const offset = action_index * NUM_HANDS;
        if (node.isp1) {
            for (0..NUM_HANDS) |i| {
                next_p1[i] = p1_reach[i] * avg_strategy[offset + i];
                next_p2[i] = p2_reach[i];
            }
        } else {
            for (0..NUM_HANDS) |i| {
                next_p1[i] = p1_reach[i];
                next_p2[i] = p2_reach[i] * avg_strategy[offset + i];
            }
        }

        const next_path = try path.with(edge);
        try collectChanceSeedsRecursive(allocator, edge.child.?, next_state, next_path, &next_p1, &next_p2, seeds);
    }
}

fn stateForEdge(state: *const GameState, edge: *const Edge) !GameState {
    return switch (edge.action) {
        .FOLD => state.getFoldGameState() orelse error.TreeStateMismatch,
        .CHECK => state.getCheckGameState() orelse error.TreeStateMismatch,
        .CALL => state.getCallGameState() orelse error.TreeStateMismatch,
        .ALLIN => state.getAllInGameState() orelse error.TreeStateMismatch,
        .BET => betStateForEdge(state, edge),
        .CHANCE => if (state.is_chance) state.applyChance() else error.TreeStateMismatch,
    };
}

fn betStateForEdge(state: *const GameState, edge: *const Edge) !GameState {
    for (gamestate_mod.BETSIZES) |pct| {
        if (state.getBetGameState(pct)) |next| {
            if (sameEdgeState(next, edge)) return next;
        }
    }
    return error.TreeStateMismatch;
}

fn sameEdgeState(state: GameState, edge: *const Edge) bool {
    return approxEq(state.pot, edge.amount) and
        approxEq(state.stack1, edge.stack1) and
        approxEq(state.stack2, edge.stack2) and
        state.action == edge.action;
}

fn approxEq(a: f32, b: f32) bool {
    return @abs(a - b) <= 1e-3;
}

fn boardWithPublicCard(board: [5]Card, public_card: Card) ![5]Card {
    if (public_card == 0) return error.InvalidPublicCard;
    if (boardContains(board, public_card)) return error.CardAlreadyOnBoard;

    var next = board;
    const count = boardCardCount(board);
    if (count == 3) {
        next[3] = public_card;
    } else if (count == 4) {
        next[4] = public_card;
    } else {
        return error.InvalidBoardCardCount;
    }
    return next;
}

fn boardCardCount(board: [5]Card) usize {
    var count: usize = 0;
    for (board) |c| {
        if (c != 0) count += 1;
    }
    return count;
}

fn boardContains(board: [5]Card, card: Card) bool {
    if (card == 0) return false;
    for (board) |bc| {
        if (bc == card) return true;
    }
    return false;
}

fn maskReachForCard(reach: *ReachProbs, public_card: Card) void {
    const table = range_mod.HandTable.init();
    for (table.all_hands, 0..) |hand, i| {
        if (hand.card1 == public_card or hand.card2 == public_card) {
            reach.p1[i] = 0;
            reach.p2[i] = 0;
        }
    }
}

fn findFirst(edges: []Edge, action: gamestate_mod.Action) ?*Edge {
    for (edges) |*edge| {
        if (edge.action == action) return edge;
    }
    return null;
}

fn actionIndex(edges: []Edge, action: gamestate_mod.Action) ?usize {
    for (edges, 0..) |edge, i| {
        if (edge.action == action) return i;
    }
    return null;
}

fn countEdges(edges: []const Edge) usize {
    var total: usize = 0;
    for (edges) |*edge| {
        total += 1;
        if (edge.child) |child| {
            total += countEdges(child.edges);
        }
    }
    return total;
}

test "Subgame.init builds a fresh CFR instance from GameState and ReachProbs" {
    const allocator = std.testing.allocator;

    const board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        card_mod.makeCard(3, 3),
        card_mod.makeCard(2, 0),
    };

    const table = range_mod.HandTable.init();
    const aa_idx = table.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
    const kk_idx = table.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;

    var reach = ReachProbs.zero();
    reach.p1[aa_idx] = 1.0;
    reach.p2[kk_idx] = 1.0;

    const state = GameState.init(.RIVER, true, 50, 100, 100);
    var subgame = try Subgame.init(allocator, state, board, &reach, .{});
    defer subgame.deinit();

    try std.testing.expect(subgame.root.edges.len > 0);
    try std.testing.expectEqual(@as(f32, 1.0), subgame.solver.p1_reach[aa_idx]);
    try std.testing.expectEqual(@as(f32, 1.0), subgame.solver.p2_reach[kk_idx]);
    try std.testing.expectEqual(@as(f32, 50), subgame.solver.pot_at_root);
}

test "SubgameManager collects flop chance seeds and resolves a turn subgame" {
    const allocator = std.testing.allocator;

    const board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        0,
        0,
    };

    const table = range_mod.HandTable.init();
    const aa_idx = table.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
    const kk_idx = table.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;

    var reach = ReachProbs.zero();
    reach.p1[aa_idx] = 1.0;
    reach.p2[kk_idx] = 1.0;

    var manager = SubgameManager.init(allocator);
    defer manager.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    try manager.solveFlop(GameState.init(.FLOP, true, 50, 100, 100), board, &reach, 0, prng.random());
    try std.testing.expect(manager.chance_seeds.items.len > 0);
    const check_check_path = [_]PathStep{
        .{ .action = .CHECK, .amount = 50 },
        .{ .action = .CHECK, .amount = 50 },
    };
    const check_check_seed = manager.findSeedByPath(&check_check_path).?;
    try std.testing.expect(manager.chance_seeds.items[check_check_seed].path.eql(&check_check_path));

    const turn_card = card_mod.makeCard(12, 0);
    var turn = try manager.solveTurnByPath(&check_check_path, turn_card, 0, prng.random());
    defer turn.deinit();

    try std.testing.expectEqual(Street.TURN, turn.root_state.street);
    try std.testing.expectEqual(turn_card, turn.board[3]);
    try std.testing.expectEqual(@as(f32, 0), turn.solver.p1_reach[aa_idx]);
    try std.testing.expect(turn.solver.p2_reach[kk_idx] > 0);

    const root_check = findFirst(turn.root.edges, .CHECK).?;
    const p2_node = root_check.child.?;
    const p2_check = findFirst(p2_node.edges, .CHECK).?;
    const river_leaf = p2_check.child.?;
    try std.testing.expect(river_leaf.is_chance);
    try std.testing.expect(river_leaf.is_leaf);
}

test "SubgameManager finds chance seeds by deterministic action path" {
    const allocator = std.testing.allocator;

    const board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        0,
        0,
    };

    const table = range_mod.HandTable.init();
    const aa_idx = table.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
    const kk_idx = table.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;

    var reach = ReachProbs.zero();
    reach.p1[aa_idx] = 1.0;
    reach.p2[kk_idx] = 1.0;

    var manager = SubgameManager.init(allocator);
    defer manager.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    try manager.solveFlop(GameState.init(.FLOP, true, 50, 100, 100), board, &reach, 0, prng.random());

    const check_check_path = [_]PathStep{
        .{ .action = .CHECK, .amount = 50 },
        .{ .action = .CHECK, .amount = 50 },
    };
    const check_check = manager.findSeedByPath(&check_check_path).?;
    try std.testing.expect(manager.chance_seeds.items[check_check].state.is_chance);
    try std.testing.expect(manager.chance_seeds.items[check_check].path.eql(&check_check_path));

    const half_bet_call_path = [_]PathStep{
        .{ .action = .BET, .amount = 75 },
        .{ .action = .CALL, .amount = 100 },
    };
    const half_bet_call = manager.findSeedByPath(&half_bet_call_path).?;
    try std.testing.expect(manager.chance_seeds.items[half_bet_call].state.is_chance);
    try std.testing.expectApproxEqAbs(@as(f32, 100), manager.chance_seeds.items[half_bet_call].state.pot, 1e-3);
    try std.testing.expect(manager.chance_seeds.items[half_bet_call].path.eql(&half_bet_call_path));

    const full_bet_call_path = [_]PathStep{
        .{ .action = .BET, .amount = 100 },
        .{ .action = .CALL, .amount = 150 },
    };
    const full_bet_call = manager.findSeedByPath(&full_bet_call_path).?;
    try std.testing.expect(half_bet_call != full_bet_call);
    try std.testing.expectApproxEqAbs(@as(f32, 150), manager.chance_seeds.items[full_bet_call].state.pot, 1e-3);
}

test "verification: turn re-solve matches full turn all-in response strategy" {
    const allocator = std.testing.allocator;

    const flop_board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        0,
        0,
    };
    const turn_card = card_mod.makeCard(3, 3);

    const table = range_mod.HandTable.init();
    const aa_idx = table.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
    const kk_idx = table.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;

    var reach = ReachProbs.zero();
    reach.p1[aa_idx] = 1.0;
    reach.p2[kk_idx] = 1.0;

    var manager = SubgameManager.init(allocator);
    defer manager.deinit();

    var flop_prng = std.Random.DefaultPrng.init(42);
    try manager.solveFlop(GameState.init(.FLOP, true, 50, 100, 100), flop_board, &reach, 0, flop_prng.random());

    const seed_idx = manager.findSeedByPath(&.{
        .{ .action = .CHECK, .amount = 50 },
        .{ .action = .CHECK, .amount = 50 },
    }).?;
    const seed = &manager.chance_seeds.items[seed_idx];

    var full_turn = try seed.buildNextStreetSubgame(allocator, flop_board, turn_card, .{});
    defer full_turn.deinit();
    var trunc_turn = try seed.buildNextStreetSubgame(allocator, flop_board, turn_card, .{ .truncate_after = .TURN });
    defer trunc_turn.deinit();

    var full_prng = std.Random.DefaultPrng.init(43);
    try full_turn.solve(20, full_prng.random());
    var trunc_prng = std.Random.DefaultPrng.init(43);
    try trunc_turn.solve(20, trunc_prng.random());

    const full_allin = findFirst(full_turn.root.edges, .ALLIN).?;
    const trunc_allin = findFirst(trunc_turn.root.edges, .ALLIN).?;
    const full_p2_node = full_allin.child.?;
    const trunc_p2_node = trunc_allin.child.?;

    const full_strategy = try allocator.alloc(f32, full_p2_node.edges.len * NUM_HANDS);
    defer allocator.free(full_strategy);
    const trunc_strategy = try allocator.alloc(f32, trunc_p2_node.edges.len * NUM_HANDS);
    defer allocator.free(trunc_strategy);
    cfr.averageStrategy(full_p2_node, full_strategy);
    cfr.averageStrategy(trunc_p2_node, trunc_strategy);

    const full_fold = actionIndex(full_p2_node.edges, .FOLD).?;
    const trunc_fold = actionIndex(trunc_p2_node.edges, .FOLD).?;
    const full_call = actionIndex(full_p2_node.edges, .CALL).?;
    const trunc_call = actionIndex(trunc_p2_node.edges, .CALL).?;

    try std.testing.expectApproxEqAbs(
        full_strategy[full_fold * NUM_HANDS + kk_idx],
        trunc_strategy[trunc_fold * NUM_HANDS + kk_idx],
        0.35,
    );
    try std.testing.expectApproxEqAbs(
        full_strategy[full_call * NUM_HANDS + kk_idx],
        trunc_strategy[trunc_call * NUM_HANDS + kk_idx],
        0.35,
    );
}

test "verification: polarized vs condensed compact truncated game exploitability is bounded" {
    const allocator = std.testing.allocator;

    const board = [5]Card{
        card_mod.makeCard(12, 0),
        card_mod.makeCard(11, 0),
        card_mod.makeCard(0, 1),
        card_mod.makeCard(1, 2),
        0,
    };

    const table = range_mod.HandTable.init();
    var reach = ReachProbs.zero();
    const aa = table.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(12, 2))).?;
    const kk = table.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 1), card_mod.makeCard(11, 2))).?;
    const air = table.getIndex(range_mod.Hand.init(card_mod.makeCard(5, 0), card_mod.makeCard(0, 3))).?;
    reach.p1[aa] = 0.2;
    reach.p1[kk] = 0.2;
    reach.p1[air] = 0.6;

    const aq = table.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(10, 2))).?;
    const aj = table.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(9, 2))).?;
    const at = table.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(8, 2))).?;
    reach.p2[aq] = 0.33;
    reach.p2[aj] = 0.33;
    reach.p2[at] = 0.34;

    var p1_range = try rangeFromDense(allocator, &reach.p1);
    defer p1_range.deinit(allocator);
    var p2_range = try rangeFromDense(allocator, &reach.p2);
    defer p2_range.deinit(allocator);

    var solver = try cfr.Solver.init(board, &p1_range, &p2_range, 500, 500, 100);
    defer solver.deinit();

    var check_leaf_edges = [_]Edge{.{
        .action = .CHANCE,
        .amount = 100,
        .stack1 = 500,
        .stack2 = 500,
        .child = null,
    }};
    var check_leaf = Node{
        .is_chance = true,
        .is_leaf = true,
        .isp1 = true,
        .id = node_mod.UNASSIGNED_ID,
        .regrets = &.{},
        .strategy_sum = &.{},
        .edges = check_leaf_edges[0..],
    };

    var call_leaf_edges = [_]Edge{.{
        .action = .CHANCE,
        .amount = 1100,
        .stack1 = 0,
        .stack2 = 0,
        .child = null,
    }};
    var call_leaf = Node{
        .is_chance = true,
        .is_leaf = true,
        .isp1 = true,
        .id = node_mod.UNASSIGNED_ID,
        .regrets = &.{},
        .strategy_sum = &.{},
        .edges = call_leaf_edges[0..],
    };

    var p2_regrets: [2 * NUM_HANDS]f32 = undefined;
    var p2_strategy_sum: [2 * NUM_HANDS]f32 = undefined;
    @memset(&p2_regrets, 0);
    @memset(&p2_strategy_sum, 0);
    var p2_edges = [_]Edge{
        .{
            .action = .FOLD,
            .amount = 600,
            .stack1 = 0,
            .stack2 = 500,
            .child = null,
        },
        .{
            .action = .CALL,
            .amount = 1100,
            .stack1 = 0,
            .stack2 = 0,
            .child = &call_leaf,
        },
    };
    var p2_node = Node{
        .is_chance = false,
        .is_leaf = false,
        .isp1 = false,
        .id = node_mod.UNASSIGNED_ID,
        .regrets = p2_regrets[0..],
        .strategy_sum = p2_strategy_sum[0..],
        .edges = p2_edges[0..],
    };

    var root_regrets: [2 * NUM_HANDS]f32 = undefined;
    var root_strategy_sum: [2 * NUM_HANDS]f32 = undefined;
    @memset(&root_regrets, 0);
    @memset(&root_strategy_sum, 0);
    var root_edges = [_]Edge{
        .{
            .action = .CHECK,
            .amount = 100,
            .stack1 = 500,
            .stack2 = 500,
            .child = &check_leaf,
        },
        .{
            .action = .ALLIN,
            .amount = 600,
            .stack1 = 0,
            .stack2 = 500,
            .child = &p2_node,
        },
    };
    var root = Node{
        .is_chance = false,
        .is_leaf = false,
        .isp1 = true,
        .id = node_mod.UNASSIGNED_ID,
        .regrets = root_regrets[0..],
        .strategy_sum = root_strategy_sum[0..],
        .edges = root_edges[0..],
    };

    var prng = std.Random.DefaultPrng.init(42);
    var cfv_p1: [NUM_HANDS]f32 = undefined;
    var cfv_p2: [NUM_HANDS]f32 = undefined;
    try cfr.solve(&solver, allocator, &root, 200, prng.random(), &cfv_p1, &cfv_p2);

    try std.testing.expect(try cfr.exploitability(&solver, &root) < 1.0);
}

test "verification: truncated flop tree stays far smaller than full flop topology" {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const allocator = da.allocator();

    var full_arena = std.heap.ArenaAllocator.init(allocator);
    defer full_arena.deinit();
    var trunc_arena = std.heap.ArenaAllocator.init(allocator);
    defer trunc_arena.deinit();

    var full_state = GameState.init(.FLOP, true, 50, 100, 100);
    var trunc_state = full_state;

    var full_edges = std.ArrayList(Edge).empty;
    defer full_edges.deinit(allocator);
    var trunc_edges = std.ArrayList(Edge).empty;
    defer trunc_edges.deinit(allocator);

    try node_mod.buildTree(&full_state, &full_edges, full_arena.allocator(), allocator, 1, 1);
    try node_mod.buildTreeTruncated(&trunc_state, &trunc_edges, trunc_arena.allocator(), allocator, 1, 1, .FLOP);

    const full_count = countEdges(full_edges.items);
    const trunc_count = countEdges(trunc_edges.items);

    try std.testing.expect(trunc_count < full_count);
    try std.testing.expect(trunc_count < 250);
}

test "ActionPath.with errors at MAX_ACTION_PATH boundary" {
    const edge = Edge{
        .action = .CHECK,
        .amount = 50,
        .stack1 = 100,
        .stack2 = 100,
        .child = null,
    };

    var path = ActionPath.empty();
    var i: usize = 0;
    while (i < MAX_ACTION_PATH) : (i += 1) {
        path = try path.with(&edge);
    }
    try std.testing.expectEqual(@as(u8, MAX_ACTION_PATH), path.len);
    try std.testing.expectError(error.ActionPathTooLong, path.with(&edge));
}
