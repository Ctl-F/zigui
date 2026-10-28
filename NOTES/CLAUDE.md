# CLAUDE.md

Guidance for Claude Code working in this repo.

## What this is

zigui: a lightweight, retained-mode, cross-platform UI toolkit in Zig 0.17.0,
aimed at IDEs, editors, and paint programs. Design doc:
`Zig UI Toolkit Design Document.md` (sections 3 and 6 are being superseded; see
below). Status and decisions: `README.md`.

## Current direction: Zig first, C as a facade

Read `docs/zig-first-refactor.md` before changing public types. In short:

- The core API is idiomatic Zig (slices, optionals, tagged unions, error unions,
  `std.mem.Allocator`, methods, comptime). Do not add `extern struct`,
  `callconv(.c)`, `export fn`, or `?*anyopaque` user-data pairs outside
  `src/capi/` (and the existing C-import modules `platform/`, `text/stb*`).
- C interop will be a separate facade over the Zig API (opaque handles, setter
  and getter functions, status codes, `(ptr, len)` strings). C never gets raw
  struct access; raw `props`/`out` access is a Zig-only feature. **The facade is
  deferred until the core Zig library is done. Do not build it yet.**
- Keep `Handle`, `Rect`, `Vec2`, `Size`, `Color` as `extern` value types.
- Widget text uses a small wrapper type (`Text`), not a bare `[]const u8`, so
  ownership stays with the toolkit.
- **Do not move a `Ui` after creating widgets.** It may live on the stack or the
  heap, but widgets keep a pointer back to it. Never return it from a function,
  copy it, or store it in a container that can reallocate once widgets exist.
  Debug builds assert this.

## Documentation is part of the work

User-facing docs live in `docs/` (static HTML; start at `docs/index.html`). Every
new feature, widget, option, or behavior change updates them in the same change:
a widget gets its own page under `docs/widgets/` and a line in `docs/nav.js`.
Follow `docs/maintaining.html`. Fix any snippet whose API you changed.

## Commands

```
zig build test        # 304 tests at last count; no SDL needed
zig build demo        # needs SDL3 dev files (pkg-config sdl3)
zig build dedit       # demo editor
```

`zig build test` prints `ui_check` warnings and a "failed command" line from the
shadow-checker tests on purpose, while exiting 0. Run it after every change.

## Rules that must keep holding

- Single-threaded UI core. Worker threads post results to a queue drained at the
  start of a frame.
- No dynamic allocation in the frame path. `DrawList` capacity is fixed; allocate
  `draw_list.Storage` once.
- Shadow dirty-checker is on in Debug and ReleaseSafe only and compiles to nothing
  otherwise (`-Dui_checks`, `-Dui_strict`). Callback fields are skipped by it.
- Anything that can be destroyed is referenced by a generational `Handle`.
- Event callbacks dispatch immediately; destroys during dispatch are deferred
  to the end of the outermost dispatch.
- Widget strings are copied and owned by the toolkit; the app never frees them.
- Backends own GPU resources; the engine holds opaque handles.

## Working style

- One commit per refactor phase, tests green before each commit.
- Do not touch `src/editor/`, `src/text/`, `src/render/software.zig`, or
  `third_party/` unless a phase requires it; they are already Zig-native.
- Zig 0.17 is newer than much of what is written about it. When unsure about a
  std or build API, check the compiler's actual behavior or the std source
  instead of assuming; the refactor doc lists items that are still unverified.
- When behavior or a decision changes, update the README "Decisions encoded so
  far" and the relevant design doc section in the same commit.
