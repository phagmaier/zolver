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
    child: ?*Node,

    pub fn init(arena: Allocator, state: *GameState) !Edge {
        return Edge{ .action = state.action, .amount = state.pot, .child = if (state.isTerm) null else try Node.create(arena) };
    }

    pub fn setChildren(self: *Edge, arena: Allocator, arr: *std.ArrayList(Edge), numCards: u16) !void {
        if (self.child) |child| {
            try child.finalize(arena, arr, numCards);
        }
    }
};

pub const Node = struct {
    regrets: []f32,
    strategy_sum: []f32,
    edges: []Edge,

    pub fn create(arena: Allocator) !*Node {
        var self = try arena.create(Node);
        self.regrets = &.{};
        self.strategy_sum = &.{};
        self.edges = &.{};
        return self;
    }

    pub fn finalize(self: *Node, arena: Allocator, arr: *std.ArrayList(Edge), numCards: u16) !void {
        const size = arr.items.len;

        // Allocate slices in Arena
        self.edges = try arena.alloc(Edge, size);
        @memcpy(self.edges, arr.items);

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

    const numCards = if (state.isp1) numCards1 else numCards2;
    try edge.setChildren(arena, &childArr, numCards);
    try arr.append(temp_allocator, edge);
}

fn count_and_check(arr: *std.ArrayList(Edge), maxPotSize: f32) void {
    var count: usize = 0;
    for (arr.items) |*edge| {
        count += _count_and_check(edge, maxPotSize);
    }
    std.debug.print("COUNT: {d}", .{count});
}

fn _count_and_check(edge: *Edge, maxPotSize: f32) usize {
    var count: usize = 1;
    std.debug.assert(edge.amount <= maxPotSize);
    if (edge.amount == maxPotSize) {
        std.debug.print("Got a max pot size: {d}\n", .{maxPotSize});
    }
    if (edge.child) |child| {
        for (child.edges) |*children| {
            count += _count_and_check(children, maxPotSize);
        }
    }
    return count;
}

test "Init count and confirm sizes" {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const temp_allocator = da.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    std.debug.print("Initializing Tree...\n", .{});

    var root_state = GameState.init(.FLOP, true, 100.0, 1000.0, 1000.0);
    const maxPotSize = root_state.pot + root_state.stack1 + root_state.stack2;
    var arr = std.ArrayList(Edge).empty;
    defer arr.deinit(temp_allocator);
    try buildTree(&root_state, &arr, arena_allocator, temp_allocator, 16);
    count_and_check(&arr, maxPotSize);
}
