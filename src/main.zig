const std = @import("std");
const fast_life = @import("fast_life");
const hilbert_curve = fast_life.hilbert_curve;
const hilbert_neighbors = fast_life.hilbert_neighbors;

const Mode = enum {
    curve,
    neighbors,
    neighbors_histogram,
};

const Command = struct {
    mode: Mode,
    order: u8,
    kind: hilbert_neighbors.NeighborKind = .all,
    kind_explicit: bool = false,
    max_distance: ?u16 = null,
};

fn printUsage(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try writer.print("Usage: {s} <order>\n", .{exe_name});
    try writer.print("       {s} curve <order>\n", .{exe_name});
    try writer.print("       {s} neighbors <order>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order> kind <all|orthogonal|diagonal>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order> max-distance <distance>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order> kind <all|orthogonal|diagonal> max-distance <distance>\n", .{exe_name});
    try writer.print("       {s} neighbors histogram <order> max-distance <distance> kind <all|orthogonal|diagonal>\n", .{exe_name});
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

fn parseNeighborKind(arg: []const u8) !hilbert_neighbors.NeighborKind {
    if (std.mem.eql(u8, arg, "all")) return .all;
    if (std.mem.eql(u8, arg, "orthogonal")) return .orthogonal;
    if (std.mem.eql(u8, arg, "diagonal")) return .diagonal;
    return error.InvalidUsage;
}

fn parseHistogramCommand(args: []const []const u8) !Command {
    if (args.len < 3) return error.InvalidUsage;

    var command = Command{
        .mode = .neighbors_histogram,
        .order = try parseOrder(args[2]),
    };

    const option_count = args.len - 3;
    if (option_count % 2 != 0) {
        return error.InvalidUsage;
    }

    var i: usize = 3;
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
    if (args.len >= 3 and std.mem.eql(u8, args[0], "neighbors") and std.mem.eql(u8, args[1], "histogram")) {
        return parseHistogramCommand(args);
    }

    return switch (args.len) {
        1 => .{
            .mode = .curve,
            .order = try parseOrder(args[0]),
            .kind = .all,
            .kind_explicit = false,
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
            .kind = .all,
            .kind_explicit = false,
            .max_distance = null,
        },
        else => error.InvalidUsage,
    };
}

fn writeCommand(writer: *std.Io.Writer, command: Command) !void {
    return switch (command.mode) {
        .curve => hilbert_curve.writeCurve(writer, command.order),
        .neighbors => hilbert_neighbors.writeNeighborDistances(writer, command.order),
        .neighbors_histogram => if (command.kind_explicit or command.max_distance != null)
            hilbert_neighbors.writeNeighborDistanceHistogramFiltered(writer, command.order, command.kind, command.max_distance)
        else
            hilbert_neighbors.writeNeighborDistanceHistogram(writer, command.order),
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

    var arg_storage: [7][]const u8 = undefined;
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
    const orthogonal_command = try parseCommand(&.{ "neighbors", "histogram", "5", "kind", "orthogonal" });
    const combined_command = try parseCommand(&.{ "neighbors", "histogram", "5", "max-distance", "80", "kind", "diagonal" });

    try std.testing.expectEqual(Mode.curve, curve_command.mode);
    try std.testing.expectEqual(@as(u8, 3), curve_command.order);
    try std.testing.expectEqual(hilbert_neighbors.NeighborKind.all, curve_command.kind);
    try std.testing.expectEqual(false, curve_command.kind_explicit);
    try std.testing.expectEqual(@as(?u16, null), curve_command.max_distance);
    try std.testing.expectEqual(Mode.neighbors, neighbor_command.mode);
    try std.testing.expectEqual(@as(u8, 4), neighbor_command.order);
    try std.testing.expectEqual(hilbert_neighbors.NeighborKind.all, neighbor_command.kind);
    try std.testing.expectEqual(false, neighbor_command.kind_explicit);
    try std.testing.expectEqual(@as(?u16, null), neighbor_command.max_distance);
    try std.testing.expectEqual(Mode.neighbors_histogram, histogram_command.mode);
    try std.testing.expectEqual(@as(u8, 5), histogram_command.order);
    try std.testing.expectEqual(hilbert_neighbors.NeighborKind.all, histogram_command.kind);
    try std.testing.expectEqual(false, histogram_command.kind_explicit);
    try std.testing.expectEqual(@as(?u16, null), histogram_command.max_distance);
    try std.testing.expectEqual(Mode.neighbors_histogram, max_distance_command.mode);
    try std.testing.expectEqual(@as(u8, 5), max_distance_command.order);
    try std.testing.expectEqual(hilbert_neighbors.NeighborKind.all, max_distance_command.kind);
    try std.testing.expectEqual(false, max_distance_command.kind_explicit);
    try std.testing.expectEqual(@as(?u16, 80), max_distance_command.max_distance);
    try std.testing.expectEqual(Mode.neighbors_histogram, orthogonal_command.mode);
    try std.testing.expectEqual(@as(u8, 5), orthogonal_command.order);
    try std.testing.expectEqual(hilbert_neighbors.NeighborKind.orthogonal, orthogonal_command.kind);
    try std.testing.expectEqual(true, orthogonal_command.kind_explicit);
    try std.testing.expectEqual(@as(?u16, null), orthogonal_command.max_distance);
    try std.testing.expectEqual(Mode.neighbors_histogram, combined_command.mode);
    try std.testing.expectEqual(@as(u8, 5), combined_command.order);
    try std.testing.expectEqual(hilbert_neighbors.NeighborKind.diagonal, combined_command.kind);
    try std.testing.expectEqual(true, combined_command.kind_explicit);
    try std.testing.expectEqual(@as(?u16, 80), combined_command.max_distance);
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
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "neighbors", "histogram", "5", "kind" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "neighbors", "histogram", "5", "kind", "sideways" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "neighbors", "histogram", "5", "kind", "all", "kind", "diagonal" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "neighbors", "histogram", "5", "max-distance", "2", "max-distance", "4" }));
    try std.testing.expectError(error.InvalidUsage, parseCommand(&.{ "neighbors", "histogram", "5", "kind", "all", "oops", "4" }));
}
