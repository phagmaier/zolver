# Zig Poker Hand Evaluator (PHE)

A high-performance, zero-static-memory 7-card poker hand evaluator for Zig 0.16.0.

Optimized for **CFR solvers, Monte Carlo simulations, and game-tree search**, where every kilobyte of memory matters and every nanosecond of latency counts.

## 🚀 Key Improvements in v2.0

I recently refactored the evaluator to move away from large lookup tables. The results are significant:

| Metric | Legacy (v1.0) | **New (v2.0)** | Improvement |
|:---|:---|:---|:---|
| **Throughput** | ~7.38 M hands/sec | **~34 M hands/sec** | **4.6x faster** |
| **Latency** | ~135 ns/hand | **~30 ns/hand** | **4.5x faster** |
| **Static Memory** | ~384 KB | **0 bytes** | **∞ reduction** |

## Why This Implementation?

Traditional fast poker evaluators (like Cactus Kev or TwoPlusTwo) rely on massive lookup tables (ranging from ~400 KB to ~120 MB). While fast, this memory consumption is a deal-breaker for solvers maintaining massive game trees in RAM.

**PHE v2.0** uses a **direct rank-histogram analysis** with bitwise tricks:
- **Zero Static Memory**: No precomputed tables in your binary. Your solver gets its full memory back.
- **Modern Bitwise Ops**: Leverages `@clz`, `@ctz`, and bit-stripping (`x &= x - 1`) for lightning-fast classification.
- **Fisher–Yates Sampling**: Benchmark uses realistic 7-card sampling without replacement.

## Features

- **Zig 0.16.0 Native**: Uses modern Zig features like Juicy Main and `std.Io.Clock`.
- **7-Card Evaluation**: Native support for Texas Hold'em (best 5-of-7).
- **Tie-Breaker Accuracy**: Returns a `u32` strength value designed for direct integer comparison.
- **Zero Heap & Zero Static Memory**: `Evaluator` is a zero-sized struct.

## Usage

### As a Library

Add this project as a dependency in your `build.zig.zon` and import the `PokerEval` module.

```zig
const std = @import("std");
const PHE = @import("PokerEval");
const Card = PHE.Card;
const Evaluator = PHE.Evaluator;

pub fn main() !void {
    var evaluator = try Evaluator.init();
    
    // Create a 7-card hand (Royal Flush in Spades)
    // Card.makeCard(rank, suit) where rank 0-12, suit 0-3
    const hand = [7]u32{
        Card.makeCard(12, 0), // Ace of Spades
        Card.makeCard(11, 0), // King of Spades
        Card.makeCard(10, 0), // Queen of Spades
        Card.makeCard(9, 0),  // Jack of Spades
        Card.makeCard(8, 0),  // Ten of Spades
        Card.makeCard(2, 1),  // Four of Hearts
        Card.makeCard(3, 2),  // Five of Clubs
    };
    
    const strength = evaluator.handStrength(hand);
    
    // Higher values = better hands
    std.debug.print("Hand strength: 0x{X}\n", .{strength});
}
```

### Build & Run

```bash
# Run the benchmark
zig build run -Doptimize=ReleaseFast

# Run the test suite
zig build test
```

## Technical Details

### Hand Strength Encoding

The returned `u32` strength is `(category << 26) | tiebreaker`.
- **Categories**: High Card (1) ... Straight Flush (9).
- **Tiebreakers**: Byte-identical to legacy layouts, ensuring compatibility with downstream code.

### Evaluation Strategy

1. **Flush Check**: Early exit if count ≥ 5 in any suit.
2. **Straight Check**: Match rank bitmask against hard-coded masks.
3. **Histogram Scan**: Descending scan of rank multiplicities to identify Quads, Boats, Trips, Pairs, etc.

## License

MIT
