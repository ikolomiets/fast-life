# Hilbert Curve Algorithm And Zig Implementation

## Overview

This repository implements the classic iterative 2-dimensional Hilbert curve mapping in Zig. The core algorithm is built from three pieces:

1. `d2xy` converts a Hilbert index `d` into coordinates `(x, y)`
2. `xy2d` converts coordinates `(x, y)` back into the Hilbert index
3. `rot` applies the quadrant-specific rotation or reflection needed to keep the curve continuous

The Zig code lives in:

- `src/root.zig` for the canonical `fast_life` package import
- `src/modules/binary_grid.zig` for the built-in packed 4x4 block type and dense binary-grid API
- `src/modules/hilbert_curve.zig` for the core Hilbert mapping API and inline tests
- `src/modules/hilbert_neighbors.zig` for neighbor-distance analysis and inline tests
- `src/main.zig` for the top-level Game of Life CLI
- `build.zig` for build, run, and test integration

The Hilbert implementation is iterative, allocation-free, and close to the standard reference algorithm. This document focuses on the Hilbert mapping and neighbor-reporting modules. For the separate dense binary-grid design built into the same package root, see `docs/binary_grid_design.md`.

## Geometry Of A 2D Hilbert Curve

For a Hilbert curve of order `k`:

```text
grid size n = 2^k
points      = n^2 = 4^k
```

Example orders:

| Order | Grid size | Points    |
| ----- | --------- | --------- |
| 0     | 1 x 1     | 1         |
| 1     | 2 x 2     | 4         |
| 2     | 4 x 4     | 16        |
| 3     | 8 x 8     | 64        |
| 8     | 256 x 256 | 65,536    |

The curve visits every cell exactly once, and each step moves to a neighboring cell. Conceptually, the order-`k` curve is built from four order-`k-1` sub-curves:

```text
Level k
 ├─ quadrant 0
 ├─ quadrant 1
 ├─ quadrant 2
 └─ quadrant 3
```

Each quadrant contains the same smaller Hilbert pattern, but with an orientation that depends on where that quadrant appears in the larger traversal. That orientation change is the purpose of `rot`.

## Bit Interpretation Of The Hilbert Index

A Hilbert index stores two bits per recursion level:

```text
d = b_(2k-1) b_(2k-2) ... b1 b0
```

Each bit pair identifies a quadrant:

```text
00 -> quadrant 0
01 -> quadrant 1
10 -> quadrant 2
11 -> quadrant 3
```

`d2xy` processes the index from the least significant pair upward. At each scale it extracts two quadrant bits:

```text
rx = bit controlling the x-side of the quadrant
ry = bit controlling the y-side of the quadrant
```

Those bits decide both:

- which sub-square contains the point at the current scale
- how the local coordinate system must be rotated or reflected before the next offset is applied

## Rotation And Reflection

The Hilbert curve only stays continuous if the coordinate system changes orientation in specific quadrants.

### Cases

| rx | ry | action           |
| -- | -- | ---------------- |
| 0  | 0  | rotate 90 deg    |
| 0  | 1  | no rotation      |
| 1  | 0  | rotate + reflect |
| 1  | 1  | no rotation      |

In practice the standard rule collapses to:

```text
if ry == 0:
    if rx == 1:
        reflect
    swap x and y
```

Pseudocode:

```text
procedure ROT(size, x, y, rx, ry)

    if ry == 0 then
        if rx == 1 then
            x <- size - 1 - x
            y <- size - 1 - y
        end if

        swap(x, y)
    end if

    return (x, y)

end procedure
```

Parameter meaning:

```text
size = current quadrant size
x,y  = coordinates inside the current square
rx   = x-direction quadrant bit
ry   = y-direction quadrant bit
```

## `d2xy`: Hilbert Index To Coordinates

`d2xy` starts at `(0, 0)` and expands the point from the smallest square outward to the full grid.

Generic pseudocode:

```text
procedure D2XY(n, d)

    x <- 0
    y <- 0

    t <- d
    size <- 1

    while size < n do

        rx <- (t div 2) AND 1
        ry <- (t XOR rx) AND 1

        (x, y) <- ROT(size, x, y, rx, ry)

        x <- x + size * rx
        y <- y + size * ry

        t <- t div 4
        size <- size * 2

    end while

    return (x, y)

end procedure
```

Step-by-step:

1. Extract the current quadrant bits from the low end of `t`
2. Rotate or reflect the existing local coordinates with `ROT`
3. Offset into the selected quadrant with `x += size * rx` and `y += size * ry`
4. Drop the processed bit pair with `t = t div 4`
5. Double the square size and continue

This takes `O(order)` time and `O(1)` memory.

## `xy2d`: Coordinates To Hilbert Index

`xy2d` performs the inverse mapping by examining the point from the largest scale down to the smallest.

Generic pseudocode:

```text
procedure XY2D(n, x, y)

    d <- 0
    size <- n / 2

    while size > 0 do

        if (x AND size) > 0
            rx <- 1
        else
            rx <- 0
        end if

        if (y AND size) > 0
            ry <- 1
        else
            ry <- 0
        end if

        d <- d + size * size * ((3 * rx) XOR ry)

        (x, y) <- ROT(size, x, y, rx, ry)

        size <- size / 2

    end while

    return d

end procedure
```

The quadrant contribution is encoded with `(3 * rx) XOR ry`, which produces the Hilbert ordering:

| rx | ry | index |
| -- | -- | ----- |
| 0  | 0  | 0     |
| 0  | 1  | 1     |
| 1  | 1  | 2     |
| 1  | 0  | 3     |

Like `d2xy`, this inverse transform runs in `O(order)` time and `O(1)` memory.

## Worked Example: Order 2

For order `2`, the grid is `4 x 4` and the traversal order is:

```text
 0  1 14 15
 3  2 13 12
 4  7  8 11
 5  6  9 10
```

For `d = 5`, `d2xy` processes two levels:

```text
level 0:
rx = 0
ry = 1
-> position inside the first quadrant

level 1:
rx = 1
ry = 0
-> move into the next quadrant with rotation
```

Final result:

```text
(x, y) = (0, 3)
```

The repository tests this exact mapping and the full order-2 table.

## Data Model And Repository Limits

The public coordinate type is:

```zig
pub const Point = struct {
    x: u16,
    y: u16,
};
```

The library also exposes compass directions for neighbor reporting:

```zig
pub const Direction = enum { N, NE, E, SE, S, SW, W, NW };
```

This repository intentionally limits `order` to `0..8`:

- grid size `n = 2^order`
- maximum grid is `256 x 256`
- maximum valid Hilbert index is `65535`

That makes `u16` sufficient for the public `x`, `y`, and `d` values. One implementation detail follows from that limit: the code tracks the inclusive last valid Hilbert index rather than a total point count, because order `8` has `65,536` points, which does not fit in `u16`, while the last valid index `65,535` does.

In the generic algorithm, higher orders work if the integer widths are widened. This repository chooses a tighter public range to keep the API and tests simple.

## Validation And Geometry Helpers

`src/modules/hilbert_curve.zig` validates all public inputs before doing bit manipulation:

- `validate_order(order)` returns `error.InvalidOrder` when `order > 8`
- `validate_index(order, d)` returns `error.IndexOutOfRange` when `d >= 4^order`
- `validate_point(order, point)` returns `error.PointOutOfRange` when either coordinate is outside `[0, 2^order)`

These checks keep failure modes explicit and prevent silent wraparound.

Two small helpers derive grid geometry:

```zig
fn grid_size(order: u8) u16
fn max_index(order: u8) u16
```

`grid_size` computes `1 << order`. `max_index` computes the inclusive last valid Hilbert index:

- for orders `0..7`, `max_index = 4^order - 1`
- for order `8`, `max_index = 65535`

The code also keeps one private geometry helper for debug assertions:

```zig
fn max_index_for_grid_size(n: u16) u16
```

Unchecked helpers assert that `n` is non-zero, a power of two, and consistent with the documented `u16` limits. A small compile-time block also verifies that `max_order = 8` still fits the chosen public integer widths.

The public mapping functions validate once, then delegate into internal unchecked helpers:

- `d2xy_unchecked(n, d)`
- `xy2d_unchecked(n, point)`

That keeps boundary checks at the API edge while avoiding repeated validation in internal loops such as full-curve generation.

## Rotation Implementation In Zig

The abstract algorithm uses one `rot(size, x, y, rx, ry)` transform. The Zig code splits that into two private helpers:

- `rot_unsigned(size: u16, x: *u16, y: *u16, rx: u16, ry: u16)`
- `rot_signed(size: i32, x: *i32, y: *i32, rx: i32, ry: i32)`

Both implement the same logic:

```text
if ry == 0:
    if rx == 1:
        reflect
    swap x and y
```

The split exists because `xy2d` can temporarily produce negative intermediate coordinates during the inverse rotation step. Public inputs and outputs remain non-negative, but signed temporaries avoid overflow traps during reflection and swap. `d2xy` does not need that concession, so it stays fully unsigned.

## Public Mapping APIs

The public `d2xy` entry point is:

```zig
pub fn d2xy(order: u8, d: u16) !Point
```

Implementation flow:

1. Validate `order` and `d`
2. Compute `n = 2^order`
3. Delegate to `d2xy_unchecked(n, d)`
4. Initialize `x = 0`, `y = 0`, `t = d`, and `size = 1`
5. Loop while `size < n`, extracting `rx` and `ry`, rotating, offsetting, and doubling `size`
6. Return the final `Point`

The public `xy2d` entry point is:

```zig
pub fn xy2d(order: u8, point: Point) !u16
```

Implementation flow:

1. Validate `order` and `point`
2. Compute `n = 2^order`
3. Delegate to `xy2d_unchecked(n, point)`
4. Promote `x` and `y` to signed `i32`
5. Start from `size = n / 2`
6. Loop while `size > 0`, deriving `rx` and `ry`, adding the quadrant contribution with `(3 * rx) ^ ry`, rotating, and halving `size`
7. Return `d`

Both mappings stay faithful to the standard iterative algorithm and complete in at most eight iterations in this repository.

## Curve Writer

The canonical `fast_life.hilbert_curve` module also exposes:

```zig
pub fn write_curve(writer: anytype, order: u8) !void
```

This helper:

- validates `order`
- computes `n = 2^order` once
- iterates over all indices from `0` to `max_index(order)`
- calls `d2xy_unchecked(n, d)` for each index
- prints one line per point as `d x y`

Example for order `2`:

```text
0 0 0
1 1 0
2 1 1
3 0 1
...
15 3 0
```

This is the concrete repository form of the generic "generate the whole curve by iterating `d`" pattern.

## Moore-Neighbor Distance Report

The library also exposes:

```zig
pub const NeighborKind = enum { all, orthogonal, diagonal };
pub fn write_neighbor_distances(writer: anytype, order: u8) !void
pub fn write_neighbor_distance_histogram(writer: anytype, order: u8) !void
pub fn write_neighbor_distance_histogram_max_distance(writer: anytype, order: u8, max_distance: u16) !void
pub fn write_neighbor_distance_histogram_filtered(writer: anytype, order: u8, kind: NeighborKind, max_distance: ?u16) !void
```

This report walks the Hilbert curve in index order and prints one line per cell with:

- the current Hilbert index
- the current grid position
- distances to Moore neighbors in fixed compass order: `N NE E SE S SW W NW`

Each distance is the absolute difference between the current cell index and the neighbor cell index along the Hilbert curve. Missing neighbors print `-`.

The histogram writer aggregates those same neighbor-distance values across the full report and prints one `distance=<value> count=<value> percentage=<value>%` line per distinct distance, sorted by ascending distance. The percentage is always the bucket's share of all valid directed neighbor relationships in the full Moore neighborhood, rounded to the nearest hundredth. The filtered variant accepts `kind` and optional `max_distance`, prints only the selected rows, then appends `cumulative_percentage=<value>%` computed from the exact subtotal count of the printed rows.

Example output line:

```text
d=5 pos=(0,3) N=1 NE=8 E=1 SE=- S=- SW=- W=- NW=-
```

Neighbor lookup is handled by a private `neighbor_point(n, point, dir)` helper in `src/modules/hilbert_neighbors.zig`. It computes the candidate adjacent cell from the `Direction` value, rejects out-of-bounds results, and returns `null` for missing border or corner neighbors.

## Command-Line Entry Point

The Hilbert tools keep module-owned standalone entry points in `src/modules/hilbert_curve.zig` and `src/modules/hilbert_neighbors.zig`:

```text
zig run src/modules/hilbert_curve.zig -- 2
zig run src/modules/hilbert_curve.zig -- curve 2
zig run src/modules/hilbert_neighbors.zig -- 2
zig run src/modules/hilbert_neighbors.zig -- histogram 2
zig run src/modules/hilbert_neighbors.zig -- histogram 2 kind orthogonal
zig run src/modules/hilbert_neighbors.zig -- histogram 2 max-distance 4
zig run src/modules/hilbert_neighbors.zig -- histogram 2 kind diagonal max-distance 4
zig run src/modules/hilbert_neighbors.zig -- histogram 2 max-distance 4 kind diagonal
```

Behavior:

- `zig run src/modules/hilbert_curve.zig -- <order>` prints the plain Hilbert traversal
- `zig run src/modules/hilbert_curve.zig -- curve <order>` does the same explicitly
- `zig run src/modules/hilbert_neighbors.zig -- <order>` prints Moore-neighbor distances
- `zig run src/modules/hilbert_neighbors.zig -- histogram <order>` prints the histogram of neighbor distances
- `zig run src/modules/hilbert_neighbors.zig -- histogram <order> kind <all|orthogonal|diagonal>` filters the histogram by neighbor kind and appends a final cumulative percentage row
- `zig run src/modules/hilbert_neighbors.zig -- histogram <order> max-distance <distance>` filters by inclusive distance and appends a final cumulative percentage row
- `kind` and `max-distance` may be combined in either order
- prints usage to stderr on missing, malformed, or extra arguments
- prints usage again when `order > 8`
- writes the selected report to stdout

`src/modules/hilbert_curve.zig` and `src/modules/hilbert_neighbors.zig` both use Zig `0.16.0` process and I/O initialization for their executable entry points:

- `pub fn main(init: std.process.Init) !void`
- `init.minimal.args.toSlice(init.arena.allocator())` for CLI args
- `std.Io.File.stdout().writer(init.io, &buffer)` for buffered curve output
- `std.Io.File.stderr().writer(init.io, &.{})` for short unbuffered usage messages

The top-level executable in `src/main.zig` now targets the Game of Life CLI. Hilbert functionality remains available through these standalone module entry points.

## Performance Characteristics

The classic `rot + d2xy / xy2d` approach has these properties:

| Property        | Value                  |
| --------------- | ---------------------- |
| Time complexity | `O(order)` per point   |
| Memory          | `O(1)`                 |
| Arithmetic      | integer bit operations |
| Branching       | minimal                |

Within this repository's `order <= 8` constraint, each transform completes in at most eight loop iterations.

## Tests

Tests live inline in `src/modules/hilbert_curve.zig`, `src/modules/hilbert_neighbors.zig`, and `src/root.zig` and run with:

```text
zig build test
```

The suite covers:

- the full order-2 traversal table shown in this document
- the specific example `d2xy(2, 5) == Point{ .x = 0, .y = 3 }`
- exhaustive round-trips for every valid point in orders `0..8`
- exact neighbor-distance output for orders `0` and `1`
- exact histogram output for orders `0` and `1`
- exact histogram max-distance output for order `2`
- exact orthogonal and diagonal histogram output for order `1`
- exact combined kind and max-distance histogram output for order `2`
- percentage formatting and rounding behavior
- Moore-neighbor distance checks for every point in orders `0..8`
- histogram total-count validation for every point in orders `0..8`
- orthogonal and diagonal histogram counts partition the full histogram for every order in `0..8`
- bounds checking for generated coordinates
- invalid order, index, and coordinate errors
- exact `write_curve` output for order `2`
- CLI parsing for bare and explicit output modes

These tests validate both the generic Hilbert mapping and the repository's public interface choices.

TigerStyle in this repository uses `snake_case` for functions, variables, and files, while keeping Zig-style type names such as `Point` and `Direction`.

## Build Integration

`build.zig` defines three normal Zig workflows:

- `zig build` to compile the top-level executable
- `zig build run -- <steps> <input-rle-path> <output-rle-path>` to run the Game of Life CLI
- `zig build test` to execute the unit tests

It also defines the canonical `fast_life` package import rooted at `src/root.zig`. The top-level executable is named `fast_life`, and the Hilbert module sources can be run directly as standalone entry points with `zig run src/modules/hilbert_curve.zig -- ...` and `zig run src/modules/hilbert_neighbors.zig -- ...`.

## Summary

This codebase keeps the standard Hilbert mapping algorithm recognizable:

- two bits per level choose the quadrant
- `rot` fixes orientation before each offset or inverse step
- `d2xy` builds outward from small squares
- `xy2d` collapses inward from large squares

The repository then adds a few explicit constraints and conveniences on top:

- public coordinates and indices use `u16`
- supported orders are limited to `0..8`
- `xy2d` uses signed internal rotation to avoid overflow during intermediate steps
- additional helpers generate full traversals and Moore-neighbor distance reports

Within those constraints, the implementation preserves the algorithm's main advantages: direct random access, no recursion, constant memory usage, and exhaustive test coverage.
