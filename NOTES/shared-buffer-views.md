# Same file open twice (two views, one buffer): research notes

Status: **not started** (assessed 2026-11-02; deferred by the user). Difficulty: medium to hard,
concentrated in the editor core.

## Why it cannot be done today
1. Policy (trivial): `Documents.open` finds an existing doc by path and just activates its tab.
2. Structure (the real work): each `CodeEditor` owns its whole `Editor` (`src/editor/editor.zig`,
   ~1200 lines: `doc: Document`, `sel: SelectionSet`, `undo_stack`/`redo_stack`, `saved_id`,
   `tab_width`, `auto_indent`). A second tab today would be an independent copy: edits would not
   appear in the other view and saving would clobber.

## What it needs
- **Split Editor into a shared Buffer and per-view state.**
  Buffer: `Document` (piece table), undo/redo stacks, `saved_id`/modified marker, `version`, and the
  mapped-file / `Indexer` state (now on `CodeEditor`: `mapped`, `indexer`).
  Per view: `SelectionSet`, scroll_x/y, folds, `Highlighter`, decorations (owners 0-7: find uses 0,
  LSP diagnostics use 1), preedit, hooks, blink. ~85 `self.editor.` refs in `code_editor.zig`
  plus ~37 reaches into `.editor.doc` / `.core()` in the IDE layer.
- **Change notification becomes multi-consumer.** `Document.changes` is drained once per frame by
  its single `CodeEditor.update` (`clearChanges`). Needs a version-stamped log with a cursor per
  view, trimmed to the oldest. Consumers: highlighter `onChange`, `remapDecorations`, `remapFolds`,
  find-bar matches.
- **Map other views' selections/folds through each edit.** `Editor.replaceRanges` already has a
  `.map` selection mode (see `SelectionMode`); reuse it for every other view on every edit.
- **Shared undo.** `Entry` stores `before`/`after` selections of the editing view. Rule needed:
  undo from either view undoes the buffer's last edit and restores the cursor in the view that asked.
- **Lifetime / IDE layer.** Refcounted buffer. `Documents.Doc` splits into buffer-doc (path, dirty,
  save, LSP didOpen once) and views (dock panels). Closing a view asks about unsaved changes only
  for the last view. `on_edit`/`on_change` hooks fire only in the editing view: need a buffer-level
  signal so other views repaint and so LSP didChange / designer sync / diagnostics fire once.
  Also: `Documents.pathChanged`/`closeUnder`, `ide/session.zig` (file list becomes view list),
  tab title bullet (shared dirty), `Designer` attach, `ZigCompleter` per-editor dirs, `FindBar`
  (per view is fine), `LspAssist` (per-editor docs keyed by `*CodeEditor`).
- **Commands.** "Split Right", "Split Down", "Open in New View" using `Dock.dockSplit`.

## Suggested stages (tests green after each)
1. Extract Buffer (text, undo, saved marker) from `Editor`; no behaviour change.
2. Multi-consumer change log; move highlighter/decorations/folds onto it.
3. Cross-view selection and fold mapping; shared undo with the rule above.
4. `Documents` into buffers + views; lifetime rules; LSP/session/rename handling.
5. Commands, menu items, polish.
Risk is in stages 1 and 3 (editing semantics). Needs new tests: two cursors editing one text,
undo across views, selections/folds after edits in the other view, closing one of two views.

## Rejected shortcut
A read-only mirror view, or an independent copy synced periodically: quick, but breaks undo and
save and does not give real "two cursors, one buffer".
