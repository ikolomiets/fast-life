const std = @import("std");
const hilbert_curve = @import("hilbert_curve.zig");

pub const NeighborKind = enum {
    all,
    orthogonal,
    diagonal,
};

pub const max_order: u8 = 8;

const directions = [_]hilbert_curve.Direction{ .N, .NE, .E, .SE, .S, .SW, .W, .NW };
// Order 8 is the largest grid that keeps every Hilbert distance in u16 and the histogram fixed-size.
const histogram_bins = @as(usize, std.math.maxInt(u16)) + 1;

comptime {
    const grid_shift: u5 = @intCast(max_order);
    const distance_shift: u5 = @intCast(max_order * 2);
    const max_grid_side = @as(u32, 1) << grid_shift;
    const max_index_for_max_order = (@as(u32, 1) << distance_shift) - 1;

    if (max_grid_side > std.math.maxInt(u16)) {
        @compileError("hilbert_neighbors.max_order must keep grid_size(max_order) within u16");
    }
    if (max_index_for_max_order > std.math.maxInt(u16)) {
        @compileError("hilbert_neighbors.max_order must keep max_index(max_order) within u16");
    }
}

const HistogramEntry = struct {
    distance: u16,
    count: u32,
};

const HistogramSummary = struct {
    directed_neighbor_count_total: u32,
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

fn write_percentage_hundredths(writer: anytype, hundredths: u32) !void {
    try writer.print("{d}.{d:0>2}%", .{ @divFloor(hundredths, 100), hundredths % 100 });
}

fn percentage_hundredths(count: u32, total_count: u32) u32 {
    std.debug.assert(total_count != 0);

    const scaled_count: u64 = @as(u64, count) * 10_000;
    const rounded = scaled_count + @divFloor(@as(u64, total_count), 2);
    return @intCast(@divFloor(rounded, total_count));
}

fn write_percentage(writer: anytype, count: u32, total_count: u32) !void {
    try write_percentage_hundredths(writer, percentage_hundredths(count, total_count));
}

fn percentage_hundredths_or_zero(count: u32, total_count: u32) u32 {
    return if (total_count == 0) 0 else percentage_hundredths(count, total_count);
}

fn parse_order(arg: []const u8) !u8 {
    return std.fmt.parseInt(u8, arg, 10) catch error.InvalidUsage;
}

fn parse_max_distance(arg: []const u8) !u16 {
    return std.fmt.parseInt(u16, arg, 10) catch error.InvalidUsage;
}

fn parse_neighbor_kind(arg: []const u8) !NeighborKind {
    if (std.mem.eql(u8, arg, "all")) return .all;
    if (std.mem.eql(u8, arg, "orthogonal")) return .orthogonal;
    if (std.mem.eql(u8, arg, "diagonal")) return .diagonal;
    return error.InvalidUsage;
}

fn apply_histogram_option(command: *Command, option: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, option, "kind")) {
        if (command.kind_explicit) return error.InvalidUsage;
        command.kind = try parse_neighbor_kind(value);
        command.kind_explicit = true;
        return;
    }
    if (std.mem.eql(u8, option, "max-distance")) {
        if (command.max_distance != null) return error.InvalidUsage;
        command.max_distance = try parse_max_distance(value);
        return;
    }

    return error.InvalidUsage;
}

fn parse_histogram_command(args: []const []const u8) !Command {
    if (args.len < 2) return error.InvalidUsage;

    var command = Command{
        .mode = .histogram,
        .order = try parse_order(args[1]),
    };

    const option_count = args.len - 2;
    if (option_count % 2 != 0) {
        return error.InvalidUsage;
    }

    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        const option = args[i];
        const value = args[i + 1];
        try apply_histogram_option(&command, option, value);
    }

    return command;
}

fn parse_command(args: []const []const u8) !Command {
    if (args.len >= 1 and std.mem.eql(u8, args[0], "histogram")) {
        return parse_histogram_command(args);
    }

    if (args.len == 1) {
        return .{
            .mode = .neighbors,
            .order = try parse_order(args[0]),
        };
    }

    return error.InvalidUsage;
}

fn write_command(writer: *std.Io.Writer, command: Command) !void {
    switch (command.mode) {
        .neighbors => try write_neighbor_distances(writer, command.order),
        .histogram => {
            if (command.kind_explicit or command.max_distance != null) {
                try write_neighbor_distance_histogram_filtered(
                    writer,
                    command.order,
                    command.kind,
                    command.max_distance,
                );
                return;
            }

            try write_neighbor_distance_histogram(writer, command.order);
        },
    }
}

pub fn append_usage(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try writer.print("       {s} neighbors <order>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order> kind <all|orthogonal|diagonal>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order> max-distance <distance>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order> kind <all|orthogonal|diagonal> max-distance <distance>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order> max-distance <distance> kind <all|orthogonal|diagonal>\n", .{exe_name});
}

fn print_standalone_usage(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try writer.print("Usage: {s} <order>\n", .{exe_name});
    try writer.print("       {s} histogram <order>\n", .{exe_name});
    try writer.print("       {s} histogram <order> kind <all|orthogonal|diagonal>\n", .{exe_name});
    try writer.print("       {s} histogram <order> max-distance <distance>\n", .{exe_name});
    try writer.print("       {s} histogram <order> kind <all|orthogonal|diagonal> max-distance <distance>\n", .{exe_name});
    try writer.print("       {s} histogram <order> max-distance <distance> kind <all|orthogonal|diagonal>\n", .{exe_name});
    try writer.writeAll("Generate Moore-neighbor distances or a neighbor-distance histogram for order 0 through 8.\n");
}

fn print_standalone_usage_and_flush(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try print_standalone_usage(writer, exe_name);
    try writer.flush();
}

pub fn run_cli(writer: *std.Io.Writer, args: []const []const u8) !void {
    const command = try parse_command(args);
    try write_command(writer, command);
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

    run_cli(stdout_w, args[1..]) catch |err| switch (err) {
        error.InvalidUsage, error.InvalidOrder => {
            try print_standalone_usage_and_flush(stderr_w, exe_name);
            return err;
        },
        else => return err,
    };

    try stdout_w.flush();
}

fn validate_order(order: u8) !void {
    if (order > max_order) {
        return error.InvalidOrder;
    }
}

fn grid_size(order: u8) u16 {
    std.debug.assert(order <= max_order);
    const shift: u4 = @intCast(order);
    return @as(u16, 1) << shift;
}

fn max_index(order: u8) u16 {
    std.debug.assert(order <= max_order);
    const shift: u5 = @intCast(order * 2);
    const max_index_u32 = (@as(u32, 1) << shift) - 1;
    return @intCast(max_index_u32);
}

fn neighbor_point(n: u16, point: hilbert_curve.Point, dir: hilbert_curve.Direction) ?hilbert_curve.Point {
    var neighbor_x: i32 = point.x;
    var neighbor_y: i32 = point.y;

    switch (dir) {
        .N => neighbor_y -= 1,
        .NE => {
            neighbor_x += 1;
            neighbor_y -= 1;
        },
        .E => neighbor_x += 1,
        .SE => {
            neighbor_x += 1;
            neighbor_y += 1;
        },
        .S => neighbor_y += 1,
        .SW => {
            neighbor_x -= 1;
            neighbor_y += 1;
        },
        .W => neighbor_x -= 1,
        .NW => {
            neighbor_x -= 1;
            neighbor_y -= 1;
        },
    }

    const limit: i32 = @intCast(n);
    if (neighbor_x < 0) return null;
    if (neighbor_y < 0) return null;
    if (neighbor_x >= limit) return null;
    if (neighbor_y >= limit) return null;

    return .{
        .x = @intCast(neighbor_x),
        .y = @intCast(neighbor_y),
    };
}

fn index_distance(a: u16, b: u16) u16 {
    return if (a > b) a - b else b - a;
}

fn direction_matches_kind(kind: NeighborKind, dir: hilbert_curve.Direction) bool {
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

fn fill_neighbor_distance_counts(order: u8, kind: NeighborKind, counts: *[histogram_bins]u32) !u32 {
    try validate_order(order);

    @memset(counts[0..], 0);

    const n = grid_size(order);
    const end = max_index(order);
    var directed_neighbor_count_total: u32 = 0;
    var d: u16 = 0;
    while (true) {
        const point = try hilbert_curve.d2xy(order, d);

        for (directions) |dir| {
            if (neighbor_point(n, point, dir)) |neighbor| {
                directed_neighbor_count_total += 1;
                if (!direction_matches_kind(kind, dir)) {
                    continue;
                }

                const neighbor_d = try hilbert_curve.xy2d(order, neighbor);
                const distance = index_distance(d, neighbor_d);
                counts[@intCast(distance)] += 1;
            }
        }

        if (d == end) break;
        d += 1;
    }

    return directed_neighbor_count_total;
}

fn build_neighbor_distance_histogram(
    order: u8,
    kind: NeighborKind,
    entries: *[histogram_bins]HistogramEntry,
) !HistogramSummary {
    var counts: [histogram_bins]u32 = [_]u32{0} ** histogram_bins;
    const directed_neighbor_count_total = try fill_neighbor_distance_counts(order, kind, &counts);

    var entry_count: usize = 0;
    for (counts[1..], 1..) |count, distance| {
        if (count == 0) continue;

        entries[entry_count] = .{
            .distance = @intCast(distance),
            .count = count,
        };
        entry_count += 1;
    }

    return .{
        .directed_neighbor_count_total = directed_neighbor_count_total,
        .entry_count = entry_count,
    };
}

fn write_neighbor_distance_histogram_entry(
    writer: anytype,
    entry: HistogramEntry,
    directed_neighbor_count_total: u32,
) !void {
    try writer.print("distance={d} count={d} percentage=", .{ entry.distance, entry.count });
    try write_percentage(writer, entry.count, directed_neighbor_count_total);
    try writer.writeByte('\n');
}

pub fn write_neighbor_distances(writer: anytype, order: u8) !void {
    try validate_order(order);

    const n = grid_size(order);
    const end = max_index(order);
    var d: u16 = 0;
    while (true) {
        const point = try hilbert_curve.d2xy(order, d);
        try writer.print("d={d} pos=({d},{d})", .{ d, point.x, point.y });

        for (directions) |dir| {
            try writer.print(" {s}=", .{@tagName(dir)});
            if (neighbor_point(n, point, dir)) |neighbor| {
                const neighbor_d = try hilbert_curve.xy2d(order, neighbor);
                try writer.print("{d}", .{index_distance(d, neighbor_d)});
            } else {
                try writer.writeAll("-");
            }
        }
        try writer.writeByte('\n');

        if (d == end) break;
        d += 1;
    }
}

pub fn write_neighbor_distance_histogram(writer: anytype, order: u8) !void {
    try validate_order(order);

    var entries: [histogram_bins]HistogramEntry = undefined;
    const summary = try build_neighbor_distance_histogram(order, .all, &entries);

    for (entries[0..summary.entry_count]) |entry| {
        try write_neighbor_distance_histogram_entry(
            writer,
            entry,
            summary.directed_neighbor_count_total,
        );
    }
}

pub fn write_neighbor_distance_histogram_max_distance(
    writer: anytype,
    order: u8,
    max_distance: u16,
) !void {
    return write_neighbor_distance_histogram_filtered(writer, order, .all, max_distance);
}

pub fn write_neighbor_distance_histogram_filtered(
    writer: anytype,
    order: u8,
    kind: NeighborKind,
    max_distance: ?u16,
) !void {
    try validate_order(order);

    var entries: [histogram_bins]HistogramEntry = undefined;
    const summary = try build_neighbor_distance_histogram(order, kind, &entries);

    var subtotal_count: u32 = 0;
    for (entries[0..summary.entry_count]) |entry| {
        if (max_distance) |limit| {
            if (entry.distance > limit) break;
        }

        try write_neighbor_distance_histogram_entry(
            writer,
            entry,
            summary.directed_neighbor_count_total,
        );
        subtotal_count += entry.count;
    }

    try writer.writeAll("cumulative_percentage=");
    try write_percentage_hundredths(
        writer,
        percentage_hundredths_or_zero(subtotal_count, summary.directed_neighbor_count_total),
    );
    try writer.writeByte('\n');
}

test "write_neighbor_distances emits expected order 0 report" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_neighbor_distances(&writer, 0);

    const expected =
        \\d=0 pos=(0,0) N=- NE=- E=- SE=- S=- SW=- W=- NW=-
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "write_neighbor_distances emits expected order 1 report" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_neighbor_distances(&writer, 1);

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
    while (order <= max_order) : (order += 1) {
        const n = grid_size(order);
        const end = max_index(order);

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

                const neighbor = neighbor_point(n, point, dir);
                try std.testing.expectEqual(expected_present, neighbor != null);

                if (neighbor) |actual_neighbor| {
                    const neighbor_d = try hilbert_curve.xy2d(order, actual_neighbor);
                    try std.testing.expectEqual(
                        index_distance(d, neighbor_d),
                        index_distance(neighbor_d, d),
                    );
                    try std.testing.expectEqual(neighbor_d, try hilbert_curve.xy2d(order, actual_neighbor));
                }
            }

            if (d == end) break;
            d += 1;
        }
    }
}

test "write_neighbor_distance_histogram emits empty order 0 report" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_neighbor_distance_histogram(&writer, 0);

    try std.testing.expectEqualStrings("", writer.buffered());
}

test "write_neighbor_distance_histogram emits expected order 1 report" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_neighbor_distance_histogram(&writer, 1);

    const expected =
        \\distance=1 count=6 percentage=50.00%
        \\distance=2 count=4 percentage=33.33%
        \\distance=3 count=2 percentage=16.67%
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "write_neighbor_distance_histogram emits expected order 2 report" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_neighbor_distance_histogram(&writer, 2);

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

test "write_neighbor_distance_histogram_max_distance emits zero cutoff summary" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_neighbor_distance_histogram_max_distance(&writer, 1, 0);

    try std.testing.expectEqualStrings("cumulative_percentage=0.00%\n", writer.buffered());
}

test "write_neighbor_distance_histogram_max_distance emits expected order 2 report" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_neighbor_distance_histogram_max_distance(&writer, 2, 4);

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

test "write_neighbor_distance_histogram_max_distance emits full order 2 report for oversized cutoff" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_neighbor_distance_histogram_max_distance(&writer, 2, std.math.maxInt(u16));

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

test "write_neighbor_distance_histogram_filtered emits expected order 1 orthogonal report" {
    var buffer: [192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_neighbor_distance_histogram_filtered(&writer, 1, .orthogonal, null);

    const expected =
        \\distance=1 count=6 percentage=50.00%
        \\distance=3 count=2 percentage=16.67%
        \\cumulative_percentage=66.67%
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "write_neighbor_distance_histogram_filtered emits expected order 1 diagonal report" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_neighbor_distance_histogram_filtered(&writer, 1, .diagonal, null);

    const expected =
        \\distance=2 count=4 percentage=33.33%
        \\cumulative_percentage=33.33%
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "write_neighbor_distance_histogram_filtered emits explicit kind all summary" {
    var buffer: [192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_neighbor_distance_histogram_filtered(&writer, 1, .all, null);

    const expected =
        \\distance=1 count=6 percentage=50.00%
        \\distance=2 count=4 percentage=33.33%
        \\distance=3 count=2 percentage=16.67%
        \\cumulative_percentage=100.00%
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "write_neighbor_distance_histogram_filtered emits expected order 2 diagonal max-distance report" {
    var buffer: [192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_neighbor_distance_histogram_filtered(&writer, 2, .diagonal, 4);

    const expected =
        \\distance=2 count=24 percentage=28.57%
        \\distance=4 count=4 percentage=4.76%
        \\cumulative_percentage=33.33%
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "write_neighbor_distance_histogram_filtered emits empty filtered result summary" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_neighbor_distance_histogram_filtered(&writer, 1, .diagonal, 1);

    try std.testing.expectEqualStrings("cumulative_percentage=0.00%\n", writer.buffered());
}

test "write_neighbor_distance_histogram_filtered emits order 0 summary" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_neighbor_distance_histogram_filtered(&writer, 0, .orthogonal, null);

    try std.testing.expectEqualStrings("cumulative_percentage=0.00%\n", writer.buffered());
}

test "write_percentage rounds and zero pads to hundredths" {
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_percentage(&writer, 1, 8);
    try writer.writeByte(' ');
    try write_percentage(&writer, 1, 6);

    try std.testing.expectEqualStrings("12.50% 16.67%", writer.buffered());
}

test "parse_command accepts neighbors CLI shapes" {
    const neighbor_command = try parse_command(&.{"4"});
    const histogram_command = try parse_command(&.{ "histogram", "5" });
    const max_distance_command = try parse_command(&.{ "histogram", "5", "max-distance", "80" });
    const orthogonal_command = try parse_command(&.{ "histogram", "5", "kind", "orthogonal" });
    const combined_command = try parse_command(
        &.{ "histogram", "5", "max-distance", "80", "kind", "diagonal" },
    );

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

test "parse_command rejects malformed neighbors CLI shapes" {
    try std.testing.expectError(error.InvalidUsage, parse_command(&.{}));
    try std.testing.expectError(error.InvalidUsage, parse_command(&.{ "curve", "2" }));
    try std.testing.expectError(error.InvalidUsage, parse_command(&.{ "unknown", "2" }));
    try std.testing.expectError(error.InvalidUsage, parse_command(&.{ "histogram", "5", "max-distance" }));
    try std.testing.expectError(error.InvalidUsage, parse_command(&.{ "histogram", "5", "max-distance", "70000" }));
    try std.testing.expectError(error.InvalidUsage, parse_command(&.{ "histogram", "max-distance", "5", "80" }));
    try std.testing.expectError(error.InvalidUsage, parse_command(&.{ "histogram", "5", "kind" }));
    try std.testing.expectError(error.InvalidUsage, parse_command(&.{ "histogram", "5", "kind", "sideways" }));
    try std.testing.expectError(error.InvalidUsage, parse_command(&.{ "histogram", "5", "kind", "all", "kind", "diagonal" }));
    try std.testing.expectError(error.InvalidUsage, parse_command(&.{ "histogram", "5", "max-distance", "2", "max-distance", "4" }));
    try std.testing.expectError(error.InvalidUsage, parse_command(&.{ "histogram", "5", "kind", "all", "oops", "4" }));
}

test "run_cli dispatches neighbors CLI modes" {
    var report_buffer: [128]u8 = undefined;
    var report_writer: std.Io.Writer = .fixed(&report_buffer);
    var histogram_buffer: [128]u8 = undefined;
    var histogram_writer: std.Io.Writer = .fixed(&histogram_buffer);

    try run_cli(&report_writer, &.{"0"});
    try run_cli(&histogram_writer, &.{ "histogram", "1", "kind", "diagonal" });

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

test "run_cli returns invalid order for out-of-range neighbors order" {
    var buffer: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.InvalidOrder, run_cli(&writer, &.{"9"}));
}

test "max_order keeps neighbor distances within u16" {
    try std.testing.expectEqual(@as(u8, 8), max_order);
    try std.testing.expectEqual(@as(u16, 256), grid_size(max_order));
    try std.testing.expectEqual(std.math.maxInt(u16), max_index(max_order));
    try validate_order(max_order);
    try std.testing.expectError(error.InvalidOrder, validate_order(@as(u8, max_order + 1)));
}

test "neighbor distance histogram counts all valid neighbors" {
    var order: u8 = 0;
    while (order <= max_order) : (order += 1) {
        var counts: [histogram_bins]u32 = [_]u32{0} ** histogram_bins;
        const directed_neighbor_count_total = try fill_neighbor_distance_counts(order, .all, &counts);

        var histogram_total: u32 = 0;
        for (counts) |count| {
            histogram_total += count;
        }

        const n = grid_size(order);
        const end = max_index(order);
        var expected_total: u32 = 0;
        var d: u16 = 0;
        while (true) {
            const point = try hilbert_curve.d2xy(order, d);
            for (directions) |dir| {
                if (neighbor_point(n, point, dir) != null) {
                    expected_total += 1;
                }
            }

            if (d == end) break;
            d += 1;
        }

        try std.testing.expectEqual(expected_total, histogram_total);
        try std.testing.expectEqual(expected_total, directed_neighbor_count_total);
    }
}

test "orthogonal and diagonal histogram counts partition all neighbors" {
    var order: u8 = 0;
    while (order <= max_order) : (order += 1) {
        var all_counts: [histogram_bins]u32 = [_]u32{0} ** histogram_bins;
        var orthogonal_counts: [histogram_bins]u32 = [_]u32{0} ** histogram_bins;
        var diagonal_counts: [histogram_bins]u32 = [_]u32{0} ** histogram_bins;

        const all_total_count = try fill_neighbor_distance_counts(order, .all, &all_counts);
        const orthogonal_total_count = try fill_neighbor_distance_counts(
            order,
            .orthogonal,
            &orthogonal_counts,
        );
        const diagonal_total_count = try fill_neighbor_distance_counts(
            order,
            .diagonal,
            &diagonal_counts,
        );

        try std.testing.expectEqual(all_total_count, orthogonal_total_count);
        try std.testing.expectEqual(all_total_count, diagonal_total_count);

        for (all_counts, orthogonal_counts, diagonal_counts) |all_count, orthogonal_count, diagonal_count| {
            try std.testing.expectEqual(all_count, orthogonal_count + diagonal_count);
        }
    }
}
