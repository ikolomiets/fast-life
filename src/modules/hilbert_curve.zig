const std = @import("std");

pub const max_order: u8 = 8;

pub const Point = struct {
    x: u16,
    y: u16,
};

pub const Direction = enum {
    N,
    NE,
    E,
    SE,
    S,
    SW,
    W,
    NW,
};

fn validate_order(order: u8) !void {
    if (order > max_order) {
        return error.InvalidOrder;
    }
}

fn grid_size(order: u8) u16 {
    const shift: u4 = @intCast(order);
    return @as(u16, 1) << shift;
}

// Order 8 has 65,536 points, which does not fit in u16, so the public API tracks
// the inclusive last valid index instead of a total point count.
fn max_index(order: u8) u16 {
    return max_index_for_grid_size(grid_size(order));
}

fn max_index_for_grid_size(n: u16) u16 {
    std.debug.assert(is_power_of_two_u16(n));

    const point_count: u32 = @as(u32, n) * n;
    std.debug.assert(point_count > 0);
    std.debug.assert(point_count <= @as(u32, std.math.maxInt(u16)) + 1);

    return @intCast(point_count - 1);
}

fn is_power_of_two_u16(value: u16) bool {
    return value != 0 and (value & (value - 1)) == 0;
}

comptime {
    const largest_grid_size: u32 = @as(u32, 1) << max_order;
    const largest_point_count: u32 = largest_grid_size * largest_grid_size;

    if (largest_grid_size > std.math.maxInt(u16)) {
        @compileError("max_order must keep the public grid size within u16");
    }
    if (largest_point_count > @as(u32, std.math.maxInt(u16)) + 1) {
        @compileError("max_order must keep the inclusive last valid index within u16");
    }
    if (max_index(max_order) != std.math.maxInt(u16)) {
        @compileError("max_order must preserve the documented 16-bit inclusive Hilbert index limit");
    }
}

fn validate_index(order: u8, d: u16) !void {
    if (d > max_index(order)) {
        return error.IndexOutOfRange;
    }
}

fn validate_point(order: u8, point: Point) !void {
    const n = grid_size(order);
    if (point.x >= n) {
        return error.PointOutOfRange;
    }
    if (point.y >= n) {
        return error.PointOutOfRange;
    }
}

// xy2d uses signed temporaries here because inverse reflection can step through
// negative intermediate values even though public coordinates stay non-negative.
fn rot_unsigned(size: u16, x: *u16, y: *u16, rx: u16, ry: u16) void {
    if (ry == 0) {
        if (rx == 1) {
            x.* = size - 1 - x.*;
            y.* = size - 1 - y.*;
        }

        const old_x = x.*;
        x.* = y.*;
        y.* = old_x;
    }
}

fn rot_signed(size: i32, x: *i32, y: *i32, rx: i32, ry: i32) void {
    if (ry == 0) {
        if (rx == 1) {
            x.* = size - 1 - x.*;
            y.* = size - 1 - y.*;
        }

        const old_x = x.*;
        x.* = y.*;
        y.* = old_x;
    }
}

fn d2xy_unchecked(n: u16, d: u16) Point {
    std.debug.assert(n != 0);
    std.debug.assert(is_power_of_two_u16(n));
    std.debug.assert(d <= max_index_for_grid_size(n));

    var x: u16 = 0;
    var y: u16 = 0;
    var t: u16 = d;
    var size: u16 = 1;

    while (size < n) : (size <<= 1) {
        const rx: u16 = (t >> 1) & 1;
        const ry: u16 = (t ^ rx) & 1;

        rot_unsigned(size, &x, &y, rx, ry);

        x += size * rx;
        y += size * ry;

        t >>= 2;
    }

    const point = Point{ .x = x, .y = y };
    std.debug.assert(point.x < n);
    std.debug.assert(point.y < n);
    return point;
}

fn xy2d_unchecked(n: u16, point: Point) u16 {
    std.debug.assert(n != 0);
    std.debug.assert(is_power_of_two_u16(n));
    std.debug.assert(point.x < n);
    std.debug.assert(point.y < n);

    var x: i32 = point.x;
    var y: i32 = point.y;
    var d: u16 = 0;
    var size: i32 = n >> 1;

    while (size > 0) : (size >>= 1) {
        const rx: i32 = if ((x & size) != 0) 1 else 0;
        const ry: i32 = if ((y & size) != 0) 1 else 0;
        const quadrant: u16 = @intCast((3 * rx) ^ ry);
        const size_u16: u16 = @intCast(size);

        d += size_u16 * size_u16 * quadrant;
        rot_signed(size, &x, &y, rx, ry);
    }

    std.debug.assert(d <= max_index_for_grid_size(n));
    return d;
}

pub fn d2xy(order: u8, d: u16) !Point {
    try validate_order(order);
    try validate_index(order, d);

    return d2xy_unchecked(grid_size(order), d);
}

pub fn xy2d(order: u8, point: Point) !u16 {
    try validate_order(order);
    try validate_point(order, point);

    return xy2d_unchecked(grid_size(order), point);
}

fn parse_cli_order(arg: []const u8) !u8 {
    return std.fmt.parseInt(u8, arg, 10) catch error.InvalidUsage;
}

fn parse_cli_order_args(args: []const []const u8) error{InvalidUsage}!u8 {
    return switch (args.len) {
        1 => parse_cli_order(args[0]),
        2 => {
            if (!std.mem.eql(u8, args[0], "curve")) {
                return error.InvalidUsage;
            }
            return parse_cli_order(args[1]);
        },
        else => error.InvalidUsage,
    };
}

pub fn append_usage(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try writer.print("Usage: {s} <order>\n", .{exe_name});
    try writer.print("       {s} curve <order>\n", .{exe_name});
}

fn print_usage_and_flush(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try append_usage(writer, exe_name);
    try writer.flush();
}

pub fn run_cli(writer: *std.Io.Writer, args: []const []const u8) !void {
    const order = try parse_cli_order_args(args);
    try write_curve(writer, order);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const exe_name = if (args.len != 0) args[0] else "hilbert_curve";

    var stdout_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &.{});
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stderr_w = &stderr.interface;
    const stdout_w = &stdout.interface;

    run_cli(stdout_w, args[1..]) catch |err| switch (err) {
        error.InvalidUsage, error.InvalidOrder => {
            try print_usage_and_flush(stderr_w, exe_name);
            return err;
        },
        else => return err,
    };

    try stdout_w.flush();
}

pub fn write_curve(writer: anytype, order: u8) !void {
    try validate_order(order);

    const n = grid_size(order);
    const end = max_index(order);
    var d: u16 = 0;
    while (true) {
        const point = d2xy_unchecked(n, d);
        try writer.print("{d} {d} {d}\n", .{ d, point.x, point.y });
        if (d == end) break;
        d += 1;
    }
}

test "order 2 mapping matches the document table" {
    const expected = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = 1 },
        .{ .x = 0, .y = 2 },
        .{ .x = 0, .y = 3 },
        .{ .x = 1, .y = 3 },
        .{ .x = 1, .y = 2 },
        .{ .x = 2, .y = 2 },
        .{ .x = 2, .y = 3 },
        .{ .x = 3, .y = 3 },
        .{ .x = 3, .y = 2 },
        .{ .x = 3, .y = 1 },
        .{ .x = 2, .y = 1 },
        .{ .x = 2, .y = 0 },
        .{ .x = 3, .y = 0 },
    };

    var d: u16 = 0;
    for (expected) |point| {
        const actual = try d2xy(2, d);
        try std.testing.expectEqualDeep(point, actual);
        try std.testing.expectEqual(d, try xy2d(2, actual));
        d += 1;
    }

    try std.testing.expectEqualDeep(Point{ .x = 0, .y = 3 }, try d2xy(2, 5));
}

test "round trips for every point in orders 0 through 8" {
    var order: u8 = 0;
    while (order <= max_order) : (order += 1) {
        const n = grid_size(order);
        const end = max_index(order);

        var d: u16 = 0;
        while (true) {
            const point = try d2xy(order, d);
            try std.testing.expect(point.x < n);
            try std.testing.expect(point.y < n);
            try std.testing.expectEqual(d, try xy2d(order, point));
            if (d == end) break;
            d += 1;
        }
    }
}

test "rejects invalid input" {
    try std.testing.expectError(error.InvalidOrder, d2xy(9, 0));
    try std.testing.expectError(error.InvalidOrder, xy2d(9, .{ .x = 0, .y = 0 }));
    try std.testing.expectError(error.IndexOutOfRange, d2xy(2, 16));
    try std.testing.expectError(error.PointOutOfRange, xy2d(2, .{ .x = 4, .y = 0 }));
}

test "grid geometry matches the documented repository limits" {
    try std.testing.expectEqual(@as(u16, 1), grid_size(0));
    try std.testing.expectEqual(@as(u16, 256), grid_size(max_order));
    try std.testing.expectEqual(@as(u16, 0), max_index(0));
    try std.testing.expectEqual(std.math.maxInt(u16), max_index(max_order));
}

test "order 8 upper bound round-trips through the inclusive last valid index" {
    const last_index = std.math.maxInt(u16);
    const point = try d2xy(max_order, last_index);

    try std.testing.expect(point.x < grid_size(max_order));
    try std.testing.expect(point.y < grid_size(max_order));
    try std.testing.expectEqual(last_index, try xy2d(max_order, point));
}

test "write_curve emits indexed coordinates" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_curve(&writer, 2);

    const expected =
        \\0 0 0
        \\1 1 0
        \\2 1 1
        \\3 0 1
        \\4 0 2
        \\5 0 3
        \\6 1 3
        \\7 1 2
        \\8 2 2
        \\9 2 3
        \\10 3 3
        \\11 3 2
        \\12 3 1
        \\13 2 1
        \\14 2 0
        \\15 3 0
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "run_cli accepts bare order and explicit curve mode" {
    var bare_buffer: [32]u8 = undefined;
    var bare_writer: std.Io.Writer = .fixed(&bare_buffer);
    var explicit_buffer: [32]u8 = undefined;
    var explicit_writer: std.Io.Writer = .fixed(&explicit_buffer);

    try run_cli(&bare_writer, &.{"1"});
    try run_cli(&explicit_writer, &.{ "curve", "1" });

    const expected =
        \\0 0 0
        \\1 0 1
        \\2 1 1
        \\3 1 0
        \\
    ;

    try std.testing.expectEqualStrings(expected, bare_writer.buffered());
    try std.testing.expectEqualStrings(expected, explicit_writer.buffered());
}

test "run_cli rejects malformed curve CLI shapes" {
    var buffer: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.InvalidUsage, run_cli(&writer, &.{}));
    try std.testing.expectError(error.InvalidUsage, run_cli(&writer, &.{"curve"}));
    try std.testing.expectError(error.InvalidUsage, run_cli(&writer, &.{ "neighbors", "1" }));
    try std.testing.expectError(error.InvalidUsage, run_cli(&writer, &.{ "1", "2" }));
    try std.testing.expectError(error.InvalidUsage, run_cli(&writer, &.{"foo"}));
}

test "run_cli returns invalid order for out-of-range curve order" {
    var buffer: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.InvalidOrder, run_cli(&writer, &.{"9"}));
}
