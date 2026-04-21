# Life RLE Design

## Overview

This document describes the Conway's Game of Life RLE support implemented in this repository.

Relevant code:

- `src/root.zig` re-exports the canonical `fast_life.life_rle` module
- `src/modules/life_rle.zig` contains the RLE parser, encoder, file helpers, grid integration helpers, a standalone CLI entry point, and inline tests
- `src/modules/binary_grid.zig` provides the `BinaryGrid` and `CellCoord` types that the RLE module integrates with

The module is intentionally narrow. It treats RLE as an I/O format for relative patterns, not as a simulation format, transform library, or placement policy framework.

## RLE Format Role

Game of Life RLE is a compact textual format for relative patterns.

Instead of listing every cell explicitly, it encodes runs of:

- live cells with `o`
- dead cells with `b`
- row breaks with `$`

A header line defines the pattern bounding box:

```text
x = <width>, y = <height>
```

The body ends with `!`.

In this repository, the important boundary is:

- a `Pattern` is relative and grid-independent
- a `BinaryGrid` is absolute and size-constrained
- the RLE module converts between those two worlds

For the grid-side details, see [binary_grid_design.md](binary_grid_design.md).

## Pattern Representation

The public pattern representation is:

```zig
pub const PatternCell = struct {
    x: usize,
    y: usize,
};

pub const Pattern = struct {
    width: usize,
    height: usize,
    live_cells: []PatternCell,

    pub fn deinit(self: *Pattern, allocator: std.mem.Allocator) void
};
```

This representation is sparse:

- `width` and `height` define the declared bounding box
- `live_cells` stores only live coordinates
- coordinates are relative to the pattern origin

The module expects `live_cells` to be sorted in row-major order and to stay inside the declared bounds. Parsed and extracted patterns satisfy that automatically. If a caller constructs a `Pattern` manually and violates those invariants, `write_pattern` or `apply_pattern` can fail with `error.InvalidPattern`.

`Pattern.deinit` frees the owned live-cell slice and resets the value to an empty pattern shell.

## Public API

The module exposes these entry points:

```zig
pub const ParseError = std.mem.Allocator.Error || error{
    MissingHeader,
    InvalidHeader,
    MissingTerminator,
    InvalidBody,
    PatternTooWide,
    PatternTooTall,
    TrailingData,
};

pub const max_pattern_file_bytes: usize = 2 * 1024 * 1024;

pub fn parse_pattern(allocator: std.mem.Allocator, input: []const u8) ParseError!Pattern
pub fn parse_pattern_file(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Pattern
pub fn write_pattern(writer: anytype, pattern: Pattern) !void
pub fn write_pattern_file(io: std.Io, path: []const u8, pattern: Pattern) !void
pub fn extract_pattern(
    comptime grid_order: usize,
    allocator: std.mem.Allocator,
    grid: *const binary_grid.BinaryGrid(grid_order),
) (std.mem.Allocator.Error || error{EmptyPattern})!Pattern
pub fn write_grid(
    comptime grid_order: usize,
    writer: anytype,
    grid: *const binary_grid.BinaryGrid(grid_order),
) !void
pub fn apply_pattern(
    comptime grid_order: usize,
    grid: *binary_grid.BinaryGrid(grid_order),
    pattern: Pattern,
    origin: binary_grid.CellCoord,
) !void
pub fn run_cli(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void
pub fn main(init: std.process.Init) !void
```

The responsibilities are:

- `parse_pattern` converts RLE text bytes into an owned relative `Pattern`
- `parse_pattern_file` loads RLE text from a file path and then parses it into an owned `Pattern`
- `write_pattern` emits canonical RLE for a given `Pattern`
- `write_pattern_file` writes canonical RLE for a `Pattern` directly to a file path
- `extract_pattern` scans a `BinaryGrid(order)` and returns the minimal live bounding box as a relative `Pattern`
- `write_grid` streams the minimal live bounding box of a `BinaryGrid(order)` directly as RLE
- `apply_pattern` overlays a relative pattern onto a `BinaryGrid(order)` at an absolute origin
- `run_cli` performs a file-to-file rewrite by parsing input RLE, placing it into a `BinaryGrid`, extracting the trimmed live pattern, and writing canonical output
- `main` exposes that rewrite flow as a standalone executable entry point for `zig run src/modules/life_rle.zig -- <input> <output>`

## Parsing Behavior

`parse_pattern` accepts a byte slice. `parse_pattern_file` is the file-system wrapper for current-working-directory path access.

Header rules:

- the first non-empty, non-comment line must be the header
- `x = ...` and `y = ...` are required
- `rule = ...` is accepted if present
- unknown header fields are rejected

Body rules:

- spaces, tabs, and carriage returns are ignored
- comment lines beginning with `#` are ignored before the header
- run counts are optional; omitted count means `1`
- `o`, `b`, `$`, digits, and `!` are the only valid tokens
- line breaks in the source do not imply row breaks; only `$` does

The parser accepts omitted trailing dead cells and omitted trailing empty rows up to the declared `width` and `height`.

Malformed input is reported with these explicit errors:

- `MissingHeader`: no valid `x = ..., y = ...` header appears before body content
- `InvalidHeader`: the header is present but malformed
- `MissingTerminator`: the body never reaches `!`
- `InvalidBody`: the body contains an unknown token, zero run count, or other malformed run syntax
- `PatternTooWide`: a row run exceeds the declared width
- `PatternTooTall`: row breaks exceed the declared height
- `TrailingData`: non-whitespace content appears after `!`

For file parsing, `parse_pattern_file` reads through `std.Io.Dir.cwd()` and applies a fixed size cap:

- `max_pattern_file_bytes` is `2 MiB`
- files larger than that fail with `error.StreamTooLong`
- the cap is intended to comfortably cover canonical RLE for dense patterns up to roughly `1024 x 1024`

## Encoding Behavior

`write_pattern` emits a canonical simple form:

- header only contains `x = <w>, y = <h>`
- no comments are emitted
- no `rule = ...` field is emitted
- runs are compressed with decimal counts only when the count is not `1`
- output always ends with `!\n`
- no line wrapping is performed

Example:

```text
x = 3, y = 3
bo$2bo$3o!
```

The writer only emits explicit dead-cell runs when they are needed to reach the next live run in a row. Trailing dead cells at the end of a row are omitted.

`write_pattern_file` uses the same canonical encoding, but writes it directly to a file path through `std.Io.Dir.cwd()`. It creates or truncates the destination file and preserves the same `error.InvalidPattern` validation behavior as `write_pattern`.

## Grid Integration

The module integrates with `BinaryGrid`, but keeps pattern data relative.

TigerStyle cleanup made that boundary explicit:

- writer parameters stay generic where Zig I/O benefits from it
- grid parameters are no longer arbitrary "grid-like" `anytype` values
- `extract_pattern` and `write_grid` take `*const BinaryGrid(order)`
- `apply_pattern` takes `*BinaryGrid(order)` because it mutates the destination
- the compile-time `grid_order` argument makes the supported grid shape obvious at the call site

### Extraction

`extract_pattern` finds the minimal live-cell bounding box over the whole grid, rewrites those live cells relative to the box origin, and returns a sparse `Pattern`.

If the grid has no live cells, it returns:

```zig
error.EmptyPattern
```

### Direct Grid Encoding

`write_grid` performs the same bounding-box trim as `extract_pattern`, but streams RLE directly without first allocating a `Pattern`.

It also returns `error.EmptyPattern` for an all-dead grid.

## Command-Line Entry Point

`src/modules/life_rle.zig` also exposes a standalone executable entry point:

```text
zig run src/modules/life_rle.zig -- <input-rle-path> <output-rle-path>
```

The command flow is:

1. parse the input file with `parse_pattern_file`
2. reject the input if the declared pattern bounds exceed `BinaryGrid(8).cells_per_side`, which is `1024`
3. place the parsed live cells into `BinaryGrid(8)`
4. call `extract_pattern(8, ...)` on that grid
5. write the extracted pattern with `write_pattern_file`

This means the output is always the trimmed live bounding box in the module's canonical RLE form.

CLI-specific behavior:

- invalid argument count returns `error.InvalidUsage` and prints usage to stderr
- input whose declared `width` or `height` exceeds `1024` returns `error.PatternTooLargeForBinaryGrid`
- input with no live cells and declared bounds within `1024 x 1024` returns `error.EmptyPattern`, because the intermediate grid has no live bounding box to extract
- input and output paths are interpreted through `std.Io.Dir.cwd()`, matching the file helper APIs

### Pattern Application

`apply_pattern` takes a relative `Pattern` plus an absolute `binary_grid.CellCoord` origin.

Placement rules:

- placement is strict
- every live cell must fit inside the destination grid
- if any live cell would land outside the grid, the function returns `error.PatternOutOfRange`
- bounds are checked before mutation, so failed placement does not partially modify the grid

Application mode:

- only live cells from the pattern are written
- dead cells inside the pattern bounding box do not clear the destination grid

This is an overlay operation, not a rectangular overwrite.

## Design Boundaries

This module intentionally does not provide:

- absolute coordinates in the serialized format
- rotation, reflection, or translation helpers
- rule persistence in `Pattern`
- comment preservation in `Pattern`
- top-level integration with the Game of Life CLI in `src/main.zig`

Those concerns stay outside the current RLE layer.

## Tests

The inline tests in `src/modules/life_rle.zig` and `src/root.zig` cover:

- glider parsing
- comment and whitespace handling
- empty-pattern parsing
- malformed-input errors
- canonical RLE writing
- parse/write round trips
- file-based parse and write helpers
- trimmed extraction from `BinaryGrid`
- direct grid encoding
- cross-order coverage for the `BinaryGrid(order)`-specialized grid helpers
- overlay application and out-of-bounds failure
- empty-grid rejection
- file-to-file CLI rewrite behavior
- package-root re-export coverage

Run the suite with:

```text
zig build test
```

## Summary

The RLE subsystem provides a small bridge between textual Life patterns and the repository's dense binary grid:

- `Pattern` is a sparse, relative, allocator-backed representation
- `parse_pattern` and `write_pattern` handle RLE text I/O
- `extract_pattern`, `write_grid`, and `apply_pattern` connect relative patterns to absolute `BinaryGrid(order)` values

That keeps the format handling compact, explicit, and separate from simulation semantics.
