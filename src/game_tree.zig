const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Player = enum(u8) {
    oop = 0,
    ip = 1,

    pub fn index(self: Player) usize {
        return @intFromEnum(self);
    }

    pub fn other(self: Player) Player {
        return switch (self) {
            .oop => .ip,
            .ip => .oop,
        };
    }
};

pub const Street = enum(u8) {
    flop = 0,
    turn = 1,
    river = 2,

    pub fn index(self: Street) usize {
        return @intFromEnum(self);
    }

    pub fn next(self: Street) ?Street {
        return switch (self) {
            .flop => .turn,
            .turn => .river,
            .river => null,
        };
    }
};

pub const NodeTag = enum(u2) {
    action = 0,
    chance = 1,
    terminal = 2,
};

pub const NodeRef = u32;

const ref_index_bits = 30;
const ref_index_limit: u32 = 1 << ref_index_bits;
const ref_index_mask: u32 = ref_index_limit - 1;

pub fn makeRef(tag: NodeTag, index: u32) !NodeRef {
    if (index >= ref_index_limit) return error.NodeIndexTooLarge;
    return (@as(u32, @intFromEnum(tag)) << ref_index_bits) | index;
}

pub fn refTag(ref: NodeRef) !NodeTag {
    return switch (ref >> ref_index_bits) {
        0 => .action,
        1 => .chance,
        2 => .terminal,
        else => error.InvalidNodeTag,
    };
}

pub fn refIndex(ref: NodeRef) u32 {
    return ref & ref_index_mask;
}

pub const TerminalKind = enum(u8) {
    fold = 0,
    showdown = 1,
};

pub const ActionNode = struct {
    player: u8,
    first_child_edge: u32,
    num_children: u8,
    base: u32,
};

pub const ChanceNode = struct {
    next_street: u8,
    child: NodeRef,
};

pub const TerminalNode = struct {
    kind: TerminalKind,
    who_folded: u8,
    pot: u32,
    /// Total postflop commitment of the folding player.
    /// Meaningless for showdown terminals (always 0).
    folder_committed: u32,
};

pub const Sizing = struct {
    numerator: u32,
    denominator: u32,

    pub fn init(numerator: u32, denominator: u32) Sizing {
        return .{
            .numerator = numerator,
            .denominator = denominator,
        };
    }

    fn validate(self: Sizing) !void {
        if (self.denominator == 0) return error.InvalidSizing;
    }

    fn lessThan(self: Sizing, other: Sizing) bool {
        return @as(u64, self.numerator) * other.denominator < @as(u64, other.numerator) * self.denominator;
    }

    fn roundOf(self: Sizing, amount: u32) !u32 {
        try self.validate();

        const product = @as(u64, self.numerator) * amount;
        const half = @as(u64, self.denominator) / 2;
        const rounded = (product + half) / self.denominator;
        if (rounded > std.math.maxInt(u32)) return error.AmountOverflow;
        return @intCast(rounded);
    }
};

const default_sizing_values = [_]Sizing{
    Sizing.init(25, 100),
    Sizing.init(50, 100),
};

pub const default_sizings: [3][]const Sizing = .{
    default_sizing_values[0..],
    default_sizing_values[0..],
    default_sizing_values[0..],
};

pub const default_raise_cap: [3]?u8 = .{ 1, 1, 1 };

pub const BuildConfig = struct {
    initial_pot: u32,
    effective_stack: u32,
    min_bet: u32,
    sizings: [3][]const Sizing,
    raise_cap: [3]?u8,
    range_sizes: [2]u32,

    pub fn default(initial_pot: u32, effective_stack: u32, min_bet: u32, range_sizes: [2]u32) BuildConfig {
        return .{
            .initial_pot = initial_pot,
            .effective_stack = effective_stack,
            .min_bet = min_bet,
            .sizings = default_sizings,
            .raise_cap = default_raise_cap,
            .range_sizes = range_sizes,
        };
    }

    fn validate(self: BuildConfig) !void {
        if (self.effective_stack == 0) return error.InvalidEffectiveStack;
        if (self.min_bet == 0) return error.InvalidMinBet;
        if (self.range_sizes[0] == 0 or self.range_sizes[1] == 0) return error.InvalidRangeSize;

        for (self.sizings) |street_sizings| {
            var previous: ?Sizing = null;
            for (street_sizings) |sizing| {
                try sizing.validate();
                if (previous) |prev| {
                    if (!prev.lessThan(sizing)) return error.SizingsNotAscending;
                }
                previous = sizing;
            }
        }
    }
};

const BuildState = struct {
    street: Street,
    to_act: Player,
    committed: [2]u32,
    last_increment: u32,
    raises_this_street: u8,

    fn opening() BuildState {
        return .{
            .street = .flop,
            .to_act = .oop,
            .committed = .{ 0, 0 },
            .last_increment = 0,
            .raises_this_street = 0,
        };
    }

    fn pot(self: BuildState, config: BuildConfig) !u32 {
        const value = @as(u64, config.initial_pot) + self.committed[0] + self.committed[1];
        if (value > std.math.maxInt(u32)) return error.PotOverflow;
        return @intCast(value);
    }

    fn toCall(self: BuildState) !u32 {
        const me = self.to_act.index();
        const opp = self.to_act.other().index();
        if (self.committed[opp] < self.committed[me]) return error.InvalidCommitmentState;
        return self.committed[opp] - self.committed[me];
    }

    fn myRemaining(self: BuildState, config: BuildConfig) !u32 {
        const me = self.to_act.index();
        if (self.committed[me] > config.effective_stack) return error.InvalidCommitmentState;
        return config.effective_stack - self.committed[me];
    }
};

pub const ActionKind = enum {
    check,
    fold,
    call,
    bet,
    raise,
    all_in,
};

pub const Action = struct {
    kind: ActionKind,
    amount: u32 = 0,
};

const ActionBuffer = struct {
    items: [8]Action = undefined,
    len: u8 = 0,

    fn append(self: *ActionBuffer, action: Action) !void {
        if (self.len >= self.items.len) return error.TooManyActions;
        self.items[self.len] = action;
        self.len += 1;
    }

    fn slice(self: *const ActionBuffer) []const Action {
        return self.items[0..self.len];
    }

    fn containsAmount(self: *const ActionBuffer, kind: ActionKind, amount: u32) bool {
        for (self.slice()) |action| {
            if (action.kind == kind and action.amount == amount) return true;
        }
        return false;
    }
};

fn enumerateLegalActions(config: BuildConfig, state: BuildState) !ActionBuffer {
    const to_call = try state.toCall();
    const my_remaining = try state.myRemaining(config);
    if (my_remaining == 0) return error.InvalidActionNodeState;

    const street_sizings = config.sizings[state.street.index()];
    const pot = try state.pot(config);

    var actions: ActionBuffer = .{};
    if (to_call == 0) {
        try actions.append(.{ .kind = .check });

        for (street_sizings) |sizing| {
            const added = try sizing.roundOf(pot);
            const total_committed = @as(u64, state.committed[state.to_act.index()]) + added;
            if (added >= config.min_bet and
                total_committed < config.effective_stack and
                !actions.containsAmount(.bet, added))
            {
                try actions.append(.{ .kind = .bet, .amount = added });
            }
        }

        try actions.append(.{ .kind = .all_in });
        return actions;
    }

    try actions.append(.{ .kind = .fold });
    try actions.append(.{ .kind = .call });

    if (my_remaining > to_call) {
        const cap_allows_raise = if (config.raise_cap[state.street.index()]) |cap|
            state.raises_this_street < cap
        else
            true;

        if (cap_allows_raise) {
            const pot_after_call = checkedAddU32(pot, to_call) catch return error.PotOverflow;
            for (street_sizings) |sizing| {
                const raise_increment = try sizing.roundOf(pot_after_call);
                const total_committed = @as(u64, state.committed[state.to_act.index()]) + to_call + raise_increment;
                if (raise_increment >= state.last_increment and
                    total_committed < config.effective_stack and
                    !actions.containsAmount(.raise, raise_increment))
                {
                    try actions.append(.{ .kind = .raise, .amount = raise_increment });
                }
            }
        }

        try actions.append(.{ .kind = .all_in });
    }

    return actions;
}

pub const Tree = struct {
    allocator: Allocator,
    action_nodes: std.ArrayList(ActionNode),
    chance_nodes: std.ArrayList(ChanceNode),
    terminal_nodes: std.ArrayList(TerminalNode),
    edges: std.ArrayList(NodeRef),
    root: NodeRef,
    slots_per_runout: [3]u64,
    initial_pot: u32,

    pub fn init(allocator: Allocator, initial_pot: u32) Tree {
        return .{
            .allocator = allocator,
            .action_nodes = .empty,
            .chance_nodes = .empty,
            .terminal_nodes = .empty,
            .edges = .empty,
            .root = 0,
            .slots_per_runout = .{ 0, 0, 0 },
            .initial_pot = initial_pot,
        };
    }

    pub fn deinit(self: *Tree) void {
        self.action_nodes.deinit(self.allocator);
        self.chance_nodes.deinit(self.allocator);
        self.terminal_nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn validate(self: *const Tree, allocator: Allocator, config: BuildConfig) !void {
        try config.validate();
        if (try refTag(self.root) != .action) return error.RootIsNotAction;

        const visited_actions = try allocator.alloc(bool, self.action_nodes.items.len);
        defer allocator.free(visited_actions);
        const visited_chances = try allocator.alloc(bool, self.chance_nodes.items.len);
        defer allocator.free(visited_chances);
        const visited_terminals = try allocator.alloc(bool, self.terminal_nodes.items.len);
        defer allocator.free(visited_terminals);
        @memset(visited_actions, false);
        @memset(visited_chances, false);
        @memset(visited_terminals, false);

        var ctx = ValidationContext{
            .allocator = allocator,
            .config = config,
            .tree = self,
            .visited_actions = visited_actions,
            .visited_chances = visited_chances,
            .visited_terminals = visited_terminals,
            .slot_sums = .{ 0, 0, 0 },
        };

        try ctx.visitAction(self.root, BuildState.opening());

        for (visited_actions) |visited| {
            if (!visited) return error.UnreachableActionNode;
        }
        for (visited_chances) |visited| {
            if (!visited) return error.UnreachableChanceNode;
        }
        for (visited_terminals) |visited| {
            if (!visited) return error.UnreachableTerminalNode;
        }
        if (!std.mem.eql(u64, &ctx.slot_sums, &self.slots_per_runout)) return error.SlotCountMismatch;
    }

    pub fn estimateStorageBytes(self: *const Tree, runout_counts: [3]u64) !u64 {
        var total: u64 = 0;
        for (self.slots_per_runout, 0..) |slots, street_idx| {
            const runout_slots = try std.math.mul(u64, slots, runout_counts[street_idx]);
            const bytes = try std.math.mul(u64, runout_slots, 6);
            total = try std.math.add(u64, total, bytes);
        }
        return total;
    }
};

/// What a `walkActionNodes` visitor receives at each action node.
pub const ActionNodeVisit = struct {
    ref: NodeRef,
    street: Street,
    player: Player,
    /// Legal actions at this node, in the same order as the node's child edges.
    actions: []const Action,
    /// Actions taken from the root to reach this node (betting actions only;
    /// street transitions are implicit). The acting node's own street is in
    /// `street`.
    path: []const Action,
};

const path_max = 64;

/// Pre-order walk over every action node in the tree, re-deriving betting state
/// so the caller learns each node's street, acting player, and labeled legal
/// actions plus the action path from the root. This mirrors the build and
/// validation walks — the labels are recomputed because they are not stored on
/// the nodes. `ctx` must expose `pub fn visitActionNode(self, ActionNodeVisit) !void`.
pub fn walkActionNodes(tree: *const Tree, config: BuildConfig, ctx: anytype) !void {
    var path: [path_max]Action = undefined;
    try walkAction(tree, config, tree.root, BuildState.opening(), &path, 0, ctx);
}

fn walkAction(
    tree: *const Tree,
    config: BuildConfig,
    ref: NodeRef,
    state: BuildState,
    path: *[path_max]Action,
    path_len: usize,
    ctx: anytype,
) anyerror!void {
    const node = tree.action_nodes.items[refIndex(ref)];
    const actions = try enumerateLegalActions(config, state);

    try ctx.visitActionNode(.{
        .ref = ref,
        .street = state.street,
        .player = @enumFromInt(node.player),
        .actions = actions.slice(),
        .path = path[0..path_len],
    });

    for (actions.slice(), 0..) |action, i| {
        const child = tree.edges.items[node.first_child_edge + i];
        if (path_len < path.len) path[path_len] = action;
        try walkActionResult(tree, config, child, state, action, path, path_len + 1, ctx);
    }
}

fn walkActionResult(
    tree: *const Tree,
    config: BuildConfig,
    ref: NodeRef,
    state: BuildState,
    action: Action,
    path: *[path_max]Action,
    path_len: usize,
    ctx: anytype,
) anyerror!void {
    const me = state.to_act.index();
    const opp = state.to_act.other().index();
    const to_call = try state.toCall();

    switch (action.kind) {
        .check => {
            if (state.to_act == .oop) {
                var next = state;
                next.to_act = .ip;
                return walkAction(tree, config, ref, next, path, path_len, ctx);
            }
            return walkCloseRound(tree, config, ref, state.committed, state.street, path, path_len, ctx);
        },
        .fold => return, // terminal node, nothing to visit
        .call => {
            var committed = state.committed;
            committed[me] = try checkedAddU32(committed[me], to_call);
            return walkCloseRound(tree, config, ref, committed, state.street, path, path_len, ctx);
        },
        .bet => {
            var next = state;
            next.committed[me] = try checkedAddU32(next.committed[me], action.amount);
            next.last_increment = action.amount;
            next.to_act = state.to_act.other();
            return walkAction(tree, config, ref, next, path, path_len, ctx);
        },
        .raise => {
            var next = state;
            next.committed[me] = try checkedAddU32(next.committed[me], try checkedAddU32(to_call, action.amount));
            next.last_increment = action.amount;
            next.raises_this_street = try checkedAddU8(next.raises_this_street, 1);
            next.to_act = state.to_act.other();
            return walkAction(tree, config, ref, next, path, path_len, ctx);
        },
        .all_in => {
            var next = state;
            next.committed[me] = config.effective_stack;
            next.last_increment = config.effective_stack - state.committed[opp];
            next.to_act = state.to_act.other();
            return walkAction(tree, config, ref, next, path, path_len, ctx);
        },
    }
}

fn walkCloseRound(
    tree: *const Tree,
    config: BuildConfig,
    ref: NodeRef,
    committed: [2]u32,
    street: Street,
    path: *[path_max]Action,
    path_len: usize,
    ctx: anytype,
) anyerror!void {
    if (street == .river or (committed[0] == config.effective_stack and committed[1] == config.effective_stack)) {
        return; // showdown terminal
    }
    const chance = tree.chance_nodes.items[refIndex(ref)];
    const next_street = street.next().?;
    return walkAction(tree, config, chance.child, openState(next_street, committed), path, path_len, ctx);
}

pub fn buildGameTree(allocator: Allocator, config: BuildConfig) !Tree {
    try config.validate();

    var builder = Builder{
        .allocator = allocator,
        .config = config,
        .tree = Tree.init(allocator, config.initial_pot),
        .next_slot = .{ 0, 0, 0 },
    };
    errdefer builder.tree.deinit();

    builder.tree.root = try builder.build(BuildState.opening());
    builder.tree.slots_per_runout = builder.next_slot;
    try builder.tree.validate(allocator, config);
    return builder.tree;
}

const Builder = struct {
    allocator: Allocator,
    config: BuildConfig,
    tree: Tree,
    next_slot: [3]u64,

    fn build(self: *Builder, state: BuildState) anyerror!NodeRef {
        const actions = try enumerateLegalActions(self.config, state);

        var child_refs: [8]NodeRef = undefined;
        for (actions.slice(), 0..) |action, i| {
            child_refs[i] = try self.resolve(state, action);
        }

        const first_child_edge = try u32Index(self.tree.edges.items.len);
        try self.tree.edges.appendSlice(self.allocator, child_refs[0..actions.len]);

        const node_index = try u32Index(self.tree.action_nodes.items.len);
        const street_idx = state.street.index();
        const base: u32 = std.math.cast(u32, self.next_slot[street_idx]) orelse return error.BaseOverflow;

        try self.tree.action_nodes.append(self.allocator, .{
            .player = @intFromEnum(state.to_act),
            .first_child_edge = first_child_edge,
            .num_children = actions.len,
            .base = base,
        });

        const footprint = @as(u64, self.config.range_sizes[state.to_act.index()]) * actions.len;
        self.next_slot[street_idx] = try std.math.add(u64, self.next_slot[street_idx], footprint);

        return makeRef(.action, node_index);
    }

    fn resolve(self: *Builder, state: BuildState, action: Action) anyerror!NodeRef {
        const me = state.to_act.index();
        const opp = state.to_act.other().index();
        const to_call = try state.toCall();
        const pot = try state.pot(self.config);

        switch (action.kind) {
            .check => {
                if (state.to_act == .oop) {
                    var next = state;
                    next.to_act = .ip;
                    return self.build(next);
                }
                return self.closeRound(state.committed, state.street, pot);
            },
            .fold => return self.appendTerminal(.{
                .kind = .fold,
                .who_folded = @intFromEnum(state.to_act),
                .pot = pot,
                .folder_committed = state.committed[me],
            }),
            .call => {
                var committed = state.committed;
                committed[me] = try checkedAddU32(committed[me], to_call);
                return self.closeRound(committed, state.street, try checkedAddU32(pot, to_call));
            },
            .bet => {
                var next = state;
                next.committed[me] = try checkedAddU32(next.committed[me], action.amount);
                next.last_increment = action.amount;
                next.to_act = state.to_act.other();
                return self.build(next);
            },
            .raise => {
                var next = state;
                next.committed[me] = try checkedAddU32(next.committed[me], try checkedAddU32(to_call, action.amount));
                next.last_increment = action.amount;
                next.raises_this_street = try checkedAddU8(next.raises_this_street, 1);
                next.to_act = state.to_act.other();
                return self.build(next);
            },
            .all_in => {
                var next = state;
                next.committed[me] = self.config.effective_stack;
                next.last_increment = self.config.effective_stack - state.committed[opp];
                next.to_act = state.to_act.other();
                return self.build(next);
            },
        }
    }

    fn closeRound(self: *Builder, committed: [2]u32, street: Street, pot: u32) anyerror!NodeRef {
        if (street == .river or (committed[0] == self.config.effective_stack and committed[1] == self.config.effective_stack)) {
            return self.appendTerminal(.{
                .kind = .showdown,
                .who_folded = 0,
                .pot = pot,
                .folder_committed = 0,
            });
        }

        const next_street = street.next().?;
        const child = try self.build(openState(next_street, committed));
        return self.appendChance(.{
            .next_street = @intFromEnum(next_street),
            .child = child,
        });
    }

    fn appendTerminal(self: *Builder, node: TerminalNode) anyerror!NodeRef {
        const index = try u32Index(self.tree.terminal_nodes.items.len);
        try self.tree.terminal_nodes.append(self.allocator, node);
        return makeRef(.terminal, index);
    }

    fn appendChance(self: *Builder, node: ChanceNode) anyerror!NodeRef {
        const index = try u32Index(self.tree.chance_nodes.items.len);
        try self.tree.chance_nodes.append(self.allocator, node);
        return makeRef(.chance, index);
    }
};

const ValidationContext = struct {
    allocator: Allocator,
    config: BuildConfig,
    tree: *const Tree,
    visited_actions: []bool,
    visited_chances: []bool,
    visited_terminals: []bool,
    slot_sums: [3]u64,

    fn visitAction(self: *ValidationContext, ref: NodeRef, state: BuildState) anyerror!void {
        if (try refTag(ref) != .action) return error.ExpectedActionRef;
        const idx = try self.markAction(ref);
        const node = self.tree.action_nodes.items[idx];
        if (node.player != @intFromEnum(state.to_act)) return error.ActionPlayerMismatch;

        const actions = try enumerateLegalActions(self.config, state);
        if (node.num_children != actions.len) return error.ActionChildCountMismatch;

        const first = node.first_child_edge;
        const end = @as(u64, first) + node.num_children;
        if (end > self.tree.edges.items.len) return error.EdgeBlockOutOfRange;

        const footprint = @as(u64, self.config.range_sizes[state.to_act.index()]) * node.num_children;
        self.slot_sums[state.street.index()] = try std.math.add(u64, self.slot_sums[state.street.index()], footprint);

        for (actions.slice(), 0..) |action, action_idx| {
            const child = self.tree.edges.items[first + action_idx];
            try self.visitActionResult(child, state, action);
        }
    }

    fn visitActionResult(self: *ValidationContext, ref: NodeRef, state: BuildState, action: Action) anyerror!void {
        const me = state.to_act.index();
        const opp = state.to_act.other().index();
        const to_call = try state.toCall();
        const pot = try state.pot(self.config);

        switch (action.kind) {
            .check => {
                if (state.to_act == .oop) {
                    var next = state;
                    next.to_act = .ip;
                    return self.visitAction(ref, next);
                }
                return self.visitCloseRound(ref, state.committed, state.street, pot);
            },
            .fold => {
                const terminal = try self.visitTerminal(ref);
                if (terminal.kind != .fold) return error.TerminalKindMismatch;
                if (terminal.who_folded != @intFromEnum(state.to_act)) return error.TerminalFoldedPlayerMismatch;
                if (terminal.pot != pot) return error.TerminalPotMismatch;
                if (terminal.folder_committed != state.committed[me]) return error.TerminalFolderCommittedMismatch;
            },
            .call => {
                var committed = state.committed;
                committed[me] = try checkedAddU32(committed[me], to_call);
                return self.visitCloseRound(ref, committed, state.street, try checkedAddU32(pot, to_call));
            },
            .bet => {
                var next = state;
                next.committed[me] = try checkedAddU32(next.committed[me], action.amount);
                next.last_increment = action.amount;
                next.to_act = state.to_act.other();
                return self.visitAction(ref, next);
            },
            .raise => {
                var next = state;
                next.committed[me] = try checkedAddU32(next.committed[me], try checkedAddU32(to_call, action.amount));
                next.last_increment = action.amount;
                next.raises_this_street = try checkedAddU8(next.raises_this_street, 1);
                next.to_act = state.to_act.other();
                return self.visitAction(ref, next);
            },
            .all_in => {
                var next = state;
                next.committed[me] = self.config.effective_stack;
                next.last_increment = self.config.effective_stack - state.committed[opp];
                next.to_act = state.to_act.other();
                return self.visitAction(ref, next);
            },
        }
    }

    fn visitCloseRound(self: *ValidationContext, ref: NodeRef, committed: [2]u32, street: Street, pot: u32) anyerror!void {
        if (street == .river or (committed[0] == self.config.effective_stack and committed[1] == self.config.effective_stack)) {
            const terminal = try self.visitTerminal(ref);
            if (terminal.kind != .showdown) return error.TerminalKindMismatch;
            if (terminal.pot != pot) return error.TerminalPotMismatch;
            return;
        }

        if (try refTag(ref) != .chance) return error.ExpectedChanceRef;
        const chance_idx = try self.markChance(ref);
        const chance = self.tree.chance_nodes.items[chance_idx];
        const next_street = street.next().?;
        if (chance.next_street != @intFromEnum(next_street)) return error.ChanceStreetMismatch;
        if (try refTag(chance.child) != .action) return error.ChanceChildIsNotAction;
        try self.visitAction(chance.child, openState(next_street, committed));
    }

    fn visitTerminal(self: *ValidationContext, ref: NodeRef) !TerminalNode {
        if (try refTag(ref) != .terminal) return error.ExpectedTerminalRef;
        const idx = try self.markTerminal(ref);
        return self.tree.terminal_nodes.items[idx];
    }

    fn markAction(self: *ValidationContext, ref: NodeRef) !usize {
        const idx: usize = @intCast(refIndex(ref));
        if (idx >= self.visited_actions.len) return error.ActionRefOutOfRange;
        if (self.visited_actions[idx]) return error.SharedOrCyclicActionNode;
        self.visited_actions[idx] = true;
        return idx;
    }

    fn markChance(self: *ValidationContext, ref: NodeRef) !usize {
        const idx: usize = @intCast(refIndex(ref));
        if (idx >= self.visited_chances.len) return error.ChanceRefOutOfRange;
        if (self.visited_chances[idx]) return error.SharedOrCyclicChanceNode;
        self.visited_chances[idx] = true;
        return idx;
    }

    fn markTerminal(self: *ValidationContext, ref: NodeRef) !usize {
        const idx: usize = @intCast(refIndex(ref));
        if (idx >= self.visited_terminals.len) return error.TerminalRefOutOfRange;
        if (self.visited_terminals[idx]) return error.SharedOrCyclicTerminalNode;
        self.visited_terminals[idx] = true;
        return idx;
    }
};

fn openState(street: Street, committed: [2]u32) BuildState {
    return .{
        .street = street,
        .to_act = .oop,
        .committed = committed,
        .last_increment = 0,
        .raises_this_street = 0,
    };
}

fn checkedAddU32(a: u32, b: u32) !u32 {
    return std.math.add(u32, a, b) catch error.AmountOverflow;
}

fn checkedAddU8(a: u8, b: u8) !u8 {
    return std.math.add(u8, a, b) catch error.AmountOverflow;
}

fn u32Index(index: usize) !u32 {
    if (index >= ref_index_limit) return error.NodeIndexTooLarge;
    return @intCast(index);
}

test "node reference encoding uses top two bits" {
    const action_ref = try makeRef(.action, 123);
    try std.testing.expectEqual(NodeTag.action, try refTag(action_ref));
    try std.testing.expectEqual(@as(u32, 123), refIndex(action_ref));

    const chance_ref = try makeRef(.chance, 7);
    try std.testing.expectEqual(NodeTag.chance, try refTag(chance_ref));
    try std.testing.expectEqual(@as(u32, 7), refIndex(chance_ref));

    const terminal_ref = try makeRef(.terminal, ref_index_limit - 1);
    try std.testing.expectEqual(NodeTag.terminal, try refTag(terminal_ref));
    try std.testing.expectEqual(ref_index_limit - 1, refIndex(terminal_ref));

    try std.testing.expectError(error.NodeIndexTooLarge, makeRef(.action, ref_index_limit));
    try std.testing.expectError(error.InvalidNodeTag, refTag(@as(u32, 3) << ref_index_bits));
}

test "default opening actions are check, quarter pot, half pot, all-in" {
    const config = BuildConfig.default(100, 1000, 1, .{ 10, 10 });
    const actions = try enumerateLegalActions(config, BuildState.opening());

    try std.testing.expectEqual(@as(u8, 4), actions.len);
    try std.testing.expectEqual(ActionKind.check, actions.items[0].kind);
    try std.testing.expectEqual(ActionKind.bet, actions.items[1].kind);
    try std.testing.expectEqual(@as(u32, 25), actions.items[1].amount);
    try std.testing.expectEqual(ActionKind.bet, actions.items[2].kind);
    try std.testing.expectEqual(@as(u32, 50), actions.items[2].amount);
    try std.testing.expectEqual(ActionKind.all_in, actions.items[3].kind);
}

test "rounded duplicate sizings are kept once" {
    const values = [_]Sizing{
        Sizing.init(25, 100),
        Sizing.init(26, 100),
    };
    const config = BuildConfig{
        .initial_pot = 2,
        .effective_stack = 100,
        .min_bet = 1,
        .sizings = .{ values[0..], values[0..], values[0..] },
        .raise_cap = default_raise_cap,
        .range_sizes = .{ 10, 10 },
    };

    const actions = try enumerateLegalActions(config, BuildState.opening());
    try std.testing.expectEqual(@as(u8, 3), actions.len);
    try std.testing.expectEqual(ActionKind.bet, actions.items[1].kind);
    try std.testing.expectEqual(@as(u32, 1), actions.items[1].amount);
    try std.testing.expectEqual(ActionKind.all_in, actions.items[2].kind);
}

test "facing all-in allows only fold or call" {
    const config = BuildConfig.default(100, 1000, 1, .{ 10, 10 });
    const state = BuildState{
        .street = .flop,
        .to_act = .oop,
        .committed = .{ 0, 1000 },
        .last_increment = 1000,
        .raises_this_street = 0,
    };

    const actions = try enumerateLegalActions(config, state);
    try std.testing.expectEqual(@as(u8, 2), actions.len);
    try std.testing.expectEqual(ActionKind.fold, actions.items[0].kind);
    try std.testing.expectEqual(ActionKind.call, actions.items[1].kind);
}

test "raise cap removes percentage reraises but leaves all-in" {
    const config = BuildConfig.default(100, 1000, 1, .{ 10, 10 });
    const state = BuildState{
        .street = .flop,
        .to_act = .ip,
        .committed = .{ 100, 0 },
        .last_increment = 100,
        .raises_this_street = 1,
    };

    const actions = try enumerateLegalActions(config, state);
    try std.testing.expectEqual(@as(u8, 3), actions.len);
    try std.testing.expectEqual(ActionKind.fold, actions.items[0].kind);
    try std.testing.expectEqual(ActionKind.call, actions.items[1].kind);
    try std.testing.expectEqual(ActionKind.all_in, actions.items[2].kind);
}

test "build default game tree and estimate raw runout storage" {
    const config = BuildConfig.default(20, 60, 1, .{ 3, 5 });
    var tree = try buildGameTree(std.testing.allocator, config);
    defer tree.deinit();

    try std.testing.expectEqual(NodeTag.action, try refTag(tree.root));
    try std.testing.expect(tree.action_nodes.items.len > 0);
    try std.testing.expect(tree.terminal_nodes.items.len > 0);
    try std.testing.expect(tree.slots_per_runout[0] > 0);
    try std.testing.expect(tree.slots_per_runout[1] > 0);
    try std.testing.expect(tree.slots_per_runout[2] > 0);

    const bytes = try tree.estimateStorageBytes(.{ 1, 49, 2352 });
    try std.testing.expect(bytes > 0);
}

test "walkActionNodes visits every action node exactly once" {
    const config = BuildConfig.default(20, 60, 1, .{ 3, 5 });
    var tree = try buildGameTree(std.testing.allocator, config);
    defer tree.deinit();

    const Counter = struct {
        visited: []bool,
        count: usize = 0,
        max_path: usize = 0,
        saw_each_street: [3]bool = .{ false, false, false },

        pub fn visitActionNode(self: *@This(), v: ActionNodeVisit) !void {
            try std.testing.expectEqual(NodeTag.action, try refTag(v.ref));
            const idx: usize = @intCast(refIndex(v.ref));
            try std.testing.expect(!self.visited[idx]); // no node visited twice
            self.visited[idx] = true;
            self.count += 1;
            self.max_path = @max(self.max_path, v.path.len);
            self.saw_each_street[v.street.index()] = true;
            // The acting player matches the stored node.
        }
    };

    const visited = try std.testing.allocator.alloc(bool, tree.action_nodes.items.len);
    defer std.testing.allocator.free(visited);
    @memset(visited, false);

    var counter = Counter{ .visited = visited };
    try walkActionNodes(&tree, config, &counter);

    // Every action node was reached, exactly once.
    try std.testing.expectEqual(tree.action_nodes.items.len, counter.count);
    for (visited) |seen| try std.testing.expect(seen);
    // All three streets appear and the path stays within bounds.
    try std.testing.expect(counter.saw_each_street[0] and counter.saw_each_street[1] and counter.saw_each_street[2]);
    try std.testing.expect(counter.max_path < path_max);
}

test "called all-in before river resolves directly to showdown" {
    const config = BuildConfig.default(100, 10, 1, .{ 2, 2 });
    var tree = try buildGameTree(std.testing.allocator, config);
    defer tree.deinit();

    const root_idx: usize = @intCast(refIndex(tree.root));
    const root = tree.action_nodes.items[root_idx];
    try std.testing.expectEqual(@as(u8, 2), root.num_children);

    const all_in_ref = tree.edges.items[root.first_child_edge + 1];
    try std.testing.expectEqual(NodeTag.action, try refTag(all_in_ref));
    const facing_all_in = tree.action_nodes.items[@intCast(refIndex(all_in_ref))];
    try std.testing.expectEqual(@as(u8, 2), facing_all_in.num_children);

    const call_ref = tree.edges.items[facing_all_in.first_child_edge + 1];
    try std.testing.expectEqual(NodeTag.terminal, try refTag(call_ref));
    const terminal = tree.terminal_nodes.items[@intCast(refIndex(call_ref))];
    try std.testing.expectEqual(TerminalKind.showdown, terminal.kind);
    try std.testing.expectEqual(@as(u32, 120), terminal.pot);
}
