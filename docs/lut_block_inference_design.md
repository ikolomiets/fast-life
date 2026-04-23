# LUT Block Inference Design

## Overview

This document describes the current block-neighborhood LUT path in
`src/modules/game_of_life.zig`.

Relevant code:

- `src/modules/game_of_life.zig` contains the runtime LUT initialization, the block helper, and
  `GameOfLife.step_block()`
- `src/modules/binary_grid.zig` defines the packed `4 x 4` `Block` representation and wrapped
  block-neighbor access
- `docs/game_of_life_design.md` describes the broader `GameOfLife` API and CLI behavior

The block-LUT path is now part of the `game_of_life` module:

- `GameOfLife.step()` remains the cell-wise baseline implementation
- `GameOfLife.step_block()` is the block-wise stepping alternative that uses the LUT path
- callers must call `game_of_life.init_runtime_luts()` before using either
  `infer_next_block_from_neighborhood(...)` or `GameOfLife.step_block()`

## Public Surface

The current public API is:

```zig
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

pub fn init_runtime_luts() void
pub fn infer_next_block_from_neighborhood(
    neighborhood: BlockNeighborhood,
) binary_grid.Block

pub fn GameOfLife(comptime grid_order: usize) type
// ...
pub fn step(self: *Self) void
pub fn step_block(self: *Self) void
```

`infer_next_block_from_neighborhood(...)` returns the full next-state `4 x 4` block for
`neighborhood.center`.

`step_block()` applies that helper across the whole wrapped grid, one source block at a time.

## Geometry And Bit Layout

`binary_grid.Block` stores a `4 x 4` tile in one `u16` with row-major bit numbering:

```text
row 0: bits  0  1  2  3
row 1: bits  4  5  6  7
row 2: bits  8  9 10 11
row 3: bits 12 13 14 15
```

The block-neighborhood helper reasons about the next state of all `16` cells in the center block.
That requires the one-cell border supplied by the eight neighboring blocks.

Those nine blocks define the same logical `6 x 6` cell context:

```text
row 0: nw(3,3)  n(0,3)  n(1,3)  n(2,3)  n(3,3)  ne(0,3)
row 1:  w(3,0)  c(0,0)  c(1,0)  c(2,0)  c(3,0)   e(0,0)
row 2:  w(3,1)  c(0,1)  c(1,1)  c(2,1)  c(3,1)   e(0,1)
row 3:  w(3,2)  c(0,2)  c(1,2)  c(2,2)  c(3,2)   e(0,2)
row 4:  w(3,3)  c(0,3)  c(1,3)  c(2,3)  c(3,3)   e(0,3)
row 5: sw(3,0)  s(0,0)  s(1,0)  s(2,0)  s(3,0)  se(0,0)
```

Where `c(...)` refers to `neighborhood.center`.

The optimized path does not materialize that `6 x 6` context as a dedicated packed object. It uses
the same geometry directly when building the four `4 x 4` LUT inputs it needs.

## Required LUTs

The implementation uses two LUT layers.

### Primitive `3 x 3 -> next cell` LUT

The primitive LUT is:

```zig
const next_cell_lut: [1 << 9]bool = build_next_cell_lut();
```

Each `u9` entry is one row-major `3 x 3` neighborhood:

- bit `4` is the current cell
- the other eight bits are the neighbors

`build_next_cell_lut()` iterates over all `512` neighborhoods and computes each entry by:

1. extracting the center bit
2. counting live bits with `@popCount(...)`
3. subtracting the center bit to obtain the live-neighbor count
4. calling `next_state(...)`

### Runtime `4 x 4 -> inner 2 x 2` LUT

The second LUT is runtime-initialized:

```zig
var next_center_lut: [1 << 16]u4 = undefined;
```

`init_runtime_luts()` fills it once through `build_next_center_lut_runtime()`.

Each entry maps:

- input: one packed `binary_grid.Block.bits`
- output: one packed `u4` center result

The builder iterates over all `65536` `4 x 4` block patterns and computes each entry by:

1. splitting the `u16` block into four packed `u4` rows
2. extracting the four `3 x 3` windows whose centers are the inner `2 x 2`
3. looking those windows up in `next_cell_lut`
4. packing the four returned cell states into one `u4`

The packed center layout is:

```text
top_left | (top_right << 1) | (bottom_left << 2) | (bottom_right << 3)
```

After initialization, the hot lookup is:

```zig
next_center_lut[@as(usize, block_bits)]
```

## Fast Path In `infer_next_block_from_neighborhood(...)`

The optimized block helper does:

1. verify that `init_runtime_luts()` has run
2. extract the border rows, center rows, edge columns, and corner bits from `BlockNeighborhood`
3. pack four overlapping `4 x 4` windows with `direct_block_windows(...)`
4. look each window up in `next_center_lut`
5. assemble the four `u4` quadrant results into one returned `binary_grid.Block`

### Direct Window Extraction

`direct_block_windows(...)` first extracts:

```zig
north_row = neighborhood.n.row_mask(3)
south_row = neighborhood.s.row_mask(0)

center_row_0 = neighborhood.center.row_mask(0)
center_row_1 = neighborhood.center.row_mask(1)
center_row_2 = neighborhood.center.row_mask(2)
center_row_3 = neighborhood.center.row_mask(3)

west_edge_bits = block_right_column_bits(neighborhood.w.bits)
east_edge_bits = block_left_column_bits(neighborhood.e.bits)

nw_corner = (neighborhood.nw.bits >> 15) & 1
ne_corner = (neighborhood.ne.bits >> 12) & 1
sw_corner = (neighborhood.sw.bits >> 3) & 1
se_corner = neighborhood.se.bits & 1
```

The four required windows are:

| Window | Logical `6 x 6` top-left | Produces output cells |
| ------ | ------------------------ | --------------------- |
| `nw`   | `(0,0)`                  | `(0..1, 0..1)`        |
| `ne`   | `(2,0)`                  | `(2..3, 0..1)`        |
| `sw`   | `(0,2)`                  | `(0..1, 2..3)`        |
| `se`   | `(2,2)`                  | `(2..3, 2..3)`        |

Each window is packed from four `u4` rows through:

```text
row0 | (row1 << 4) | (row2 << 8) | (row3 << 12)
```

The exact row formulas are:

```text
nw:
row0 = nw_corner | ((north_row & 0b0111) << 1)
row1 = (west_edge_bits & 1) | ((center_row_0 & 0b0111) << 1)
row2 = ((west_edge_bits >> 1) & 1) | ((center_row_1 & 0b0111) << 1)
row3 = ((west_edge_bits >> 2) & 1) | ((center_row_2 & 0b0111) << 1)

ne:
row0 = ((north_row >> 1) & 0b0111) | (ne_corner << 3)
row1 = ((center_row_0 >> 1) & 0b0111) | ((east_edge_bits & 1) << 3)
row2 = ((center_row_1 >> 1) & 0b0111) | (((east_edge_bits >> 1) & 1) << 3)
row3 = ((center_row_2 >> 1) & 0b0111) | (((east_edge_bits >> 2) & 1) << 3)

sw:
row0 = ((west_edge_bits >> 1) & 1) | ((center_row_1 & 0b0111) << 1)
row1 = ((west_edge_bits >> 2) & 1) | ((center_row_2 & 0b0111) << 1)
row2 = ((west_edge_bits >> 3) & 1) | ((center_row_3 & 0b0111) << 1)
row3 = sw_corner | ((south_row & 0b0111) << 1)

se:
row0 = ((center_row_1 >> 1) & 0b0111) | (((east_edge_bits >> 1) & 1) << 3)
row1 = ((center_row_2 >> 1) & 0b0111) | (((east_edge_bits >> 2) & 1) << 3)
row2 = ((center_row_3 >> 1) & 0b0111) | (((east_edge_bits >> 3) & 1) << 3)
row3 = ((south_row >> 1) & 0b0111) | (se_corner << 3)
```

This avoids materializing a generic packed `6 x 6` intermediate.

### Final Block Assembly

Each window lookup returns one packed `u4` center result.

`center_bits_to_origin_block_bits(...)` remaps that `u4` into origin `2 x 2` block bits:

```text
top_row    = center_bits & 0b0011
bottom_row = (center_bits >> 2) & 0b0011
result     = top_row | (bottom_row << 4)
```

The full next block is then assembled as:

```zig
result_bits =
    center_bits_to_origin_block_bits(next_nw) |
    (center_bits_to_origin_block_bits(next_ne) << 2) |
    (center_bits_to_origin_block_bits(next_sw) << 8) |
    (center_bits_to_origin_block_bits(next_se) << 10)
```

The quadrant shifts are:

- `0` for the top-left
- `2` for the top-right
- `8` for the bottom-left
- `10` for the bottom-right

## Whole-Grid Integration In `step_block()`

`GameOfLife.step_block()` applies the same helper across the whole wrapped grid:

1. verify the runtime LUT is initialized
2. select current and next buffers by generation parity
3. iterate over every block index in the current grid
4. gather that block's wrapped `BlockNeighborhood`
5. compute the next block with `infer_next_block_from_neighborhood(...)`
6. write the next block directly into the next buffer
7. increment `generation`

Unlike the baseline `step()`, `step_block()` does not copy the current grid first. It overwrites
every block in the next buffer directly.

## Reference Oracle

The module keeps an independent private oracle,
`infer_next_block_reference(neighborhood)`, for tests.

That oracle counts neighbors directly from the nine source blocks and intentionally does not reuse
the optimized direct-window packing logic. This separation is what allows the moved block helper
and `step_block()` to be checked against code that does not share the same geometry packing.
