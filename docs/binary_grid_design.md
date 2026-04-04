# Binary Grid Design

## Overview

This document describes the dense binary-grid library implemented in this repository.

Relevant code:

- `src/root.zig` re-exports the canonical `fast_life.block` and `fast_life.grid` modules
- `src/modules/block.zig` contains the packed 4x4 block type
- `src/modules/grid.zig` contains the generic dense grid type and its inline tests

The design targets data-oriented binary grids built from fixed-size `4 x 4` blocks. The grid is generic over the block representation, but the repository provides one high-performance packed implementation, `PackedBlock4x4`, as the canonical default.

## Grid Geometry

The public grid type is:

```zig
pub fn BinaryGrid(comptime Order: usize, comptime Block: type) type
```

`Order` is the exponent, not the side length itself:

```text
blocks_per_side = 2^Order
block_count     = 2^(2 * Order)
cells_per_side  = 2^(Order + 2)
cell_count      = 2^(2 * Order + 4)
```

Examples:

| `Order` | Block grid | Blocks | Cell grid |
| ------- | ---------- | ------ | --------- |
| `0`     | `1 x 1`    | `1`    | `4 x 4`   |
| `1`     | `2 x 2`    | `4`    | `8 x 8`   |
| `2`     | `4 x 4`    | `16`   | `16 x 16` |
| `3`     | `8 x 8`    | `64`   | `32 x 32` |

The grid stores blocks densely in one contiguous array:

```zig
blocks: [block_count]Block
```

This is an inline-owned, allocation-free layout. Callers decide whether the grid value itself lives on the stack, in static storage, or inside a larger owner type.

## Block Indexing

Blocks use plain row-major linear indexing:

```text
index = (y << Order) | x
```

For `Order = 2`, the block grid is `4 x 4`, so:

```text
(0, 0) -> 0
(3, 0) -> 3
(0, 1) -> 4
(1, 2) -> 9
```

The inverse mapping is:

```text
x = index & (blocks_per_side - 1)
y = index >> Order
```

This works because `blocks_per_side` is always a power of two.

The public coordinate helpers are:

```zig
pub const BlockCoord = struct {
    x: usize,
    y: usize,
};

pub const CellCoord = struct {
    x: usize,
    y: usize,
};
```

`BinaryGrid` exposes checked and unchecked translation helpers:

```zig
pub fn blockIndex(coord: BlockCoord) error{BlockCoordOutOfRange}!usize
pub fn blockIndexUnchecked(coord: BlockCoord) usize
pub fn blockCoord(index: usize) error{IndexOutOfRange}!BlockCoord
pub fn blockCoordUnchecked(index: usize) BlockCoord
```

The checked forms return explicit errors. The unchecked forms use `std.debug.assert` and are intended for hot paths where the caller already knows the inputs are valid.

## Global Cell Mapping

Each block represents a fixed `4 x 4` cell matrix, so a global cell coordinate is split into:

- block coordinates by shifting right two bits
- local in-block coordinates by masking with `3`

Conceptually:

```text
block_x = cell_x >> 2
block_y = cell_y >> 2
local_x = cell_x & 3
local_y = cell_y & 3
```

That means the boundary between adjacent blocks appears every four cells. For `Order = 2`:

```text
(3, 3) -> block (0, 0), local (3, 3)
(4, 3) -> block (1, 0), local (0, 3)
(3, 4) -> block (0, 1), local (3, 0)
(4, 4) -> block (1, 1), local (0, 0)
```

The public cell accessors are:

```zig
pub fn getCell(self: *const Self, coord: CellCoord) error{CellCoordOutOfRange}!bool
pub fn getCellUnchecked(self: *const Self, coord: CellCoord) bool
pub fn setCell(self: *Self, coord: CellCoord, value: bool) error{CellCoordOutOfRange}!void
pub fn setCellUnchecked(self: *Self, coord: CellCoord, value: bool) void
```

The checked forms validate against `cells_per_side`. The unchecked forms go straight to block lookup and in-block bit access.

## `PackedBlock4x4`

The canonical block implementation is:

```zig
pub const PackedBlock4x4 = struct {
    bits: u16,
    pub const side: usize = 4;
};
```

It stores all 16 binary cells in one `u16`.

### Bit Layout

The bit numbering is row-major:

```text
bit_index = y * 4 + x
```

with `(0, 0)` stored in the least-significant bit.

Visualized:

```text
row 0: bits  0  1  2  3
row 1: bits  4  5  6  7
row 2: bits  8  9 10 11
row 3: bits 12 13 14 15
```

The public API is:

```zig
pub fn init(fill: bool) PackedBlock4x4
pub fn get(self: PackedBlock4x4, x: u2, y: u2) bool
pub fn set(self: *PackedBlock4x4, x: u2, y: u2, value: bool) void
pub fn rowMask(self: PackedBlock4x4, y: u2) u4
pub fn count(self: PackedBlock4x4) u5
pub fn any(self: PackedBlock4x4) bool
pub fn all(self: PackedBlock4x4) bool
```

Behavior:

- `init(false)` clears all bits
- `init(true)` fills all 16 bits
- `get` tests one cell bit
- `set` updates one cell bit with a branch-light mask operation
- `rowMask` returns one 4-bit row packed into `u4`
- `count` uses `@popCount`
- `any` and `all` provide fast aggregate checks

Worked example:

```text
set (0,0), (2,1), (3,3)
row 0 mask = 0001
row 1 mask = 0100
row 2 mask = 0000
row 3 mask = 1000
count      = 3
```

The implementation deliberately avoids `[4][4]bool` and Zig packed-struct bitfields in the hot path. A single `u16` gives tighter storage and more direct bitwise control.

## Generic Grid API

`BinaryGrid` exposes these public constants:

```zig
pub const order: usize
pub const block_type: type
pub const block_side: usize
pub const blocks_per_side: usize
pub const block_count: usize
pub const cells_per_side: usize
pub const cell_count: usize
```

Initialization and bulk operations:

```zig
pub fn initEmpty() Self
pub fn initFilled() Self
pub fn clear(self: *Self) void
pub fn fill(self: *Self) void
```

Block-level access:

```zig
pub fn getBlock(self: *const Self, index: usize) error{IndexOutOfRange}!Block
pub fn getBlockUnchecked(self: *const Self, index: usize) Block
pub fn setBlock(self: *Self, index: usize, value: Block) error{IndexOutOfRange}!void
pub fn setBlockUnchecked(self: *Self, index: usize, value: Block) void
pub fn blockPtr(self: anytype, index: usize) error{IndexOutOfRange}!*Block
pub fn blockPtrUnchecked(self: anytype, index: usize) *Block
pub fn blockPtrAt(self: anytype, coord: BlockCoord) error{BlockCoordOutOfRange}!*Block
pub fn blockPtrAtUnchecked(self: anytype, coord: BlockCoord) *Block
```

For `const` receivers, the pointer-returning functions return `*const Block` instead.

Contiguous views:

```zig
pub fn asSlice(self: *Self) []Block
pub fn asConstSlice(self: *const Self) []const Block
pub fn rowBlocks(self: anytype, block_y: usize) error{BlockCoordOutOfRange}![]Block
pub fn rowBlocksUnchecked(self: anytype, block_y: usize) []Block
```

Again, the slice-returning row helpers become `[]const Block` for `const` receivers.

These APIs exist to support data-oriented scans:

- `asSlice` exposes the full contiguous block storage
- `rowBlocks` exposes one contiguous block row without recomputing per-block translations
- `blockPtr` and `blockPtrAt` let callers mutate blocks in place instead of copying them out and writing them back

## Custom Block Contract

`BinaryGrid` is generic over `Block`, but it only accepts block types that satisfy a small comptime-checked contract:

```zig
pub const side: usize = 4;
pub fn init(fill: bool) Self
pub fn get(self: Self, x: u2, y: u2) bool
pub fn set(self: *Self, x: u2, y: u2, value: bool) void
```

The grid does not know or care how a custom block stores its data. It only relies on those four interface points.

The test module in `src/modules/grid.zig` includes a simple `MatrixBlock4x4` backed by `[4][4]bool` to verify that `BinaryGrid` is decoupled from the packed `u16` representation.

## Limits And Design Choices

This implementation intentionally chooses a narrow v1 design:

- dense storage only
- compile-time `Order`
- fixed block side of `4`
- no CLI surface
- no serialization or external wire format layer
- no sparse indirection, compression, or allocator-managed backing store

The compile-time `Order` must still fit the `usize` shift width. If `Order` is too large to compute `1 << Order` safely for the target architecture, the type construction fails at comptime.

## Performance Characteristics

The main performance properties are:

| Property | Choice |
| -------- | ------ |
| Block layout | `u16` for 16 binary cells |
| Grid layout | one contiguous `[block_count]Block` array |
| Access math | shifts and masks |
| Allocation | none inside block or grid |
| Validation | checked APIs at the boundary, unchecked APIs for hot paths |
| Genericity | comptime block interface, no runtime virtual dispatch |

This is a data-oriented design:

- block-level scans walk contiguous memory
- row slices avoid per-access coordinate reconstruction
- in-block cell operations stay branch-light and scalar
- the public API separates safe boundary checks from unchecked inner-loop access

## Tests

The inline tests in `src/modules/block.zig`, `src/modules/grid.zig`, and `src/root.zig` cover:

- empty and filled block initialization
- per-cell block reads and writes
- row-mask extraction and population counts
- derived grid sizes from `Order`
- exact row-major block index and coordinate mappings
- shared storage access through block index and block coordinates
- cell writes that cross block boundaries
- use of `BinaryGrid` with a non-packed test block type
- out-of-range error handling for block and cell APIs

Run the suite with:

```text
zig build test
```

## Summary

The binary-grid library combines two small abstractions:

- `PackedBlock4x4` provides a compact 16-cell binary block
- `BinaryGrid(Order, Block)` provides a dense block grid with row-major indexing and direct cell translation

Together they provide a fast, allocation-free, cache-friendly foundation for binary-grid algorithms while keeping the grid API independent from the block storage format.
