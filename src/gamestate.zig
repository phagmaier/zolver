const std = @import("std");

pub const Action = enum { FOLD, CHECK, CALL, BET, ALLIN, CHANCE };
pub const Street = enum { FLOP, TURN, RIVER };

pub const BETSIZES: [2]f32 = .{ 0.5, 1.0 };
const MAXNUMBETS = 2; // "No reraising the reraise"

pub const GameState = struct {
    street: Street,
    action: Action,
    bet: f32, // Total wager of the aggressor
    isp1: bool,
    pot: f32,
    stack1: f32,
    stack2: f32,
    isTerm: bool,
    numbets: u8,
    current_bet_p1: f32,
    current_bet_p2: f32,
    is_chance: bool,

    pub fn init(street: Street, isp1: bool, pot: f32, stack1: f32, stack2: f32) GameState {
        return .{
            .street = street,
            .action = .CHECK,
            .bet = 0,
            .isp1 = isp1,
            .pot = pot,
            .stack1 = stack1,
            .stack2 = stack2,
            .isTerm = false,
            .numbets = 0,
            .current_bet_p1 = 0,
            .current_bet_p2 = 0,
            .is_chance = false,
        };
    }

    pub fn nextStreet(self: *GameState) void {
        if (self.street == .FLOP) self.street = .TURN else self.street = .RIVER;
        self.current_bet_p1 = 0;
        self.current_bet_p2 = 0;
        self.numbets = 0;
        self.bet = 0;
        self.isp1 = true;
    }

    pub fn getFoldGameState(self: *const GameState) ?GameState {
        if (self.is_chance) return null;
        if (self.numbets == 0) return null;

        var new = self.*;
        new.isp1 = !self.isp1;
        new.action = .FOLD;
        new.bet = 0;
        new.isTerm = true;
        new.numbets = 0;
        return new;
    }

    pub fn getCheckGameState(self: *const GameState) ?GameState {
        if (self.is_chance) return null;
        if (self.numbets > 0) return null;

        var new = self.*;
        new.action = .CHECK;
        new.bet = 0;

        if (self.isp1) {
            new.isp1 = false;
        } else {
            if (self.street == .RIVER) {
                new.isTerm = true;
            } else {
                // Defer the street advance to applyChance() so the tree gets a chance node.
                new.is_chance = true;
            }
        }
        return new;
    }

    pub fn getBetGameState(self: *const GameState, pct_pot: f32) ?GameState {
        if (self.is_chance) return null;
        // 1. Check Max Bets rule
        if (self.numbets >= MAXNUMBETS or self.action == .ALLIN) return null;

        const my_current = if (self.isp1) self.current_bet_p1 else self.current_bet_p2;
        const opp_current = if (self.isp1) self.current_bet_p2 else self.current_bet_p1;
        const my_stack = if (self.isp1) self.stack1 else self.stack2;
        const opp_stack = if (self.isp1) self.stack2 else self.stack1;

        // 2. Calculate Raise
        // "Pot Size Raise" = Current Pot + Cost to Call
        const raise_amount = (self.pot + (opp_current - my_current)) * pct_pot;
        const total_wager = opp_current + raise_amount;
        const chips_to_add = total_wager - my_current;

        // Reject when either side would be all-in (use getAllInGameState instead).
        // Opp's cost to call is raise_amount, not chips_to_add.
        if (chips_to_add >= my_stack or raise_amount >= opp_stack) return null;

        var new = self.*;
        new.isp1 = !self.isp1;
        new.action = .BET;
        new.numbets += 1;
        new.bet = total_wager;

        new.pot += chips_to_add;
        if (self.isp1) {
            new.stack1 -= chips_to_add;
            new.current_bet_p1 = total_wager;
        } else {
            new.stack2 -= chips_to_add;
            new.current_bet_p2 = total_wager;
        }

        return new;
    }

    pub fn getAllInGameState(self: *const GameState) ?GameState {
        if (self.is_chance) return null;
        if (self.action == .ALLIN) return null;

        var new = self.*;

        const my_stack = if (self.isp1) self.stack1 else self.stack2;
        const opp_stack = if (self.isp1) self.stack2 else self.stack1;
        const my_current = if (self.isp1) self.current_bet_p1 else self.current_bet_p2;
        const opp_current = if (self.isp1) self.current_bet_p2 else self.current_bet_p1;

        // Effective stack compares total potential contributions, not remaining stacks —
        // chips already committed this street count toward each side's cap.
        const effective_total = @min(my_current + my_stack, opp_current + opp_stack);
        const effective_add = effective_total - my_current;
        const total_wager = effective_total;

        new.isp1 = !self.isp1;
        new.action = .ALLIN;
        new.numbets += 1;
        new.bet = total_wager;

        new.pot += effective_add;
        if (self.isp1) {
            new.stack1 -= effective_add;
            new.current_bet_p1 = total_wager;
        } else {
            new.stack2 -= effective_add;
            new.current_bet_p2 = total_wager;
        }

        return new;
    }

    pub fn getCallGameState(self: *const GameState) ?GameState {
        if (self.is_chance) return null;
        if (self.numbets == 0) return null;

        var new = self.*;
        const my_current = if (self.isp1) self.current_bet_p1 else self.current_bet_p2;
        const opp_current = if (self.isp1) self.current_bet_p2 else self.current_bet_p1;
        const my_stack = if (self.isp1) self.stack1 else self.stack2;

        const cost_to_call = opp_current - my_current;

        std.debug.assert(cost_to_call <= my_stack);
        new.action = .CALL;

        new.pot += cost_to_call;
        new.bet = opp_current;

        if (self.isp1) {
            new.stack1 -= cost_to_call;
            new.current_bet_p1 += cost_to_call;
        } else {
            new.stack2 -= cost_to_call;
            new.current_bet_p2 += cost_to_call;
        }

        // Terminal Logic. A call of an all-in pre-river is *not* terminal — the
        // remaining board cards must run out before showdown. We model that as a
        // chance node here; applyChance() chains additional chance steps as
        // needed until the river is dealt.
        if (self.street == .RIVER) {
            new.isTerm = true;
        } else {
            new.is_chance = true;
        }

        return new;
    }

    pub fn applyChance(self: *const GameState) GameState {
        std.debug.assert(self.is_chance);
        var new = self.*;
        new.is_chance = false;
        new.action = .CHANCE;
        new.nextStreet();
        // Post-allin: at least one stack is zero, so no decision can occur. If
        // we've reached the river the next node is the showdown terminal;
        // otherwise we chain another chance step to deal the next street.
        if (new.stack1 == 0 or new.stack2 == 0) {
            if (new.street == .RIVER) {
                new.isTerm = true;
            } else {
                new.is_chance = true;
            }
        }
        return new;
    }
};

const expect = std.testing.expect;

fn chipsConserved(s: GameState, initial_total: f32) bool {
    return std.math.approxEqAbs(f32, s.pot + s.stack1 + s.stack2, initial_total, 1e-3);
}

test "init: no bets, not terminal, chips conserved" {
    const s = GameState.init(.FLOP, true, 100.0, 1000.0, 1000.0);
    try expect(s.numbets == 0);
    try expect(!s.isTerm);
    try expect(chipsConserved(s, 2100.0));
}

test "check-check on flop produces chance state, applyChance advances to turn" {
    const s = GameState.init(.FLOP, true, 100.0, 1000.0, 1000.0);
    const s1 = s.getCheckGameState().?;
    try expect(s1.street == .FLOP);
    try expect(!s1.isp1);
    try expect(!s1.is_chance);
    const s2 = s1.getCheckGameState().?;
    try expect(s2.street == .FLOP);
    try expect(s2.is_chance);
    try expect(!s2.isTerm);
    const s3 = s2.applyChance();
    try expect(s3.street == .TURN);
    try expect(s3.isp1);
    try expect(!s3.is_chance);
    try expect(s3.action == .CHANCE);
    try expect(chipsConserved(s3, 2100.0));
}

test "check-check on river is terminal, no chance state" {
    const s = GameState.init(.RIVER, true, 100.0, 1000.0, 1000.0);
    const s1 = s.getCheckGameState().?;
    const s2 = s1.getCheckGameState().?;
    try expect(s2.isTerm);
    try expect(!s2.is_chance);
}

test "fold and call disallowed when no bet is outstanding" {
    const s = GameState.init(.FLOP, true, 100.0, 1000.0, 1000.0);
    try expect(s.getFoldGameState() == null);
    try expect(s.getCallGameState() == null);
}

test "check disallowed after a bet" {
    const s = GameState.init(.FLOP, true, 100.0, 1000.0, 1000.0);
    const s1 = s.getBetGameState(1.0).?;
    try expect(s1.getCheckGameState() == null);
}

test "max bets cap enforced (no third bet)" {
    const s = GameState.init(.FLOP, true, 100.0, 1000.0, 1000.0);
    const s1 = s.getBetGameState(1.0).?;
    const s2 = s1.getBetGameState(1.0).?;
    try expect(s2.getBetGameState(1.0) == null);
}

test "bet then call on flop produces chance state, applyChance advances to turn" {
    const s = GameState.init(.FLOP, true, 100.0, 1000.0, 1000.0);
    const s1 = s.getBetGameState(1.0).?;
    const s2 = s1.getCallGameState().?;
    try expect(s2.street == .FLOP);
    try expect(s2.is_chance);
    try expect(!s2.isTerm);
    try expect(chipsConserved(s2, 2100.0));
    const s3 = s2.applyChance();
    try expect(s3.street == .TURN);
    try expect(!s3.isTerm);
    try expect(s3.numbets == 0);
    try expect(s3.current_bet_p1 == 0.0);
    try expect(s3.current_bet_p2 == 0.0);
    try expect(chipsConserved(s3, 2100.0));
}

test "river bet-call is terminal, no chance state" {
    const s = GameState.init(.RIVER, true, 100.0, 1000.0, 1000.0);
    const s1 = s.getBetGameState(1.0).?;
    const s2 = s1.getCallGameState().?;
    try expect(s2.isTerm);
    try expect(!s2.is_chance);
}

test "all action methods reject a chance state" {
    const s = GameState.init(.FLOP, true, 100.0, 1000.0, 1000.0);
    const s1 = s.getCheckGameState().?;
    const s2 = s1.getCheckGameState().?;
    try expect(s2.is_chance);
    try expect(s2.getCheckGameState() == null);
    try expect(s2.getCallGameState() == null);
    try expect(s2.getFoldGameState() == null);
    try expect(s2.getBetGameState(1.0) == null);
    try expect(s2.getAllInGameState() == null);
}

test "all-in then call pre-river is chance (runout pending), chips conserved" {
    // FLOP all-in-call: turn and river still need to run before showdown, so the
    // resulting state is a chance node, not a terminal. applyChance dealt twice
    // takes us to a river-terminal post-allin state.
    const s = GameState.init(.FLOP, true, 100.0, 1000.0, 1000.0);
    const s1 = s.getAllInGameState().?;
    try expect(s1.action == .ALLIN);
    const s2 = s1.getCallGameState().?;
    try expect(s2.is_chance);
    try expect(!s2.isTerm);
    try expect(chipsConserved(s2, 2100.0));

    // First chance deal advances FLOP -> TURN. Stacks are still 0/0 so another
    // chance step is required before showdown.
    const s3 = s2.applyChance();
    try expect(s3.street == .TURN);
    try expect(s3.is_chance);
    try expect(!s3.isTerm);

    // Second chance deal advances TURN -> RIVER and lands on the showdown.
    const s4 = s3.applyChance();
    try expect(s4.street == .RIVER);
    try expect(s4.isTerm);
    try expect(!s4.is_chance);
    try expect(chipsConserved(s4, 2100.0));
}

test "all-in call on river is terminal directly (no runout pending)" {
    const s = GameState.init(.RIVER, true, 100.0, 1000.0, 1000.0);
    const s1 = s.getAllInGameState().?;
    const s2 = s1.getCallGameState().?;
    try expect(s2.isTerm);
    try expect(!s2.is_chance);
}

test "all-in respects chips already committed (regression)" {
    // Old `min(my_stack, opp_stack)` ignored already-committed chips: with p1 (500 stack)
    // betting 100 then p2 (1000 stack) shoving, it would put 400 in instead of 500 and
    // leave p1 with 100 chips after a so-called all-in.
    const s = GameState.init(.FLOP, true, 100.0, 500.0, 1000.0);
    const s1 = s.getBetGameState(1.0).?;
    try expect(s1.current_bet_p1 == 100.0);
    try expect(s1.stack1 == 400.0);
    const s2 = s1.getAllInGameState().?;
    try expect(s2.current_bet_p2 == 500.0);
    try expect(s2.stack2 == 500.0);
    const s3 = s2.getCallGameState().?;
    try expect(s3.stack1 == 0.0);
    // Pre-river all-in-call is now a chance node, not terminal.
    try expect(s3.is_chance);
    try expect(!s3.isTerm);
    try expect(chipsConserved(s3, 1600.0));
}

test "no further all-in after an all-in" {
    const s = GameState.init(.FLOP, true, 100.0, 1000.0, 1000.0);
    const s1 = s.getAllInGameState().?;
    try expect(s1.getAllInGameState() == null);
}

test "bet rejected when it would force either side all-in" {
    const s = GameState.init(.FLOP, true, 100.0, 1000.0, 50.0);
    try expect(s.getBetGameState(1.0) == null);
    try expect(s.getBetGameState(0.5) == null);
}
