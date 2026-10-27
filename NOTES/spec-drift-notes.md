# Spec drift notes

Audience: Claude Code on Spencer's desktop. Purpose: where the repo has drifted
from the original design (`Zig UI Toolkit Design Document.md`, sections 1-24),
what is a deliberate or acceptable deviation, and what is worth correcting.

How this was produced: a read-only look at commit `95150d2` ("working hello
world", about 16k lines) by Claude, which also wrote the original spec and the
first baseline drop. It used file reads and `grep`, not a compiler or test run.
`ui.zig` (2.6k lines) was skimmed, not read in full. **Verify a claim in code
before acting on it.** "Not found" means a search came up empty, not proof of
absence.

Companion docs: `docs/zig-first-refactor.md` (the extern-to-Zig-first plan) and
`CLAUDE.md`. Section 3 (ABI rule) and the section 6 `extern` sketch in the
design doc are **superseded** by that plan, so they are not counted as drift
below.

## Summary

The core, input, text, and editor work is faithful to the spec and often goes
further (commands and shortcuts, a real editor widget, syntax highlighting,
a software renderer). The drift is concentrated in three places:

1. **The builder-friendliness thread has not started.** No runtime schema, widget
   registry, ZON loader, forms, or builder, and widgets are hand-wired one by one
   in `ui.zig`. This was the spec's main differentiator, and each new
   hand-wired widget makes retrofitting it more expensive.
2. **Rendering is still a free function, not a backend interface.** The spec's
   backend contract, SDL3 GPU, cached geometry, and damage tracking do not exist
   yet. Painters return a stopgap `Visual`, not draw commands.
3. **Canvas and frame scheduling are absent**, along with raw-key mode and
   pointer lock, which affect input routing and the event loop.

Smaller items are in the table. Most of what is missing is already listed in the
README's "Known gaps"; the ones the README does **not** call out are marked
**(new)**.

## Matches the spec (keep as is)

- Generational handles, chunked pool with stable addresses (`handle.zig`,
  `pool.zig`).
- Node tree, dirty categories, relayout and repaint boundaries, intrusive layout
  queue (`tree.zig`). Dirty flags are a categorical bitset, as agreed.
- `Length` and resolve-then-clamp (min wins), flex freeze-and-redistribute,
  border-box sizing, circular percent falls back to auto (`length.zig`,
  `flex.zig`, `layout.zig`).
- Shadow-copy checker gated on Debug/ReleaseSafe, `dirty_map`, strict mode.
- Events: capture/target/bubble, lazy listener table, interactive bit set by
  pointer listeners, immediate dispatch with destroys deferred, polling flags that
  share the callback's event path, monotonic `click_count` (`event.zig`,
  `dispatch.zig`, `button.zig`).
- Focus, Tab order, `focus_in`/`focus_out`, key events separate from text events,
  `textInputRect` for IME placement; commands and scoped, chorded, remappable
  shortcuts (four scopes, most specific wins).
- Pre-shaped glyph runs, monospace ASCII fast path, atlas with 1024px shelf pages,
  4 subpixel buckets for proportional text and whole pixels for monospace, ASCII
  prewarm, eviction only of pages not used this frame.
- Editor: piece table (treap with cached counts), reversible commands independent
  of buffers, transactions, cursor movement not undoable, change records feeding
  the highlighter, sorted multi-selection, gap buffer for single-line fields.
- Text ownership: toolkit copies widget text; backend-owned text resources.
- No watchdog thread (removed per Spencer); single-threaded core.
- Platform shim uses its own event and window types and carries a window id, so
  multi-window needs no API change.

## Drift, by severity

| # | Spec | Repo | Severity | Suggested action |
| --- | --- | --- | --- | --- |
| 1 | §12-13: one widget declaration drives checker, inspector, ZON loader, forms; schema + widget registry | Only `dirty_map` exists. No events/child-slot declarations, runtime schema, registry, or ZON. `ui.zig` has a per-widget pool, create function, and setters for each of 4 widgets. | **High (new)** | Do the generic widget interface from refactor phase 5 *before* adding more widgets. Then start the runtime schema generator (comptime reflection of `Props` to descriptors). |
| 2 | §22, §19: backend contract (begin frame, submit draw list with damage rect, texture create/destroy, atlas upload, present), backend owns resources, SDL3 GPU default | `software.render(fb, list, opts)` is a free function; SDL shim presents a software framebuffer. No `Renderer` interface, no GPU path, no shader pipeline. | **High** | Define the renderer interface now with software as the first implementation, so the GPU backend slots in. Atlas pages already track a dirty flag for upload. |
| 3 | §19: painter takes state, rect, style and **emits draw commands**; optional measure override | `ButtonPainter` returns a `Visual` (background, border, radius). Only buttons have a swappable painter; label/field/editor colors are fixed theme values. `paint.zig` calls this a stopgap. | **High (new)** | Change painters to emit into the draw list (or a small painter context) so "radically different looks" work without a new widget. Make painters swappable per widget type. |
| 4 | §9: Canvas widget with 3 surface modes, `redraw_policy` (on_demand/continuous/fixed_hz), pointer capture, grab-all, raw-key mode before shortcuts, pointer lock | `Role.canvas` exists; nothing else. Pointer capture on press exists. The event loop only wakes for caret blink via `nextWakeMs`. | **High** | Add a Canvas node with draw-list mode first, a `redraw_policy` field the loop honors, and raw-key mode in key routing (before shortcuts). Decide this before the SDL3 GPU work, since it shapes the loop and input routing. |
| 5 | §4, §24: repaint-boundary geometry cache, damage rects, redraw only what changed | `paint.build` rebuilds the whole draw list whenever anything is dirty. The software renderer accepts a `damage` rect, but nothing computes one from dirty nodes. | Medium | Compute damage from dirty/painted nodes, and cache per-repaint-boundary draw records so an unchanged panel replays without rebuilding. Required for the "buttery on weak hardware" goal. |
| 6 | §24: frame-time overlay, ring buffer of per-frame costs (layout/build/submit), handler tracing, handler time-budget warning | None found. | Medium (new) | Add a tiny `FrameStats` ring buffer and optional overlay, and a debug-only handler timer. Cheap now, hard to justify later. |
| 7 | §24: no dynamic allocation in the hot path (a hard rule) | Layout scratch buffers grow then reuse; `DrawList` is fixed-size. But `CodeEditor` paint calls `text.shape(..., self.gpa)` per visible line with `catch break`/`catch continue`, and layout/paint return `!void`. Probably alloc-free in steady state, but nothing enforces it and OOM is swallowed. | Medium (new) | Add a test that runs several steady-state frames under a counting or failing allocator and asserts zero allocations after warmup. Stop swallowing errors silently. |
| 8 | §5: single pass, constraints down, sizes up; text measured through a width-constrained callback | Two phases (`measure` bottom-up from `Node.intrinsic`, then `place` top-down). Leaves report a fixed intrinsic size, so no wrapping and no constraint-dependent text. | Medium | Decide: update the spec to the two-phase model, or add a width-constrained measure callback (needed for wrapping, multi-line labels). README already lists the callback as a gap. |
| 9 | §8: `makeClickable` helper (focusable, keyboard activation, accessibility role) | Not found. Pointer listeners set `interactive`; nothing sets focusability, key activation, or role. | Medium (new) | Add the helper so a label can act as a link or button. |
| 10 | §23: unlabeled-interactive-node warning in debug builds; derived accessibility tree hook; editor text-range interface | `role` and `label` fields reserved and set. No warning, no derived-tree hook. `label` is unowned (README notes it). | Medium | Add the debug warning now (small). Make `label` owned or interned to settle the strings question for the node. |
| 11 | §23: focus scopes (modal trap, per-panel memory), tab index, arrow-key groups, raw-key mode, IME preedit | Tab order is tree order only; none of the others (README gap 4). | Medium | Focus scopes before modals/dialogs/wizards; preedit before real IME use. |
| 12 | §19: draw commands include circle/ellipse, path fill/stroke, image quad, nine-slice, box shadow, push/pop transform, blur-behind (later) | Fill/stroke rect, rounded rect, line, clip, opacity, glyph run. Paints: solid, linear, radial. | Medium | Add transform and image quad first (canvas and icons need them), then shadow and path. |
| 13 | §19: theme keyed by widget type and variant, per-widget overrides on top, global switch marks everything paint-dirty | Variant colors only for buttons; no `setTheme`; no per-widget override path found. | Medium | Add `Ui.setTheme` that marks all nodes dirty, and a per-widget override layer. |
| 14 | §20: text shaped without a record per glyph for monospace runs (start, cell width, glyph ids) | Positions still emitted per glyph (README gap). | Low-Medium | Do it with the GPU backend; it mainly cuts CPU write volume. |
| 15 | §20, §24: syntax highlighting incremental and **off the UI thread** | Incremental and on-demand for visible lines, but synchronous on the UI thread. | Low (acceptable now) | Fine while lexing one dirty line per keystroke. Revisit when a large paste or open stalls a frame; the Highlighter is already change-driven. |
| 16 | §20: files open instantly via memory-mapping; piece table borrows the original | Demo reads the whole file (`readFileAlloc`, 32 MB cap) and scans for newlines. Spencer values instant opening of massive files. | Medium | Add an mmap-backed original and move the newline-index scan off-thread, as README already suggests. Raise the priority. |
| 17 | §14: model interfaces for collections (lists, trees, tables) | None; the demo's sidebar is a column of buttons. | Medium | Define the model interface before building a list/tree widget. |
| 18 | §10: panels as reparentable subtrees; dock layout as data; multi-window | Tree has one root and one `focused`; the SDL shim is window-id aware. | Low (planned post-0.1) | Keep new code from assuming a single global tree or window. |
| 19 | §22: SDL statically linked via the build system | `build.zig` finds SDL3 through `pkg-config` (system library). | Low | Fine for development; revisit for distribution. |
| 20 | §11-13: forms from structs, wizards, ZON UI files, builder | Not started. | Planned | Blocked on item 1 (schema and registry). |
| 21 | §8: mouse-motion coalescing (§24: coalesce mouse motion, late input sampling) | Each motion event calls `pointerMove` in the demo loop; no coalescing found. | Low | Coalesce to the latest position per frame when the GPU path lands. |
| 22 | §12: keymap and bindings "live in data" (ZON) | Keymaps are a custom text format (`ctrl+k ctrl+c = edit.comment`). | Low (acceptable) | Keep; add a ZON form later if the builder wants one. |
| 23 | §2: layers depend only downward | `ui.zig` imports widgets, editor, text, layout, input together; `core/` also contains `ui.zig`, which depends on `widgets/` and `text/`. | Low | Consider moving `ui.zig` out of `core/` (for example `src/ui/`) so `core/` really has no widget knowledge. |

## Where the roadmap order drifted

The spec's roadmap put runtime schema, ZON loader, and registry (step 4) and
canvas modes and the GPU backend (step 5) before forms and the builder
(steps 6-7). The repo instead built the editor, syntax highlighter, commands, and
shortcuts, which serve the IDE goal and are good work, but they did not advance
the builder or canvas. That is a reasonable call for an IDE-first project. The
risk is cost: every widget wired by hand now has to be touched again when the
registry arrives. So the single most valuable course correction is item 1.

## Stale documentation in the repo

- `README.md` "Status" still says "Foundation layer only", and "Known gaps"
  item 2 says "only Button exists", but label, text field, and code editor exist.
- The README layout block closes its code fence before the `src/render/`,
  `src/editor/`, `src/text/`, and `src/platform/` lists; `shadow.zig` and
  `draw_list.zig` sit under the widgets heading.
- The design doc in the repo is a copy of the spec and still contains section 3
  (extern boundary rule) and the `extern` Button sketch in section 6. Update both
  when refactor phase 7 runs, and tick off roadmap items that are done.
- README "Decisions encoded so far" bullets that describe extern state blocks and
  `Setter methods live on Ui` are superseded by the Zig-first plan.

## Suggested order for course correction

Do these *after* (or interleaved with) the Zig-first refactor phases, keeping the
test suite green:

1. Generic widget interface plus `Ui.add` (item 1, refactor phase 5).
2. Painters that emit draw commands, theme switch, per-widget overrides (items 3, 13).
3. Renderer interface with the software backend as implementation (item 2).
4. Canvas node with `redraw_policy` and raw-key mode (item 4).
5. Frame stats, handler timer, zero-allocation steady-state test (items 6, 7).
6. Damage rects and per-boundary draw-record caching (item 5).
7. `makeClickable`, unlabeled-node warning, owned labels, focus scopes (items 9-11).
8. mmap-backed document open (item 16).
9. Runtime schema generator, then forms/wizards, then ZON and the builder (item 20).
10. SDL3 GPU backend and shader pipeline (item 2), then monospace run records (14).

## Intentional deviations to record in the spec

If Spencer agrees, update the design doc to match these rather than reverting
the code: the two-phase layout (item 8, unless a constrained measure is added),
the synchronous highlighter (item 15), the text keymap format (item 22), and
`pkg-config` SDL linking during development (item 19).
