const std = @import("std");

pub const binary_grid = @import("modules/binary_grid.zig");
pub const game_of_life = @import("modules/game_of_life.zig");
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
    try std.testing.expect(try grid_instance.get_cell_neighbor(.{ .x = 0, .y = 0 }, binary_grid.Direction.NW));
    try std.testing.expect((try grid_instance.get_block(0)).get(3, 3));
    try std.testing.expect((try grid_instance.get_block_neighbor(0, .E)).get(3, 3));
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

test "package_root_exposes_game_of_life_module" {
    const Game = game_of_life.GameOfLife(0);
    var life: Game = undefined;

    const grid = life.init_generation_zero_grid();
    try grid.set_cell(.{ .x = 1, .y = 2 }, true);

    try std.testing.expectEqual(@as(u64, 0), life.generation);
    try std.testing.expect(try life.current_grid().get_cell(.{ .x = 1, .y = 2 }));
    try std.testing.expect(game_of_life.next_state(false, 3));
    try std.testing.expectEqual(game_of_life.Transition.death, game_of_life.next_transition(true, 4));

    game_of_life.init_runtime_luts();
    const step_block_fn: *const fn (*Game) void = Game.step_block;
    _ = step_block_fn;

    const neighborhood = game_of_life.BlockNeighborhood{
        .nw = binary_grid.Block.empty(),
        .n = binary_grid.Block.empty(),
        .ne = binary_grid.Block.empty(),
        .w = binary_grid.Block.empty(),
        .center = .{ .bits = 0x0660 },
        .e = binary_grid.Block.empty(),
        .sw = binary_grid.Block.empty(),
        .s = binary_grid.Block.empty(),
        .se = binary_grid.Block.empty(),
    };

    try std.testing.expectEqual(
        @as(u16, 0x0660),
        game_of_life.infer_next_block_from_neighborhood(neighborhood).bits,
    );
}
