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

fn gridType(comptime GridPtr: type) type {
    return switch (@typeInfo(GridPtr)) {
        .pointer => |pointer_info| pointer_info.child,
        else => @compileError("expected a grid pointer"),
    };
}

fn trimLine(line: []const u8) []const u8 {
    const without_cr = if (line.len != 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
    return std.mem.trim(u8, without_cr, " \t");
}

fn parseDimension(value_text: []const u8) ParseError!usize {
    return std.fmt.parseInt(usize, std.mem.trim(u8, value_text, " \t"), 10) catch error.InvalidHeader;
}

fn parseHeader(line: []const u8) ParseError!Header {
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
            width = try parseDimension(value);
        } else if (std.mem.eql(u8, key, "y")) {
            if (height != null) return error.InvalidHeader;
            height = try parseDimension(value);
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

fn pushLiveRun(allocator: std.mem.Allocator, live_cells: *std.ArrayList(PatternCell), row_y: usize, start_x: usize, count: usize) ParseError!void {
    try live_cells.ensureUnusedCapacity(allocator, count);

    var offset: usize = 0;
    while (offset < count) : (offset += 1) {
        live_cells.appendAssumeCapacity(.{
            .x = start_x + offset,
            .y = row_y,
        });
    }
}

fn takeRunCount(state: *BodyState) ParseError!usize {
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

fn accumulateDigit(state: *BodyState, digit: u8) ParseError!void {
    state.have_count = true;
    const widened = std.math.mul(usize, state.pending_count, 10) catch return error.InvalidBody;
    state.pending_count = std.math.add(usize, widened, digit) catch return error.InvalidBody;
}

fn parseBodyLine(
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
            try accumulateDigit(state, char - '0');
            continue;
        }

        switch (char) {
            'b', 'o' => {
                const count = try takeRunCount(state);
                if (state.y >= height) return error.PatternTooTall;

                const next_x = std.math.add(usize, state.x, count) catch return error.PatternTooWide;
                if (next_x > width) return error.PatternTooWide;

                if (char == 'o') {
                    try pushLiveRun(allocator, live_cells, state.y, state.x, count);
                }
                state.x = next_x;
            },
            '$' => {
                const count = try takeRunCount(state);
                const next_y = std.math.add(usize, state.y, count) catch return error.PatternTooTall;
                if (next_y > height) return error.PatternTooTall;
                state.y = next_y;
                state.x = 0;
            },
            '!' => {
                if (state.have_count) return error.InvalidBody;
                state.finished = true;
            },
            else => return error.InvalidBody,
        }
    }
}

fn validatePattern(pattern: Pattern) error{InvalidPattern}!void {
    var previous: ?PatternCell = null;

    for (pattern.live_cells) |cell| {
        if (cell.x >= pattern.width or cell.y >= pattern.height) {
            return error.InvalidPattern;
        }

        if (previous) |prev| {
            if (cell.y < prev.y) return error.InvalidPattern;
            if (cell.y == prev.y and cell.x <= prev.x) return error.InvalidPattern;
        }

        previous = cell;
    }
}

fn writeRun(writer: anytype, count: usize, symbol: u8) !void {
    if (count != 1) {
        try writer.print("{d}", .{count});
    }
    try writer.writeByte(symbol);
}

fn writeEncodedRow(writer: anytype, row_cells: []const PatternCell) !void {
    var cursor_x: usize = 0;
    var index: usize = 0;

    while (index < row_cells.len) {
        const live_start = row_cells[index].x;
        if (live_start > cursor_x) {
            try writeRun(writer, live_start - cursor_x, 'b');
        }

        var live_end = live_start + 1;
        index += 1;
        while (index < row_cells.len and row_cells[index].x == live_end) : (index += 1) {
            live_end += 1;
        }

        try writeRun(writer, live_end - live_start, 'o');
        cursor_x = live_end;
    }
}

fn findLiveBounds(grid: anytype) ?Bounds {
    const Grid = gridType(@TypeOf(grid));
    const side = Grid.cells_per_side;

    var bounds: Bounds = undefined;
    var found_live = false;

    var y: usize = 0;
    while (y < side) : (y += 1) {
        var x: usize = 0;
        while (x < side) : (x += 1) {
            if (!grid.getCellUnchecked(.{ .x = x, .y = y })) continue;

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

fn writePatternHeader(writer: anytype, width: usize, height: usize) !void {
    try writer.print("x = {d}, y = {d}\n", .{ width, height });
}

fn writeGridRow(writer: anytype, grid: anytype, min_x: usize, row_y: usize, max_x: usize) !void {
    var row_has_live = false;
    var last_live_x: usize = min_x;

    var x: usize = min_x;
    while (x <= max_x) : (x += 1) {
        if (!grid.getCellUnchecked(.{ .x = x, .y = row_y })) continue;
        row_has_live = true;
        last_live_x = x;
    }

    if (!row_has_live) return;

    var run_start = min_x;
    while (run_start <= last_live_x) {
        const live = grid.getCellUnchecked(.{ .x = run_start, .y = row_y });
        var run_end = run_start + 1;
        while (run_end <= last_live_x and grid.getCellUnchecked(.{ .x = run_end, .y = row_y }) == live) : (run_end += 1) {}

        try writeRun(writer, run_end - run_start, if (live) 'o' else 'b');
        run_start = run_end;
    }
}

pub fn parsePattern(allocator: std.mem.Allocator, input: []const u8) ParseError!Pattern {
    var lines = std.mem.splitScalar(u8, input, '\n');
    var header: ?Header = null;
    var live_cells = std.ArrayList(PatternCell).empty;
    errdefer live_cells.deinit(allocator);

    var state = BodyState{};

    while (lines.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        if (header == null) {
            if (std.mem.findScalar(u8, line, '=') == null) {
                return error.MissingHeader;
            }
            header = try parseHeader(line);
            continue;
        }

        try parseBodyLine(allocator, line, header.?.width, header.?.height, &state, &live_cells);
    }

    const parsed_header = header orelse return error.MissingHeader;
    if (!state.finished) return error.MissingTerminator;

    return .{
        .width = parsed_header.width,
        .height = parsed_header.height,
        .live_cells = try live_cells.toOwnedSlice(allocator),
    };
}

pub fn parsePatternFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Pattern {
    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_pattern_file_bytes));
    defer allocator.free(input);

    return parsePattern(allocator, input);
}

pub fn writePattern(writer: anytype, pattern: Pattern) !void {
    try validatePattern(pattern);
    try writePatternHeader(writer, pattern.width, pattern.height);

    if (pattern.live_cells.len == 0) {
        try writer.writeAll("!\n");
        return;
    }

    var live_index: usize = 0;
    var cursor_row: usize = 0;

    while (live_index < pattern.live_cells.len) {
        const row_y = pattern.live_cells[live_index].y;
        if (row_y > cursor_row) {
            try writeRun(writer, row_y - cursor_row, '$');
        }

        const row_start = live_index;
        while (live_index < pattern.live_cells.len and pattern.live_cells[live_index].y == row_y) : (live_index += 1) {}

        try writeEncodedRow(writer, pattern.live_cells[row_start..live_index]);
        cursor_row = row_y;
    }

    try writer.writeAll("!\n");
}

pub fn writePatternFile(io: std.Io, path: []const u8, pattern: Pattern) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var file_writer = file.writer(io, &.{});
    const writer = &file_writer.interface;

    writePattern(writer, pattern) catch |err| switch (err) {
        error.WriteFailed => return file_writer.err.?,
        else => return err,
    };
    writer.flush() catch |err| switch (err) {
        error.WriteFailed => return file_writer.err.?,
    };
}

pub fn extractPattern(allocator: std.mem.Allocator, grid: anytype) (std.mem.Allocator.Error || error{EmptyPattern})!Pattern {
    const bounds = findLiveBounds(grid) orelse return error.EmptyPattern;
    var live_cells = std.ArrayList(PatternCell).empty;
    errdefer live_cells.deinit(allocator);

    var y: usize = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        var x: usize = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            if (!grid.getCellUnchecked(.{ .x = x, .y = y })) continue;

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

pub fn writeGrid(writer: anytype, grid: anytype) !void {
    const bounds = findLiveBounds(grid) orelse return error.EmptyPattern;
    const width = bounds.max_x - bounds.min_x + 1;
    const height = bounds.max_y - bounds.min_y + 1;

    try writePatternHeader(writer, width, height);

    var cursor_row: usize = 0;
    var row_y: usize = bounds.min_y;
    while (row_y <= bounds.max_y) : (row_y += 1) {
        var row_has_live = false;
        var x: usize = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            if (grid.getCellUnchecked(.{ .x = x, .y = row_y })) {
                row_has_live = true;
                break;
            }
        }

        if (!row_has_live) continue;

        const relative_row = row_y - bounds.min_y;
        if (relative_row > cursor_row) {
            try writeRun(writer, relative_row - cursor_row, '$');
        }

        try writeGridRow(writer, grid, bounds.min_x, row_y, bounds.max_x);
        cursor_row = relative_row;
    }

    try writer.writeAll("!\n");
}

pub fn applyPattern(grid: anytype, pattern: Pattern, origin: binary_grid.CellCoord) !void {
    const Grid = gridType(@TypeOf(grid));
    const side = Grid.cells_per_side;

    try validatePattern(pattern);

    for (pattern.live_cells) |cell| {
        const dest_x = std.math.add(usize, origin.x, cell.x) catch return error.PatternOutOfRange;
        const dest_y = std.math.add(usize, origin.y, cell.y) catch return error.PatternOutOfRange;

        if (dest_x >= side or dest_y >= side) {
            return error.PatternOutOfRange;
        }
    }

    for (pattern.live_cells) |cell| {
        grid.setCellUnchecked(.{
            .x = origin.x + cell.x,
            .y = origin.y + cell.y,
        }, true);
    }
}

fn expectPattern(pattern: Pattern, width: usize, height: usize, expected_cells: []const PatternCell) !void {
    try std.testing.expectEqual(width, pattern.width);
    try std.testing.expectEqual(height, pattern.height);
    try std.testing.expectEqual(expected_cells.len, pattern.live_cells.len);

    for (expected_cells, 0..) |expected_cell, index| {
        try std.testing.expectEqualDeep(expected_cell, pattern.live_cells[index]);
    }
}

fn tmpFilePath(buffer: []u8, tmp_dir: *const std.testing.TmpDir, file_name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/{s}", .{ tmp_dir.sub_path, file_name });
}

test "parsePattern decodes a glider" {
    var pattern = try parsePattern(std.testing.allocator,
        \\x = 3, y = 3
        \\bo$2bo$3o!
        \\
    );
    defer pattern.deinit(std.testing.allocator);

    try expectPattern(pattern, 3, 3, &.{
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 0, .y = 2 },
        .{ .x = 1, .y = 2 },
        .{ .x = 2, .y = 2 },
    });
}

test "parsePattern ignores comments whitespace and implicit trailing dead space" {
    var pattern = try parsePattern(std.testing.allocator,
        \\#N Glider
        \\#C preserved as ignored input only
        \\x = 3, y = 3, rule = B3/S23
        \\ b o $
        \\ 2b o $
        \\ 3o !
        \\
    );
    defer pattern.deinit(std.testing.allocator);

    try expectPattern(pattern, 3, 3, &.{
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 0, .y = 2 },
        .{ .x = 1, .y = 2 },
        .{ .x = 2, .y = 2 },
    });
}

test "parsePattern accepts empty patterns" {
    var pattern = try parsePattern(std.testing.allocator,
        \\x = 4, y = 3
        \\!
        \\
    );
    defer pattern.deinit(std.testing.allocator);

    try expectPattern(pattern, 4, 3, &.{});
}

test "parsePattern rejects malformed input" {
    try std.testing.expectError(error.MissingHeader, parsePattern(std.testing.allocator, "bo$2bo$3o!\n"));
    try std.testing.expectError(error.InvalidHeader, parsePattern(std.testing.allocator, "x = 3\nbo!\n"));
    try std.testing.expectError(error.InvalidBody, parsePattern(std.testing.allocator, "x = 1, y = 1\nx!\n"));
    try std.testing.expectError(error.InvalidBody, parsePattern(std.testing.allocator, "x = 1, y = 1\n0o!\n"));
    try std.testing.expectError(error.MissingTerminator, parsePattern(std.testing.allocator, "x = 1, y = 1\no\n"));
    try std.testing.expectError(error.PatternTooWide, parsePattern(std.testing.allocator, "x = 2, y = 1\n3o!\n"));
    try std.testing.expectError(error.PatternTooTall, parsePattern(std.testing.allocator, "x = 1, y = 1\no$o!\n"));
    try std.testing.expectError(error.TrailingData, parsePattern(std.testing.allocator, "x = 1, y = 1\no!o\n"));
}

test "writePattern emits canonical RLE" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var live_cells = [_]PatternCell{
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 0, .y = 2 },
        .{ .x = 1, .y = 2 },
        .{ .x = 2, .y = 2 },
    };

    try writePattern(&writer, .{
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

test "writePattern rejects invalid public Pattern values" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var live_cells = [_]PatternCell{
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = 1 },
    };

    try std.testing.expectError(error.InvalidPattern, writePattern(&writer, .{
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

    var pattern = try parsePattern(std.testing.allocator, input);
    defer pattern.deinit(std.testing.allocator);

    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writePattern(&writer, pattern);

    var roundtrip = try parsePattern(std.testing.allocator, writer.buffered());
    defer roundtrip.deinit(std.testing.allocator);

    try expectPattern(roundtrip, pattern.width, pattern.height, pattern.live_cells);
}

test "writePatternFile writes canonical RLE text" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buffer: [128]u8 = undefined;
    const file_path = try tmpFilePath(&path_buffer, &tmp_dir, "glider.rle");

    var live_cells = [_]PatternCell{
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 0, .y = 2 },
        .{ .x = 1, .y = 2 },
        .{ .x = 2, .y = 2 },
    };

    try writePatternFile(std.testing.io, file_path, .{
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

test "parsePatternFile parses a pattern from disk" {
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
    const file_path = try tmpFilePath(&path_buffer, &tmp_dir, "glider.rle");

    var pattern = try parsePatternFile(std.testing.io, std.testing.allocator, file_path);
    defer pattern.deinit(std.testing.allocator);

    try expectPattern(pattern, 3, 3, &.{
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 0, .y = 2 },
        .{ .x = 1, .y = 2 },
        .{ .x = 2, .y = 2 },
    });
}

test "parsePatternFile rejects files larger than the built-in cap" {
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
    const file_path = try tmpFilePath(&path_buffer, &tmp_dir, "too_big.rle");

    try std.testing.expectError(error.StreamTooLong, parsePatternFile(std.testing.io, std.testing.allocator, file_path));
}

test "extractPattern trims a grid to the live bounding box" {
    const Grid = binary_grid.BinaryGrid(2);
    var grid = Grid.initEmpty();

    try grid.setCell(.{ .x = 5, .y = 6 }, true);
    try grid.setCell(.{ .x = 7, .y = 6 }, true);
    try grid.setCell(.{ .x = 6, .y = 7 }, true);

    var pattern = try extractPattern(std.testing.allocator, &grid);
    defer pattern.deinit(std.testing.allocator);

    try expectPattern(pattern, 3, 2, &.{
        .{ .x = 0, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 1, .y = 1 },
    });
}

test "writeGrid matches the trimmed grid contents" {
    const Grid = binary_grid.BinaryGrid(2);
    var grid = Grid.initEmpty();

    try grid.setCell(.{ .x = 5, .y = 6 }, true);
    try grid.setCell(.{ .x = 7, .y = 6 }, true);
    try grid.setCell(.{ .x = 6, .y = 7 }, true);

    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeGrid(&writer, &grid);

    try std.testing.expectEqualStrings(
        \\x = 3, y = 2
        \\obo$bo!
        \\
    , writer.buffered());
}

test "applyPattern overlays live cells without clearing unrelated cells" {
    const Grid = binary_grid.BinaryGrid(2);
    var grid = Grid.initEmpty();
    try grid.setCell(.{ .x = 0, .y = 0 }, true);

    var pattern = try parsePattern(std.testing.allocator,
        \\x = 3, y = 3
        \\bo$2bo$3o!
        \\
    );
    defer pattern.deinit(std.testing.allocator);

    try applyPattern(&grid, pattern, .{ .x = 4, .y = 5 });

    try std.testing.expect(try grid.getCell(.{ .x = 0, .y = 0 }));
    try std.testing.expect(try grid.getCell(.{ .x = 5, .y = 5 }));
    try std.testing.expect(try grid.getCell(.{ .x = 6, .y = 6 }));
    try std.testing.expect(try grid.getCell(.{ .x = 4, .y = 7 }));
    try std.testing.expect(try grid.getCell(.{ .x = 5, .y = 7 }));
    try std.testing.expect(try grid.getCell(.{ .x = 6, .y = 7 }));
}

test "applyPattern fails before mutating when placement is out of bounds" {
    const Grid = binary_grid.BinaryGrid(2);
    var grid = Grid.initEmpty();

    var pattern = try parsePattern(std.testing.allocator,
        \\x = 3, y = 3
        \\bo$2bo$3o!
        \\
    );
    defer pattern.deinit(std.testing.allocator);

    try std.testing.expectError(error.PatternOutOfRange, applyPattern(&grid, pattern, .{ .x = 14, .y = 14 }));
    try std.testing.expect(!(try grid.getCell(.{ .x = 14, .y = 14 })));
    try std.testing.expect(!(try grid.getCell(.{ .x = 15, .y = 15 })));
}

test "extractPattern and writeGrid reject empty grids" {
    const Grid = binary_grid.BinaryGrid(1);
    var grid = Grid.initEmpty();

    try std.testing.expectError(error.EmptyPattern, extractPattern(std.testing.allocator, &grid));

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.EmptyPattern, writeGrid(&writer, &grid));
}
