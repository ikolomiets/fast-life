const std = @import("std");

pub const binary_grid = @import("modules/binary_grid.zig");
pub const hilbert_curve = @import("modules/hilbert_curve.zig");
pub const hilbert_neighbors = @import("modules/hilbert_neighbors.zig");
pub const life_rle = @import("modules/life_rle.zig");

test "package_root_exposes_canonical_modules" {
    try std.testing.expectEqualDeep(hilbert_curve.Point{ .x = 0, .y = 3 }, try hilbert_curve.d2xy(2, 5));

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try hilbert_neighbors.write_neighbor_distance_histogram_filtered(&writer, 1, .diagonal, 1);

    try std.testing.expectEqualStrings("cumulative_percentage=0.00%\n", writer.buffered());
}

test "package_root_exposes_binary_grid_block_and_grid_apis" {
    const Grid = binary_grid.BinaryGrid(0);
    var grid_instance: Grid = undefined;
    grid_instance.init_empty();
    var block = binary_grid.Block.empty();

    block.set(3, 3, true);
    try grid_instance.set_block(0, block);

    try std.testing.expect(try grid_instance.get_cell(.{ .x = 3, .y = 3 }));
    try std.testing.expect((try grid_instance.get_block(0)).get(3, 3));
}

test "package_root_exposes_life_rle_module" {
    var pattern = try life_rle.parse_pattern(std.testing.allocator,
        \\x = 1, y = 1
        \\o!
        \\
    );
    defer pattern.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), pattern.width);
    try std.testing.expectEqual(@as(usize, 1), pattern.height);
    try std.testing.expectEqual(@as(usize, 1), pattern.live_cells.len);
    try std.testing.expectEqualDeep(life_rle.PatternCell{ .x = 0, .y = 0 }, pattern.live_cells[0]);
}
