# zigui

A lightweight, retained-mode, cross-platform UI toolkit for Zig, built for
IDEs, editors, and paint programs. Design doc:
https://claude.ai/artifact/XGC2eMeVS2WEMebrHEk6iT

## Status

Foundation layer only. Builds and passes all tests on Zig 0.17.0
(`zig build test`; 182 tests). The only 0.17 fix needed was `@typeInfo(...).@"struct"`
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
  keys.zig           Key enum and modifier bits (platform-independent)
  event.zig          Event, EventKind, Listener (extern): capture/target/bubble
  dispatch.zig       immediate dispatch; destroys deferred until it finishes
  input.zig          pointer state machine (hover, capture, click) and keyboard
                     focus, key/text routing, Tab navigation
  ui.zig             Ui: tree + layout + input + widgets + theme, frame protocol
src/widgets/
  label.zig          Label state block (text, font, size, color, align)
  text_field.zig     TextField state block: single-line editable text
  common.zig         shared widget types (Text)
  button.zig         Button state block (props/out/node), listener, default painter
  theme.zig          Theme: colors, metrics, swappable painters
  shadow.zig         comptime shadow-copy checker (void when checks are off)
  draw_list.zig      fixed-size command records, fixed capacity, no allocation
```

src/render/
  software.zig       software rasterizer: DrawList to RGBA8 (SDF-based AA)
  png.zig            tiny PNG encoder for screenshots
src/text/
  font.zig           font backend interface (swappable) + synthetic TestFont
  gap_buffer.zig    byte gap buffer (storage for single-line fields)
  line_editor.zig   single-line editing model: caret, selection, words, UTF-8
  atlas.zig          glyph atlas: shelf-packed 1024px pages, LRU page eviction
  system.zig         TextSystem: font registry, shaping, monospace fast path
  block.zig          TextBlock: a shaped line owned by a node
  stb.zig            stb_truetype backend (own module `zigui_stb`, needs C)
third_party/stb/     stb_truetype.h v1.26 (public domain), vendored unmodified
src/platform/
  sdl.zig            SDL3 shim: windows, events, present (own types only)
examples/demo.zig    IDE-style demo window

## Running the demo

Needs SDL3 development files (found via pkg-config as `sdl3`).

```
zig build demo                       # opens a window; Esc closes it
SDL_VIDEODRIVER=dummy ZIGUI_SCREENSHOT=out.png ./zig-out/bin/demo   # headless PNG
SDL_VIDEODRIVER=dummy ZIGUI_SCRIPT="move 60 20;click 60 20" ZIGUI_SCREENSHOT=out.png ./zig-out/bin/demo
# script verbs: move X Y | click X Y | press X Y | type TEXT | key [ctrl+][shift+]NAME
SDL_VIDEODRIVER=dummy ZIGUI_SCRIPT="click 700 22;type lay" ZIGUI_SCREENSHOT=out.png ./zig-out/bin/demo
```

Keys for the demo: Tab / Shift+Tab move focus, Enter or Space activate a focused
button, the header's filter field narrows the sidebar as you type (Enter selects
the first match), Esc leaves a focused field or quits.

The demo has working buttons (header "+ Card" / "- Card" / "Toggle sidebar" and
selectable sidebar rows), real text in a UI font and a monospace font, and a
status label that updates with clicks. Fonts come from system paths (Linux);
override with `ZIGUI_FONT=/path/ui.ttf` and `ZIGUI_MONO_FONT=/path/mono.ttf`.

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
- Text: `font.Backend` is the swappable layer (stb_truetype today). The text
  system shapes UTF-8 lines (cmap, advances, pair kerning; no ligatures, bidi, or
  complex scripts yet) into glyph ids plus positions, and the draw list carries
  those, not strings. Monospace fonts get a fast path for ASCII. Glyphs are
  rasterized on demand into the atlas at the exact device size with 4 subpixel
  buckets (proportional text) or whole pixels (monospace). Atlas pages are only
  evicted when not used this frame (`Ui.layoutAndPaint` starts a frame).
- Text ownership: widget text is copied by the `Ui` setters and owned by the
  toolkit; the node's shaped `TextBlock` is owned by the node. `Ui.update`
  reshapes when the text, font, or size changed, including raw prop writes.
  Layout learns a text node's size from `Node.intrinsic` (single line, no
  wrapping yet, so no width-constrained measure callback).
- Focus: one focused node per tree (`Tree.focused`). A press that nothing
  handles focuses the nearest focusable ancestor-or-self (or clears focus);
  Tab/Shift+Tab walk focusable nodes in tree order, wrapping; hidden or disabled
  nodes are skipped. Destroying or hiding the focused node moves focus to the
  nearest focusable ancestor. `focus_in`/`focus_out` fire however focus changed.
  `Input.keyboard` records the last input modality so painters draw focus rings
  after keyboard use only.
- Keys vs text: key events carry a `keys.Key` plus modifier bits; committed text
  arrives separately as `text_input` (typing, paste, IME) and goes only to the
  focused node. Keys go to the focused node (or the root if none) and an
  unhandled Tab moves focus; handlers claim keys with `markHandled`.
- Text fields: content in a gap buffer, edited through `LineEditor` (UTF-8 safe,
  word movement, selection). Caret stops come from the same shaping loop as the
  glyphs, so caret, selection, and click hit-testing always match what is drawn.
  Selection and caret are paint `Decor`ations on the node's text block; the
  field scrolls horizontally to keep the caret visible. Edits fire `on_change`;
  `setTextFieldText` does not. Caret blink runs from `Ui.tick(now_ms)`, and
  `Ui.nextWakeMs()` is the event-wait timeout. `Ui.textInputRect()` is where the
  caret is (window coordinates) for the platform to enable text input and place
  the IME popup; `Ui.cursor()` picks the I-beam over fields. Clipboard access
  comes from the platform through `Ui.clipboard`.
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
4. Input and platform: a shortcut/command registry (scoped, multi-key chords,
   remappable) and raw-key mode for canvases, focus scopes (modal traps, per-panel
   memory), tab indices and arrow-key groups, IME composition display (preedit),
   multi-window, canvas pointer modes (lock, coalescing), accessibility tree.
   Text fields: undo/redo, max length, password mode, multi-line, rich text.
5. Text follow-ups: wrapping and a width-constrained measure callback, multi-line,
   a HarfBuzz/FreeType backend (ligatures, bidi, GPOS kerning, variable fonts),
   color glyphs/emoji, font fallback chains, bundled default font, text gamma/
   contrast tuning, GPU atlas upload (pages already track a dirty flag), the
   monospace draw-list record from the design doc (positions are still emitted
   per glyph). Text selection, caret, IME, and the text field/editor widgets.
6. Piece-table editor core with reversible command log.
7. The accessibility `label` on nodes is still unowned (widget text is owned).

Tests live next to the code (`test` blocks) and run through `src/root.zig`.
