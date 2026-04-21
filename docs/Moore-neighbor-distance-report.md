# Moore-Neighbor Distance Report

## Overview

This document describes the Moore-neighbor distance report implemented for the Hilbert curve generator in this repository.

Relevant code:

- `src/modules/hilbert_curve.zig` contains the core Hilbert types and mapping functions
- `src/modules/hilbert_neighbors.zig` contains neighbor lookup, histogram logic, and report writers
- `src/root.zig` re-exports the canonical modules
- `src/modules/hilbert_neighbors.zig` exposes the standalone neighbor-report CLI

The report walks the Hilbert curve from index `0` through `max_index(order)` and, for every visited cell, prints one line describing the Hilbert-curve distance to each of that cell's Moore neighbors.

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
fn index_distance(a: u16, b: u16) u16
```

The result is symmetric:

- distance from `A` to `B` equals distance from `B` to `A`
- the report does not encode whether the neighbor appears earlier or later on the curve

## Neighbor Lookup

Neighbor lookup is handled by:

```zig
fn neighbor_point(n: u16, point: Point, dir: Direction) ?Point
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
pub fn write_neighbor_distances(writer: anytype, order: u8) !void
```

Processing steps:

1. Validate `order`
2. Compute `n = grid_size(order)`
3. Iterate `d` from `0` through `max_index(order)`
4. Compute the current coordinate with `hilbert.d2xy(order, d)`
5. For each direction in fixed order `N NE E SE S SW W NW`:
   - call `neighbor_point`
   - if the neighbor exists, compute `neighbor_d = hilbert.xy2d(order, neighbor)`
   - print `abs(neighbor_d - d)`
   - otherwise print `-`

The neighbor module depends only on the public Hilbert API. It does not reach into private unchecked transform helpers from the core module.

## Histogram Mode

The implementation also exposes:

```zig
pub const NeighborKind = enum { all, orthogonal, diagonal };
pub fn write_neighbor_distance_histogram(writer: anytype, order: u8) !void
pub fn write_neighbor_distance_histogram_max_distance(writer: anytype, order: u8, max_distance: u16) !void
pub fn write_neighbor_distance_histogram_filtered(writer: anytype, order: u8, kind: NeighborKind, max_distance: ?u16) !void
```

This mode computes the frequency of every distance that appears among valid Moore-neighbor relationships in the report.

Behavior:

- only valid neighbors are counted
- missing neighbors do not contribute
- if cell `A` reports cell `B` as a neighbor and cell `B` reports cell `A`, both occurrences are counted
- each percentage uses the total number of valid directed neighbor relationships in the full Moore neighborhood as its denominator, even when a `kind` filter is active
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

Internally the implementation accumulates counts in a fixed array indexed by distance, tracks the total valid directed neighbor relationships for `kind=all`, then emits the selected non-zero buckets in ascending distance order.

### Kind Filter

Histogram mode supports an optional neighbor-kind filter:

```text
zig run src/modules/hilbert_neighbors.zig -- histogram <order> kind <all|orthogonal|diagonal>
```

Behavior:

- `all` counts all 8 directions
- `orthogonal` counts only `N`, `E`, `S`, `W`
- `diagonal` counts only `NE`, `SE`, `SW`, `NW`
- any explicit filter form appends one summary row:

```text
cumulative_percentage=<value>%
```

- `kind all` is accepted explicitly and emits the full histogram plus `cumulative_percentage=100.00%`

Example for order `1` with `kind orthogonal`:

```text
distance=1 count=6 percentage=50.00%
distance=3 count=2 percentage=16.67%
cumulative_percentage=66.67%
```

### Max-Distance Filter

Histogram mode also supports an optional inclusive distance cutoff:

```text
zig run src/modules/hilbert_neighbors.zig -- histogram <order> max-distance <distance>
```

Behavior:

- `distance` is parsed as `u16`
- only rows with `distance <= max_distance` are emitted
- the filtered form appends `cumulative_percentage=<value>%`
- the summary percentage is computed from the exact subtotal count for displayed rows, not by summing already-rounded row percentages
- `max-distance 0` emits no distance rows and `cumulative_percentage=0.00%`
- a cutoff above the largest present distance emits the full histogram plus `cumulative_percentage=100.00%`

### Combining Filters

`kind` and `max-distance` may be provided together in either order:

```text
zig run src/modules/hilbert_neighbors.zig -- histogram <order> kind <kind> max-distance <distance>
zig run src/modules/hilbert_neighbors.zig -- histogram <order> max-distance <distance> kind <kind>
```

The `max-distance` cutoff is applied after the `kind` selection.

Example for order `2` with `kind diagonal max-distance 4`:

```text
distance=2 count=24 percentage=28.57%
distance=4 count=4 percentage=4.76%
cumulative_percentage=33.33%
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

The standalone module entry point supports these forms:

```text
zig run src/modules/hilbert_neighbors.zig -- <order>
zig run src/modules/hilbert_neighbors.zig -- histogram <order>
zig run src/modules/hilbert_neighbors.zig -- histogram <order> kind <all|orthogonal|diagonal>
zig run src/modules/hilbert_neighbors.zig -- histogram <order> max-distance <distance>
zig run src/modules/hilbert_neighbors.zig -- histogram <order> kind <all|orthogonal|diagonal> max-distance <distance>
zig run src/modules/hilbert_neighbors.zig -- histogram <order> max-distance <distance> kind <all|orthogonal|diagonal>
```

Mode behavior:

- `<order>` emits the Moore-neighbor distance report
- `histogram <order>` emits the histogram of neighbor distances
- `histogram <order> kind <kind>` emits only the selected kind and a final cumulative percentage row
- `histogram <order> max-distance <distance>` emits only distances `1..max_distance` and a final cumulative percentage row
- the two histogram filters may be combined in either order

Neighbor-specific argument parsing is handled in `src/modules/hilbert_neighbors.zig` by `run_cli`, which is used by the standalone module `main(init)` entry point.

## Tests

The implementation is covered by unit tests in `src/modules/hilbert_curve.zig`, `src/modules/hilbert_neighbors.zig`, and `src/root.zig`.

Neighbor-report-specific coverage includes:

- exact golden output for order `0`
- exact golden output for order `1`
- exact histogram output for orders `0` and `1`
- exact histogram max-distance output for order `2`
- exact orthogonal and diagonal histogram output for order `1`
- exact combined kind and max-distance histogram output for order `2`
- percentage formatting and rounding behavior
- exhaustive neighbor validation for every point in orders `0..8`
- histogram total-count validation for every point in orders `0..8`
- orthogonal and diagonal histogram counts partition the full histogram for every order in `0..8`
- CLI parsing tests for:
  - bare `<order>`
  - `curve <order>`
  - `neighbors <order>`
  - `neighbors histogram <order>`
  - `neighbors histogram <order> kind <kind>`
  - `neighbors histogram <order> max-distance <distance>`
  - combined `kind` and `max-distance` in either order
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
