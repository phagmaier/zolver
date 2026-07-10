//! By convention, root.zig is the root source file when making a package.
//! It re-exports every public module so consumers (and the test runner) can
//! reach them through the single `zolver` import.
const std = @import("std");

pub const card = @import("card.zig");
pub const evaluator = @import("evaluator.zig");
pub const game_tree = @import("game_tree.zig");
pub const isomorphism = @import("isomorphism.zig");
pub const range = @import("range.zig");
pub const storage = @import("storage.zig");
pub const blocking = @import("blocking.zig");
pub const showdown = @import("showdown.zig");
pub const remap = @import("remap.zig");
pub const init = @import("init.zig");
pub const kernels = @import("kernels.zig");
pub const terminal_eval = @import("terminal_eval.zig");
pub const scratch = @import("scratch.zig");
pub const cfr = @import("cfr.zig");
pub const best_response = @import("best_response.zig");
pub const threading = @import("threading.zig");
pub const extract = @import("extract.zig");
pub const invariants = @import("invariants.zig");
pub const parse = @import("parse.zig");
pub const config = @import("config.zig");
pub const output = @import("output.zig");
pub const summary = @import("summary.zig");

test {
    std.testing.refAllDecls(card);
    std.testing.refAllDecls(evaluator);
    std.testing.refAllDecls(game_tree);
    std.testing.refAllDecls(isomorphism);
    std.testing.refAllDecls(range);
    std.testing.refAllDecls(storage);
    std.testing.refAllDecls(blocking);
    std.testing.refAllDecls(showdown);
    std.testing.refAllDecls(remap);
    std.testing.refAllDecls(init);
    std.testing.refAllDecls(kernels);
    std.testing.refAllDecls(terminal_eval);
    std.testing.refAllDecls(scratch);
    std.testing.refAllDecls(cfr);
    std.testing.refAllDecls(best_response);
    std.testing.refAllDecls(threading);
    std.testing.refAllDecls(extract);
    std.testing.refAllDecls(invariants);
    std.testing.refAllDecls(parse);
    std.testing.refAllDecls(config);
    std.testing.refAllDecls(output);
    std.testing.refAllDecls(summary);
}
