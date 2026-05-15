const std = @import("std");

pub const Card = @import("card.zig");
pub const Evaluator = @import("evaluator.zig").Evaluator;

test "library tests" {
    std.testing.refAllDecls(@This());
}
