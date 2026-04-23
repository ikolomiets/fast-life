const builtin = @import("builtin");
const std = @import("std");
const binary_grid = @import("binary_grid.zig");

const neighbor_directions = [_]binary_grid.Direction{ .N, .NE, .E, .SE, .S, .SW, .W, .NW };
const next_cell_lut: [1 << 9]bool = build_next_cell_lut();
const block_pattern_count: usize = 1 << 16;
const border_pattern_count: usize = 1 << 20;
const representative_center_patterns = [_]u16{ 0x0000, 0xffff, 0xa5a5, 0x3c5a };
const benchmark_grid_order_release_fast: usize = 8;
const benchmark_generations_release_fast: u64 = 16;
const next_center_lut_not_initialized_message =
    "game_of_life.init_runtime_luts() must be called before infer_next_block_from_neighborhood() or GameOfLife.step_block()";
const neighborhood_patch_side: usize = binary_grid.Block.side + 2;
const NeighborhoodPatchCoord = u3;

var next_center_lut_initialized: bool = false;
var next_center_lut: [block_pattern_count]u4 = undefined;

const CenterBlock = struct {
    bits: u4,

    const Self = @This();

    fn empty() Self {
        return .{ .bits = 0 };
    }

    fn bit_index(center_x: u1, center_y: u1) u2 {
        return (@as(u2, center_y) << 1) | @as(u2, center_x);
    }

    fn get(self: Self, center_x: u1, center_y: u1) bool {
        return (self.bits & (@as(u4, 1) << bit_index(center_x, center_y))) != 0;
    }

    fn set(self: *Self, center_x: u1, center_y: u1, value: bool) void {
        const mask = @as(u4, 1) << bit_index(center_x, center_y);

        if (value) {
            self.bits |= mask;
            return;
        }

        self.bits &= ~mask;
    }
};

pub const BlockNeighborhood = struct {
    nw: binary_grid.Block,
    n: binary_grid.Block,
    ne: binary_grid.Block,
    w: binary_grid.Block,
    center: binary_grid.Block,
    e: binary_grid.Block,
    sw: binary_grid.Block,
    s: binary_grid.Block,
    se: binary_grid.Block,
};

const BlockWindowSet = struct {
    nw: u16,
    ne: u16,
    sw: u16,
    se: u16,
};

const StepBenchmarkImplementation = enum {
    baseline,
    block,
};

const BenchmarkResult = struct {
    elapsed: std.Io.Duration,
    checksum: u64,
};

comptime {
    if (neighborhood_patch_side != 6) {
        @compileError("neighborhood_patch_side must remain 6");
    }
}

pub const Transition = enum {
    no_change,
    birth,
    death,
};

pub fn init_runtime_luts() void {
    if (next_center_lut_initialized) {
        return;
    }

    next_center_lut = build_next_center_lut_runtime();
    next_center_lut_initialized = true;
}

pub fn infer_next_block_from_neighborhood(neighborhood: BlockNeighborhood) binary_grid.Block {
    ensure_next_center_lut_initialized();
    return infer_next_block_from_neighborhood_initialized(neighborhood);
}

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

        pub fn step_block(self: *Self) void {
            ensure_next_center_lut_initialized();

            const current_buffer_index = self.current_index();
            const next_buffer_index = self.next_index();

            std.debug.assert(current_buffer_index < self.grids.len);
            std.debug.assert(next_buffer_index < self.grids.len);
            std.debug.assert(current_buffer_index != next_buffer_index);

            const current = &self.grids[current_buffer_index];
            const next = &self.grids[next_buffer_index];

            var block_index: usize = 0;
            while (block_index < Grid.block_count) : (block_index += 1) {
                const neighborhood = block_neighborhood(current, block_index);
                next.set_block_unchecked(
                    block_index,
                    infer_next_block_from_neighborhood_initialized(neighborhood),
                );
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

        fn block_neighborhood(current: *const Grid, block_index: usize) BlockNeighborhood {
            std.debug.assert(block_index < Grid.block_count);

            return .{
                .nw = current.get_block_neighbor_unchecked(block_index, .NW),
                .n = current.get_block_neighbor_unchecked(block_index, .N),
                .ne = current.get_block_neighbor_unchecked(block_index, .NE),
                .w = current.get_block_neighbor_unchecked(block_index, .W),
                .center = current.get_block_unchecked(block_index),
                .e = current.get_block_neighbor_unchecked(block_index, .E),
                .sw = current.get_block_neighbor_unchecked(block_index, .SW),
                .s = current.get_block_neighbor_unchecked(block_index, .S),
                .se = current.get_block_neighbor_unchecked(block_index, .SE),
            };
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

fn infer_next_block_from_neighborhood_initialized(neighborhood: BlockNeighborhood) binary_grid.Block {
    const windows = direct_block_windows(neighborhood);
    const next_nw = infer_next_center_bits_from_runtime_lut(windows.nw);
    const next_ne = infer_next_center_bits_from_runtime_lut(windows.ne);
    const next_sw = infer_next_center_bits_from_runtime_lut(windows.sw);
    const next_se = infer_next_center_bits_from_runtime_lut(windows.se);

    return .{
        .bits = center_bits_to_origin_block_bits(next_nw) |
            (center_bits_to_origin_block_bits(next_ne) << 2) |
            (center_bits_to_origin_block_bits(next_sw) << 8) |
            (center_bits_to_origin_block_bits(next_se) << 10),
    };
}

fn ensure_next_center_lut_initialized() void {
    if (!next_center_lut_initialized) {
        @panic(next_center_lut_not_initialized_message);
    }
}

fn infer_next_center_from_runtime_lut_bits(block_bits: u16) CenterBlock {
    return .{ .bits = infer_next_center_bits_from_runtime_lut(block_bits) };
}

fn infer_next_center_block_from_runtime_lut_bits(block_bits: u16) binary_grid.Block {
    return .{ .bits = center_bits_to_origin_block_bits(infer_next_center_bits_from_runtime_lut(block_bits)) << 5 };
}

fn infer_next_center_bits_from_runtime_lut(block_bits: u16) u4 {
    return next_center_lut[@as(usize, block_bits)];
}

fn build_next_cell_lut() [1 << 9]bool {
    @setEvalBranchQuota(10_000);

    var lut: [1 << 9]bool = undefined;
    var window_bits: usize = 0;
    while (window_bits < lut.len) : (window_bits += 1) {
        lut[window_bits] = next_cell_reference(@intCast(window_bits));
    }

    return lut;
}

fn build_next_center_lut_runtime() [block_pattern_count]u4 {
    var lut: [block_pattern_count]u4 = undefined;
    var block_bits: usize = 0;

    while (block_bits < lut.len) : (block_bits += 1) {
        lut[block_bits] = infer_next_center_from_bits(@intCast(block_bits)).bits;
    }

    return lut;
}

fn next_cell_reference(neighborhood: u9) bool {
    const current_state = ((neighborhood >> 4) & 1) != 0;
    const total_alive: u4 = @popCount(neighborhood);
    const alive_neighbors = total_alive - @intFromBool(current_state);

    return next_state(current_state, alive_neighbors);
}

fn infer_next_center_from_bits(block_bits: u16) CenterBlock {
    return .{ .bits = infer_next_center_bits_from_bits(block_bits) };
}

fn infer_next_center_bits_from_bits(block_bits: u16) u4 {
    const row_0 = block_bits & 0b1111;
    const row_1 = (block_bits >> 4) & 0b1111;
    const row_2 = (block_bits >> 8) & 0b1111;
    const row_3 = (block_bits >> 12) & 0b1111;
    const top_left_window: u9 = @intCast(
        (row_0 & 0b111) | ((row_1 & 0b111) << 3) | ((row_2 & 0b111) << 6),
    );
    const top_right_window: u9 = @intCast(
        ((row_0 >> 1) & 0b111) | (((row_1 >> 1) & 0b111) << 3) | (((row_2 >> 1) & 0b111) << 6),
    );
    const bottom_left_window: u9 = @intCast(
        (row_1 & 0b111) | ((row_2 & 0b111) << 3) | ((row_3 & 0b111) << 6),
    );
    const bottom_right_window: u9 = @intCast(
        ((row_1 >> 1) & 0b111) | (((row_2 >> 1) & 0b111) << 3) | (((row_3 >> 1) & 0b111) << 6),
    );
    const top_left = @as(u4, @intFromBool(next_cell_lut[top_left_window]));
    const top_right = @as(u4, @intFromBool(next_cell_lut[top_right_window]));
    const bottom_left = @as(u4, @intFromBool(next_cell_lut[bottom_left_window]));
    const bottom_right = @as(u4, @intFromBool(next_cell_lut[bottom_right_window]));

    return top_left | (top_right << 1) | (bottom_left << 2) | (bottom_right << 3);
}

fn center_bits_to_origin_block_bits(center_bits: u4) u16 {
    const top_row: u16 = center_bits & 0b0011;
    const bottom_row: u16 = (center_bits >> 2) & 0b0011;

    return top_row | (bottom_row << 4);
}

fn block_left_column_bits(block_bits: u16) u4 {
    return @intCast(
        ((block_bits >> 0) & 0b0001) |
            ((block_bits >> 3) & 0b0010) |
            ((block_bits >> 6) & 0b0100) |
            ((block_bits >> 9) & 0b1000),
    );
}

fn block_right_column_bits(block_bits: u16) u4 {
    return @intCast(
        ((block_bits >> 3) & 0b0001) |
            ((block_bits >> 6) & 0b0010) |
            ((block_bits >> 9) & 0b0100) |
            ((block_bits >> 12) & 0b1000),
    );
}

fn pack_window_rows(row_0: u4, row_1: u4, row_2: u4, row_3: u4) u16 {
    return @as(u16, row_0) |
        (@as(u16, row_1) << 4) |
        (@as(u16, row_2) << 8) |
        (@as(u16, row_3) << 12);
}

fn direct_block_windows(neighborhood: BlockNeighborhood) BlockWindowSet {
    const north_row = neighborhood.n.row_mask(3);
    const south_row = neighborhood.s.row_mask(0);
    const center_row_0 = neighborhood.center.row_mask(0);
    const center_row_1 = neighborhood.center.row_mask(1);
    const center_row_2 = neighborhood.center.row_mask(2);
    const center_row_3 = neighborhood.center.row_mask(3);
    const west_edge_bits = block_right_column_bits(neighborhood.w.bits);
    const east_edge_bits = block_left_column_bits(neighborhood.e.bits);
    const nw_corner: u1 = @intCast((neighborhood.nw.bits >> 15) & 1);
    const ne_corner: u1 = @intCast((neighborhood.ne.bits >> 12) & 1);
    const sw_corner: u1 = @intCast((neighborhood.sw.bits >> 3) & 1);
    const se_corner: u1 = @intCast(neighborhood.se.bits & 1);

    return .{
        .nw = pack_window_rows(
            @intCast(@as(u4, nw_corner) | ((north_row & 0b0111) << 1)),
            @intCast(@as(u4, west_edge_bits & 1) | ((center_row_0 & 0b0111) << 1)),
            @intCast(@as(u4, (west_edge_bits >> 1) & 1) | ((center_row_1 & 0b0111) << 1)),
            @intCast(@as(u4, (west_edge_bits >> 2) & 1) | ((center_row_2 & 0b0111) << 1)),
        ),
        .ne = pack_window_rows(
            @intCast(((north_row >> 1) & 0b0111) | (@as(u4, ne_corner) << 3)),
            @intCast(((center_row_0 >> 1) & 0b0111) | (@as(u4, east_edge_bits & 1) << 3)),
            @intCast(((center_row_1 >> 1) & 0b0111) | (@as(u4, (east_edge_bits >> 1) & 1) << 3)),
            @intCast(((center_row_2 >> 1) & 0b0111) | (@as(u4, (east_edge_bits >> 2) & 1) << 3)),
        ),
        .sw = pack_window_rows(
            @intCast(@as(u4, (west_edge_bits >> 1) & 1) | ((center_row_1 & 0b0111) << 1)),
            @intCast(@as(u4, (west_edge_bits >> 2) & 1) | ((center_row_2 & 0b0111) << 1)),
            @intCast(@as(u4, (west_edge_bits >> 3) & 1) | ((center_row_3 & 0b0111) << 1)),
            @intCast(@as(u4, sw_corner) | ((south_row & 0b0111) << 1)),
        ),
        .se = pack_window_rows(
            @intCast(((center_row_1 >> 1) & 0b0111) | (@as(u4, (east_edge_bits >> 1) & 1) << 3)),
            @intCast(((center_row_2 >> 1) & 0b0111) | (@as(u4, (east_edge_bits >> 2) & 1) << 3)),
            @intCast(((center_row_3 >> 1) & 0b0111) | (@as(u4, (east_edge_bits >> 3) & 1) << 3)),
            @intCast(((south_row >> 1) & 0b0111) | (@as(u4, se_corner) << 3)),
        ),
    };
}

fn infer_next_center_reference(block: binary_grid.Block) CenterBlock {
    var center = CenterBlock.empty();

    inline for ([_]u1{ 0, 1 }) |center_y| {
        inline for ([_]u1{ 0, 1 }) |center_x| {
            const source_x: binary_grid.Block.LocalCoord = @intCast(@as(u2, center_x) + 1);
            const source_y: binary_grid.Block.LocalCoord = @intCast(@as(u2, center_y) + 1);
            const current_state = block.get(source_x, source_y);
            const alive_neighbors = count_alive_neighbors(block, source_x, source_y);

            center.set(center_x, center_y, next_state(current_state, alive_neighbors));
        }
    }

    return center;
}

fn count_alive_neighbors(
    block: binary_grid.Block,
    source_x: binary_grid.Block.LocalCoord,
    source_y: binary_grid.Block.LocalCoord,
) u4 {
    std.debug.assert(source_x >= 1 and source_x <= 2);
    std.debug.assert(source_y >= 1 and source_y <= 2);

    const x: usize = @intCast(source_x);
    const y: usize = @intCast(source_y);
    var alive_neighbors: u4 = 0;
    var neighbor_y: usize = y - 1;

    while (neighbor_y <= y + 1) : (neighbor_y += 1) {
        var neighbor_x: usize = x - 1;
        while (neighbor_x <= x + 1) : (neighbor_x += 1) {
            if (neighbor_x == x and neighbor_y == y) {
                continue;
            }

            if (block.get(@intCast(neighbor_x), @intCast(neighbor_y))) {
                alive_neighbors += 1;
            }
        }
    }

    return alive_neighbors;
}

fn infer_next_block_reference(neighborhood: BlockNeighborhood) binary_grid.Block {
    var next = binary_grid.Block.empty();

    var local_y: usize = 0;
    while (local_y < binary_grid.Block.side) : (local_y += 1) {
        const y: binary_grid.Block.LocalCoord = @intCast(local_y);

        var local_x: usize = 0;
        while (local_x < binary_grid.Block.side) : (local_x += 1) {
            const x: binary_grid.Block.LocalCoord = @intCast(local_x);
            const current_state = neighborhood.center.get(x, y);
            const alive_neighbors = count_alive_neighbors_in_neighborhood(neighborhood, x, y);
            next.set(x, y, next_state(current_state, alive_neighbors));
        }
    }

    return next;
}

fn count_alive_neighbors_in_neighborhood(
    neighborhood: BlockNeighborhood,
    local_x: binary_grid.Block.LocalCoord,
    local_y: binary_grid.Block.LocalCoord,
) u4 {
    var alive_neighbors: u4 = 0;
    const top_left_x: usize = @intCast(local_x);
    const top_left_y: usize = @intCast(local_y);
    var patch_y_offset: usize = 0;

    while (patch_y_offset < 3) : (patch_y_offset += 1) {
        var patch_x_offset: usize = 0;

        while (patch_x_offset < 3) : (patch_x_offset += 1) {
            if (patch_x_offset == 1 and patch_y_offset == 1) {
                continue;
            }

            const patch_x: NeighborhoodPatchCoord = @intCast(top_left_x + patch_x_offset);
            const patch_y: NeighborhoodPatchCoord = @intCast(top_left_y + patch_y_offset);

            if (neighborhood_patch_cell(neighborhood, patch_x, patch_y)) {
                alive_neighbors += 1;
            }
        }
    }

    return alive_neighbors;
}

fn neighborhood_patch_cell(
    neighborhood: BlockNeighborhood,
    patch_x: NeighborhoodPatchCoord,
    patch_y: NeighborhoodPatchCoord,
) bool {
    std.debug.assert(patch_x < neighborhood_patch_side);
    std.debug.assert(patch_y < neighborhood_patch_side);

    if (patch_y == 0) {
        if (patch_x == 0) {
            return neighborhood.nw.get(3, 3);
        }
        if (patch_x == 5) {
            return neighborhood.ne.get(0, 3);
        }

        const x: binary_grid.Block.LocalCoord = @intCast(@as(usize, patch_x) - 1);
        return neighborhood.n.get(x, 3);
    }

    if (patch_y == 5) {
        if (patch_x == 0) {
            return neighborhood.sw.get(3, 0);
        }
        if (patch_x == 5) {
            return neighborhood.se.get(0, 0);
        }

        const x: binary_grid.Block.LocalCoord = @intCast(@as(usize, patch_x) - 1);
        return neighborhood.s.get(x, 0);
    }

    if (patch_x == 0) {
        const y: binary_grid.Block.LocalCoord = @intCast(@as(usize, patch_y) - 1);
        return neighborhood.w.get(3, y);
    }

    if (patch_x == 5) {
        const y: binary_grid.Block.LocalCoord = @intCast(@as(usize, patch_y) - 1);
        return neighborhood.e.get(0, y);
    }

    const x: binary_grid.Block.LocalCoord = @intCast(@as(usize, patch_x) - 1);
    const y: binary_grid.Block.LocalCoord = @intCast(@as(usize, patch_y) - 1);
    return neighborhood.center.get(x, y);
}

fn neighborhood_from_center_and_border_bits(center_bits: u16, border_bits: u20) BlockNeighborhood {
    var neighborhood = BlockNeighborhood{
        .nw = binary_grid.Block.empty(),
        .n = binary_grid.Block.empty(),
        .ne = binary_grid.Block.empty(),
        .w = binary_grid.Block.empty(),
        .center = .{ .bits = center_bits },
        .e = binary_grid.Block.empty(),
        .sw = binary_grid.Block.empty(),
        .s = binary_grid.Block.empty(),
        .se = binary_grid.Block.empty(),
    };

    var x: usize = 0;
    while (x < neighborhood_patch_side) : (x += 1) {
        const top_bit_index: u5 = @intCast(x);
        if (((border_bits >> top_bit_index) & 1) != 0) {
            switch (x) {
                0 => neighborhood.nw.set(3, 3, true),
                5 => neighborhood.ne.set(0, 3, true),
                else => neighborhood.n.set(@intCast(x - 1), 3, true),
            }
        }

        const bottom_bit_index: u5 = @intCast(14 + x);
        if (((border_bits >> bottom_bit_index) & 1) != 0) {
            switch (x) {
                0 => neighborhood.sw.set(3, 0, true),
                5 => neighborhood.se.set(0, 0, true),
                else => neighborhood.s.set(@intCast(x - 1), 0, true),
            }
        }
    }

    var y: usize = 0;
    while (y < binary_grid.Block.side) : (y += 1) {
        const top_to_bottom_y: binary_grid.Block.LocalCoord = @intCast(y);
        const left_bit_index: u5 = @intCast(6 + y);
        if (((border_bits >> left_bit_index) & 1) != 0) {
            neighborhood.w.set(3, top_to_bottom_y, true);
        }

        const right_bit_index: u5 = @intCast(10 + y);
        if (((border_bits >> right_bit_index) & 1) != 0) {
            neighborhood.e.set(0, top_to_bottom_y, true);
        }
    }

    return neighborhood;
}

fn duration_nanoseconds(elapsed: std.Io.Duration) u128 {
    const elapsed_ns_signed = elapsed.toNanoseconds();
    std.debug.assert(elapsed_ns_signed >= 0);
    return @intCast(elapsed_ns_signed);
}

fn duration_seconds_microseconds(elapsed: std.Io.Duration) struct {
    seconds: u128,
    microseconds: u128,
} {
    const elapsed_ns = duration_nanoseconds(elapsed);

    return .{
        .seconds = elapsed_ns / std.time.ns_per_s,
        .microseconds = (elapsed_ns % std.time.ns_per_s) / std.time.ns_per_us,
    };
}

fn grid_checksum(
    comptime grid_order: usize,
    grid: *const binary_grid.BinaryGrid(grid_order),
) u64 {
    const Grid = binary_grid.BinaryGrid(grid_order);
    var checksum: u64 = 0;
    var block_index: usize = 0;

    while (block_index < Grid.block_count) : (block_index += 1) {
        checksum +%= (@as(u64, block_index) + 1) *% (@as(u64, grid.blocks[block_index].bits) + 1);
    }

    return checksum;
}

fn seed_benchmark_grid(
    comptime grid_order: usize,
    grid: *binary_grid.BinaryGrid(grid_order),
) void {
    const Grid = binary_grid.BinaryGrid(grid_order);
    var block_index: usize = 0;

    while (block_index < Grid.block_count) : (block_index += 1) {
        const mixed = (block_index *% 0x9e37) ^ 0xa5a5;
        grid.set_block_unchecked(block_index, .{ .bits = @truncate(mixed) });
    }
}

fn benchmark_step_implementation(
    io: std.Io,
    comptime implementation: StepBenchmarkImplementation,
    generations: u64,
) BenchmarkResult {
    const Game = GameOfLife(benchmark_grid_order_release_fast);
    var life: Game = undefined;

    seed_benchmark_grid(benchmark_grid_order_release_fast, life.init_generation_zero_grid());

    const start = std.Io.Clock.awake.now(io);
    var generation: u64 = 0;
    while (generation < generations) : (generation += 1) {
        switch (implementation) {
            .baseline => life.step(),
            .block => life.step_block(),
        }
    }

    const checksum = grid_checksum(benchmark_grid_order_release_fast, life.current_grid());
    std.mem.doNotOptimizeAway(checksum);

    return .{
        .elapsed = start.durationTo(std.Io.Clock.awake.now(io)),
        .checksum = checksum,
    };
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

test "next_cell_lut matches the Conway rule for every 3x3 neighborhood" {
    var window_bits: usize = 0;
    while (window_bits < next_cell_lut.len) : (window_bits += 1) {
        try std.testing.expectEqual(
            next_cell_reference(@intCast(window_bits)),
            next_cell_lut[window_bits],
        );
    }
}

test "runtime center LUT returns empty for an empty block" {
    init_runtime_luts();
    try std.testing.expectEqualDeep(
        CenterBlock.empty(),
        infer_next_center_from_runtime_lut_bits(binary_grid.Block.empty().bits),
    );
}

test "runtime center LUT keeps a centered 2x2 still life alive" {
    init_runtime_luts();
    var block = binary_grid.Block.empty();
    block.set(1, 1, true);
    block.set(2, 1, true);
    block.set(1, 2, true);
    block.set(2, 2, true);

    try std.testing.expectEqual(@as(u4, 0b1111), infer_next_center_from_runtime_lut_bits(block.bits).bits);
}

test "runtime center LUT births the missing center cell when exactly three neighbors are present" {
    init_runtime_luts();
    var block = binary_grid.Block.empty();
    block.set(2, 1, true);
    block.set(1, 2, true);
    block.set(2, 2, true);

    try std.testing.expectEqual(@as(u4, 0b1111), infer_next_center_from_runtime_lut_bits(block.bits).bits);
}

test "runtime center LUT handles crowded center cells" {
    init_runtime_luts();
    var block = binary_grid.Block.empty();
    block.set(1, 1, true);
    block.set(2, 1, true);
    block.set(3, 1, true);
    block.set(1, 2, true);
    block.set(2, 2, true);
    block.set(3, 2, true);

    try std.testing.expectEqual(@as(u4, 0b0101), infer_next_center_from_runtime_lut_bits(block.bits).bits);
}

test "runtime center LUT block helper writes only the center cells" {
    init_runtime_luts();
    var block = binary_grid.Block.empty();
    block.set(1, 1, true);
    block.set(2, 1, true);
    block.set(1, 2, true);
    block.set(2, 2, true);

    const next = infer_next_center_block_from_runtime_lut_bits(block.bits);

    try std.testing.expectEqual(@as(u16, 0x0660), next.bits);

    var y: usize = 0;
    while (y < binary_grid.Block.side) : (y += 1) {
        var x: usize = 0;
        while (x < binary_grid.Block.side) : (x += 1) {
            const is_center = x >= 1 and x <= 2 and y >= 1 and y <= 2;
            try std.testing.expectEqual(is_center, next.get(@intCast(x), @intCast(y)));
        }
    }
}

test "center_bits_to_origin_block_bits matches 2x2 origin placement for every center pattern" {
    var center_bits_value: usize = 0;

    while (center_bits_value < 16) : (center_bits_value += 1) {
        const center = CenterBlock{ .bits = @intCast(center_bits_value) };
        var expected = binary_grid.Block.empty();

        expected.set(0, 0, center.get(0, 0));
        expected.set(1, 0, center.get(1, 0));
        expected.set(0, 1, center.get(0, 1));
        expected.set(1, 1, center.get(1, 1));

        try std.testing.expectEqual(
            expected.bits,
            center_bits_to_origin_block_bits(center.bits),
        );
    }
}

test "direct_block_windows extracts the top-left 4x4 block from nw n w and center" {
    var neighborhood = neighborhood_from_center_and_border_bits(0, 0);
    neighborhood.nw.set(3, 3, true);
    neighborhood.n.set(0, 3, true);
    neighborhood.n.set(2, 3, true);
    neighborhood.w.set(3, 1, true);
    neighborhood.center.set(1, 0, true);
    neighborhood.center.set(0, 2, true);
    neighborhood.center.set(2, 2, true);

    const windows = direct_block_windows(neighborhood);

    try std.testing.expectEqual(@as(u16, 0xa14b), windows.nw);
}

test "direct_block_windows extracts the top-right 4x4 block from n ne center and e" {
    var neighborhood = neighborhood_from_center_and_border_bits(0, 0);
    neighborhood.n.set(1, 3, true);
    neighborhood.n.set(3, 3, true);
    neighborhood.ne.set(0, 3, true);
    neighborhood.center.set(2, 0, true);
    neighborhood.center.set(1, 1, true);
    neighborhood.center.set(3, 1, true);
    neighborhood.center.set(2, 2, true);
    neighborhood.e.set(0, 2, true);

    const windows = direct_block_windows(neighborhood);

    try std.testing.expectEqual(@as(u16, 0xa52d), windows.ne);
}

test "direct_block_windows extracts the bottom-left 4x4 block from w center sw and s" {
    var neighborhood = neighborhood_from_center_and_border_bits(0, 0);
    neighborhood.w.set(3, 1, true);
    neighborhood.center.set(2, 1, true);
    neighborhood.w.set(3, 2, true);
    neighborhood.center.set(0, 2, true);
    neighborhood.center.set(1, 2, true);
    neighborhood.w.set(3, 3, true);
    neighborhood.center.set(1, 3, true);
    neighborhood.sw.set(3, 0, true);
    neighborhood.s.set(2, 0, true);

    const windows = direct_block_windows(neighborhood);

    try std.testing.expectEqual(@as(u16, 0x9579), windows.sw);
}

test "direct_block_windows extracts the bottom-right 4x4 block from center e s and se" {
    var neighborhood = neighborhood_from_center_and_border_bits(0, 0);
    neighborhood.center.set(1, 1, true);
    neighborhood.center.set(3, 1, true);
    neighborhood.center.set(2, 2, true);
    neighborhood.e.set(0, 2, true);
    neighborhood.center.set(1, 3, true);
    neighborhood.center.set(3, 3, true);
    neighborhood.s.set(2, 0, true);
    neighborhood.se.set(0, 0, true);

    const windows = direct_block_windows(neighborhood);

    try std.testing.expectEqual(@as(u16, 0xa5a5), windows.se);
}

test "build_next_center_lut_runtime matches the direct 4x3x3 evaluator for every 4x4 block" {
    const lut = build_next_center_lut_runtime();
    var bits: usize = 0;

    while (bits < block_pattern_count) : (bits += 1) {
        try std.testing.expectEqual(
            infer_next_center_from_bits(@intCast(bits)).bits,
            lut[bits],
        );
    }
}

test "runtime center LUT matches the direct evaluator for every 4x4 block" {
    init_runtime_luts();
    var bits: usize = 0;
    while (bits < block_pattern_count) : (bits += 1) {
        const block = binary_grid.Block{ .bits = @intCast(bits) };

        try std.testing.expectEqualDeep(
            infer_next_center_reference(block),
            infer_next_center_from_runtime_lut_bits(block.bits),
        );
    }
}

test "init_runtime_luts is idempotent" {
    const expected = build_next_center_lut_runtime();

    init_runtime_luts();
    const snapshot = next_center_lut;
    init_runtime_luts();

    try std.testing.expect(next_center_lut_initialized);
    try std.testing.expectEqualDeep(expected, next_center_lut);
    try std.testing.expectEqualDeep(snapshot, next_center_lut);
}

test "infer_next_block_from_neighborhood returns empty for an empty neighborhood" {
    init_runtime_luts();
    const neighborhood = neighborhood_from_center_and_border_bits(0, 0);

    try std.testing.expectEqual(@as(u16, 0), infer_next_block_from_neighborhood(neighborhood).bits);
}

test "infer_next_block_from_neighborhood keeps a centered still life stable" {
    init_runtime_luts();
    const neighborhood = neighborhood_from_center_and_border_bits(0x0660, 0);

    try std.testing.expectEqual(@as(u16, 0x0660), infer_next_block_from_neighborhood(neighborhood).bits);
}

test "infer_next_block_from_neighborhood births a corner cell from neighbor blocks" {
    init_runtime_luts();
    const neighborhood = neighborhood_from_center_and_border_bits(0, (1 << 0) | (1 << 1) | (1 << 6));

    try std.testing.expectEqual(@as(u16, 0x0001), infer_next_block_from_neighborhood(neighborhood).bits);
}

test "infer_next_block_from_neighborhood handles a top-edge oscillator using n" {
    init_runtime_luts();
    const neighborhood = neighborhood_from_center_and_border_bits(0x0022, 1 << 2);

    try std.testing.expectEqual(@as(u16, 0x0007), infer_next_block_from_neighborhood(neighborhood).bits);
}

test "infer_next_block_from_neighborhood handles a right-edge oscillator using e" {
    init_runtime_luts();
    const neighborhood = neighborhood_from_center_and_border_bits(0x00c0, 1 << 11);

    try std.testing.expectEqual(@as(u16, 0x0888), infer_next_block_from_neighborhood(neighborhood).bits);
}

test "infer_next_block_from_neighborhood matches the direct evaluator for every center block with empty borders" {
    init_runtime_luts();
    var center_bits: usize = 0;
    while (center_bits < block_pattern_count) : (center_bits += 1) {
        const neighborhood = neighborhood_from_center_and_border_bits(@intCast(center_bits), 0);

        try std.testing.expectEqual(
            infer_next_block_reference(neighborhood).bits,
            infer_next_block_from_neighborhood(neighborhood).bits,
        );
    }
}

test "infer_next_block_from_neighborhood matches the direct evaluator for representative centers across every border" {
    init_runtime_luts();
    for (representative_center_patterns) |center_bits| {
        var border_bits: usize = 0;

        while (border_bits < border_pattern_count) : (border_bits += 1) {
            const neighborhood = neighborhood_from_center_and_border_bits(
                center_bits,
                @intCast(border_bits),
            );

            try std.testing.expectEqual(
                infer_next_block_reference(neighborhood).bits,
                infer_next_block_from_neighborhood(neighborhood).bits,
            );
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

test "GameOfLife step_block has a stable public signature" {
    const Game = GameOfLife(0);
    const step_block_fn: *const fn (*Game) void = Game.step_block;

    _ = step_block_fn;
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

test "GameOfLife step_block increments generation and keeps an empty grid empty" {
    init_runtime_luts();
    const Game = GameOfLife(0);
    var life: Game = undefined;

    life.init_empty();
    life.step_block();

    try std.testing.expectEqual(@as(u64, 1), life.generation);
    try std.testing.expectEqual(@intFromPtr(&life.grids[1]), @intFromPtr(life.current_grid()));
    try expect_grid_all_dead(0, life.current_grid());
}

test "GameOfLife step_block kills an isolated live cell" {
    init_runtime_luts();
    const Game = GameOfLife(0);
    var life: Game = undefined;

    life.init_empty();
    try life.current_grid_mut().set_cell(.{ .x = 1, .y = 1 }, true);

    life.step_block();

    try std.testing.expectEqual(@as(u64, 1), life.generation);
    try expect_grid_all_dead(0, life.current_grid());
}

test "GameOfLife step_block preserves a stable block" {
    init_runtime_luts();
    const Game = GameOfLife(0);
    const block = [_]binary_grid.CellCoord{
        .{ .x = 1, .y = 1 },
        .{ .x = 2, .y = 1 },
        .{ .x = 1, .y = 2 },
        .{ .x = 2, .y = 2 },
    };
    var life: Game = undefined;

    try seed_live_cells(0, life.init_generation_zero_grid(), &block);

    life.step_block();
    try expect_grid_live_cells(0, life.current_grid(), &block);

    life.step_block();
    try expect_grid_live_cells(0, life.current_grid(), &block);
}

test "GameOfLife step_block oscillates a blinker and flips buffers" {
    init_runtime_luts();
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

    life.step_block();
    try std.testing.expectEqual(@as(u64, 1), life.generation);
    try std.testing.expectEqual(@intFromPtr(&life.grids[1]), @intFromPtr(life.current_grid()));
    try expect_grid_live_cells(1, life.current_grid(), &horizontal);

    life.step_block();
    try std.testing.expectEqual(@as(u64, 2), life.generation);
    try std.testing.expectEqual(@intFromPtr(&life.grids[0]), @intFromPtr(life.current_grid()));
    try expect_grid_live_cells(1, life.current_grid(), &vertical);
}

test "GameOfLife step_block wraps neighbors across grid edges" {
    init_runtime_luts();
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
    life.step_block();

    try expect_grid_live_cells(0, life.current_grid(), &expected);
}

test "GameOfLife step_block matches step for every order-zero grid state" {
    init_runtime_luts();
    const Game = GameOfLife(0);
    var bits: usize = 0;

    while (bits < block_pattern_count) : (bits += 1) {
        var reference: Game = undefined;
        var block: Game = undefined;

        const reference_grid = reference.init_generation_zero_grid();
        reference_grid.set_block_unchecked(0, .{ .bits = @intCast(bits) });

        const block_grid = block.init_generation_zero_grid();
        block_grid.set_block_unchecked(0, .{ .bits = @intCast(bits) });

        reference.step();
        block.step_block();

        try std.testing.expectEqual(@as(u64, 1), reference.generation);
        try std.testing.expectEqual(reference.generation, block.generation);
        try std.testing.expectEqualDeep(reference.current_grid().*, block.current_grid().*);
    }
}

test "GameOfLife step_block matches step across multiple generations for representative order-one patterns" {
    init_runtime_luts();
    const Game = GameOfLife(1);
    const vertical = [_]binary_grid.CellCoord{
        .{ .x = 3, .y = 2 },
        .{ .x = 3, .y = 3 },
        .{ .x = 3, .y = 4 },
    };
    const wrapped = [_]binary_grid.CellCoord{
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 7 },
        .{ .x = 7, .y = 0 },
    };
    const patterns = [_][]const binary_grid.CellCoord{ &vertical, &wrapped };

    for (patterns) |pattern| {
        var reference: Game = undefined;
        var block: Game = undefined;

        try seed_live_cells(1, reference.init_generation_zero_grid(), pattern);
        try seed_live_cells(1, block.init_generation_zero_grid(), pattern);

        var generation: u64 = 0;
        while (generation < 4) : (generation += 1) {
            reference.step();
            block.step_block();

            try std.testing.expectEqual(reference.generation, block.generation);
            try std.testing.expectEqualDeep(reference.current_grid().*, block.current_grid().*);
        }
    }
}

test "GameOfLife step and step_block benchmark reports speedup in ReleaseFast" {
    if (builtin.mode != .ReleaseFast) {
        return;
    }

    init_runtime_luts();

    const reference = benchmark_step_implementation(
        std.testing.io,
        .baseline,
        benchmark_generations_release_fast,
    );
    const block = benchmark_step_implementation(
        std.testing.io,
        .block,
        benchmark_generations_release_fast,
    );

    try std.testing.expectEqual(reference.checksum, block.checksum);

    const reference_elapsed = duration_seconds_microseconds(reference.elapsed);
    const block_elapsed = duration_seconds_microseconds(block.elapsed);
    const block_ns = duration_nanoseconds(block.elapsed);

    if (block_ns == 0) {
        std.debug.print(
            "game_of_life benchmark grid_order={d} generations={d} reference_s={d}.{d:0>6} block_s={d}.{d:0>6} speedup=inf\n",
            .{
                benchmark_grid_order_release_fast,
                benchmark_generations_release_fast,
                reference_elapsed.seconds,
                reference_elapsed.microseconds,
                block_elapsed.seconds,
                block_elapsed.microseconds,
            },
        );
        return;
    }

    const speedup_x1000 = (duration_nanoseconds(reference.elapsed) * 1000) / block_ns;
    std.debug.print(
        "game_of_life benchmark grid_order={d} generations={d} reference_s={d}.{d:0>6} block_s={d}.{d:0>6} speedup={d}.{d:0>3}x\n",
        .{
            benchmark_grid_order_release_fast,
            benchmark_generations_release_fast,
            reference_elapsed.seconds,
            reference_elapsed.microseconds,
            block_elapsed.seconds,
            block_elapsed.microseconds,
            speedup_x1000 / 1000,
            speedup_x1000 % 1000,
        },
    );
}
