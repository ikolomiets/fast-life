# Game Of Life Design

## Overview

This document describes the current `GameOfLife` implementation in this repository.

Relevant code:

- `src/root.zig` re-exports the canonical `fast_life.game_of_life` module
- `src/modules/game_of_life.zig` contains the stateful automaton shell and its inline tests
- `src/main.zig` contains the top-level Game of Life CLI
- `src/modules/binary_grid.zig` provides the packed `BinaryGrid(order)` storage used for both buffers
- `docs/lut_block_inference_design.md` describes the current block-LUT stepping path in detail

The module keeps the state layout intentionally small and explicit, and now implements one full
Conway Life step over the packed `BinaryGrid(order)` storage in two forms:

- `step()` is the original cell-wise baseline
- `step_block()` is the block-wise LUT-based alternative

## Public Type

The public type is a comptime factory:

```zig
pub fn GameOfLife(comptime grid_order: usize) type
```

This matches the repository's existing `BinaryGrid(order)` shape. Grid size stays a compile-time
decision, storage remains inline, and there is no hidden allocation or runtime-sized indirection.

## State Layout

Each instantiated `GameOfLife(order)` value stores:

```zig
generation: u64,
grids: [2]Grid,
```

where `Grid` is:

```zig
const Grid = binary_grid.BinaryGrid(grid_order);
```

The layout is intentionally minimal:

- `generation` selects the active buffer by parity
- `grids[0]` holds generation `0`
- `grids[1]` is the alternate buffer for the next generation

The module encodes the expected field order with compile-time assertions so the layout stays
explicit if the type evolves later.

## Buffer Selection

Current and next grid selection are private helpers based on parity:

```zig
current_index = generation & 1
next_index = current_index ^ 1
```

The important design point is that the implementation uses `[2]Grid` rather than two named fields.
That keeps the representation homogeneous and matches the access pattern that `step()` uses:
choose current once, choose next once, then stream over both grids.

## Initialization

The module exposes three initialization paths:

```zig
pub fn init_empty(self: *Self) void
pub fn init_generation_zero_grid(self: *Self) *Grid
pub fn init_from_grid(self: *Self, initial: *const Grid) void
```

Behavior:

- `init_empty()` resets `generation` to `0` and clears both buffers
- `init_generation_zero_grid()` performs the same reset and returns `&grids[0]`
- `init_from_grid()` resets to generation `0`, copies the caller's grid into `grids[0]`, and
  clears `grids[1]`

`init_generation_zero_grid()` exists to support external initialization code directly. A caller can
reset the automaton, obtain the generation-zero grid pointer, and pass that pointer to another
helper that seeds cells, applies an RLE pattern, or performs some other setup step.

## Public Surface

The initial public methods are:

```zig
pub fn init_runtime_luts() void
pub fn clear(self: *Self) void
pub fn current_grid(self: *const Self) *const Grid
pub fn current_grid_mut(self: *Self) *Grid
pub fn step(self: *Self) void
pub fn step_block(self: *Self) void
```

`clear()` is the reset alias for `init_empty()`. The two current-grid accessors expose the buffer
selected by generation parity.

The module also exposes the public block helper used by `step_block()`:

```zig
pub const BlockNeighborhood = struct { ... };
pub fn infer_next_block_from_neighborhood(
    neighborhood: BlockNeighborhood,
) binary_grid.Block
```

`init_runtime_luts()` eagerly builds the runtime `4 x 4 -> inner 2 x 2` LUT used by both
`infer_next_block_from_neighborhood(...)` and `step_block()`. It is idempotent, but it must be
called before either block-LUT entry point is used.

The module also exposes two public rule helpers plus a transition enum:

```zig
pub const Transition = enum { no_change, birth, death };
pub fn next_state(current_state: bool, alive_neighbors: u4) bool
pub fn next_transition(current_state: bool, alive_neighbors: u4) Transition
```

`next_state()` is the canonical boolean encoding of Conway Life's per-cell rule. `next_transition()`
wraps that result and classifies it as no change, birth, or death.

`step()` performs one full Conway Life generation update with the original cell-wise algorithm.

Its internal strategy is:

1. select the current and next buffers from generation parity
2. copy the current grid into the next grid
3. scan every cell in the current grid
4. count the wrapped live neighbors for that cell
5. compute the transition with `next_transition(...)`
6. patch only the changed cells in the next grid
7. increment `generation`

The copy-first approach keeps the control flow simple: unchanged cells are already correct in the
next buffer, so the scan only needs to write births and deaths. Neighbor reads always come from the
current buffer, so each step observes a stable source generation.

`step_block()` performs the same generation update block-by-block instead:

1. verify that `init_runtime_luts()` has already run
2. select current and next buffers from generation parity
3. iterate over every source block
4. gather the wrapped `3 x 3` `BlockNeighborhood` around that block
5. compute the next-state block with `infer_next_block_from_neighborhood(...)`
6. write the returned block directly into the next buffer
7. increment `generation`

`step_block()` does not copy the current grid first because it overwrites every block in the next
buffer directly.

`BinaryGrid` uses a closed-world topology, so both stepping paths wrap across every edge. There is
no special dead boundary.

The detailed LUT/block algorithm behind `infer_next_block_from_neighborhood(...)` and
`step_block()` is documented in [lut_block_inference_design.md](lut_block_inference_design.md).

## Top-Level CLI

The top-level executable entry point lives in `src/main.zig`:

```text
zig build run -- <steps> <input-rle-path> <output-rle-path>
```

The current CLI uses a fixed `GameOfLife(8)` instance. Its flow is:

1. parse the steps argument as an unsigned integer
2. parse the input file with `life_rle.parse_pattern_file(...)`
3. reject declared pattern bounds larger than `1024 x 1024`
4. call `game_of_life.init_runtime_luts()` once at process startup
5. initialize generation `0` with `init_generation_zero_grid()`
6. apply the parsed pattern at coordinate `(400, 400)` with `life_rle.apply_pattern(...)`
7. run `step_block()` exactly the requested number of times
8. write `current_grid()` back out as canonical RLE with `life_rle.write_grid(...)`
9. print a timing summary to stdout

The timing covers only the stepping loop. It starts immediately before the first `step_block()`
call and ends immediately after the last one. Input parsing, runtime LUT initialization, initial
pattern application, final file output, and stdout reporting are not part of the measured interval.

The stdout format is:

```text
time_s=<seconds.microseconds> generations_per_second=<rounded_integer>
```

For `0` steps, the CLI reports:

```text
time_s=0.000000 generations_per_second=0
```

The implementation uses `std.Io.Clock.awake`, which is a monotonic portable timer. On macOS this
maps to `CLOCK_UPTIME_RAW`.

`src/modules/game_of_life.zig` itself remains library-only. It no longer owns file parsing, file
writing, usage text, process initialization, or timing-report output.
