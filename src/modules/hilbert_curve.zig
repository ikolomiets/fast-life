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

fn validateOrder(order: u8) !void {
    if (order > max_order) {
        return error.InvalidOrder;
    }
}

fn gridSize(order: u8) u16 {
    const shift: u4 = @intCast(order);
    return @as(u16, 1) << shift;
}

fn maxIndex(order: u8) u16 {
    return switch (order) {
        max_order => std.math.maxInt(u16),
        else => (@as(u16, 1) << @intCast(order * 2)) - 1,
    };
}

fn validateIndex(order: u8, d: u16) !void {
    if (d > maxIndex(order)) {
        return error.IndexOutOfRange;
    }
}

fn validatePoint(order: u8, point: Point) !void {
    const n = gridSize(order);
    if (point.x >= n or point.y >= n) {
        return error.PointOutOfRange;
    }
}

fn rotUnsigned(size: u16, x: *u16, y: *u16, rx: u16, ry: u16) void {
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

fn rotSigned(size: i32, x: *i32, y: *i32, rx: i32, ry: i32) void {
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

fn d2xyUnchecked(n: u16, d: u16) Point {
    var x: u16 = 0;
    var y: u16 = 0;
    var t: u16 = d;
    var size: u16 = 1;

    while (size < n) : (size <<= 1) {
        const rx: u16 = (t >> 1) & 1;
        const ry: u16 = (t ^ rx) & 1;

        rotUnsigned(size, &x, &y, rx, ry);

        x += size * rx;
        y += size * ry;

        t >>= 2;
    }

    return .{ .x = x, .y = y };
}

fn xy2dUnchecked(n: u16, point: Point) u16 {
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
        rotSigned(size, &x, &y, rx, ry);
    }

    return d;
}

pub fn d2xy(order: u8, d: u16) !Point {
    try validateOrder(order);
    try validateIndex(order, d);

    return d2xyUnchecked(gridSize(order), d);
}

pub fn xy2d(order: u8, point: Point) !u16 {
    try validateOrder(order);
    try validatePoint(order, point);

    return xy2dUnchecked(gridSize(order), point);
}

pub fn writeCurve(writer: anytype, order: u8) !void {
    try validateOrder(order);

    const n = gridSize(order);
    const end = maxIndex(order);
    var d: u16 = 0;
    while (true) {
        const point = d2xyUnchecked(n, d);
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
        const n = gridSize(order);
        const end = maxIndex(order);

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

test "writeCurve emits indexed coordinates" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeCurve(&writer, 2);

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
