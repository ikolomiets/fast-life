const std = @import("std");
const binary_grid = @import("binary_grid.zig");

pub const PatternCell = struct {
    x: usize,
    y: usize,
};

pub const Pattern = struct {
    width: usize,
    height: usize,
    live_cells: []PatternCell,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.live_cells.len != 0) {
            allocator.free(self.live_cells);
        }
        self.* = .{
            .width = 0,
            .height = 0,
            .live_cells = &[_]PatternCell{},
        };
    }
};

pub const ParseError = std.mem.Allocator.Error || error{
    MissingHeader,
    InvalidHeader,
    MissingTerminator,
    InvalidBody,
    PatternTooWide,
    PatternTooTall,
    TrailingData,
};

pub const max_pattern_file_bytes: usize = 2 * 1024 * 1024;

const Bounds = struct {
    min_x: usize,
    min_y: usize,
    max_x: usize,
    max_y: usize,
};

const Header = struct {
    width: usize,
    height: usize,
};

const BodyState = struct {
    x: usize = 0,
    y: usize = 0,
    pending_count: usize = 0,
    have_count: bool = false,
    finished: bool = false,
};

fn trim_line(line: []const u8) []const u8 {
    const without_cr = if (line.len != 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
    return std.mem.trim(u8, without_cr, " \t");
}

fn parse_dimension(value_text: []const u8) ParseError!usize {
    return std.fmt.parseInt(usize, std.mem.trim(u8, value_text, " \t"), 10) catch error.InvalidHeader;
}

fn parse_header(line: []const u8) ParseError!Header {
    var width: ?usize = null;
    var height: ?usize = null;

    var fields = std.mem.splitScalar(u8, line, ',');
    while (fields.next()) |field_text| {
        const field = std.mem.trim(u8, field_text, " \t");
        if (field.len == 0) return error.InvalidHeader;

        const equals_index = std.mem.findScalar(u8, field, '=') orelse return error.InvalidHeader;
        const key = std.mem.trim(u8, field[0..equals_index], " \t");
        const value = field[equals_index + 1 ..];

        if (std.mem.eql(u8, key, "x")) {
            if (width != null) return error.InvalidHeader;
            width = try parse_dimension(value);
        } else if (std.mem.eql(u8, key, "y")) {
            if (height != null) return error.InvalidHeader;
            height = try parse_dimension(value);
        } else if (std.mem.eql(u8, key, "rule")) {
            _ = std.mem.trim(u8, value, " \t");
        } else {
            return error.InvalidHeader;
        }
    }

    return .{
        .width = width orelse return error.InvalidHeader,
        .height = height orelse return error.InvalidHeader,
    };
}

fn push_live_run(
    allocator: std.mem.Allocator,
    live_cells: *std.ArrayList(PatternCell),
    row_y: usize,
    start_x: usize,
    count: usize,
) ParseError!void {
    try live_cells.ensureUnusedCapacity(allocator, count);

    var offset: usize = 0;
    while (offset < count) : (offset += 1) {
        live_cells.appendAssumeCapacity(.{
            .x = start_x + offset,
            .y = row_y,
        });
    }
}

fn take_run_count(state: *BodyState) ParseError!usize {
    if (!state.have_count) return 1;

    defer {
        state.have_count = false;
        state.pending_count = 0;
    }

    if (state.pending_count == 0) {
        return error.InvalidBody;
    }
    return state.pending_count;
}

fn accumulate_digit(state: *BodyState, digit: u8) ParseError!void {
    state.have_count = true;
    const widened = std.math.mul(usize, state.pending_count, 10) catch return error.InvalidBody;
    state.pending_count = std.math.add(usize, widened, digit) catch return error.InvalidBody;
}

fn handle_body_run(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    state: *BodyState,
    live_cells: *std.ArrayList(PatternCell),
    live: bool,
) ParseError!void {
    const count = try take_run_count(state);
    if (state.y >= height) return error.PatternTooTall;

    const next_x = std.math.add(usize, state.x, count) catch return error.PatternTooWide;
    if (next_x > width) return error.PatternTooWide;
    std.debug.assert(next_x > state.x);

    if (live) {
        try push_live_run(allocator, live_cells, state.y, state.x, count);
    }
    state.x = next_x;
}

fn handle_body_row_break(height: usize, state: *BodyState) ParseError!void {
    const count = try take_run_count(state);
    const next_y = std.math.add(usize, state.y, count) catch return error.PatternTooTall;
    if (next_y > height) return error.PatternTooTall;
    std.debug.assert(next_y > state.y);

    state.y = next_y;
    state.x = 0;
}

fn handle_body_terminator(state: *BodyState) ParseError!void {
    if (state.have_count) return error.InvalidBody;
    std.debug.assert(!state.finished);
    state.finished = true;
}

fn parse_body_line(
    allocator: std.mem.Allocator,
    line: []const u8,
    width: usize,
    height: usize,
    state: *BodyState,
    live_cells: *std.ArrayList(PatternCell),
) ParseError!void {
    for (line) |char| {
        switch (char) {
            ' ', '\t', '\r' => continue,
            '#' => break,
            else => {},
        }

        if (state.finished) {
            return error.TrailingData;
        }

        if (char >= '0' and char <= '9') {
            try accumulate_digit(state, char - '0');
            continue;
        }

        switch (char) {
            'b' => try handle_body_run(allocator, width, height, state, live_cells, false),
            'o' => try handle_body_run(allocator, width, height, state, live_cells, true),
            '$' => try handle_body_row_break(height, state),
            '!' => try handle_body_terminator(state),
            else => return error.InvalidBody,
        }
    }
}

fn validate_pattern(pattern: Pattern) error{InvalidPattern}!void {
    var previous: ?PatternCell = null;

    for (pattern.live_cells) |cell| {
        if (cell.x >= pattern.width) {
            return error.InvalidPattern;
        }
        if (cell.y >= pattern.height) {
            return error.InvalidPattern;
        }

        if (previous) |prev| {
            if (cell.y < prev.y) return error.InvalidPattern;
            if (cell.y == prev.y) {
                if (cell.x <= prev.x) return error.InvalidPattern;
            }
        }

        previous = cell;
    }
}

fn write_run(writer: anytype, count: usize, symbol: u8) !void {
    if (count != 1) {
        try writer.print("{d}", .{count});
    }
    try writer.writeByte(symbol);
}

fn write_encoded_row(writer: anytype, row_cells: []const PatternCell) !void {
    std.debug.assert(row_cells.len != 0);

    const row_y = row_cells[0].y;
    var previous_x: ?usize = null;
    for (row_cells) |cell| {
        std.debug.assert(cell.y == row_y);
        if (previous_x) |prev_x| {
            std.debug.assert(cell.x > prev_x);
        }
        previous_x = cell.x;
    }

    var cursor_x: usize = 0;
    var index: usize = 0;

    while (index < row_cells.len) {
        const live_start = row_cells[index].x;
        if (live_start > cursor_x) {
            try write_run(writer, live_start - cursor_x, 'b');
        }

        var live_end = live_start + 1;
        index += 1;
        while (index < row_cells.len and row_cells[index].x == live_end) : (index += 1) {
            live_end += 1;
        }

        try write_run(writer, live_end - live_start, 'o');
        cursor_x = live_end;
    }
}

fn find_live_bounds(
    comptime grid_order: usize,
    grid: *const binary_grid.BinaryGrid(grid_order),
) ?Bounds {
    const Grid = binary_grid.BinaryGrid(grid_order);
    const side = Grid.cells_per_side;

    var bounds: Bounds = undefined;
    var found_live = false;

    var y: usize = 0;
    while (y < side) : (y += 1) {
        var x: usize = 0;
        while (x < side) : (x += 1) {
            if (!grid.get_cell_unchecked(.{ .x = x, .y = y })) continue;

            if (!found_live) {
                bounds = .{
                    .min_x = x,
                    .min_y = y,
                    .max_x = x,
                    .max_y = y,
                };
                found_live = true;
                continue;
            }

            bounds.min_x = @min(bounds.min_x, x);
            bounds.min_y = @min(bounds.min_y, y);
            bounds.max_x = @max(bounds.max_x, x);
            bounds.max_y = @max(bounds.max_y, y);
        }
    }

    return if (found_live) bounds else null;
}

fn write_pattern_header(writer: anytype, width: usize, height: usize) !void {
    try writer.print("x = {d}, y = {d}\n", .{ width, height });
}

fn write_grid_row(
    comptime grid_order: usize,
    writer: anytype,
    grid: *const binary_grid.BinaryGrid(grid_order),
    min_x: usize,
    row_y: usize,
    max_x: usize,
) !void {
    const Grid = binary_grid.BinaryGrid(grid_order);
    std.debug.assert(min_x <= max_x);
    std.debug.assert(row_y < Grid.cells_per_side);
    std.debug.assert(max_x < Grid.cells_per_side);

    var row_has_live = false;
    var last_live_x: usize = min_x;

    var x: usize = min_x;
    while (x <= max_x) : (x += 1) {
        if (!grid.get_cell_unchecked(.{ .x = x, .y = row_y })) continue;
        row_has_live = true;
        last_live_x = x;
    }

    if (!row_has_live) return;

    var run_start = min_x;
    while (run_start <= last_live_x) {
        const live = grid.get_cell_unchecked(.{ .x = run_start, .y = row_y });
        var run_end = run_start + 1;
        while (run_end <= last_live_x and grid.get_cell_unchecked(.{ .x = run_end, .y = row_y }) == live) : (run_end += 1) {}

        try write_run(writer, run_end - run_start, if (live) 'o' else 'b');
        run_start = run_end;
    }
}

fn print_usage(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try writer.print("Usage: {s} <input-rle-path> <output-rle-path>\n", .{exe_name});
    try writer.writeAll("Parse a Life RLE file into a BinaryGrid, extract the trimmed live pattern, and write canonical RLE output.\n");
}

fn print_usage_and_flush(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try print_usage(writer, exe_name);
    try writer.flush();
}

fn rewrite_pattern_through_grid_order(
    comptime grid_order: usize,
    allocator: std.mem.Allocator,
    pattern: Pattern,
) (std.mem.Allocator.Error || error{EmptyPattern})!Pattern {
    const Grid = binary_grid.BinaryGrid(grid_order);
    var grid: Grid = undefined;
    grid.init_empty();

    apply_pattern(grid_order, &grid, pattern, .{ .x = 0, .y = 0 }) catch |err| switch (err) {
        error.InvalidPattern, error.PatternOutOfRange => unreachable,
    };

    return extract_pattern(grid_order, allocator, &grid);
}

const cli_binary_grid_order: usize = 8;
const cli_binary_grid_side: usize = binary_grid.BinaryGrid(cli_binary_grid_order).cells_per_side;

pub fn parse_pattern(allocator: std.mem.Allocator, input: []const u8) ParseError!Pattern {
    var lines = std.mem.splitScalar(u8, input, '\n');
    var header: ?Header = null;
    var live_cells = std.ArrayList(PatternCell).empty;
    errdefer live_cells.deinit(allocator);

    var state = BodyState{};

    while (lines.next()) |raw_line| {
        const line = trim_line(raw_line);
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        if (header == null) {
            if (std.mem.findScalar(u8, line, '=') == null) {
                return error.MissingHeader;
            }
            header = try parse_header(line);
            continue;
        }

        try parse_body_line(allocator, line, header.?.width, header.?.height, &state, &live_cells);
    }

    const parsed_header = header orelse return error.MissingHeader;
    if (!state.finished) return error.MissingTerminator;

    return .{
        .width = parsed_header.width,
        .height = parsed_header.height,
        .live_cells = try live_cells.toOwnedSlice(allocator),
    };
}

pub fn parse_pattern_file(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Pattern {
    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_pattern_file_bytes));
    defer allocator.free(input);

    return parse_pattern(allocator, input);
}

pub fn write_pattern(writer: anytype, pattern: Pattern) !void {
    try validate_pattern(pattern);
    try write_pattern_header(writer, pattern.width, pattern.height);

    if (pattern.live_cells.len == 0) {
        try writer.writeAll("!\n");
        return;
    }

    var live_index: usize = 0;
    var cursor_row: usize = 0;

    while (live_index < pattern.live_cells.len) {
        const row_y = pattern.live_cells[live_index].y;
        if (row_y > cursor_row) {
            try write_run(writer, row_y - cursor_row, '$');
        }

        const row_start = live_index;
        while (live_index < pattern.live_cells.len and pattern.live_cells[live_index].y == row_y) : (live_index += 1) {}

        try write_encoded_row(writer, pattern.live_cells[row_start..live_index]);
        cursor_row = row_y;
    }

    try writer.writeAll("!\n");
}

pub fn write_pattern_file(io: std.Io, path: []const u8, pattern: Pattern) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var file_writer = file.writer(io, &.{});
    const writer = &file_writer.interface;

    write_pattern(writer, pattern) catch |err| switch (err) {
        error.WriteFailed => return file_writer.err.?,
        else => return err,
    };
    writer.flush() catch |err| switch (err) {
        error.WriteFailed => return file_writer.err.?,
    };
}

pub fn extract_pattern(
    comptime grid_order: usize,
    allocator: std.mem.Allocator,
    grid: *const binary_grid.BinaryGrid(grid_order),
) (std.mem.Allocator.Error || error{EmptyPattern})!Pattern {
    const bounds = find_live_bounds(grid_order, grid) orelse return error.EmptyPattern;
    var live_cells = std.ArrayList(PatternCell).empty;
    errdefer live_cells.deinit(allocator);

    var y: usize = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        var x: usize = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            if (!grid.get_cell_unchecked(.{ .x = x, .y = y })) continue;

            try live_cells.append(allocator, .{
                .x = x - bounds.min_x,
                .y = y - bounds.min_y,
            });
        }
    }

    return .{
        .width = bounds.max_x - bounds.min_x + 1,
        .height = bounds.max_y - bounds.min_y + 1,
        .live_cells = try live_cells.toOwnedSlice(allocator),
    };
}

pub fn write_grid(
    comptime grid_order: usize,
    writer: anytype,
    grid: *const binary_grid.BinaryGrid(grid_order),
) !void {
    const bounds = find_live_bounds(grid_order, grid) orelse return error.EmptyPattern;
    const width = bounds.max_x - bounds.min_x + 1;
    const height = bounds.max_y - bounds.min_y + 1;

    try write_pattern_header(writer, width, height);

    var cursor_row: usize = 0;
    var row_y: usize = bounds.min_y;
    while (row_y <= bounds.max_y) : (row_y += 1) {
        var row_has_live = false;
        var x: usize = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            if (grid.get_cell_unchecked(.{ .x = x, .y = row_y })) {
                row_has_live = true;
                break;
            }
        }

        if (!row_has_live) continue;

        const relative_row = row_y - bounds.min_y;
        if (relative_row > cursor_row) {
            try write_run(writer, relative_row - cursor_row, '$');
        }

        try write_grid_row(grid_order, writer, grid, bounds.min_x, row_y, bounds.max_x);
        cursor_row = relative_row;
    }

    try writer.writeAll("!\n");
}

pub fn apply_pattern(
    comptime grid_order: usize,
    grid: *binary_grid.BinaryGrid(grid_order),
    pattern: Pattern,
    origin: binary_grid.CellCoord,
) !void {
    const Grid = binary_grid.BinaryGrid(grid_order);
    const side = Grid.cells_per_side;

    try validate_pattern(pattern);

    // Validate the full placement before mutating so failure never leaves a partial overlay behind.
    for (pattern.live_cells) |cell| {
        const dest_x = std.math.add(usize, origin.x, cell.x) catch return error.PatternOutOfRange;
        const dest_y = std.math.add(usize, origin.y, cell.y) catch return error.PatternOutOfRange;

        if (dest_x >= side) {
            return error.PatternOutOfRange;
        }
        if (dest_y >= side) {
            return error.PatternOutOfRange;
        }
    }

    for (pattern.live_cells) |cell| {
        grid.set_cell_unchecked(.{
            .x = origin.x + cell.x,
            .y = origin.y + cell.y,
        }, true);
    }
}

pub fn run_cli(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 2) {
        return error.InvalidUsage;
    }

    var input_pattern = try parse_pattern_file(io, allocator, args[0]);
    defer input_pattern.deinit(allocator);

    if (input_pattern.width > cli_binary_grid_side) {
        return error.PatternTooLargeForBinaryGrid;
    }
    if (input_pattern.height > cli_binary_grid_side) {
        return error.PatternTooLargeForBinaryGrid;
    }

    var output_pattern = try rewrite_pattern_through_grid_order(cli_binary_grid_order, allocator, input_pattern);
    defer output_pattern.deinit(allocator);

    try write_pattern_file(io, args[1], output_pattern);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const exe_name = if (args.len != 0) args[0] else "life_rle";

    var stderr = std.Io.File.stderr().writer(io, &.{});
    const stderr_w = &stderr.interface;

    run_cli(io, allocator, args[1..]) catch |err| switch (err) {
        error.InvalidUsage => {
            try print_usage_and_flush(stderr_w, exe_name);
            return err;
        },
        else => return err,
    };
}

fn expect_pattern(pattern: Pattern, width: usize, height: usize, expected_cells: []const PatternCell) !void {
    try std.testing.expectEqual(width, pattern.width);
    try std.testing.expectEqual(height, pattern.height);
    try std.testing.expectEqual(expected_cells.len, pattern.live_cells.len);

    for (expected_cells, 0..) |expected_cell, index| {
        try std.testing.expectEqualDeep(expected_cell, pattern.live_cells[index]);
    }
}

fn tmp_file_path(buffer: []u8, tmp_dir: *const std.testing.TmpDir, file_name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/{s}", .{ tmp_dir.sub_path, file_name });
}

test "parse_pattern decodes a glider" {
    var pattern = try parse_pattern(std.testing.allocator,
        \\x = 3, y = 3
        \\bo$2bo$3o!
        \\
    );
    defer pattern.deinit(std.testing.allocator);

    try expect_pattern(pattern, 3, 3, &.{
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 0, .y = 2 },
        .{ .x = 1, .y = 2 },
        .{ .x = 2, .y = 2 },
    });
}

test "parse_pattern ignores comments whitespace and implicit trailing dead space" {
    var pattern = try parse_pattern(std.testing.allocator,
        \\#N Glider
        \\#C preserved as ignored input only
        \\x = 3, y = 3, rule = B3/S23
        \\ b o $
        \\ 2b o $
        \\ 3o !
        \\
    );
    defer pattern.deinit(std.testing.allocator);

    try expect_pattern(pattern, 3, 3, &.{
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 0, .y = 2 },
        .{ .x = 1, .y = 2 },
        .{ .x = 2, .y = 2 },
    });
}

test "parse_pattern accepts empty patterns" {
    var pattern = try parse_pattern(std.testing.allocator,
        \\x = 4, y = 3
        \\!
        \\
    );
    defer pattern.deinit(std.testing.allocator);

    try expect_pattern(pattern, 4, 3, &.{});
}

test "parse_pattern rejects malformed input" {
    try std.testing.expectError(error.MissingHeader, parse_pattern(std.testing.allocator, "bo$2bo$3o!\n"));
    try std.testing.expectError(error.InvalidHeader, parse_pattern(std.testing.allocator, "x = 3\nbo!\n"));
    try std.testing.expectError(error.InvalidBody, parse_pattern(std.testing.allocator, "x = 1, y = 1\nx!\n"));
    try std.testing.expectError(error.InvalidBody, parse_pattern(std.testing.allocator, "x = 1, y = 1\n0o!\n"));
    try std.testing.expectError(error.MissingTerminator, parse_pattern(std.testing.allocator, "x = 1, y = 1\no\n"));
    try std.testing.expectError(error.PatternTooWide, parse_pattern(std.testing.allocator, "x = 2, y = 1\n3o!\n"));
    try std.testing.expectError(error.PatternTooTall, parse_pattern(std.testing.allocator, "x = 1, y = 1\no$o!\n"));
    try std.testing.expectError(error.TrailingData, parse_pattern(std.testing.allocator, "x = 1, y = 1\no!o\n"));
}

test "write_pattern emits canonical RLE" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var live_cells = [_]PatternCell{
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 0, .y = 2 },
        .{ .x = 1, .y = 2 },
        .{ .x = 2, .y = 2 },
    };

    try write_pattern(&writer, .{
        .width = 3,
        .height = 3,
        .live_cells = live_cells[0..],
    });

    try std.testing.expectEqualStrings(
        \\x = 3, y = 3
        \\bo$2bo$3o!
        \\
    , writer.buffered());
}

test "write_pattern rejects invalid public Pattern values" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var live_cells = [_]PatternCell{
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = 1 },
    };

    try std.testing.expectError(error.InvalidPattern, write_pattern(&writer, .{
        .width = 2,
        .height = 2,
        .live_cells = live_cells[0..],
    }));
}

test "parse and write round-trip preserves geometry and live cells" {
    const input =
        \\#C glider
        \\x = 3, y = 3
        \\bo$2bo$3o!
        \\
    ;

    var pattern = try parse_pattern(std.testing.allocator, input);
    defer pattern.deinit(std.testing.allocator);

    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write_pattern(&writer, pattern);

    var roundtrip = try parse_pattern(std.testing.allocator, writer.buffered());
    defer roundtrip.deinit(std.testing.allocator);

    try expect_pattern(roundtrip, pattern.width, pattern.height, pattern.live_cells);
}

test "write_pattern_file writes canonical RLE text" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buffer: [128]u8 = undefined;
    const file_path = try tmp_file_path(&path_buffer, &tmp_dir, "glider.rle");

    var live_cells = [_]PatternCell{
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 0, .y = 2 },
        .{ .x = 1, .y = 2 },
        .{ .x = 2, .y = 2 },
    };

    try write_pattern_file(std.testing.io, file_path, .{
        .width = 3,
        .height = 3,
        .live_cells = live_cells[0..],
    });

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(max_pattern_file_bytes));
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(
        \\x = 3, y = 3
        \\bo$2bo$3o!
        \\
    , written);
}

test "parse_pattern_file parses a pattern from disk" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "glider.rle",
        .data =
        \\#C glider
        \\x = 3, y = 3
        \\bo$2bo$3o!
        \\
        ,
    });

    var path_buffer: [128]u8 = undefined;
    const file_path = try tmp_file_path(&path_buffer, &tmp_dir, "glider.rle");

    var pattern = try parse_pattern_file(std.testing.io, std.testing.allocator, file_path);
    defer pattern.deinit(std.testing.allocator);

    try expect_pattern(pattern, 3, 3, &.{
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 0, .y = 2 },
        .{ .x = 1, .y = 2 },
        .{ .x = 2, .y = 2 },
    });
}

test "parse_pattern_file rejects files larger than the built-in cap" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var file = try tmp_dir.dir.createFile(std.testing.io, "too_big.rle", .{});
    defer file.close(std.testing.io);

    var file_writer = file.writer(std.testing.io, &.{});
    const writer = &file_writer.interface;
    const chunk = [_]u8{'o'} ** 4096;

    var remaining = max_pattern_file_bytes + 1;
    while (remaining > 0) {
        const write_len = @min(remaining, chunk.len);
        try writer.writeAll(chunk[0..write_len]);
        remaining -= write_len;
    }
    try writer.flush();

    var path_buffer: [128]u8 = undefined;
    const file_path = try tmp_file_path(&path_buffer, &tmp_dir, "too_big.rle");

    try std.testing.expectError(error.StreamTooLong, parse_pattern_file(std.testing.io, std.testing.allocator, file_path));
}

test "extract_pattern trims a grid to the live bounding box" {
    const Grid = binary_grid.BinaryGrid(2);
    var grid: Grid = undefined;
    grid.init_empty();

    try grid.set_cell(.{ .x = 5, .y = 6 }, true);
    try grid.set_cell(.{ .x = 7, .y = 6 }, true);
    try grid.set_cell(.{ .x = 6, .y = 7 }, true);

    var pattern = try extract_pattern(2, std.testing.allocator, &grid);
    defer pattern.deinit(std.testing.allocator);

    try expect_pattern(pattern, 3, 2, &.{
        .{ .x = 0, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 1, .y = 1 },
    });
}

test "write_grid matches the trimmed grid contents" {
    const Grid = binary_grid.BinaryGrid(2);
    var grid: Grid = undefined;
    grid.init_empty();

    try grid.set_cell(.{ .x = 5, .y = 6 }, true);
    try grid.set_cell(.{ .x = 7, .y = 6 }, true);
    try grid.set_cell(.{ .x = 6, .y = 7 }, true);

    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write_grid(2, &writer, &grid);

    try std.testing.expectEqualStrings(
        \\x = 3, y = 2
        \\obo$bo!
        \\
    , writer.buffered());
}

test "grid helpers are specialized to BinaryGrid across grid orders" {
    var pattern = try parse_pattern(std.testing.allocator,
        \\x = 2, y = 2
        \\bo$2o!
        \\
    );
    defer pattern.deinit(std.testing.allocator);

    inline for ([_]usize{ 0, 2 }) |grid_order| {
        const Grid = binary_grid.BinaryGrid(grid_order);
        var grid: Grid = undefined;
        grid.init_empty();

        try apply_pattern(grid_order, &grid, pattern, .{ .x = 1, .y = 1 });

        var extracted = try extract_pattern(grid_order, std.testing.allocator, &grid);
        defer extracted.deinit(std.testing.allocator);
        try expect_pattern(extracted, 2, 2, pattern.live_cells);

        var buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try write_grid(grid_order, &writer, &grid);
        try std.testing.expectEqualStrings(
            \\x = 2, y = 2
            \\bo$2o!
            \\
        , writer.buffered());
    }
}

test "apply_pattern overlays live cells without clearing unrelated cells" {
    const Grid = binary_grid.BinaryGrid(2);
    var grid: Grid = undefined;
    grid.init_empty();
    try grid.set_cell(.{ .x = 0, .y = 0 }, true);

    var pattern = try parse_pattern(std.testing.allocator,
        \\x = 3, y = 3
        \\bo$2bo$3o!
        \\
    );
    defer pattern.deinit(std.testing.allocator);

    try apply_pattern(2, &grid, pattern, .{ .x = 4, .y = 5 });

    try std.testing.expect(try grid.get_cell(.{ .x = 0, .y = 0 }));
    try std.testing.expect(try grid.get_cell(.{ .x = 5, .y = 5 }));
    try std.testing.expect(try grid.get_cell(.{ .x = 6, .y = 6 }));
    try std.testing.expect(try grid.get_cell(.{ .x = 4, .y = 7 }));
    try std.testing.expect(try grid.get_cell(.{ .x = 5, .y = 7 }));
    try std.testing.expect(try grid.get_cell(.{ .x = 6, .y = 7 }));
}

test "apply_pattern fails before mutating when placement is out of bounds" {
    const Grid = binary_grid.BinaryGrid(2);
    var grid: Grid = undefined;
    grid.init_empty();

    var pattern = try parse_pattern(std.testing.allocator,
        \\x = 3, y = 3
        \\bo$2bo$3o!
        \\
    );
    defer pattern.deinit(std.testing.allocator);

    try std.testing.expectError(error.PatternOutOfRange, apply_pattern(2, &grid, pattern, .{ .x = 14, .y = 14 }));
    try std.testing.expect(!(try grid.get_cell(.{ .x = 14, .y = 14 })));
    try std.testing.expect(!(try grid.get_cell(.{ .x = 15, .y = 15 })));
}

test "extract_pattern and write_grid reject empty grids" {
    const Grid = binary_grid.BinaryGrid(1);
    var grid: Grid = undefined;
    grid.init_empty();

    try std.testing.expectError(error.EmptyPattern, extract_pattern(1, std.testing.allocator, &grid));

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.EmptyPattern, write_grid(1, &writer, &grid));
}

test "rewrite_pattern_through_grid_order trims parsed live bounds" {
    var pattern = try parse_pattern(std.testing.allocator,
        \\x = 6, y = 6
        \\$2bo$3bo$b3o!
        \\
    );
    defer pattern.deinit(std.testing.allocator);

    var rewritten = try rewrite_pattern_through_grid_order(2, std.testing.allocator, pattern);
    defer rewritten.deinit(std.testing.allocator);

    try expect_pattern(rewritten, 3, 3, &.{
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 0, .y = 2 },
        .{ .x = 1, .y = 2 },
        .{ .x = 2, .y = 2 },
    });
}

test "run_cli rewrites an input file through grid extraction" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "input.rle",
        .data =
        \\x = 6, y = 6
        \\$2bo$3bo$b3o!
        \\
        ,
    });

    var input_path_buffer: [128]u8 = undefined;
    const input_path = try tmp_file_path(&input_path_buffer, &tmp_dir, "input.rle");
    var output_path_buffer: [128]u8 = undefined;
    const output_path = try tmp_file_path(&output_path_buffer, &tmp_dir, "output.rle");

    try run_cli(std.testing.io, std.testing.allocator, &.{ input_path, output_path });

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, output_path, std.testing.allocator, .limited(max_pattern_file_bytes));
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(
        \\x = 3, y = 3
        \\bo$2bo$3o!
        \\
    , written);
}

test "run_cli rejects declared width larger than the fixed grid side" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "too_wide.rle",
        .data =
        \\x = 1025, y = 1
        \\o!
        \\
        ,
    });

    var input_path_buffer: [128]u8 = undefined;
    const input_path = try tmp_file_path(&input_path_buffer, &tmp_dir, "too_wide.rle");
    var output_path_buffer: [128]u8 = undefined;
    const output_path = try tmp_file_path(&output_path_buffer, &tmp_dir, "output.rle");

    try std.testing.expectError(error.PatternTooLargeForBinaryGrid, run_cli(std.testing.io, std.testing.allocator, &.{ input_path, output_path }));
}

test "run_cli rejects declared height larger than the fixed grid side" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "too_tall.rle",
        .data =
        \\x = 1, y = 1025
        \\o!
        \\
        ,
    });

    var input_path_buffer: [128]u8 = undefined;
    const input_path = try tmp_file_path(&input_path_buffer, &tmp_dir, "too_tall.rle");
    var output_path_buffer: [128]u8 = undefined;
    const output_path = try tmp_file_path(&output_path_buffer, &tmp_dir, "output.rle");

    try std.testing.expectError(error.PatternTooLargeForBinaryGrid, run_cli(std.testing.io, std.testing.allocator, &.{ input_path, output_path }));
}

test "run_cli accepts declared bounds exactly matching the fixed grid side" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "edge_ok.rle",
        .data =
        \\x = 1024, y = 1024
        \\o!
        \\
        ,
    });

    var input_path_buffer: [128]u8 = undefined;
    const input_path = try tmp_file_path(&input_path_buffer, &tmp_dir, "edge_ok.rle");
    var output_path_buffer: [128]u8 = undefined;
    const output_path = try tmp_file_path(&output_path_buffer, &tmp_dir, "output.rle");

    try run_cli(std.testing.io, std.testing.allocator, &.{ input_path, output_path });

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, output_path, std.testing.allocator, .limited(max_pattern_file_bytes));
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(
        \\x = 1, y = 1
        \\o!
        \\
    , written);
}

test "run_cli rejects oversized empty patterns before empty-grid extraction" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "oversized_empty.rle",
        .data =
        \\x = 1025, y = 1
        \\!
        \\
        ,
    });

    var input_path_buffer: [128]u8 = undefined;
    const input_path = try tmp_file_path(&input_path_buffer, &tmp_dir, "oversized_empty.rle");
    var output_path_buffer: [128]u8 = undefined;
    const output_path = try tmp_file_path(&output_path_buffer, &tmp_dir, "output.rle");

    try std.testing.expectError(error.PatternTooLargeForBinaryGrid, run_cli(std.testing.io, std.testing.allocator, &.{ input_path, output_path }));
}

test "run_cli keeps empty in-bounds patterns as empty-grid errors" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "empty_ok.rle",
        .data =
        \\x = 1024, y = 1024
        \\!
        \\
        ,
    });

    var input_path_buffer: [128]u8 = undefined;
    const input_path = try tmp_file_path(&input_path_buffer, &tmp_dir, "empty_ok.rle");
    var output_path_buffer: [128]u8 = undefined;
    const output_path = try tmp_file_path(&output_path_buffer, &tmp_dir, "output.rle");

    try std.testing.expectError(error.EmptyPattern, run_cli(std.testing.io, std.testing.allocator, &.{ input_path, output_path }));
}

test "run_cli rejects invalid argument counts" {
    try std.testing.expectError(error.InvalidUsage, run_cli(std.testing.io, std.testing.allocator, &.{}));
    try std.testing.expectError(error.InvalidUsage, run_cli(std.testing.io, std.testing.allocator, &.{"input.rle"}));
    try std.testing.expectError(error.InvalidUsage, run_cli(std.testing.io, std.testing.allocator, &.{ "in.rle", "out.rle", "extra" }));
}
