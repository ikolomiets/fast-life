# Moore-Neighbor Distance Report

## Overview

This document describes the Moore-neighbor distance report implemented for the Hilbert curve generator in this repository.

Relevant code:

- `src/hilbert.zig` contains the `Direction` enum, neighbor lookup, and report writer
- `src/main.zig` exposes the report through the CLI

The report walks the Hilbert curve from index `0` through `maxIndex(order)` and, for every visited cell, prints one line describing the Hilbert-curve distance to each of that cell's Moore neighbors.

## Moore Neighborhood

A Moore neighborhood includes the 8 adjacent cells around a grid cell:

- orthogonal neighbors: `N`, `E`, `S`, `W`
- diagonal neighbors: `NE`, `SE`, `SW`, `NW`

The implementation represents these neighbors with:

```zig
pub const Direction = enum {
    N, NE, E, SE, S, SW, W, NW,
};
```

The report uses grid orientation:

- `N = (x, y - 1)`
- `E = (x + 1, y)`
- `S = (x, y + 1)`
- `W = (x - 1, y)`

`y` increases downward, matching the existing grid-style output in this repository.

## Distance Definition

For a cell with Hilbert index `d` and a valid neighbor with Hilbert index `neighbor_d`, the reported distance is:

```text
abs(neighbor_d - d)
```

This is implemented by the private helper:

```zig
fn indexDistance(a: u16, b: u16) u16
```

The result is symmetric:

- distance from `A` to `B` equals distance from `B` to `A`
- the report does not encode whether the neighbor appears earlier or later on the curve

## Neighbor Lookup

Neighbor lookup is handled by:

```zig
fn neighborPoint(n: u16, point: Point, dir: Direction) ?Point
```

Purpose:

- take the current cell coordinate
- move one step in the requested compass direction
- return the neighbor coordinate if it stays inside the grid
- return `null` for missing edge or corner neighbors

The helper does not store `dx` and `dy` as data. Instead, it derives the step directly from the `Direction` value with a `switch`.

Example mappings:

- `.N`  -> `(x, y - 1)`
- `.NE` -> `(x + 1, y - 1)`
- `.SW` -> `(x - 1, y + 1)`

Signed temporary coordinates are used during the step calculation so that moves like `x - 1` and `y - 1` can be checked safely before converting back to `u16`.

## Report Generation

The main writer is:

```zig
pub fn writeNeighborDistances(writer: anytype, order: u8) !void
```

Processing steps:

1. Validate `order`
2. Compute `n = gridSize(order)`
3. Iterate `d` from `0` through `maxIndex(order)`
4. Compute the current coordinate with `d2xyUnchecked(n, d)`
5. For each direction in fixed order `N NE E SE S SW W NW`:
   - call `neighborPoint`
   - if the neighbor exists, compute `neighbor_d = xy2dUnchecked(n, neighbor)`
   - print `abs(neighbor_d - d)`
   - otherwise print `-`

The report reuses the existing unchecked Hilbert transforms because the loop already guarantees valid indices and points.

## Histogram Mode

The implementation also exposes:

```zig
pub fn writeNeighborDistanceHistogram(writer: anytype, order: u8) !void
pub fn writeNeighborDistanceHistogramMaxDistance(writer: anytype, order: u8, max_distance: u16) !void
```

This mode computes the frequency of every distance that appears among valid Moore-neighbor relationships in the report.

Behavior:

- only valid neighbors are counted
- missing neighbors do not contribute
- if cell `A` reports cell `B` as a neighbor and cell `B` reports cell `A`, both occurrences are counted
- each percentage uses the total number of valid directed neighbor relationships in the grid as its denominator
- results are sorted by ascending distance

Each output line has the form:

```text
distance=<value> count=<value> percentage=<value>%
```

Example for order `1`:

```text
distance=1 count=6 percentage=50.00%
distance=2 count=4 percentage=33.33%
distance=3 count=2 percentage=16.67%
```

The percentage is rounded to the nearest hundredth. Because of rounding, the printed percentages may not sum to exactly `100.00%`.

Internally the implementation accumulates counts in a fixed array indexed by distance, sums the total valid directed neighbor relationships, then emits the non-zero buckets in ascending distance order.

### Max-Distance Filter

Histogram mode also supports an optional distance cutoff:

```text
zig build run -- neighbors histogram <order> max-distance <distance>
```

Behavior:

- `distance` is parsed as `u16`
- only rows with `distance <= max_distance` are emitted
- the cutoff is inclusive
- the filtered form always appends one summary row:

```text
cumulative_percentage=<value>%
```

- the summary percentage is computed from the exact subtotal count for displayed rows, not by summing already-rounded row percentages
- `max-distance 0` emits no distance rows and `cumulative_percentage=0.00%`
- a cutoff above the largest present distance emits the full histogram plus `cumulative_percentage=100.00%`

Example for order `2` with `max-distance 4`:

```text
distance=1 count=30 percentage=35.71%
distance=2 count=24 percentage=28.57%
distance=3 count=10 percentage=11.90%
distance=4 count=4 percentage=4.76%
cumulative_percentage=80.95%
```

## Output Format

Each cell produces exactly one line in this form:

```text
d=<index> pos=(<x>,<y>) N=<value|-> NE=<value|-> E=<value|-> SE=<value|-> S=<value|-> SW=<value|-> W=<value|-> NW=<value|->
```

Properties of the format:

- one line per Hilbert index
- lines are emitted in ascending Hilbert order
- neighbor fields always appear in the same compass order
- missing neighbors are represented by `-`

Example for order `1`:

```text
d=0 pos=(0,0) N=- NE=- E=3 SE=2 S=1 SW=- W=- NW=-
d=1 pos=(0,1) N=1 NE=2 E=1 SE=- S=- SW=- W=- NW=-
d=2 pos=(1,1) N=1 NE=- E=- SE=- S=- SW=- W=1 NW=2
d=3 pos=(1,0) N=- NE=- E=- SE=- S=1 SW=2 W=3 NW=-
```

## CLI Integration

The executable supports these forms:

```text
zig build run -- <order>
zig build run -- curve <order>
zig build run -- neighbors <order>
zig build run -- neighbors histogram <order>
zig build run -- neighbors histogram <order> max-distance <distance>
```

Mode behavior:

- `<order>` keeps the original plain curve output
- `curve <order>` is an explicit alias for the original mode
- `neighbors <order>` emits the Moore-neighbor distance report
- `neighbors histogram <order>` emits the histogram of neighbor distances
- `neighbors histogram <order> max-distance <distance>` emits only distances `1..max_distance` and a final cumulative percentage row

Argument parsing is handled in `src/main.zig` by `parseCommand`, which selects either curve output or neighbor-distance output before dispatching to the appropriate writer.

## Tests

The implementation is covered by unit tests in `src/hilbert.zig` and `src/main.zig`.

Neighbor-report-specific coverage includes:

- exact golden output for order `0`
- exact golden output for order `1`
- exact histogram output for orders `0` and `1`
- exact histogram max-distance output for order `2`
- percentage formatting and rounding behavior
- exhaustive neighbor validation for every point in orders `0..8`
- histogram total-count validation for every point in orders `0..8`
- CLI parsing tests for:
  - bare `<order>`
  - `curve <order>`
  - `neighbors <order>`
  - `neighbors histogram <order>`
  - `neighbors histogram <order> max-distance <distance>`
  - invalid argument shapes

Run all tests with:

```text
zig build test
```

## Notes

The report is intentionally textual and allocation-free. It favors fixed-width semantics over compactness:

- every line carries the same 8 labeled neighbor slots
- edge and corner cells stay structurally identical to interior cells
- compass labels are taken directly from the enum tag names via `@tagName(dir)`
