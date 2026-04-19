# Binary Grid Design

## Overview

This document describes the dense binary-grid library implemented in this repository.

Relevant code:

- `src/root.zig` re-exports the canonical `fast_life.binary_grid` module and the Hilbert modules
- `src/modules/binary_grid.zig` contains the built-in `Block`, the dense `BinaryGrid` type, and their inline tests

The design targets data-oriented binary grids built from a fixed packed `4 x 4` block representation. The block implementation and grid API live together in one module, so there is no separate block abstraction layer.

## TigerStyle Alignment

The current module reflects the repository's TigerStyle rules in a few explicit ways:

- public methods use `snake_case`, even though `BinaryGrid(...)` remains a PascalCase type factory
- function and module names use `snake_case`, while type names still follow Zig conventions such as `Block` and `CellCoord`
- initialization is in-place with `init_empty()` and `init_filled()` so callers do not copy large grid values by return
- checked APIs return explicit errors at the boundary, while unchecked APIs use `std.debug.assert` for hot-path preconditions
- the API favors explicit mutable receivers over `anytype` tricks that change return types based on constness
- comments explain why the grid is capped at order `8` and why each block stays a packed `u16`
- compile-time invariants protect the fixed `4 x 4` block layout

This document describes the post-refactor API and design. It intentionally does not preserve the older camelCase API that existed before the TigerStyle cleanup.

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

This implementation caps `grid_order` at `8`.

At the cap, the grid contains `256 x 256` blocks, exposes a `1024 x 1024` cell space, and stores `128 KiB` of packed block data inline.

Examples:

| `order` | Block grid | Blocks | Cell grid |
| ------- | ---------- | ------ | --------- |
| `0`     | `1 x 1`    | `1`    | `4 x 4`   |
| `1`     | `2 x 2`    | `4`    | `8 x 8`   |
| `2`     | `4 x 4`    | `16`   | `16 x 16` |
| `3`     | `8 x 8`    | `64`   | `32 x 32` |
| `8`     | `256 x 256`| `65536`| `1024 x 1024` |

The grid stores blocks densely in one contiguous array:

```zig
blocks: [block_count]Block
```

This is a fixed-size inline layout. The storage for all blocks is part of the grid value itself.

## Memory Ownership And Placement

`BinaryGrid(order)` returns a type at compile time. That type contains the full block array directly:

```zig
blocks: [block_count]Block
```

The important consequence is:

- the grid does not allocate a hidden backing buffer
- the grid value itself contains the whole block array

A good mental model is:

```text
BinaryGrid is not a handle to storage.
BinaryGrid is the storage.
```

That is what this document means by "allocation-free" or "heap-allocation-free inside the grid API". `init_empty`, `init_filled`, `clear`, and `fill` only construct or overwrite memory that already exists.

### When Memory Actually Appears

Memory for the blocks appears when the caller creates or places a `BinaryGrid` value.

Local variable example:

```zig
const Grid = fast_life.binary_grid.BinaryGrid(2);
var grid: Grid = undefined;
grid.init_empty();
```

`grid` contains the entire block array directly. In practice, that memory usually lives in the current function's local storage. No heap allocation happens here.

Top-level storage example:

```zig
const Grid = fast_life.binary_grid.BinaryGrid(2);
var global_grid: Grid = undefined;

pub fn initializeGlobalGrid() void {
    global_grid.init_empty();
}
```

Here the full block array is reserved in static program storage because the value itself is defined at top level. Initialization still happens explicitly through a mutable method.

Heap-owned example:

```zig
const Grid = fast_life.binary_grid.BinaryGrid(2);
const grid_ptr = try allocator.create(Grid);
errdefer allocator.destroy(grid_ptr);

grid_ptr.init_empty();
```

The heap allocation happens at `allocator.create(Grid)`. `init_empty()` still does not allocate. It only fills the already-allocated `Grid` value.

### Why In-Place Initialization

The older by-value constructors were removed during the TigerStyle cleanup.

- returning a fixed-size grid by value invites large accidental copies
- in-place initialization keeps ownership and mutation explicit
- the call shape makes it obvious that the caller already owns the storage

This is especially important near the order cap, where a grid value is still large enough that silent copies are a poor default.

## `Block`

The built-in block implementation is:

```zig
pub const Block = struct {
    bits: u16,
    pub const side: usize = 4;
    pub const side_shift: u2 = 2;
    pub const LocalCoord = u2;
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
pub fn empty() Block
pub fn filled() Block
pub fn get(self: Block, x: Block.LocalCoord, y: Block.LocalCoord) bool
pub fn set(self: *Block, x: Block.LocalCoord, y: Block.LocalCoord, value: bool) void
pub fn row_mask(self: Block, y: Block.LocalCoord) u4
pub fn count(self: Block) u5
pub fn any(self: Block) bool
pub fn all(self: Block) bool
```

Behavior:

- `empty()` clears all bits
- `filled()` sets all 16 bits
- `get()` tests one cell bit
- `set()` uses explicit `if` branches to set or clear one bit
- `row_mask()` returns one 4-bit row packed into `u4`
- `count()` uses `@popCount`
- `any()` and `all()` provide fast aggregate checks

Worked example:

```text
set (0,0), (2,1), (3,3)
row 0 mask = 0001
row 1 mask = 0100
row 2 mask = 0000
row 3 mask = 1000
count      = 3
```

The implementation deliberately avoids `[4][4]bool` and Zig packed-struct bitfields in the hot path. A single `u16` gives tighter storage and direct bitwise control.

### Block Invariants

The module guards the packed layout with compile-time checks:

```zig
comptime {
    if (Block.side != (@as(usize, 1) << Block.side_shift)) {
        @compileError("Block.side must match Block.side_shift");
    }
    if (Block.side != 4) {
        @compileError("Block.side must remain 4 to preserve the packed 16-bit storage layout");
    }
}
```

These invariants are part of the design, not just defensive decoration. The global-cell split logic and the block bit layout both depend on them.

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
pub fn block_index(coord: BlockCoord) error{BlockCoordOutOfRange}!usize
pub fn block_index_unchecked(coord: BlockCoord) usize
pub fn block_coord(index: usize) error{IndexOutOfRange}!BlockCoord
pub fn block_coord_unchecked(index: usize) BlockCoord
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
pub fn get_cell(self: *const Self, coord: CellCoord) error{CellCoordOutOfRange}!bool
pub fn get_cell_unchecked(self: *const Self, coord: CellCoord) bool
pub fn set_cell(self: *Self, coord: CellCoord, value: bool) error{CellCoordOutOfRange}!void
pub fn set_cell_unchecked(self: *Self, coord: CellCoord, value: bool) void
```

The checked forms validate against `cells_per_side`. The unchecked forms go straight to block lookup and in-block bit access.

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
pub fn init_empty(self: *Self) void
pub fn init_filled(self: *Self) void
pub fn clear(self: *Self) void
pub fn fill(self: *Self) void
```

Block-level access:

```zig
pub fn get_block(self: *const Self, index: usize) error{IndexOutOfRange}!Block
pub fn get_block_unchecked(self: *const Self, index: usize) Block
pub fn set_block(self: *Self, index: usize, value: Block) error{IndexOutOfRange}!void
pub fn set_block_unchecked(self: *Self, index: usize, value: Block) void
pub fn block_ptr(self: *Self, index: usize) error{IndexOutOfRange}!*Block
pub fn block_ptr_unchecked(self: *Self, index: usize) *Block
pub fn block_ptr_at(self: *Self, coord: BlockCoord) error{BlockCoordOutOfRange}!*Block
pub fn block_ptr_at_unchecked(self: *Self, coord: BlockCoord) *Block
pub fn row_blocks(self: *Self, block_y: usize) error{BlockCoordOutOfRange}![]Block
pub fn row_blocks_unchecked(self: *Self, block_y: usize) []Block
```

The pointer and row helpers are intentionally explicit and mutable-only. The module no longer uses `anytype` receivers or paired const-return-shape tricks here. That change keeps the API simpler and makes ownership and mutation visible at the call site.

These APIs exist to support data-oriented scans:

- `row_blocks()` exposes one contiguous block row without recomputing per-block translations
- `block_ptr()` and `block_ptr_at()` let callers mutate blocks in place instead of copying them out and writing them back
- `get_block()` and `set_block()` keep checked whole-block reads and writes available when pointer access is not needed

## Coupled Grid And Block Design

`BinaryGrid` always stores the built-in `Block` type. That keeps the `4 x 4` packed layout explicit and removes the extra comptime validation layer that would otherwise be needed to accept arbitrary block implementations.

The type factory also keeps a few compile-time invariants inside each instantiated grid type:

```zig
comptime {
    if (blocks_per_side == 0) {
        @compileError("BinaryGrid requires at least one block per side");
    }
    if (block_side != (@as(usize, 1) << block_side_shift)) {
        @compileError("BinaryGrid block shift must match Block.side");
    }
}
```

These checks document the assumptions behind row-major indexing and cell splitting.

## Limits And Design Choices

This implementation intentionally chooses a narrow v1 design:

- dense storage only
- compile-time `order`
- single built-in `Block` type
- fixed block side of `4`
- no CLI surface
- no serialization or external wire format layer
- no sparse indirection, compression, or allocator-managed backing store

The compile-time `grid_order` is capped at `8`. Larger values fail during type construction at comptime.

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
- in-block cell operations stay scalar and explicit
- the public API separates safe boundary checks from unchecked inner-loop access

## Tests

The inline tests in `src/modules/binary_grid.zig` and `src/root.zig` cover:

- empty and filled block construction
- per-cell block reads and writes
- `row_mask()` extraction and population counts
- derived grid sizes from `order`, including the order-8 cap
- exact row-major block index and coordinate mappings
- shared storage access through block index and block coordinates
- mutable row access through `row_blocks()`
- explicit in-place initialization, clearing, and refilling
- cell writes that cross block boundaries
- last valid block and cell coordinates
- out-of-range error handling for block and cell APIs

Run the suite with:

```text
zig build test
```

## Summary

The binary-grid library combines two concrete pieces:

- `Block` provides a compact 16-cell packed binary block
- `BinaryGrid(order)` provides a dense block grid with row-major indexing and direct cell translation

Together they provide a fast, fixed-size, cache-friendly foundation for binary-grid algorithms without a separate block abstraction layer. The current API also reflects the repository's TigerStyle direction: explicit naming, explicit mutation, explicit invariants, and explicit checked versus unchecked boundaries.
