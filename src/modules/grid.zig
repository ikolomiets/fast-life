const std = @import("std");

pub const BlockCoord = struct {
    x: usize,
    y: usize,
};

pub const CellCoord = struct {
    x: usize,
    y: usize,
};

fn pointerToBlock(comptime GridPtr: type, comptime Block: type) type {
    return switch (@typeInfo(GridPtr)) {
        .pointer => |pointer_info| if (pointer_info.is_const) *const Block else *Block,
        else => @compileError("expected a grid pointer receiver"),
    };
}

fn sliceOfBlocks(comptime GridPtr: type, comptime Block: type) type {
    return switch (@typeInfo(GridPtr)) {
        .pointer => |pointer_info| if (pointer_info.is_const) []const Block else []Block,
        else => @compileError("expected a grid pointer receiver"),
    };
}

fn validateBlock(comptime Block: type) void {
    if (!@hasDecl(Block, "side")) {
        @compileError(@typeName(Block) ++ " must declare pub const side");
    }
    if (!@hasDecl(Block, "init")) {
        @compileError(@typeName(Block) ++ " must declare pub fn init(fill: bool)");
    }
    if (!@hasDecl(Block, "get")) {
        @compileError(@typeName(Block) ++ " must declare pub fn get(self, x: u2, y: u2) bool");
    }
    if (!@hasDecl(Block, "set")) {
        @compileError(@typeName(Block) ++ " must declare pub fn set(self: *Self, x: u2, y: u2, value: bool) void");
    }
    if (Block.side != 4) {
        @compileError(@typeName(Block) ++ " must use side = 4");
    }

    if (@TypeOf(Block.init) != fn (bool) Block) {
        @compileError(@typeName(Block) ++ ".init(fill) must have type fn (bool) " ++ @typeName(Block));
    }
    if (@TypeOf(Block.get) != fn (Block, u2, u2) bool) {
        @compileError(@typeName(Block) ++ ".get must have type fn (Self, u2, u2) bool");
    }
    if (@TypeOf(Block.set) != fn (*Block, u2, u2, bool) void) {
        @compileError(@typeName(Block) ++ ".set must have type fn (*Self, u2, u2, bool) void");
    }
}

pub fn BinaryGrid(comptime Order: usize, comptime Block: type) type {
    comptime validateBlock(Block);

    const Shift = std.math.Log2Int(usize);
    const usize_bits = @typeInfo(usize).int.bits;
    const order_shift: Shift = blk: {
        if (Order >= usize_bits) {
            @compileError("BinaryGrid Order is too large for usize");
        }
        break :blk @intCast(Order);
    };

    const block_side_shift: Shift = 2;
    const local_mask = Block.side - 1;
    const blocks_per_side_value: usize = @as(usize, 1) << order_shift;
    const block_count_value: usize = blocks_per_side_value * blocks_per_side_value;
    const cells_per_side_value: usize = blocks_per_side_value * Block.side;
    const cell_count_value: usize = cells_per_side_value * cells_per_side_value;

    return struct {
        blocks: [block_count_value]Block,

        const Self = @This();

        pub const order: usize = Order;
        pub const block_type = Block;
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

        pub fn blockPtr(self: anytype, index: usize) error{IndexOutOfRange}!pointerToBlock(@TypeOf(self), Block) {
            try validateBlockIndex(index);
            return &self.blocks[index];
        }

        pub fn blockPtrUnchecked(self: anytype, index: usize) pointerToBlock(@TypeOf(self), Block) {
            std.debug.assert(index < block_count);
            return &self.blocks[index];
        }

        pub fn blockPtrAt(self: anytype, coord: BlockCoord) error{BlockCoordOutOfRange}!pointerToBlock(@TypeOf(self), Block) {
            const index = try blockIndex(coord);
            return &self.blocks[index];
        }

        pub fn blockPtrAtUnchecked(self: anytype, coord: BlockCoord) pointerToBlock(@TypeOf(self), Block) {
            const index = blockIndexUnchecked(coord);
            return &self.blocks[index];
        }

        pub fn rowBlocks(self: anytype, block_y: usize) error{BlockCoordOutOfRange}!sliceOfBlocks(@TypeOf(self), Block) {
            try validateBlockAxis(block_y);
            return rowBlocksUnchecked(self, block_y);
        }

        pub fn rowBlocksUnchecked(self: anytype, block_y: usize) sliceOfBlocks(@TypeOf(self), Block) {
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

const block_module = @import("block.zig");

const MatrixBlock4x4 = struct {
    cells: [4][4]bool,

    pub const side: usize = 4;

    const Self = @This();

    pub fn init(fill: bool) Self {
        const row = [_]bool{fill} ** 4;
        return .{
            .cells = [_][4]bool{row} ** 4,
        };
    }

    pub fn get(self: Self, x: u2, y: u2) bool {
        return self.cells[@as(usize, y)][@as(usize, x)];
    }

    pub fn set(self: *Self, x: u2, y: u2, value: bool) void {
        self.cells[@as(usize, y)][@as(usize, x)] = value;
    }
};

test "BinaryGrid derives sizes from Order" {
    try std.testing.expectEqual(@as(usize, 1), BinaryGrid(0, block_module.PackedBlock4x4).blocks_per_side);
    try std.testing.expectEqual(@as(usize, 4), BinaryGrid(2, block_module.PackedBlock4x4).blocks_per_side);
    try std.testing.expectEqual(@as(usize, 8), BinaryGrid(3, block_module.PackedBlock4x4).blocks_per_side);
}

test "BinaryGrid maps block coordinates and indices" {
    const Grid = BinaryGrid(2, block_module.PackedBlock4x4);

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
    const Grid = BinaryGrid(2, block_module.PackedBlock4x4);
    var grid = Grid.initEmpty();

    var value = block_module.PackedBlock4x4.init(false);
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
    const Grid = BinaryGrid(2, block_module.PackedBlock4x4);
    var grid = Grid.initEmpty();

    var value = block_module.PackedBlock4x4.init(false);
    value.set(0, 0, true);
    try grid.setBlock(8, value);

    const row = try grid.rowBlocks(2);
    try std.testing.expectEqual(@as(usize, Grid.blocks_per_side), row.len);
    try std.testing.expect(row[0].get(0, 0));
}

test "BinaryGrid global cell access crosses block boundaries" {
    const Grid = BinaryGrid(2, block_module.PackedBlock4x4);
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

test "BinaryGrid stays decoupled from the block wire format" {
    const Grid = BinaryGrid(1, MatrixBlock4x4);
    var grid = Grid.initFilled();

    try std.testing.expect(try grid.getCell(.{ .x = 7, .y = 7 }));

    try grid.setCell(.{ .x = 5, .y = 2 }, false);

    try std.testing.expect(!(try grid.getCell(.{ .x = 5, .y = 2 })));
    try std.testing.expect(!(try grid.getBlock(1)).get(1, 2));
}

test "BinaryGrid checked APIs reject out-of-range coordinates and indices" {
    const Grid = BinaryGrid(2, block_module.PackedBlock4x4);
    var grid = Grid.initEmpty();

    try std.testing.expectError(error.BlockCoordOutOfRange, Grid.blockIndex(.{ .x = 4, .y = 0 }));
    try std.testing.expectError(error.IndexOutOfRange, Grid.blockCoord(Grid.block_count));
    try std.testing.expectError(error.IndexOutOfRange, grid.getBlock(Grid.block_count));
    try std.testing.expectError(error.BlockCoordOutOfRange, grid.blockPtrAt(.{ .x = 0, .y = 4 }));
    try std.testing.expectError(error.BlockCoordOutOfRange, grid.rowBlocks(Grid.blocks_per_side));
    try std.testing.expectError(error.CellCoordOutOfRange, grid.getCell(.{ .x = Grid.cells_per_side, .y = 0 }));
    try std.testing.expectError(error.CellCoordOutOfRange, grid.setCell(.{ .x = 0, .y = Grid.cells_per_side }, true));
}
