# Hilbert Curve Zig Implementation

## Overview

This repository implements the classic iterative Hilbert curve algorithm described in [`hilbert_curve_rot_d2xy_xy2d_algorithm.md`](./hilbert_curve_rot_d2xy_xy2d_algorithm.md) in Zig. The Zig code lives in:

- `src/hilbert.zig` for the reusable library API and unit tests
- `src/main.zig` for the command-line entry point
- `build.zig` for build, run, and test integration

The implementation keeps the original algorithm shape:

1. `d2xy` converts a Hilbert index to `(x, y)`
2. `xy2d` converts `(x, y)` back to the Hilbert index
3. `rot` performs the orientation correction at each scale

The code is intentionally iterative, branch-light, and allocation-free.

## Data Model And Limits

The public coordinate type is:

```zig
pub const Point = struct {
    x: u16,
    y: u16,
};
```

The repository limits `order` to `0..8`:

- grid size `n = 2^order`
- maximum grid is `256 x 256`
- maximum valid Hilbert index is `65535`

This makes `u16` sufficient for public `x`, `y`, and `d`.

The library also exposes the 8 compass directions as:

```zig
pub const Direction = enum { N, NE, E, SE, S, SW, W, NW };
```

One internal detail matters: the implementation does not track “total points” as a numeric count. For order `8`, the total would be `65536`, which does not fit in `u16`. Instead, the code tracks the inclusive maximum valid Hilbert index, which is `65535` and does fit in `u16`.

## Validation Helpers

`src/hilbert.zig` validates inputs before doing any bit manipulation:

- `validateOrder(order)` returns `error.InvalidOrder` when `order > 8`
- `validateIndex(order, d)` returns `error.IndexOutOfRange` when `d >= 4^order`
- `validatePoint(order, point)` returns `error.PointOutOfRange` when either coordinate is outside `[0, 2^order)`

These checks keep failure modes explicit and prevent silent wraparound.

## Grid And Count Helpers

Two small helpers derive the geometry:

```zig
fn gridSize(order: u8) u16
fn maxIndex(order: u8) u16
```

`gridSize` computes `1 << order`. `maxIndex` computes the inclusive last valid Hilbert index for the order:

- for orders `0..7`, `maxIndex = 4^order - 1`
- for order `8`, `maxIndex = 65535`

This lets the implementation keep all index math in `u16` without inventing a wider count type just for loop bounds.

## Rotation Implementation

The reference algorithm uses a single `rot(size, x, y, rx, ry)` transformation. The Zig implementation splits it into two internal helpers:

- `rotUnsigned(size: u16, x: *u16, y: *u16, rx: u16, ry: u16)`
- `rotSigned(size: i32, x: *i32, y: *i32, rx: i32, ry: i32)`

Both implement the same logic:

```text
if ry == 0:
    if rx == 1:
        reflect
    swap x and y
```

The split exists because `xy2d` can temporarily produce negative intermediate coordinates during the inverse rotation step. Public inputs and outputs remain non-negative, but using signed temporaries avoids overflow traps during reflection and swap. `d2xy` does not need that concession, so it stays fully unsigned.

The public transform functions also delegate into private unchecked helpers:

- `d2xyUnchecked(n, d)`
- `xy2dUnchecked(n, point)`

That keeps validation at the public boundary while allowing internal loops such as curve generation to avoid re-validating each point.

## `d2xy(order, d)`

`d2xy` starts from `(0, 0)` and expands outward from the smallest square:

```zig
pub fn d2xy(order: u8, d: u16) !Point
```

Implementation flow:

1. Validate `order` and `d`
2. Compute `n = 2^order`
3. Delegate to `d2xyUnchecked(n, d)`
4. In the unchecked helper, set `x = 0`, `y = 0`, `t = d`, and `size = 1`
4. While `size < n`:
   - `rx = (t >> 1) & 1`
   - `ry = (t ^ rx) & 1`
   - rotate with `rotUnsigned`
   - move into the selected quadrant with `x += size * rx` and `y += size * ry`
   - shift `t >>= 2`
   - double `size`
5. Return the final `Point`

This matches the algorithm note directly and runs in `O(order)` time with `O(1)` memory.

## `xy2d(order, point)`

`xy2d` walks from the largest scale down to the smallest:

```zig
pub fn xy2d(order: u8, point: Point) !u16
```

Implementation flow:

1. Validate `order` and `point`
2. Compute `n = 2^order`
3. Delegate to `xy2dUnchecked(n, point)`
4. In the unchecked helper, promote `x` and `y` to signed `i32`
5. Start with `size = n / 2`
5. While `size > 0`:
   - detect the current quadrant bits with `(x & size)` and `(y & size)`
   - compute the quadrant contribution with `(3 * rx) ^ ry`
   - add `size * size * quadrant` into `d`
   - rotate with `rotSigned`
   - halve `size`
6. Return `d`

The use of signed temporaries is the main implementation nuance in this file.

## Curve Writer

The library also exposes:

```zig
pub fn writeCurve(writer: anytype, order: u8) !void
```

This helper:

- validates `order`
- iterates over all indices from `0` to `maxIndex(order)`
- computes `n = 2^order` once
- calls `d2xyUnchecked(n, d)` for each index
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

The loop counter is `u16`. The loop terminates by comparing against the inclusive end index instead of an exclusive point count.

## Moore-Neighbor Distance Report

The library also exposes:

```zig
pub fn writeNeighborDistances(writer: anytype, order: u8) !void
pub fn writeNeighborDistanceHistogram(writer: anytype, order: u8) !void
pub fn writeNeighborDistanceHistogramCoverage(writer: anytype, order: u8, coverage_percent: u8) !void
```

This report walks the Hilbert curve in index order and prints one line per cell with:

- the current Hilbert index
- the current grid position
- distances to Moore neighbors in fixed compass order: `N NE E SE S SW W NW`

Each distance is the absolute difference between the current cell index and the neighbor cell index along the Hilbert curve. Missing neighbors print `-`.

The histogram writer aggregates those same neighbor-distance values across the full report and prints one `distance=<value> count=<value> percentage=<value>%` line per distinct distance, sorted by ascending distance. The percentage is the bucket's share of all valid directed neighbor relationships in the grid, rounded to the nearest hundredth. The coverage variant prints only the shortest leading prefix of those sorted rows whose cumulative count reaches the requested integer percentage in `0..100`.

Example output line:

```text
d=5 pos=(0,3) N=1 NE=8 E=1 SE=- S=- SW=- W=- NW=-
```

Neighbor lookup is handled by a private `neighborPoint(n, point, dir)` helper. It computes the candidate adjacent cell from the `Direction` value, rejects out-of-bounds results, and returns `null` for missing border or corner neighbors.

## Command-Line Entry Point

`src/main.zig` provides a minimal CLI:

```text
zig build run -- 2
zig build run -- curve 2
zig build run -- neighbors 2
zig build run -- neighbors histogram 2
zig build run -- neighbors histogram 2 coverage 80
```

Behavior:

- `zig build run -- <order>` prints the plain Hilbert traversal
- `zig build run -- curve <order>` does the same explicitly
- `zig build run -- neighbors <order>` prints Moore-neighbor distances
- `zig build run -- neighbors histogram <order>` prints the histogram of neighbor distances
- `zig build run -- neighbors histogram <order> coverage <percent>` prints the shortest ascending-distance histogram prefix that reaches the requested cumulative coverage
- prints usage to stderr on missing, malformed, or extra arguments
- prints usage again when `order > 8`
- writes the selected report to stdout

The file uses the current Zig `0.15.2` file writer API:

- `std.fs.File.stdout().writer(&buffer)` for buffered curve output
- `std.fs.File.stderr().writer(&.{})` for short unbuffered usage messages

The program passes `&writer.interface` into helpers that expect `std.Io.Writer`, then explicitly calls `flush()` before exiting.

## Tests

All tests live in `src/hilbert.zig` and run with:

```text
zig build test
```

The suite covers:

- the full order-2 traversal table from the design note
- the specific example `d2xy(2, 5) == Point{ .x = 0, .y = 3 }`
- exhaustive round-trips for every valid point in orders `0..8`
- exact neighbor-distance output for orders `0` and `1`
- exact histogram output for orders `0` and `1`
- exact histogram coverage output for order `1`
- percentage formatting and rounding behavior
- Moore-neighbor distance checks for every point in orders `0..8`
- histogram total-count validation for every point in orders `0..8`
- bounds checking for generated coordinates
- invalid order, index, and coordinate errors
- exact `writeCurve` output for order `2`
- CLI parsing for bare and explicit output modes

These tests validate both correctness and the repository’s chosen public interface.

## Build Integration

`build.zig` defines three normal Zig workflows:

- `zig build` to compile the executable
- `zig build run -- <order>` to run the generator
- `zig build test` to execute the unit tests

The executable is named `hilbert_curve`.

## Summary

The Zig implementation is a direct, type-safe translation of the standard Hilbert mapping algorithm with three repository-specific constraints:

- public coordinates and indices use `u16`
- supported orders are limited to `0..8`
- the inverse transform uses signed internal rotation to avoid overflow during intermediate steps

Within those constraints, the code preserves the original algorithm’s main benefits: direct random access, no recursion, constant memory usage, and simple exhaustive testing.
