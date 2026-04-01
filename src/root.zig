const std = @import("std");

pub const hilbert_curve = @import("modules/hilbert_curve.zig");
pub const hilbert_neighbors = @import("modules/hilbert_neighbors.zig");

test "package root exposes canonical modules" {
    try std.testing.expectEqualDeep(hilbert_curve.Point{ .x = 0, .y = 3 }, try hilbert_curve.d2xy(2, 5));

    var buffer: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try hilbert_neighbors.writeNeighborDistanceHistogramFiltered(stream.writer(), 1, .diagonal, 1);

    try std.testing.expectEqualStrings("cumulative_percentage=0.00%\n", stream.getWritten());
}
