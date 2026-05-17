const std = @import("std");
const Allocator = std.mem.Allocator;

const card_mod = @import("card.zig");
const Card = card_mod.Card;
const cfr = @import("cfr.zig");
const gamestate_mod = @import("gamestate.zig");
const GameState = gamestate_mod.GameState;
const Street = gamestate_mod.Street;
const node_mod = @import("node.zig");
const Edge = node_mod.Edge;
const Node = node_mod.Node;
const range_mod = @import("range.zig");
const Range = range_mod.Range;

pub const NUM_HANDS = cfr.NUM_HANDS;

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

    pub fn solve(self: *Subgame, iterations: usize, random: std.Random) void {
        cfr.solve(&self.solver, self.root, iterations, random, &self.cfv_p1, &self.cfv_p2);
    }

    pub fn exploitability(self: *Subgame) f32 {
        return self.solver.exploitability(self.root);
    }

    pub fn collectChanceSeeds(self: *Subgame, allocator: Allocator) !std.ArrayList(ChanceSeed) {
        var seeds = std.ArrayList(ChanceSeed).empty;
        errdefer seeds.deinit(allocator);
        try collectChanceSeedsRecursive(allocator, self.root, self.root_state, &self.root_reach.p1, &self.root_reach.p2, &seeds);
        return seeds;
    }
};

pub const ChanceSeed = struct {
    state: GameState,
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
        flop.solve(iterations, random);

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
            &flop.root_reach.p1,
            &flop.root_reach.p2,
            &self.chance_seeds,
        );
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
        turn.solve(iterations, random);
        return turn;
    }
};

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
    river.solve(iterations, random);
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
    p1_reach: []const f32,
    p2_reach: []const f32,
    seeds: *std.ArrayList(ChanceSeed),
) !void {
    if (node.is_chance) {
        var seed = ChanceSeed{
            .state = state,
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

        try collectChanceSeedsRecursive(allocator, edge.child.?, next_state, &next_p1, &next_p2, seeds);
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

    const turn_card = card_mod.makeCard(12, 0);
    var turn = try manager.solveTurn(0, turn_card, 0, prng.random());
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
