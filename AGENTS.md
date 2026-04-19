# Repository Guidelines

## Project Structure & Module Organization

This repository is centered on a small Zig implementation of the Hilbert curve algorithm plus a combined algorithm and implementation note. The main files are:

- `docs/hilbert_curve_implementation.md` for the algorithm explanation and Zig implementation details
- `build.zig` for build, run, and test entry points
- `src/root.zig` for the canonical package root that re-exports project modules
- `src/modules/hilbert_curve.zig` for the core Hilbert mapping module and its inline tests
- `src/modules/hilbert_neighbors.zig` for neighbor-distance analysis and its inline tests
- `src/main.zig` for the CLI curve generator

Keep new Zig modules under `src/`. Use lowercase snake case for new files, for example `curve_examples.zig`.

## Build, Test, and Development Commands

Use Zig’s standard build commands:

- `zig build test` to run the inline unit tests in the module files and CLI entry point
- `zig build run -- 2` to print the full order-2 Hilbert traversal as `d x y`
- `zig build` to compile the `hilbert_curve` executable into `zig-out/`
- `zig fmt build.zig src` to format the Zig sources

Use `rg "TODO|FIXME" .` before submitting changes if you add follow-up notes.

## Coding Style & Naming Conventions

Use Zig with small, explicit helpers and straightforward integer math. Keep the algorithm iterative and close to the reference material in `docs/hilbert_curve_implementation.md`. For documentation, use short sections and fenced code blocks for pseudocode or shell examples.

Follow the local [TigerStyle reference](docs/TIGER_STYLE.md) as the default style guide for this repository. That document is copied from the upstream [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md). When a repo-specific rule in this file conflicts with TigerStyle, this file takes precedence.

Apply these TigerStyle rules when editing this project:

- prioritize safety, then performance, then developer experience
- prefer simple, explicit control flow; avoid recursion and unnecessary abstractions
- use `snake_case` for functions, variables, file names, and package-root or module aliases
- keep Zig-style PascalCase for types, structs, enums, error sets, and type-returning factories such as `BinaryGrid(...)`
- use explicitly sized integer types for domain data where practical, and use `usize` only where Zig APIs or indexing require it
- assert preconditions, postconditions, and invariants; split compound assertions when it improves fault isolation
- prefer checked and unchecked API pairs at module boundaries; guard unchecked paths with `std.debug.assert`
- prefer explicit mutation and in-place initialization for large fixed-size values instead of returning large values by copy
- prefer concrete domain boundaries over clever `anytype` abstractions unless the abstraction is clearly justified by multiple real callers
- encode important geometry, packing, and size limits with compile-time checks and runtime assertions
- keep functions small enough to fit on one screen, centralize control flow, and keep variable scope tight
- use descriptive `snake_case` names, avoid abbreviations, and add units or qualifiers at the end when relevant, for example `distance_steps_max`
- use `fast_life.binary_grid` as the canonical package-root import; do not reintroduce `fast_life.grid`
- keep Hilbert reference identifiers such as `d2xy`, `xy2d`, `rx`, and `ry` as intentional exceptions, alongside Zig-standard names such as `main` and `deinit`
- explain why with comments when the reasoning is not obvious; comments should read as sentences
- run `zig fmt`, use 4-space indentation, and keep lines at 100 columns or fewer
- prefer Zig-native tooling and avoid adding new dependencies unless there is a strong project-level reason
- keep design notes, examples, and package-root import paths synchronized when public names change

For filenames:

- use lowercase
- separate words with underscores
- keep names descriptive and topic-specific

## Testing Guidelines

Tests live inline in `src/modules/hilbert_curve.zig`, `src/modules/hilbert_neighbors.zig`, `src/root.zig`, and `src/main.zig` using Zig’s built-in test runner. Cover:

- exact known mappings, especially the order-2 table
- round-trip behavior for `d2xy` and `xy2d`
- invalid input cases and CLI-facing helpers such as output generation

For documentation-only changes, verify formulas, tables, and fenced blocks remain consistent.

## Commit & Pull Request Guidelines

Git history is not available in this checkout, so no repository-specific commit convention can be inferred. Use short imperative commit messages such as `Add contributor guide` or `Clarify Hilbert rotation example`.

Pull requests should include:

- a brief summary of the change
- the reason for the update
- rendered screenshots only when formatting or presentation meaningfully changes

## Security & Configuration Tips

Do not commit secrets, generated credentials, or machine-specific configuration. Keep the repository portable and text-based unless binary assets become necessary.
