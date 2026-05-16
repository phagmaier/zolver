# CFR ROADMAP
---

Since we have the `HandTable` (0-1325 indices) and the internalized `Evaluator`, we can make this loop extremely fast by pre-calculating as much as possible.

---

### Phase 1: The "Static" Environment
Before the first iteration starts, you need to prepare the "Showdown Table."
1.  **Pre-calculate Strengths:** Take the fixed 5-card board and evaluate every one of the 1,326 possible hands.
    *   Store this in a `[1326]u32` array called `hand_strengths`.
    *   This means during the CFR loop, you **never** call the evaluator again. You just compare two integers.
2.  **Blocker Check:** Identify which of the 1,326 hands are impossible because they contain a card already on the board. Zero out their initial probabilities in the `Range`.

### Phase 2: The Showdown Engine (Terminal Nodes)
This is the most mathematically intensive part. When you reach a "Fold" or "Showdown" node:
1.  **Fold:** Simple. The winner takes the pot.
2.  **Showdown:** You must calculate the EV of every hand in Player 1's range against the *entirety* of Player 2's range.
    *   **Math:** `EV(Hand_i) = Sum Over Hand_j [ Weight(Hand_j) * Result(Hand_i vs Hand_j) ]`
    *   **Optimization:** This is a nested loop (Range1 x Range2). To make it fast, you should use the pre-calculated `hand_strengths`.

### Phase 3: The CFR Walker (`src/cfr.zig`)
This is a recursive function: `fn walk(node, p1_reach, p2_reach)`.

1.  **Base Case:** If `node` is null (terminal), return the Showdown/Fold EV.
2.  **Current Strategy:** Calculate the strategy for the current player using **Regret Matching**:
    *   `strategy[action] = max(0, regret[action]) / sum(max(0, all_regrets))`
3.  **Recursion:** For each edge (action):
    *   Update the "Reach Probability" for the current player.
    *   Call `walk(child_node, new_p1_reach, new_p2_reach)`.
4.  **Regret Update:** 
    *   `node_EV = sum(strategy[a] * child_EV[a])`
    *   `regret[a] += child_EV[a] - node_EV`
5.  **Strategy Sum Update:**
    *   `strategy_sum[a] += reach_prob * strategy[a]`

### Phase 4: The Convergence Test
To know if it's working, we need to track **Exploitability**.
1.  After 100 iterations, calculate the "Best Response" (the maximum possible EV an opponent could get if they knew your current strategy).
2.  As iterations increase, the difference between your EV and the Best Response should shrink toward zero.

---

### Suggested File Structure for `src/cfr.zig`

```zig
pub const Solver = struct {
    evaluator: Evaluator,
    hand_table: HandTable,
    board: [5]Card,
    hand_strengths: [1326]u32,

    pub fn init(allocator: Allocator, board: [5]Card) !Solver {
        // 1. Init evaluator
        // 2. Pre-calculate all 1326 strengths vs this board
    }

    pub fn solve(self: *Solver, root: *Node, p1_range: *Range, p2_range: *Range, iterations: usize) !void {
        for (0..iterations) |_| {
            _ = try self.walk(root, p1_range.probs, p2_range.probs, true);
        }
    }

    fn walk(self: *Solver, node: ?*Node, p1_probs: []f32, p2_probs: []f32, isp1: bool) ![]f32 {
        // The recursive logic goes here
    }
};
```

### Why this plan is robust:
*   **Vectorization:** By passing `[]f32` (the whole range) through the `walk` function, you can use Zig's `@Vector` or simple loops that the compiler can optimize into SIMD instructions.
*   **Memory Efficiency:** Since the board is fixed, you only need to store `regrets` for the nodes in the tree. 
*   **Separation of Concerns:** The `Solver` doesn't care how the tree was built or how the cards were encoded; it just does the math.

**Does this implementation plan look good to you?** If you're ready, we can start writing the `Solver.init` and the strength pre-calculation logic in `src/cfr.zig`.
