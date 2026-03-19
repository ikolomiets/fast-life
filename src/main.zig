const std = @import("std");
const hilbert = @import("hilbert.zig");

const Mode = enum {
    curve,
    neighbors,
    neighbors_histogram,
};

const Command = struct {
    mode: Mode,
    order: u8,
    max_distance: ?u16 = null,
};

fn printUsage(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try writer.print("Usage: {s} <order>\n", .{exe_name});
    try writer.print("       {s} curve <order>\n", .{exe_name});
    try writer.print("       {s} neighbors <order>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order> max-distance <distance>\n", .{exe_name});
    try writer.writeAll("Generate Hilbert curve points, Moore-neighbor distances, or a neighbor-distance histogram for order 0 through 8.\n");
}

fn printUsageAndFlush(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try printUsage(writer, exe_name);
    try writer.flush();
}

fn parseOrder(arg: []const u8) !u8 {
    return std.fmt.parseInt(u8, arg, 10) catch error.InvalidUsage;
}

fn parseMaxDistance(arg: []const u8) !u16 {
    return std.fmt.parseInt(u16, arg, 10) catch error.InvalidUsage;
}

fn parseCommand(args: []const []const u8) !Command {
    return switch (args.len) {
        1 => .{
            .mode = .curve,
            .order = try parseOrder(args[0]),
            .max_distance = null,
        },
        2 => .{
            .mode = if (std.mem.eql(u8, args[0], "curve"))
                .curve
            else if (std.mem.eql(u8, args[0], "neighbors"))
                .neighbors
            else
                return error.InvalidUsage,
            .order = try parseOrder(args[1]),
            .max_distance = null,
        },
        3 => .{
            .mode = if (std.mem.eql(u8, args[0], "neighbors") and std.mem.eql(u8, args[1], "histogram"))
                .neighbors_histogram
            else
                return error.InvalidUsage,
            .order = try parseOrder(args[2]),
            .max_distance = null,
        },
        5 => .{
            .mode = if (std.mem.eql(u8, args[0], "neighbors") and
                std.mem.eql(u8, args[1], "histogram") and
                std.mem.eql(u8, args[3], "max-distance"))
                .neighbors_histogram
            else
                return error.InvalidUsage,
            .order = try parseOrder(args[2]),
            .max_distance = try parseMaxDistance(args[4]),
        },
        else => error.InvalidUsage,
    };
}

fn writeCommand(writer: *std.Io.Writer, command: Command) !void {
    return switch (command.mode) {
        .curve => hilbert.writeCurve(writer, command.order),
        .neighbors => hilbert.writeNeighborDistances(writer, command.order),
        .neighbors_histogram => if (command.max_distance) |max_distance|
            hilbert.writeNeighborDistanceHistogramMaxDistance(writer, command.order, max_distance)
        else
            hilbert.writeNeighborDistanceHistogram(writer, command.order),
    };
}

pub fn main() !void {
    var args = std.process.args();
    const exe_name = args.next() orelse "hilbert_curve";

    var stdout_buffer: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&.{});
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    const stderr_w = &stderr.interface;
    const stdout_w = &stdout.interface;

    var arg_storage: [5][]const u8 = undefined;
    var arg_count: usize = 0;
    while (args.next()) |arg| {
        if (arg_count == arg_storage.len) {
            try printUsageAndFlush(stderr_w, exe_name);
            return error.InvalidUsage;
        }
        arg_storage[arg_count] = arg;
        arg_count += 1;
    }

    const command = parseCommand(arg_storage[0..arg_count]) catch {
        try printUsageAndFlush(stderr_w, exe_name);
        return error.InvalidUsage;
    };

    writeCommand(stdout_w, command) catch |err| switch (err) {
        error.InvalidOrder => {
            try printUsageAndFlush(stderr_w, exe_name);
            return err;
        },
        else => return err,
    };

    try stdout_w.flush();
}

test "parseCommand accepts bare order as curve mode" {
    const command = try parseCommand(&.{ "2" });

    try std.testing.expectEqual(Mode.curve, command.mode);
    try std.testing.expectEqual(@as(u8, 2), command.order);
}

test "parseCommand accepts explicit modes" {
    const curve_command = try parseCommand(&.{ "curve", "3" });
    const neighbor_command = try parseCommand(&.{ "neighbors", "4" });
    const histogram_command = try parseCommand(&.{ "neighbors", "histogram", "5" });
    const max_distance_command = try parseCommand(&.{ "neighbors", "histogram", "5", "max-distance", "80" });

    try std.testing.expectEqual(Mode.curve, curve_command.mode);
    try std.testing.expectEqual(@as(u8, 3), curve_command.order);
    try std.testing.expectEqual(@as(?u16, null), curve_command.max_distance);
    try std.testing.expectEqual(Mode.neighbors, neighbor_command.mode);
    try std.testing.expectEqual(@as(u8, 4), neighbor_command.order);
    try std.testing.expectEqual(@as(?u16, null), neighbor_command.max_distance);
    try std.testing.expectEqual(Mode.neighbors_histogram, histogram_command.mode);
    try std.testing.expectEqual(@as(u8, 5), histogram_command.order);
    try std.testing.expectEqual(@as(?u16, null), histogram_command.max_distance);
    try std.testing.expectEqual(Mode.neighbors_histogram, max_distance_command.mode);
    try std.testing.expectEqual(@as(u8, 5), max_distance_command.order);
    try std.testing.expectEqual(@as(?u16, 80), max_distance_command.max_distance);
}

test "parseCommand rejects invalid arg shapes" {
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{}));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "neighbors" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "unknown", "2" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "neighbors", "unknown", "2" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "1", "2", "3" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "neighbors", "histogram", "5", "max-distance" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "neighbors", "histogram", "5", "max-distance", "70000" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "neighbors", "histogram", "max-distance", "5", "80" }));
}
