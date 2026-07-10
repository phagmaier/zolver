const std = @import("std");
const card = @import("card.zig");
const game_tree = @import("game_tree.zig");
const init_mod = @import("init.zig");
const cfr_mod = @import("cfr.zig");
const parse = @import("parse.zig");

const Allocator = std.mem.Allocator;
const Config = init_mod.Config;
const SolverConfig = cfr_mod.SolverConfig;
const Sizing = game_tree.Sizing;

pub const ConfigBundle = struct {
    game: Config,
    solver: SolverConfig,
    _arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ConfigBundle) void {
        self._arena.deinit();
        self.* = undefined;
    }
};

const RawValue = union(enum) {
    string: []const u8,
    integer: i64,
    float: f32,
    boolean: bool,
    int_array: []const u32,
    identifier: []const u8,
};

const KeyValue = struct {
    value: RawValue,
    line: u32,
};

const SectionStack = struct {
    parts: [4][]const u8,
    len: u8,

    fn set(self: *SectionStack, p: []const []const u8) void {
        self.len = 0;
        for (p) |part| {
            self.parts[self.len] = part;
            self.len += 1;
        }
    }

    fn key(self: SectionStack, name: []const u8, buf: []u8) []const u8 {
        var pos: usize = 0;
        for (self.parts[0..self.len]) |part| {
            @memcpy(buf[pos .. pos + part.len], part);
            pos += part.len;
            buf[pos] = '.';
            pos += 1;
        }
        @memcpy(buf[pos .. pos + name.len], name);
        pos += name.len;
        return buf[0..pos];
    }
};

/// Captures where and why config parsing failed, so the CLI can print
/// `file:line: message`. Uses an inline buffer (no allocation) because the
/// parser's arena is freed on the error path — the message must outlive it.
/// `line == 0` means the error is not tied to a specific line.
pub const Diagnostic = struct {
    line: u32 = 0,
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Diagnostic, line: u32, comptime fmt: []const u8, args: anytype) void {
        self.line = line;
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch self.buf[0..self.buf.len];
        self.len = s.len;
    }
};

/// Short human description of a value's actual type/contents, for "got ..." in
/// type-mismatch messages. `buf` backs the identifier case.
fn rawDesc(v: RawValue, buf: []u8) []const u8 {
    return switch (v) {
        .string => "a string",
        .integer => "an integer",
        .float => "a float",
        .boolean => "a boolean",
        .int_array => "an array",
        .identifier => |id| std.fmt.bufPrint(buf, "'{s}'", .{id}) catch "an identifier",
    };
}

/// Field accessors over the parsed key/value map that record a `Diagnostic` on
/// failure (line number + message). Replaces bare `expect*` errors.
const Fields = struct {
    kv: *std.StringHashMap(KeyValue),
    diag: ?*Diagnostic,

    fn missing(self: Fields, comptime key: []const u8) error{MissingRequiredField} {
        if (self.diag) |d| d.set(0, "missing required field '" ++ key ++ "'", .{});
        return error.MissingRequiredField;
    }

    fn failType(self: Fields, entry: KeyValue, comptime expected: []const u8, comptime key: []const u8) error{InvalidValue} {
        if (self.diag) |d| {
            var vbuf: [96]u8 = undefined;
            d.set(entry.line, "expected " ++ expected ++ " for '" ++ key ++ "', got {s}", .{rawDesc(entry.value, &vbuf)});
        }
        return error.InvalidValue;
    }

    fn rangeFail(self: Fields, entry: KeyValue, comptime key: []const u8, value: i64) error{InvalidValue} {
        if (self.diag) |d| d.set(entry.line, "value out of range for '" ++ key ++ "': {d}", .{value});
        return error.InvalidValue;
    }

    /// Re-raise a parser error (flop/range/sizing) with line context.
    fn parseFail(self: Fields, line: u32, comptime what: []const u8, value: []const u8, err: anyerror) anyerror {
        if (self.diag) |d| d.set(line, "invalid " ++ what ++ " '{s}': {s}", .{ value, @errorName(err) });
        return err;
    }

    fn stringField(self: Fields, comptime key: []const u8) !struct { value: []const u8, line: u32 } {
        const entry = self.kv.get(key) orelse return self.missing(key);
        switch (entry.value) {
            .string => |s| return .{ .value = s, .line = entry.line },
            else => return self.failType(entry, "string", key),
        }
    }

    fn expectString(self: Fields, comptime key: []const u8) ![]const u8 {
        return (try self.stringField(key)).value;
    }

    fn expectInt(self: Fields, comptime key: []const u8) !u32 {
        const entry = self.kv.get(key) orelse return self.missing(key);
        switch (entry.value) {
            .integer => |i| {
                if (i < 0 or i > std.math.maxInt(u32)) return self.rangeFail(entry, key, i);
                return @intCast(i);
            },
            else => return self.failType(entry, "integer", key),
        }
    }

    fn expectOptionalIntDefault(self: Fields, comptime key: []const u8, default: u32) !u32 {
        const entry = self.kv.get(key) orelse return default;
        switch (entry.value) {
            .integer => |i| {
                if (i < 0 or i > std.math.maxInt(u32)) return self.rangeFail(entry, key, i);
                return @intCast(i);
            },
            else => return self.failType(entry, "integer", key),
        }
    }

    fn expectOptionalIntDefaultU64(self: Fields, comptime key: []const u8, default: u64) !u64 {
        const entry = self.kv.get(key) orelse return default;
        switch (entry.value) {
            .integer => |i| {
                if (i < 0) return self.rangeFail(entry, key, i);
                return @intCast(i);
            },
            else => return self.failType(entry, "integer", key),
        }
    }

    fn expectOptionalU8(self: Fields, comptime key: []const u8) !?u8 {
        const entry = self.kv.get(key) orelse return null;
        switch (entry.value) {
            .integer => |i| {
                if (i < 0 or i > std.math.maxInt(u8)) return self.rangeFail(entry, key, i);
                return @intCast(i);
            },
            .identifier => |id| {
                if (std.mem.eql(u8, id, "none") or std.mem.eql(u8, id, "unlimited")) return null;
                return self.failType(entry, "an integer or none/unlimited", key);
            },
            else => return self.failType(entry, "an integer or none/unlimited", key),
        }
    }

    fn expectFloat(self: Fields, comptime key: []const u8) !f32 {
        const entry = self.kv.get(key) orelse return self.missing(key);
        switch (entry.value) {
            .float => |f| return f,
            .integer => |i| return @floatFromInt(i),
            else => return self.failType(entry, "a number", key),
        }
    }

    fn expectOptionalFloat(self: Fields, comptime key: []const u8, default: f32) !f32 {
        const entry = self.kv.get(key) orelse return default;
        switch (entry.value) {
            .float => |f| return f,
            .integer => |i| return @floatFromInt(i),
            else => return self.failType(entry, "a number", key),
        }
    }

    fn expectBool(self: Fields, comptime key: []const u8, default: bool) !bool {
        const entry = self.kv.get(key) orelse return default;
        switch (entry.value) {
            .boolean => |b| return b,
            else => return self.failType(entry, "a boolean", key),
        }
    }

    fn expectIntArray(self: Fields, comptime key: []const u8) ![]const u32 {
        const entry = self.kv.get(key) orelse return self.missing(key);
        switch (entry.value) {
            .int_array => |arr| return arr,
            else => return self.failType(entry, "an array", key),
        }
    }
};

pub fn parseConfig(parent_allocator: Allocator, content: []const u8) !ConfigBundle {
    return parseConfigDiag(parent_allocator, content, null);
}

pub fn parseConfigDiag(parent_allocator: Allocator, content: []const u8, diag: ?*Diagnostic) !ConfigBundle {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var kv: std.StringHashMap(KeyValue) = .{
        .unmanaged = .{},
        .allocator = allocator,
        .ctx = .{},
    };
    defer kv.deinit();

    var section = SectionStack{ .parts = undefined, .len = 0 };
    var key_buf: [256]u8 = undefined;

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |raw| : (line_no += 1) {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const line_num = line_no + 1;

        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse {
                if (diag) |d| d.set(line_num, "malformed section header (missing ']')", .{});
                return error.InvalidConfig;
            };
            const inner = line[1..end];
            var parts = std.mem.splitScalar(u8, inner, '.');
            var part_list: [4][]const u8 = undefined;
            var part_count: u8 = 0;
            while (parts.next()) |p| {
                const trimmed = std.mem.trim(u8, p, " \t");
                if (trimmed.len == 0) {
                    if (diag) |d| d.set(line_num, "malformed section header (empty part)", .{});
                    return error.InvalidConfig;
                }
                part_list[part_count] = trimmed;
                part_count += 1;
            }
            section.set(part_list[0..part_count]);
            continue;
        }

        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse {
            if (diag) |d| d.set(line_num, "expected 'key = value'", .{});
            return error.InvalidConfig;
        };
        const key = std.mem.trim(u8, line[0..eq_pos], " \t");
        var raw_value = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

        if (key.len == 0) {
            if (diag) |d| d.set(line_num, "missing key before '='", .{});
            return error.InvalidConfig;
        }

        // Strip inline comment
        if (std.mem.indexOfScalar(u8, raw_value, '#')) |comment_pos| {
            raw_value = raw_value[0..comment_pos];
            raw_value = std.mem.trim(u8, raw_value, " \t");
            if (raw_value.len == 0) {
                if (diag) |d| d.set(line_num, "missing value after '='", .{});
                return error.InvalidValue;
            }
        }

        const full_key = section.key(key, &key_buf);

        const value = parseValue(allocator, raw_value) catch |err| {
            if (diag) |d| d.set(line_num, "invalid value '{s}': {s}", .{ raw_value, @errorName(err) });
            return err;
        };
        const entry = KeyValue{ .value = value, .line = line_num };

        if (kv.contains(full_key)) {
            if (diag) |d| d.set(line_num, "duplicate key '{s}'", .{full_key});
            return error.DuplicateKey;
        }
        const owned_key = try allocator.dupe(u8, full_key);
        try kv.put(owned_key, entry);
    }

    return buildBundle(allocator, &kv, arena, diag);
}

fn parseValue(allocator: Allocator, s: []const u8) !RawValue {
    if (s.len == 0) return error.InvalidValue;

    if (s[0] == '"') {
        if (s.len < 2 or s[s.len - 1] != '"') return error.InvalidValue;
        return .{ .string = s[1 .. s.len - 1] };
    }

    if (s[0] == '[') {
        if (s.len < 2 or s[s.len - 1] != ']') return error.InvalidValue;
        const inner = std.mem.trim(u8, s[1 .. s.len - 1], " \t");
        if (inner.len == 0) return .{ .int_array = &.{} };

        var count: usize = 0;
        var it = std.mem.tokenizeScalar(u8, inner, ',');
        var nums: [32]u32 = undefined;

        while (it.next()) |token| : (count += 1) {
            const trimmed = std.mem.trim(u8, token, " \t");
            nums[count] = try std.fmt.parseInt(u32, trimmed, 10);
        }

        const result = try allocator.alloc(u32, count);
        @memcpy(result, nums[0..count]);
        return .{ .int_array = result };
    }

    if (std.mem.eql(u8, s, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, s, "false")) return .{ .boolean = false };

    if (std.ascii.isDigit(s[0]) or (s.len > 1 and s[0] == '-' and std.ascii.isDigit(s[1]))) {
        if (std.mem.indexOfScalar(u8, s, '.') != null) {
            const f = try std.fmt.parseFloat(f32, s);
            return .{ .float = f };
        }
        const i = try std.fmt.parseInt(i64, s, 10);
        return .{ .integer = i };
    }

    return .{ .identifier = s };
}

fn buildBundle(allocator: Allocator, kv: *std.StringHashMap(KeyValue), arena: std.heap.ArenaAllocator, diag: ?*Diagnostic) !ConfigBundle {
    const f = Fields{ .kv = kv, .diag = diag };

    const flop_field = try f.stringField("game.flop");
    const flop = parse.parseFlop(allocator, flop_field.value) catch |err|
        return f.parseFail(flop_field.line, "flop", flop_field.value, err);

    const initial_pot = try f.expectInt("game.initial_pot");
    const effective_stack = try f.expectInt("game.effective_stack");
    const min_bet = try f.expectOptionalIntDefault("game.min_bet", 1);

    const sizings_flop_pct = try f.expectIntArray("game.sizings.flop");
    const sizings_turn_pct = try f.expectIntArray("game.sizings.turn");
    const sizings_river_pct = try f.expectIntArray("game.sizings.river");

    const sizings_flop = try parse.parseSizingList(allocator, sizings_flop_pct);
    const sizings_turn = try parse.parseSizingList(allocator, sizings_turn_pct);
    const sizings_river = try parse.parseSizingList(allocator, sizings_river_pct);

    const raise_cap_flop = try f.expectOptionalU8("game.raise_cap.flop");
    const raise_cap_turn = try f.expectOptionalU8("game.raise_cap.turn");
    const raise_cap_river = try f.expectOptionalU8("game.raise_cap.river");

    const oop_field = try f.stringField("ranges.oop");
    const ip_field = try f.stringField("ranges.ip");

    const oop_range = parse.parseRange(allocator, oop_field.value) catch |err|
        return f.parseFail(oop_field.line, "oop range", oop_field.value, err);
    const ip_range = parse.parseRange(allocator, ip_field.value) catch |err|
        return f.parseFail(ip_field.line, "ip range", ip_field.value, err);

    const algo_field = try f.stringField("solver.algorithm");
    const algorithm: cfr_mod.Algorithm = if (std.mem.eql(u8, algo_field.value, "dcfr"))
        .dcfr
    else if (std.mem.eql(u8, algo_field.value, "cfr_plus"))
        .cfr_plus
    else {
        if (diag) |d| d.set(algo_field.line, "unknown algorithm '{s}' (expected 'dcfr' or 'cfr_plus')", .{algo_field.value});
        return error.InvalidValue;
    };

    const dcfr_alpha = try f.expectOptionalFloat("solver.dcfr.alpha", 1.5);
    const dcfr_beta = try f.expectOptionalFloat("solver.dcfr.beta", 0.0);
    const dcfr_gamma = try f.expectOptionalFloat("solver.dcfr.gamma", 2.0);

    const max_iterations = try f.expectOptionalIntDefault("solver.max_iterations", 1000);
    const target_exploitability_pct = try f.expectOptionalFloat("solver.target_exploitability_pct", 0.5);
    const check_interval = try f.expectOptionalIntDefault("solver.check_interval", 64);
    const stall_patience = try f.expectOptionalIntDefault("solver.stall_patience", 5);
    const stall_rel_improvement = try f.expectOptionalFloat("solver.stall_rel_improvement", 0.01);
    const num_threads = try f.expectOptionalIntDefault("solver.num_threads", 0);
    const prune_zero_reach = try f.expectBool("solver.prune_zero_reach", false);
    const use_simd = try f.expectBool("solver.use_simd", true);
    const debug_invariants = try f.expectBool("solver.debug_invariants", @import("builtin").mode == .Debug);

    const max_budget_bytes = try f.expectOptionalIntDefaultU64("game.max_budget_bytes", 8 * 1024 * 1024 * 1024);
    const compress_suits = try f.expectBool("game.compress_suits", true);

    const game = Config{
        .flop = flop,
        .initial_pot = initial_pot,
        .effective_stack = effective_stack,
        .min_bet = min_bet,
        .sizings = .{ sizings_flop, sizings_turn, sizings_river },
        .raise_cap = .{ raise_cap_flop, raise_cap_turn, raise_cap_river },
        .oop_range = oop_range,
        .ip_range = ip_range,
        .max_budget_bytes = max_budget_bytes,
        .compress_suits = compress_suits,
    };

    const solver = SolverConfig{
        .algorithm = algorithm,
        .dcfr = .{ .alpha = dcfr_alpha, .beta = dcfr_beta, .gamma = dcfr_gamma },
        .prune_zero_reach = prune_zero_reach,
        .use_simd = use_simd,
        .max_iterations = max_iterations,
        .target_exploitability_pct = target_exploitability_pct,
        .check_interval = check_interval,
        .stall_patience = stall_patience,
        .stall_rel_improvement = stall_rel_improvement,
        .num_threads = num_threads,
        .debug_invariants = debug_invariants,
    };

    return .{ .game = game, .solver = solver, ._arena = arena };
}

test "parse minimal config string" {
    const cfg =
        \\[game]
        \\flop = "As Kd 7h"
        \\initial_pot = 100
        \\effective_stack = 200
        \\min_bet = 2
        \\
        \\[game.sizings]
        \\flop = [25, 50]
        \\turn = [25, 50]
        \\river = [25, 50]
        \\
        \\[game.raise_cap]
        \\flop = 1
        \\turn = 1
        \\river = 1
        \\
        \\[ranges]
        \\oop = "AKs, QQ:0.5"
        \\ip = "AKo:0.75"
        \\
        \\[solver]
        \\algorithm = "dcfr"
        \\max_iterations = 100
        \\num_threads = 0
    ;

    var bundle = try parseConfig(std.testing.allocator, cfg);
    defer bundle.deinit();

    try std.testing.expectEqual(@as(u32, 100), bundle.game.initial_pot);
    try std.testing.expectEqual(@as(u32, 200), bundle.game.effective_stack);
    try std.testing.expectEqual(@as(u32, 2), bundle.game.min_bet);
    try std.testing.expectEqual(@as(u32, 12), card.rankIndex(bundle.game.flop[0]));
    try std.testing.expectEqual(@as(u32, 0), card.suitIndex(bundle.game.flop[0]));

    try std.testing.expectEqual(@as(usize, 2), bundle.game.sizings[0].len);
    try std.testing.expectEqual(@as(u32, 25), bundle.game.sizings[0][0].numerator);
    try std.testing.expectEqual(@as(u32, 50), bundle.game.sizings[0][1].numerator);

    try std.testing.expectEqual(@as(?u8, 1), bundle.game.raise_cap[0]);
    try std.testing.expectEqual(@as(?u8, 1), bundle.game.raise_cap[1]);
    try std.testing.expectEqual(@as(?u8, 1), bundle.game.raise_cap[2]);

    try std.testing.expectEqual(@as(usize, 10), bundle.game.oop_range.len);
    try std.testing.expectEqual(@as(usize, 12), bundle.game.ip_range.len);

    try std.testing.expectEqual(cfr_mod.Algorithm.dcfr, bundle.solver.algorithm);
    try std.testing.expectEqual(@as(u32, 100), bundle.solver.max_iterations);
    try std.testing.expectEqual(@as(u32, 0), bundle.solver.num_threads);
    try std.testing.expect(bundle.game.compress_suits);
}

test "parse config can disable suit compression" {
    const cfg =
        \\[game]
        \\flop = "As Kd 7h"
        \\initial_pot = 100
        \\effective_stack = 200
        \\compress_suits = false
        \\[game.sizings]
        \\flop = [50]
        \\turn = [50]
        \\river = [50]
        \\[game.raise_cap]
        \\flop = 1
        \\turn = 1
        \\river = 1
        \\[ranges]
        \\oop = "AK"
        \\ip = "AK"
        \\[solver]
        \\algorithm = "dcfr"
    ;

    var bundle = try parseConfig(std.testing.allocator, cfg);
    defer bundle.deinit();
    try std.testing.expect(!bundle.game.compress_suits);
}

test "parse config with unlimited raise cap" {
    const cfg =
        \\[game]
        \\flop = "As Kd 7h"
        \\initial_pot = 100
        \\effective_stack = 200
        \\
        \\[game.sizings]
        \\flop = [25]
        \\turn = []
        \\river = [50]
        \\
        \\[game.raise_cap]
        \\flop = 1
        \\turn = none
        \\river = unlimited
        \\
        \\[ranges]
        \\oop = "AA"
        \\ip = "KK"
        \\
        \\[solver]
        \\algorithm = "cfr_plus"
    ;

    var bundle = try parseConfig(std.testing.allocator, cfg);
    defer bundle.deinit();

    try std.testing.expectEqual(@as(?u8, 1), bundle.game.raise_cap[0]);
    try std.testing.expectEqual(@as(?u8, null), bundle.game.raise_cap[1]);
    try std.testing.expectEqual(@as(?u8, null), bundle.game.raise_cap[2]);

    try std.testing.expectEqual(@as(usize, 0), bundle.game.sizings[1].len);

    try std.testing.expectEqual(cfr_mod.Algorithm.cfr_plus, bundle.solver.algorithm);
    try std.testing.expectEqual(@as(u32, 1), bundle.game.min_bet);
}

test "parse config with DCFR params and all solver options" {
    const cfg =
        \\[game]
        \\flop = "As Kd 7h"
        \\initial_pot = 500
        \\effective_stack = 1000
        \\
        \\[game.sizings]
        \\flop = [25, 50, 75]
        \\turn = [33, 66]
        \\river = [50, 100, 150]
        \\
        \\[game.raise_cap]
        \\flop = none
        \\turn = none
        \\river = none
        \\
        \\[ranges]
        \\oop = "AJo:0.75, ATo:0.12, 88:0.5"
        \\ip = "AKs:0.8, QQ:0.6, JTs:0.4"
        \\
        \\[solver]
        \\algorithm = "dcfr"
        \\max_iterations = 5000
        \\target_exploitability_pct = 0.1
        \\num_threads = 8
        \\prune_zero_reach = true
        \\use_simd = true
        \\debug_invariants = false
        \\check_interval = 32
        \\
        \\[solver.dcfr]
        \\alpha = 1.2
        \\beta = 0.5
        \\gamma = 1.8
    ;

    var bundle = try parseConfig(std.testing.allocator, cfg);
    defer bundle.deinit();

    try std.testing.expectEqual(@as(u32, 500), bundle.game.initial_pot);
    try std.testing.expectEqual(@as(u32, 1000), bundle.game.effective_stack);
    try std.testing.expectEqual(@as(u32, 1), bundle.game.min_bet);

    try std.testing.expectEqual(@as(usize, 3), bundle.game.sizings[0].len);
    try std.testing.expectEqual(@as(usize, 2), bundle.game.sizings[1].len);
    try std.testing.expectEqual(@as(usize, 3), bundle.game.sizings[2].len);

    try std.testing.expectEqual(@as(?u8, null), bundle.game.raise_cap[0]);
    try std.testing.expectEqual(@as(?u8, null), bundle.game.raise_cap[1]);
    try std.testing.expectEqual(@as(?u8, null), bundle.game.raise_cap[2]);

    try std.testing.expectEqual(@as(usize, 30), bundle.game.oop_range.len);
    try std.testing.expectEqual(@as(usize, 14), bundle.game.ip_range.len);

    try std.testing.expectEqual(cfr_mod.Algorithm.dcfr, bundle.solver.algorithm);
    try std.testing.expectEqual(@as(u32, 5000), bundle.solver.max_iterations);
    try std.testing.expectEqual(@as(f32, 0.1), bundle.solver.target_exploitability_pct);
    try std.testing.expectEqual(@as(u32, 8), bundle.solver.num_threads);
    try std.testing.expectEqual(true, bundle.solver.prune_zero_reach);
    try std.testing.expectEqual(true, bundle.solver.use_simd);
    try std.testing.expectEqual(false, bundle.solver.debug_invariants);
    try std.testing.expectEqual(@as(u32, 32), bundle.solver.check_interval);
    try std.testing.expectEqual(@as(f32, 1.2), bundle.solver.dcfr.alpha);
    try std.testing.expectEqual(@as(f32, 0.5), bundle.solver.dcfr.beta);
    try std.testing.expectEqual(@as(f32, 1.8), bundle.solver.dcfr.gamma);
}

test "parse config with defaults for optional fields" {
    const cfg =
        \\[game]
        \\flop = "2s 3h 4d"
        \\initial_pot = 50
        \\effective_stack = 100
        \\
        \\[game.sizings]
        \\flop = [50]
        \\turn = [50]
        \\river = [50]
        \\
        \\[game.raise_cap]
        \\flop = 1
        \\turn = 1
        \\river = 1
        \\
        \\[ranges]
        \\oop = "AK"
        \\ip = "AK"
        \\
        \\[solver]
        \\algorithm = "dcfr"
    ;

    var bundle = try parseConfig(std.testing.allocator, cfg);
    defer bundle.deinit();

    try std.testing.expectEqual(@as(u32, 1), bundle.game.min_bet);
    try std.testing.expectEqual(@as(u32, 1000), bundle.solver.max_iterations);
    try std.testing.expectEqual(@as(f32, 0.5), bundle.solver.target_exploitability_pct);
    try std.testing.expectEqual(@as(u32, 0), bundle.solver.num_threads);
    try std.testing.expectEqual(@as(u32, 64), bundle.solver.check_interval);
    try std.testing.expectEqual(@as(u32, 5), bundle.solver.stall_patience);
    try std.testing.expectEqual(@as(f32, 0.01), bundle.solver.stall_rel_improvement);
}

test "missing required field" {
    const cfg =
        \\[game]
        \\flop = "As Kd 7h"
        \\initial_pot = 100
    ;

    try std.testing.expectError(error.MissingRequiredField, parseConfig(std.testing.allocator, cfg));
}

test "diagnostic: type mismatch reports line, field, and value" {
    const cfg =
        \\[game]
        \\flop = "As Kd 7h"
        \\initial_pot = abc
    ;
    var diag = Diagnostic{};
    try std.testing.expectError(error.InvalidValue, parseConfigDiag(std.testing.allocator, cfg, &diag));
    try std.testing.expectEqual(@as(u32, 3), diag.line);
    try std.testing.expectEqualStrings("expected integer for 'game.initial_pot', got 'abc'", diag.message());
}

test "diagnostic: missing required field has no line" {
    const cfg =
        \\[game]
        \\flop = "As Kd 7h"
        \\initial_pot = 100
    ;
    var diag = Diagnostic{};
    try std.testing.expectError(error.MissingRequiredField, parseConfigDiag(std.testing.allocator, cfg, &diag));
    try std.testing.expectEqual(@as(u32, 0), diag.line);
    try std.testing.expectEqualStrings("missing required field 'game.effective_stack'", diag.message());
}

test "diagnostic: bad flop reports the line and the parser error" {
    const cfg =
        \\[game]
        \\flop = "As Kd"
        \\initial_pot = 100
        \\effective_stack = 200
        \\[game.sizings]
        \\flop = [50]
        \\turn = [50]
        \\river = [50]
        \\[game.raise_cap]
        \\flop = 1
        \\turn = 1
        \\river = 1
        \\[ranges]
        \\oop = "AK"
        \\ip = "AK"
        \\[solver]
        \\algorithm = "dcfr"
    ;
    var diag = Diagnostic{};
    try std.testing.expectError(error.NotEnoughFlopCards, parseConfigDiag(std.testing.allocator, cfg, &diag));
    try std.testing.expectEqual(@as(u32, 2), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message(), "invalid flop 'As Kd'") != null);
}

test "diagnostic: unknown algorithm names the offending value" {
    const cfg =
        \\[game]
        \\flop = "As Kd 7h"
        \\initial_pot = 100
        \\effective_stack = 200
        \\[game.sizings]
        \\flop = [50]
        \\turn = [50]
        \\river = [50]
        \\[game.raise_cap]
        \\flop = 1
        \\turn = 1
        \\river = 1
        \\[ranges]
        \\oop = "AK"
        \\ip = "AK"
        \\[solver]
        \\algorithm = "monte_carlo"
    ;
    var diag = Diagnostic{};
    try std.testing.expectError(error.InvalidValue, parseConfigDiag(std.testing.allocator, cfg, &diag));
    try std.testing.expectEqual(@as(u32, 17), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message(), "unknown algorithm 'monte_carlo'") != null);
}

test "diagnostic: malformed line reports position" {
    const cfg =
        \\[game]
        \\flop "As Kd 7h"
    ;
    var diag = Diagnostic{};
    try std.testing.expectError(error.InvalidConfig, parseConfigDiag(std.testing.allocator, cfg, &diag));
    try std.testing.expectEqual(@as(u32, 2), diag.line);
    try std.testing.expectEqualStrings("expected 'key = value'", diag.message());
}

test "config with comments and blank lines" {
    const cfg =
        \\# Zolver solver configuration
        \\# Game settings
        \\[game]
        \\flop = "As Kd 7h"
        \\initial_pot = 100
        \\effective_stack = 200
        \\
        \\[game.sizings]
        \\flop = [25, 50]     # 25% and 50% pot
        \\turn = [33]          # 33% pot
        \\river = [50, 100]    # 50% and 100% pot
        \\
        \\[game.raise_cap]
        \\flop = 1
        \\turn = none
        \\river = 1
        \\
        \\[ranges]
        \\oop = "AK"
        \\ip = "AK"
        \\
        \\[solver]
        \\algorithm = "dcfr"
    ;

    var bundle = try parseConfig(std.testing.allocator, cfg);
    defer bundle.deinit();
    try std.testing.expectEqual(@as(u32, 100), bundle.game.initial_pot);
}

test "parse value: integer array" {
    const v = try parseValue(std.testing.allocator, "[33, 66]");
    defer if (v.int_array.len > 0) std.testing.allocator.free(@constCast(v.int_array));
    switch (v) {
        .int_array => |arr| {
            try std.testing.expectEqual(@as(usize, 2), arr.len);
            try std.testing.expectEqual(@as(u32, 33), arr[0]);
            try std.testing.expectEqual(@as(u32, 66), arr[1]);
        },
        else => return error.TestExpectedIntArray,
    }
}
