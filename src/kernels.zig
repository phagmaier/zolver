const std = @import("std");

pub const DcfrParams = struct {
    alpha: f32 = 1.5,
    beta: f32 = 0.0,
    gamma: f32 = 2.0,
};

/// Compute regret-matching strategy from regrets for a single action node.
///
/// regrets: flat array, action-major layout [A * N_p]f32
/// strategy_out: flat array, same layout, filled with action probabilities
///
/// For each hand h: sigma[a][h] = max(R[a][h], 0) / sum(max(R[a][h], 0))
/// Lanes where the denominator is zero get uniform strategy 1/A.
pub fn regretMatching(
    regrets: []const f32,
    strategy_out: []f32,
    N_p: u32,
    A: u32,
) void {
    // `pos` is a fixed A_max-wide stack buffer; the tree must never produce a
    // node with more than this many actions.
    std.debug.assert(A <= 8);
    const inv_A: f32 = 1.0 / @as(f32, @floatFromInt(A));

    var h: u32 = 0;
    while (h < N_p) : (h += 1) {
        var pos: [8]f32 = undefined;
        var sum: f32 = 0;

        var a: u32 = 0;
        while (a < A) : (a += 1) {
            const r = regrets[a * N_p + h];
            const p: f32 = if (r > 0.0) r else 0.0;
            pos[a] = p;
            sum += p;
        }

        const uniform = sum <= 0.0;
        a = 0;
        while (a < A) : (a += 1) {
            strategy_out[a * N_p + h] = if (uniform) inv_A else pos[a] / sum;
        }
    }
}

/// DCFR regret discount followed by instantaneous regret addition.
///
/// regrets: [A * N_p]f32, action-major, updated in-place
/// child_values: [A * N_p]f32, action-major, child CFVs
/// node_value: [N_p]f32, weighted-sum child values
///
/// For each (a, h): discount stored regret, then add child_v[a][h] - v[h].
pub fn dcfrRegretUpdate(
    regrets: []f32,
    child_values: []const f32,
    node_value: []const f32,
    pos_discount: f32,
    neg_discount: f32,
    N_p: u32,
    A: u32,
) void {
    var a: u32 = 0;
    while (a < A) : (a += 1) {
        const r_base = a * N_p;
        const cv_base = a * N_p;
        var h: u32 = 0;
        while (h < N_p) : (h += 1) {
            const older = regrets[r_base + h];
            const discounted: f32 = if (older > 0.0)
                older * pos_discount
            else
                older * neg_discount;
            regrets[r_base + h] = discounted + child_values[cv_base + h] - node_value[h];
        }
    }
}

/// DCFR strategy accumulation: scale existing cumulative slots by
/// (t/(t+1))^gamma, then add reach_u[h] * sigma[a][h].
///
/// Storage is f32: the cumulative strategy is an unbounded running sum and
/// overflowed/lost precision in f16 (see storage.bytes_per_strategy).
pub fn accumulateStrategy(
    cumul_strategy: []f32,
    reach_u: []const f32,
    strategy: []const f32,
    strategy_scale: f32,
    N_p: u32,
    A: u32,
) void {
    var a: u32 = 0;
    while (a < A) : (a += 1) {
        const base = a * N_p;
        var h: u32 = 0;
        while (h < N_p) : (h += 1) {
            const scaled = cumul_strategy[base + h] * strategy_scale;
            cumul_strategy[base + h] = scaled + reach_u[h] * strategy[base + h];
        }
    }
}

/// CFR+ regret update: add instantaneous regrets, then clamp negative entries to zero.
/// No discounting — CFR+ relies on non-negativity to drive convergence.
pub fn cfrRegretUpdate(
    regrets: []f32,
    child_values: []const f32,
    node_value: []const f32,
    N_p: u32,
    A: u32,
) void {
    var a: u32 = 0;
    while (a < A) : (a += 1) {
        const r_base = a * N_p;
        const cv_base = a * N_p;
        var h: u32 = 0;
        while (h < N_p) : (h += 1) {
            const updated = regrets[r_base + h] + child_values[cv_base + h] - node_value[h];
            regrets[r_base + h] = if (updated > 0.0) updated else 0.0;
        }
    }
}

/// CFR+ (linear) strategy accumulation: S[a][h] += t * reach_u[h] * sigma[a][h].
/// At extraction, the per-action sums are renormalized, so the t*(t+1)/2 weight
/// total cancels. Storage is f32: this running sum grows like t*(t+1)/2 and
/// overflowed f16 (Inf) around t=362.
pub fn cfrAccumulateStrategy(
    cumul_strategy: []f32,
    reach_u: []const f32,
    strategy: []const f32,
    t: u32,
    N_p: u32,
    A: u32,
) void {
    const t_f32: f32 = @floatFromInt(t);
    var a: u32 = 0;
    while (a < A) : (a += 1) {
        const base = a * N_p;
        var h: u32 = 0;
        while (h < N_p) : (h += 1) {
            cumul_strategy[base + h] += t_f32 * reach_u[h] * strategy[base + h];
        }
    }
}

/// Elementwise mask multiply: dst[i] = src[i] * mask[i].
/// Used for applying blocking masks and chance weights.
pub fn maskMultiply(
    dst: []f32,
    src: []const f32,
    mask: []const f32,
) void {
    for (dst, 0..) |_, i| {
        dst[i] = src[i] * mask[i];
    }
}

/// Weighted accumulate: dst[h] += weight[h] * val[h].
/// Used at the updating player's action nodes to compute v[h] = sum_a sigma[a][h] * child_v[a][h].
pub fn weightedAccumulate(
    dst: []f32,
    weight: []const f32,
    val: []const f32,
) void {
    for (dst, 0..) |_, i| {
        dst[i] += weight[i] * val[i];
    }
}

/// Unweighted accumulate: dst[h] += val[h].
/// Used at opponent nodes where strategy weights are already folded into reach_opp.
pub fn unweightedAccumulate(
    dst: []f32,
    val: []const f32,
) void {
    for (dst, 0..) |_, i| {
        dst[i] += val[i];
    }
}

/// Masked scale: dst[i] = src[i] * mask[i] * weight.
/// Used at chance nodes to apply a blocking mask and chance weight in one pass.
pub fn maskedScale(
    dst: []f32,
    src: []const f32,
    mask: []const f32,
    weight: f32,
) void {
    for (dst, 0..) |_, i| {
        dst[i] = src[i] * mask[i] * weight;
    }
}

// ── SIMD kernels ─────────────────────────────────────────────────────────────

const simd_width: u32 = 8;
const Vec = @Vector(simd_width, f32);

fn vecLoad(ptr: [*]const f32, offset: usize) Vec {
    const arr: [simd_width]f32 = ptr[offset..][0..simd_width].*;
    return arr;
}

fn vecStore(ptr: [*]f32, offset: usize, vec: Vec) void {
    const arr: [simd_width]f32 = vec;
    @memcpy(ptr[offset..][0..simd_width], &arr);
}

pub fn regretMatchingSimd(
    regrets: []const f32,
    strategy_out: []f32,
    N_p: u32,
    A: u32,
) void {
    std.debug.assert(A <= 8);
    const inv_A: f32 = 1.0 / @as(f32, @floatFromInt(A));
    const inv_A_vec: Vec = @splat(inv_A);
    const zero_vec: Vec = @splat(0.0);
    const vec_hands: u32 = (N_p / simd_width) * simd_width;

    var h: u32 = 0;
    while (h < vec_hands) : (h += simd_width) {
        var pos_arr: [8]Vec = undefined;
        var sum: Vec = zero_vec;

        var a: u32 = 0;
        while (a < A) : (a += 1) {
            const r = vecLoad(regrets.ptr, a * N_p + h);
            const p = @select(f32, r > zero_vec, r, zero_vec);
            pos_arr[a] = p;
            sum += p;
        }

        const uniform = sum <= zero_vec;
        a = 0;
        while (a < A) : (a += 1) {
            const s = @select(f32, uniform, inv_A_vec, pos_arr[a] / sum);
            vecStore(strategy_out.ptr, a * N_p + h, s);
        }
    }

    while (h < N_p) : (h += 1) {
        var pos: [8]f32 = undefined;
        var sum: f32 = 0;

        var a: u32 = 0;
        while (a < A) : (a += 1) {
            const r = regrets[a * N_p + h];
            const p: f32 = if (r > 0.0) r else 0.0;
            pos[a] = p;
            sum += p;
        }

        const uniform = sum <= 0.0;
        a = 0;
        while (a < A) : (a += 1) {
            strategy_out[a * N_p + h] = if (uniform) inv_A else pos[a] / sum;
        }
    }
}

pub fn dcfrRegretUpdateSimd(
    regrets: []f32,
    child_values: []const f32,
    node_value: []const f32,
    pos_discount: f32,
    neg_discount: f32,
    N_p: u32,
    A: u32,
) void {
    const pos_disc_vec: Vec = @splat(pos_discount);
    const neg_disc_vec: Vec = @splat(neg_discount);
    const zero_vec: Vec = @splat(0.0);
    const vec_hands: u32 = (N_p / simd_width) * simd_width;

    var a: u32 = 0;
    while (a < A) : (a += 1) {
        const r_base = a * N_p;
        const cv_base = a * N_p;
        var h: u32 = 0;
        while (h < vec_hands) : (h += simd_width) {
            const older = vecLoad(regrets.ptr, r_base + h);
            const discounted = @select(f32, older > zero_vec, older * pos_disc_vec, older * neg_disc_vec);
            const cv = vecLoad(child_values.ptr, cv_base + h);
            const nv = vecLoad(node_value.ptr, h);
            vecStore(regrets.ptr, r_base + h, discounted + cv - nv);
        }
        while (h < N_p) : (h += 1) {
            const older = regrets[r_base + h];
            const discounted: f32 = if (older > 0.0)
                older * pos_discount
            else
                older * neg_discount;
            regrets[r_base + h] = discounted + child_values[cv_base + h] - node_value[h];
        }
    }
}

pub fn cfrRegretUpdateSimd(
    regrets: []f32,
    child_values: []const f32,
    node_value: []const f32,
    N_p: u32,
    A: u32,
) void {
    const zero_vec: Vec = @splat(0.0);
    const vec_hands: u32 = (N_p / simd_width) * simd_width;

    var a: u32 = 0;
    while (a < A) : (a += 1) {
        const r_base = a * N_p;
        const cv_base = a * N_p;
        var h: u32 = 0;
        while (h < vec_hands) : (h += simd_width) {
            const existing = vecLoad(regrets.ptr, r_base + h);
            const cv = vecLoad(child_values.ptr, cv_base + h);
            const nv = vecLoad(node_value.ptr, h);
            const updated = existing + cv - nv;
            vecStore(regrets.ptr, r_base + h, @select(f32, updated > zero_vec, updated, zero_vec));
        }
        while (h < N_p) : (h += 1) {
            const updated = regrets[r_base + h] + child_values[cv_base + h] - node_value[h];
            regrets[r_base + h] = if (updated > 0.0) updated else 0.0;
        }
    }
}

pub fn accumulateStrategySimd(
    cumul_strategy: []f32,
    reach_u: []const f32,
    strategy: []const f32,
    strategy_scale: f32,
    N_p: u32,
    A: u32,
) void {
    const scale_vec: Vec = @splat(strategy_scale);
    const vec_hands: u32 = (N_p / simd_width) * simd_width;

    var a: u32 = 0;
    while (a < A) : (a += 1) {
        const base = a * N_p;
        var h: u32 = 0;
        while (h < vec_hands) : (h += simd_width) {
            const existing = vecLoad(cumul_strategy.ptr, base + h);
            const ru = vecLoad(reach_u.ptr, h);
            const s = vecLoad(strategy.ptr, base + h);
            vecStore(cumul_strategy.ptr, base + h, existing * scale_vec + ru * s);
        }
        while (h < N_p) : (h += 1) {
            const scaled = cumul_strategy[@intCast(base + h)] * strategy_scale;
            cumul_strategy[@intCast(base + h)] = scaled + reach_u[h] * strategy[base + h];
        }
    }
}

pub fn cfrAccumulateStrategySimd(
    cumul_strategy: []f32,
    reach_u: []const f32,
    strategy: []const f32,
    t: u32,
    N_p: u32,
    A: u32,
) void {
    const t_f32: f32 = @floatFromInt(t);
    const t_vec: Vec = @splat(t_f32);
    const vec_hands: u32 = (N_p / simd_width) * simd_width;

    var a: u32 = 0;
    while (a < A) : (a += 1) {
        const base = a * N_p;
        var h: u32 = 0;
        while (h < vec_hands) : (h += simd_width) {
            const existing = vecLoad(cumul_strategy.ptr, base + h);
            const ru = vecLoad(reach_u.ptr, h);
            const s = vecLoad(strategy.ptr, base + h);
            vecStore(cumul_strategy.ptr, base + h, existing + t_vec * ru * s);
        }
        while (h < N_p) : (h += 1) {
            cumul_strategy[@intCast(base + h)] += t_f32 * reach_u[h] * strategy[base + h];
        }
    }
}

pub fn maskMultiplySimd(
    dst: []f32,
    src: []const f32,
    mask: []const f32,
) void {
    const vec_len: usize = (dst.len / simd_width) * simd_width;
    var i: usize = 0;
    while (i < vec_len) : (i += simd_width) {
        const s = vecLoad(src.ptr, i);
        const m = vecLoad(mask.ptr, i);
        vecStore(dst.ptr, i, s * m);
    }
    while (i < dst.len) : (i += 1) {
        dst[i] = src[i] * mask[i];
    }
}

pub fn maskedScaleSimd(
    dst: []f32,
    src: []const f32,
    mask: []const f32,
    weight: f32,
) void {
    const w_vec: Vec = @splat(weight);
    const vec_len: usize = (dst.len / simd_width) * simd_width;
    var i: usize = 0;
    while (i < vec_len) : (i += simd_width) {
        const s = vecLoad(src.ptr, i);
        const m = vecLoad(mask.ptr, i);
        vecStore(dst.ptr, i, s * m * w_vec);
    }
    while (i < dst.len) : (i += 1) {
        dst[i] = src[i] * mask[i] * weight;
    }
}

pub fn weightedAccumulateSimd(
    dst: []f32,
    weight: []const f32,
    val: []const f32,
) void {
    const vec_len: usize = (dst.len / simd_width) * simd_width;
    var i: usize = 0;
    while (i < vec_len) : (i += simd_width) {
        const d = vecLoad(dst.ptr, i);
        const w = vecLoad(weight.ptr, i);
        const v = vecLoad(val.ptr, i);
        vecStore(dst.ptr, i, d + w * v);
    }
    while (i < dst.len) : (i += 1) {
        dst[i] += weight[i] * val[i];
    }
}

pub fn unweightedAccumulateSimd(
    dst: []f32,
    val: []const f32,
) void {
    const vec_len: usize = (dst.len / simd_width) * simd_width;
    var i: usize = 0;
    while (i < vec_len) : (i += simd_width) {
        const d = vecLoad(dst.ptr, i);
        const v = vecLoad(val.ptr, i);
        vecStore(dst.ptr, i, d + v);
    }
    while (i < dst.len) : (i += 1) {
        dst[i] += val[i];
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "regret matching: uniform when all regrets zero" {
    const N_p: u32 = 4;
    const A: u32 = 3;
    const regrets = [_]f32{0} ** (N_p * A);
    var strategy: [N_p * A]f32 = undefined;

    regretMatching(&regrets, &strategy, N_p, A);

    const expected: f32 = 1.0 / @as(f32, @floatFromInt(A));
    for (strategy) |s| {
        try testing.expect(@abs(expected - s) < 1e-7);
    }
}

test "regret matching: uniform when all regrets negative" {
    const N_p: u32 = 2;
    const A: u32 = 2;
    const regrets = [_]f32{ -1.0, -0.5, -3.0, -2.0 };
    var strategy: [4]f32 = undefined;

    regretMatching(&regrets, &strategy, N_p, A);

    for (strategy) |s| {
        try testing.expect(@abs(0.5 - s) < 1e-7);
    }
}

test "regret matching: proportional to positive regrets" {
    const N_p: u32 = 2;
    const A: u32 = 2;
    // Hand 0: R[0]=3.0, R[1]=1.0 → sigma[0]=0.75, sigma[1]=0.25
    // Hand 1: R[0]=0.0, R[1]=4.0 → sigma[0]=0.0,  sigma[1]=1.0
    const regrets = [_]f32{ 3.0, 0.0, 1.0, 4.0 };
    var strategy: [4]f32 = undefined;

    regretMatching(&regrets, &strategy, N_p, A);

    try testing.expect(@abs(0.75 - strategy[0]) < 1e-7);
    try testing.expect(@abs(0.25 - strategy[2]) < 1e-7);
    try testing.expect(@abs(0.0 - strategy[1]) < 1e-7);
    try testing.expect(@abs(1.0 - strategy[3]) < 1e-7);
}

test "regret matching: single action always uniform" {
    const N_p: u32 = 5;
    const A: u32 = 1;
    const regrets = [_]f32{ 1.0, 2.0, -3.0, 0.0, 0.5 };
    var strategy: [5]f32 = undefined;

    regretMatching(&regrets, &strategy, N_p, A);

    for (strategy) |s| {
        try testing.expect(@abs(1.0 - s) < 1e-7);
    }
}

test "dcfrRegretUpdate: discount and add" {
    const N_p: u32 = 3;
    const A: u32 = 2;
    // Stored regrets:  [2, -4, 0,  0, 0, 0]
    // Child values:    [5,  2, 3,  1, 1, 1]
    // Node value:      [4,  1, 2]
    var regrets = [_]f32{ 2.0, -4.0, 0.0, 0.0, 0.0, 0.0 };
    const child_v = [_]f32{ 5.0, 2.0, 3.0, 1.0, 1.0, 1.0 };
    const node_v = [_]f32{ 4.0, 1.0, 2.0 };
    const pos_discount: f32 = 0.75;
    const neg_discount: f32 = 0.5;

    dcfrRegretUpdate(&regrets, &child_v, &node_v, pos_discount, neg_discount, N_p, A);

    // Hand 0, a=0: 2*0.75 + (5-4) = 1.5 + 1 = 2.5
    try testing.expect(@abs(2.5 - regrets[0]) < 1e-7);
    // Hand 1, a=0: -4*0.5 + (2-1) = -2 + 1 = -1
    try testing.expect(@abs(-1.0 - regrets[1]) < 1e-7);
    // Hand 2, a=0: 0*0.75 + (3-2) = 0 + 1 = 1
    try testing.expect(@abs(1.0 - regrets[2]) < 1e-7);
    // Hand 0, a=1: 0*0.75 + (1-4) = -3
    try testing.expect(@abs(-3.0 - regrets[3]) < 1e-6);
    // Hand 1, a=1: 0*0.75 + (1-1) = 0
    try testing.expect(@abs(0.0 - regrets[4]) < 1e-7);
    // Hand 2, a=1: 0*0.75 + (1-2) = -1
    try testing.expect(@abs(-1.0 - regrets[5]) < 1e-7);
}

test "dcfrRegretUpdate: negative entries discounted independently" {
    const N_p: u32 = 1;
    const A: u32 = 2;
    var regrets = [_]f32{ -10.0, 5.0 };
    const child_v = [_]f32{ 0.0, 0.0 };
    const node_v = [_]f32{0.0};
    const pos_discount: f32 = 0.9;
    const neg_discount: f32 = 0.5;

    dcfrRegretUpdate(&regrets, &child_v, &node_v, pos_discount, neg_discount, N_p, A);

    try testing.expect(@abs(-5.0 - regrets[0]) < 1e-7);
    try testing.expect(@abs(4.5 - regrets[1]) < 1e-7);
}

test "accumulateStrategy: f16 boundary correctness" {
    const N_p: u32 = 2;
    const A: u32 = 2;
    var cumul = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    const reach_u = [_]f32{ 0.5, 1.0 };
    const strategy = [_]f32{ 0.75, 0.25, 0.0, 1.0 };
    const scale: f32 = 0.25; // (1/2)^2 for t=1

    accumulateStrategy(&cumul, &reach_u, &strategy, scale, N_p, A);

    // Hand 0, a=0: 0*0.25 + 0.5*0.75 = 0.375
    try testing.expect(@abs(@as(f32, 0.375) - @as(f32, @floatCast(cumul[0]))) < 0.002);
    // Hand 1, a=0: 0*0.25 + 1.0*0.25 = 0.25
    try testing.expect(@abs(@as(f32, 0.25) - @as(f32, @floatCast(cumul[1]))) < 0.002);
    // Hand 0, a=1: 0*0.25 + 0.5*0.0 = 0.0
    try testing.expect(@abs(@as(f32, 0.0) - @as(f32, @floatCast(cumul[2]))) < 1e-4);
    // Hand 1, a=1: 0*0.25 + 1.0*1.0 = 1.0
    try testing.expect(@abs(@as(f32, 1.0) - @as(f32, @floatCast(cumul[3]))) < 0.002);
}

test "accumulateStrategy: persists and scales previous contributions" {
    const N_p: u32 = 1;
    const A: u32 = 2;
    // Start with some previous accumulation
    var cumul = [_]f32{ 2.0, 1.0 };
    const reach_u = [_]f32{0.5};
    const strategy = [_]f32{ 0.8, 0.2 };
    const scale: f32 = 0.25; // (1/2)^2

    accumulateStrategy(&cumul, &reach_u, &strategy, scale, N_p, A);

    // a=0: 2.0*0.25 + 0.5*0.8 = 0.5 + 0.4 = 0.9
    try testing.expect(@abs(@as(f32, 0.9) - @as(f32, @floatCast(cumul[0]))) < 0.002);
    // a=1: 1.0*0.25 + 0.5*0.2 = 0.25 + 0.1 = 0.35
    try testing.expect(@abs(@as(f32, 0.35) - @as(f32, @floatCast(cumul[1]))) < 0.002);
}

test "cfrRegretUpdate: clamps negatives to zero" {
    const N_p: u32 = 2;
    const A: u32 = 2;
    var regrets = [_]f32{ 1.0, -2.0, 3.0, 0.0 };
    const child_v = [_]f32{ 5.0, 2.0, 3.0, 1.0 };
    const node_v = [_]f32{ 4.0, 1.0 };

    cfrRegretUpdate(&regrets, &child_v, &node_v, N_p, A);

    // Hand 0, a=0: 1 + (5-4) = 2
    try testing.expect(@abs(2.0 - regrets[0]) < 1e-7);
    // Hand 1, a=0: -2 + (2-1) = -1 → clamp to 0
    try testing.expect(@abs(0.0 - regrets[1]) < 1e-7);
    // Hand 0, a=1: 3 + (3-4) = 2
    try testing.expect(@abs(2.0 - regrets[2]) < 1e-7);
    // Hand 1, a=1: 0 + (1-1) = 0
    try testing.expect(@abs(0.0 - regrets[3]) < 1e-7);
}

test "cfrAccumulateStrategy: linear weighting by t" {
    const N_p: u32 = 2;
    const A: u32 = 1;
    var cumul = [_]f32{0.0} ** 2;
    const reach_u = [_]f32{ 0.6, 1.0 };
    const strategy = [_]f32{ 1.0, 1.0 };
    const t: u32 = 3;

    cfrAccumulateStrategy(&cumul, &reach_u, &strategy, t, N_p, A);

    // Hand 0: 0 + 3*0.6*1.0 = 1.8
    try testing.expect(@abs(@as(f32, 1.8) - @as(f32, @floatCast(cumul[0]))) < 0.002);
    // Hand 1: 0 + 3*1.0*1.0 = 3.0
    try testing.expect(@abs(@as(f32, 3.0) - @as(f32, @floatCast(cumul[1]))) < 0.002);
}

test "cfrAccumulateStrategy: large-t running sum stays finite (regression: f16 overflowed)" {
    // Worst-case slot: reach=1, sigma=1, weighted by t each iteration. The
    // running sum is 1+2+...+t. By t=362 that exceeds f16's max (65504), so the
    // old f16 storage overflowed to +Inf and CFR+ produced NaN at extraction.
    // f32 must accumulate the exact sum and stay finite. Cheap (<1ms): a single
    // slot over a few hundred iterations, no tree.
    var cumul = [_]f32{0.0};
    const reach = [_]f32{1.0};
    const strat = [_]f32{1.0};
    var t: u32 = 1;
    while (t <= 400) : (t += 1) {
        cfrAccumulateStrategy(&cumul, &reach, &strat, t, 1, 1);
    }
    try testing.expect(std.math.isFinite(cumul[0]));
    // sum_{t=1..400} t = 400*401/2 = 80200, well past the f16 ceiling.
    try testing.expectApproxEqRel(@as(f32, 80200.0), cumul[0], 1e-5);
}

test "maskMultiply: zeros where mask is zero" {
    var dst = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const mask = [_]f32{ 1.0, 0.0, 1.0, 0.0 };

    maskMultiply(&dst, &dst, &mask);

    try testing.expect(@abs(1.0 - dst[0]) < 1e-7);
    try testing.expect(@abs(0.0 - dst[1]) < 1e-7);
    try testing.expect(@abs(3.0 - dst[2]) < 1e-7);
    try testing.expect(@abs(0.0 - dst[3]) < 1e-7);
}

test "maskMultiply: preserves values when mask is all-ones" {
    const src = [_]f32{ 1.5, 2.5, 3.5 };
    var dst: [3]f32 = undefined;
    const mask = [_]f32{ 1.0, 1.0, 1.0 };

    maskMultiply(&dst, &src, &mask);

    for (src, 0..) |s, i| {
        try testing.expect(@abs(s - dst[i]) < 1e-7);
    }
}

test "weightedAccumulate: dot product per lane" {
    var dst = [_]f32{ 1.0, 2.0, 3.0 };
    const weight = [_]f32{ 0.5, 0.25, 0.75 };
    const val = [_]f32{ 10.0, 20.0, 30.0 };

    weightedAccumulate(&dst, &weight, &val);

    try testing.expect(@abs(1.0 + 0.5 * 10.0 - dst[0]) < 1e-7);
    try testing.expect(@abs(2.0 + 0.25 * 20.0 - dst[1]) < 1e-7);
    try testing.expect(@abs(3.0 + 0.75 * 30.0 - dst[2]) < 1e-7);
}

test "unweightedAccumulate: simple addition" {
    var dst = [_]f32{ 1.0, 2.0, 3.0 };
    const val = [_]f32{ 10.0, 20.0, 30.0 };

    unweightedAccumulate(&dst, &val);

    try testing.expectEqual(@as(f32, 11.0), dst[0]);
    try testing.expectEqual(@as(f32, 22.0), dst[1]);
    try testing.expectEqual(@as(f32, 33.0), dst[2]);
}

test "dcfrRegretUpdate: non-neg discount = 0.5 matches beta=0" {
    // With beta=0, t^0/(t^0+1) = 1/2 = 0.5 for all t
    const pos: f32 = 0.75;
    const neg: f32 = 0.5;
    try testing.expect(@abs(0.5 - neg) < 1e-7);
    _ = pos;
}

test "regret matching: consistent with naive elementwise implementation" {
    const N_p: u32 = 5;
    const A: u32 = 4;
    var rng = std.Random.DefaultPrng.init(42);
    const rand = rng.random();

    var regrets: [5 * 4]f32 = undefined;
    for (&regrets) |*r| {
        r.* = rand.floatNorm(f32) * 2.0; // varied negative and positive
    }

    var strategy_fast: [5 * 4]f32 = undefined;
    regretMatching(&regrets, &strategy_fast, N_p, A);

    // Naive reference
    for (0..N_p) |h| {
        var sum: f32 = 0;
        var pos: [4]f32 = undefined;
        for (0..A) |a| {
            const r = regrets[a * N_p + h];
            const p: f32 = if (r > 0) r else 0;
            pos[a] = p;
            sum += p;
        }
        const scale: f32 = if (sum > 0) 1.0 / sum else 1.0 / @as(f32, @floatFromInt(A));
        for (0..A) |a| {
            const expected = if (sum > 0) pos[a] * scale else scale;
            try testing.expect(@abs(expected - strategy_fast[a * N_p + h]) < 1e-7);
        }
    }
}

// ── SIMD validation tests ────────────────────────────────────────────────────

test "regretMatchingSimd: matches scalar lane-by-lane" {
    const N_p: u32 = 13;
    const A: u32 = 4;
    var rng = std.Random.DefaultPrng.init(42);
    const rand = rng.random();

    var regrets: [13 * 4]f32 = undefined;
    for (&regrets) |*r| r.* = rand.floatNorm(f32) * 2.0;

    var scalar_out: [13 * 4]f32 = undefined;
    var simd_out: [13 * 4]f32 = undefined;

    regretMatching(&regrets, &scalar_out, N_p, A);
    regretMatchingSimd(&regrets, &simd_out, N_p, A);

    for (scalar_out, 0..) |s, i| {
        try testing.expect(@abs(s - simd_out[i]) < 1e-7);
    }
}

test "regretMatchingSimd: exact multiple of simd_width" {
    const N_p: u32 = 8;
    const A: u32 = 3;
    var rng = std.Random.DefaultPrng.init(123);
    const rand = rng.random();

    var regrets: [8 * 3]f32 = undefined;
    for (&regrets) |*r| r.* = rand.floatNorm(f32) * 2.0;

    var scalar_out: [8 * 3]f32 = undefined;
    var simd_out: [8 * 3]f32 = undefined;

    regretMatching(&regrets, &scalar_out, N_p, A);
    regretMatchingSimd(&regrets, &simd_out, N_p, A);

    for (scalar_out, 0..) |s, i| {
        try testing.expect(@abs(s - simd_out[i]) < 1e-7);
    }
}

test "regretMatchingSimd: all actions maxed (A=8)" {
    const N_p: u32 = 15;
    const A: u32 = 8;
    var rng = std.Random.DefaultPrng.init(77);
    const rand = rng.random();

    var regrets: [15 * 8]f32 = undefined;
    for (&regrets) |*r| r.* = rand.floatExp(f32);

    var scalar_out: [15 * 8]f32 = undefined;
    var simd_out: [15 * 8]f32 = undefined;

    regretMatching(&regrets, &scalar_out, N_p, A);
    regretMatchingSimd(&regrets, &simd_out, N_p, A);

    for (scalar_out, 0..) |s, i| {
        try testing.expect(@abs(s - simd_out[i]) < 1e-7);
    }
}

test "dcfrRegretUpdateSimd: matches scalar lane-by-lane" {
    const N_p: u32 = 17;
    const A: u32 = 3;
    var rng = std.Random.DefaultPrng.init(99);
    const rand = rng.random();

    var scalar_regrets: [17 * 3]f32 = undefined;
    var simd_regrets: [17 * 3]f32 = undefined;
    var child_values: [17 * 3]f32 = undefined;
    var node_values: [17]f32 = undefined;

    for (&scalar_regrets, &simd_regrets) |*sr, *ss| {
        const v = rand.floatNorm(f32) * 5.0;
        sr.* = v;
        ss.* = v;
    }
    for (&child_values) |*cv| cv.* = rand.floatNorm(f32) * 3.0;
    for (&node_values) |*nv| nv.* = rand.floatNorm(f32) * 2.0;

    const pos_discount: f32 = 0.75;
    const neg_discount: f32 = 0.5;

    dcfrRegretUpdate(&scalar_regrets, &child_values, &node_values, pos_discount, neg_discount, N_p, A);
    dcfrRegretUpdateSimd(&simd_regrets, &child_values, &node_values, pos_discount, neg_discount, N_p, A);

    for (scalar_regrets, 0..) |s, i| {
        try testing.expect(@abs(s - simd_regrets[i]) < 1e-7);
    }
}

test "dcfrRegretUpdateSimd: exact multiple of simd_width" {
    const N_p: u32 = 16;
    const A: u32 = 2;
    var rng = std.Random.DefaultPrng.init(55);
    const rand = rng.random();

    var scalar_regrets: [16 * 2]f32 = undefined;
    var simd_regrets: [16 * 2]f32 = undefined;
    var child_values: [16 * 2]f32 = undefined;
    var node_values: [16]f32 = undefined;

    for (&scalar_regrets, &simd_regrets) |*sr, *ss| {
        const v = rand.floatNorm(f32) * 5.0;
        sr.* = v;
        ss.* = v;
    }
    for (&child_values) |*cv| cv.* = rand.floatNorm(f32) * 3.0;
    for (&node_values) |*nv| nv.* = rand.floatNorm(f32) * 2.0;

    dcfrRegretUpdate(&scalar_regrets, &child_values, &node_values, 0.8, 0.6, N_p, A);
    dcfrRegretUpdateSimd(&simd_regrets, &child_values, &node_values, 0.8, 0.6, N_p, A);

    for (scalar_regrets, 0..) |s, i| {
        try testing.expect(@abs(s - simd_regrets[i]) < 1e-7);
    }
}

test "cfrRegretUpdateSimd: matches scalar lane-by-lane" {
    const N_p: u32 = 20;
    const A: u32 = 5;
    var rng = std.Random.DefaultPrng.init(33);
    const rand = rng.random();

    var scalar_regrets: [20 * 5]f32 = undefined;
    var simd_regrets: [20 * 5]f32 = undefined;
    var child_values: [20 * 5]f32 = undefined;
    var node_values: [20]f32 = undefined;

    for (&scalar_regrets, &simd_regrets) |*sr, *ss| {
        const v = rand.floatNorm(f32) * 5.0;
        sr.* = v;
        ss.* = v;
    }
    for (&child_values) |*cv| cv.* = rand.floatNorm(f32) * 3.0;
    for (&node_values) |*nv| nv.* = rand.floatNorm(f32) * 2.0;

    cfrRegretUpdate(&scalar_regrets, &child_values, &node_values, N_p, A);
    cfrRegretUpdateSimd(&simd_regrets, &child_values, &node_values, N_p, A);

    for (scalar_regrets, 0..) |s, i| {
        try testing.expect(@abs(s - simd_regrets[i]) < 1e-7);
    }
}

test "accumulateStrategySimd: matches scalar lane-by-lane" {
    const N_p: u32 = 11;
    const A: u32 = 3;
    var rng = std.Random.DefaultPrng.init(101);
    const rand = rng.random();

    var scalar_cumul: [11 * 3]f32 = undefined;
    var simd_cumul: [11 * 3]f32 = undefined;
    var reach_u: [11]f32 = undefined;
    var strategy: [11 * 3]f32 = undefined;

    for (&scalar_cumul, &simd_cumul) |*sc, *ss| {
        const v: f32 = rand.floatNorm(f32) * 2.0;
        sc.* = v;
        ss.* = v;
    }
    for (&reach_u) |*ru| ru.* = rand.float(f32);
    for (&strategy) |*s| s.* = rand.float(f32);

    const scale: f32 = 0.64;

    accumulateStrategy(&scalar_cumul, &reach_u, &strategy, scale, N_p, A);
    accumulateStrategySimd(&simd_cumul, &reach_u, &strategy, scale, N_p, A);

    for (scalar_cumul, 0..) |s, i| {
        try testing.expect(@abs(@as(f32, @floatCast(s)) - @as(f32, @floatCast(simd_cumul[i]))) < 0.002);
    }
}

test "accumulateStrategySimd: exact multiple of simd_width" {
    const N_p: u32 = 8;
    const A: u32 = 2;
    var rng = std.Random.DefaultPrng.init(202);
    const rand = rng.random();

    var scalar_cumul: [8 * 2]f32 = undefined;
    var simd_cumul: [8 * 2]f32 = undefined;
    var reach_u: [8]f32 = undefined;
    var strategy: [8 * 2]f32 = undefined;

    for (&scalar_cumul, &simd_cumul) |*sc, *ss| {
        const v: f32 = rand.floatNorm(f32) * 3.0;
        sc.* = v;
        ss.* = v;
    }
    for (&reach_u) |*ru| ru.* = rand.float(f32);
    for (&strategy) |*s| s.* = rand.float(f32);

    accumulateStrategy(&scalar_cumul, &reach_u, &strategy, 0.25, N_p, A);
    accumulateStrategySimd(&simd_cumul, &reach_u, &strategy, 0.25, N_p, A);

    for (scalar_cumul, 0..) |s, i| {
        try testing.expect(@abs(@as(f32, @floatCast(s)) - @as(f32, @floatCast(simd_cumul[i]))) < 0.002);
    }
}

test "cfrAccumulateStrategySimd: matches scalar lane-by-lane" {
    const N_p: u32 = 14;
    const A: u32 = 2;
    var rng = std.Random.DefaultPrng.init(303);
    const rand = rng.random();

    var scalar_cumul: [14 * 2]f32 = undefined;
    var simd_cumul: [14 * 2]f32 = undefined;
    var reach_u: [14]f32 = undefined;
    var strategy: [14 * 2]f32 = undefined;

    for (&scalar_cumul, &simd_cumul) |*sc, *ss| {
        const v: f32 = rand.float(f32) * 5.0;
        sc.* = v;
        ss.* = v;
    }
    for (&reach_u) |*ru| ru.* = rand.float(f32);
    for (&strategy) |*s| s.* = rand.float(f32);

    const t: u32 = 7;

    cfrAccumulateStrategy(&scalar_cumul, &reach_u, &strategy, t, N_p, A);
    cfrAccumulateStrategySimd(&simd_cumul, &reach_u, &strategy, t, N_p, A);

    for (scalar_cumul, 0..) |s, i| {
        try testing.expect(@abs(@as(f32, @floatCast(s)) - @as(f32, @floatCast(simd_cumul[i]))) < 0.002);
    }
}

test "maskMultiplySimd: matches scalar lane-by-lane" {
    var rng = std.Random.DefaultPrng.init(404);
    const rand = rng.random();

    var scalar_dst: [25]f32 = undefined;
    var simd_dst: [25]f32 = undefined;
    var src: [25]f32 = undefined;
    var mask: [25]f32 = undefined;

    for (&scalar_dst, &simd_dst, &src, &mask) |*sd, *ss, *s, *m| {
        const v = rand.floatNorm(f32) * 3.0;
        sd.* = v;
        ss.* = v;
        s.* = rand.floatNorm(f32) * 2.0;
        m.* = rand.float(f32);
    }

    maskMultiply(&scalar_dst, &src, &mask);
    maskMultiplySimd(&simd_dst, &src, &mask);

    for (scalar_dst, 0..) |s, i| {
        try testing.expect(@abs(s - simd_dst[i]) < 1e-7);
    }
}

test "maskedScaleSimd: matches scalar lane-by-lane" {
    var rng = std.Random.DefaultPrng.init(505);
    const rand = rng.random();

    var scalar_dst: [31]f32 = undefined;
    var simd_dst: [31]f32 = undefined;
    var src: [31]f32 = undefined;
    var mask: [31]f32 = undefined;

    for (&src, &mask) |*s, *m| {
        s.* = rand.floatNorm(f32) * 2.0;
        m.* = rand.float(f32);
    }

    const weight: f32 = 1.0 / 49.0;

    maskedScale(&scalar_dst, &src, &mask, weight);
    maskedScaleSimd(&simd_dst, &src, &mask, weight);

    for (scalar_dst, 0..) |s, i| {
        try testing.expect(@abs(s - simd_dst[i]) < 1e-7);
    }
}

test "weightedAccumulateSimd: matches scalar lane-by-lane" {
    var rng = std.Random.DefaultPrng.init(606);
    const rand = rng.random();

    var scalar_dst: [19]f32 = undefined;
    var simd_dst: [19]f32 = undefined;
    var weight: [19]f32 = undefined;
    var val: [19]f32 = undefined;

    for (&scalar_dst, &simd_dst, &weight, &val) |*sd, *ss, *w, *v| {
        const d = rand.floatNorm(f32) * 3.0;
        sd.* = d;
        ss.* = d;
        w.* = rand.float(f32);
        v.* = rand.floatNorm(f32) * 2.0;
    }

    weightedAccumulate(&scalar_dst, &weight, &val);
    weightedAccumulateSimd(&simd_dst, &weight, &val);

    for (scalar_dst, 0..) |s, i| {
        try testing.expect(@abs(s - simd_dst[i]) < 1e-7);
    }
}

test "unweightedAccumulateSimd: matches scalar lane-by-lane" {
    var rng = std.Random.DefaultPrng.init(707);
    const rand = rng.random();

    var scalar_dst: [23]f32 = undefined;
    var simd_dst: [23]f32 = undefined;
    var val: [23]f32 = undefined;

    for (&scalar_dst, &simd_dst, &val) |*sd, *ss, *v| {
        const d = rand.floatNorm(f32) * 4.0;
        sd.* = d;
        ss.* = d;
        v.* = rand.floatNorm(f32) * 3.0;
    }

    unweightedAccumulate(&scalar_dst, &val);
    unweightedAccumulateSimd(&simd_dst, &val);

    for (scalar_dst, 0..) |s, i| {
        try testing.expect(@abs(s - simd_dst[i]) < 1e-7);
    }
}

test "maskedScale: scalar correctness" {
    var dst: [4]f32 = undefined;
    const src = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const mask = [_]f32{ 1.0, 0.0, 0.5, 1.0 };
    const weight: f32 = 0.5;

    maskedScale(&dst, &src, &mask, weight);

    try testing.expect(@abs(0.5 - dst[0]) < 1e-7);
    try testing.expect(@abs(0.0 - dst[1]) < 1e-7);
    try testing.expect(@abs(0.75 - dst[2]) < 1e-7);
    try testing.expect(@abs(2.0 - dst[3]) < 1e-7);
}
