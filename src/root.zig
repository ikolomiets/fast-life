const std = @import("std");

pub const block = @import("modules/block.zig");
pub const grid = @import("modules/grid.zig");
pub const hilbert_curve = @import("modules/hilbert_curve.zig");
pub const hilbert_neighbors = @import("modules/hilbert_neighbors.zig");

test "package root exposes canonical modules" {
    try std.testing.expectEqualDeep(hilbert_curve.Point{ .x = 0, .y = 3 }, try hilbert_curve.d2xy(2, 5));

    var buffer: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try hilbert_neighbors.writeNeighborDistanceHistogramFiltered(stream.writer(), 1, .diagonal, 1);

    try std.testing.expectEqualStrings("cumulative_percentage=0.00%\n", stream.getWritten());
}

test "package root exposes block and grid modules" {
    const Grid = grid.BinaryGrid(0, block.PackedBlock4x4);
    var binary_grid = Grid.initEmpty();

    try binary_grid.setCell(.{ .x = 3, .y = 3 }, true);

    try std.testing.expect(try binary_grid.getCell(.{ .x = 3, .y = 3 }));
    try std.testing.expect((try binary_grid.getBlock(0)).get(3, 3));
}
