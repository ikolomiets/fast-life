const std = @import("std");

// Each additional order doubles the block width in each axis and quadruples storage.
// The cap keeps the largest instantiation at 256x256 blocks, 1024x1024 cells, and 128 KiB total.
pub const max_order: usize = 8;

pub const Block = struct {
    bits: u16,

    // A 4x4 tile packs cleanly into one u16 so local cell operations stay branch-light.
    pub const side: usize = 4;
    pub const side_shift: u2 = 2;
    pub const LocalCoord = u2;

    const Self = @This();
    const filled_bits = std.math.maxInt(u16);

    pub fn empty() Self {
        return .{ .bits = 0 };
    }

    pub fn filled() Self {
        return .{ .bits = filled_bits };
    }

    fn bit_index(x: LocalCoord, y: LocalCoord) u4 {
        return (@as(u4, y) << side_shift) | @as(u4, x);
    }

    fn bit_mask(x: LocalCoord, y: LocalCoord) u16 {
        return @as(u16, 1) << bit_index(x, y);
    }

    pub fn get(self: Self, x: LocalCoord, y: LocalCoord) bool {
        return (self.bits & bit_mask(x, y)) != 0;
    }

    pub fn set(self: *Self, x: LocalCoord, y: LocalCoord, value: bool) void {
        const mask = bit_mask(x, y);
        if (value) {
            self.bits |= mask;
            return;
        }

        self.bits &= ~mask;
    }

    pub fn row_mask(self: Self, y: LocalCoord) u4 {
        return @intCast((self.bits >> (@as(u4, y) << side_shift)) & 0b1111);
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

comptime {
    if (Block.side != (@as(usize, 1) << Block.side_shift)) {
        @compileError("Block.side must match Block.side_shift");
    }
    if (Block.side != 4) {
        @compileError("Block.side must remain 4 to preserve the packed 16-bit storage layout");
    }
}

pub const BlockCoord = struct {
    x: usize,
    y: usize,
};

pub const CellCoord = struct {
    x: usize,
    y: usize,
};

pub const Direction = enum {
    N,
    NE,
    E,
    SE,
    S,
    SW,
    W,
    NW,
};

pub fn BinaryGrid(comptime grid_order: usize) type {
    const Shift = std.math.Log2Int(usize);
    if (grid_order > max_order) {
        @compileError(std.fmt.comptimePrint("BinaryGrid order must be <= {d}", .{max_order}));
    }

    const order_shift: Shift = @intCast(grid_order);
    const block_side_shift: Shift = @intCast(Block.side_shift);
    const local_mask: usize = Block.side - 1;
    const blocks_per_side_value: usize = @as(usize, 1) << order_shift;
    const block_count_value: usize = blocks_per_side_value * blocks_per_side_value;
    const cells_per_side_value: usize = blocks_per_side_value * Block.side;
    const cell_count_value: usize = cells_per_side_value * cells_per_side_value;

    return struct {
        blocks: [block_count_value]Block,

        const Self = @This();

        pub const order: usize = grid_order;
        pub const block_side: usize = Block.side;
        pub const blocks_per_side: usize = blocks_per_side_value;
        pub const block_count: usize = block_count_value;
        pub const cells_per_side: usize = cells_per_side_value;
        pub const cell_count: usize = cell_count_value;

        comptime {
            if (blocks_per_side == 0) {
                @compileError("BinaryGrid requires at least one block per side");
            }
            if (block_side != (@as(usize, 1) << block_side_shift)) {
                @compileError("BinaryGrid block shift must match Block.side");
            }
        }

        pub fn init_empty(self: *Self) void {
            @memset(self.blocks[0..], Block.empty());
        }

        pub fn init_filled(self: *Self) void {
            @memset(self.blocks[0..], Block.filled());
        }

        pub fn clear(self: *Self) void {
            self.init_empty();
        }

        pub fn fill(self: *Self) void {
            self.init_filled();
        }

        pub fn block_index(coord: BlockCoord) error{BlockCoordOutOfRange}!usize {
            try validate_block_coord(coord);
            return block_index_unchecked(coord);
        }

        pub fn block_index_unchecked(coord: BlockCoord) usize {
            std.debug.assert(coord.x < blocks_per_side);
            std.debug.assert(coord.y < blocks_per_side);
            return (coord.y << order_shift) | coord.x;
        }

        pub fn block_coord(index: usize) error{IndexOutOfRange}!BlockCoord {
            try validate_block_index(index);
            return block_coord_unchecked(index);
        }

        pub fn block_coord_unchecked(index: usize) BlockCoord {
            std.debug.assert(index < block_count);
            return .{
                .x = index & (blocks_per_side - 1),
                .y = index >> order_shift,
            };
        }

        pub fn get_block(self: *const Self, index: usize) error{IndexOutOfRange}!Block {
            try validate_block_index(index);
            return self.blocks[index];
        }

        pub fn get_block_unchecked(self: *const Self, index: usize) Block {
            std.debug.assert(index < block_count);
            return self.blocks[index];
        }

        pub fn get_block_neighbor(self: *const Self, index: usize, direction: Direction) error{IndexOutOfRange}!Block {
            try validate_block_index(index);
            return self.get_block_neighbor_unchecked(index, direction);
        }

        pub fn get_block_neighbor_unchecked(self: *const Self, index: usize, direction: Direction) Block {
            std.debug.assert(index < block_count);

            const coord = block_coord_unchecked(index);
            const neighbor = neighbor_block_coord(coord, direction);
            return self.blocks[block_index_unchecked(neighbor)];
        }

        pub fn set_block(self: *Self, index: usize, value: Block) error{IndexOutOfRange}!void {
            try validate_block_index(index);
            self.blocks[index] = value;
        }

        pub fn set_block_unchecked(self: *Self, index: usize, value: Block) void {
            std.debug.assert(index < block_count);
            self.blocks[index] = value;
        }

        pub fn block_ptr(self: *Self, index: usize) error{IndexOutOfRange}!*Block {
            try validate_block_index(index);
            return &self.blocks[index];
        }

        pub fn block_ptr_unchecked(self: *Self, index: usize) *Block {
            std.debug.assert(index < block_count);
            return &self.blocks[index];
        }

        pub fn block_ptr_at(self: *Self, coord: BlockCoord) error{BlockCoordOutOfRange}!*Block {
            const index = try block_index(coord);
            return &self.blocks[index];
        }

        pub fn block_ptr_at_unchecked(self: *Self, coord: BlockCoord) *Block {
            const index = block_index_unchecked(coord);
            return &self.blocks[index];
        }

        pub fn row_blocks(self: *Self, block_y: usize) error{BlockCoordOutOfRange}![]Block {
            try validate_block_axis(block_y);
            return self.row_blocks_unchecked(block_y);
        }

        pub fn row_blocks_unchecked(self: *Self, block_y: usize) []Block {
            std.debug.assert(block_y < blocks_per_side);
            const start = block_y << order_shift;
            return self.blocks[start .. start + blocks_per_side];
        }

        pub fn get_cell(self: *const Self, coord: CellCoord) error{CellCoordOutOfRange}!bool {
            try validate_cell_coord(coord);
            return self.get_cell_unchecked(coord);
        }

        pub fn get_cell_unchecked(self: *const Self, coord: CellCoord) bool {
            std.debug.assert(coord.x < cells_per_side);
            std.debug.assert(coord.y < cells_per_side);

            const parts = split_cell_coord(coord);
            return self.blocks[block_index_unchecked(parts.block)].get(parts.local_x, parts.local_y);
        }

        pub fn get_cell_neighbor(self: *const Self, coord: CellCoord, direction: Direction) error{CellCoordOutOfRange}!bool {
            try validate_cell_coord(coord);
            return self.get_cell_neighbor_unchecked(coord, direction);
        }

        pub fn get_cell_neighbor_unchecked(self: *const Self, coord: CellCoord, direction: Direction) bool {
            std.debug.assert(coord.x < cells_per_side);
            std.debug.assert(coord.y < cells_per_side);

            const neighbor = neighbor_cell_coord(coord, direction);
            return self.get_cell_unchecked(neighbor);
        }

        pub fn set_cell(self: *Self, coord: CellCoord, value: bool) error{CellCoordOutOfRange}!void {
            try validate_cell_coord(coord);
            self.set_cell_unchecked(coord, value);
        }

        pub fn set_cell_unchecked(self: *Self, coord: CellCoord, value: bool) void {
            std.debug.assert(coord.x < cells_per_side);
            std.debug.assert(coord.y < cells_per_side);

            const parts = split_cell_coord(coord);
            self.blocks[block_index_unchecked(parts.block)].set(parts.local_x, parts.local_y, value);
        }

        const CellParts = struct {
            block: BlockCoord,
            local_x: Block.LocalCoord,
            local_y: Block.LocalCoord,
        };

        fn split_cell_coord(coord: CellCoord) CellParts {
            return .{
                .block = .{
                    .x = coord.x >> block_side_shift,
                    .y = coord.y >> block_side_shift,
                },
                .local_x = @intCast(coord.x & local_mask),
                .local_y = @intCast(coord.y & local_mask),
            };
        }

        fn previous_axis(value: usize, limit: usize) usize {
            std.debug.assert(limit != 0);
            std.debug.assert(value < limit);

            if (value == 0) {
                return limit - 1;
            }

            return value - 1;
        }

        fn next_axis(value: usize, limit: usize) usize {
            std.debug.assert(limit != 0);
            std.debug.assert(value < limit);

            if (value + 1 == limit) {
                return 0;
            }

            return value + 1;
        }

        // BinaryGrid uses a closed-world topology, so every edge wraps to the opposite side.
        fn neighbor_block_coord(coord: BlockCoord, direction: Direction) BlockCoord {
            std.debug.assert(coord.x < blocks_per_side);
            std.debug.assert(coord.y < blocks_per_side);

            var neighbor = coord;
            switch (direction) {
                .N => neighbor.y = previous_axis(coord.y, blocks_per_side),
                .NE => {
                    neighbor.x = next_axis(coord.x, blocks_per_side);
                    neighbor.y = previous_axis(coord.y, blocks_per_side);
                },
                .E => neighbor.x = next_axis(coord.x, blocks_per_side),
                .SE => {
                    neighbor.x = next_axis(coord.x, blocks_per_side);
                    neighbor.y = next_axis(coord.y, blocks_per_side);
                },
                .S => neighbor.y = next_axis(coord.y, blocks_per_side),
                .SW => {
                    neighbor.x = previous_axis(coord.x, blocks_per_side);
                    neighbor.y = next_axis(coord.y, blocks_per_side);
                },
                .W => neighbor.x = previous_axis(coord.x, blocks_per_side),
                .NW => {
                    neighbor.x = previous_axis(coord.x, blocks_per_side);
                    neighbor.y = previous_axis(coord.y, blocks_per_side);
                },
            }
            return neighbor;
        }

        fn neighbor_cell_coord(coord: CellCoord, direction: Direction) CellCoord {
            std.debug.assert(coord.x < cells_per_side);
            std.debug.assert(coord.y < cells_per_side);

            var neighbor = coord;
            switch (direction) {
                .N => neighbor.y = previous_axis(coord.y, cells_per_side),
                .NE => {
                    neighbor.x = next_axis(coord.x, cells_per_side);
                    neighbor.y = previous_axis(coord.y, cells_per_side);
                },
                .E => neighbor.x = next_axis(coord.x, cells_per_side),
                .SE => {
                    neighbor.x = next_axis(coord.x, cells_per_side);
                    neighbor.y = next_axis(coord.y, cells_per_side);
                },
                .S => neighbor.y = next_axis(coord.y, cells_per_side),
                .SW => {
                    neighbor.x = previous_axis(coord.x, cells_per_side);
                    neighbor.y = next_axis(coord.y, cells_per_side);
                },
                .W => neighbor.x = previous_axis(coord.x, cells_per_side),
                .NW => {
                    neighbor.x = previous_axis(coord.x, cells_per_side);
                    neighbor.y = previous_axis(coord.y, cells_per_side);
                },
            }
            return neighbor;
        }

        fn validate_block_index(index: usize) error{IndexOutOfRange}!void {
            if (index >= block_count) {
                return error.IndexOutOfRange;
            }
        }

        fn validate_block_axis(value: usize) error{BlockCoordOutOfRange}!void {
            if (value >= blocks_per_side) {
                return error.BlockCoordOutOfRange;
            }
        }

        fn validate_block_coord(coord: BlockCoord) error{BlockCoordOutOfRange}!void {
            if (coord.x >= blocks_per_side) {
                return error.BlockCoordOutOfRange;
            }
            if (coord.y >= blocks_per_side) {
                return error.BlockCoordOutOfRange;
            }
        }

        fn validate_cell_coord(coord: CellCoord) error{CellCoordOutOfRange}!void {
            if (coord.x >= cells_per_side) {
                return error.CellCoordOutOfRange;
            }
            if (coord.y >= cells_per_side) {
                return error.CellCoordOutOfRange;
            }
        }
    };
}

test "Block initializes empty and filled states" {
    const empty = Block.empty();
    const filled = Block.filled();

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
    var block = Block.empty();

    try std.testing.expect(!block.get(0, 0));
    try std.testing.expect(!block.get(3, 3));

    block.set(0, 0, true);
    block.set(2, 1, true);
    block.set(3, 3, true);

    try std.testing.expect(block.get(0, 0));
    try std.testing.expect(block.get(2, 1));
    try std.testing.expect(block.get(3, 3));
    try std.testing.expectEqual(@as(u5, 3), block.count());
    try std.testing.expectEqual(@as(u4, 0b0001), block.row_mask(0));
    try std.testing.expectEqual(@as(u4, 0b0100), block.row_mask(1));
    try std.testing.expectEqual(@as(u4, 0b0000), block.row_mask(2));
    try std.testing.expectEqual(@as(u4, 0b1000), block.row_mask(3));

    block.set(2, 1, false);

    try std.testing.expect(!block.get(2, 1));
    try std.testing.expectEqual(@as(u5, 2), block.count());
    try std.testing.expectEqual(@as(u4, 0b0000), block.row_mask(1));
}

test "BinaryGrid derives sizes from order" {
    try std.testing.expectEqual(@as(usize, 1), BinaryGrid(0).blocks_per_side);
    try std.testing.expectEqual(@as(usize, 4), BinaryGrid(2).blocks_per_side);
    try std.testing.expectEqual(@as(usize, 8), BinaryGrid(3).blocks_per_side);
    try std.testing.expectEqual(@as(usize, 256), BinaryGrid(max_order).blocks_per_side);
    try std.testing.expectEqual(@as(usize, 1024), BinaryGrid(max_order).cells_per_side);
}

test "BinaryGrid maps block coordinates and indices" {
    const Grid = BinaryGrid(2);

    try std.testing.expectEqual(@as(usize, 0), try Grid.block_index(.{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(usize, 3), try Grid.block_index(.{ .x = 3, .y = 0 }));
    try std.testing.expectEqual(@as(usize, 4), try Grid.block_index(.{ .x = 0, .y = 1 }));
    try std.testing.expectEqualDeep(BlockCoord{ .x = 1, .y = 2 }, try Grid.block_coord(9));

    var index: usize = 0;
    while (index < Grid.block_count) : (index += 1) {
        const coord = try Grid.block_coord(index);
        try std.testing.expectEqual(index, try Grid.block_index(coord));
    }
}

test "BinaryGrid block access by index and coordinate reaches the same storage" {
    const Grid = BinaryGrid(2);
    var grid: Grid = undefined;
    grid.init_empty();

    var value = Block.empty();
    value.set(1, 2, true);

    try grid.set_block(5, value);

    const block_copy = try grid.get_block(5);
    try std.testing.expectEqualDeep(value, block_copy);

    const block_ptr = try grid.block_ptr_at(.{ .x = 1, .y = 1 });
    try std.testing.expectEqualDeep(value, block_ptr.*);

    block_ptr.set(3, 0, true);

    try std.testing.expect((try grid.get_block(5)).get(3, 0));
}

test "BinaryGrid row_blocks exposes contiguous rows" {
    const Grid = BinaryGrid(2);
    var grid: Grid = undefined;
    grid.init_empty();

    var value = Block.empty();
    value.set(0, 0, true);
    try grid.set_block(8, value);

    const row = try grid.row_blocks(2);
    try std.testing.expectEqual(@as(usize, Grid.blocks_per_side), row.len);
    try std.testing.expect(row[0].get(0, 0));
}

test "BinaryGrid global cell access crosses block boundaries" {
    const Grid = BinaryGrid(2);
    var grid: Grid = undefined;
    grid.init_empty();

    try grid.set_cell(.{ .x = 3, .y = 3 }, true);
    try grid.set_cell(.{ .x = 4, .y = 3 }, true);
    try grid.set_cell(.{ .x = 3, .y = 4 }, true);
    try grid.set_cell(.{ .x = 4, .y = 4 }, true);

    try std.testing.expect(try grid.get_cell(.{ .x = 3, .y = 3 }));
    try std.testing.expect(try grid.get_cell(.{ .x = 4, .y = 3 }));
    try std.testing.expect(try grid.get_cell(.{ .x = 3, .y = 4 }));
    try std.testing.expect(try grid.get_cell(.{ .x = 4, .y = 4 }));

    try std.testing.expect((try grid.get_block(0)).get(3, 3));
    try std.testing.expect((try grid.get_block(1)).get(0, 3));
    try std.testing.expect((try grid.get_block(4)).get(3, 0));
    try std.testing.expect((try grid.get_block(5)).get(0, 0));
}

test "BinaryGrid wrapped block neighbors cross edges and corners" {
    const Grid = BinaryGrid(2);
    var grid: Grid = undefined;
    grid.init_empty();

    var index: usize = 0;
    while (index < Grid.block_count) : (index += 1) {
        try grid.set_block(index, .{ .bits = @intCast(index + 1) });
    }

    try std.testing.expectEqual(@as(u16, 13), (try grid.get_block_neighbor(0, .N)).bits);
    try std.testing.expectEqual(@as(u16, 2), (try grid.get_block_neighbor(0, .E)).bits);
    try std.testing.expectEqual(@as(u16, 16), (try grid.get_block_neighbor(0, .NW)).bits);
    try std.testing.expectEqual(@as(u16, 10), (try grid.get_block_neighbor(10, .W)).bits);
    try std.testing.expectEqual(@as(u16, 8), (try grid.get_block_neighbor(10, .NE)).bits);
    try std.testing.expectEqual(@as(u16, 16), (try grid.get_block_neighbor(10, .SE)).bits);
}

test "BinaryGrid wrapped cell neighbors cross block and grid boundaries" {
    const Grid = BinaryGrid(1);
    var grid: Grid = undefined;
    grid.init_empty();

    try grid.set_cell(.{ .x = 4, .y = 3 }, true);
    try grid.set_cell(.{ .x = 3, .y = 4 }, true);
    try grid.set_cell(.{ .x = 4, .y = 4 }, true);
    try grid.set_cell(.{ .x = 7, .y = 0 }, true);
    try grid.set_cell(.{ .x = 0, .y = 7 }, true);
    try grid.set_cell(.{ .x = 7, .y = 7 }, true);

    try std.testing.expect(try grid.get_cell_neighbor(.{ .x = 3, .y = 3 }, .E));
    try std.testing.expect(try grid.get_cell_neighbor(.{ .x = 3, .y = 3 }, .S));
    try std.testing.expect(try grid.get_cell_neighbor(.{ .x = 3, .y = 3 }, .SE));
    try std.testing.expect(!(try grid.get_cell_neighbor(.{ .x = 3, .y = 3 }, .N)));

    try std.testing.expect(try grid.get_cell_neighbor(.{ .x = 0, .y = 0 }, .W));
    try std.testing.expect(try grid.get_cell_neighbor(.{ .x = 0, .y = 0 }, .N));
    try std.testing.expect(try grid.get_cell_neighbor(.{ .x = 0, .y = 0 }, .NW));
    try std.testing.expect(!(try grid.get_cell_neighbor(.{ .x = 0, .y = 0 }, .NE)));
}

test "BinaryGrid supports explicit in-place initialization and refill" {
    const Grid = BinaryGrid(1);
    var grid: Grid = undefined;

    grid.init_filled();
    try std.testing.expect(try grid.get_cell(.{ .x = 7, .y = 7 }));

    try grid.set_cell(.{ .x = 5, .y = 2 }, false);
    try std.testing.expect(!(try grid.get_cell(.{ .x = 5, .y = 2 })));

    grid.clear();
    try std.testing.expect(!(try grid.get_cell(.{ .x = 7, .y = 7 })));

    grid.fill();
    try std.testing.expect(try grid.get_cell(.{ .x = 5, .y = 2 }));
    try std.testing.expect((try grid.get_block(1)).get(1, 2));
}

test "BinaryGrid checked APIs reject out-of-range coordinates and indices" {
    const Grid = BinaryGrid(2);
    var grid: Grid = undefined;
    grid.init_empty();

    try std.testing.expectError(error.BlockCoordOutOfRange, Grid.block_index(.{ .x = 4, .y = 0 }));
    try std.testing.expectError(error.BlockCoordOutOfRange, Grid.block_index(.{ .x = 0, .y = 4 }));
    try std.testing.expectError(error.IndexOutOfRange, Grid.block_coord(Grid.block_count));
    try std.testing.expectError(error.IndexOutOfRange, grid.get_block(Grid.block_count));
    try std.testing.expectError(error.IndexOutOfRange, grid.get_block_neighbor(Grid.block_count, .E));
    try std.testing.expectError(error.BlockCoordOutOfRange, grid.block_ptr_at(.{ .x = 0, .y = 4 }));
    try std.testing.expectError(error.BlockCoordOutOfRange, grid.row_blocks(Grid.blocks_per_side));
    try std.testing.expectError(error.CellCoordOutOfRange, grid.get_cell(.{ .x = Grid.cells_per_side, .y = 0 }));
    try std.testing.expectError(error.CellCoordOutOfRange, grid.get_cell_neighbor(.{ .x = Grid.cells_per_side, .y = 0 }, .N));
    try std.testing.expectError(error.CellCoordOutOfRange, grid.get_cell(.{ .x = 0, .y = Grid.cells_per_side }));
    try std.testing.expectError(error.CellCoordOutOfRange, grid.set_cell(.{ .x = 0, .y = Grid.cells_per_side }, true));
}

test "BinaryGrid accepts last valid block and cell coordinates" {
    const Grid = BinaryGrid(2);
    var grid: Grid = undefined;
    grid.init_empty();

    const last_block = BlockCoord{
        .x = Grid.blocks_per_side - 1,
        .y = Grid.blocks_per_side - 1,
    };
    const last_cell = CellCoord{
        .x = Grid.cells_per_side - 1,
        .y = Grid.cells_per_side - 1,
    };

    try std.testing.expectEqual(Grid.block_count - 1, try Grid.block_index(last_block));
    try std.testing.expectEqualDeep(last_block, try Grid.block_coord(Grid.block_count - 1));

    try grid.set_cell(last_cell, true);
    try std.testing.expect(try grid.get_cell(last_cell));
}

test "BinaryGrid order zero wraps block and cell neighbors onto itself" {
    const Grid = BinaryGrid(0);
    var grid: Grid = undefined;
    grid.init_empty();

    const directions = [_]Direction{ .N, .NE, .E, .SE, .S, .SW, .W, .NW };
    const block = Block{ .bits = 0x00f0 };
    try grid.set_block(0, block);

    for (directions) |direction| {
        try std.testing.expectEqualDeep(block, try grid.get_block_neighbor(0, direction));
    }

    try grid.set_cell(.{ .x = 0, .y = 3 }, true);
    try grid.set_cell(.{ .x = 1, .y = 3 }, true);
    try grid.set_cell(.{ .x = 1, .y = 0 }, true);
    try grid.set_cell(.{ .x = 1, .y = 1 }, true);
    try grid.set_cell(.{ .x = 0, .y = 1 }, true);
    try grid.set_cell(.{ .x = 3, .y = 1 }, true);
    try grid.set_cell(.{ .x = 3, .y = 0 }, true);
    try grid.set_cell(.{ .x = 3, .y = 3 }, true);

    for (directions) |direction| {
        try std.testing.expect(try grid.get_cell_neighbor(.{ .x = 0, .y = 0 }, direction));
    }
}
