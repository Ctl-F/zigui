# Plan: from workbench to IDE

Status: planning. Nothing below is built unless it says "exists". Update this file
as items land (and move finished items into `README.md` "Decisions encoded so far").

## 0. Ground rules

**Three layers, one direction of dependency.** Code goes in the lowest layer that
makes sense; a lower layer never imports a higher one (extend `tools/check_boundary.zig`
to enforce it).

| Layer | Where | What belongs |
|---|---|---|
| **Framework** (`zigui`) | `src/core`, `src/widgets`, `src/editor`, `src/text`, `src/render`, `src/platform` | Anything another application could reuse: widgets, the editor engine, text search, popups, a terminal emulator widget, process/PTY plumbing, thread-to-UI wakeups. No knowledge of Zig, projects, or LSP. |
| **IDE services** (`zigide`, new `src/ide/`, no UI) | `src/ide/` | UI-free logic specific to being an IDE: project model, file walking, Zig source indexing, the LSP client, build-output parsing, refactoring engine. Testable headless. Imports `zigui` only for small shared types (never widgets). |
| **IDE app** (`examples/workbench.zig` grows into `ide/main.zig`) | `ide/` | Wiring: panels, menus, commands, keymap, settings, the builder integration. The only place that knows both the framework and the services. |

The builder already sits between layers: the builder itself is framework (it edits UI
documents), but "which handler does this event call" is IDE knowledge, so the builder
gets an **interface** the IDE implements (section 5).

**Threading.** The UI core stays single-threaded. Background work (search, indexing,
LSP and process I/O) runs on worker threads that never touch the tree; they push
results into a mutex-protected queue and call `Ui.wake`. The UI thread drains the
queues in a frame hook. One small framework piece covers this (section 1.3).

**Every item ships with**: unit tests (headless where possible), a docs page or
section under `docs/`, a README "Decisions" line, and for UI pieces a screenshot
check through `ZIGUI_SCRIPT`.

## 1. Framework work the IDE items depend on

Do these first or alongside; several are useful on their own.

### 1.1 Non-focus-stealing popups and tooltips (framework)
Completion lists, hover docs and signature help must appear over the editor
**without** taking keyboard focus (today's `Menu` pushes a focus scope). Add a
`Popup` primitive: an absolute node on the root layer anchored to a rectangle,
clamped to the window, flips above/below, optional scroll, dismissed by Escape or a
click elsewhere, and given the key events the *owner* chooses to forward (the editor
forwards Up/Down/Enter/Tab to the completion list). `Menu` and `Select` could be
rebuilt on it later. Plus `Tooltip` (delay, hover-intent) on the same layer.

### 1.2 CodeEditor extension points (framework)
The editor must stay language-agnostic but exposes hooks the IDE fills:
- **Decorations**: ranges with a style (squiggle under, background, inline
  ghost text, gutter icon) keyed by an owner id, set/cleared in bulk
  (`setDecorations(owner, []Decoration)`), kept correct through edits by the
  document's change records. Diagnostics, find matches, bracket match, "current
  word" highlights, and fold placeholders all use it.
- **Providers** (callback structs, async-friendly with a request id):
  `CompletionProvider`, `HoverProvider`, `DefinitionProvider`; the editor asks, the
  provider answers now or later via `editor.deliver(request_id, result)`.
- **Events**: `on_caret_moved`, `on_change` (already), with the incremental change
  record so the LSP client can send `didChange` deltas.
- **Gutter**: pluggable gutter columns (line numbers exist; add fold arrows,
  diagnostics icons, breakpoints later).

### 1.3 Background work (framework)
A tiny `Worker`/`Channel` utility: spawn a thread, a bounded queue of results,
`drain(ui)` called each frame, `ui.wake()` on push. Used by find-in-project, the
indexer, the LSP reader, and process readers. Rules documented once.

### 1.4 Processes and PTYs (framework, platform-specific)
- `ProcessRunner` over `std.process.spawn` (exists in Zig 0.17 with piped
  stdin/stdout/stderr and `cwd`): captured streams, exit status, kill. For builds,
  runs, and LSP servers.
- `Pty` (Linux/macOS: `openpty`; Windows: ConPTY later) for an interactive terminal.
  Lives in `src/platform/`.

### 1.5 File dialogs, watching, settings (framework/platform)
Open/save/pick-folder via SDL's dialog API; a file-change watcher (inotify /
FSEvents / ReadDirectoryChanges; polling fallback); a settings store (ZON files,
layered user/project) and keymap persistence (the keymap text loader exists).

## 2. Projects (IDE app + services)

**Services (`src/ide/project.zig`)**: a `Project` is a root directory with: detected
kind (`build.zig`/`build.zig.zon` present), a settings file (`.zigide/project.zon`:
tab width, exclude globs, run configurations, LSP command), the set of open
documents, and recent-project history in the user settings. File enumeration respects
excludes (`.git`, `zig-cache`, `zig-out`).

**App**: *Files* panel (a `TreeView` filled lazily from the file system, watching for
changes, context menu: new file/folder, rename, delete, reveal); open documents as
tabs in editor groups (`Dock` + `TabPanel`; dirty markers, close prompts); *Open
folder* / recent projects on the File menu; layout and open files restored per
project (needs dock layout serialization, section 8).

Milestone M1: open a folder, browse, open/edit/save several files in tabs, restore
the session.

## 3. CodeEditor features

Classified by where the code lives.

| Feature | Layer | Notes |
|---|---|---|
| **Soft-tab backspace** (erase to the previous tab stop when only whitespace precedes the caret; Shift+Tab unindents) | Framework (`editor.zig`) | Small and self-contained: do it first. Uses `tab_width`. Undo-grouped as one step. |
| **Find / replace in a document** | Framework | A `search` module (literal first; whole-word, case, then regex via a small engine or `std.Io.Reader`-free matcher) producing match ranges, rendered as decorations; a `FindBar` widget (query, replace, toggles, count, next/prev, replace all as one undo step). Ctrl+F/H, F3. |
| **Find across project** | Services + app | Walker + the framework search module on worker threads, streaming results into a results panel (`TreeView`: file nodes, line children, click to open at line). Cancels when the query changes. Honors excludes; binary-file skip; max result cap. |
| **Code folding** | Framework | A fold model (ranges over lines) with a visible-line mapping that the painter, caret movement, scrolling and line numbers all use (virtualized painting already works per visible line, so the mapping is the main change). Fold providers: indentation (default), brace/`{}` matching for Zig/C, later LSP `foldingRange`. Gutter arrows, `...` placeholder via decorations, commands (fold/unfold/all), state kept by the IDE per file. |
| **Suggestions overlay** | Framework (popup, provider API) + services (sources) | See below. |
| **Language server integration** | Services + app | See below. |
| **Zig std indexing independent of LSP** | Services | See below. |

### 3.1 Suggestions overlay (offline and online)
Framework: the completion popup widget (on the 1.1 popup), `CompletionProvider`
interface, trigger rules (identifier chars, `.`, manual Ctrl+Space), filtering/ranking
by typed prefix (fuzzy), item kinds/icons, detail + doc side pane, accept with
Tab/Enter, snippet insertion with tab stops (a small snippet engine), and result
merging that tolerates providers answering late.
Services supply the providers: **offline** (keywords and builtins from the language
table, words in open buffers, snippets, the std index) answers in the same frame;
**online** (LSP) answers asynchronously and its items replace/merge into the open
popup. The popup shows offline results immediately and refines when the server
responds, so a slow or missing server never blocks typing.

### 3.2 Zig std indexing without a language server
Services (`src/ide/zigindex.zig`), no UI. Uses `std.zig.Ast.parse` (available in
0.17) over `<lib_dir>/std/**/*.zig` (found with `zig env`) and over the project's own
files. Produces an in-memory (later memory-mapped on-disk cache keyed by mtime/size)
index of declarations: namespace path, name, kind (fn/const/type/field/test), `pub`,
doc comment, signature text, file + line. Resolves the common member-access chains
purely syntactically: `std.mem.` → the namespace `mem`, `@import("...")` aliases,
`const x = std.ArrayList(u8)` one step of alias following. It will not do full type
inference (that is the server's job); when the server is up its answers win and the
index fills gaps and provides hover/definition for std when the server lags. Background
indexing on a worker; incremental reindex of changed files; a command "Rebuild std
index". Also the source of "go to definition" into std files (opened read-only).

### 3.3 Language server (LSP) client
Services (`src/ide/lsp/`), transport + protocol, UI-free:
- Transport: spawn the server with `ProcessRunner` (stdio), reader thread, `Content-Length`
  framing, JSON via `std.json`, request ids, cancellation, timeouts, restart policy.
- Lifecycle: `initialize` (client capabilities limited to what we implement),
  `didOpen/didChange (incremental)/didSave/didClose`, `shutdown`.
- Features in order: diagnostics (→ decorations + a Problems panel), completion
  (+ resolve), hover, signature help, definition/declaration, references, rename,
  formatting, code actions, document symbols (→ outline panel), folding ranges, then
  semantic tokens (layered over our own lexer highlighting).
- Position encoding: LSP uses UTF-16 offsets; the editor core indexes bytes/columns in
  code points, so a conversion layer lives here, with tests.
- Server discovery/config per language: command + args in settings; for Zig, `zls`
  (not installed on this machine; the IDE must degrade gracefully and say so).
App: status-bar server state, output log panel for protocol traffic (debug).

## 4. Terminal and process output

- **Output panel** (build/run, no PTY): `ProcessRunner` with stdout and stderr captured
  separately and styled differently, exit code and duration, a Stop button, ANSI colour
  handling, and **clickable diagnostics**: `file:line:col: error: ...` lines parsed by
  `src/ide/buildout.zig` (Zig's format first) open the file at the spot and also feed
  Problems and editor decorations.
- **Terminal panel** (interactive): a VT/xterm **emulator** in the framework
  (`src/term/`: escape-sequence parser, screen grid with attributes, scrollback,
  alternate screen, resize, mouse reporting later), a `TerminalView` widget (paint from
  the grid on the Canvas or as text runs, selection, copy/paste, key encoding including
  modifiers, IME), and a `Pty` from 1.4. Shell = user's `$SHELL`; working directory =
  project root; several terminals as tabs; "run in terminal" for run configurations.
  Stdin/stdout/stderr "capture" for a plain run uses the Output panel; the terminal
  merges them as a real terminal does.
- This is the largest single piece after the LSP client; build the emulator test-first
  (feed byte streams, assert grid contents) before any UI.

## 5. UI builder → event → handler → refactor

Goal: bind an event in the builder to an existing function, generate a new function,
and move or rename it later with every reference updated.

**Where things live.** The document already stores `on = .{ .click = "confirm" }`
(framework). The mapping from action name to Zig function lives in code
(`actions.put(gpa, "confirm", .bind(&app, App.onConfirm))`). To make that editable by
tools, the IDE owns a **generated binding file** per project (default
`ui_actions.zig`, marked "generated, do not edit"): one registration per action name,
regenerated from a manifest (`.zigide/actions.zon`: action name → `Type.function`,
file, signature kind). Hand-written handlers stay in the user's files.

**Builder interface (framework, small):** `Builder.Options.handlers: ?HandlerProvider`
with `list(widget_event) -> []Candidate`, `create(name, event_kind) -> Result`,
`reveal(name)`, and change notifications. Without a provider the Events tab behaves as
today (a free-text action name). The Events section becomes: a drop-down of matching
existing handlers (filtered by the event's callback signature), "New handler..."
(name suggestion from widget id + event), "Go to handler", "Unbind".

**IDE services (`src/ide/handlers.zig`):**
- *Discover*: parse project `.zig` files with `std.zig.Ast`; candidates are functions
  whose signature matches `fn (*T, *zigui.event.Event) void` (receiver type free);
  record file/line/container.
- *Generate*: insert a stub into a chosen container (struct) or file via the same
  `Editor` edit path as typing (so it is one undo step and the buffer stays live),
  regenerate the binding file, open the new function.
- *Rename*: rename the function declaration and every reference. With LSP up use
  `textDocument/rename`; without it, an Ast-based rename restricted to
  same-container references and the binding file, with a preview list the user
  confirms. Updates the manifest and every `.zon` document that binds the old action
  name only if the *action name* changes too (action name and function name are
  separate; the dialog offers both).
- *Move*: relocate the function to another container/file (text move with its doc
  comment), fix qualifiers at call/bind sites, regenerate the binding file. Refuse
  with a clear message when it cannot be done safely (captures, private decls).
- All refactors produce a **workspace edit** (list of file edits) applied atomically
  through open buffers (undoable as one step) and shown in a preview panel first.
This design also gives a path to "rename widget id" refactors and finding all uses of
an id in handlers (`inst.find("id")` strings).

## 6. Suggested order

Dependencies first, quick wins early, the two big pieces (LSP, terminal) after the
foundations they share.

1. **Quick editor wins** (framework): soft-tab backspace; find/replace + `FindBar`;
   indentation-based code folding. *(Days; all headless-testable.)*
2. **Background work + processes** (framework 1.3/1.4 without PTY) and the **Output
   panel** with clickable Zig diagnostics (services `buildout`). Immediately useful:
   "build" from inside the workbench.
3. **Projects** (section 2) and **find in project**.
4. **Popup/tooltip primitive, decoration API, provider API** (1.1, 1.2), then the
   **completion overlay** with offline sources and the **Zig std index** (3.1, 3.2).
5. **LSP client** (3.3), features in the order listed; online completion plugs into 3.1.
6. **Terminal**: emulator (test-first), then Pty, then the widget and panel.
7. **Handler wiring and refactors** (section 5); needs projects (2), the Ast index
   (3.2), and ideally the LSP rename (5) but works without it.
8. **Dock layout/session persistence**, settings UI, keymap UI (the workbench's
   quality-of-life layer) interleaved as needed.

## 7. Risks and open questions

- **Zig API churn** (0.17): `std.process.spawn`, `Io`, and `std.zig.Ast` are used
  directly; wrap them thinly so a bump touches few files.
- **UTF-16 vs byte offsets** in LSP: easy to get subtly wrong; dedicated tests with
  multi-byte text.
- **Folding and virtualized painting**: the fold mapping touches caret movement,
  selection rendering, scroll extents and hit testing; do it before adding more
  editor features that assume 1 line = 1 row.
- **Large files / performance**: decorations and folds must be range-indexed, not
  per-line scans; reuse the line index.
- **PTY portability**: Windows needs ConPTY; plan the `Pty` interface so a platform
  implementation can be added without touching the widget.
- **Server availability**: zls is not installed here; features must degrade (offline
  index + our lexer) and say what is missing.
- **Multi-window (deferred)**: floating panels stay in-window; terminals and editors
  floated to OS windows wait for the platform multi-window work.
- **Where does `ide/` live**: proposed as `src/ide/` (services, no UI) plus an `ide/`
  app directory with its own build step; confirm.

## 8. Items not yet scheduled
Debugging (DAP), version control panel, task runner/run configurations UI, snippets
manager, theming UI, multi-cursor LSP edits, remote development, plugin API. Dock
layout serialization is needed by projects (section 2) and is small: the dock model
(`groups/splits/floats`) is already a plain tree.
