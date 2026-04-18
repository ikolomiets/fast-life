const std = @import("std");

pub const max_order: usize = 12;

pub const Block = struct {
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

pub const BlockCoord = struct {
    x: usize,
    y: usize,
};

pub const CellCoord = struct {
    x: usize,
    y: usize,
};

fn pointerToBlock(comptime GridPtr: type) type {
    return switch (@typeInfo(GridPtr)) {
        .pointer => |pointer_info| if (pointer_info.is_const) *const Block else *Block,
        else => @compileError("expected a grid pointer receiver"),
    };
}

fn sliceOfBlocks(comptime GridPtr: type) type {
    return switch (@typeInfo(GridPtr)) {
        .pointer => |pointer_info| if (pointer_info.is_const) []const Block else []Block,
        else => @compileError("expected a grid pointer receiver"),
    };
}

pub fn BinaryGrid(comptime grid_order: usize) type {
    const Shift = std.math.Log2Int(usize);
    if (grid_order > max_order) {
        @compileError(std.fmt.comptimePrint("BinaryGrid order must be <= {d}", .{max_order}));
    }
    const order_shift: Shift = @intCast(grid_order);

    const block_side_shift: Shift = 2;
    const local_mask = Block.side - 1;
    const blocks_per_side_value: usize = @as(usize, 1) << order_shift;
    const block_count_value: usize = blocks_per_side_value * blocks_per_side_value;
    const cells_per_side_value: usize = blocks_per_side_value * Block.side;
    const cell_count_value: usize = cells_per_side_value * cells_per_side_value;

    return struct {
        blocks: [block_count_value]Block,

        const Self = @This();

        pub const order: usize = grid_order;
        pub const block_side: usize = Block.side;
        pub const blocks_per_side = blocks_per_side_value;
        pub const block_count = block_count_value;
        pub const cells_per_side = cells_per_side_value;
        pub const cell_count = cell_count_value;

        pub fn initEmpty() Self {
            var self: Self = undefined;
            @memset(self.blocks[0..], Block.init(false));
            return self;
        }

        pub fn initFilled() Self {
            var self: Self = undefined;
            @memset(self.blocks[0..], Block.init(true));
            return self;
        }

        pub fn clear(self: *Self) void {
            @memset(self.blocks[0..], Block.init(false));
        }

        pub fn fill(self: *Self) void {
            @memset(self.blocks[0..], Block.init(true));
        }

        pub fn asSlice(self: *Self) []Block {
            return self.blocks[0..];
        }

        pub fn asConstSlice(self: *const Self) []const Block {
            return self.blocks[0..];
        }

        pub fn blockIndex(coord: BlockCoord) error{BlockCoordOutOfRange}!usize {
            try validateBlockCoord(coord);
            return blockIndexUnchecked(coord);
        }

        pub fn blockIndexUnchecked(coord: BlockCoord) usize {
            std.debug.assert(coord.x < blocks_per_side);
            std.debug.assert(coord.y < blocks_per_side);
            return (coord.y << order_shift) | coord.x;
        }

        pub fn blockCoord(index: usize) error{IndexOutOfRange}!BlockCoord {
            try validateBlockIndex(index);
            return blockCoordUnchecked(index);
        }

        pub fn blockCoordUnchecked(index: usize) BlockCoord {
            std.debug.assert(index < block_count);
            return .{
                .x = index & (blocks_per_side - 1),
                .y = index >> order_shift,
            };
        }

        pub fn getBlock(self: *const Self, index: usize) error{IndexOutOfRange}!Block {
            try validateBlockIndex(index);
            return self.blocks[index];
        }

        pub fn getBlockUnchecked(self: *const Self, index: usize) Block {
            std.debug.assert(index < block_count);
            return self.blocks[index];
        }

        pub fn setBlock(self: *Self, index: usize, value: Block) error{IndexOutOfRange}!void {
            try validateBlockIndex(index);
            self.blocks[index] = value;
        }

        pub fn setBlockUnchecked(self: *Self, index: usize, value: Block) void {
            std.debug.assert(index < block_count);
            self.blocks[index] = value;
        }

        pub fn blockPtr(self: anytype, index: usize) error{IndexOutOfRange}!pointerToBlock(@TypeOf(self)) {
            try validateBlockIndex(index);
            return &self.blocks[index];
        }

        pub fn blockPtrUnchecked(self: anytype, index: usize) pointerToBlock(@TypeOf(self)) {
            std.debug.assert(index < block_count);
            return &self.blocks[index];
        }

        pub fn blockPtrAt(self: anytype, coord: BlockCoord) error{BlockCoordOutOfRange}!pointerToBlock(@TypeOf(self)) {
            const index = try blockIndex(coord);
            return &self.blocks[index];
        }

        pub fn blockPtrAtUnchecked(self: anytype, coord: BlockCoord) pointerToBlock(@TypeOf(self)) {
            const index = blockIndexUnchecked(coord);
            return &self.blocks[index];
        }

        pub fn rowBlocks(self: anytype, block_y: usize) error{BlockCoordOutOfRange}!sliceOfBlocks(@TypeOf(self)) {
            try validateBlockAxis(block_y);
            return rowBlocksUnchecked(self, block_y);
        }

        pub fn rowBlocksUnchecked(self: anytype, block_y: usize) sliceOfBlocks(@TypeOf(self)) {
            std.debug.assert(block_y < blocks_per_side);
            const start = block_y << order_shift;
            return self.blocks[start .. start + blocks_per_side];
        }

        pub fn getCell(self: *const Self, coord: CellCoord) error{CellCoordOutOfRange}!bool {
            try validateCellCoord(coord);
            return self.getCellUnchecked(coord);
        }

        pub fn getCellUnchecked(self: *const Self, coord: CellCoord) bool {
            std.debug.assert(coord.x < cells_per_side);
            std.debug.assert(coord.y < cells_per_side);
            const parts = splitCellCoord(coord);
            return self.blocks[blockIndexUnchecked(parts.block)].get(parts.local_x, parts.local_y);
        }

        pub fn setCell(self: *Self, coord: CellCoord, value: bool) error{CellCoordOutOfRange}!void {
            try validateCellCoord(coord);
            self.setCellUnchecked(coord, value);
        }

        pub fn setCellUnchecked(self: *Self, coord: CellCoord, value: bool) void {
            std.debug.assert(coord.x < cells_per_side);
            std.debug.assert(coord.y < cells_per_side);
            const parts = splitCellCoord(coord);
            self.blocks[blockIndexUnchecked(parts.block)].set(parts.local_x, parts.local_y, value);
        }

        fn splitCellCoord(coord: CellCoord) struct {
            block: BlockCoord,
            local_x: u2,
            local_y: u2,
        } {
            return .{
                .block = .{
                    .x = coord.x >> block_side_shift,
                    .y = coord.y >> block_side_shift,
                },
                .local_x = @intCast(coord.x & local_mask),
                .local_y = @intCast(coord.y & local_mask),
            };
        }

        fn validateBlockIndex(index: usize) error{IndexOutOfRange}!void {
            if (index >= block_count) {
                return error.IndexOutOfRange;
            }
        }

        fn validateBlockAxis(value: usize) error{BlockCoordOutOfRange}!void {
            if (value >= blocks_per_side) {
                return error.BlockCoordOutOfRange;
            }
        }

        fn validateBlockCoord(coord: BlockCoord) error{BlockCoordOutOfRange}!void {
            if (coord.x >= blocks_per_side or coord.y >= blocks_per_side) {
                return error.BlockCoordOutOfRange;
            }
        }

        fn validateCellCoord(coord: CellCoord) error{CellCoordOutOfRange}!void {
            if (coord.x >= cells_per_side or coord.y >= cells_per_side) {
                return error.CellCoordOutOfRange;
            }
        }
    };
}

test "Block initializes empty and filled states" {
    const empty = Block.init(false);
    const filled = Block.init(true);

    try std.testing.expectEqual(@as(u16, 0), empty.bits);
    try std.testing.expectEqual(@as(u5, 0), empty.count());
    try std.testing.expect(!empty.any());
    try std.testing.expect(!empty.all());

    try std.testing.expectEqual(std.math.maxInt(u16), filled.bits);
    try std.testing.expectEqual(@as(u5, 16), filled.count());
    try std.testing.expect(filled.any());
    try std.testing.expect(filled.all());
}

test "Block reads and writes individual cells" {
    var block = Block.init(false);

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

test "BinaryGrid derives sizes from order" {
    try std.testing.expectEqual(@as(usize, 1), BinaryGrid(0).blocks_per_side);
    try std.testing.expectEqual(@as(usize, 4), BinaryGrid(2).blocks_per_side);
    try std.testing.expectEqual(@as(usize, 8), BinaryGrid(3).blocks_per_side);
    try std.testing.expectEqual(@as(usize, 4096), BinaryGrid(max_order).blocks_per_side);
}

test "BinaryGrid maps block coordinates and indices" {
    const Grid = BinaryGrid(2);

    try std.testing.expectEqual(@as(usize, 0), try Grid.blockIndex(.{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(usize, 3), try Grid.blockIndex(.{ .x = 3, .y = 0 }));
    try std.testing.expectEqual(@as(usize, 4), try Grid.blockIndex(.{ .x = 0, .y = 1 }));
    try std.testing.expectEqualDeep(BlockCoord{ .x = 1, .y = 2 }, try Grid.blockCoord(9));

    var index: usize = 0;
    while (index < Grid.block_count) : (index += 1) {
        const coord = try Grid.blockCoord(index);
        try std.testing.expectEqual(index, try Grid.blockIndex(coord));
    }
}

test "BinaryGrid block access by index and coordinate reaches the same storage" {
    const Grid = BinaryGrid(2);
    var grid = Grid.initEmpty();

    var value = Block.init(false);
    value.set(1, 2, true);

    try grid.setBlock(5, value);

    const block_copy = try grid.getBlock(5);
    try std.testing.expectEqualDeep(value, block_copy);

    const block_ptr = try grid.blockPtrAt(.{ .x = 1, .y = 1 });
    try std.testing.expectEqualDeep(value, block_ptr.*);

    block_ptr.set(3, 0, true);

    try std.testing.expect((try grid.getBlock(5)).get(3, 0));
}

test "BinaryGrid rowBlocks exposes contiguous rows" {
    const Grid = BinaryGrid(2);
    var grid = Grid.initEmpty();

    var value = Block.init(false);
    value.set(0, 0, true);
    try grid.setBlock(8, value);

    const row = try grid.rowBlocks(2);
    try std.testing.expectEqual(@as(usize, Grid.blocks_per_side), row.len);
    try std.testing.expect(row[0].get(0, 0));
}

test "BinaryGrid global cell access crosses block boundaries" {
    const Grid = BinaryGrid(2);
    var grid = Grid.initEmpty();

    try grid.setCell(.{ .x = 3, .y = 3 }, true);
    try grid.setCell(.{ .x = 4, .y = 3 }, true);
    try grid.setCell(.{ .x = 3, .y = 4 }, true);
    try grid.setCell(.{ .x = 4, .y = 4 }, true);

    try std.testing.expect(try grid.getCell(.{ .x = 3, .y = 3 }));
    try std.testing.expect(try grid.getCell(.{ .x = 4, .y = 3 }));
    try std.testing.expect(try grid.getCell(.{ .x = 3, .y = 4 }));
    try std.testing.expect(try grid.getCell(.{ .x = 4, .y = 4 }));

    try std.testing.expect((try grid.getBlock(0)).get(3, 3));
    try std.testing.expect((try grid.getBlock(1)).get(0, 3));
    try std.testing.expect((try grid.getBlock(4)).get(3, 0));
    try std.testing.expect((try grid.getBlock(5)).get(0, 0));
}

test "BinaryGrid initFilled populates the built-in Block storage" {
    const Grid = BinaryGrid(1);
    var grid = Grid.initFilled();

    try std.testing.expect(try grid.getCell(.{ .x = 7, .y = 7 }));

    try grid.setCell(.{ .x = 5, .y = 2 }, false);

    try std.testing.expect(!(try grid.getCell(.{ .x = 5, .y = 2 })));
    try std.testing.expect(!(try grid.getBlock(1)).get(1, 2));
}

test "BinaryGrid checked APIs reject out-of-range coordinates and indices" {
    const Grid = BinaryGrid(2);
    var grid = Grid.initEmpty();

    try std.testing.expectError(error.BlockCoordOutOfRange, Grid.blockIndex(.{ .x = 4, .y = 0 }));
    try std.testing.expectError(error.IndexOutOfRange, Grid.blockCoord(Grid.block_count));
    try std.testing.expectError(error.IndexOutOfRange, grid.getBlock(Grid.block_count));
    try std.testing.expectError(error.BlockCoordOutOfRange, grid.blockPtrAt(.{ .x = 0, .y = 4 }));
    try std.testing.expectError(error.BlockCoordOutOfRange, grid.rowBlocks(Grid.blocks_per_side));
    try std.testing.expectError(error.CellCoordOutOfRange, grid.getCell(.{ .x = Grid.cells_per_side, .y = 0 }));
    try std.testing.expectError(error.CellCoordOutOfRange, grid.setCell(.{ .x = 0, .y = Grid.cells_per_side }, true));
}
