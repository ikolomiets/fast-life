const std = @import("std");

pub const PackedBlock4x4 = struct {
    bits: u16,

    pub const side: usize = 4;

    const Self = @This();
    const filled_bits = std.math.maxInt(u16);

    pub fn init(fill: bool) Self {
        return .{
            .bits = if (fill) filled_bits else 0,
        };
    }

    fn bitIndex(x: u2, y: u2) u4 {
        return (@as(u4, y) << 2) | @as(u4, x);
    }

    fn bitMask(x: u2, y: u2) u16 {
        return @as(u16, 1) << bitIndex(x, y);
    }

    pub fn get(self: Self, x: u2, y: u2) bool {
        return (self.bits & bitMask(x, y)) != 0;
    }

    pub fn set(self: *Self, x: u2, y: u2, value: bool) void {
        const mask = bitMask(x, y);
        const fill_mask: u16 = if (value) filled_bits else 0;
        self.bits = (self.bits & ~mask) | (fill_mask & mask);
    }

    pub fn rowMask(self: Self, y: u2) u4 {
        return @intCast((self.bits >> (@as(u4, y) << 2)) & 0b1111);
    }

    pub fn count(self: Self) u5 {
        return @intCast(@popCount(self.bits));
    }

    pub fn any(self: Self) bool {
        return self.bits != 0;
    }

    pub fn all(self: Self) bool {
        return self.bits == filled_bits;
    }
};

test "PackedBlock4x4 initializes empty and filled states" {
    const empty = PackedBlock4x4.init(false);
    const filled = PackedBlock4x4.init(true);

    try std.testing.expectEqual(@as(u16, 0), empty.bits);
    try std.testing.expectEqual(@as(u5, 0), empty.count());
    try std.testing.expect(!empty.any());
    try std.testing.expect(!empty.all());

    try std.testing.expectEqual(std.math.maxInt(u16), filled.bits);
    try std.testing.expectEqual(@as(u5, 16), filled.count());
    try std.testing.expect(filled.any());
    try std.testing.expect(filled.all());
}

test "PackedBlock4x4 reads and writes individual cells" {
    var block = PackedBlock4x4.init(false);

    try std.testing.expect(!block.get(0, 0));
    try std.testing.expect(!block.get(3, 3));

    block.set(0, 0, true);
    block.set(2, 1, true);
    block.set(3, 3, true);

    try std.testing.expect(block.get(0, 0));
    try std.testing.expect(block.get(2, 1));
    try std.testing.expect(block.get(3, 3));
    try std.testing.expectEqual(@as(u5, 3), block.count());
    try std.testing.expectEqual(@as(u4, 0b0001), block.rowMask(0));
    try std.testing.expectEqual(@as(u4, 0b0100), block.rowMask(1));
    try std.testing.expectEqual(@as(u4, 0b0000), block.rowMask(2));
    try std.testing.expectEqual(@as(u4, 0b1000), block.rowMask(3));

    block.set(2, 1, false);

    try std.testing.expect(!block.get(2, 1));
    try std.testing.expectEqual(@as(u5, 2), block.count());
    try std.testing.expectEqual(@as(u4, 0b0000), block.rowMask(1));
}
