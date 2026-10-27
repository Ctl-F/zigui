# zigui

A lightweight, retained-mode, cross-platform UI toolkit for Zig 0.17, built for
IDEs, editors, and paint programs. Design doc: `Zig UI Toolkit Design Document.md`.

The API is plain, idiomatic Zig. C interop will be a separate facade over it,
built after the core is done (see "Zig first" below). Notes for contributors are
in `NOTES/`: `CLAUDE.md` (rules), `zig-first-refactor.md` (the plan this tree just
went through), and `spec-drift-notes.md` (where the code differs from the design
doc, and what to do next).

## Status

Working and tested: node tree, flex layout, events and focus, text (shaping,
atlas, fields), commands and scoped shortcuts, a piece-table editor core with
undo/redo and multi-cursor, a code editor widget with incremental syntax
highlighting, a software renderer, and an SDL3 platform shim. About 315 tests.

Not built yet (largest first): the builder-friendly layer (runtime schema, widget
registry, ZON loader, forms), a renderer backend interface and GPU path, canvas
and frame scheduling, damage tracking, list/tree widgets and a model interface,
docking and multi-window, accessibility. See "Next steps".

## Commands

```
zig build test                 # all tests; no SDL needed
zig build check-boundary       # also part of `test`: no C-convention code in the core
zig build demo                 # IDE-style demo window (needs SDL3 dev files, pkg-config sdl3)
zig build dedit                # a minimal demo editor window
```

`zig build test` prints `ui_check` warnings and a "failed command" line from the
shadow-checker tests on purpose, while exiting 0.

Headless demo runs (no window needed):

```
SDL_VIDEODRIVER=dummy ZIGUI_SCREENSHOT=out.png ./zig-out/bin/demo
SDL_VIDEODRIVER=dummy ZIGUI_SCRIPT="click 700 22;type lay;key enter" ZIGUI_SCREENSHOT=out.png ./zig-out/bin/demo
# script verbs: move X Y | click X Y | press X Y | type TEXT | key [ctrl+][shift+]NAME
```

Fonts come from system paths (Linux); override with `ZIGUI_FONT=/path/ui.ttf` and
`ZIGUI_MONO_FONT=/path/mono.ttf`. The demo never writes files.

## Using it

```zig
var ui = try Ui.init(gpa);          // DO NOT MOVE the Ui after adding widgets
defer ui.deinit();
_ = try ui.addFont(font_backend);

const save = try ui.add(Button, ui.tree.root, .{
    .style = .{ .width = .px(120), .padding = Edges.xy(14, 0) },
    .text = "Save",
    .on_click = .bind(&app, App.save),      // fn (*App, *Event) void
});
try ui.registerCommand("file.save", .{ .title = "Save", .run = .bind(&app, App.save) });
try ui.bindShortcut("mod+s", "file.save", .app, null);

// Each frame: feed input, then
ui.update();
if (ui.isDirty()) {
    try ui.layoutAndPaint(size, &draw_list);
    software.render(&framebuffer, &draw_list, .{ .glyphs = ui.glyphProvider() });
}
ui.endFrame();
```

`examples/demo.zig` is a complete application built this way.

## Layout

```
build.zig              test, check-boundary, demo, dedit; options -Dui_checks, -Dui_strict
tools/check_boundary.zig   build-time scan for C-convention code in the core
src/root.zig           public exports; pulls in every module's tests
src/core/
  handle.zig           generational Handle (extern value type)
  pool.zig             chunked pool: stable addresses, free list, generations
  geometry.zig         Vec2, Size, Rect, Color (extern value types)
  length.zig           Length tagged union; resolve then clamp (min wins)
  flex.zig             flex main-axis solver (grow/shrink, freeze-and-redistribute)
  dirty.zig            DirtyFlags category bitset (one byte)
  shadow.zig           comptime shadow-copy checker (void when checks are off)
  tree.zig             node tree on the pool: hierarchy, dirty propagation, layout seeding
  style.zig            Style: size, flex, padding, margin, align; Visual (stopgap look)
  layout.zig           flex layout pass: measure (bottom-up) then place (top-down)
  draw_list.zig        fixed-capacity draw commands (tagged union), no allocation
  paint.zig            paint pass: laid-out tree to draw list
  keys.zig             Key, Mods, Chord; parse/format ("ctrl+shift+p")
  event.zig            Event, Callback, Listener: capture/target/bubble
  dispatch.zig         immediate dispatch; destroys deferred until it finishes
  input.zig            pointer state machine; keyboard focus, key/text routing
  commands.zig         command registry: named actions
  shortcuts.zig        scoped bindings, multi-key chords, keymap text loader
  clipboard.zig        Clipboard interface supplied by the platform
  ui.zig               Ui: owns tree, layout, input, theme, widgets; frame protocol
src/widgets/
  widget.zig           the comptime widget interface check
  button.zig label.zig text_field.zig code_editor.zig   the widgets
  common.zig           shared widget types (Text)
  theme.zig            Theme: colors, metrics, swappable button painter
src/editor/
  piece_table.zig      treap with cached byte/newline counts (line index)
  document.zig         Document: one edit path (Op/Command), change records, lines, columns
  selection.zig        sorted, merged (anchor, head) ranges; one cursor = list of one
  editor.zig           Editor: motion, edits, transactions, undo/redo, multi-cursor
  syntax.zig           line lexer + languages as data (Zig, C/C++, JSON, Markdown, plain)
  highlighter.zig      incremental per-line lexer state, driven by Document.changes
src/text/
  font.zig             font backend interface + synthetic TestFont
  gap_buffer.zig line_editor.zig   single-line field storage and editing model
  atlas.zig            glyph atlas: shelf-packed 1024px pages, LRU page eviction
  system.zig           TextSystem: font registry, shaping, caret stops, monospace fast path
  block.zig            TextBlock: a shaped line owned by a node
  stb.zig              stb_truetype backend (own module `zigui_stb`, needs C)
src/render/
  software.zig         software rasterizer: DrawList to RGBA8 (SDF-based AA)
  png.zig              tiny PNG encoder for screenshots
src/platform/sdl.zig   SDL3 shim: windows, events, text input, clipboard, cursors
third_party/stb/       stb_truetype.h v1.26 (public domain), vendored unmodified
examples/              demo.zig (IDE-style demo), dedit.zig (minimal editor)
```

## Zig first, C as a facade

- The core API is slices, optionals, tagged unions, error unions,
  `std.mem.Allocator`, and methods. Callbacks are `event.Callback` (a function and
  a typed context: `.bind(&app, App.onClick)`). No `callconv(.c)`, `export`, or
  `?*anyopaque` user-data pairs.
- Only `Handle`, `Rect`, `Vec2`, `Size`, `Color` are `extern`, so a facade can pass
  them by value. `zig build check-boundary` fails the build if C-convention code
  appears in the core (exempt: `src/platform/`, `src/text/stb*`, a future
  `src/capi/`).
- The C facade (opaque handles, setters/getters, status codes, `(ptr, len)`
  strings) comes after the core Zig library is done. Raw `props`/`out` access is a
  Zig-only feature.
- **Do not move a `Ui` after adding widgets.** Widgets keep a pointer back to it.
  Put it on the stack or the heap, never return it, copy it, or store it in a
  growing container. Debug builds panic if it moves (`Ui.isPinned`).

## Decisions encoded so far

- Handles are index + generation; generation 0 is never issued. Anything that can
  be destroyed is referenced by a handle. Pool chunks never move, so a `*T` stays
  valid until that object is destroyed.
- Single-threaded UI core. No allocation on the frame path: `DrawList` storage is
  allocated once and has fixed capacity (it keeps slots free so a full frame can
  still close its clips).
- `ui_checks` defaults on for Debug and ReleaseSafe, off otherwise. With it off
  the shadow type is `void` and `verify` compiles to nothing. `-Dui_strict=true`
  makes the checker panic instead of warning. `Callback` fields are skipped by it.
- Layout dirtiness stops at `relayout_boundary` nodes (which must have a
  content-independent size); paint markers stop at the first ancestor already
  marked. Boundaries needing layout go on an intrusive stack (links in `Node`, so
  no allocation) that a layout pass drains with `Tree.popLayoutRoot()`.
- Layout (`layout.zig`): border-box sizing; margins join the main-axis solve;
  percent is of the parent content box and falls back to auto (counted in
  `Layout.circular_percent`) under a `fit` parent; children are descended into
  only if their size changed or they are dirty. Two phases (measure, place); text
  size comes from `Node.intrinsic` (single line, no width-constrained measure yet).
- `Length` is `.px(10)`, `.pct(20)`, `.auto`, `.fill`, `.fit`; the union tags are
  `.pixels`/`.percent`. Draw commands and paints are tagged unions with one named
  payload per kind.
- Events: DOM-style capture, target, bubble. Listeners live on the node in a lazily
  allocated table; a pointer listener sets `interactive` (hit-testable). Dispatch is
  immediate; `Tree.destroySubtree` during dispatch is deferred to the end of the
  outermost dispatch, other structural changes apply immediately and dispatch
  re-validates handles each step.
- Pointer input: a press captures the pointer; `click` fires if the release is
  still inside the pressed node's subtree. Enter/leave do not bubble.
- Widgets: one struct per widget (props, out, node, a `ui` back-pointer, internal
  state) in a pool, created with `ui.add(Widget, parent, .{ options })` and checked
  against the comptime widget interface. Setters are methods that mark dirty; raw
  `props` writes are caught by the shadow checker in `Ui.update`. A widget's state
  is reclaimed in `update` once its node is destroyed. Polling flags are
  frame-scoped (`out.clicked`) with a monotonic counter (`out.click_count`), and
  callbacks and flags come from the same event path.
- Frame protocol (see `ui.zig`): input, app logic, `Ui.update` (settle focus, verify
  props, resolve looks), layout and paint if `isDirty`, then `endFrame`.
- Text: `font.Backend` is the swappable layer (stb_truetype today). The text system
  shapes UTF-8 lines (cmap, advances, pair kerning; no ligatures, bidi, or complex
  scripts yet) into glyph ids plus positions, and the draw list carries those, not
  strings. Monospace fonts get an ASCII fast path. Glyphs rasterize on demand into
  the atlas at the exact device size with 4 subpixel buckets (proportional text) or
  whole pixels (monospace); atlas pages are only evicted when not used this frame.
- Text ownership: widget text is copied by the setters into toolkit-owned storage
  (the `Text` wrapper keeps a literal from being mistaken for owned memory); a
  node's shaped `TextBlock` is owned by the node. `Ui.update` reshapes when text,
  font, or size changed, including raw prop writes.
- Focus: one focused node per tree. A press that nothing handles focuses the
  nearest focusable ancestor-or-self (or clears focus); Tab/Shift+Tab walk focusable
  nodes in tree order, wrapping, skipping hidden or disabled ones. Destroying or
  hiding the focused node moves focus to the nearest focusable ancestor.
  `Input.keyboard` records the last modality so focus rings show after keyboard use.
- Keys vs text: key events carry a `Key` plus `Mods`; committed text arrives
  separately as `text_input` and goes only to the focused node. Key order: focused
  node (capture, target, bubble), then shortcuts, then Tab focus movement.
- Text fields: gap buffer + `LineEditor` (UTF-8 safe, word movement, selection).
  Caret stops come from the same shaping loop as the glyphs, so caret, selection,
  and click hit-testing always match what is drawn. Edits fire `on_change`;
  `setText` does not. Caret blink runs from `Ui.tick(now_ms)` and `Ui.nextWakeMs()`
  is the event-wait timeout; `Ui.textInputRect()` is where the IME popup goes;
  `Ui.cursor()` picks the I-beam; clipboard access comes from the platform.
- Commands and shortcuts: a command is a named action with a title, enabled flag,
  repeat flag, and an optional `Callback` that receives a `command` event whose
  text is the name. Shortcuts bind chord sequences in four scopes (app, window,
  panel = focus inside a subtree, widget = that node has focus); the most specific
  scope wins, the deeper panel beats the shallower, ties go to the latest binding,
  and a disabled command is skipped. Plain typing never reaches shortcuts while a
  text widget is focused. Chords wait 1.5 s (time comes from `Ui.tick`, so tick with
  the current time before delivering input); a focus change or click cancels them;
  a dead chord swallows its last key; within a scope a sequence may not be a prefix
  of another. Keymaps are text (`ctrl+k ctrl+c = edit.comment`, `= none` to unbind)
  and later lines override. `Button.setCommand` links a button to a command.
- Editor core: a piece table (original file borrowed and never modified, plus an
  append-only add buffer) in a treap that caches subtree byte and newline counts, so
  line lookups never scan text. Every change goes through `Document.apply` as an
  `Op`, reversible by construction; history stores `Command`s that own their text.
  Selections are a sorted, merged list (a cursor is a list of one); edits are
  replace-ranges applied back to front inside one undo step. Steps group typing /
  backspace / delete-forward until a pause, a cursor move, a change of kind, or a
  save, and record selections before and after. Cursor movement is not undoable.
  Columns count code points; "\r\n" is one character.
- Syntax highlighting: a `Language` is data; `lexLine` colors one line and returns
  the state the next line starts in (only block-comment depth and Markdown fences
  cross lines). The `Highlighter` keeps per-line end states, splices them from
  `Document.changes`, and relexes dirty lines until a line ends in the state it had
  before (editing one line of 2000 relexes one line). Spans are computed on demand
  for visible lines. The lexer is approximate, like a TextMate grammar.
- Code editor widget: only visible lines are built and drawn (tabs expanded, shaped
  through the text system), so cost does not grow with document size. It paints
  through `Node.paint_hook`. Scroll follows the primary caret; the wheel scrolls
  independently.

## Next steps

Ordered by the spec-drift notes (`NOTES/spec-drift-notes.md`); the notes are the
authority for rationale, and a few items are recommendations, not requirements.

1. Painters that emit draw commands (today the button painter returns a `Visual`),
   swappable per widget type, plus `Ui.setTheme` and per-widget overrides.
2. A renderer backend interface with the software renderer as its first
   implementation (the atlas pages already track a dirty flag for GPU upload).
3. Canvas node with `redraw_policy` and raw-key mode in key routing.
4. Frame stats ring buffer and overlay, a handler time-budget warning, and a test
   that steady-state frames allocate nothing.
5. Damage rects and per-repaint-boundary draw-record caching.
6. `makeClickable`, an unlabeled-interactive-node warning, owned node labels,
   focus scopes (modal traps), tab indices, IME preedit.
7. Memory-mapped document open and an off-thread newline-index scan.
8. Runtime schema generator (reflect over the widget interface), then forms and
   wizards, then a ZON loader and the builder.
9. SDL3 GPU backend and shader pipeline; monospace draw-list run records.
10. The C facade (`src/capi/`), once the core Zig library is done.

Smaller gaps: layout follow-ups (width-constrained text measure, stack/absolute,
split and scroll containers, wrap, grid, calc `Length`); draw commands for
transforms, image quads, shadows, paths; a model interface for lists and trees;
more languages, bracket matching, find/replace, soft wrap, and folding in the
editor; undo/redo and password mode in text fields; HarfBuzz/FreeType backend
(ligatures, bidi, GPOS kerning); a bundled default font. `ui.zig` still imports
every widget (the notes suggest moving it out of `core/`).
