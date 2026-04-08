# Binary Grid Design

## Overview

This document describes the dense binary-grid library implemented in this repository.

Relevant code:

- `src/root.zig` re-exports the canonical `fast_life.grid` module and the Hilbert modules
- `src/modules/binary_grid.zig` contains the built-in `Block`, the dense `BinaryGrid` type, and their inline tests

The design targets data-oriented binary grids built from a fixed packed `4 x 4` block representation. The block implementation and grid API live together in one module, so there is no separate block abstraction layer.

## Grid Geometry

The public grid type is:

```zig
pub fn BinaryGrid(comptime grid_order: usize) type
```

`grid_order` is the exponent parameter, not the side length itself:

```text
blocks_per_side = 2^grid_order
block_count     = 2^(2 * grid_order)
cells_per_side  = 2^(grid_order + 2)
cell_count      = 2^(2 * grid_order + 4)
```

This implementation caps `grid_order` at `12`.

Examples:

| `order` | Block grid | Blocks | Cell grid |
| ------- | ---------- | ------ | --------- |
| `0`     | `1 x 1`    | `1`    | `4 x 4`   |
| `1`     | `2 x 2`    | `4`    | `8 x 8`   |
| `2`     | `4 x 4`    | `16`   | `16 x 16` |
| `3`     | `8 x 8`    | `64`   | `32 x 32` |

The grid stores blocks densely in one contiguous array:

```zig
blocks: [block_count]Block
```

This is a fixed-size inline layout. The storage for all blocks is part of the grid value itself.

## Memory Ownership And Allocation

`BinaryGrid(order)` returns a type at compile time. That type contains this field directly:

```zig
blocks: [block_count]Block
```

The important consequence is:

- the grid does not allocate a hidden buffer somewhere else
- the grid value itself contains the whole block array

A good beginner mental model is:

```text
BinaryGrid is not a handle to storage.
BinaryGrid is the storage.
```

That is what this document means when it says the design is "allocation-free" or "heap-allocation-free inside the grid API". `BinaryGrid`, `initEmpty`, `initFilled`, `clear`, and `fill` do not call an allocator. They only construct or overwrite memory that already exists.

### Terminology

These terms are easy to mix up, so the distinction matters:

- fixed-size or statically sized: the size is known at compile time
- stack storage: memory used for a local variable inside a function
- static storage: memory reserved for a top-level or program-lifetime value
- heap allocation: memory requested from an allocator at runtime

In this design, "static memory allocation" mainly means the grid has a fixed-size layout known at compile time. It does not mean every grid must live in global memory.

### When Memory Actually Appears

Memory for the blocks appears when the caller creates or places a `BinaryGrid` value.

Local variable example:

```zig
const Grid = fast_life.grid.BinaryGrid(2);
var grid = Grid.initEmpty();
```

`grid` contains the entire block array directly. In practice, that memory usually lives in the current function's local storage. No heap allocation happens here.

Top-level storage example:

```zig
const Grid = fast_life.grid.BinaryGrid(2);
const global_grid = Grid.initEmpty();
```

Here the full block array is reserved in static program storage, because the value itself is defined at top level and has program lifetime.

Heap-owned example:

```zig
const Grid = fast_life.grid.BinaryGrid(2);
const grid_ptr = try allocator.create(Grid);
grid_ptr.* = Grid.initEmpty();
```

The heap allocation happens at `allocator.create(Grid)`. `Grid.initEmpty()` still does not allocate. It only fills the already-allocated `Grid` value.

### Why Choose Fixed Inline Storage

This is an intentional design choice, not an accident of the implementation.

- the total memory cost is predictable from `order`
- all blocks are contiguous in memory, which improves cache locality
- the grid API does not depend on an allocator, which keeps call sites simpler
- initialization has fewer runtime failure paths because there is no internal memory request to fail

For data-oriented code, this matters because predictable layout and contiguous storage usually make scanning, updating, and reasoning about performance easier.

### Tradeoffs

Fixed inline storage also has costs:

- the grid size is fixed by `order`; resizing is not part of this design
- very large local grids can use a lot of stack space if created as local variables
- copying a `BinaryGrid` copies the full inline block array
- if a caller wants heap ownership, they must explicitly allocate an outer `Grid` value themselves

So the design is best read as: no internal heap allocation, caller-controlled placement.

## Block Indexing

Blocks use plain row-major linear indexing:

```text
index = (y << order) | x
```

For `order = 2`, the block grid is `4 x 4`, so:

```text
(0, 0) -> 0
(3, 0) -> 3
(0, 1) -> 4
(1, 2) -> 9
```

The inverse mapping is:

```text
x = index & (blocks_per_side - 1)
y = index >> order
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

That means the boundary between adjacent blocks appears every four cells. For `order = 2`:

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

## `Block`

The built-in block implementation is:

```zig
pub const Block = struct {
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
pub fn init(fill: bool) Block
pub fn get(self: Block, x: u2, y: u2) bool
pub fn set(self: *Block, x: u2, y: u2, value: bool) void
pub fn rowMask(self: Block, y: u2) u4
pub fn count(self: Block) u5
pub fn any(self: Block) bool
pub fn all(self: Block) bool
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

## Grid API

`BinaryGrid` exposes these public constants:

```zig
pub const order: usize
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

## Coupled Grid And Block Design

`BinaryGrid` always stores the built-in `Block` type. That keeps the `4 x 4` packed layout explicit and removes the extra comptime validation layer that would otherwise be needed to accept arbitrary block implementations.

## Limits And Design Choices

This implementation intentionally chooses a narrow v1 design:

- dense storage only
- compile-time `order`
- single built-in `Block` type
- fixed block side of `4`
- no CLI surface
- no serialization or external wire format layer
- no sparse indirection, compression, or allocator-managed backing store

The compile-time `grid_order` is capped at `12`. Larger values fail during type construction at comptime.

## Performance Characteristics

The main performance properties are:

| Property | Choice |
| -------- | ------ |
| Block type | built-in `Block` backed by `u16` for 16 binary cells |
| Grid layout | one contiguous `[block_count]Block` array |
| Access math | shifts and masks |
| Allocation | no internal heap allocation; caller chooses placement |
| Validation | checked APIs at the boundary, unchecked APIs for hot paths |
| Dispatch | direct calls on a concrete block type |

This is a data-oriented design:

- block-level scans walk contiguous memory
- row slices avoid per-access coordinate reconstruction
- in-block cell operations stay branch-light and scalar
- the public API separates safe boundary checks from unchecked inner-loop access

## Tests

The inline tests in `src/modules/binary_grid.zig` and `src/root.zig` cover:

- empty and filled block initialization
- per-cell block reads and writes
- row-mask extraction and population counts
- derived grid sizes from `order`
- exact row-major block index and coordinate mappings
- shared storage access through block index and block coordinates
- filled-grid writes using the built-in block storage
- cell writes that cross block boundaries
- out-of-range error handling for block and cell APIs

Run the suite with:

```text
zig build test
```

## Summary

The binary-grid library combines two concrete pieces:

- `Block` provides a compact 16-cell binary block
- `BinaryGrid(order)` provides a dense block grid with row-major indexing and direct cell translation

Together they provide a fast, fixed-size, cache-friendly foundation for binary-grid algorithms without a separate block abstraction layer.
