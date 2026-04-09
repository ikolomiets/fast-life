# Life RLE Design

## Overview

This document describes the Conway's Game of Life RLE support implemented in this repository.

Relevant code:

- `src/root.zig` re-exports the canonical `fast_life.life_rle` module
- `src/modules/life_rle.zig` contains the RLE parser, encoder, file helpers, grid integration helpers, and inline tests
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

The module expects `live_cells` to be sorted in row-major order and to stay inside the declared bounds. Parsed and extracted patterns satisfy that automatically. If a caller constructs a `Pattern` manually and violates those invariants, `writePattern` or `applyPattern` can fail with `error.InvalidPattern`.

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

pub fn parsePattern(allocator: std.mem.Allocator, input: []const u8) ParseError!Pattern
pub fn parsePatternFile(allocator: std.mem.Allocator, path: []const u8) !Pattern
pub fn writePattern(writer: anytype, pattern: Pattern) !void
pub fn writePatternFile(path: []const u8, pattern: Pattern) !void
pub fn extractPattern(allocator: std.mem.Allocator, grid: anytype) (std.mem.Allocator.Error || error{EmptyPattern})!Pattern
pub fn writeGrid(writer: anytype, grid: anytype) !void
pub fn applyPattern(grid: anytype, pattern: Pattern, origin: binary_grid.CellCoord) !void
```

The responsibilities are:

- `parsePattern` converts RLE text bytes into an owned relative `Pattern`
- `parsePatternFile` loads RLE text from a file path and then parses it into an owned `Pattern`
- `writePattern` emits canonical RLE for a given `Pattern`
- `writePatternFile` writes canonical RLE for a `Pattern` directly to a file path
- `extractPattern` scans a grid and returns the minimal live bounding box as a relative `Pattern`
- `writeGrid` streams the minimal live bounding box of a grid directly as RLE
- `applyPattern` overlays a relative pattern onto a grid at an absolute origin

## Parsing Behavior

`parsePattern` accepts a byte slice. `parsePatternFile` is the file-system wrapper for current-working-directory path access.

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

For file parsing, `parsePatternFile` reads through `std.fs.cwd()` and applies a fixed size cap:

- `max_pattern_file_bytes` is `2 MiB`
- files larger than that fail with `error.FileTooBig`
- the cap is intended to comfortably cover canonical RLE for dense patterns up to roughly `1024 x 1024`

## Encoding Behavior

`writePattern` emits a canonical simple form:

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

`writePatternFile` uses the same canonical encoding, but writes it directly to a file path through `std.fs.cwd()`. It creates or truncates the destination file and preserves the same `error.InvalidPattern` validation behavior as `writePattern`.

## Grid Integration

The module integrates with `BinaryGrid`, but keeps pattern data relative.

### Extraction

`extractPattern` finds the minimal live-cell bounding box over the whole grid, rewrites those live cells relative to the box origin, and returns a sparse `Pattern`.

If the grid has no live cells, it returns:

```zig
error.EmptyPattern
```

### Direct Grid Encoding

`writeGrid` performs the same bounding-box trim as `extractPattern`, but streams RLE directly without first allocating a `Pattern`.

It also returns `error.EmptyPattern` for an all-dead grid.

### Pattern Application

`applyPattern` takes a relative `Pattern` plus an absolute `binary_grid.CellCoord` origin.

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
- CLI wrappers

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
- overlay application and out-of-bounds failure
- empty-grid rejection
- package-root re-export coverage

Run the suite with:

```text
zig build test
```

## Summary

The RLE subsystem provides a small bridge between textual Life patterns and the repository's dense binary grid:

- `Pattern` is a sparse, relative, allocator-backed representation
- `parsePattern` and `writePattern` handle RLE text I/O
- `extractPattern`, `writeGrid`, and `applyPattern` connect relative patterns to absolute grids

That keeps the format handling compact, explicit, and separate from simulation semantics.
