# Zig-first refactor plan

Audience: Claude Code running on Spencer's desktop, with a real Zig 0.17
compiler. This plan was written from a read-only look at the repo (commit
`95150d2`, "working hello world") by Claude in a workspace with **no Zig
compiler**. Every snippet below is an untested sketch. Compile, run
`zig build test`, and adjust.

## 1. Decision (stated by Spencer)

- **Zig is the primary API.** The core uses ordinary Zig types: slices,
  optionals, tagged unions, error unions, `std.mem.Allocator`, methods, comptime
  generics.
- **C interop stays, as a facade.** A separate layer wraps the Zig API with
  `extern` types and `callconv(.c)` functions. The core never imports it.
- **C goes through functions only.** No raw struct access from C. Direct
  read/write of widget `props` and `out` is a Zig-only feature.
- **The C facade is deferred.** Finish the core Zig library first (phases 0-7
  below). The facade (phase 8, design in section 7) waits until then. In the
  meantime, just do not add new C-convention code to the core.
- **`Text` stays a small wrapper type** (not a bare `[]const u8`).
- **`Ui` can live on the stack or the heap.** `Ui.init` keeps returning `Ui` by
  value. The price is a "do not move" rule that the docs must state loudly.
- This **supersedes** design doc section 3 ("The ABI Boundary Rule": app-visible
  types are `extern`) and the `extern struct` widget sketch in section 6. The
  earlier "middle path" (extern at the boundary, Zig inside) is dropped.

Why: the extern rule forced `callconv(.c)` handlers with `?*anyopaque` plus
`@ptrCast(@alignCast(...))` boilerplate, `Text{ptr,len}` instead of slices,
setters hung off `Ui` instead of the widget, and flat "field means different
things per kind" records. All of that is cost on the Zig side to pay for a C
surface that now lives in its own layer.

## 2. Where things stand (snapshot)

About 16k lines, 304 tests (README), builds on Zig 0.17.0. Modules: `core/`
(tree, layout, flex, input, dispatch, shortcuts, commands, `ui.zig` at ~2.6k
lines), `widgets/` (button, label, text_field, code_editor, theme), `editor/`
(piece table, document, selection, editor, syntax, highlighter), `text/` (atlas,
shaping, stb backend), `render/` (software rasterizer, png), `platform/sdl.zig`.

Extern/C-convention footprint (the thing to unwind), by grep:

- `extern struct`: `Handle`, `Rect/Vec2/Size/Color`, `Edges`, `Visual`,
  `Length`, `Paint`, `Glyph`, `Command`, `Event`, `Listener`, `Text`, and every
  widget block (`Button`, `Label`, `TextField`, `CodeEditor` plus their
  `Props`/`Out`).
- `callconv(.c)`: about 35 functions. `event.Handler` is the shared callback type
  (~9 references): widget `handleEvent`s, input handlers, command handlers, and
  the demo's callbacks.
- `?*anyopaque` user-data pairs sit next to every callback field
  (`on_click_user`, `on_change_user`, `Command.user_data`, `Node.user_data`).

Already Zig-native and **not to be touched** by this refactor: `editor/*`,
`text/*` (font backend vtable uses Zig-CC function pointers, fine),
`render/software.zig` internals, `core/pool.zig`, `core/tree.zig` algorithms,
`core/layout.zig`/`flex.zig` algorithms, `platform/sdl.zig`, `third_party/`.

## 3. Target architecture

```
C / C++ host ──► include/zigui.h ──► src/capi/*  (extern types, export fn,
                                         │         status codes, handles only)
Zig app ────────────────────────────────►│
                                         ▼
                     zigui core (plain Zig): core/ widgets/ editor/ text/ render/
                                         ▲
              platform/sdl.zig, text/stb.zig (separate modules, as today)
```

Rules:

1. `extern`, `callconv(.c)`, `export`, and C-style `?*anyopaque` user-data live
   **only** in `src/capi/` (and the existing C-import modules `platform/` and
   `text/stb*`). Add a check (see phase 6) so this stays true.
2. Small value types stay `extern` because they cost nothing and the facade can
   pass them directly: `Handle` (8 bytes), `Rect`, `Vec2`, `Size`, `Color`.
   Keep their size asserts.
3. The facade converts at the edge ("lower on the way in, lift on the way out").
   The core never sees a C type.
4. Unchanged project rules: single-threaded UI core, no allocation in the frame
   path (`DrawList.Storage` allocated once), shadow checker on in Debug and
   ReleaseSafe only, generational handles for anything that can be destroyed.

## 4. Type-by-type changes

| Today | Target | Notes |
| --- | --- | --- |
| `Handle` extern | unchanged | Used by both sides. |
| `Rect/Vec2/Size/Color` extern | unchanged | Facade passes by value. |
| `Edges`, `Visual` extern | plain structs | Drop extern; facade gets its own `zui_edges`/`zui_visual` mirrors. |
| `Length` extern (`unit`+`value`) | `union(enum) { px: f32, percent: f32, auto, fill, fit }` | Keep `Length.px(10)` / `.pct(20)` constructors; they work as decl literals (`.width = .px(100)`). Update `@sizeOf` test. Consumers: `style`, `layout`, `paint`, `ui`, demos. Facade mirrors as `{unit, value}`. |
| `Paint` extern | `union(enum) { solid: Color, linear: Linear, radial: Radial, image: Image }` | Only `solid` and `linear` exist today. |
| `Command` extern (kind + `a/b/params[4]`) | `union(enum)` with one named payload per kind | Fixes the "params[0] means width here, opacity there" convention. Keep records fixed-size and add a `comptime` assert on `@sizeOf(Command)` (pick a ceiling, e.g. 80). Consumers: `software.zig` (switch), `paint.zig`, `ui.zig` tests that read `c.kind == .glyph_run` / `.fill_rect` (use `c == .glyph_run`). `Glyph` can drop extern. |
| `Event` extern | plain struct | `text: []const u8` instead of `text`+`text_len`; `mods` as a `packed struct` of bools (keep `hasMod` helper or replace its callers); keep `handled`/`stopped`/`markHandled()`/`stopPropagation()`. Do this as its own commit; it touches every handler. |
| `Handler = *const fn(*Event, ?*anyopaque) callconv(.c) void` | `Callback` struct (see 4.1) | Replaces `Handler` + every `*_user` field. |
| `Listener` extern | plain struct `{ kind, capture, callback: Callback }` | Removal currently matches `(kind, callback fn, user_data)`; match on `(kind, callback.ctx, callback.call)`. |
| `Text` extern `{ptr,len}` | **decided:** keep a distinct non-extern wrapper | Do **not** make `props.text` a bare `[]const u8`: a user could assign a literal and the toolkit would later free it. A wrapper type that only the setters construct keeps ownership honest and still has `.slice()`. |
| Widget blocks `Button/Label/TextField/CodeEditor` + `Props`/`Out` extern | plain structs | Props use slices-in-wrapper, `?Callback`, enums without explicit int tags. Add a private back-pointer to `Ui` so methods work (4.2). |
| `Node.user_data: ?*anyopaque` | keep for now | Internal; consider a typed alternative later. |
| `commands.Command{handler, user_data}` | `run: ?Callback` | `registerCommand` takes an options struct (4.3). |
| `PaintHook{ctx, run}` | unchanged shape | Already Zig-CC; consider `Callback`-style `bind` for symmetry. |
| enums `Variant`, `Align`, `Font`, `EventKind`, `Phase`, `Key` with `(u32)`/`(u8)` tags | drop explicit int tags where nothing depends on them | `Key` and `EventKind` tags may be relied on by the SDL shim or the keymap parser; check before changing. The facade maps them to its own C enums anyway. |

### 4.1 Callbacks

Replace the `Handler` + user-data pair with one type. Sketch:

```zig
pub const Callback = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, ev: *Event) void,

    /// Marker so the shadow checker skips it (see section 6).
    pub const is_callback = true;

    /// Callback.bind(&app, App.onSave) where onSave is fn (*App, *Event) void.
    pub fn bind(ctx: anytype, comptime f: anytype) Callback {
        return .{ .ctx = ctx, .call = struct {
            fn thunk(c: ?*anyopaque, ev: *Event) void {
                f(@ptrCast(@alignCast(c.?)), ev);
            }
        }.thunk };
    }

    /// For callbacks that need no context: fn (*Event) void.
    pub fn fromFn(comptime f: fn (*Event) void) Callback { ... }
};
```

This removes all the `@ptrCast(@alignCast(user.?))` boilerplate (see
`examples/demo.zig`, `fn app(user)`). The C facade builds a `Callback` by
allocating a small box `{ c_fn, user }` (registration time, not a hot path) and
using a thunk that converts `*Event` to a `zui_event` and calls `c_fn`. It must
copy `handled`/`stopped` back afterward.

### 4.2 Widget API

Today setters hang off `Ui` because extern blocks hold no pointer to it
(`ui.setButtonText(b, ...)`). Target:

```zig
const save = try ui.add(.button, root, .{
    .style = .{ .width = .px(120) },
    .text = "Save",
    .on_click = .bind(&app, App.save),
});
if (save.out.clicked) { ... }          // polling, unchanged
save.setText("Saved") catch {};        // setter: copies, marks dirty
save.props.enabled = false;            // raw write: Zig only; shadow checker verifies
```

- `Ui.add(kind_or_type, parent, opts)` is generic over a widget type, building
  `Props` from an options struct with defaults. This likely collapses the
  per-widget `createButton`/`createLabel`/... boilerplate in `ui.zig`. Define a
  small comptime "widget interface" (`Props`, `Out`, `dirty_map`,
  `listened_kinds`, `handleEvent`, painter) so the future builder registry and
  the C accessor generator can reflect over it.
- Keep `Ui.setButtonText` etc. as thin wrappers during migration, then delete
  them once demos and tests use the methods.
- **Address stability (decided: keep `Ui.init` by value).** Widget slots store
  `ui: *Ui`, so the `Ui` must not move once the first widget exists. Both of
  these are fine:
  `var ui = try Ui.init(gpa);` on the stack, or `const ui = try gpa.create(Ui);
  ui.* = try Ui.init(gpa);` on the heap. Moving it afterward (returning it from
  a function, putting it in a growing `ArrayList`, copying a struct that embeds
  it) leaves widgets with dangling back-pointers.
  Make this impossible to miss:
  - A `DO NOT MOVE` block in the doc comment on `Ui` and on `Ui.init`, plus the
    README and the frame-protocol header in `ui.zig`.
  - A debug check: in Debug and ReleaseSafe (the same `shadow.enabled` gate),
    record `pinned: *Ui` on the first widget creation and `assert(self.pinned
    == self)` at the top of `update`, `layoutAndPaint`, and the creation
    functions. Compiles to nothing in ReleaseFast.
  - A test that the check stays quiet through normal create/update/layout use
    (a deliberate move cannot be tested safely).
  Note that tests already build `Ui` in heap-allocated harnesses (`Harness`,
  `TextHarness`), which is consistent with this rule.

### 4.3 Commands

```zig
try ui.registerCommand("file.save", .{ .title = "Save", .run = .bind(&app, App.save), .repeat = false });
```

## 5. Phases

Do these in order, one commit per phase, with `zig build test` green (304 tests,
adjusted as types change) and `zig build demo` still launching after each.

0. **Baseline.** Branch `zig-first`. Run `zig build test`; confirm 304 pass.
   Note the known noise: shadow-checker tests intentionally print `ui_check`
   warnings and a "failed command" line while exiting 0.
1. **Callbacks.** Add `Callback`; switch `Listener`, widget props, command
   registry, input handlers, shortcuts handler, demos. Remove all
   `callconv(.c)` and `*_user` fields from core. Update `shadow.isCallback`
   (section 6).
2. **Event cleanup.** `Event` to a plain struct (`text` slice, `Mods` packed
   struct). Separate commit.
3. **Widget blocks.** De-extern `Button/Label/TextField/CodeEditor`, `Props`,
   `Out`; `Text` wrapper; back-pointer; methods; keep `Ui` wrappers temporarily.
4. **Value unions.** `Length`, `Paint`, `Command` (+ `Glyph`, `Edges`, `Visual`
   de-extern). Update the software renderer's switch and every `kind` test.
5. **Creation API.** `Ui.add` plus options-struct `registerCommand`; migrate
   `examples/demo.zig` and `examples/dedit.zig` to it. This is the ergonomics
   payoff, so check the demos got shorter and clearer.
6. **Boundary check and `Ui` pin check.** Add a build step or test that fails if
   `callconv(.c)` or `export fn` appears anywhere under `src/core`,
   `src/widgets`, `src/editor`, `src/text`, `src/render`, or if `extern struct`
   appears there outside an allow-list (`Handle`, `Rect`, `Vec2`, `Size`,
   `Color`). Add the debug `Ui` pin assertion from section 4.2. Both are cheap
   and keep the refactor from regressing while the facade waits.
7. **Docs.** Replace design doc sections 3 and 6 (and the roadmap line on the C
   ABI), rewrite README "Decisions encoded so far" bullets that mention extern
   state blocks, and update the `Setter methods live on Ui` note. Add the loud
   "do not move the `Ui`" warning here too.
8. **C facade (deferred until the core Zig library is done).** New `src/capi/`
   module `zigui_c`, built as a static library plus `include/zigui.h`, plus
   `tests/c/smoke.c` run by `zig build c-test`. Design is in section 7. Do not
   start it as part of this refactor.

## 6. Gotchas to check as you go

- **Shadow checker and callbacks.** `shadow.isCallback` currently detects
  `*const fn` pointers (and optionals of them). A `?Callback` struct is neither,
  so the checker would compare it field by field and force a layout/paint dirty
  mark whenever a handler changes. Make `isCallback` also return true for any
  struct declaring `is_callback`. Add a test that changing a handler produces no
  warning.
- **Strings in props.** The checker already compares slices by content. If
  `Text` stays a wrapper struct, make sure `fieldEql` handles it (via a
  `slice()` decl or by recursing into its slice field).
- **Listener removal identity** changes with `Callback`; update
  `Tree.removeListener` and its tests. The C facade needs its own box lookup to
  remove a C listener.
- **Frame-scoped flags** (`out.clicked`) and the "callbacks and flags come from
  one event path" guarantee must survive the rewrite; keep the single
  `activate()` path in `button.zig`.
- **Deferred destroy during dispatch** and handle revalidation in `dispatch.zig`
  must keep working when callbacks become Zig-CC; do not shortcut it.
- **Tests that read draw commands** (`ui.zig`: `c.kind == .glyph_run`,
  `.fill_rect`, `c.paint.color`, `c.rect`) will need rewriting for the union.
- **Size asserts** in `handle.zig`, `geometry.zig`, `length.zig`, `draw_list.zig`
  encode ABI sizes. Keep them for `Handle/Rect/Color`; replace the others with
  intentional ceilings.
- **Do not let a Zig-only type leak into the facade.** Error unions become
  status codes, slices become pointer+length, optionals become nullable pointers
  or flags, tagged unions become tag+payload structs.

## 7. C facade design (deferred; keep for when the core is done)

Nothing in this section should be built yet. It is here so the core is shaped
to make the facade easy later.

Principles: opaque handles only, no struct pointers into the engine, explicit
lengths for every string (no NUL requirement), status codes for every fallible
call, one translation point per type.

- **Handles:** `typedef struct { uint32_t index, generation; } zui_handle;`
  (same layout as `Handle`). Widgets are addressed by their node handle; `Ui`
  needs a `widgetFor(node)`-style lookup per widget kind (it may not exist yet).
  `zui_ui` is an opaque pointer to a heap-allocated `Ui`.
- **Status:** `zui_status` enum (`ZUI_OK`, `ZUI_ERR_OOM`,
  `ZUI_ERR_INVALID_HANDLE`, ...) and `zui_last_error()` for detail.
- **Strings:** setters take `(const char *ptr, size_t len)` and copy. Getters
  return `(ptr, len)` valid until the next mutation of that widget.
- **Events and callbacks:** `zui_event` is an extern mirror of `Event`;
  `typedef void (*zui_handler)(zui_event *ev, void *user);`. Registration
  allocates the box described in 4.1.
- **Allocator:** `zui_config` optionally carries an allocator vtable
  (alloc/resize/remap/free **with alignment**) wrapped into a
  `std.mem.Allocator`; default is the C allocator (`link_libc`).
- **Setters/getters:** `zui_button_set_text`, `zui_button_set_enabled`,
  `zui_button_clicked`, `zui_button_click_count`, and the same family for label,
  text field, and code editor. Start by hand-writing button and label to prove
  the shape. Then generate the rest from the widget interface, either with
  `@export` using comptime-computed names (check it works on 0.17) or with a
  build-step generator that reflects over widgets and emits both
  `capi_gen.zig` and `zigui.h` (more verifiable and also produces the header).
- **Frame protocol:** `zui_pointer_move/button`, `zui_key`, `zui_text_input`,
  `zui_update`, `zui_layout_and_paint` (into a caller-provided RGBA buffer via the
  software renderer), `zui_end_frame`. A C host that owns its own window can
  then drive zigui with no SDL dependency.
- **Smoke test (`tests/c/smoke.c`):** headless: create `Ui`, add a button, feed
  a pointer click, assert `zui_button_clicked`, render to a buffer, assert it is
  not blank, destroy. Run it from `zig build c-test`.
- **Deferred past the first facade:** C custom widgets (extern vtable adapted to
  the widget interface plus `zui_draw_*` calls instead of writing draw records),
  docking, menus, forms from schemas.

## 8. Verify against real Zig 0.17 before relying on it

I could not check any of these:

- `@export(&fn, .{ .name = computed })` inside a `comptime` block.
- `std.mem.Allocator.VTable` shape for the C allocator adapter.
- `b.addLibrary(.{ .linkage = .static, ... })` and compiling a C test with
  `addCSourceFile` in `build.zig`.
- Decl literals for `Length` constructors (`.width = .px(100)`).
- Whether any header-emission support exists (assume not; use a generator).
- `@typeInfo` shape: README notes `field_names`/`field_types` replaced `fields`
  for structs in 0.17; the sketches here use older shapes in places.

## 9. Resolved questions and what is still open

Resolved by Spencer:

1. `Text` stays a small wrapper type.
2. `Ui.init` keeps returning by value (stack or heap both allowed); documentation
   and a debug assertion enforce "do not move".
3. The C facade waits until the core Zig library is done, so its scope (host owns
   the window versus widgets and events only) is not decided yet.

Still open: nothing blocking phases 0-7.
