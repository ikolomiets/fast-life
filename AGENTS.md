# Repository Guidelines

## Project Structure & Module Organization

This repository is centered on a small Zig implementation of the Hilbert curve algorithm plus its design note. The main files are:

- `hilbert_curve_rot_d2xy_xy2d_algorithm.md` for the algorithm explanation
- `build.zig` for build, run, and test entry points
- `src/hilbert.zig` for the reusable library API and inline unit tests
- `src/main.zig` for the CLI curve generator

Keep new Zig modules under `src/`. Use lowercase snake case for new files, for example `curve_examples.zig`.

## Build, Test, and Development Commands

Use Zig’s standard build commands:

- `zig build test` to run the inline unit tests in `src/hilbert.zig`
- `zig build run -- 2` to print the full order-2 Hilbert traversal as `d x y`
- `zig build` to compile the `hilbert_curve` executable into `zig-out/`

Use `rg "TODO|FIXME" .` before submitting changes if you add follow-up notes.

## Coding Style & Naming Conventions

Use Zig with small, explicit helpers and straightforward integer math. Keep the algorithm iterative and close to the reference document. For documentation, use short sections and fenced code blocks for pseudocode or shell examples.

For filenames:

- use lowercase
- separate words with underscores
- keep names descriptive and topic-specific

Keep identifiers consistent with the algorithm note, such as `rot`, `d2xy`, `xy2d`, `rx`, and `ry`.

## Testing Guidelines

Tests live inline in `src/hilbert.zig` using Zig’s built-in test runner. Cover:

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
