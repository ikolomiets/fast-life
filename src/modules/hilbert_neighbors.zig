const std = @import("std");
const hilbert_curve = @import("hilbert_curve.zig");

pub const NeighborKind = enum {
    all,
    orthogonal,
    diagonal,
};

const directions = [_]hilbert_curve.Direction{ .N, .NE, .E, .SE, .S, .SW, .W, .NW };
const histogram_bins = @as(usize, std.math.maxInt(u16)) + 1;

const HistogramEntry = struct {
    distance: u16,
    count: u32,
};

const HistogramSummary = struct {
    all_total_count: u32,
    entry_count: usize,
};

const Mode = enum {
    neighbors,
    histogram,
};

const Command = struct {
    mode: Mode,
    order: u8,
    kind: NeighborKind = .all,
    kind_explicit: bool = false,
    max_distance: ?u16 = null,
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

fn parseOrder(arg: []const u8) !u8 {
    return std.fmt.parseInt(u8, arg, 10) catch error.InvalidUsage;
}

fn parseMaxDistance(arg: []const u8) !u16 {
    return std.fmt.parseInt(u16, arg, 10) catch error.InvalidUsage;
}

fn parseNeighborKind(arg: []const u8) !NeighborKind {
    if (std.mem.eql(u8, arg, "all")) return .all;
    if (std.mem.eql(u8, arg, "orthogonal")) return .orthogonal;
    if (std.mem.eql(u8, arg, "diagonal")) return .diagonal;
    return error.InvalidUsage;
}

fn parseHistogramCommand(args: []const []const u8) !Command {
    if (args.len < 2) return error.InvalidUsage;

    var command = Command{
        .mode = .histogram,
        .order = try parseOrder(args[1]),
    };

    const option_count = args.len - 2;
    if (option_count % 2 != 0) {
        return error.InvalidUsage;
    }

    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        const option = args[i];
        const value = args[i + 1];

        if (std.mem.eql(u8, option, "kind")) {
            if (command.kind_explicit) return error.InvalidUsage;
            command.kind = try parseNeighborKind(value);
            command.kind_explicit = true;
        } else if (std.mem.eql(u8, option, "max-distance")) {
            if (command.max_distance != null) return error.InvalidUsage;
            command.max_distance = try parseMaxDistance(value);
        } else {
            return error.InvalidUsage;
        }
    }

    return command;
}

fn parseCommand(args: []const []const u8) !Command {
    if (args.len >= 1 and std.mem.eql(u8, args[0], "histogram")) {
        return parseHistogramCommand(args);
    }

    if (args.len == 1) {
        return .{
            .mode = .neighbors,
            .order = try parseOrder(args[0]),
        };
    }

    return error.InvalidUsage;
}

fn writeCommand(writer: *std.Io.Writer, command: Command) !void {
    return switch (command.mode) {
        .neighbors => writeNeighborDistances(writer, command.order),
        .histogram => if (command.kind_explicit or command.max_distance != null)
            writeNeighborDistanceHistogramFiltered(writer, command.order, command.kind, command.max_distance)
        else
            writeNeighborDistanceHistogram(writer, command.order),
    };
}

pub fn appendUsage(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try writer.print("       {s} neighbors <order>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order> kind <all|orthogonal|diagonal>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order> max-distance <distance>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order> kind <all|orthogonal|diagonal> max-distance <distance>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order> max-distance <distance> kind <all|orthogonal|diagonal>\n", .{exe_name});
}

fn printStandaloneUsage(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try writer.print("Usage: {s} <order>\n", .{exe_name});
    try writer.print("       {s} histogram <order>\n", .{exe_name});
    try writer.print("       {s} histogram <order> kind <all|orthogonal|diagonal>\n", .{exe_name});
    try writer.print("       {s} histogram <order> max-distance <distance>\n", .{exe_name});
    try writer.print("       {s} histogram <order> kind <all|orthogonal|diagonal> max-distance <distance>\n", .{exe_name});
    try writer.print("       {s} histogram <order> max-distance <distance> kind <all|orthogonal|diagonal>\n", .{exe_name});
    try writer.writeAll("Generate Moore-neighbor distances or a neighbor-distance histogram for order 0 through 8.\n");
}

fn printStandaloneUsageAndFlush(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try printStandaloneUsage(writer, exe_name);
    try writer.flush();
}

pub fn runCli(writer: *std.Io.Writer, args: []const []const u8) !void {
    const command = try parseCommand(args);
    try writeCommand(writer, command);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const exe_name = if (args.len != 0) args[0] else "hilbert_neighbors";

    var stdout_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &.{});
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stderr_w = &stderr.interface;
    const stdout_w = &stdout.interface;

    runCli(stdout_w, args[1..]) catch |err| switch (err) {
        error.InvalidUsage, error.InvalidOrder => {
            try printStandaloneUsageAndFlush(stderr_w, exe_name);
            return err;
        },
        else => return err,
    };

    try stdout_w.flush();
}

fn validateOrder(order: u8) !void {
    if (order > hilbert_curve.max_order) {
        return error.InvalidOrder;
    }
}

fn gridSize(order: u8) u16 {
    const shift: u4 = @intCast(order);
    return @as(u16, 1) << shift;
}

fn maxIndex(order: u8) u16 {
    return switch (order) {
        hilbert_curve.max_order => std.math.maxInt(u16),
        else => (@as(u16, 1) << @intCast(order * 2)) - 1,
    };
}

fn neighborPoint(n: u16, point: hilbert_curve.Point, dir: hilbert_curve.Direction) ?hilbert_curve.Point {
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

fn directionMatchesKind(kind: NeighborKind, dir: hilbert_curve.Direction) bool {
    return switch (kind) {
        .all => true,
        .orthogonal => switch (dir) {
            .N, .E, .S, .W => true,
            else => false,
        },
        .diagonal => switch (dir) {
            .NE, .SE, .SW, .NW => true,
            else => false,
        },
    };
}

fn fillNeighborDistanceCounts(order: u8, kind: NeighborKind, counts: *[histogram_bins]u32) !u32 {
    try validateOrder(order);

    @memset(counts[0..], 0);

    const n = gridSize(order);
    const end = maxIndex(order);
    var all_total_count: u32 = 0;
    var d: u16 = 0;
    while (true) {
        const point = try hilbert_curve.d2xy(order, d);

        for (directions) |dir| {
            if (neighborPoint(n, point, dir)) |neighbor| {
                all_total_count += 1;
                if (!directionMatchesKind(kind, dir)) {
                    continue;
                }

                const neighbor_d = try hilbert_curve.xy2d(order, neighbor);
                const distance = indexDistance(d, neighbor_d);
                counts[@intCast(distance)] += 1;
            }
        }

        if (d == end) break;
        d += 1;
    }

    return all_total_count;
}

fn histogramEntryLessThan(_: void, lhs: HistogramEntry, rhs: HistogramEntry) bool {
    return lhs.distance < rhs.distance;
}

fn buildNeighborDistanceHistogram(order: u8, kind: NeighborKind, entries: *[histogram_bins]HistogramEntry) !HistogramSummary {
    var counts: [histogram_bins]u32 = [_]u32{0} ** histogram_bins;
    const all_total_count = try fillNeighborDistanceCounts(order, kind, &counts);

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
        .all_total_count = all_total_count,
        .entry_count = entry_count,
    };
}

fn writeNeighborDistanceHistogramEntry(writer: anytype, entry: HistogramEntry, all_total_count: u32) !void {
    try writer.print("distance={d} count={d} percentage=", .{ entry.distance, entry.count });
    try writePercentage(writer, entry.count, all_total_count);
    try writer.writeByte('\n');
}

pub fn writeNeighborDistances(writer: anytype, order: u8) !void {
    try validateOrder(order);

    const n = gridSize(order);
    const end = maxIndex(order);
    var d: u16 = 0;
    while (true) {
        const point = try hilbert_curve.d2xy(order, d);
        try writer.print("d={d} pos=({d},{d})", .{ d, point.x, point.y });

        for (directions) |dir| {
            try writer.print(" {s}=", .{@tagName(dir)});
            if (neighborPoint(n, point, dir)) |neighbor| {
                const neighbor_d = try hilbert_curve.xy2d(order, neighbor);
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
    const summary = try buildNeighborDistanceHistogram(order, .all, &entries);

    for (entries[0..summary.entry_count]) |entry| {
        try writeNeighborDistanceHistogramEntry(writer, entry, summary.all_total_count);
    }
}

pub fn writeNeighborDistanceHistogramMaxDistance(writer: anytype, order: u8, max_distance: u16) !void {
    return writeNeighborDistanceHistogramFiltered(writer, order, .all, max_distance);
}

pub fn writeNeighborDistanceHistogramFiltered(writer: anytype, order: u8, kind: NeighborKind, max_distance: ?u16) !void {
    try validateOrder(order);

    var entries: [histogram_bins]HistogramEntry = undefined;
    const summary = try buildNeighborDistanceHistogram(order, kind, &entries);

    var subtotal_count: u32 = 0;
    for (entries[0..summary.entry_count]) |entry| {
        if (max_distance) |limit| {
            if (entry.distance > limit) break;
        }

        try writeNeighborDistanceHistogramEntry(writer, entry, summary.all_total_count);
        subtotal_count += entry.count;
    }

    try writer.writeAll("cumulative_percentage=");
    try writePercentageHundredths(writer, percentageHundredthsOrZero(subtotal_count, summary.all_total_count));
    try writer.writeByte('\n');
}

test "writeNeighborDistances emits expected order 0 report" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeNeighborDistances(&writer, 0);

    const expected =
        \\d=0 pos=(0,0) N=- NE=- E=- SE=- S=- SW=- W=- NW=-
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "writeNeighborDistances emits expected order 1 report" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeNeighborDistances(&writer, 1);

    const expected =
        \\d=0 pos=(0,0) N=- NE=- E=3 SE=2 S=1 SW=- W=- NW=-
        \\d=1 pos=(0,1) N=1 NE=2 E=1 SE=- S=- SW=- W=- NW=-
        \\d=2 pos=(1,1) N=1 NE=- E=- SE=- S=- SW=- W=1 NW=2
        \\d=3 pos=(1,0) N=- NE=- E=- SE=- S=1 SW=2 W=3 NW=-
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "neighbor distances are correct for all points and directions" {
    var order: u8 = 0;
    while (order <= hilbert_curve.max_order) : (order += 1) {
        const n = gridSize(order);
        const end = maxIndex(order);

        var d: u16 = 0;
        while (true) {
            const point = try hilbert_curve.d2xy(order, d);

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
                    const neighbor_d = try hilbert_curve.xy2d(order, actual_neighbor);
                    try std.testing.expectEqual(indexDistance(d, neighbor_d), indexDistance(neighbor_d, d));
                    try std.testing.expectEqual(neighbor_d, try hilbert_curve.xy2d(order, actual_neighbor));
                }
            }

            if (d == end) break;
            d += 1;
        }
    }
}

test "writeNeighborDistanceHistogram emits empty order 0 report" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeNeighborDistanceHistogram(&writer, 0);

    try std.testing.expectEqualStrings("", writer.buffered());
}

test "writeNeighborDistanceHistogram emits expected order 1 report" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeNeighborDistanceHistogram(&writer, 1);

    const expected =
        \\distance=1 count=6 percentage=50.00%
        \\distance=2 count=4 percentage=33.33%
        \\distance=3 count=2 percentage=16.67%
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "writeNeighborDistanceHistogram emits expected order 2 report" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeNeighborDistanceHistogram(&writer, 2);

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

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "writeNeighborDistanceHistogramMaxDistance emits zero cutoff summary" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeNeighborDistanceHistogramMaxDistance(&writer, 1, 0);

    try std.testing.expectEqualStrings("cumulative_percentage=0.00%\n", writer.buffered());
}

test "writeNeighborDistanceHistogramMaxDistance emits expected order 2 report" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeNeighborDistanceHistogramMaxDistance(&writer, 2, 4);

    const expected =
        \\distance=1 count=30 percentage=35.71%
        \\distance=2 count=24 percentage=28.57%
        \\distance=3 count=10 percentage=11.90%
        \\distance=4 count=4 percentage=4.76%
        \\cumulative_percentage=80.95%
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "writeNeighborDistanceHistogramMaxDistance emits full order 2 report for oversized cutoff" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeNeighborDistanceHistogramMaxDistance(&writer, 2, std.math.maxInt(u16));

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

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "writeNeighborDistanceHistogramFiltered emits expected order 1 orthogonal report" {
    var buffer: [192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeNeighborDistanceHistogramFiltered(&writer, 1, .orthogonal, null);

    const expected =
        \\distance=1 count=6 percentage=50.00%
        \\distance=3 count=2 percentage=16.67%
        \\cumulative_percentage=66.67%
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "writeNeighborDistanceHistogramFiltered emits expected order 1 diagonal report" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeNeighborDistanceHistogramFiltered(&writer, 1, .diagonal, null);

    const expected =
        \\distance=2 count=4 percentage=33.33%
        \\cumulative_percentage=33.33%
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "writeNeighborDistanceHistogramFiltered emits explicit kind all summary" {
    var buffer: [192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeNeighborDistanceHistogramFiltered(&writer, 1, .all, null);

    const expected =
        \\distance=1 count=6 percentage=50.00%
        \\distance=2 count=4 percentage=33.33%
        \\distance=3 count=2 percentage=16.67%
        \\cumulative_percentage=100.00%
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "writeNeighborDistanceHistogramFiltered emits expected order 2 diagonal max-distance report" {
    var buffer: [192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeNeighborDistanceHistogramFiltered(&writer, 2, .diagonal, 4);

    const expected =
        \\distance=2 count=24 percentage=28.57%
        \\distance=4 count=4 percentage=4.76%
        \\cumulative_percentage=33.33%
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "writeNeighborDistanceHistogramFiltered emits empty filtered result summary" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeNeighborDistanceHistogramFiltered(&writer, 1, .diagonal, 1);

    try std.testing.expectEqualStrings("cumulative_percentage=0.00%\n", writer.buffered());
}

test "writeNeighborDistanceHistogramFiltered emits order 0 summary" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeNeighborDistanceHistogramFiltered(&writer, 0, .orthogonal, null);

    try std.testing.expectEqualStrings("cumulative_percentage=0.00%\n", writer.buffered());
}

test "writePercentage rounds and zero pads to hundredths" {
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writePercentage(&writer, 1, 8);
    try writer.writeByte(' ');
    try writePercentage(&writer, 1, 6);

    try std.testing.expectEqualStrings("12.50% 16.67%", writer.buffered());
}

test "parseCommand accepts neighbors CLI shapes" {
    const neighbor_command = try parseCommand(&.{ "4" });
    const histogram_command = try parseCommand(&.{ "histogram", "5" });
    const max_distance_command = try parseCommand(&.{ "histogram", "5", "max-distance", "80" });
    const orthogonal_command = try parseCommand(&.{ "histogram", "5", "kind", "orthogonal" });
    const combined_command = try parseCommand(&.{ "histogram", "5", "max-distance", "80", "kind", "diagonal" });

    try std.testing.expectEqual(Mode.neighbors, neighbor_command.mode);
    try std.testing.expectEqual(@as(u8, 4), neighbor_command.order);
    try std.testing.expectEqual(NeighborKind.all, neighbor_command.kind);
    try std.testing.expectEqual(false, neighbor_command.kind_explicit);
    try std.testing.expectEqual(@as(?u16, null), neighbor_command.max_distance);

    try std.testing.expectEqual(Mode.histogram, histogram_command.mode);
    try std.testing.expectEqual(@as(u8, 5), histogram_command.order);
    try std.testing.expectEqual(NeighborKind.all, histogram_command.kind);
    try std.testing.expectEqual(false, histogram_command.kind_explicit);
    try std.testing.expectEqual(@as(?u16, null), histogram_command.max_distance);

    try std.testing.expectEqual(Mode.histogram, max_distance_command.mode);
    try std.testing.expectEqual(@as(u8, 5), max_distance_command.order);
    try std.testing.expectEqual(NeighborKind.all, max_distance_command.kind);
    try std.testing.expectEqual(false, max_distance_command.kind_explicit);
    try std.testing.expectEqual(@as(?u16, 80), max_distance_command.max_distance);

    try std.testing.expectEqual(Mode.histogram, orthogonal_command.mode);
    try std.testing.expectEqual(@as(u8, 5), orthogonal_command.order);
    try std.testing.expectEqual(NeighborKind.orthogonal, orthogonal_command.kind);
    try std.testing.expectEqual(true, orthogonal_command.kind_explicit);
    try std.testing.expectEqual(@as(?u16, null), orthogonal_command.max_distance);

    try std.testing.expectEqual(Mode.histogram, combined_command.mode);
    try std.testing.expectEqual(@as(u8, 5), combined_command.order);
    try std.testing.expectEqual(NeighborKind.diagonal, combined_command.kind);
    try std.testing.expectEqual(true, combined_command.kind_explicit);
    try std.testing.expectEqual(@as(?u16, 80), combined_command.max_distance);
}

test "parseCommand rejects malformed neighbors CLI shapes" {
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{}));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "curve", "2" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "unknown", "2" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "histogram", "5", "max-distance" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "histogram", "5", "max-distance", "70000" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "histogram", "max-distance", "5", "80" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "histogram", "5", "kind" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "histogram", "5", "kind", "sideways" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "histogram", "5", "kind", "all", "kind", "diagonal" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "histogram", "5", "max-distance", "2", "max-distance", "4" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "histogram", "5", "kind", "all", "oops", "4" }));
}

test "runCli dispatches neighbors CLI modes" {
    var report_buffer: [128]u8 = undefined;
    var report_writer: std.Io.Writer = .fixed(&report_buffer);
    var histogram_buffer: [128]u8 = undefined;
    var histogram_writer: std.Io.Writer = .fixed(&histogram_buffer);

    try runCli(&report_writer, &.{ "0" });
    try runCli(&histogram_writer, &.{ "histogram", "1", "kind", "diagonal" });

    try std.testing.expectEqualStrings(
        \\d=0 pos=(0,0) N=- NE=- E=- SE=- S=- SW=- W=- NW=-
        \\
    , report_writer.buffered());

    try std.testing.expectEqualStrings(
        \\distance=2 count=4 percentage=33.33%
        \\cumulative_percentage=33.33%
        \\
    , histogram_writer.buffered());
}

test "runCli returns invalid order for out-of-range neighbors order" {
    var buffer: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.InvalidOrder, runCli(&writer, &.{ "9" }));
}

test "neighbor distance histogram counts all valid neighbors" {
    var order: u8 = 0;
    while (order <= hilbert_curve.max_order) : (order += 1) {
        var counts: [histogram_bins]u32 = [_]u32{0} ** histogram_bins;
        const all_total_count = try fillNeighborDistanceCounts(order, .all, &counts);

        var histogram_total: u32 = 0;
        for (counts) |count| {
            histogram_total += count;
        }

        const n = gridSize(order);
        const end = maxIndex(order);
        var expected_total: u32 = 0;
        var d: u16 = 0;
        while (true) {
            const point = try hilbert_curve.d2xy(order, d);
            for (directions) |dir| {
                if (neighborPoint(n, point, dir) != null) {
                    expected_total += 1;
                }
            }

            if (d == end) break;
            d += 1;
        }

        try std.testing.expectEqual(expected_total, histogram_total);
        try std.testing.expectEqual(expected_total, all_total_count);
    }
}

test "orthogonal and diagonal histogram counts partition all neighbors" {
    var order: u8 = 0;
    while (order <= hilbert_curve.max_order) : (order += 1) {
        var all_counts: [histogram_bins]u32 = [_]u32{0} ** histogram_bins;
        var orthogonal_counts: [histogram_bins]u32 = [_]u32{0} ** histogram_bins;
        var diagonal_counts: [histogram_bins]u32 = [_]u32{0} ** histogram_bins;

        const all_total_count = try fillNeighborDistanceCounts(order, .all, &all_counts);
        const orthogonal_total_count = try fillNeighborDistanceCounts(order, .orthogonal, &orthogonal_counts);
        const diagonal_total_count = try fillNeighborDistanceCounts(order, .diagonal, &diagonal_counts);

        try std.testing.expectEqual(all_total_count, orthogonal_total_count);
        try std.testing.expectEqual(all_total_count, diagonal_total_count);

        for (all_counts, orthogonal_counts, diagonal_counts) |all_count, orthogonal_count, diagonal_count| {
            try std.testing.expectEqual(all_count, orthogonal_count + diagonal_count);
        }
    }
}
