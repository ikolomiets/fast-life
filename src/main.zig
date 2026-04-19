const std = @import("std");
const fast_life = @import("fast_life");
const hilbert_curve = fast_life.hilbert_curve;
const hilbert_neighbors = fast_life.hilbert_neighbors;

const Route = union(enum) {
    curve: []const []const u8,
    neighbors: []const []const u8,
};

fn print_usage(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try hilbert_curve.append_usage(writer, exe_name);
    try hilbert_neighbors.append_usage(writer, exe_name);
    try writer.writeAll("Generate Hilbert curve points, Moore-neighbor distances, or a neighbor-distance histogram for order 0 through 8.\n");
}

fn print_usage_and_flush(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try print_usage(writer, exe_name);
    try writer.flush();
}

fn route_args(args: []const []const u8) !Route {
    if (args.len == 0) {
        return error.InvalidUsage;
    }

    // Preserve the original CLI shape where a bare order means "print the curve".
    if (args.len == 1) {
        return .{ .curve = args };
    }

    if (std.mem.eql(u8, args[0], "curve")) {
        return .{ .curve = args[1..] };
    }
    if (std.mem.eql(u8, args[0], "neighbors")) {
        return .{ .neighbors = args[1..] };
    }

    return error.InvalidUsage;
}

fn run_route(writer: *std.Io.Writer, route: Route) !void {
    return switch (route) {
        .curve => |args| hilbert_curve.run_cli(writer, args),
        .neighbors => |args| hilbert_neighbors.run_cli(writer, args),
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const exe_name = if (args.len != 0) args[0] else "hilbert_curve";

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_writer_state = std.Io.File.stderr().writer(io, &.{});
    var stdout_writer_state = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stderr_writer = &stderr_writer_state.interface;
    const stdout_writer = &stdout_writer_state.interface;

    const route = route_args(args[1..]) catch {
        try print_usage_and_flush(stderr_writer, exe_name);
        return error.InvalidUsage;
    };

    run_route(stdout_writer, route) catch |err| switch (err) {
        error.InvalidUsage, error.InvalidOrder => {
            try print_usage_and_flush(stderr_writer, exe_name);
            return err;
        },
        else => return err,
    };

    try stdout_writer.flush();
}

test "route_args routes bare order to curve module" {
    const route = try route_args(&.{"2"});

    switch (route) {
        .curve => |args| {
            try std.testing.expectEqual(@as(usize, 1), args.len);
            try std.testing.expectEqualStrings("2", args[0]);
        },
        .neighbors => unreachable,
    }
}

test "route_args routes explicit prefixes to the matching module" {
    const curve_route = try route_args(&.{ "curve", "3" });
    const neighbors_route = try route_args(&.{ "neighbors", "4" });

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

test "route_args rejects zero args and unknown prefixes" {
    try std.testing.expectError(error.InvalidUsage, route_args(&.{}));
    try std.testing.expectError(error.InvalidUsage, route_args(&.{ "unknown", "2" }));
}

test "run_route dispatches curve and neighbors routes" {
    var curve_buffer: [32]u8 = undefined;
    var curve_writer: std.Io.Writer = .fixed(&curve_buffer);
    var neighbors_buffer: [128]u8 = undefined;
    var neighbors_writer: std.Io.Writer = .fixed(&neighbors_buffer);

    try run_route(&curve_writer, .{ .curve = &.{"0"} });
    try run_route(&neighbors_writer, .{ .neighbors = &.{"0"} });

    try std.testing.expectEqualStrings(
        \\0 0 0
        \\
    , curve_writer.buffered());
    try std.testing.expectEqualStrings(
        \\d=0 pos=(0,0) N=- NE=- E=- SE=- S=- SW=- W=- NW=-
        \\
    , neighbors_writer.buffered());
}

test "print_usage includes curve and neighbors help" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try print_usage(&writer, "hilbert_curve");

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Usage: hilbert_curve <order>\n") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, writer.buffered(), "hilbert_curve neighbors histogram <order>\n") != null,
    );
}
