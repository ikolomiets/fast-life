const std = @import("std");

pub const grid = @import("modules/binary_grid.zig");
pub const hilbert_curve = @import("modules/hilbert_curve.zig");
pub const hilbert_neighbors = @import("modules/hilbert_neighbors.zig");

test "package root exposes canonical modules" {
    try std.testing.expectEqualDeep(hilbert_curve.Point{ .x = 0, .y = 3 }, try hilbert_curve.d2xy(2, 5));

    var buffer: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try hilbert_neighbors.writeNeighborDistanceHistogramFiltered(stream.writer(), 1, .diagonal, 1);

    try std.testing.expectEqualStrings("cumulative_percentage=0.00%\n", stream.getWritten());
}

test "package root exposes grid block and grid APIs" {
    const Grid = grid.BinaryGrid(0);
    var binary_grid = Grid.initEmpty();
    var block = grid.Block.init(false);

    block.set(3, 3, true);
    try binary_grid.setBlock(0, block);

    try std.testing.expect(try binary_grid.getCell(.{ .x = 3, .y = 3 }));
    try std.testing.expect((try binary_grid.getBlock(0)).get(3, 3));
}
