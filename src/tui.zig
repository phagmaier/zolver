// `poker tui [spec.zon]` — interactive front-end for the resolve flow.
//
// Layout (single fixed pane, no resize for v1):
//
//   board    : [AhKsQd                                       ]
//   pot      : [50.00                                        ]
//   stack    : [200.00                                       ]
//   p1       : [JJ+, AKs                                     ]
//   p2       : [TT+, AQs+                                    ]
//   iters    : [50                                           ]
//   flop path: [x x                                          ]
//   turn card: [Th                                           ]
//   river pth: [                                             ]  (empty = turn-only)
//   river crd: [                                             ]
//   csv out  : [                                             ]
//   exploit  : [false                                        ]
//   ── Status ────────────────────────────────────────────────
//   ready.
//   ── Results ───────────────────────────────────────────────
//   wall: 12.3s  iters: 50  exploitability: 1.234
//   hand    reach    CHECK@50.00    BET@75.00    ...
//   JhJs    0.981    0.998          0.001         ...
//   ...
//   [Tab/↑↓ navigate]  [Enter solve]  [Ctrl+S save]  [q/Esc quit]

const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;

const card_mod = @import("card.zig");
const cfr = @import("cfr.zig");
const export_mod = @import("export.zig");
const gamestate_mod = @import("gamestate.zig");
const range_mod = @import("range.zig");
const range_parser = @import("range_parser.zig");
const spec_mod = @import("spec.zig");
const subgame_mod = @import("subgame.zig");

const NUM_HANDS = cfr.NUM_HANDS;

const FieldIndex = enum(u8) {
    board = 0,
    pot,
    stack,
    p1,
    p2,
    iters,
    flop_path,
    turn_path,
    csv_out,
    exploit,

    pub const count: usize = 10;

    pub fn label(self: FieldIndex) []const u8 {
        return switch (self) {
            .board => "board    ",
            .pot => "pot      ",
            .stack => "stack    ",
            .p1 => "p1       ",
            .p2 => "p2       ",
            .iters => "iters    ",
            .flop_path => "flop path",
            .turn_path => "turn path",
            .csv_out => "csv out  ",
            .exploit => "exploit  ",
        };
    }

    pub fn isPathField(self: FieldIndex) bool {
        return self == .flop_path or self == .turn_path;
    }
};

const PATH_HELP: []const u8 = "tokens (space-sep): x=check c=call f=fold j=allin  b50=half-pot bet  b100=pot bet";

const ResultRow = struct {
    hand: [4]u8,
    reach: f32,
    n_actions: u8,
    probs: [8]f32,
};

const RunResult = struct {
    wall_s: f64,
    iters: u32,
    exploitability: ?f32,
    action_labels: std.ArrayList(std.ArrayList(u8)),
    rows: std.ArrayList(ResultRow),
    csv_path: ?[]const u8,

    pub fn deinit(self: *RunResult, gpa: Allocator) void {
        for (self.action_labels.items) |*lbl| lbl.deinit(gpa);
        self.action_labels.deinit(gpa);
        self.rows.deinit(gpa);
        if (self.csv_path) |p| gpa.free(p);
    }
};

const App = struct {
    allocator: Allocator,
    io: std.Io,

    inputs: [FieldIndex.count]vaxis.widgets.TextInput,
    focused: u8,
    status_buf: [256]u8,
    status_len: usize,

    spec_path: ?[]const u8,
    result: ?RunResult,
    scroll: usize,

    wants_solve: bool,
    quit: bool,

    pub fn init(allocator: Allocator, io: std.Io, spec_path: ?[]const u8) !App {
        var app: App = .{
            .allocator = allocator,
            .io = io,
            .inputs = undefined,
            .focused = 0,
            .status_buf = undefined,
            .status_len = 0,
            .spec_path = spec_path,
            .result = null,
            .scroll = 0,
            .wants_solve = false,
            .quit = false,
        };
        for (&app.inputs) |*input| input.* = vaxis.widgets.TextInput.init(allocator);
        try app.setStatus("ready.", .{});
        return app;
    }

    pub fn deinit(self: *App) void {
        for (&self.inputs) |*input| input.deinit();
        if (self.result) |*r| r.deinit(self.allocator);
    }

    pub fn loadFromSpec(self: *App, spec: spec_mod.Spec) !void {
        // Combine board + turn.card + (river.card) into a single board string.
        var board_buf: [10]u8 = undefined;
        var board_w: usize = 0;
        @memcpy(board_buf[board_w..][0..spec.board.len], spec.board);
        board_w += spec.board.len;
        if (board_w >= 6) {
            @memcpy(board_buf[board_w..][0..spec.turn.card.len], spec.turn.card);
            board_w += spec.turn.card.len;
            if (spec.river) |r| {
                @memcpy(board_buf[board_w..][0..r.card.len], r.card);
                board_w += r.card.len;
            }
        }
        try self.setField(.board, board_buf[0..board_w]);

        try self.setFieldFmt(.pot, "{d}", .{spec.pot});
        try self.setFieldFmt(.stack, "{d}", .{spec.stack});
        try self.setField(.p1, spec.p1);
        try self.setField(.p2, spec.p2);
        try self.setFieldFmt(.iters, "{d}", .{spec.iters});
        try self.setField(.flop_path, spec.flop.path);
        if (spec.river) |r| try self.setField(.turn_path, r.path);
        if (spec.output.strategy_csv) |p| try self.setField(.csv_out, p);
        try self.setField(.exploit, if (spec.output.exploitability) "true" else "false");
    }

    /// Returns the number of cards (3, 4, or 5) currently in the board field,
    /// or 0 if the field is empty or malformed.
    fn boardCardCount(self: *const App) usize {
        var buf: [32]u8 = undefined;
        const text = self.readField(.board, &buf);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len != 6 and trimmed.len != 8 and trimmed.len != 10) return 0;
        const board = range_parser.parseBoard(trimmed) catch return 0;
        var n: usize = 0;
        for (board) |c| if (c != 0) {
            n += 1;
        };
        return n;
    }

    fn isFieldVisible(self: *const App, idx: FieldIndex) bool {
        const cards = self.boardCardCount();
        return switch (idx) {
            .flop_path => cards >= 4,
            .turn_path => cards >= 5,
            else => true,
        };
    }

    const Dir = enum { forward, backward };

    fn nextVisibleField(self: *const App, current: u8, direction: Dir) u8 {
        const count: u8 = @intCast(FieldIndex.count);
        var idx = current;
        var steps: u8 = 0;
        while (steps < count) : (steps += 1) {
            idx = switch (direction) {
                .forward => (idx + 1) % count,
                .backward => if (idx == 0) count - 1 else idx - 1,
            };
            if (self.isFieldVisible(@enumFromInt(idx))) return idx;
        }
        return current;
    }

    fn setField(self: *App, idx: FieldIndex, text: []const u8) !void {
        const input = &self.inputs[@intFromEnum(idx)];
        input.clearRetainingCapacity();
        try input.insertSliceAtCursor(text);
    }

    fn setFieldFmt(self: *App, idx: FieldIndex, comptime fmt: []const u8, args: anytype) !void {
        var buf: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, fmt, args);
        try self.setField(idx, text);
    }

    fn readField(self: *const App, idx: FieldIndex, buf: []u8) []const u8 {
        const input = &self.inputs[@intFromEnum(idx)];
        const fh = input.buf.firstHalf();
        const sh = input.buf.secondHalf();
        const total = fh.len + sh.len;
        std.debug.assert(total <= buf.len);
        @memcpy(buf[0..fh.len], fh);
        @memcpy(buf[fh.len..total], sh);
        return buf[0..total];
    }

    fn setStatus(self: *App, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.status_buf, fmt, args);
        self.status_len = text.len;
    }

    fn status(self: *const App) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn handleKey(self: *App, key: vaxis.Key) !void {
        // Quit shortcuts
        if (key.matches('c', .{ .ctrl = true })) {
            self.quit = true;
            return;
        }
        if (key.matches(vaxis.Key.escape, .{})) {
            self.quit = true;
            return;
        }

        // Ctrl+S → save
        if (key.matches('s', .{ .ctrl = true })) {
            self.save() catch |err| {
                try self.setStatus("save failed: {s}", .{@errorName(err)});
                return;
            };
            return;
        }

        // Enter / Ctrl+R → queue a solve. The main loop runs it after
        // painting "Solving..." so the user sees progress feedback.
        if (key.matches('r', .{ .ctrl = true }) or key.matches(vaxis.Key.enter, .{})) {
            self.wants_solve = true;
            return;
        }

        // Field navigation (skipping hidden fields based on board length)
        if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.down, .{})) {
            self.focused = self.nextVisibleField(self.focused, .forward);
            return;
        }
        if (key.matches(vaxis.Key.tab, .{ .shift = true }) or key.matches(vaxis.Key.up, .{})) {
            self.focused = self.nextVisibleField(self.focused, .backward);
            return;
        }

        // Results scroll
        if (key.matches(vaxis.Key.page_down, .{})) {
            self.scroll +|= 5;
            return;
        }
        if (key.matches(vaxis.Key.page_up, .{})) {
            self.scroll = if (self.scroll < 5) 0 else self.scroll - 5;
            return;
        }

        // Pass remaining keys to focused TextInput
        try self.inputs[self.focused].update(.{ .key_press = key });
    }

    fn save(self: *App) !void {
        const path = self.spec_path orelse {
            try self.setStatus("no spec path (launch with `poker tui spot.zon`)", .{});
            return;
        };

        var spec = try self.buildSpec();
        defer freeBuiltSpec(self.allocator, &spec);

        var alloc_writer = std.Io.Writer.Allocating.init(self.allocator);
        defer alloc_writer.deinit();
        try std.zon.stringify.serialize(spec, .{ .whitespace = true }, &alloc_writer.writer);
        try alloc_writer.writer.writeByte('\n');

        const bytes = alloc_writer.writer.buffered();
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes });

        try self.setStatus("saved spec ({d} bytes) → {s}", .{ bytes.len, path });
    }

    fn runSolve(self: *App) !void {
        const t_start = std.Io.Clock.Timestamp.now(self.io, .awake);

        if (self.result) |*r| {
            r.deinit(self.allocator);
            self.result = null;
        }
        self.scroll = 0;

        var spec = self.buildSpec() catch |err| {
            try self.setStatus("input error: {s}", .{@errorName(err)});
            return;
        };
        defer freeBuiltSpec(self.allocator, &spec);

        const result = self.solve(spec) catch |err| {
            try self.setStatus("solve failed: {s}", .{@errorName(err)});
            return;
        };

        const t_end = std.Io.Clock.Timestamp.now(self.io, .awake);
        const elapsed_ns: i96 = t_end.raw.nanoseconds - t_start.raw.nanoseconds;
        const elapsed_s: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(@max(@as(i96, 0), elapsed_ns))))) / 1e9;

        var final = result;
        final.wall_s = elapsed_s;
        self.result = final;
        try self.setStatus("done in {d:.3}s.", .{elapsed_s});
    }

    // Builds a `spec_mod.Spec` from the current field text. Strings are owned
    // by `allocator` and must be released via `freeBuiltSpec` (NOT the ZON
    // free, since we didn't parse via fromSliceAlloc).
    fn buildSpec(self: *App) !spec_mod.Spec {
        var bufs: [FieldIndex.count][1024]u8 = undefined;

        const board_txt = std.mem.trim(u8, self.readField(.board, &bufs[0]), " \t\r\n");
        const pot_txt = self.readField(.pot, &bufs[1]);
        const stack_txt = self.readField(.stack, &bufs[2]);
        const p1_txt = self.readField(.p1, &bufs[3]);
        const p2_txt = self.readField(.p2, &bufs[4]);
        const iters_txt = self.readField(.iters, &bufs[5]);
        const flop_path_txt = self.readField(.flop_path, &bufs[6]);
        const turn_path_txt = self.readField(.turn_path, &bufs[7]);
        const csv_txt = self.readField(.csv_out, &bufs[8]);
        const exploit_txt = self.readField(.exploit, &bufs[9]);

        // TUI is the resolve front-end: turn or river. 3-card flop-only spots
        // are out of scope here — use `poker solve` for those.
        if (board_txt.len != 8 and board_txt.len != 10) return error.BadBoard;
        _ = range_parser.parseBoard(board_txt) catch return error.BadBoard;
        const n_cards: usize = board_txt.len / 2;

        if (flop_path_txt.len == 0) return error.FlopPathRequired;
        if (n_cards == 5 and turn_path_txt.len == 0) return error.TurnPathRequired;

        // Split the full board into the underlying Spec sections.
        const flop_str = board_txt[0..6];
        const turn_card_str: []const u8 = if (n_cards >= 4) board_txt[6..8] else "";
        const river_card_str: []const u8 = if (n_cards >= 5) board_txt[8..10] else "";

        var s: spec_mod.Spec = .{
            .board = try self.allocator.dupe(u8, flop_str),
            .pot = std.fmt.parseFloat(f32, pot_txt) catch return error.BadPot,
            .stack = std.fmt.parseFloat(f32, stack_txt) catch return error.BadStack,
            .p1 = try self.allocator.dupe(u8, p1_txt),
            .p2 = try self.allocator.dupe(u8, p2_txt),
            .iters = std.fmt.parseInt(u32, iters_txt, 10) catch return error.BadIters,
            .flop = .{ .path = try self.allocator.dupe(u8, flop_path_txt) },
            .turn = .{ .card = try self.allocator.dupe(u8, turn_card_str) },
            .river = null,
            .output = .{
                .strategy_csv = if (csv_txt.len > 0) try self.allocator.dupe(u8, csv_txt) else null,
                .exploitability = parseBool(exploit_txt),
            },
        };

        if (n_cards == 5) {
            s.river = .{
                .path = try self.allocator.dupe(u8, turn_path_txt),
                .card = try self.allocator.dupe(u8, river_card_str),
            };
        }

        return s;
    }

    // Runs the resolve (flop → turn [→ river]), optionally writes CSV +
    // exploitability, and packs results into RunResult. Caller frees the
    // RunResult.
    fn solve(self: *App, spec: spec_mod.Spec) !RunResult {
        const flop_board = try range_parser.parseBoard(spec.board);
        var flop_count: usize = 0;
        for (flop_board) |c| if (c != 0) {
            flop_count += 1;
        };
        if (flop_count != 3) return error.BadBoard;

        var hand_table = range_mod.HandTable.init();
        var p1 = try range_parser.parseRange(spec.p1, &hand_table, self.allocator);
        defer p1.deinit(self.allocator);
        var p2 = try range_parser.parseRange(spec.p2, &hand_table, self.allocator);
        defer p2.deinit(self.allocator);

        var reach = subgame_mod.ReachProbs.zero();
        for (p1.active_indices, p1.probs) |idx, w| reach.p1[idx] = w;
        for (p2.active_indices, p2.probs) |idx, w| reach.p2[idx] = w;

        const turn_card = try range_parser.parseCard(spec.turn.card);

        var manager = subgame_mod.SubgameManager.init(self.io, self.allocator);
        defer manager.deinit();

        var prng = std.Random.DefaultPrng.init(42);

        const flop_state = gamestate_mod.GameState.init(.FLOP, true, spec.pot, spec.stack, spec.stack);
        try manager.solveFlop(flop_state, flop_board, &reach, spec.iters, prng.random());

        const flop_tokens = try spec_mod.parsePathTokens(self.allocator, spec.flop.path);
        defer self.allocator.free(flop_tokens);
        const flop_steps = try spec_mod.buildPathSteps(self.allocator, flop_state, flop_tokens);
        defer self.allocator.free(flop_steps);

        var turn = try manager.solveTurnByPath(flop_steps, turn_card, spec.iters, prng.random());

        var subgame_ptr: *subgame_mod.Subgame = &turn;
        var river_opt: ?subgame_mod.Subgame = null;

        if (spec.river) |river_spec| {
            const river_card = try range_parser.parseCard(river_spec.card);
            var turn_seeds = try turn.collectChanceSeeds(self.allocator);
            defer turn_seeds.deinit(self.allocator);
            const turn_tokens = try spec_mod.parsePathTokens(self.allocator, river_spec.path);
            defer self.allocator.free(turn_tokens);
            const turn_steps = try spec_mod.buildPathSteps(self.allocator, turn.root_state, turn_tokens);
            defer self.allocator.free(turn_steps);

            river_opt = try subgame_mod.solveRiverFromPath(
                self.io,
                self.allocator,
                turn_seeds.items,
                turn_steps,
                turn.board,
                river_card,
                spec.iters,
                prng.random(),
            );
            subgame_ptr = &river_opt.?;
        }

        defer {
            if (river_opt) |*r| r.deinit();
            turn.deinit();
        }

        const exploit: ?f32 = if (spec.output.exploitability) try subgame_ptr.exploitability() else null;

        // Build per-hand rows for in-TUI table.
        var rows = std.ArrayList(ResultRow).empty;
        errdefer rows.deinit(self.allocator);
        var labels = std.ArrayList(std.ArrayList(u8)).empty;
        errdefer {
            for (labels.items) |*l| l.deinit(self.allocator);
            labels.deinit(self.allocator);
        }

        const root = subgame_ptr.root;
        const n_actions = root.edges.len;
        const actor_reach: []const f32 = if (root.isp1) &subgame_ptr.solver.p1_reach else &subgame_ptr.solver.p2_reach;

        for (root.edges) |*edge| {
            var aw = std.Io.Writer.Allocating.init(self.allocator);
            errdefer aw.deinit();
            try aw.writer.print("{s}@{d:.2}", .{ @tagName(edge.action), edge.amount });
            try labels.append(self.allocator, aw.toArrayList());
        }

        const strat_buf = try self.allocator.alloc(f32, n_actions * NUM_HANDS);
        defer self.allocator.free(strat_buf);
        cfr.averageStrategy(root, strat_buf);

        const table = range_mod.HandTable.init();
        var idx: usize = 0;
        while (idx < NUM_HANDS) : (idx += 1) {
            const r = actor_reach[idx];
            if (r == 0) continue;
            const hand = table.all_hands[idx];
            const s1 = card_mod.get_card_str(hand.card1) catch [2]u8{ '?', '?' };
            const s2 = card_mod.get_card_str(hand.card2) catch [2]u8{ '?', '?' };
            var row = ResultRow{
                .hand = [4]u8{ s1[0], s1[1], s2[0], s2[1] },
                .reach = r,
                .n_actions = @intCast(@min(n_actions, 8)),
                .probs = [_]f32{0} ** 8,
            };
            var a: usize = 0;
            while (a < row.n_actions) : (a += 1) {
                row.probs[a] = strat_buf[a * NUM_HANDS + idx];
            }
            try rows.append(self.allocator, row);
        }

        // CSV side-effect (mirrors `poker resolve` behavior).
        var csv_out_path: ?[]const u8 = null;
        if (spec.output.strategy_csv) |csv_path| {
            var csv_writer = std.Io.Writer.Allocating.init(self.allocator);
            defer csv_writer.deinit();
            try export_mod.writeRootStrategyCsv(self.allocator, &csv_writer.writer, root, actor_reach);
            const bytes = csv_writer.writer.buffered();
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = csv_path, .data = bytes });
            csv_out_path = try self.allocator.dupe(u8, csv_path);
        }

        return .{
            .wall_s = 0, // filled by caller
            .iters = spec.iters,
            .exploitability = exploit,
            .action_labels = labels,
            .rows = rows,
            .csv_path = csv_out_path,
        };
    }

    pub fn draw(self: *App, win: vaxis.Window) void {
        const focused_style: vaxis.Cell.Style = .{ .reverse = true };
        const dim_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } };

        var row: u16 = 0;

        // Title bar
        _ = win.printSegment(.{
            .text = " poker tui ",
            .style = .{ .reverse = true },
        }, .{ .row_offset = row, .col_offset = 0 });
        row += 2;

        // Form fields (skip hidden based on board card count)
        var focused_idx: ?FieldIndex = null;
        var i: u8 = 0;
        while (i < FieldIndex.count) : (i += 1) {
            const idx: FieldIndex = @enumFromInt(i);
            if (!self.isFieldVisible(idx)) continue;
            const focused = (i == self.focused);
            if (focused) focused_idx = idx;
            const label_style: vaxis.Cell.Style = if (focused) focused_style else .{};

            _ = win.printSegment(.{
                .text = idx.label(),
                .style = label_style,
            }, .{ .row_offset = row, .col_offset = 0 });
            _ = win.printSegment(.{
                .text = " : ",
                .style = .{},
            }, .{ .row_offset = row, .col_offset = 9 });

            const input_win = win.child(.{
                .x_off = 12,
                .y_off = row,
                .width = @min(win.width -| 12, 60),
                .height = 1,
            });
            if (focused) {
                self.inputs[i].drawWithStyle(input_win, .{});
            } else {
                self.inputs[i].drawWithStyle(input_win, dim_style);
            }
            row += 1;
        }

        // Inline help for the focused field
        const focused_hint: []const u8 = blk: {
            if (focused_idx) |fi| {
                if (fi.isPathField()) break :blk PATH_HELP;
                if (fi == .board) break :blk "board: 8 chars (turn resolve) or 10 chars (river resolve), e.g. AhKsQdTh or AhKsQdTh2s";
                if (fi == .exploit) break :blk "exploit: true/false (adds a best-response pass after the solve)";
                if (fi == .csv_out) break :blk "csv out: path (cwd-relative) to write per-hand strategy CSV; empty = skip";
            }
            break :blk "";
        };
        if (focused_hint.len > 0) {
            _ = win.printSegment(.{ .text = focused_hint, .style = dim_style }, .{ .row_offset = row, .col_offset = 0 });
        }
        row += 2;

        // Status bar
        _ = win.printSegment(.{
            .text = "── Status ─────────────────────────────────────────",
            .style = dim_style,
        }, .{ .row_offset = row, .col_offset = 0 });
        row += 1;
        _ = win.printSegment(.{
            .text = self.status(),
            .style = .{},
        }, .{ .row_offset = row, .col_offset = 0 });
        row += 2;

        // Results
        _ = win.printSegment(.{
            .text = "── Results ────────────────────────────────────────",
            .style = dim_style,
        }, .{ .row_offset = row, .col_offset = 0 });
        row += 1;

        if (self.result) |*r| {
            self.drawResults(win, r, row);
        } else {
            _ = win.printSegment(.{
                .text = "(no solve yet — press Enter)",
                .style = dim_style,
            }, .{ .row_offset = row, .col_offset = 0 });
        }

        // Footer help
        if (win.height >= 2) {
            const footer_row = win.height - 1;
            _ = win.printSegment(.{
                .text = " [Tab/↑↓] navigate  [Enter] solve  [Ctrl+S] save  [Esc] quit ",
                .style = .{ .reverse = true },
            }, .{ .row_offset = footer_row, .col_offset = 0 });
        }
    }

    fn drawResults(self: *App, win: vaxis.Window, r: *const RunResult, start_row: u16) void {
        var row = start_row;

        // Summary line
        var summary_buf: [128]u8 = undefined;
        const summary = std.fmt.bufPrint(&summary_buf, "wall: {d:.3}s  iters: {d}  exploitability: {s}", .{
            r.wall_s,
            r.iters,
            if (r.exploitability) |e| blk: {
                var eb: [32]u8 = undefined;
                break :blk std.fmt.bufPrint(&eb, "{d:.6}", .{e}) catch "?";
            } else "(n/a)",
        }) catch "";
        _ = win.printSegment(.{ .text = summary, .style = .{} }, .{ .row_offset = row, .col_offset = 0 });
        row += 1;

        if (r.csv_path) |p| {
            var pb: [256]u8 = undefined;
            const t = std.fmt.bufPrint(&pb, "csv: {s}", .{p}) catch "";
            _ = win.printSegment(.{
                .text = t,
                .style = .{ .fg = .{ .index = 8 } },
            }, .{ .row_offset = row, .col_offset = 0 });
            row += 1;
        }

        // Table header
        var hdr_buf: [256]u8 = undefined;
        var hdr_w = std.Io.Writer.fixed(&hdr_buf);
        hdr_w.print("hand   reach   ", .{}) catch {};
        for (r.action_labels.items) |lbl| {
            hdr_w.print("{s:>13} ", .{lbl.items}) catch {};
        }
        const header = hdr_w.buffered();
        _ = win.printSegment(.{ .text = header, .style = .{ .bold = true } }, .{ .row_offset = row, .col_offset = 0 });
        row += 1;

        // Rows, with scroll
        const available_rows: usize = if (win.height > row + 2) @as(usize, win.height - row - 2) else 0;
        const rows = r.rows.items;
        const total = rows.len;
        const start = @min(self.scroll, total);
        const end = @min(start + available_rows, total);

        var idx = start;
        while (idx < end) : (idx += 1) {
            const cur = rows[idx];
            var line_buf: [256]u8 = undefined;
            var lw = std.Io.Writer.fixed(&line_buf);
            lw.print("{s}   {d:.3}   ", .{ cur.hand, cur.reach }) catch {};
            var a: usize = 0;
            while (a < cur.n_actions) : (a += 1) {
                lw.print("{d:>13.6} ", .{cur.probs[a]}) catch {};
            }
            const line = lw.buffered();
            _ = win.printSegment(.{ .text = line, .style = .{} }, .{ .row_offset = row, .col_offset = 0 });
            row += 1;
            if (row + 2 >= win.height) break;
        }

        // Scroll indicator
        if (total > available_rows and row < win.height - 1) {
            var info_buf: [64]u8 = undefined;
            const info = std.fmt.bufPrint(&info_buf, "  ({d}–{d} of {d}, PgUp/PgDn to scroll)", .{
                start + 1, end, total,
            }) catch "";
            _ = win.printSegment(.{ .text = info, .style = .{ .fg = .{ .index = 8 } } }, .{ .row_offset = row, .col_offset = 0 });
        }
    }
};

fn parseBool(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return false;
    return std.mem.eql(u8, trimmed, "true") or
        std.mem.eql(u8, trimmed, "yes") or
        std.mem.eql(u8, trimmed, "y") or
        std.mem.eql(u8, trimmed, "1");
}

fn freeBuiltSpec(gpa: Allocator, spec: *spec_mod.Spec) void {
    gpa.free(spec.board);
    gpa.free(spec.p1);
    gpa.free(spec.p2);
    gpa.free(spec.flop.path);
    gpa.free(spec.turn.card);
    if (spec.river) |r| {
        gpa.free(r.path);
        gpa.free(r.card);
    }
    if (spec.output.strategy_csv) |p| gpa.free(p);
}

pub fn run(io: std.Io, allocator: Allocator, env_map: *std.process.Environ.Map, args: []const []const u8) !void {
    const spec_path: ?[]const u8 = if (args.len >= 1) args[0] else null;

    var initial: ?spec_mod.Spec = null;
    defer if (initial) |s| spec_mod.freeSpec(allocator, s);
    if (spec_path) |p| {
        initial = try spec_mod.loadSpec(allocator, io, p);
    }

    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(io, allocator, env_map, .{});
    defer vx.deinit(allocator, tty.writer());

    var loop: vaxis.Loop(vaxis.Event) = .init(io, &tty, &vx);
    try loop.installResizeHandler();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    var app = try App.init(allocator, io, spec_path);
    defer app.deinit();

    if (initial) |s| try app.loadFromSpec(s);

    // Initial render
    {
        const win = vx.window();
        win.clear();
        win.hideCursor();
        app.draw(win);
        try vx.render(tty.writer());
    }

    while (!app.quit) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |k| try app.handleKey(k),
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            else => {},
        }

        // If the user queued a solve, paint a clear "solving" status first
        // so they see it before the (blocking) CFR pass starts. Without this
        // the screen stays stuck on the pre-Enter state and the TUI looks
        // frozen / broken.
        if (app.wants_solve) {
            app.wants_solve = false;
            try app.setStatus("Solving... UI is frozen until done. Please wait.", .{});
            const win0 = vx.window();
            win0.clear();
            win0.hideCursor();
            app.draw(win0);
            try vx.render(tty.writer());

            try app.runSolve();
        }

        const win = vx.window();
        win.clear();
        win.hideCursor();
        app.draw(win);
        try vx.render(tty.writer());
    }
}
