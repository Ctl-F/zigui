# zigui

A lightweight, retained-mode, cross-platform UI toolkit for Zig, built for
IDEs, editors, and paint programs. Design doc:
https://claude.ai/artifact/XGC2eMeVS2WEMebrHEk6iT

## Status

Foundation layer only. Builds and passes all 57 tests on Zig 0.17.0
(`zig build test`). The only 0.17 fix needed was `@typeInfo(...).@"struct"`
now exposing `field_names` / `field_types` instead of `fields` (`shadow.zig`).

The shadow-checker tests intentionally trigger `ui_check` warnings, so the
test run prints them and a "failed command" line even though it exits 0.

## Layout

```
build.zig            test step; options -Dui_checks, -Dui_strict
src/root.zig         public exports; pulls in every module's tests
src/core/
  handle.zig         generational Handle (extern, 8 bytes)
  pool.zig           chunked pool: stable addresses, free list, generations
  geometry.zig       Vec2, Size, Rect, Color (all extern)
  length.zig         Length tagged union; resolve then clamp (min wins)
  flex.zig           flex main-axis solver (grow/shrink, freeze-and-redistribute)
  dirty.zig          DirtyFlags category bitset (one byte)
  tree.zig           node tree on the pool: hierarchy ops, dirty propagation
  shadow.zig         comptime shadow-copy checker (void when checks are off)
  draw_list.zig      fixed-size command records, fixed capacity, no allocation
```

## Decisions encoded so far

- Handles are index + generation; generation 0 is never issued.
- Pool chunks never move, so `*T` stays valid until that object is destroyed.
- Layout dirtiness stops at `relayout_boundary` nodes; paint markers stop at
  the first ancestor already marked.
- `ui_checks` defaults on for Debug and ReleaseSafe, off otherwise. With it
  off, the shadow type is `void` and `verify` compiles to nothing.
  `-Dui_strict=true` makes the checker panic instead of warning.
- The draw list never allocates per frame: allocate `draw_list.Storage` once.
- Length: `px`, `pct` (percent of parent content box), `auto`, `fill`, `fit`.
  A percent against a content-sized parent falls back to auto and is flagged.

## Known gaps and next steps

1. **Layout pass seeding.** Dirty markers stop at relayout boundaries, so a
   layout pass cannot start from the root alone. Tree needs a list of dirty
   boundaries (or a scan) to seed layout. Not written yet.
2. **Flex layout pass**: the main-axis solver exists (`flex.zig`); still needed
   are the cross axis, alignment, padding, and walking the tree to call it.
3. **Widget state blocks** (`props` / `out` extern structs) and listeners.
4. **Software renderer** that executes a `DrawList` into a pixel buffer.
5. **SDL3 platform shim** and the SDL3 GPU backend.
6. Text system: glyph atlas, shaping cache, monospace fast path.
7. Piece-table editor core with reversible command log.
8. Strings: the node `label` is not owned; ownership policy is undecided.

Tests live next to the code (`test` blocks) and run through `src/root.zig`.
