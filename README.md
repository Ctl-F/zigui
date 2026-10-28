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
highlighting, a software renderer, an SDL3 platform shim, a runtime widget
schema and registry, generated forms and wizards, ZON UI documents, and a visual
builder. About 505 tests.

Not built yet (largest first): a renderer backend interface and GPU path, canvas
and frame scheduling, damage tracking, list/tree widgets and a model interface,
docking and multi-window, accessibility. See "Next steps".

## Documentation

Guides, a tutorial, and a page per widget are in `docs/` (open `docs/index.html`).
They are a living document: a feature or widget is not finished until its docs
are updated (`docs/maintaining.html` has the checklist).

## Commands

```
zig build test                 # all tests; no SDL needed
zig build check-boundary       # also part of `test`: no C-convention code in the core
zig build demo                 # IDE-style demo window (needs SDL3 dev files, pkg-config sdl3)
zig build dedit                # a minimal demo editor window
zig build paint                # paint program on a canvas with an offscreen surface
zig build shaders              # recompile GLSL to SPIR-V (needs glslc; the .spv files are committed)
zig build builder              # the UI builder, editing ./ui.zon (or zig-out/bin/builder FILE)
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
  paint_ctx.zig        PaintCtx: what a painter draws into (list, rect, text-color overrides)
  paint.zig            paint pass: Visual, then painter, then text, then children
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

- Runtime schema (`core/schema.zig`): `typeOf(T)` reflects a struct at compile
  time into a constant `Type` tree (kinds, nested fields, enum names, dirty
  category from `dirty_map`, optional `pub const ui` metadata) with compiler
  generated typed get/set functions, so reads and writes through the schema are
  type-checked, not raw memory. Paths like `colors.normal` or `syntax[3]` reach
  nested values. Callbacks, painters, and slice strings are listed but not
  editable. Text writes go through the owner's `replace_text` hook so the toolkit
  keeps ownership.
- Forms (`forms/form.zig`): `Form(T)` generates a non-blocking dialog body from
  `T`'s schema (toggle, enum cycle button, text fields with parsing for numbers,
  colors, lengths; optionals get a Set toggle and rebuild; structs and arrays
  nest). `pub fn validate(*const T, *Report)` adds cross-field errors; parse and
  validation errors show under the field and disable Submit. Typed strings are
  form-owned; `take(allocator)` returns a deep copy (`freeOwned` frees it). The
  blocking `prompt` belongs to the platform loop and is not built yet.
- Wizards (`forms/wizard.zig`): `Wizard(T)` is a page list over one result
  struct with Back/Next/Finish/Cancel chrome and a step indicator. Pages are
  generated (named fields, or a `ui` `.group`; `generatedPages(T)` makes one per
  group) or custom (a build callback). `can_next` conditions and page-scoped
  validation gate Next; edits persist across pages.
- UI documents (`uidoc/`): `zon.zig` reads and writes a dynamic ZON `Value` tree
  (line/column errors); `doc.zig` is the document model (nodes with type, id,
  sparse `style` and `props` records, `on` event-to-action bindings, children),
  the same model the builder edits; `load.zig` instantiates it, applying style
  and props through the runtime schema and binding events to an app-supplied
  `Actions` table. Anything the document gets wrong is a `Problem` with a path
  (`props.variant: unknown value 'huge' ...`), and the rest still builds.
  Widgets whose text is content (text fields, code editors) take `.text` in
  `.props` through the registry's `set_text`. `@embedFile` text loads the same way
  at startup; comptime validation and declarative wizards are not built.
- Builder (`builder/builder.zig`, run with `zig build builder`): palette, outline,
  live preview, and a generated inspector, all in the toolkit, over the undoable
  document editor in `uidoc/edit.zig` (edits made in one gesture, like a resize
  drag, merge into one step; batches group multi-part edits such as wrap).
  - *Design surface:* the preview is not running; clicks select the node under the
    pointer (empty frame space selects the root), hover and selection are drawn
    as overlays with resize handles, and the frame can be set to a device size.
  - *Moving things:* drag in the preview or the outline to reorder and reparent
    (over a box's middle: inside; over a widget or a box's edge: beside, with an
    insertion marker; never into the node's own subtree); drag a palette entry
    to create it where you drop it. The geometry lives in `builder/interact.zig`
    and is unit tested.
  - *Resizing:* right, bottom, and corner handles set pixel width and height.
  - *Inspector* (scrolls): Props and Style are generated from the schema; Layout
    is a hand-made panel (direction, gap, padding, align, justify, width and
    height modes, grow, shrink, margin, align self); Events binds actions.
  - *Structure:* duplicate, wrap in a box, unwrap, indent, outdent, move up/down,
    delete, copy, cut, paste (ZON text through the system clipboard), each with a
    toolbar button and a shortcut scoped to the builder's panel.
  - *Hosting:* `command_prefix` lets several builders coexist, `modified()` /
    `markSaved()` / `on_change` track the document, and `loadDocument` swaps it,
    which is what an IDE embedding it needs.
  Inspector edits write to the live widget and are diffed back into the document,
  so typing focus survives; structural changes, undo, and redo rebuild the views.
  Limits: no multi-selection, no zoom, no drag from the preview onto the
  inspector, no live text editing on the canvas; enums are cycle buttons.
- Scroll containers (`widgets/scroll_view.zig`): `Node.scroll_x/y` offsets what
  its children draw, hit, and report (`absoluteRect`, hit testing, paint, and
  damage all follow it); `ScrollView` is a clipped viewport onto a content node
  with wheel scrolling, shift-wheel for horizontal, a draggable thumb,
  `scrollTo`/`scrollIntoView`, and an `overlay` slot; `Node.overlay_hook` paints
  after children. `Tree.nodeAt` picks the deepest node at a point, interactive or
  not.
- Event system audit (this is what an audit of the input path found and fixed):
  the SDL loops delivered wheel events at (0, 0) instead of at the pointer, so
  wheel scrolling went to whatever was in the window's top-left corner (the shim
  now reports the pointer position with the wheel); a button release that
  happened outside the window was lost, leaving the old press "held" so the next
  click was misrouted (a press while the same button is still held now ends the
  old press, SDL captures the mouse while a button is down, and
  `Ui.pointerCancel` handles a lost focus); hover stayed lit after the pointer
  left the window (`Ui.pointerLeft`); and runs of mouse motion were each
  hit-tested and dispatched (the shim merges them). A randomized stress test
  (`core/input_fuzz.zig`: pointer, keys, focus scopes, and listeners that stop
  propagation, destroy, reparent, hide, and change focusability mid-dispatch)
  checks tree consistency, closed dispatches, and live-only input state after
  every step.
- Rendering cost: the software rasterizer fills the interior of rectangles and
  rounded boxes and skips the empty middle of borders instead of evaluating
  every pixel (about 5x faster on large panels), the builder repaints only the
  edges and handles of its overlays, and the example programs build as
  ReleaseSafe by default (`-Dexample_optimize=debug` for Debug); a Debug build
  of software rendering is an order of magnitude slower and not a fair
  judge of responsiveness.
- Widget registry (`widgets/registry.zig`): one list of widget types gives each a
  name, `Props`/`Out` schemas, and create-by-name. `Ui.add` tags the node
  (`Node.widget`, `Node.widget_type`) so a node maps back to its descriptor.
  `setProp`/`setStyle` write by path and mark the node with the prop's declared
  dirty categories. `Text` declares `is_text` to be recognized.
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
- Painters and themes: a painter is `fn (*PaintCtx, *const Widget) Error!void` that
  emits the widget's draw commands from its state (and may set the text color,
  selection color, and caret color on the context). `Theme` holds one painter per
  widget type (`button_painter`, `label_painter`, `field_painter`, `editor_painter`)
  plus the color tables; a widget can override its colors (`props.colors`) or its
  painter (`setPainter`). State changes that painters read (hover, press, focus)
  mark the node paint-dirty where they happen. `Ui.setTheme` swaps the whole theme
  and repaints everything; fonts and sizes that changed reshape on the next `update`.
  The paint pass runs, per node: `Visual` (plain containers), painter, text, children.
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
- Layout modes: `Style.position = .absolute` with `inset` places a child
  relative to its parent outside the flex flow; `Style.wrap` wraps flex rows.
  Wrap does not yet grow a fit-sized container. `SplitView` is a two-pane
  container with a draggable divider and resize cursors; child hosts are
  addressed through `content_at` in the registry. The builder edits all of this
  (Layout tab, drag to move absolute children).
- Workbench (`zig build workbench`): a code editor on the ZON text beside the
  builder, synced both ways; parse errors go to the status line. Examples build
  ReleaseSafe by default (`-Dexample_optimize`) because the software rasterizer
  is too slow in Debug.
- Buttons and text fields get inner spacing from the theme (`button_padding`,
  `field_padding`) when their style has no padding, so rounded corners stay
  clear of the text. The preview root grows to fill its frame (builder only), so
  `fill` heights work in a document root.


## Next steps

Ordered by the spec-drift notes (`NOTES/spec-drift-notes.md`); the notes are the
authority for rationale, and a few items are recommendations, not requirements.

1. The C facade (`src/capi/`), once the core Zig library is done.

Smaller gaps: theme metrics (padding, min sizes) and a painter measure override; layout follow-ups (width-constrained text measure, grid, calc `Length`, wrap
growing a fit-sized container); draw commands for
transforms, image quads, shadows, paths; a model interface for lists and trees;
more languages, bracket matching, find/replace, soft wrap, and folding in the
editor; undo/redo and password mode in text fields; HarfBuzz/FreeType backend
(ligatures, bidi, GPOS kerning); a bundled default font. `ui.zig` still imports
every widget (the notes suggest moving it out of `core/`).
