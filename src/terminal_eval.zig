const std = @import("std");
const card = @import("card.zig");
const isomorphism = @import("isomorphism.zig");
const remap_mod = @import("remap.zig");
const showdown_mod = @import("showdown.zig");

const Combo = card.Combo;
const ShowdownTables = showdown_mod.ShowdownTables;
const RunoutTables = isomorphism.RunoutTables;
const sentinel = std.math.maxInt(u32);

/// Compute an O(N_u + N_opp) fold-terminal value vector for player u.
///
/// values: [N_u]f32 output — CFVs for the updating player
/// reach_opp: [N_opp]f32 — opponent reach probabilities
/// u_card_idx: [2*N_u]u8 — precomputed card indices for u's hands
/// opp_card_idx: [2*N_opp]u8 — precomputed card indices for opponent's hands
/// same_combo_idx: [N_u]u32 — opponent index of identical combo, or maxInt(u32)
/// amount: u's fold-terminal utility (signed; Section 2 conventions)
/// scratch_cardsum: [52]f32 scratch buffer (zeroed by caller)
pub fn foldEval(
    values: []f32,
    reach_opp: []const f32,
    u_card_idx: []const u8,
    opp_card_idx: []const u8,
    same_combo_idx: []const u32,
    amount: f32,
    scratch_cardsum: []f32,
) void {
    // Build cardsum[52] and total reach
    const total = computeCardSum(scratch_cardsum, reach_opp, opp_card_idx);

    // Evaluate each of u's hands
    for (values, 0..) |*v, h| {
        const c1 = u_card_idx[2 * h];
        const c2 = u_card_idx[2 * h + 1];
        var compat: f32 = total - scratch_cardsum[c1] - scratch_cardsum[c2];
        const same = same_combo_idx[h];
        if (same != sentinel) {
            compat += reach_opp[same];
        }
        v.* = amount * compat;
    }
}

/// Compute the 52-float cardsum array from opponent reach and precomputed card indices.
/// cardsum[c] = sum of reach_opp[i] where opponent hand i shares card c.
pub fn computeCardSum(
    cardsum: []f32,
    reach_opp: []const f32,
    opp_card_idx: []const u8,
) f32 {
    var total: f32 = 0;
    for (reach_opp, 0..) |r, i| {
        total += r;
        cardsum[opp_card_idx[2 * i]] += r;
        cardsum[opp_card_idx[2 * i + 1]] += r;
    }
    return total;
}

/// O(N_u + N_opp) showdown-terminal value vector for player u,
/// using the sorted-strength sweep algorithm.
///
/// values: [N_u]f32 output — CFVs for the updating player
/// reach_opp: [N_opp]f32 — opponent reach
/// u_card_idx: [2*N_u]u8 — precomputed card indices for u's hands
/// opp_card_idx: [2*N_opp]u8 — precomputed card indices for opponent's hands
/// u_order: [N_u]u32 — hand indices sorted by decreasing strength
/// u_strengths: [N_u]u32 — hand strengths (indexed by hand idx)
/// opp_order: [N_opp]u32 — same for opponent
/// opp_strengths: [N_opp]u32 — same for opponent
/// same_combo_idx: [N_u]u32 — opponent index of identical combo or sentinel
/// win_amount / loss_amount / tie_amount: payoffs from Section 2 conventions
/// cardsum: [52]f32 — precomputed global card-sum (read-only)
/// total: f32 — precomputed total opponent reach
/// same_reach: [N_u]f32 — precomputed reach_opp[same] for each u-hand, 0 if sentinel
/// scratch_lo_card / scratch_eq_card: [52]f32 each (caller zeroes lo_card)
/// scratch_compat: [N_u]f32 — temp buffer for precomputed compat values
pub fn showdownEval(
    values: []f32,
    reach_opp: []const f32,
    u_card_idx: []const u8,
    opp_card_idx: []const u8,
    u_order: []const u32,
    u_strengths: []const u32,
    opp_order: []const u32,
    opp_strengths: []const u32,
    win_amount: f32,
    loss_amount: f32,
    tie_amount: f32,
    cardsum: []const f32,
    total: f32,
    same_reach: []const f32,
    scratch_lo_card: []f32,
    scratch_eq_card: []f32,
    scratch_compat: []f32,
) void {
    const N_u: u32 = @intCast(values.len);
    const N_opp: u32 = @intCast(reach_opp.len);
    if (N_u == 0) return;

    // Precompute compat[h] = total - cardsum[c1] - cardsum[c2] + same_reach[h]
    for (0..@intCast(N_u)) |h| {
        const c1 = u_card_idx[2 * h];
        const c2 = u_card_idx[2 * h + 1];
        scratch_compat[h] = total - cardsum[c1] - cardsum[c2] + same_reach[h];
    }

    // Walk orders from weakest (end) to strongest (start)
    var u_pos: i32 = @as(i32, @intCast(N_u)) - 1;
    var opp_pos: i32 = @as(i32, @intCast(N_opp)) - 1;
    var lo_total: f32 = 0;

    while (u_pos >= 0) {
        const u_hand: u32 = u_order[@intCast(u_pos)];
        const u_str: u32 = u_strengths[u_hand];

        // Advance opponent hands weaker than this U strength into lo
        while (opp_pos >= 0) {
            const opp_hand: u32 = opp_order[@intCast(opp_pos)];
            const opp_str: u32 = opp_strengths[opp_hand];
            if (opp_str >= u_str) break;
            const r = reach_opp[opp_hand];
            lo_total += r;
            scratch_lo_card[opp_card_idx[2 * opp_hand]] += r;
            scratch_lo_card[opp_card_idx[2 * opp_hand + 1]] += r;
            opp_pos -= 1;
        }

        // Collect opponent hands tied with this U strength into eq
        var eq_total: f32 = 0;
        @memset(scratch_eq_card[0..52], 0);
        while (opp_pos >= 0) {
            const opp_hand: u32 = opp_order[@intCast(opp_pos)];
            const opp_str: u32 = opp_strengths[opp_hand];
            if (opp_str != u_str) break;
            const r = reach_opp[opp_hand];
            eq_total += r;
            scratch_eq_card[opp_card_idx[2 * opp_hand]] += r;
            scratch_eq_card[opp_card_idx[2 * opp_hand + 1]] += r;
            opp_pos -= 1;
        }

        // Process all U hands at this strength
        while (u_pos >= 0) {
            const hand: u32 = u_order[@intCast(u_pos)];
            if (u_strengths[hand] != u_str) break;

            const c1 = u_card_idx[2 * hand];
            const c2 = u_card_idx[2 * hand + 1];

            // weaker = lo mass compatible with this hand
            const weaker: f32 = lo_total - scratch_lo_card[c1] - scratch_lo_card[c2];

            // tied = eq mass compatible with this hand
            const tied: f32 = eq_total - scratch_eq_card[c1] - scratch_eq_card[c2] + same_reach[hand];

            // stronger = precomputed compat - weaker - tied
            const stronger: f32 = scratch_compat[hand] - weaker - tied;

            values[hand] = win_amount * weaker - loss_amount * stronger + tie_amount * tied;

            u_pos -= 1;
        }

        // Fold eq into lo
        lo_total += eq_total;
        for (0..52) |c| {
            scratch_lo_card[c] += scratch_eq_card[c];
        }
    }
}

// ── All-in showdown kernel (terminal reached before the river) ────────────
//
// When both players are all-in before the river, the terminal stands in for
// every remaining canonical runout. We apply the chance protocol of CFR spec
// §3.3/§4.3 *locally*: for each remaining canonical river (and, for a flop
// all-in, each canonical turn above it) we mask both sides, weight by the
// chance multiplicity, run the showdown sweep, mask the returned u-values, and
// accumulate.
//
// NOTE (coupling): this kernel reaches directly into ShowdownTables and
// RunoutTables and enumerates runouts serially. When threading lands
// (plan Phase 8), runout enumeration becomes the parallel unit and this will
// be restructured to share that machinery — expect this signature and the
// serial loop to change. The per-runout math (the showdown sweep + masking)
// is what is being locked down here.

/// Shared inputs for the all-in kernel. All per-runout tables are addressed by
/// the river runout's flat index (`turn.first_river + r`), matching the layout
/// produced by ShowdownTables / BlockingTables.
pub const AllInContext = struct {
    /// Player being updated (0 = OOP, 1 = IP). Opponent is `1 - u`.
    u: u8,
    sd: *const ShowdownTables,
    rt: *const RunoutTables,
    /// Precomputed card indices: card_idx[p][2*h] = card.index(hands[p][h].first),
    /// card_idx[p][2*h+1] = card.index(hands[p][h].second).
    card_idx: [2][]const u8,
    /// Combo arrays (needed only for the O(N^2) naive test oracle).
    u_hands: []const Combo,
    opp_hands: []const Combo,
    /// f32 blocking masks per river runout: mask_river[p][full_index * N_p + h]
    /// (1.0 = live, 0.0 = blocked against the full 5-card board).
    mask_river: [2][]const f32,
    /// Chance weights: weight_rivers[full_index] = river_multiplicity / 48,
    /// weight_turns[turn_index] = turn_multiplicity / 49.
    weight_rivers: []const f32,
    weight_turns: []const f32,
    /// same_combo_idx[h] = opponent index of u-hand h's identical combo, or sentinel.
    same_combo_idx: []const u32,
    /// Showdown payoff coefficients (Section 2 conventions): u wins / u loses / tie.
    win_amount: f32,
    loss_amount: f32,
    tie_amount: f32,
    /// Suit-orbit remap tables; non-null only when compression is enabled, in
    /// which case the `*Remapped` all-in kernels enumerate physical members over
    /// the canonical river tables. When null the physical kernels are used.
    rm: ?*const remap_mod.RemapTables = null,
};

/// Per-thread scratch for the all-in kernel. Sized once; never allocated in the
/// hot path. `reach_opp` and `child_values` must hold N_opp / N_u floats; the
/// three card buffers are [52] each; `same_reach` and `compat` hold N_u each.
pub const AllInScratch = struct {
    reach_opp: []f32,
    child_values: []f32,
    same_reach: []f32,
    compat: []f32,
    lo_card: []f32,
    eq_card: []f32,
    cardsum: []f32,
    /// Per-canonical-turn partial-sum buffer for the compressed flop all-in
    /// reduction. Length N_u. Unused by the physical kernels.
    term_partial: []f32 = &.{},
};

/// All-in terminal reached on the turn (one card to come). `reach_opp` is the
/// opponent reach at this turn runout. Enumerates the canonical rivers under
/// `turn_id`. `values` is fully written (zeroed internally).
pub fn allInEvalTurn(
    values: []f32,
    reach_opp: []const f32,
    turn_id: usize,
    ctx: AllInContext,
    scratch: AllInScratch,
) void {
    @memset(values, 0);
    const turn = ctx.rt.canonical_turns[turn_id];
    accumulateTurnRivers(values, reach_opp, turn, 1.0, false, ctx, scratch);
}

/// All-in terminal reached on the flop (two cards to come). `reach_opp` is the
/// flop-level opponent reach. Enumerates every canonical turn × its rivers,
/// weighting by the turn multiplicity. `values` is fully written (zeroed
/// internally).
pub fn allInEvalFlop(
    values: []f32,
    reach_opp: []const f32,
    ctx: AllInContext,
    scratch: AllInScratch,
) void {
    @memset(values, 0);
    for (ctx.rt.canonical_turns, 0..) |turn, t| {
        accumulateTurnRivers(values, reach_opp, turn, ctx.weight_turns[t], false, ctx, scratch);
    }
}

/// Sum the contribution of all rivers under one canonical turn into `values`.
/// `turn_weight` is 1.0 for a turn all-in, or the turn multiplicity weight for a
/// flop all-in. `use_naive` selects the O(N²) showdown oracle (testing only).
pub fn accumulateTurnRivers(
    values: []f32,
    reach_opp: []const f32,
    turn: isomorphism.CanonicalTurn,
    turn_weight: f32,
    comptime use_naive: bool,
    ctx: AllInContext,
    scratch: AllInScratch,
) void {
    const N_u: usize = values.len;
    const N_opp: usize = reach_opp.len;
    const opp: usize = 1 - @as(usize, ctx.u);
    const u: usize = ctx.u;
    const first: usize = @intCast(turn.first_river);
    const u_card_idx = ctx.card_idx[u];
    const opp_card_idx = ctx.card_idx[opp];

    var r: usize = 0;
    while (r < turn.num_rivers) : (r += 1) {
        const full = first + r;
        const w = turn_weight * ctx.weight_rivers[full];

        // Fuse reach masking + cardsum + same_reach into a single O(N_opp) pass.
        // computeCardSum (~14% of runtime) was previously a SEPARATE loop —
        // now eliminated from the all-in hot path.
        const m_opp = ctx.mask_river[opp][full * N_opp ..][0..N_opp];
        @memset(scratch.cardsum[0..52], 0);
        var total: f32 = 0;
        for (0..N_opp) |i| {
            const mr = reach_opp[i] * m_opp[i] * w;
            total += mr;
            scratch.reach_opp[i] = mr;
            scratch.cardsum[opp_card_idx[2 * i]] += mr;
            scratch.cardsum[opp_card_idx[2 * i + 1]] += mr;
        }

        // Precompute same_reach[h] = reach_opp[same] for each u-hand (0 if sentinel).
        for (0..N_u) |h| {
            const same = ctx.same_combo_idx[h];
            scratch.same_reach[h] = if (same != sentinel) scratch.reach_opp[same] else 0.0;
        }

        if (use_naive) {
            showdownEvalNaive(
                scratch.child_values[0..N_u],
                scratch.reach_opp[0..N_opp],
                ctx.u_hands,
                ctx.opp_hands,
                ctx.sd.strengths[u][full * N_u ..][0..N_u],
                ctx.sd.strengths[opp][full * N_opp ..][0..N_opp],
                ctx.win_amount,
                ctx.loss_amount,
                ctx.tie_amount,
            );
        } else {
            @memset(scratch.lo_card[0..52], 0);
            showdownEval(
                scratch.child_values[0..N_u],
                scratch.reach_opp[0..N_opp],
                u_card_idx,
                opp_card_idx,
                ctx.sd.order[u][full * N_u ..][0..N_u],
                ctx.sd.strengths[u][full * N_u ..][0..N_u],
                ctx.sd.order[opp][full * N_opp ..][0..N_opp],
                ctx.sd.strengths[opp][full * N_opp ..][0..N_opp],
                ctx.win_amount,
                ctx.loss_amount,
                ctx.tie_amount,
                scratch.cardsum,
                total,
                scratch.same_reach,
                scratch.lo_card,
                scratch.eq_card,
                scratch.compat,
            );
        }

        // Return-side mask: zero u-hands blocked by this runout's full board,
        // then accumulate. Without this the showdown sweep's garbage value for a
        // board-blocked traverser hand would leak into the flop/turn CFV.
        const m_u = ctx.mask_river[u][full * N_u ..][0..N_u];
        for (0..N_u) |h| {
            values[h] += m_u[h] * scratch.child_values[h];
        }
    }
}

/// Compressed all-in on the turn: enumerate physical river members of each
/// canonical river under `turn_id`, remapping reach/values through each member's
/// permutation while using the canonical river showdown/mask tables. `values` and
/// `reach_opp` are in the canonical-turn hand frame. `values` is fully written.
pub fn allInEvalTurnRemapped(
    values: []f32,
    reach_opp: []const f32,
    turn_id: usize,
    ctx: AllInContext,
    scratch: AllInScratch,
) void {
    @memset(values, 0);
    const rm = ctx.rm.?;
    const turn = ctx.rt.canonical_turns[turn_id];
    const first: usize = @intCast(turn.first_river);
    var r: usize = 0;
    while (r < turn.num_rivers) : (r += 1) {
        const full = first + r;
        for (rm.river_members[full]) |member| {
            accumulateRiverMemberRemapped(values, reach_opp, full, rm.hand_perms[member.perm_index], rm.weight_river, ctx, scratch);
        }
    }
}

/// Compressed all-in on the flop: enumerate every physical turn→river runout,
/// grouped by canonical turn, using the composed permutation onto its canonical
/// river board. `values`/`reach_opp` are in the flop hand frame. Each canonical
/// turn's contributions are summed into a partial buffer first, then folded into
/// `values` — matching the physical `allInEvalFlop`'s two-level reduction so the
/// rainbow case is bit-identical.
pub fn allInEvalFlopRemapped(
    values: []f32,
    reach_opp: []const f32,
    ctx: AllInContext,
    scratch: AllInScratch,
) void {
    @memset(values, 0);
    const rm = ctx.rm.?;
    const partial = scratch.term_partial[0..values.len];
    for (0..rm.flop_runouts.len) |t| {
        allInEvalFlopRemappedTurn(partial, reach_opp, @intCast(t), ctx, scratch);
        for (values, partial) |*value, contribution| value.* += contribution;
    }
}

/// Contribution of one canonical turn orbit to a compressed flop all-in.
/// `values` is fully written and may be used as a per-turn worker result slot;
/// this makes compressed flop all-ins safe to dispatch in parallel while keeping
/// the caller's final reduction in canonical-turn order.
pub fn allInEvalFlopRemappedTurn(
    values: []f32,
    reach_opp: []const f32,
    turn_id: u32,
    ctx: AllInContext,
    scratch: AllInScratch,
) void {
    @memset(values, 0);
    const rm = ctx.rm.?;
    const w = rm.weight_turn * rm.weight_river;
    for (rm.flop_runouts[turn_id]) |run| {
        accumulateRiverMemberRemapped(values, reach_opp, run.canonical_river, rm.hand_perms[run.perm_index], w, ctx, scratch);
    }
}

/// One physical river member's contribution to a compressed all-in CFV.
///
/// `reach_opp`/`values` are in the *current* (canonical-turn or flop) hand frame;
/// `full` selects the canonical river's showdown/mask tables. `hp` carries the
/// current frame onto the canonical river frame. Mirrors one iteration of
/// `accumulateTurnRivers`, with a reach gather in and a value gather out.
fn accumulateRiverMemberRemapped(
    values: []f32,
    reach_opp: []const f32,
    full: usize,
    hp: remap_mod.HandPerm,
    w: f32,
    ctx: AllInContext,
    scratch: AllInScratch,
) void {
    const N_u: usize = values.len;
    const N_opp: usize = reach_opp.len;
    const u: usize = ctx.u;
    const opp: usize = 1 - @as(usize, ctx.u);
    const u_card_idx = ctx.card_idx[u];
    const opp_card_idx = ctx.card_idx[opp];

    const m_opp = ctx.mask_river[opp][full * N_opp ..][0..N_opp];
    const fo = hp.from_canon[opp];
    @memset(scratch.cardsum[0..52], 0);
    var total: f32 = 0;
    for (0..N_opp) |j| {
        const mr = reach_opp[fo[j]] * m_opp[j] * w;
        total += mr;
        scratch.reach_opp[j] = mr;
        scratch.cardsum[opp_card_idx[2 * j]] += mr;
        scratch.cardsum[opp_card_idx[2 * j + 1]] += mr;
    }

    // same_reach is indexed in the canonical frame; same_combo_idx is
    // frame-independent (identical-combo pairing is a property of the two cards).
    for (0..N_u) |j| {
        const same = ctx.same_combo_idx[j];
        scratch.same_reach[j] = if (same != sentinel) scratch.reach_opp[same] else 0.0;
    }

    @memset(scratch.lo_card[0..52], 0);
    showdownEval(
        scratch.child_values[0..N_u],
        scratch.reach_opp[0..N_opp],
        u_card_idx,
        opp_card_idx,
        ctx.sd.order[u][full * N_u ..][0..N_u],
        ctx.sd.strengths[u][full * N_u ..][0..N_u],
        ctx.sd.order[opp][full * N_opp ..][0..N_opp],
        ctx.sd.strengths[opp][full * N_opp ..][0..N_opp],
        ctx.win_amount,
        ctx.loss_amount,
        ctx.tie_amount,
        scratch.cardsum,
        total,
        scratch.same_reach,
        scratch.lo_card,
        scratch.eq_card,
        scratch.compat,
    );

    // Fold canonical-river values back into the current frame: current-frame
    // u-hand h maps to canonical u-hand tu[h]; its physical mask equals the
    // canonical mask at that index.
    const m_u = ctx.mask_river[u][full * N_u ..][0..N_u];
    const tu = hp.to_canon[u];
    for (0..N_u) |h| {
        const g = tu[h];
        values[h] += m_u[g] * scratch.child_values[g];
    }
}

// ── Naive O(N²) oracles for testing ──────────────────────────────────────

/// O(N_u * N_opp) fold-terminal evaluation — reference oracle.
pub fn foldEvalNaive(
    values: []f32,
    reach_opp: []const f32,
    u_hands: []const Combo,
    opp_hands: []const Combo,
    amount: f32,
) void {
    for (values, 0..) |*v, h| {
        const u_hand = u_hands[h];
        const u_mask = card.mask(u_hand.first) | card.mask(u_hand.second);
        var compat: f32 = 0;
        for (opp_hands, 0..) |opp_hand, i| {
            const opp_mask = card.mask(opp_hand.first) | card.mask(opp_hand.second);
            if ((u_mask & opp_mask) == 0) {
                compat += reach_opp[i];
            }
        }
        v.* = amount * compat;
    }
}

/// O(N_u * N_opp) showdown-terminal evaluation — reference oracle.
pub fn showdownEvalNaive(
    values: []f32,
    reach_opp: []const f32,
    u_hands: []const Combo,
    opp_hands: []const Combo,
    u_strengths: []const u32,
    opp_strengths: []const u32,
    win_amount: f32,
    loss_amount: f32,
    tie_amount: f32,
) void {
    for (values, 0..) |*v, h| {
        const u_hand = u_hands[h];
        const u_mask = card.mask(u_hand.first) | card.mask(u_hand.second);
        const u_str = u_strengths[h];
        var weaker: f32 = 0;
        var tied: f32 = 0;
        var stronger: f32 = 0;
        for (opp_hands, 0..) |opp_hand, i| {
            const opp_mask = card.mask(opp_hand.first) | card.mask(opp_hand.second);
            if ((u_mask & opp_mask) != 0) continue;
            const opp_str = opp_strengths[i];
            const r = reach_opp[i];
            if (u_str > opp_str) {
                weaker += r;
            } else if (u_str == opp_str) {
                tied += r;
            } else {
                stronger += r;
            }
        }
        v.* = win_amount * weaker - loss_amount * stronger + tie_amount * tied;
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeHands() !struct { hands: [3]Combo, card1: [3]u8, card2: [3]u8 } {
    const h0 = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 0)); // A♠ K♠
    const h1 = try Combo.init(card.makeCard(12, 1), card.makeCard(11, 1)); // A♥ K♥
    const h2 = try Combo.init(card.makeCard(0, 2), card.makeCard(1, 2)); // 2♦ 3♦
    const c1 = [_]u8{ card.index(h0.first), card.index(h1.first), card.index(h2.first) };
    const c2 = [_]u8{ card.index(h0.second), card.index(h1.second), card.index(h2.second) };
    return .{ .hands = .{ h0, h1, h2 }, .card1 = c1, .card2 = c2 };
}

test "foldEval: O(N) matches O(N^2) oracle with random reaches" {
    const hands = try makeHands();
    const u_hands = [_]Combo{ hands.hands[0], hands.hands[1], hands.hands[2] };
    const opp_hands = [_]Combo{ hands.hands[0], hands.hands[1], hands.hands[2] };

    var prng = std.Random.DefaultPrng.init(123);
    const rand = prng.random();

    var reach_opp: [3]f32 = undefined;
    for (&reach_opp) |*r| r.* = rand.float(f32);

    var same_idx: [3]u32 = undefined;
    same_idx[0] = 0;
    same_idx[1] = 1;
    same_idx[2] = 2;

    const u_ci = [_]u8{
        card.index(u_hands[0].first), card.index(u_hands[0].second),
        card.index(u_hands[1].first), card.index(u_hands[1].second),
        card.index(u_hands[2].first), card.index(u_hands[2].second),
    };
    const opp_ci = [_]u8{
        card.index(opp_hands[0].first), card.index(opp_hands[0].second),
        card.index(opp_hands[1].first), card.index(opp_hands[1].second),
        card.index(opp_hands[2].first), card.index(opp_hands[2].second),
    };

    var values_fast: [3]f32 = undefined;
    var values_naive: [3]f32 = undefined;
    var scratch_cardsum = [_]f32{0} ** 52;

    foldEval(&values_fast, &reach_opp, &u_ci, &opp_ci, &same_idx, 1.0, &scratch_cardsum);
    foldEvalNaive(&values_naive, &reach_opp, &u_hands, &opp_hands, 1.0);

    for (0..3) |i| {
        try testing.expect(@abs(values_fast[i] - values_naive[i]) < 1e-6);
    }
}

test "foldEval: negative amount flips sign" {
    const h0 = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 0));
    const h1 = try Combo.init(card.makeCard(12, 1), card.makeCard(11, 1));
    const reach_opp = [_]f32{1.0};
    const same_idx = [_]u32{sentinel};
    const u_ci = [_]u8{ card.index(h0.first), card.index(h0.second) };
    const opp_ci = [_]u8{ card.index(h1.first), card.index(h1.second) };
    var values: [1]f32 = undefined;
    var scratch = [_]f32{0} ** 52;

    foldEval(&values, &reach_opp, &u_ci, &opp_ci, &same_idx, -10.0, &scratch);
    try testing.expect(@abs(-10.0 - values[0]) < 1e-6); // 100% compat × -10
}

test "foldEval: blocked hand reduces compat mass" {
    // u_hand = A♠ K♠, opp_hand = K♠ Q♠ — both share K♠ → not compatible
    const u_hand = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 0));
    const opp_hand = try Combo.init(card.makeCard(11, 0), card.makeCard(10, 0));
    const reach_opp = [_]f32{0.75};
    const same_idx = [_]u32{sentinel};
    const u_ci = [_]u8{ card.index(u_hand.first), card.index(u_hand.second) };
    const opp_ci = [_]u8{ card.index(opp_hand.first), card.index(opp_hand.second) };
    var values: [1]f32 = undefined;
    var scratch = [_]f32{0} ** 52;

    foldEval(&values, &reach_opp, &u_ci, &opp_ci, &same_idx, 1.0, &scratch);
    try testing.expect(@abs(0.0 - values[0]) < 1e-6);
}

test "foldEval: same combo inclusion-exclusion" {
    // Both players hold A♠ K♠
    const h = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 0));
    const reach_opp = [_]f32{1.0};
    const same_idx = [_]u32{0}; // same combo at opp idx 0
    const u_ci = [_]u8{ card.index(h.first), card.index(h.second) };
    const opp_ci = [_]u8{ card.index(h.first), card.index(h.second) };
    var values: [1]f32 = undefined;
    var scratch = [_]f32{0} ** 52;

    foldEval(&values, &reach_opp, &u_ci, &opp_ci, &same_idx, 1.0, &scratch);
    try testing.expect(@abs(0.0 - values[0]) < 1e-6);
}

test "showdownEval: O(N) matches O(N^2) oracle" {
    const hands = try makeHands();
    const u_hands = [_]Combo{ hands.hands[0], hands.hands[1], hands.hands[2] };
    const opp_hands = [_]Combo{ hands.hands[0], hands.hands[1], hands.hands[2] };

    var prng = std.Random.DefaultPrng.init(456);
    const rand = prng.random();

    var reach_opp: [3]f32 = undefined;
    for (&reach_opp) |*r| r.* = rand.float(f32);

    const u_strengths = [_]u32{ 300, 200, 100 };
    const opp_strengths = [_]u32{ 300, 200, 100 };

    const u_order = [_]u32{ 0, 1, 2 };
    const opp_order = [_]u32{ 0, 1, 2 };

    var same_idx: [3]u32 = undefined;
    same_idx[0] = 0;
    same_idx[1] = 1;
    same_idx[2] = 2;

    const W: f32 = 100;
    const C: f32 = 50;
    const T: f32 = 25;

    const u_ci = [_]u8{
        card.index(u_hands[0].first), card.index(u_hands[0].second),
        card.index(u_hands[1].first), card.index(u_hands[1].second),
        card.index(u_hands[2].first), card.index(u_hands[2].second),
    };
    const opp_ci = [_]u8{
        card.index(opp_hands[0].first), card.index(opp_hands[0].second),
        card.index(opp_hands[1].first), card.index(opp_hands[1].second),
        card.index(opp_hands[2].first), card.index(opp_hands[2].second),
    };

    var values_fast: [3]f32 = undefined;
    var values_naive: [3]f32 = undefined;
    var lo_card = [_]f32{0} ** 52;
    var eq_card = [_]f32{0} ** 52;
    var cardsum = [_]f32{0} ** 52;
    var compat = [_]f32{0} ** 3;
    var same_reach = [_]f32{0} ** 3;

    // Precompute cardsum, total, same_reach (mimicking cfr.zig's evalTerminal)
    const total = computeCardSum(&cardsum, &reach_opp, &opp_ci);
    for (0..3) |h| {
        const same = same_idx[h];
        same_reach[h] = if (same != sentinel) reach_opp[same] else 0.0;
    }

    showdownEval(
        &values_fast,
        &reach_opp,
        &u_ci,
        &opp_ci,
        &u_order,
        &u_strengths,
        &opp_order,
        &opp_strengths,
        W,
        C,
        T,
        &cardsum,
        total,
        &same_reach,
        &lo_card,
        &eq_card,
        &compat,
    );

    showdownEvalNaive(
        &values_naive,
        &reach_opp,
        &u_hands,
        &opp_hands,
        &u_strengths,
        &opp_strengths,
        W,
        C,
        T,
    );

    for (0..3) |i| {
        try testing.expect(@abs(values_fast[i] - values_naive[i]) < 1e-6);
    }
}

test "showdownEval: win/loss/tie coefficients applied correctly" {
    // Simple test: two compatible hands with different strengths.
    const u_hand = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 0));
    const opp_hand = try Combo.init(card.makeCard(0, 2), card.makeCard(1, 2));
    const reach_opp = [_]f32{0.75};

    const u_strengths = [_]u32{300};
    const opp_strengths = [_]u32{100};
    const order = [_]u32{0};

    const u_ci = [_]u8{ card.index(u_hand.first), card.index(u_hand.second) };
    const opp_ci = [_]u8{ card.index(opp_hand.first), card.index(opp_hand.second) };

    var values: [1]f32 = undefined;
    var lo_card = [_]f32{0} ** 52;
    var eq_card = [_]f32{0} ** 52;
    var cardsum = [_]f32{0} ** 52;
    var compat_buf = [_]f32{0} ** 1;
    var same_reach = [_]f32{0} ** 1;

    // W=10, C=5, T=2
    const total = computeCardSum(&cardsum, &reach_opp, &opp_ci);
    showdownEval(
        &values,
        &reach_opp,
        &u_ci,
        &opp_ci,
        &order,
        &u_strengths,
        &order,
        &opp_strengths,
        10.0,
        5.0,
        2.0,
        &cardsum,
        total,
        &same_reach,
        &lo_card,
        &eq_card,
        &compat_buf,
    );

    // Hands are compatible (A♠K♠ vs 2♦3♦ — no shared cards)
    // u_str=300 > opp_str=100 → weaker = 0.75 (all opp reach)
    // tied = 0, stronger = 0
    // v = 10*0.75 - 5*0 + 2*0 = 7.5
    try testing.expect(@abs(7.5 - values[0]) < 1e-6);
}

test "showdownEval: empty U range produces no output" {
    const opp_hand = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 0));
    const reach_opp = [_]f32{1.0};
    const strengths = [_]u32{300};
    const order = [_]u32{0};
    const opp_ci = [_]u8{ card.index(opp_hand.first), card.index(opp_hand.second) };

    var values: [0]f32 = undefined;
    var lo_card = [_]f32{0} ** 52;
    var eq_card = [_]f32{0} ** 52;
    var cardsum = [_]f32{0} ** 52;
    var compat_buf: [0]f32 = undefined;
    var same_reach: [0]f32 = undefined;

    const total = computeCardSum(&cardsum, &reach_opp, &opp_ci);

    showdownEval(
        &values,
        &reach_opp,
        &.{},
        &opp_ci,
        &.{},
        &.{},
        &order,
        &strengths,
        1.0,
        1.0,
        1.0,
        &cardsum,
        total,
        &same_reach,
        &lo_card,
        &eq_card,
        &compat_buf,
    );
}

test "showdownEval: order reversed from strongest→weakest verified" {
    // Three hands with known strengths. Verify the sweep processes weakest first.
    const h0 = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 0)); // A♠K♠
    const h1 = try Combo.init(card.makeCard(12, 1), card.makeCard(11, 1)); // A♥K♥
    const h2 = try Combo.init(card.makeCard(0, 2), card.makeCard(1, 2)); // 2♦3♦
    const u_hands = [_]Combo{ h0, h1, h2 };
    const opp_hands = [_]Combo{ h0, h1, h2 };
    const reach_opp = [_]f32{ 0.5, 0.3, 0.2 };

    // Distinct strengths: h0 > h1 > h2
    const u_strengths = [_]u32{ 500, 300, 100 };
    const opp_strengths = [_]u32{ 500, 300, 100 };
    const u_order = [_]u32{ 0, 1, 2 }; // strongest→weakest
    const opp_order = [_]u32{ 0, 1, 2 };
    const same_idx = [_]u32{ 0, 1, 2 };

    const u_ci = [_]u8{
        card.index(h0.first), card.index(h0.second),
        card.index(h1.first), card.index(h1.second),
        card.index(h2.first), card.index(h2.second),
    };
    const opp_ci = [_]u8{
        card.index(h0.first), card.index(h0.second),
        card.index(h1.first), card.index(h1.second),
        card.index(h2.first), card.index(h2.second),
    };

    var values_fast: [3]f32 = undefined;
    var values_naive: [3]f32 = undefined;
    var lo_card = [_]f32{0} ** 52;
    var eq_card = [_]f32{0} ** 52;
    var cardsum = [_]f32{0} ** 52;
    var compat_buf = [_]f32{0} ** 3;
    var same_reach = [_]f32{0} ** 3;

    const total = computeCardSum(&cardsum, &reach_opp, &opp_ci);
    for (0..3) |h| {
        const s = same_idx[h];
        same_reach[h] = if (s != sentinel) reach_opp[s] else 0.0;
    }

    showdownEval(
        &values_fast,
        &reach_opp,
        &u_ci,
        &opp_ci,
        &u_order,
        &u_strengths,
        &opp_order,
        &opp_strengths,
        1.0,
        0.0,
        0.5,
        &cardsum,
        total,
        &same_reach,
        &lo_card,
        &eq_card,
        &compat_buf,
    );

    showdownEvalNaive(
        &values_naive,
        &reach_opp,
        &u_hands,
        &opp_hands,
        &u_strengths,
        &opp_strengths,
        1.0,
        0.0,
        0.5,
    );

    for (0..3) |i| {
        try testing.expect(@abs(values_fast[i] - values_naive[i]) < 1e-6);
    }
}

test "showdownEval: constant-sum property on random data" {
    const h0 = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 0));
    const h1 = try Combo.init(card.makeCard(12, 1), card.makeCard(11, 1));
    const h2 = try Combo.init(card.makeCard(0, 2), card.makeCard(1, 2));
    const u_hands = [_]Combo{ h0, h1, h2 };
    const opp_hands = [_]Combo{ h0, h1, h2 };

    var prng = std.Random.DefaultPrng.init(789);
    const rand = prng.random();

    var reach_opp: [3]f32 = undefined;
    for (&reach_opp) |*r| r.* = rand.float(f32);

    const u_strengths = [_]u32{ 500, 300, 100 };
    const opp_strengths = [_]u32{ 500, 300, 100 };
    const order = [_]u32{ 0, 1, 2 };
    const same_idx = [_]u32{ 0, 1, 2 };

    const u_ci = [_]u8{
        card.index(h0.first), card.index(h0.second),
        card.index(h1.first), card.index(h1.second),
        card.index(h2.first), card.index(h2.second),
    };
    const opp_ci = [_]u8{
        card.index(h0.first), card.index(h0.second),
        card.index(h1.first), card.index(h1.second),
        card.index(h2.first), card.index(h2.second),
    };

    var values_fast: [3]f32 = undefined;
    var values_naive: [3]f32 = undefined;
    var lo_card = [_]f32{0} ** 52;
    var eq_card = [_]f32{0} ** 52;
    var cardsum = [_]f32{0} ** 52;
    var compat_buf = [_]f32{0} ** 3;
    var same_reach = [_]f32{0} ** 3;

    const total = computeCardSum(&cardsum, &reach_opp, &opp_ci);
    for (0..3) |h| {
        const s = same_idx[h];
        same_reach[h] = if (s != sentinel) reach_opp[s] else 0.0;
    }

    showdownEval(
        &values_fast,
        &reach_opp,
        &u_ci,
        &opp_ci,
        &order,
        &u_strengths,
        &order,
        &opp_strengths,
        1.0,
        0.0,
        0.5,
        &cardsum,
        total,
        &same_reach,
        &lo_card,
        &eq_card,
        &compat_buf,
    );

    showdownEvalNaive(
        &values_naive,
        &reach_opp,
        &opp_hands,
        &u_hands,
        &opp_strengths,
        &u_strengths,
        1.0,
        0.0,
        0.5,
    );

    for (0..3) |i| {
        try testing.expect(@abs(values_fast[i] - values_naive[i]) < 1e-6);
    }
}

test "computeCardSum: correct total and per-card sums" {
    const h0 = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 0));
    const h1 = try Combo.init(card.makeCard(12, 1), card.makeCard(11, 1));
    const reach = [_]f32{ 0.6, 0.4 };
    const opp_ci = [_]u8{
        card.index(h0.first), card.index(h0.second),
        card.index(h1.first), card.index(h1.second),
    };

    var cardsum = [_]f32{0} ** 52;
    const total = computeCardSum(&cardsum, &reach, &opp_ci);

    try testing.expect(@abs(1.0 - total) < 1e-7);
    try testing.expect(@abs(0.6 - cardsum[card.index(h0.first)]) < 1e-7);
    try testing.expect(@abs(0.6 - cardsum[card.index(h0.second)]) < 1e-7);
    try testing.expect(@abs(0.4 - cardsum[card.index(h1.first)]) < 1e-7);
    try testing.expect(@abs(0.4 - cardsum[card.index(h1.second)]) < 1e-7);
}

// ── All-in kernel tests ───────────────────────────────────────────────────

const blocking_mod = @import("blocking.zig");
const evaluator_mod = @import("evaluator.zig");

/// Naive enumeration wrappers (use the O(N²) showdown oracle per runout) — the
/// reference the fast kernel is validated against.
fn allInEvalTurnNaive(
    values: []f32,
    reach_opp: []const f32,
    turn_id: usize,
    ctx: AllInContext,
    scratch: AllInScratch,
) void {
    @memset(values, 0);
    const turn = ctx.rt.canonical_turns[turn_id];
    accumulateTurnRivers(values, reach_opp, turn, 1.0, true, ctx, scratch);
}

fn allInEvalFlopNaive(
    values: []f32,
    reach_opp: []const f32,
    ctx: AllInContext,
    scratch: AllInScratch,
) void {
    @memset(values, 0);
    for (ctx.rt.canonical_turns, 0..) |turn, t| {
        accumulateTurnRivers(values, reach_opp, turn, ctx.weight_turns[t], true, ctx, scratch);
    }
}

/// Owns every table the all-in kernel needs, built from real modules so the
/// test exercises the production data layout end-to-end.
const TestEnv = struct {
    allocator: std.mem.Allocator,
    rt: RunoutTables,
    sd: ShowdownTables,
    blk: blocking_mod.BlockingTables,
    mask_river: [2][]f32,
    weight_turns: []f32,
    weight_rivers: []f32,
    same_combo: []u32,
    card_idx: [2][]u8,
    u_hands: []const Combo,
    opp_hands: []const Combo,

    fn init(
        allocator: std.mem.Allocator,
        flop: [3]card.Card,
        u_hands: []const Combo,
        opp_hands: []const Combo,
    ) !TestEnv {
        var rt = try isomorphism.buildUncompressedRunoutTables(allocator, flop);
        errdefer rt.deinit();

        var eval = evaluator_mod.Evaluator{};
        var sd = try ShowdownTables.init(allocator, .{ u_hands, opp_hands }, flop, &rt, &eval);
        errdefer sd.deinit();

        var blk = try blocking_mod.BlockingTables.init(allocator, .{ u_hands, opp_hands }, flop, &rt);
        errdefer blk.deinit();

        const mr0 = try boolToF32(allocator, blk.blocked_river[0]);
        errdefer allocator.free(mr0);
        const mr1 = try boolToF32(allocator, blk.blocked_river[1]);
        errdefer allocator.free(mr1);

        const wt = try allocator.alloc(f32, rt.canonical_turns.len);
        errdefer allocator.free(wt);
        for (rt.canonical_turns, 0..) |t, i| {
            wt[i] = @as(f32, @floatFromInt(t.multiplicity)) / 45.0;
        }
        const wr = try allocator.alloc(f32, rt.canonical_rivers.len);
        errdefer allocator.free(wr);
        for (rt.canonical_rivers, 0..) |riv, i| {
            wr[i] = @as(f32, @floatFromInt(riv.multiplicity)) / 44.0;
        }

        // same_combo_idx: u-hand → opponent index of identical combo, or sentinel.
        const sc = try allocator.alloc(u32, u_hands.len);
        errdefer allocator.free(sc);
        for (u_hands, 0..) |uh, i| {
            sc[i] = sentinel;
            for (opp_hands, 0..) |oh, j| {
                if (uh.canonicalKey() == oh.canonicalKey()) {
                    sc[i] = @intCast(j);
                    break;
                }
            }
        }

        // Precompute per-hand card index arrays (eliminates card.index() hot-path calls).
        var ci: [2][]u8 = undefined;
        ci[0] = try allocator.alloc(u8, u_hands.len * 2);
        errdefer allocator.free(ci[0]);
        ci[1] = try allocator.alloc(u8, opp_hands.len * 2);
        errdefer allocator.free(ci[1]);
        for (u_hands, 0..) |h, i| {
            ci[0][2 * i] = card.index(h.first);
            ci[0][2 * i + 1] = card.index(h.second);
        }
        for (opp_hands, 0..) |h, i| {
            ci[1][2 * i] = card.index(h.first);
            ci[1][2 * i + 1] = card.index(h.second);
        }

        return .{
            .allocator = allocator,
            .rt = rt,
            .sd = sd,
            .blk = blk,
            .mask_river = .{ mr0, mr1 },
            .weight_turns = wt,
            .weight_rivers = wr,
            .same_combo = sc,
            .card_idx = ci,
            .u_hands = u_hands,
            .opp_hands = opp_hands,
        };
    }

    fn deinit(self: *TestEnv) void {
        self.allocator.free(self.card_idx[1]);
        self.allocator.free(self.card_idx[0]);
        self.allocator.free(self.same_combo);
        self.allocator.free(self.weight_rivers);
        self.allocator.free(self.weight_turns);
        self.allocator.free(self.mask_river[1]);
        self.allocator.free(self.mask_river[0]);
        self.blk.deinit();
        self.sd.deinit();
        self.rt.deinit();
    }

    fn ctx(self: *const TestEnv, W: f32, C: f32, T: f32) AllInContext {
        return .{
            .u = 0,
            .sd = &self.sd,
            .rt = &self.rt,
            .card_idx = .{ self.card_idx[0], self.card_idx[1] },
            .u_hands = self.u_hands,
            .opp_hands = self.opp_hands,
            .mask_river = .{ self.mask_river[0], self.mask_river[1] },
            .weight_rivers = self.weight_rivers,
            .weight_turns = self.weight_turns,
            .same_combo_idx = self.same_combo,
            .win_amount = W,
            .loss_amount = C,
            .tie_amount = T,
        };
    }
};

fn boolToF32(allocator: std.mem.Allocator, blocked: []const bool) ![]f32 {
    const out = try allocator.alloc(f32, blocked.len);
    for (blocked, 0..) |b, i| out[i] = if (b) 0.0 else 1.0;
    return out;
}

fn makeScratch(allocator: std.mem.Allocator, n_u: usize, n_opp: usize) !AllInScratch {
    return .{
        .reach_opp = try allocator.alloc(f32, n_opp),
        .child_values = try allocator.alloc(f32, n_u),
        .same_reach = try allocator.alloc(f32, n_u),
        .compat = try allocator.alloc(f32, n_u),
        .lo_card = try allocator.alloc(f32, 52),
        .eq_card = try allocator.alloc(f32, 52),
        .cardsum = try allocator.alloc(f32, 52),
    };
}

fn freeScratch(allocator: std.mem.Allocator, s: AllInScratch) void {
    allocator.free(s.reach_opp);
    allocator.free(s.child_values);
    allocator.free(s.same_reach);
    allocator.free(s.compat);
    allocator.free(s.lo_card);
    allocator.free(s.eq_card);
    allocator.free(s.cardsum);
}

fn testHands() ![3]Combo {
    return .{
        try Combo.init(card.makeCard(11, 3), card.makeCard(10, 3)), // K♣ Q♣
        try Combo.init(card.makeCard(7, 0), card.makeCard(6, 0)), // 9♠ 8♠
        try Combo.init(card.makeCard(3, 2), card.makeCard(2, 2)), // 5♦ 4♦
    };
}

test "allInEvalTurn: fast sweep matches naive enumeration" {
    const alloc = std.testing.allocator;
    // Rainbow flop, no suit symmetry → full runout enumeration.
    const flop = [_]card.Card{ card.makeCard(12, 0), card.makeCard(8, 1), card.makeCard(5, 2) };
    const hands = try testHands();

    var env = try TestEnv.init(alloc, flop, &hands, &hands);
    defer env.deinit();

    var prng = std.Random.DefaultPrng.init(2026);
    const rand = prng.random();
    var reach_opp: [3]f32 = undefined;
    for (&reach_opp) |*r| r.* = rand.float(f32);

    var v_fast: [3]f32 = undefined;
    var v_naive: [3]f32 = undefined;
    const s = try makeScratch(alloc, 3, 3);
    defer freeScratch(alloc, s);

    const ctx = env.ctx(120.0, 60.0, 30.0); // arbitrary W/C/T
    const turn_id: usize = 7;

    allInEvalTurn(&v_fast, &reach_opp, turn_id, ctx, s);
    allInEvalTurnNaive(&v_naive, &reach_opp, turn_id, ctx, s);

    for (0..3) |i| try testing.expect(@abs(v_fast[i] - v_naive[i]) < 1e-4);
}

test "allInEvalFlop: fast sweep matches naive enumeration" {
    const alloc = std.testing.allocator;
    const flop = [_]card.Card{ card.makeCard(12, 0), card.makeCard(8, 1), card.makeCard(5, 2) };
    const hands = try testHands();

    var env = try TestEnv.init(alloc, flop, &hands, &hands);
    defer env.deinit();

    var prng = std.Random.DefaultPrng.init(99);
    const rand = prng.random();
    var reach_opp: [3]f32 = undefined;
    for (&reach_opp) |*r| r.* = rand.float(f32);

    var v_fast: [3]f32 = undefined;
    var v_naive: [3]f32 = undefined;
    const s = try makeScratch(alloc, 3, 3);
    defer freeScratch(alloc, s);

    const ctx = env.ctx(150.0, 75.0, 0.0);
    allInEvalFlop(&v_fast, &reach_opp, ctx, s);
    allInEvalFlopNaive(&v_naive, &reach_opp, ctx, s);

    for (0..3) |i| try testing.expect(@abs(v_fast[i] - v_naive[i]) < 1e-4);
}

test "allInEvalFlop: preserves constant sum across complete physical runouts" {
    const alloc = std.testing.allocator;
    const flop = [_]card.Card{ card.makeCard(12, 0), card.makeCard(8, 1), card.makeCard(5, 2) };
    const u_hands = [_]Combo{
        try Combo.init(card.makeCard(11, 3), card.makeCard(10, 3)),
        try Combo.init(card.makeCard(4, 0), card.makeCard(3, 0)),
    };
    const opp_hands = [_]Combo{
        try Combo.init(card.makeCard(9, 3), card.makeCard(7, 3)),
        try Combo.init(card.makeCard(2, 0), card.makeCard(1, 0)),
    };
    var env = try TestEnv.init(alloc, flop, &u_hands, &opp_hands);
    defer env.deinit();

    const r0 = [_]f32{ 0.4, 0.9 };
    const r1 = [_]f32{ 0.7, 0.3 };
    var v0: [2]f32 = undefined;
    var v1: [2]f32 = undefined;
    const s = try makeScratch(alloc, 2, 2);
    defer freeScratch(alloc, s);

    const ip: f32 = 10.0;
    const ctx0 = env.ctx(20.0, 10.0, 5.0);
    allInEvalFlop(&v0, &r1, ctx0, s);

    var same1 = [_]u32{ sentinel, sentinel };
    var ctx1 = ctx0;
    ctx1.u = 1;
    ctx1.same_combo_idx = &same1;
    allInEvalFlop(&v1, &r0, ctx1, s);

    var total: f32 = 0;
    for (r0, v0) |r, v| total += r * v;
    for (r1, v1) |r, v| total += r * v;

    var compatible_mass: f32 = 0;
    for (u_hands, r0) |uh, ru| {
        for (opp_hands, r1) |oh, ro| {
            if ((uh.cardMask() & oh.cardMask()) == 0) compatible_mass += ru * ro;
        }
    }
    try std.testing.expectApproxEqAbs(ip * compatible_mass, total, 2e-3);
}

test "allInEvalFlop: u-hand sharing a flop card gets exactly zero" {
    const alloc = std.testing.allocator;
    const flop = [_]card.Card{ card.makeCard(12, 0), card.makeCard(8, 1), card.makeCard(5, 2) };
    // u-hand 0 contains A♠ (a flop card) → blocked on every runout → value 0.
    const u_hands = [_]Combo{
        try Combo.init(card.makeCard(12, 0), card.makeCard(10, 3)), // A♠ Q♣ (A♠ on flop)
        try Combo.init(card.makeCard(7, 0), card.makeCard(6, 0)), // 9♠ 8♠ (live)
    };
    const opp_hands = [_]Combo{
        try Combo.init(card.makeCard(11, 3), card.makeCard(10, 2)), // K♣ Q♦
        try Combo.init(card.makeCard(3, 3), card.makeCard(2, 3)), // 5♣ 4♣
    };

    var env = try TestEnv.init(alloc, flop, &u_hands, &opp_hands);
    defer env.deinit();

    const reach_opp = [_]f32{ 0.7, 0.5 };
    var v: [2]f32 = undefined;
    const s = try makeScratch(alloc, 2, 2);
    defer freeScratch(alloc, s);

    const ctx = env.ctx(100.0, 50.0, 25.0);
    allInEvalFlop(&v, &reach_opp, ctx, s);

    try testing.expectEqual(@as(f32, 0.0), v[0]); // flop-blocked → masked to zero
    try testing.expect(v[1] != 0.0); // live hand gets a real value
}

test "allInEvalTurn: zero opponent reach yields zero values" {
    const alloc = std.testing.allocator;
    const flop = [_]card.Card{ card.makeCard(12, 0), card.makeCard(8, 1), card.makeCard(5, 2) };
    const hands = try testHands();

    var env = try TestEnv.init(alloc, flop, &hands, &hands);
    defer env.deinit();

    const reach_opp = [_]f32{ 0.0, 0.0, 0.0 };
    var v: [3]f32 = undefined;
    const s = try makeScratch(alloc, 3, 3);
    defer freeScratch(alloc, s);

    const ctx = env.ctx(100.0, 50.0, 25.0);
    allInEvalTurn(&v, &reach_opp, 3, ctx, s);

    for (0..3) |i| try testing.expectEqual(@as(f32, 0.0), v[i]);
}
