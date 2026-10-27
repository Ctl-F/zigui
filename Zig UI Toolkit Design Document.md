# Zig UI Toolkit: Design Document (v0 draft)

## 1. Goals

- Written in Zig 0.17.0. Pin the version and wrap std behind thin internal modules, since std APIs shift between releases.
- Cross-platform, desktop first (Windows, macOS, Linux). Web is not a target.
- Lightweight, retained mode, with custom-rendered widgets and efficient refresh.
- Complete enough for IDEs, paint programs, and editors.
- Builder-friendly: a UI that builds UIs, with layouts described as data.
- Zig first, with a C facade (built once the core is done) so C and C++ projects can use it too.

## 2. Layered Architecture

Each layer depends only on the layers below it.

1. **core**: node tree, layout, dirty tracking, draw list, events. No OS or GPU code.
2. **platform**: windows, input, clipboard, IME, DPI. Start with an SDL3 shim for fast coverage of all three desktops; native backends can come later. Multi-window support must exist from day one even if v0.1 opens only one window.
3. **render**: consumes the draw list. Software rasterizer first (easy to debug, runs everywhere), then a GPU backend.
4. **widgets**: built-in widget set.
5. **builder**: the visual UI designer, written in the toolkit itself.

## 3. Zig First, C as a Facade

*(Supersedes the earlier "ABI boundary rule", under which every app-visible type was `extern`. That rule forced `callconv(.c)` handlers, `?*anyopaque` user-data pairs, `Text{ptr,len}`, and setters hung off the context, all to pay for a C surface the Zig API did not need.)*

- The core API is idiomatic Zig: slices, optionals, tagged unions, error unions, `std.mem.Allocator`, methods, and comptime generics. Callbacks are `event.Callback` (a function plus a typed context, built with `Callback.bind`).
- Only a few small value types stay `extern` (`Handle`, `Rect`, `Vec2`, `Size`, `Color`) so a facade can pass them by value.
- C interop is a separate facade layered over the Zig API (`src/capi/`, **deferred until the core is done**): opaque handles, setter and getter functions, status codes, and `(ptr, len)` strings. C never gets raw struct access; direct `props`/`out` access is a Zig-only feature. The core never imports the facade.
- `callconv(.c)`, `export`, and non-allow-listed `extern` types are banned outside the facade and the C-import modules (`src/platform/`, `src/text/stb*`). `zig build check-boundary` (part of `zig build test`) enforces it.
- Public API hands out generational handles for nodes. Widgets are addressed by stable pointers (pool slots that never move).
- A `Ui` keeps widgets pointing back at it, so it **must not move** after the first widget is added. Debug builds assert this.
- Planned facade shape: heap-allocated `Ui`; handle-addressed widgets with accessor functions generated from the widget interface; an allocator vtable that carries alignment; a `zui_event` mirror; a frame protocol that lets a C host that owns its window drive zigui with no SDL dependency; a headless C smoke test run from the build.

## 4. Node Tree and Retained Engine

- Nodes live in a pool (struct-of-arrays) addressed by generational handles (index plus generation), not pointers. This gives cheap serialization, safe references, and straightforward undo/redo.
- Separate dirty categories for style, layout, paint, and hit-test. Layout dirtiness stops at relayout boundaries (fixed-size nodes).
- Paint produces damage rects, and only damaged regions are redrawn. Repaint boundaries cache subtrees to textures.
- Each OS window owns a root node tree and its own render target.

## 5. Layout

- Single pass: constraints go down, sizes come up, which makes caching easy.
- Modes: flex row and column (grow, shrink, gap, align), stack and absolute, and grid later.
- Split, dock, and tab containers come early, since IDEs need them.
- Text measurement goes through a callback into the text system.

## 6. Widgets

Every widget is one struct with a stable address (a pool slot that never moves). The app can hold a pointer to it and read or write it at any time, before or after a frame is rendered.

- **props**: written by the app (text, enabled, callbacks, colors).
- **out**: written by the toolkit (clicked, hovered, pressed, value).
- Widgets also hold a pointer back to their `Ui`, so they have methods (`button.setText(...)`), and their own per-frame hooks and event handling. The comptime widget interface (`widgets/widget.zig`: `Props`, `Out`, `Options`, `listened_kinds`, `nodeTemplate`, `init`, `deinit`, `apply`, `handleEvent`, `prepare`, `update`, `endFrame`) is what a runtime schema and widget registry will reflect over.
- Created with `ui.add(Button, parent, .{ options })`. The state is reclaimed once its node is destroyed (use generational node handles where a widget can disappear).
- Polling flags (such as `clicked`) are frame-scoped, plus a counter for apps that poll less often than they render. Callbacks and flags come from the same event path so they never disagree.
- Strings set through setters are copied into toolkit-owned storage, so the app can free or reuse its own memory immediately. The `Text` wrapper exists so a string literal assigned straight into `props.text` is not mistaken for owned storage.
- Callbacks are optional. Polling and callbacks are equal citizens.

Sketch:

```zig
const save = try ui.add(Button, root, .{
    .style = .{ .width = .px(120) },
    .text = "Save",
    .on_click = .bind(&app, App.save),
});
if (save.out.clicked) { ... }     // polling
try save.setText("Saved");        // setter: copies, marks dirty
save.props.enabled = false;       // raw write: allowed; the shadow checker verifies it
```

## 7. Dirty Tracking

- One dirty field per widget, holding a small set of categories (for example layout, paint, children), not one flag per property.
- Setters mark the right category automatically (`btn.setText(...)`).
- Raw field reads and writes are also allowed, and the dirty flags are directly accessible. The app can mark once at the end of its updates, for example `btn.markDirty(.paint)`.
- If the app marks nothing specific, the default is layout plus paint, so the lazy call is always safe.

### Shadow-copy checker

- Enabled only in Debug and ReleaseSafe, controlled by a build option (for example `-Dui_checks`) so it can also be forced on or off independently of optimization mode. In ReleaseFast the shadow type is `void` and every access compiles out.
- The shadow is a copy of `props` only, never `out`.
- A comptime-generated comparison walks the fields: values compare directly, text compares by contents, callbacks are skipped (changing one needs no dirty flag).
- Fields can be tagged with their required category, for example `dirty_map = .{ .text = .layout, .color = .paint }`, so warnings name the missing category.
- At the start of each frame's layout pass, if props differ from the shadow and the dirty bits do not cover the required categories, log a warning naming widget, field, and missing category, then self-correct by setting the bits and updating the shadow.
- A strict mode that panics instead of logging is available for Debug.
- Canvas content is excluded from the checker. A canvas invalidates explicitly.

## 8. Events

- Listeners live on the node, not the widget type. Each node has a lazily allocated listener table (event kind, callback, userdata), so a plain label costs nothing. Built-in handlers like Button's `on_click` are sugar over the same mechanism.
- Attaching a pointer listener sets an interactive bit so the node takes part in hit-testing and can set a cursor. Removing the last listener clears it. A helper like `makeClickable` also sets focusability, keyboard activation, and an accessibility role (link or button), so a clickable label works as a hyperlink or fancy button.
- Event flow follows the DOM model: capture phase down, target, then bubble up. A listener can stop propagation or mark the event handled.
- **Dispatch is immediate.** Structural tree changes made inside a handler (adding or removing nodes) are deferred until the end of the event.
- Debug aids for slow handlers: handler tracing (event kind and listener name recorded before each call) and a warning when a handler exceeds a time budget.

## 9. Canvas and Custom Rendering

The canvas is a widget with a state block like any other, with three surface modes:

1. **Draw-list mode**: the paint callback emits commands into the normal draw list. Cheap custom widgets.
2. **Offscreen texture mode**: the widget owns a texture, the app renders into it, and the toolkit composites it. Paint programs, with `invalidate(rect)` for dirty regions.
3. **Native-pass mode**: the toolkit exposes the backend's real device and a render target plus the pixel rect, scale, and clip. The app issues native calls directly. The toolkit owns the window and frame, and composites the result.

Two tiers overall: a portable draw context for most needs, and the backend escape hatch for games and 3D. Native-pass code is backend-specific by nature, so ship one portable GPU path first so the escape hatch is not a fork.

### Canvas input

- Pointer capture, so drags that leave the rect keep going to the canvas.
- A grab-all-input flag and a raw key mode that bypasses shortcuts (a focused canvas gets keys first, with a small reserved escape set).
- Events in local coordinates with pressure and tilt, and coalesced high-frequency motion for drawing.
- Pointer lock and relative mouse mode for games.
- Both queued and callback delivery. The canvas `out` block exposes a per-frame event queue and current key and button state for game-loop polling.

### Frame scheduling

- Each widget requests a `redraw_policy`: `on_demand`, `continuous`, or `fixed_hz`.
- The main loop sleeps only when no visible widget wants continuous frames, and syncs to vblank when one does.
- A continuously redrawing canvas is its own repaint boundary, so it does not invalidate its neighbors.
- The toolkit never holds a lock across app draw code. Shared textures use clear ownership such as double-buffered swaps.

## 10. Windows and Docking (post v0.1, plan now)

- Separate the OS window, the toolkit root, and the content. A toolkit-level window is a panel that either lives inside a root (docked or floating) or is the root of its own OS window.
- Panels are plain subtrees with stable handles, so undocking is reparenting the subtree to a new OS window's root, and docking is the reverse. State blocks and pointers survive.
- Events, focus, and the frame loop are per OS window.
- The dock layout is data: a tree of splits, tab groups, and panels, serializable to ZON so layouts can be saved and restored.
- Child window kinds (modal dialog, tool window above parent, floating panel) are one type with a small policy struct covering input blocking and z-order.

## 11. Forms and Wizards

### Struct-to-form dialogs

- The toolkit reflects a struct with `@typeInfo` to generate a form: bool becomes a checkbox, numbers become number fields, strings become text inputs, enums become dropdowns or radio groups, optionals become a field with a set toggle, nested structs become grouped sections. Field default values become initial values.
- An optional comptime `pub const ui = .{ ... }` metadata block per struct, keyed by field name, supplies labels, tooltips, min and max, multiline, file pickers, and so on.
- Optional comptime `validate` function returning per-field errors, shown inline and gating the submit button.
- Blocking API: `const result = try ui.prompt(NewProject, .{ .title = "New Project" })`. It runs a nested modal event loop and returns the filled-in struct (or a cancel result). Desktop only.
- Non-blocking API: `ui.openForm(...)` returns a handle with state in its `out` block, polled per frame. The blocking call is a loop wrapped around the polling one.
- Returned slices are allocated through an allocator the caller passes in, so the caller owns them after the dialog closes.
- Re-entrancy rules matter because the caller is on the stack while UI callbacks run in the nested loop.

Implemented in `src/forms/form.zig` as the non-blocking form (`Form(T)`); enums are cycle buttons rather than dropdowns until a popup widget exists, and `prompt` waits for the platform loop.

### Wizards

- A wizard is data: an ordered list of pages (forms or arbitrary subtrees) with a shared result type, optional per-page validation, and next and back conditions.
- The toolkit supplies the chrome: title, step indicator, back, next, finish, cancel.
- Generated wizard: split a struct into steps, each page mapping to a field or group of fields.
- Explicit wizard: custom pages plus custom next and back conditions.
- In ZON, a wizard is almost entirely declarative, and the builder can edit it visually.

Implemented in `src/forms/wizard.zig`: generated pages (by field names or `ui` group) and custom pages, `can_next` conditions, page-scoped validation. Declarative ZON wizards arrive with the ZON loader.

## 12. Runtime Schema (shared foundation)

One runtime schema format (field name, type tag, offset, metadata) serves four consumers:

- the form and wizard generator,
- the builder's inspector,
- the C facade (descriptors are mirrored for C callers),
- ZON serialization.

Comptime reflection generates it on the Zig side. The engine only ever consumes runtime schemas.

Implemented in `src/core/schema.zig` (`typeOf(T)`, path get/set, optional presence, per-field `ui` metadata, dirty category from `dirty_map`) and `src/widgets/registry.zig` (named widget list, create-by-name, `setProp`/`getProp`/`getOut`, `setStyle`). Offsets are recorded, but access goes through compiler-generated typed accessors. The C mirror is still deferred.

## 13. Builder

- UI is described as data in ZON: widget type, props, layout, named bindings, named actions.
- A comptime widget registry reflects `@typeInfo` to produce property schemas, so new widgets appear in the inspector and palette automatically.
- The same ZON can be embedded with `@embedFile` for zero-cost release builds or loaded at runtime for hot reload.
- Bindings in ZON are string paths or action names resolved against a registry at load time, with comptime validation for release builds. For example `on = .{ .click = "open_docs" }` works on any widget type.
- The builder is written in the toolkit itself: canvas preview, outline tree, inspector, and palette, all editing a document model through undo/redo commands.

Implemented: the ZON reader/writer, the document model, the loader (`src/uidoc/`) with named actions and ids, the undo/redo editor, and the builder (`src/builder/`) with palette, outline, live preview, and a schema-generated inspector. Not yet: comptime validation for embedded documents, declarative wizards in ZON, selecting by clicking in the preview, drag-and-drop reordering, and a scroll container for long inspectors.

## 14. Binding Model Decision

- **Actions and callbacks** for events (builder friendly, nearly free).
- **State blocks** with direct access for widget properties (the chosen primary model).
- **Observables** may be added later by letting a prop optionally point at a shared cell, without breaking the state-block design.
- **Model interfaces** (row count, data at row and column, change notifications) for collections such as lists, trees, tables, and editor lines. A state block per row does not scale to large collections.

## 15. Text

Design this as its own subsystem, since it is the hardest part.

- Glyph atlas, cached text layout, and a swappable shaping backend (stb\_truetype first, HarfBuzz and FreeType later).
- Editors need virtualized lines, IME, and bidirectional text.
- Plan accessibility from the start.

## 16. Input

- Pointer events carry pressure and tilt, plus capture and focus.
- A command and shortcut system of named actions shared by menus, keys, and the builder.

## 17. Roadmap

1. Node pool, handles, flex layout, software renderer, one platform backend, rects and text.
2. Core widgets, focus, events with listeners, dirty and damage tracking, shadow-copy checker.
3. Text system and virtualized list.
4. Runtime schema, ZON loader, widget registry, hot reload.
5. Canvas modes, redraw policies, GPU backend.
6. Form generation and wizards.
7. Builder app.
8. Docking and multi-window panels, tabs, tree view, text editor widget, accessibility.
9. C facade over the finished Zig API (`src/capi/`, header, C smoke test).

Status (see `README.md` for detail): steps 1 and 2 are done; step 3 has the text system, the single-line field, and the editor core with syntax highlighting (the virtualized list and model interface are not built); commands and scoped shortcuts, which this list did not name, are done. Steps 4 to 9 have not started.

## 18. Risks and Open Questions

- Text, IME, and accessibility are the largest risks.
- Do not start with the GPU backend.
- Which portable GPU path to pick first for native-pass mode.
- Exact event-polling semantics for apps that poll slower than the frame rate.
- Re-entrancy rules for the nested modal loop.
- Zig 0.17 specifics (std changes, build system, async) need verification against the real release.

## 19. Draw List, Painters and Themes

The draw list is a flat, append-only buffer of fixed-size C-style tagged records, and widgets get their look from swappable painters.

- **Record format:** each command is a tagged union with one named payload per kind, kept fixed-size. Variable-size data (text runs, path points, gradient stops) lives in side arrays that commands reference by offset and length.
- **Shapes:** filled rectangle, rounded rectangle with per-corner radii, stroked rectangle, line, circle or ellipse, and general path fill and stroke.
- **Content:** text run, image or texture quad with a source rect, and nine-slice image.
- **State:** push and pop clip, transform, and opacity. Rectangular clips are cheap; arbitrary-shape clips come later.
- **Effects:** box shadow and gradients. Blur-behind is deferred past the first version.
- **Paints:** every fill takes a paint, a small tagged union of solid color, linear gradient, radial gradient, or image pattern, so each shape command gets all fill types without duplicate commands.
- **Coordinates:** floats in logical pixels. The renderer applies the scale factor, so widgets never think about DPI.
- **Resources:** the backend owns real GPU and memory resources (textures, buffers, vertex arrays), and the engine only holds opaque handles. The application owns its windows. Whether the application owns strings is still undecided.

### Painters and themes

- **Split:** a widget's behavior (hover, press, focus, click, keyboard activation) stays in the widget. Its appearance comes from a painter, a function that takes the widget state, its rect, and its style, and emits draw commands.
- **Three levels of change:** tweak style values (colors, radii, padding, borders); swap the painter for a radically different look with identical behavior and callbacks; write a custom widget only when the behavior itself differs.
- **Themes:** a theme is a table of styles, metrics, and painters keyed by widget type and variant (such as primary or danger). A widget resolves its look from the current theme, then applies per-widget overrides on top.
- **Global switch:** changing the theme swaps the table and marks every node paint-dirty.
- **Metrics:** the theme also supplies padding, minimum size, and border widths that feed measurement, and a painter may optionally override the measure step.

## 20. Text Pipeline and Editor Core

Text is shaped once, cached, and drawn from an atlas, and the editor stores its document in a piece table with a separate reversible command layer.

- **Goal:** buttery-smooth typing on old, low-powered integrated-graphics hardware. Monospace is the editing default; proportional UI fonts must also work.
- **Pre-shaped glyphs:** the draw list carries glyph ids and positions, not raw text. Shaping happens once in the text system and is cached, so typing reshapes only the changed line.
- **Monospace fast path:** simple lines skip real shaping. A run is a start position, a cell width, and a list of glyph ids, and the renderer computes each quad by column. Lines with ligatures, wide characters, emoji, or right-to-left text fall back to the full shaper.
- **Glyph atlas:** bitmap glyphs rasterized at exact pixel size, keyed by font, glyph id, size, and subpixel bucket. Shelf packing into pages of about 1024 by 1024, several pages before eviction of least-recently-used entries. Grayscale coverage first, with a separate RGBA atlas for color glyphs later.
- **Subpixel positioning:** a per-run setting. Whole-pixel snapping for monospace editor text, a few subpixel steps for proportional UI text.
- **Batching:** all glyph quads in a frame go into one vertex buffer and as few draw calls as possible.
- **Other speed levers:** virtualized lines so only visible lines are laid out, damage rects so one keystroke repaints one line, and incremental syntax highlighting off the UI thread.

### Document storage

- **Piece table:** the original file is never copied, so huge files open instantly (memory-mapped). The piece list sits in a balanced tree that caches line counts, and line starts live in a separate index so line lookup never scans text.
- **Reversible commands:** every edit goes through one public edit function as a command that carries everything needed to undo it. A delete command keeps the removed text, so history never points into the piece table and survives compaction or a backend swap.
- **Transactions:** related commands group into one undoable step (typing a word, a multi-cursor edit), closed on a pause, a cursor jump, or an edit-type change. Each carries the selection before and after.
- **Cursor movement is not undoable.** Undo restores text and puts the cursor back where the edit was.
- **Change records:** each committed edit emits a record with the affected offset range and line range. The highlighter, line index, and renderer damage tracking all subscribe to it.
- **Selections:** a sorted list of anchor and head ranges. A single cursor is a list of length one, so multi-cursor needs no special case.
- **Future uses of the command log:** macros, collaborative editing, saved undo history.
- **Storage interface:** keep storage behind a small interface so a gap buffer can serve simple text fields while the piece table serves the editor.

## 21. Layout Lengths and Sizing

Every sizing field takes one `Length` type, and a node's size is its preferred size resolved to a number, then clamped between min and max.

- **Length type:** a small C-compatible tagged union (a tag plus a float) used for min, max, basis, padding, margin, and gap. Variants: pixels (logical, float), percent of the parent's content box, auto (size to content), fill (take remaining space), and fit-content (shrink-wrap children, clamped by constraints). Zig helpers like `px(100)` and `pct(10)` keep call sites readable.
- **Percent traps:** percent is relative to the parent's content box, after padding. If the parent is fit-content, a percent child has no answer, so it is treated as auto and a debug warning is emitted.
- **Later extension:** a calc-style variant holding a percent part and a pixel part (for example 50 percent minus 20 pixels).
- **Clamp rule:** resolve the preferred size to pixels, then clamp it between min and max in absolute terms. Example: a sidebar at 20 percent of the parent, min 150 pixels, max 360 pixels, holds 150 in a small window and caps at 360 on a 4K screen.
- **Conflicts:** if min is greater than max, min wins, so a node is never smaller than its minimum.
- **Grow and shrink:** every child starts at its resolved, clamped basis. Leftover space is shared by grow factors, and overflow is taken back by shrink factors. A child that hits its min or max is frozen at that value and its share is redistributed. Repeat until nobody new is frozen, at most one pass per child.
- **Dragging:** a draggable divider simply sets the node's basis in pixels, and the same clamp keeps it within bounds.
- **Box model:** min and max apply to the border box, so padding is included.
- **Flex scope for v0.1:** row and column direction, basis, grow, shrink, gap, and start, center, end, and stretch alignment on both axes. Wrapping and grid come later. Stack, absolute, split panes, and scroll containers sit outside flex, with scroll containers exposing virtualization hooks.

## 22. Platform and Render Stack

SDL3 provides windows and input, SDL3 GPU is the default renderer, and a software rasterizer is the guaranteed fallback.

- **Windowing and input:** SDL3 behind a small interface of our own (create and destroy windows, poll events into our event structs, DPI and scale, clipboard, cursors, text input and IME rectangles, timers and vblank sync). A native backend can replace it per platform later without touching the engine.
- **Default renderer:** SDL3 GPU, which targets Vulkan, Metal, and Direct3D 12 behind one API. The native-pass canvas mode then exposes a single device type instead of one per backend.
- **Hardware reach:** SDL3 GPU does not cover older hardware that only reaches Direct3D 11 or OpenGL. The software rasterizer is the guaranteed path for those machines, and an OpenGL backend may be added later.
- **Text interface:** other SDL libraries (TTF, image) are acceptable, but text stays behind our own interface so the glyph cache and monospace fast path are under our control. FreeType or SDL's TTF layer can sit underneath it.
- **Build:** Zig imports the SDL C headers directly, and SDL can be linked statically through the build system.
- **Shaders:** the build only needs to receive named shader binaries per backend, so the source language is an implementation detail. Start with HLSL converted per platform by SDL\_shadercross. Zig-compiled SPIR-V shaders are a later, minor-priority exploration that would remove the need for an external shader compiler; the state of Zig's SPIR-V backend for graphics shaders in 0.17 must be verified before relying on it.
- **Shader needs are small:** textured quads, rounded-rectangle coverage, gradients, and glyph blits.

## 23. Focus, Input and Accessibility

Each window has exactly one focused node, key events route through capture, target, and bubble before reaching scoped shortcuts, and every node reserves an accessibility role and label from the start.

- **Focus model:** one focused node per OS window, held as a generational handle. If the node is destroyed, focus falls back to the nearest focusable ancestor. Nodes opt in with a focusable flag and an optional tab index. Default tab order is tree order.
- **Focus scopes:** containers can form scopes. A modal dialog traps Tab inside itself, and a dock panel remembers its last-focused child.
- **Arrow navigation:** widgets like toolbars, menus, and lists handle arrows internally and count as one tab stop.
- **Focus state:** focus-in and focus-out events fire, and focus is exposed in the widget's `out` block so painters can draw a focus ring.
- **Key routing order:** a raw-key-mode node (such as a game canvas) gets keys first, except a small reserved escape set. Otherwise the event travels capture, focused node, then bubble. If nobody handles it, it goes to the shortcut system.
- **Shortcuts:** key chords map to named actions, the same registry used by menus, buttons, and the builder. Bindings are scoped (widget, panel, window, app) and the most specific scope wins. Multi-key chords such as Ctrl+K then Ctrl+C are supported from the start, and bindings live in data so users can remap them.
- **Text and IME:** key events and text events are separate. During composition the platform sends preedit text, which the editor draws underlined at the cursor, and the widget reports its caret rectangle so the candidate window appears in the right place.
- **Pointer capture** is independent of keyboard focus. Clicking a focusable node focuses it.

### Accessibility (reserved for v0.1)

- **Reserved fields:** every node carries an accessibility role and an optional label and description. Built-in widgets set defaults, custom widgets and canvases must declare theirs, and debug builds warn about unlabeled interactive nodes.
- **Derived tree:** the accessibility tree is derived from the node tree and built lazily, only when an assistive technology connects. Dynamic state comes from the widgets' `out` blocks, and screen-reader actions become ordinary synthetic events.
- **Editor text:** the editor widget will expose a text-range interface over the piece table and selection list.
- **Platform bridges:** deferred. A cross-platform library such as AccessKit is the likely route, to be verified for its current state and how it links from Zig.

## 24. Performance and Smoothness

Smoothness comes from consistent frame times and low input latency, so the design avoids slow outlier frames and keeps the core single-threaded.

- **Frame budget:** target 8 ms per frame for 120 Hz. Stutter is almost always an occasional slow frame, not a slow average.
- **No dynamic allocation in the hot path (a hard rule):** nothing touches the general allocator while a frame is built. Use a per-frame arena, fixed-size draw records, and pre-sized buffers.
- **Cached vertex data:** swapchain back buffers are not reliably preserved, so the frame is generally redrawn in full and damage rects save CPU work, not GPU work. Each repaint boundary keeps its geometry cached in a GPU buffer, so an unchanged panel costs one draw call and no CPU time, and typing rebuilds only the edited line's quads.
- **Single-threaded UI core:** the node tree, layout, events, and draw-list building stay on one thread. Highlighting, file I/O, search, indexing, image decoding, and compiler or language-server communication run on worker threads, post results into a queue the UI thread drains at the start of each frame, and wake the loop with a custom SDL event. A separate render thread is skipped for now because it adds a frame of latency; plain-data draw lists keep the option open.
- **Low-latency presentation:** one or two frames in flight, input sampled as late as possible before building the frame, and mouse motion coalesced.
- **No glyph stalls:** pre-rasterize ASCII at startup, batch atlas uploads into one transfer per frame, and never evict mid-frame.
- **GPU scrolling and animation:** scroll by changing a translate on a cached buffer with no relayout. Drive animations from real frame timestamps and animate only transforms and opacity so nothing triggers layout.
- **Measure from day one:** a frame-time overlay and a ring buffer of per-frame costs split into layout, build, and submit, plus the handler time-budget warning. Test on the weakest target machine early.
- **Implementation priority:** cached vertex data, the frame budget with no hot-path allocation, and the threading model come first, because they are the hardest to retrofit.
