# zigui

A lightweight, retained-mode, cross-platform UI toolkit for Zig, built for
IDEs, editors, and paint programs. Design doc:
https://claude.ai/artifact/XGC2eMeVS2WEMebrHEk6iT

## Status

Foundation layer only. Builds and passes all tests on Zig 0.17.0
(`zig build test`; 94 tests). The only 0.17 fix needed was `@typeInfo(...).@"struct"`
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
  tree.zig           node tree on the pool: hierarchy ops, dirty propagation, layout seeding
  style.zig          Style: size/min/max, grow/shrink, direction, gap, padding, margin, align
  layout.zig         flex layout pass: measure (bottom-up) then place (top-down)
  paint.zig          paint pass: laid-out tree to draw list (stopgap `Visual` look)
  shadow.zig         comptime shadow-copy checker (void when checks are off)
  draw_list.zig      fixed-size command records, fixed capacity, no allocation
```

src/render/
  software.zig       software rasterizer: DrawList to RGBA8 (SDF-based AA)
  png.zig            tiny PNG encoder for screenshots
src/platform/
  sdl.zig            SDL3 shim: windows, events, present (own types only)
examples/demo.zig    IDE-style demo window

## Running the demo

Needs SDL3 development files (found via pkg-config as `sdl3`).

```
zig build demo                       # opens a window; Esc closes it
SDL_VIDEODRIVER=dummy ZIGUI_SCREENSHOT=out.png ./zig-out/bin/demo   # headless PNG
```

`zig build test` does not need SDL: the platform shim is a separate module.

## Decisions encoded so far

- Handles are index + generation; generation 0 is never issued.
- Pool chunks never move, so `*T` stays valid until that object is destroyed.
- Layout dirtiness stops at `relayout_boundary` nodes; paint markers stop at
  the first ancestor already marked.
- Layout seeding: each boundary that gains layout work is pushed on an
  intrusive stack (links in `Node`, so no allocation). A layout pass loops on
  `Tree.popLayoutRoot()`; entries whose dirty bits were already cleared are skipped.
- Layout (`layout.zig`): border-box sizing; margins join the main-axis solve;
  percent is of the parent content box and falls back to auto (counted in
  `Layout.circular_percent`) under a `fit` parent. Children are descended into
  only if their size changed or they are dirty. A relayout boundary must have
  a content-independent size.
- `ui_checks` defaults on for Debug and ReleaseSafe, off otherwise. With it
  off, the shadow type is `void` and `verify` compiles to nothing.
  `-Dui_strict=true` makes the checker panic instead of warning.
- The draw list never allocates per frame: allocate `draw_list.Storage` once.
- Length: `px`, `pct` (percent of parent content box), `auto`, `fill`, `fit`.
  A percent against a content-sized parent falls back to auto and is flagged.

## Known gaps and next steps

1. **Layout follow-ups**: text measurement callback (leaves use
   `Node.intrinsic` for now), stack/absolute, split/scroll containers, wrap,
   grid, and a calc-style `Length`.
2. **Widget state blocks** (`props` / `out` extern structs) and listeners.
3. Renderer gaps: glyph runs (needs the text system), image paints, damage-rect
   tracking in the paint pass, the SDL3 GPU backend. The software renderer
   evaluates paints in float per pixel; optimize when it shows up in profiles.
4. Platform: hit-testing and event dispatch to nodes (events reach the demo but
   nothing consumes them yet), clipboard, cursors, IME, multi-window.
5. Text system: glyph atlas, shaping cache, monospace fast path.
6. Piece-table editor core with reversible command log.
7. Strings: the node `label` is not owned; ownership policy is undecided.

Tests live next to the code (`test` blocks) and run through `src/root.zig`.
