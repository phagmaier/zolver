const std = @import("std");

pub const Action = enum { FOLD, CHECK, CALL, BET, ALLIN };
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

    pub fn getFoldGameState(self: *GameState) ?GameState {
        if (self.numbets == 0) return null;

        var new = self.*;
        new.isp1 = !self.isp1;
        new.action = .FOLD;
        new.bet = 0;
        new.isTerm = true;
        new.numbets = 0;
        return new;
    }

    pub fn getCheckGameState(self: *GameState) ?GameState {
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
                new.nextStreet();
            }
        }
        return new;
    }

    pub fn getBetGameState(self: *GameState, pct_pot: f32) ?GameState {
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

        // 3. STRICT CHECK: Effective Stack
        // If this bet requires more chips than I have... OR more chips than Opponent has:
        // Then it is effectively an All-in. Return null here and let getAllInGameState handle it.
        if (chips_to_add >= my_stack or chips_to_add >= opp_stack) return null;

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

    pub fn getAllInGameState(self: *GameState) ?GameState {
        if (self.action == .ALLIN) return null;

        var new = self.*;

        const my_stack = if (self.isp1) self.stack1 else self.stack2;
        const opp_stack = if (self.isp1) self.stack2 else self.stack1;
        const my_current = if (self.isp1) self.current_bet_p1 else self.current_bet_p2;

        // 1. Effective Stack Logic
        // We only bet the minimum of the two stacks.
        const effective_add = @min(my_stack, opp_stack);
        const total_wager = my_current + effective_add;

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

    pub fn getCallGameState(self: *GameState) ?GameState {
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

        // Terminal Logic
        if (self.action == .ALLIN) {
            new.isTerm = true;
        } else if (self.street == .RIVER) {
            new.isTerm = true;
        } else {
            new.nextStreet();
        }

        return new;
    }
};
