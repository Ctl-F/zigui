# zigui

A lightweight, retained-mode, cross-platform UI toolkit for Zig, built for
IDEs, editors, and paint programs. Design doc:
https://claude.ai/artifact/XGC2eMeVS2WEMebrHEk6iT

## Status

Foundation layer only. Builds and passes all tests on Zig 0.17.0
(`zig build test`; 115 tests). The only 0.17 fix needed was `@typeInfo(...).@"struct"`
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
  event.zig          Event, EventKind, Listener (extern): capture/target/bubble
  dispatch.zig       immediate dispatch; destroys deferred until it finishes
  input.zig          pointer state machine: hover enter/leave, press capture, click
  ui.zig             Ui: tree + layout + input + widgets + theme, frame protocol
src/widgets/
  button.zig         Button state block (props/out/node), listener, default painter
  theme.zig          Theme: colors, metrics, swappable painters
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
SDL_VIDEODRIVER=dummy ZIGUI_SCRIPT="move 60 20;click 60 20" ZIGUI_SCREENSHOT=out.png ./zig-out/bin/demo
```

The demo has working buttons: header "+ Card" / "- Card" / "Sidebar", and
selectable sidebar rows. Text is not drawn yet (no text renderer), so buttons
are unlabeled; the window title shows click and card counts.

`zig build test` does not need SDL: the platform shim is a separate module.

## Decisions encoded so far

- Handles are index + generation; generation 0 is never issued.
- Pool chunks never move, so `*T` stays valid until that object is destroyed.
- Layout dirtiness stops at `relayout_boundary` nodes; paint markers stop at
  the first ancestor already marked.
- Layout seeding: each boundary that gains layout work is pushed on an
  intrusive stack (links in `Node`, so no allocation). A layout pass loops on
  `Tree.popLayoutRoot()`; entries whose dirty bits were already cleared are skipped.
- Events: DOM-style capture, target, bubble. Listeners live on the node in a
  lazily allocated table; a pointer listener sets `interactive` (hit-testable).
  `Tree.destroySubtree` during dispatch is deferred to the end of the outermost
  dispatch. Other structural changes (append, reparent) apply immediately and
  dispatch re-validates handles each step.
- Pointer input: a press captures the pointer; `click` fires if the release is
  still inside the pressed node's subtree. Enter/leave do not bubble.
- Widgets: state blocks live in pools (stable address). Setters mark dirty;
  raw `props` writes are caught by the shadow checker in `Ui.update`. Buttons
  hold `out.clicked` (frame-scoped) and `out.click_count` (monotonic). A
  button's block is reclaimed in `update` once its node is destroyed.
- Frame protocol (see `ui.zig`): input, app logic, `update`, layout and paint
  if `isDirty`, then `endFrame`.
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
2. **Widgets**: only Button exists. Next: label, checkbox, text field, list
   (model interface), scroll container, split/dock. Setter methods live on
   `Ui` (extern state blocks hold no pointer to it).
3. Renderer gaps: glyph runs (needs the text system), image paints, damage-rect
   tracking in the paint pass, the SDL3 GPU backend. The software renderer
   evaluates paints in float per pixel; optimize when it shows up in profiles.
4. Input and platform: keyboard focus and tab order, key routing and shortcuts,
   cursors, clipboard, IME, multi-window, canvas pointer modes (lock, coalescing).
5. Text system: glyph atlas, shaping cache, monospace fast path.
6. Piece-table editor core with reversible command log.
7. Strings: the node `label` is not owned; ownership policy is undecided.

Tests live next to the code (`test` blocks) and run through `src/root.zig`.
