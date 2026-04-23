const std = @import("std");
const fast_life = @import("fast_life");
const binary_grid = fast_life.binary_grid;
const game_of_life = fast_life.game_of_life;
const life_rle = fast_life.life_rle;

const cli_grid_order: usize = 8;
const cli_grid_side: usize = binary_grid.BinaryGrid(cli_grid_order).cells_per_side;
const cli_pattern_origin = binary_grid.CellCoord{ .x = 400, .y = 400 };
const Life = game_of_life.GameOfLife(cli_grid_order);

var cli_life: Life = undefined;

fn parse_steps(arg: []const u8) !u64 {
    return std.fmt.parseInt(u64, arg, 10) catch error.InvalidUsage;
}

fn validate_cli_pattern_fits(pattern: life_rle.Pattern) !void {
    if (pattern.width > cli_grid_side) {
        return error.PatternTooLargeForBinaryGrid;
    }
    if (pattern.height > cli_grid_side) {
        return error.PatternTooLargeForBinaryGrid;
    }
}

fn write_grid_file(
    comptime grid_order: usize,
    io: std.Io,
    path: []const u8,
    grid: *const binary_grid.BinaryGrid(grid_order),
) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var file_writer = file.writer(io, &.{});
    const writer = &file_writer.interface;

    life_rle.write_grid(grid_order, writer, grid) catch |err| switch (err) {
        error.WriteFailed => return file_writer.err.?,
        else => return err,
    };

    writer.flush() catch |err| switch (err) {
        error.WriteFailed => return file_writer.err.?,
    };
}

fn write_timing_summary(writer: *std.Io.Writer, steps: u64, elapsed: std.Io.Duration) !void {
    const elapsed_ns_signed = elapsed.toNanoseconds();
    std.debug.assert(elapsed_ns_signed >= 0);

    const elapsed_ns: u128 = @intCast(elapsed_ns_signed);
    const ns_per_s: u128 = std.time.ns_per_s;
    const ns_per_us: u128 = std.time.ns_per_us;
    const elapsed_seconds = elapsed_ns / ns_per_s;
    const elapsed_microseconds = (elapsed_ns % ns_per_s) / ns_per_us;

    const generations_per_second: u128 = if (steps == 0 or elapsed_ns == 0)
        0
    else
        ((@as(u128, steps) * ns_per_s) + elapsed_ns / 2) / elapsed_ns;

    try writer.print(
        "time_s={d}.{d:0>6} generations_per_second={d}\n",
        .{ elapsed_seconds, elapsed_microseconds, generations_per_second },
    );
}

fn print_usage(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try writer.print("Usage: {s} <steps> <input-rle-path> <output-rle-path>\n", .{exe_name});
    try writer.writeAll(
        "Load a Life RLE pattern into GameOfLife(8), evolve it for the requested number of generations, write canonical RLE output, and print step timing to stdout.\n",
    );
}

fn print_usage_and_flush(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try print_usage(writer, exe_name);
    try writer.flush();
}

fn run_cli_with_writer(
    writer: *std.Io.Writer,
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len != 3) {
        return error.InvalidUsage;
    }

    const steps = try parse_steps(args[0]);

    var pattern = try life_rle.parse_pattern_file(io, allocator, args[1]);
    defer pattern.deinit(allocator);

    try validate_cli_pattern_fits(pattern);

    const generation_zero_grid = cli_life.init_generation_zero_grid();

    life_rle.apply_pattern(cli_grid_order, generation_zero_grid, pattern, cli_pattern_origin) catch |err| switch (err) {
        error.InvalidPattern, error.PatternOutOfRange => unreachable,
    };

    var elapsed = std.Io.Duration.zero;
    if (steps != 0) {
        const start = std.Io.Clock.awake.now(io);

        var step_index: u64 = 0;
        while (step_index < steps) : (step_index += 1) {
            cli_life.step_block();
        }

        elapsed = start.durationTo(std.Io.Clock.awake.now(io));
    }

    try write_grid_file(cli_grid_order, io, args[2], cli_life.current_grid());
    try write_timing_summary(writer, steps, elapsed);
}

fn run_cli(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var stdout_buffer: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout_w = &stdout.interface;

    try run_cli_with_writer(stdout_w, io, allocator, args);
    try stdout_w.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const exe_name = if (args.len != 0) args[0] else "fast_life";

    game_of_life.init_runtime_luts();

    var stderr = std.Io.File.stderr().writer(io, &.{});
    const stderr_w = &stderr.interface;

    run_cli(io, allocator, args[1..]) catch |err| switch (err) {
        error.InvalidUsage => {
            try print_usage_and_flush(stderr_w, exe_name);
            return err;
        },
        else => return err,
    };
}

fn tmp_file_path(buffer: []u8, tmp_dir: *const std.testing.TmpDir, file_name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/{s}", .{ tmp_dir.sub_path, file_name });
}

test "print_usage describes the Game of Life CLI" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try print_usage(&writer, "fast_life");

    try std.testing.expect(
        std.mem.indexOf(u8, writer.buffered(), "Usage: fast_life <steps> <input-rle-path> <output-rle-path>\n") != null,
    );
}

test "write_timing_summary formats zero steps as zeros" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_timing_summary(&writer, 0, .zero);

    try std.testing.expectEqualStrings(
        "time_s=0.000000 generations_per_second=0\n",
        writer.buffered(),
    );
}

test "write_timing_summary formats elapsed time with microsecond precision" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_timing_summary(&writer, 1, std.Io.Duration.fromMicroseconds(400_000));

    try std.testing.expectEqualStrings(
        "time_s=0.400000 generations_per_second=3\n",
        writer.buffered(),
    );
}

test "write_timing_summary prints zero throughput when elapsed time is zero" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_timing_summary(&writer, 9, .zero);

    try std.testing.expectEqualStrings(
        "time_s=0.000000 generations_per_second=0\n",
        writer.buffered(),
    );
}

test "run_cli rewrites generation zero output and reports zero timing" {
    game_of_life.init_runtime_luts();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "input.rle",
        .data =
        \\x = 6, y = 6
        \\$2bo$3bo$b3o!
        \\
        ,
    });

    var input_path_buffer: [128]u8 = undefined;
    const input_path = try tmp_file_path(&input_path_buffer, &tmp_dir, "input.rle");
    var output_path_buffer: [128]u8 = undefined;
    const output_path = try tmp_file_path(&output_path_buffer, &tmp_dir, "output.rle");
    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buffer);

    try run_cli_with_writer(&stdout_writer, std.testing.io, std.testing.allocator, &.{ "0", input_path, output_path });

    const written = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        output_path,
        std.testing.allocator,
        .limited(life_rle.max_pattern_file_bytes),
    );
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(
        \\x = 3, y = 3
        \\bo$2bo$3o!
        \\
    , written);

    try std.testing.expectEqualStrings(
        "time_s=0.000000 generations_per_second=0\n",
        stdout_writer.buffered(),
    );
}

test "run_cli advances requested generations and reports timing summary" {
    game_of_life.init_runtime_luts();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "input.rle",
        .data =
        \\x = 3, y = 3
        \\bob$bob$bob!
        \\
        ,
    });

    var input_path_buffer: [128]u8 = undefined;
    const input_path = try tmp_file_path(&input_path_buffer, &tmp_dir, "input.rle");
    var output_path_buffer: [128]u8 = undefined;
    const output_path = try tmp_file_path(&output_path_buffer, &tmp_dir, "output.rle");
    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buffer);

    try run_cli_with_writer(&stdout_writer, std.testing.io, std.testing.allocator, &.{ "1", input_path, output_path });

    const written = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        output_path,
        std.testing.allocator,
        .limited(life_rle.max_pattern_file_bytes),
    );
    defer std.testing.allocator.free(written);

    try std.testing.expectEqualStrings(
        \\x = 3, y = 1
        \\3o!
        \\
    , written);
    try std.testing.expect(std.mem.startsWith(u8, stdout_writer.buffered(), "time_s="));
    try std.testing.expect(std.mem.indexOf(u8, stdout_writer.buffered(), " generations_per_second=") != null);
}

test "run_cli rejects invalid usage and invalid steps" {
    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buffer);

    try std.testing.expectError(error.InvalidUsage, run_cli_with_writer(&stdout_writer, std.testing.io, std.testing.allocator, &.{}));
    try std.testing.expectError(
        error.InvalidUsage,
        run_cli_with_writer(&stdout_writer, std.testing.io, std.testing.allocator, &.{ "abc", "input.rle", "output.rle" }),
    );
}

test "run_cli rejects declared width larger than the fixed grid side" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "too_wide.rle",
        .data =
        \\x = 1025, y = 1
        \\o!
        \\
        ,
    });

    var input_path_buffer: [128]u8 = undefined;
    const input_path = try tmp_file_path(&input_path_buffer, &tmp_dir, "too_wide.rle");
    var output_path_buffer: [128]u8 = undefined;
    const output_path = try tmp_file_path(&output_path_buffer, &tmp_dir, "output.rle");
    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buffer);

    try std.testing.expectError(
        error.PatternTooLargeForBinaryGrid,
        run_cli_with_writer(&stdout_writer, std.testing.io, std.testing.allocator, &.{ "0", input_path, output_path }),
    );
}

test "run_cli rejects declared height larger than the fixed grid side" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "too_tall.rle",
        .data =
        \\x = 1, y = 1025
        \\o!
        \\
        ,
    });

    var input_path_buffer: [128]u8 = undefined;
    const input_path = try tmp_file_path(&input_path_buffer, &tmp_dir, "too_tall.rle");
    var output_path_buffer: [128]u8 = undefined;
    const output_path = try tmp_file_path(&output_path_buffer, &tmp_dir, "output.rle");
    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buffer);

    try std.testing.expectError(
        error.PatternTooLargeForBinaryGrid,
        run_cli_with_writer(&stdout_writer, std.testing.io, std.testing.allocator, &.{ "0", input_path, output_path }),
    );
}

test "run_cli propagates EmptyPattern for an empty input pattern" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "empty.rle",
        .data =
        \\x = 4, y = 3
        \\!
        \\
        ,
    });

    var input_path_buffer: [128]u8 = undefined;
    const input_path = try tmp_file_path(&input_path_buffer, &tmp_dir, "empty.rle");
    var output_path_buffer: [128]u8 = undefined;
    const output_path = try tmp_file_path(&output_path_buffer, &tmp_dir, "output.rle");
    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buffer);

    try std.testing.expectError(
        error.EmptyPattern,
        run_cli_with_writer(&stdout_writer, std.testing.io, std.testing.allocator, &.{ "0", input_path, output_path }),
    );
}
