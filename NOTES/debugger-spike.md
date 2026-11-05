# Comptime debugger spike (CT-0) - results

Date: 2026-11-04. Zig 0.17.0 (source tarball, sha256 `b6c7f172...8abd` verified against
ziglang.org/download/index.json). Everything lives in `~/.cache/zigui-ide/zigct/`
(tarball, `src/zig-0.17.0`, `out-baseline`, `out-zct`). Patch: `tools/zigct/patches/0.17.0/0001-ct0-spike-trace-hook.patch`
(~127 changed lines: `src/zct_hook.zig` new, small edits to `Sema.zig`, `main.zig`, `lib/std/zig/AstGen.zig`).

## Verdict: GO

A patched 0.17.0 compiler prints every comptime statement boundary (`file:line:col`, frame depth)
and the value of every live local, including `comptime var`s that change, structs, arrays,
slices and enums, for the unit being analyzed. Run it as
`ZCT_TRACE=1 zigct build-obj FILE -fno-emit-bin -j1 --zig-lib-dir ~/.zvm/0.17.0/lib --cache-dir D --global-cache-dir D2`.

## Numbers
- Build: 65-70 s clean with the installed 0.17.0, no LLVM, Debug, 8 cores; 40 s incremental. Binary 450 MB (Debug).
- Patch: ~127 lines. Hook cost when disabled: not measurable (one branch; 8.80 s vs 8.85 s on a file that pulls std).
- Enabled with printing every statement and all locals to stderr: 15.3 s vs 8.8 s for 10.7k statements (std included).

## Assumptions
| # | Result |
|---|---|
| A1 | Confirmed. Sema interprets ZIR; inline calls re-enter `analyzeBodyInner` (`analyzeInlineCall`) with `sema.code`/`sema.func_index` switched; `comptime var` is a `comptime_alloc` owned by one Sema instance. |
| A2 | Confirmed (Sema/Zcu/InternPool are in `src/`, not std). |
| A3 | Confirmed: `-j1` gave 1 thread for the whole run (default: 8). |
| A4 | Confirmed: `zig build -Dno-lib -Dno-langref -Dversion-string=0.17.0` (the tarball has no `.git`, so the version must be given). `-fno-emit-bin` runs Sema only. Build with `ZIG_LIB_DIR=<tarball>/lib` when std is patched (the compiler is otherwise compiled against the installed std). |
| A5 | Mostly. `analyzeBodyInner` handles `dbg_stmt`/`dbg_var_val`/`dbg_var_ptr`, backward branches go through `emitBackwardBranch`, errors through `failWithOwnedErrorMsg`, inline calls via `block.inlining`. **But AstGen emits no `dbg_stmt`/`dbg_var_*` inside comptime scopes** (`emitDbgNode`, `emitDbgStmt`, `addDbgVar` return when `gz.is_comptime`), so statements of a `comptime {}` block were invisible (only calls showed). Fix: a global `AstGen.zct_emit_comptime_dbg` that disables those three early returns; it is part of the patch. ZIR gets bigger, so zigct needs its **own cache dirs** (never share ZIR cache with the real compiler). Not done yet: `dbg_arg_inline` (function parameters are not listed as locals), memoized comptime calls (a repeated identical call is not re-evaluated, so it is not stepped), type-construction hooks (entry points exist: `resolveStructLayout`, `resolveStructDefaults`, `resolveUnionLayout`, `resolveEnumLayout`, `ensureLayoutResolved`). |
| A6 | Confirmed with a catch: `Value.fmtValueSema(sema)` prints values; pointers need the Sema variant (`fmtValue` panics on `opt_sema.?`). `comptime var` is a pointer: it must be read lazily through `Sema.pointerDeref` with the **declaring** Sema and block (read through another Sema instance panics: comptime allocs are per Sema). The hook keeps a stack of locals that shrinks when `analyzeBodyInner` returns. |
| A7 | Confirmed: `_ = @import("lib.zig");` in the root analyzes the file's container-level `comptime` blocks. |
| A8 | Confirmed: `_ = &lib.inFn;` in a root `comptime` makes Sema analyze the function body, including its inner `comptime` block (`comptime` unit vs function-owned `sema.func_index`). Generic functions still need arguments (not tried). |
| A9 | Entry points exist as above (`Sema/type_resolution.zig`); not hooked yet. |
| A10 | Not checked (type-builtin names). |
| A11 | Confirmed: `zig build --verbose` prints the complete `build-exe ... -M... --dep ...` command line of each artifact. Reproduce by capturing it (parse `-M`/`--dep`), then run zigct with `build-obj` plus those arguments. Not implemented. |
| A12 | Partly: with `ZCT_TRACE` nothing went to stdout (0 bytes) in a plain run; the compiler prints diagnostics and `@compileLog` to stderr. In `--listen=-` mode stdout carries the build protocol, but zigct will not run in that mode. Final DAP framing must own stdout. |

## Things learned
- Line numbers: `dbg_stmt.line` is relative; absolute = declaration's `src_line` (comptime unit or nav) or, inside a function, `navSrcLine(owner_nav) + lbrace_line`, plus 1 for display. Verified against sample files.
- Stop at an error before unwinding works: `failWithOwnedErrorMsg` runs while all locals and frames are still live (`@compileError` and the 1000-branch quota both observed).
- Statements show twice for calls and for `while` (`emitDbgStmtForceCurrentIndex`); dedupe on (file, line, col) per step.
- Frame depth = number of `block.inlining` hops; the function name is `inlining.func`.
- Scope filter: Sema evaluates a lot of std comptime code (>10k statements before the user's file). A filter by file (project vs std) is needed from the start, as planned.

## Next (CT-1)
Real hook interface (pause loop that reads DAP on stdin), stack of frames with names and call sites, `dbg_arg_inline`, block targeting via a synthetic root, a build script that downloads/verifies/patches/builds into the cache, golden transcripts.
