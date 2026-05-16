The following is a technical blueprint for your solver's engine. We will use **Chance-Sampled CFR (CS-CFR)** and a **Late-Solving** approach for Subgame Decomposition.

---

### Part 1: Counterfactual Regret Minimization (CFR)

CFR is an iterative algorithm. It doesn't find the "best" move in one go; it plays against itself millions of times, learns from its mistakes ("regrets"), and eventually converges to a Nash Equilibrium (unexploitable play).

#### 1. The Core Variables (stored in each `Node`)
*   **Regret Sum (`R`):** For each action, how much more EV would I have gained if I had *always* picked that action instead of what I actually did?
*   **Strategy Sum (`S`):** The sum of all strategies used across all iterations. The *average* of this sum is your final "solved" strategy.

#### 2. The CFR Loop (Simplified)
For every iteration:
1.  **Traverse the Tree:** Start at the root and go down.
2.  **Calculate Current Strategy:** At each node, use the "Regret Matching" formula:
    *   If `regret > 0`, probability = `regret / sum_of_positive_regrets`.
    *   If no positive regrets, use a uniform random strategy.
3.  **Calculate Counterfactual Values (EV):** For every hand in your range, calculate the value of taking Action A vs Action B.
4.  **Update Regrets:** 
    *   `new_regret = EV(action) - EV(node_total)`
    *   Add this to your `Regret Sum`.
5.  **Update Strategy Sum:** Add the `current_strategy` (weighted by how likely you were to reach this node) to the `Strategy Sum`.

#### 3. Why it’s fast in Zig
Because you have the `Range` indices (0-1325), we can **vectorize** these calculations. Instead of doing one hand at a time, we do 1,326 hands at once using SIMD-friendly array operations.

---

### Part 2: Subgame Decomposition

This is how we avoid needing 512GB of RAM. We treat the game as two distinct solvers working together.

#### Phase A: The "Abstraction" Solve (The Trunk)
*   **Goal:** Solve the Flop.
*   **The Trick:** When the solver hits the Turn, it doesn't build a real tree. Instead, it looks at a "Static Table" or a "Cheap Evaluator" that says: *"On a J-high board, Ace-High has roughly X% equity."*
*   **Result:** You get a "good enough" Flop strategy and, crucially, you get the **Reach Probabilities** (the % chance each player has each hand) for every possible Turn card.

#### Phase B: The "Subgame" Solve (The Branches)
*   **Trigger:** The user (or the program) picks a specific Turn card (e.g., the `Ks`).
*   **The Action:** 
    1.  Start a **brand new solve**.
    2.  The "Root" of this solve is the start of the Turn.
    3.  **Input:** Use the "Reach Probabilities" we saved from the Flop solve.
    4.  **Tree:** Build a *full, high-accuracy tree* for the Turn and River. 
*   **Result:** Because this tree only covers one runout (the `Ks` Turn), it is tiny. You can solve it to extreme precision in seconds.

---

### Implementation Roadmap

#### Step 1: `cfr.zig` (The Fixed-Board Engine)
*   **Goal:** A function `runCFR(node, range1, range2, board)` that iterates 1000 times.
*   **Validation:** On a board of `As Ks Qs Js Ts`, both players should eventually realize they both have a Royal Flush and the strategy should converge to "Always Bet / Always Call."

#### Step 2: The Chance Node Enumerator
*   Update the CFR to handle `is_chance`. When it hits a chance node, it must:
    1.  Loop over all 40+ remaining cards.
    2.  Check for blockers.
    3.  Pass the updated "Reach Probs" to the next street.

#### Step 3: The Subgame Manager
*   A "Re-solver" that takes a `GameState` + `ReachProbs` and spins up a fresh CFR instance.

**Does this high-level plan align with your vision?** If so, I am ready to start on the `cfr.zig` implementation for the fixed-board scenario.
