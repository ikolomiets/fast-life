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

const directions = [_]Direction{ .N, .NE, .E, .SE, .S, .SW, .W, .NW };
const histogram_bins = @as(usize, std.math.maxInt(u16)) + 1;

const HistogramEntry = struct {
    distance: u16,
    count: u32,
};

const HistogramSummary = struct {
    total_count: u32,
    entry_count: usize,
};

fn writePercentageHundredths(writer: anytype, hundredths: u32) !void {
    try writer.print("{d}.{d:0>2}%", .{ @divFloor(hundredths, 100), hundredths % 100 });
}

fn percentageHundredths(count: u32, total_count: u32) u32 {
    std.debug.assert(total_count != 0);

    const scaled_count: u64 = @as(u64, count) * 10_000;
    const rounded = scaled_count + @divFloor(@as(u64, total_count), 2);
    return @intCast(@divFloor(rounded, total_count));
}

fn writePercentage(writer: anytype, count: u32, total_count: u32) !void {
    try writePercentageHundredths(writer, percentageHundredths(count, total_count));
}

fn percentageHundredthsOrZero(count: u32, total_count: u32) u32 {
    return if (total_count == 0) 0 else percentageHundredths(count, total_count);
}

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

fn neighborPoint(n: u16, point: Point, dir: Direction) ?Point {
    const Candidate = struct {
        x: i32,
        y: i32,
    };

    const x: i32 = point.x;
    const y: i32 = point.y;
    const candidate: Candidate = switch (dir) {
        .N => .{ .x = x, .y = y - 1 },
        .NE => .{ .x = x + 1, .y = y - 1 },
        .E => .{ .x = x + 1, .y = y },
        .SE => .{ .x = x + 1, .y = y + 1 },
        .S => .{ .x = x, .y = y + 1 },
        .SW => .{ .x = x - 1, .y = y + 1 },
        .W => .{ .x = x - 1, .y = y },
        .NW => .{ .x = x - 1, .y = y - 1 },
    };
    const limit: i32 = @intCast(n);

    if (candidate.x < 0 or candidate.y < 0 or candidate.x >= limit or candidate.y >= limit) {
        return null;
    }

    return .{
        .x = @intCast(candidate.x),
        .y = @intCast(candidate.y),
    };
}

fn indexDistance(a: u16, b: u16) u16 {
    return if (a > b) a - b else b - a;
}

fn fillNeighborDistanceCounts(order: u8, counts: *[histogram_bins]u32) !void {
    try validateOrder(order);

    @memset(counts[0..], 0);

    const n = gridSize(order);
    const end = maxIndex(order);
    var d: u16 = 0;
    while (true) {
        const point = d2xyUnchecked(n, d);

        for (directions) |dir| {
            if (neighborPoint(n, point, dir)) |neighbor| {
                const neighbor_d = xy2dUnchecked(n, neighbor);
                const distance = indexDistance(d, neighbor_d);
                counts[@intCast(distance)] += 1;
            }
        }

        if (d == end) break;
        d += 1;
    }
}

fn histogramEntryLessThan(_: void, lhs: HistogramEntry, rhs: HistogramEntry) bool {
    return lhs.distance < rhs.distance;
}

fn buildNeighborDistanceHistogram(order: u8, entries: *[histogram_bins]HistogramEntry) !HistogramSummary {
    var counts: [histogram_bins]u32 = [_]u32{0} ** histogram_bins;
    try fillNeighborDistanceCounts(order, &counts);

    var total_count: u32 = 0;
    for (counts[1..]) |count| {
        total_count += count;
    }

    var entry_count: usize = 0;
    for (counts[1..], 1..) |count, distance| {
        if (count == 0) continue;

        entries[entry_count] = .{
            .distance = @intCast(distance),
            .count = count,
        };
        entry_count += 1;
    }

    std.mem.sort(HistogramEntry, entries[0..entry_count], {}, histogramEntryLessThan);

    return .{
        .total_count = total_count,
        .entry_count = entry_count,
    };
}

fn writeNeighborDistanceHistogramEntry(writer: anytype, entry: HistogramEntry, total_count: u32) !void {
    try writer.print("distance={d} count={d} percentage=", .{ entry.distance, entry.count });
    try writePercentage(writer, entry.count, total_count);
    try writer.writeByte('\n');
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

pub fn writeNeighborDistances(writer: anytype, order: u8) !void {
    try validateOrder(order);

    const n = gridSize(order);
    const end = maxIndex(order);
    var d: u16 = 0;
    while (true) {
        const point = d2xyUnchecked(n, d);
        try writer.print("d={d} pos=({d},{d})", .{ d, point.x, point.y });

        for (directions) |dir| {
            try writer.print(" {s}=", .{@tagName(dir)});
            if (neighborPoint(n, point, dir)) |neighbor| {
                const neighbor_d = xy2dUnchecked(n, neighbor);
                try writer.print("{d}", .{indexDistance(d, neighbor_d)});
            } else {
                try writer.writeAll("-");
            }
        }
        try writer.writeByte('\n');

        if (d == end) break;
        d += 1;
    }
}

pub fn writeNeighborDistanceHistogram(writer: anytype, order: u8) !void {
    try validateOrder(order);

    var entries: [histogram_bins]HistogramEntry = undefined;
    const summary = try buildNeighborDistanceHistogram(order, &entries);

    for (entries[0..summary.entry_count]) |entry| {
        try writeNeighborDistanceHistogramEntry(writer, entry, summary.total_count);
    }
}

pub fn writeNeighborDistanceHistogramMaxDistance(writer: anytype, order: u8, max_distance: u16) !void {
    try validateOrder(order);

    var entries: [histogram_bins]HistogramEntry = undefined;
    const summary = try buildNeighborDistanceHistogram(order, &entries);

    var subtotal_count: u32 = 0;
    for (entries[0..summary.entry_count]) |entry| {
        if (entry.distance > max_distance) {
            break;
        }

        try writeNeighborDistanceHistogramEntry(writer, entry, summary.total_count);
        subtotal_count += entry.count;
    }

    try writer.writeAll("cumulative_percentage=");
    try writePercentageHundredths(writer, percentageHundredthsOrZero(subtotal_count, summary.total_count));
    try writer.writeByte('\n');
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
    var stream = std.io.fixedBufferStream(&buffer);

    try writeCurve(stream.writer(), 2);

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

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "writeNeighborDistances emits expected order 0 report" {
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try writeNeighborDistances(stream.writer(), 0);

    const expected =
        \\d=0 pos=(0,0) N=- NE=- E=- SE=- S=- SW=- W=- NW=-
        \\
    ;

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "writeNeighborDistances emits expected order 1 report" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try writeNeighborDistances(stream.writer(), 1);

    const expected =
        \\d=0 pos=(0,0) N=- NE=- E=3 SE=2 S=1 SW=- W=- NW=-
        \\d=1 pos=(0,1) N=1 NE=2 E=1 SE=- S=- SW=- W=- NW=-
        \\d=2 pos=(1,1) N=1 NE=- E=- SE=- S=- SW=- W=1 NW=2
        \\d=3 pos=(1,0) N=- NE=- E=- SE=- S=1 SW=2 W=3 NW=-
        \\
    ;

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "neighbor distances are correct for all points and directions" {
    var order: u8 = 0;
    while (order <= max_order) : (order += 1) {
        const n = gridSize(order);
        const end = maxIndex(order);

        var d: u16 = 0;
        while (true) {
            const point = d2xyUnchecked(n, d);

            for (directions) |dir| {
                const expected_present = switch (dir) {
                    .N => point.y > 0,
                    .NE => point.y > 0 and point.x + 1 < n,
                    .E => point.x + 1 < n,
                    .SE => point.x + 1 < n and point.y + 1 < n,
                    .S => point.y + 1 < n,
                    .SW => point.x > 0 and point.y + 1 < n,
                    .W => point.x > 0,
                    .NW => point.x > 0 and point.y > 0,
                };

                const neighbor = neighborPoint(n, point, dir);
                try std.testing.expectEqual(expected_present, neighbor != null);

                if (neighbor) |actual_neighbor| {
                    const neighbor_d = xy2dUnchecked(n, actual_neighbor);
                    try std.testing.expectEqual(indexDistance(d, neighbor_d), indexDistance(neighbor_d, d));
                    try std.testing.expectEqual(neighbor_d, xy2dUnchecked(n, actual_neighbor));
                }
            }

            if (d == end) break;
            d += 1;
        }
    }
}

test "writeNeighborDistanceHistogram emits empty order 0 report" {
    var buffer: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try writeNeighborDistanceHistogram(stream.writer(), 0);

    try std.testing.expectEqualStrings("", stream.getWritten());
}

test "writeNeighborDistanceHistogram emits expected order 1 report" {
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try writeNeighborDistanceHistogram(stream.writer(), 1);

    const expected =
        \\distance=1 count=6 percentage=50.00%
        \\distance=2 count=4 percentage=33.33%
        \\distance=3 count=2 percentage=16.67%
        \\
    ;

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "writeNeighborDistanceHistogram emits expected order 2 report" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try writeNeighborDistanceHistogram(stream.writer(), 2);

    const expected =
        \\distance=1 count=30 percentage=35.71%
        \\distance=2 count=24 percentage=28.57%
        \\distance=3 count=10 percentage=11.90%
        \\distance=4 count=4 percentage=4.76%
        \\distance=5 count=4 percentage=4.76%
        \\distance=6 count=4 percentage=4.76%
        \\distance=11 count=2 percentage=2.38%
        \\distance=12 count=4 percentage=4.76%
        \\distance=13 count=2 percentage=2.38%
        \\
    ;

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "writeNeighborDistanceHistogramMaxDistance emits zero cutoff summary" {
    var buffer: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try writeNeighborDistanceHistogramMaxDistance(stream.writer(), 1, 0);

    try std.testing.expectEqualStrings("cumulative_percentage=0.00%\n", stream.getWritten());
}

test "writeNeighborDistanceHistogramMaxDistance emits expected order 2 report" {
    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try writeNeighborDistanceHistogramMaxDistance(stream.writer(), 2, 4);

    const expected =
        \\distance=1 count=30 percentage=35.71%
        \\distance=2 count=24 percentage=28.57%
        \\distance=3 count=10 percentage=11.90%
        \\distance=4 count=4 percentage=4.76%
        \\cumulative_percentage=80.95%
        \\
    ;

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "writeNeighborDistanceHistogramMaxDistance emits full order 2 report for oversized cutoff" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try writeNeighborDistanceHistogramMaxDistance(stream.writer(), 2, std.math.maxInt(u16));

    const expected =
        \\distance=1 count=30 percentage=35.71%
        \\distance=2 count=24 percentage=28.57%
        \\distance=3 count=10 percentage=11.90%
        \\distance=4 count=4 percentage=4.76%
        \\distance=5 count=4 percentage=4.76%
        \\distance=6 count=4 percentage=4.76%
        \\distance=11 count=2 percentage=2.38%
        \\distance=12 count=4 percentage=4.76%
        \\distance=13 count=2 percentage=2.38%
        \\cumulative_percentage=100.00%
        \\
    ;

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "writePercentage rounds and zero pads to hundredths" {
    var buffer: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try writePercentage(stream.writer(), 1, 8);
    try stream.writer().writeByte(' ');
    try writePercentage(stream.writer(), 1, 6);

    try std.testing.expectEqualStrings("12.50% 16.67%", stream.getWritten());
}

test "neighbor distance histogram counts all valid neighbors" {
    var order: u8 = 0;
    while (order <= max_order) : (order += 1) {
        var counts: [histogram_bins]u32 = [_]u32{0} ** histogram_bins;
        try fillNeighborDistanceCounts(order, &counts);

        var histogram_total: u32 = 0;
        for (counts) |count| {
            histogram_total += count;
        }

        const n = gridSize(order);
        const end = maxIndex(order);
        var expected_total: u32 = 0;
        var d: u16 = 0;
        while (true) {
            const point = d2xyUnchecked(n, d);
            for (directions) |dir| {
                if (neighborPoint(n, point, dir) != null) {
                    expected_total += 1;
                }
            }

            if (d == end) break;
            d += 1;
        }

        try std.testing.expectEqual(expected_total, histogram_total);
    }
}
