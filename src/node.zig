const std = @import("std");
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const GameStateModule = @import("gamestate.zig");
const GameState = GameStateModule.GameState;
const Action = GameStateModule.Action;
const BETSIZES = GameStateModule.BETSIZES;

pub const Edge = struct {
    action: Action,
    amount: f32,
    stack1: f32,
    stack2: f32,
    child: ?*Node,

    pub fn init(arena: Allocator, state: *GameState) !Edge {
        return Edge{
            .action = state.action,
            .amount = state.pot,
            .stack1 = state.stack1,
            .stack2 = state.stack2,
            .child = if (state.isTerm) null else try Node.create(arena, state.isp1),
        };
    }

    pub fn setChildren(self: *Edge, arena: Allocator, arr: *std.ArrayList(Edge), numCards: u16) !void {
        if (self.child) |child| {
            try child.finalize(arena, arr, numCards);
        }
    }
};

pub const Node = struct {
    is_chance: bool,
    isp1: bool,
    regrets: []f32,
    strategy_sum: []f32,
    edges: []Edge,

    pub fn create(arena: Allocator, isp1: bool) !*Node {
        var self = try arena.create(Node);
        self.is_chance = false;
        self.isp1 = isp1;
        self.regrets = &.{};
        self.strategy_sum = &.{};
        self.edges = &.{};
        return self;
    }

    pub fn finalize(self: *Node, arena: Allocator, arr: *std.ArrayList(Edge), numCards: u16) !void {
        const size = arr.items.len;
        self.edges = try arena.alloc(Edge, size);
        @memcpy(self.edges, arr.items);

        // Chance nodes have no strategic decision to make; CFR enumerates runouts at
        // these points instead. Skip the regret/strategy allocation for them.
        if (self.is_chance) return;

        self.regrets = try arena.alloc(f32, size * numCards);
        self.strategy_sum = try arena.alloc(f32, size * numCards);
        @memset(self.regrets, 0);
        @memset(self.strategy_sum, 0);
    }
};

pub fn buildTree(state: *GameState, arr: *std.ArrayList(Edge), arena: Allocator, temp_allocator: Allocator, numCards1: u16, numCards2: u16) !void {
    var edge = try Edge.init(arena, state);
    if (state.isTerm) {
        try arr.append(temp_allocator, edge);
        return;
    }
    var childArr = std.ArrayList(Edge).empty;
    defer childArr.deinit(temp_allocator);

    if (state.is_chance) {
        if (edge.child) |c| c.is_chance = true;
        var post_chance = state.applyChance();
        try buildTree(&post_chance, &childArr, arena, temp_allocator, numCards1, numCards2);
    } else {
        if (state.getFoldGameState()) |cState| {
            var mutable_state = cState;
            try buildTree(&mutable_state, &childArr, arena, temp_allocator, numCards1, numCards2);
        }
        if (state.getCallGameState()) |cState| {
            var mutable_state = cState;
            try buildTree(&mutable_state, &childArr, arena, temp_allocator, numCards1, numCards2);
        }
        if (state.getCheckGameState()) |cState| {
            var mutable_state = cState;
            try buildTree(&mutable_state, &childArr, arena, temp_allocator, numCards1, numCards2);
        }
        if (state.getAllInGameState()) |cState| {
            var mutable_state = cState;
            try buildTree(&mutable_state, &childArr, arena, temp_allocator, numCards1, numCards2);
        }
        for (BETSIZES) |prct| {
            if (state.getBetGameState(prct)) |cState| {
                var mutable_state = cState;
                try buildTree(&mutable_state, &childArr, arena, temp_allocator, numCards1, numCards2);
            }
        }
    }

    const numCards = if (state.isp1) numCards1 else numCards2;
    try edge.setChildren(arena, &childArr, numCards);
    try arr.append(temp_allocator, edge);
}

test "buildTree: every edge pot <= initial chips, tree is non-empty" {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const temp_allocator = da.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var root_state = GameState.init(.FLOP, true, 100.0, 1000.0, 1000.0);
    const maxPotSize = root_state.pot + root_state.stack1 + root_state.stack2;
    var arr = std.ArrayList(Edge).empty;
    defer arr.deinit(temp_allocator);
    try buildTree(&root_state, &arr, arena_allocator, temp_allocator, 16, 16);

    var count: usize = 0;
    for (arr.items) |*edge| {
        count += verifyEdge(edge, maxPotSize);
    }
    try std.testing.expect(count > 0);
}

fn verifyEdge(edge: *Edge, maxPotSize: f32) usize {
    var count: usize = 1;
    std.debug.assert(edge.amount <= maxPotSize + 1e-3);
    if (edge.child) |child| {
        for (child.edges) |*sub| {
            count += verifyEdge(sub, maxPotSize);
        }
    }
    return count;
}

test "buildTree: regret/strategy slices sized edges*numCards at every node" {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const temp_allocator = da.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const numCards1: u16 = 12;
    const numCards2: u16 = 7;
    var root_state = GameState.init(.FLOP, true, 100.0, 1000.0, 1000.0);
    var arr = std.ArrayList(Edge).empty;
    defer arr.deinit(temp_allocator);
    try buildTree(&root_state, &arr, arena_allocator, temp_allocator, numCards1, numCards2);

    // The root state's actor is p1, so the children-of-root node uses numCards1.
    for (arr.items) |*edge| {
        if (edge.child) |child| {
            try std.testing.expect(!child.is_chance);
            try std.testing.expect(child.regrets.len == child.edges.len * numCards1);
            try std.testing.expect(child.strategy_sum.len == child.edges.len * numCards1);
        }
    }
}

fn findFirst(edges: []Edge, action: GameStateModule.Action) ?*Edge {
    for (edges) |*e| if (e.action == action) return e;
    return null;
}

test "buildTree: flop check-check inserts a chance node before turn" {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const temp_allocator = da.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var root_state = GameState.init(.FLOP, true, 100.0, 1000.0, 1000.0);
    var arr = std.ArrayList(Edge).empty;
    defer arr.deinit(temp_allocator);
    try buildTree(&root_state, &arr, arena_allocator, temp_allocator, 8, 8);

    // arr[0] -> root decision node (p1 to act on flop)
    const root_node = arr.items[0].child.?;
    const p1_check = findFirst(root_node.edges, .CHECK).?;
    // p1 checked -> p2 decision node on flop
    const p2_node = p1_check.child.?;
    try std.testing.expect(!p2_node.is_chance);
    const p2_check = findFirst(p2_node.edges, .CHECK).?;
    // p2 checked -> chance node (turn deal pending)
    const chance_node = p2_check.child.?;
    try std.testing.expect(chance_node.is_chance);
    try std.testing.expect(chance_node.edges.len == 1);
    try std.testing.expect(chance_node.edges[0].action == .CHANCE);
    try std.testing.expect(chance_node.regrets.len == 0);
    try std.testing.expect(chance_node.strategy_sum.len == 0);
    // beyond the chance edge is the turn-start decision node
    const turn_node = chance_node.edges[0].child.?;
    try std.testing.expect(!turn_node.is_chance);
    try std.testing.expect(turn_node.regrets.len == turn_node.edges.len * 8);
}

test "buildTree: pre-river all-in then call builds a chance chain to a terminal showdown" {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const temp_allocator = da.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // FLOP start: all-in-call needs turn + river dealt before showdown, so the
    // builder should produce two chance nodes followed by a terminal.
    var root_state = GameState.init(.FLOP, true, 100.0, 1000.0, 1000.0);
    var arr = std.ArrayList(Edge).empty;
    defer arr.deinit(temp_allocator);
    try buildTree(&root_state, &arr, arena_allocator, temp_allocator, 4, 4);

    const root_node = arr.items[0].child.?;
    const p1_allin = findFirst(root_node.edges, .ALLIN).?;
    const p2_node = p1_allin.child.?;
    try std.testing.expect(!p2_node.is_chance);

    const p2_call = findFirst(p2_node.edges, .CALL).?;
    const turn_chance = p2_call.child.?;
    try std.testing.expect(turn_chance.is_chance);
    try std.testing.expect(turn_chance.edges.len == 1);
    try std.testing.expect(turn_chance.edges[0].action == .CHANCE);

    const river_chance = turn_chance.edges[0].child.?;
    try std.testing.expect(river_chance.is_chance);
    try std.testing.expect(river_chance.edges.len == 1);
    try std.testing.expect(river_chance.edges[0].action == .CHANCE);
    // Showdown terminal: chance edge with no further child.
    try std.testing.expect(river_chance.edges[0].child == null);
}

test "buildTree: river check-check is terminal, not a chance node" {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const temp_allocator = da.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var root_state = GameState.init(.RIVER, true, 100.0, 1000.0, 1000.0);
    var arr = std.ArrayList(Edge).empty;
    defer arr.deinit(temp_allocator);
    try buildTree(&root_state, &arr, arena_allocator, temp_allocator, 8, 8);

    const root_node = arr.items[0].child.?;
    const p1_check = findFirst(root_node.edges, .CHECK).?;
    const p2_node = p1_check.child.?;
    const p2_check = findFirst(p2_node.edges, .CHECK).?;
    // Terminal: no child node.
    try std.testing.expect(p2_check.child == null);
}
