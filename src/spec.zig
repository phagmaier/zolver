// Spec file (ZON) used by `poker resolve`. Describes a flop spot plus the
// runout to re-solve on the turn or river:
//
//   .{
//       .board = "AhKsQd",
//       .pot   = 50,
//       .stack = 200,
//       .p1    = "JJ+, AKs",
//       .p2    = "@ranges/sb.txt",
//       .iters = 200,
//       .flop  = .{ .path = "x x" },
//       .turn  = .{ .card = "Th" },
//       .river = .{ .path = "x x", .card = "2s" }, // optional
//   }
//
// Path tokens (whitespace-separated): x=CHECK, c=CALL, f=FOLD, j=ALLIN,
// b<pct>=BET sized as <pct>% of pot. Sizes must come from gamestate.BETSIZES.

const std = @import("std");
const Allocator = std.mem.Allocator;

const card_mod = @import("card.zig");
const Card = card_mod.Card;
const gamestate_mod = @import("gamestate.zig");
const Action = gamestate_mod.Action;
const GameState = gamestate_mod.GameState;
const subgame = @import("subgame.zig");
const PathStep = subgame.PathStep;

pub const FlopSection = struct {
    path: []const u8,
};

pub const TurnSection = struct {
    card: []const u8,
};

pub const RiverSection = struct {
    path: []const u8,
    card: []const u8,
};

pub const OutputSection = struct {
    /// If set, writes the root-level per-hand strategy as CSV to this path
    /// (cwd-relative). Skipped when null.
    strategy_csv: ?[]const u8 = null,
    /// If true, runs `Subgame.exploitability()` after the resolve and prints
    /// the value in the summary. Adds a best-response pass — opt in.
    exploitability: bool = false,
};

pub const Spec = struct {
    board: []const u8,
    pot: f32,
    stack: f32,
    p1: []const u8,
    p2: []const u8,
    iters: u32 = 100,
    flop: FlopSection,
    turn: TurnSection,
    river: ?RiverSection = null,
    output: OutputSection = .{},
};

/// Parses a ZON Spec from an already-loaded, null-terminated source.
/// Caller must release with `freeSpec`.
pub fn parseSpec(allocator: Allocator, source: [:0]const u8) !Spec {
    return try std.zon.parse.fromSliceAlloc(Spec, allocator, source, null, .{});
}

/// Reads a ZON spec file from `path`. Caller must release with `freeSpec`.
pub fn loadSpec(allocator: Allocator, io: std.Io, path: []const u8) !Spec {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(raw);

    const source = try allocator.dupeZ(u8, raw);
    defer allocator.free(source);

    return try parseSpec(allocator, source);
}

pub fn freeSpec(allocator: Allocator, spec: Spec) void {
    std.zon.parse.free(allocator, spec);
}

pub const Token = struct {
    action: Action,
    bet_pct: f32 = 0,
};

pub const TokenError = error{
    UnknownActionToken,
    BadBetToken,
    EmptyToken,
};

pub const PathError = error{
    IllegalAction,
};

/// Splits the path string into action tokens. Caller owns the returned slice.
pub fn parsePathTokens(allocator: Allocator, path: []const u8) ![]Token {
    var list = std.ArrayList(Token).empty;
    errdefer list.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, path, " ,\t\r\n");
    while (it.next()) |raw| {
        const tok = try parseToken(raw);
        try list.append(allocator, tok);
    }
    return try list.toOwnedSlice(allocator);
}

fn parseToken(tok: []const u8) TokenError!Token {
    if (tok.len == 0) return error.EmptyToken;
    return switch (tok[0]) {
        'x', 'X' => if (tok.len == 1) Token{ .action = .CHECK } else error.UnknownActionToken,
        'c', 'C' => if (tok.len == 1) Token{ .action = .CALL } else error.UnknownActionToken,
        'f', 'F' => if (tok.len == 1) Token{ .action = .FOLD } else error.UnknownActionToken,
        'j', 'J' => if (tok.len == 1) Token{ .action = .ALLIN } else error.UnknownActionToken,
        'b', 'B' => blk: {
            if (tok.len < 2) break :blk error.BadBetToken;
            const pct_int = std.fmt.parseInt(u32, tok[1..], 10) catch break :blk error.BadBetToken;
            break :blk Token{
                .action = .BET,
                .bet_pct = @as(f32, @floatFromInt(pct_int)) / 100.0,
            };
        },
        else => error.UnknownActionToken,
    };
}

/// Evolves `initial` through each token to produce the PathStep sequence that
/// `subgame.findSeedByPath` expects. `PathStep.amount` matches `state.pot`
/// after the action — which is what `subgame.collectChanceSeedsRecursive`
/// stores on each seed.
pub fn buildPathSteps(allocator: Allocator, initial: GameState, tokens: []const Token) ![]PathStep {
    var steps = std.ArrayList(PathStep).empty;
    errdefer steps.deinit(allocator);

    var state = initial;
    for (tokens) |tok| {
        const next: GameState = switch (tok.action) {
            .CHECK => state.getCheckGameState() orelse return error.IllegalAction,
            .CALL => state.getCallGameState() orelse return error.IllegalAction,
            .FOLD => state.getFoldGameState() orelse return error.IllegalAction,
            .ALLIN => state.getAllInGameState() orelse return error.IllegalAction,
            .BET => state.getBetGameState(tok.bet_pct) orelse return error.IllegalAction,
            .CHANCE => return error.IllegalAction,
        };
        try steps.append(allocator, .{ .action = tok.action, .amount = next.pot });
        state = next;
    }
    return try steps.toOwnedSlice(allocator);
}

test "parsePathTokens recognizes every action shorthand" {
    const allocator = std.testing.allocator;
    const tokens = try parsePathTokens(allocator, "x c f j b50 b100");
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 6), tokens.len);
    try std.testing.expectEqual(Action.CHECK, tokens[0].action);
    try std.testing.expectEqual(Action.CALL, tokens[1].action);
    try std.testing.expectEqual(Action.FOLD, tokens[2].action);
    try std.testing.expectEqual(Action.ALLIN, tokens[3].action);
    try std.testing.expectEqual(Action.BET, tokens[4].action);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), tokens[4].bet_pct, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), tokens[5].bet_pct, 1e-6);
}

test "parsePathTokens rejects malformed tokens" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnknownActionToken, parsePathTokens(allocator, "q"));
    try std.testing.expectError(error.UnknownActionToken, parsePathTokens(allocator, "xx"));
    try std.testing.expectError(error.BadBetToken, parsePathTokens(allocator, "b"));
    try std.testing.expectError(error.BadBetToken, parsePathTokens(allocator, "babc"));
}

test "buildPathSteps mirrors PathSteps recorded by collectChanceSeeds" {
    const allocator = std.testing.allocator;

    const tokens = try parsePathTokens(allocator, "x x");
    defer allocator.free(tokens);
    const steps = try buildPathSteps(allocator, GameState.init(.FLOP, true, 50, 100, 100), tokens);
    defer allocator.free(steps);

    try std.testing.expectEqual(@as(usize, 2), steps.len);
    try std.testing.expectEqual(Action.CHECK, steps[0].action);
    try std.testing.expectApproxEqAbs(@as(f32, 50), steps[0].amount, 1e-3);
    try std.testing.expectEqual(Action.CHECK, steps[1].action);
    try std.testing.expectApproxEqAbs(@as(f32, 50), steps[1].amount, 1e-3);

    const bet_call_tokens = try parsePathTokens(allocator, "b50 c");
    defer allocator.free(bet_call_tokens);
    const bet_call = try buildPathSteps(allocator, GameState.init(.FLOP, true, 50, 100, 100), bet_call_tokens);
    defer allocator.free(bet_call);

    try std.testing.expectEqual(Action.BET, bet_call[0].action);
    try std.testing.expectApproxEqAbs(@as(f32, 75), bet_call[0].amount, 1e-3);
    try std.testing.expectEqual(Action.CALL, bet_call[1].action);
    try std.testing.expectApproxEqAbs(@as(f32, 100), bet_call[1].amount, 1e-3);
}

test "buildPathSteps errors when an action is illegal in the current state" {
    const allocator = std.testing.allocator;
    const tokens = try parsePathTokens(allocator, "c");
    defer allocator.free(tokens);
    // No outstanding bet → CALL is illegal at the flop root.
    try std.testing.expectError(error.IllegalAction, buildPathSteps(allocator, GameState.init(.FLOP, true, 50, 100, 100), tokens));
}

test "parseSpec round-trips a turn spec" {
    const allocator = std.testing.allocator;

    const zon: [:0]const u8 =
        \\.{
        \\    .board = "AhKsQd",
        \\    .pot = 50,
        \\    .stack = 200,
        \\    .p1 = "AA",
        \\    .p2 = "KK",
        \\    .iters = 5,
        \\    .flop = .{ .path = "x x" },
        \\    .turn = .{ .card = "Th" },
        \\}
    ;

    const spec = try parseSpec(allocator, zon);
    defer freeSpec(allocator, spec);

    try std.testing.expectEqualStrings("AhKsQd", spec.board);
    try std.testing.expectApproxEqAbs(@as(f32, 50), spec.pot, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 200), spec.stack, 1e-3);
    try std.testing.expectEqualStrings("AA", spec.p1);
    try std.testing.expectEqualStrings("KK", spec.p2);
    try std.testing.expectEqual(@as(u32, 5), spec.iters);
    try std.testing.expectEqualStrings("x x", spec.flop.path);
    try std.testing.expectEqualStrings("Th", spec.turn.card);
    try std.testing.expect(spec.river == null);
}

test "parseSpec round-trips a river spec" {
    const allocator = std.testing.allocator;

    const zon: [:0]const u8 =
        \\.{
        \\    .board = "AhKsQd",
        \\    .pot = 50,
        \\    .stack = 200,
        \\    .p1 = "AA",
        \\    .p2 = "KK",
        \\    .iters = 5,
        \\    .flop = .{ .path = "x x" },
        \\    .turn = .{ .card = "Th" },
        \\    .river = .{ .path = "b50 c", .card = "2s" },
        \\}
    ;

    const spec = try parseSpec(allocator, zon);
    defer freeSpec(allocator, spec);

    const r = spec.river orelse return error.TestExpectedRiver;
    try std.testing.expectEqualStrings("b50 c", r.path);
    try std.testing.expectEqualStrings("2s", r.card);
}

test "parseSpec defaults output to empty when omitted" {
    const allocator = std.testing.allocator;
    const zon: [:0]const u8 =
        \\.{
        \\    .board = "AhKsQd",
        \\    .pot = 50,
        \\    .stack = 200,
        \\    .p1 = "AA",
        \\    .p2 = "KK",
        \\    .flop = .{ .path = "x x" },
        \\    .turn = .{ .card = "Th" },
        \\}
    ;
    const spec = try parseSpec(allocator, zon);
    defer freeSpec(allocator, spec);

    try std.testing.expect(spec.output.strategy_csv == null);
    try std.testing.expectEqual(false, spec.output.exploitability);
}

test "parseSpec round-trips an output section" {
    const allocator = std.testing.allocator;
    const zon: [:0]const u8 =
        \\.{
        \\    .board = "AhKsQd",
        \\    .pot = 50,
        \\    .stack = 200,
        \\    .p1 = "AA",
        \\    .p2 = "KK",
        \\    .flop = .{ .path = "x x" },
        \\    .turn = .{ .card = "Th" },
        \\    .output = .{ .strategy_csv = "out.csv", .exploitability = true },
        \\}
    ;
    const spec = try parseSpec(allocator, zon);
    defer freeSpec(allocator, spec);

    try std.testing.expectEqualStrings("out.csv", spec.output.strategy_csv.?);
    try std.testing.expectEqual(true, spec.output.exploitability);
}
