const std = @import("std");
const binary_grid = @import("binary_grid.zig");

const neighbor_directions = [_]binary_grid.Direction{ .N, .NE, .E, .SE, .S, .SW, .W, .NW };

pub const Transition = enum {
    no_change,
    birth,
    death,
};

pub fn GameOfLife(comptime grid_order: usize) type {
    const Grid = binary_grid.BinaryGrid(grid_order);

    return struct {
        generation: u64,
        grids: [2]Grid,

        const Self = @This();

        comptime {
            if (@offsetOf(Self, "generation") != 0) {
                @compileError("GameOfLife.generation must be the first field");
            }
            if (@offsetOf(Self, "grids") != @sizeOf(u64)) {
                @compileError("GameOfLife.grids must follow generation without padding");
            }
        }

        pub fn init_empty(self: *Self) void {
            self.generation = 0;
            self.grids[0].init_empty();
            self.grids[1].init_empty();
        }

        pub fn init_generation_zero_grid(self: *Self) *Grid {
            self.init_empty();
            return &self.grids[0];
        }

        pub fn init_from_grid(self: *Self, initial: *const Grid) void {
            self.generation = 0;
            self.grids[0] = initial.*;
            self.grids[1].init_empty();
        }

        pub fn clear(self: *Self) void {
            self.init_empty();
        }

        pub fn current_grid(self: *const Self) *const Grid {
            const index = self.current_index();
            return &self.grids[index];
        }

        pub fn current_grid_mut(self: *Self) *Grid {
            const index = self.current_index();
            return &self.grids[index];
        }

        pub fn step(self: *Self) void {
            const current_buffer_index = self.current_index();
            const next_buffer_index = self.next_index();

            std.debug.assert(current_buffer_index < self.grids.len);
            std.debug.assert(next_buffer_index < self.grids.len);
            std.debug.assert(current_buffer_index != next_buffer_index);

            const current = &self.grids[current_buffer_index];
            const next = &self.grids[next_buffer_index];

            next.* = current.*;

            var y: usize = 0;
            while (y < Grid.cells_per_side) : (y += 1) {
                var x: usize = 0;
                while (x < Grid.cells_per_side) : (x += 1) {
                    const coord = binary_grid.CellCoord{ .x = x, .y = y };
                    const current_state = current.get_cell_unchecked(coord);
                    const transition = next_transition(current_state, alive_neighbors(current, coord));

                    switch (transition) {
                        .no_change => {},
                        .birth => next.set_cell_unchecked(coord, true),
                        .death => next.set_cell_unchecked(coord, false),
                    }
                }
            }

            const generation, const overflow = @addWithOverflow(self.generation, 1);
            if (overflow != 0) {
                std.debug.panic("GameOfLife generation overflow", .{});
            }
            self.generation = generation;
        }

        fn current_index(self: *const Self) usize {
            const index: usize = @intCast(self.generation & 1);
            std.debug.assert(index < self.grids.len);
            return index;
        }

        fn next_index(self: *const Self) usize {
            const index = self.current_index() ^ 1;
            std.debug.assert(index < self.grids.len);
            return index;
        }

        fn alive_neighbors(current: *const Grid, coord: binary_grid.CellCoord) u4 {
            var count: u4 = 0;

            inline for (neighbor_directions) |direction| {
                if (current.get_cell_neighbor_unchecked(coord, direction)) {
                    count += 1;
                }
            }

            return count;
        }
    };
}

// Encodes Conway Life's per-cell transition rule.
pub fn next_state(current_state: bool, alive_neighbors: u4) bool {
    std.debug.assert(alive_neighbors <= 8);

    if (current_state) {
        return alive_neighbors == 2 or alive_neighbors == 3;
    }
    return alive_neighbors == 3;
}

pub fn next_transition(current_state: bool, alive_neighbors: u4) Transition {
    const next = next_state(current_state, alive_neighbors);

    if (next == current_state) {
        return .no_change;
    }
    return if (next) .birth else .death;
}

fn expect_grid_all_dead(
    comptime grid_order: usize,
    grid: *const binary_grid.BinaryGrid(grid_order),
) !void {
    const Grid = binary_grid.BinaryGrid(grid_order);

    var y: usize = 0;
    while (y < Grid.cells_per_side) : (y += 1) {
        var x: usize = 0;
        while (x < Grid.cells_per_side) : (x += 1) {
            try std.testing.expect(!grid.get_cell_unchecked(.{ .x = x, .y = y }));
        }
    }
}

fn seed_generation_zero_grid(grid: *binary_grid.BinaryGrid(0)) !void {
    try grid.set_cell(.{ .x = 1, .y = 2 }, true);
    try grid.set_cell(.{ .x = 2, .y = 2 }, true);
}

fn seed_live_cells(
    comptime grid_order: usize,
    grid: *binary_grid.BinaryGrid(grid_order),
    live_cells: []const binary_grid.CellCoord,
) !void {
    for (live_cells) |coord| {
        try grid.set_cell(coord, true);
    }
}

fn contains_cell(live_cells: []const binary_grid.CellCoord, coord: binary_grid.CellCoord) bool {
    for (live_cells) |live_cell| {
        if (live_cell.x == coord.x and live_cell.y == coord.y) {
            return true;
        }
    }

    return false;
}

fn expect_grid_live_cells(
    comptime grid_order: usize,
    grid: *const binary_grid.BinaryGrid(grid_order),
    live_cells: []const binary_grid.CellCoord,
) !void {
    const Grid = binary_grid.BinaryGrid(grid_order);

    var y: usize = 0;
    while (y < Grid.cells_per_side) : (y += 1) {
        var x: usize = 0;
        while (x < Grid.cells_per_side) : (x += 1) {
            const coord = binary_grid.CellCoord{ .x = x, .y = y };
            try std.testing.expectEqual(contains_cell(live_cells, coord), grid.get_cell_unchecked(coord));
        }
    }
}

test "next_state implements Conway Life survival and birth rules" {
    try std.testing.expect(!next_state(false, 0));
    try std.testing.expect(!next_state(false, 1));
    try std.testing.expect(!next_state(false, 2));
    try std.testing.expect(next_state(false, 3));
    try std.testing.expect(!next_state(false, 4));
    try std.testing.expect(!next_state(false, 8));

    try std.testing.expect(!next_state(true, 0));
    try std.testing.expect(!next_state(true, 1));
    try std.testing.expect(next_state(true, 2));
    try std.testing.expect(next_state(true, 3));
    try std.testing.expect(!next_state(true, 4));
    try std.testing.expect(!next_state(true, 8));
}

test "next_transition describes Conway Life state changes" {
    try std.testing.expectEqual(Transition.birth, next_transition(false, 3));
    try std.testing.expectEqual(Transition.death, next_transition(true, 0));
    try std.testing.expectEqual(Transition.death, next_transition(true, 4));
    try std.testing.expectEqual(Transition.no_change, next_transition(false, 2));
    try std.testing.expectEqual(Transition.no_change, next_transition(true, 2));
}

test "next_transition stays consistent with next_state across all neighbor counts" {
    inline for ([_]bool{ false, true }) |current_state| {
        var alive_neighbors: u4 = 0;
        while (alive_neighbors <= 8) : (alive_neighbors += 1) {
            const new_state = next_state(current_state, alive_neighbors);
            const transition = next_transition(current_state, alive_neighbors);

            if (new_state == current_state) {
                try std.testing.expectEqual(Transition.no_change, transition);
            } else if (new_state) {
                try std.testing.expect(!current_state);
                try std.testing.expectEqual(Transition.birth, transition);
            } else {
                try std.testing.expect(current_state);
                try std.testing.expectEqual(Transition.death, transition);
            }
        }
    }
}

test "GameOfLife init_empty resets generation and clears both grids" {
    const Game = GameOfLife(0);
    var life: Game = undefined;

    life.generation = 9;
    life.grids[0].init_filled();
    life.grids[1].init_filled();

    life.init_empty();

    try std.testing.expectEqual(@as(u64, 0), life.generation);
    try expect_grid_all_dead(0, &life.grids[0]);
    try expect_grid_all_dead(0, &life.grids[1]);
}

test "GameOfLife init_from_grid copies generation zero and clears the inactive grid" {
    const Game = GameOfLife(1);
    const Grid = binary_grid.BinaryGrid(1);

    var initial: Grid = undefined;
    initial.init_empty();
    try initial.set_cell(.{ .x = 2, .y = 3 }, true);

    var life: Game = undefined;
    life.generation = 3;
    life.grids[0].init_filled();
    life.grids[1].init_filled();

    life.init_from_grid(&initial);

    try std.testing.expectEqual(@as(u64, 0), life.generation);
    try std.testing.expect(try life.grids[0].get_cell(.{ .x = 2, .y = 3 }));
    try std.testing.expect(!(try life.grids[0].get_cell(.{ .x = 0, .y = 0 })));
    try expect_grid_all_dead(1, &life.grids[1]);
    try std.testing.expect(try life.current_grid().get_cell(.{ .x = 2, .y = 3 }));
}

test "GameOfLife current_grid follows generation parity" {
    const Game = GameOfLife(0);
    var life: Game = undefined;

    life.init_empty();
    try life.grids[0].set_cell(.{ .x = 0, .y = 0 }, true);
    try life.grids[1].set_cell(.{ .x = 3, .y = 3 }, true);

    life.generation = 0;
    try std.testing.expect(try life.current_grid().get_cell(.{ .x = 0, .y = 0 }));
    try std.testing.expect(!(try life.current_grid().get_cell(.{ .x = 3, .y = 3 })));

    life.generation = 1;
    try std.testing.expect(try life.current_grid().get_cell(.{ .x = 3, .y = 3 }));
    try std.testing.expect(!(try life.current_grid().get_cell(.{ .x = 0, .y = 0 })));
}

test "GameOfLife init_generation_zero_grid returns the first buffer for external seeding" {
    const Game = GameOfLife(0);
    var life: Game = undefined;

    life.generation = 7;
    life.grids[0].init_filled();
    life.grids[1].init_filled();

    const generation_zero_grid = life.init_generation_zero_grid();
    try seed_generation_zero_grid(generation_zero_grid);

    try std.testing.expectEqual(@as(u64, 0), life.generation);
    try std.testing.expectEqual(@intFromPtr(&life.grids[0]), @intFromPtr(generation_zero_grid));
    try std.testing.expect(try life.current_grid().get_cell(.{ .x = 1, .y = 2 }));
    try std.testing.expect(try life.current_grid().get_cell(.{ .x = 2, .y = 2 }));
    try expect_grid_all_dead(0, &life.grids[1]);
}

test "GameOfLife step has a stable public signature" {
    const Game = GameOfLife(0);
    const step_fn: *const fn (*Game) void = Game.step;

    _ = step_fn;
}

test "GameOfLife step increments generation and keeps an empty grid empty" {
    const Game = GameOfLife(0);
    var life: Game = undefined;

    life.init_empty();
    life.step();

    try std.testing.expectEqual(@as(u64, 1), life.generation);
    try std.testing.expectEqual(@intFromPtr(&life.grids[1]), @intFromPtr(life.current_grid()));
    try expect_grid_all_dead(0, life.current_grid());
}

test "GameOfLife step kills an isolated live cell" {
    const Game = GameOfLife(0);
    var life: Game = undefined;

    life.init_empty();
    try life.current_grid_mut().set_cell(.{ .x = 1, .y = 1 }, true);

    life.step();

    try std.testing.expectEqual(@as(u64, 1), life.generation);
    try expect_grid_all_dead(0, life.current_grid());
}

test "GameOfLife step preserves a stable block" {
    const Game = GameOfLife(0);
    const block = [_]binary_grid.CellCoord{
        .{ .x = 1, .y = 1 },
        .{ .x = 2, .y = 1 },
        .{ .x = 1, .y = 2 },
        .{ .x = 2, .y = 2 },
    };
    var life: Game = undefined;

    try seed_live_cells(0, life.init_generation_zero_grid(), &block);

    life.step();
    try expect_grid_live_cells(0, life.current_grid(), &block);

    life.step();
    try expect_grid_live_cells(0, life.current_grid(), &block);
}

test "GameOfLife step oscillates a blinker and flips buffers" {
    const Game = GameOfLife(1);
    const vertical = [_]binary_grid.CellCoord{
        .{ .x = 3, .y = 2 },
        .{ .x = 3, .y = 3 },
        .{ .x = 3, .y = 4 },
    };
    const horizontal = [_]binary_grid.CellCoord{
        .{ .x = 2, .y = 3 },
        .{ .x = 3, .y = 3 },
        .{ .x = 4, .y = 3 },
    };
    var life: Game = undefined;

    try seed_live_cells(1, life.init_generation_zero_grid(), &vertical);

    life.step();
    try std.testing.expectEqual(@as(u64, 1), life.generation);
    try std.testing.expectEqual(@intFromPtr(&life.grids[1]), @intFromPtr(life.current_grid()));
    try expect_grid_live_cells(1, life.current_grid(), &horizontal);

    life.step();
    try std.testing.expectEqual(@as(u64, 2), life.generation);
    try std.testing.expectEqual(@intFromPtr(&life.grids[0]), @intFromPtr(life.current_grid()));
    try expect_grid_live_cells(1, life.current_grid(), &vertical);
}

test "GameOfLife step wraps neighbors across grid edges" {
    const Game = GameOfLife(0);
    const initial = [_]binary_grid.CellCoord{
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 3 },
        .{ .x = 3, .y = 0 },
    };
    const expected = [_]binary_grid.CellCoord{
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 3 },
        .{ .x = 3, .y = 0 },
        .{ .x = 3, .y = 3 },
    };
    var life: Game = undefined;

    try seed_live_cells(0, life.init_generation_zero_grid(), &initial);
    life.step();

    try expect_grid_live_cells(0, life.current_grid(), &expected);
}
