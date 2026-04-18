const std = @import("std");
const fast_life = @import("fast_life");
const hilbert_curve = fast_life.hilbert_curve;
const hilbert_neighbors = fast_life.hilbert_neighbors;

const Route = union(enum) {
    curve: []const []const u8,
    neighbors: []const []const u8,
};

fn printUsage(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try hilbert_curve.appendUsage(writer, exe_name);
    try hilbert_neighbors.appendUsage(writer, exe_name);
    try writer.writeAll("Generate Hilbert curve points, Moore-neighbor distances, or a neighbor-distance histogram for order 0 through 8.\n");
}

fn printUsageAndFlush(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try printUsage(writer, exe_name);
    try writer.flush();
}

fn routeArgs(args: []const []const u8) !Route {
    return switch (args.len) {
        0 => error.InvalidUsage,
        1 => .{ .curve = args },
        else => if (std.mem.eql(u8, args[0], "curve"))
            .{ .curve = args[1..] }
        else if (std.mem.eql(u8, args[0], "neighbors"))
            .{ .neighbors = args[1..] }
        else
            error.InvalidUsage,
    };
}

fn runRoute(writer: *std.Io.Writer, route: Route) !void {
    return switch (route) {
        .curve => |args| hilbert_curve.runCli(writer, args),
        .neighbors => |args| hilbert_neighbors.runCli(writer, args),
    };
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

    const route = routeArgs(args[1..]) catch {
        try printUsageAndFlush(stderr_w, exe_name);
        return error.InvalidUsage;
    };

    runRoute(stdout_w, route) catch |err| switch (err) {
        error.InvalidUsage, error.InvalidOrder => {
            try printUsageAndFlush(stderr_w, exe_name);
            return err;
        },
        else => return err,
    };

    try stdout_w.flush();
}

test "routeArgs routes bare order to curve module" {
    const route = try routeArgs(&.{ "2" });

    switch (route) {
        .curve => |args| {
            try std.testing.expectEqual(@as(usize, 1), args.len);
            try std.testing.expectEqualStrings("2", args[0]);
        },
        .neighbors => unreachable,
    }
}

test "routeArgs routes explicit prefixes to the matching module" {
    const curve_route = try routeArgs(&.{ "curve", "3" });
    const neighbors_route = try routeArgs(&.{ "neighbors", "4" });

    switch (curve_route) {
        .curve => |args| {
            try std.testing.expectEqual(@as(usize, 1), args.len);
            try std.testing.expectEqualStrings("3", args[0]);
        },
        .neighbors => unreachable,
    }

    switch (neighbors_route) {
        .neighbors => |args| {
            try std.testing.expectEqual(@as(usize, 1), args.len);
            try std.testing.expectEqualStrings("4", args[0]);
        },
        .curve => unreachable,
    }
}

test "routeArgs rejects zero args and unknown prefixes" {
    try std.testing.expectError(error.InvalidUsage, routeArgs(&.{}));
    try std.testing.expectError(error.InvalidUsage, routeArgs(&.{ "unknown", "2" }));
}
