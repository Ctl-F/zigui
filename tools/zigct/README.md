# zigct: the comptime debugger

`zigct` is the Zig 0.17.0 compiler plus a patch that lets a debugger watch Sema evaluate
`comptime` code. `zigct dap-comptime` speaks the Debug Adapter Protocol on stdin/stdout
(`src/ide/dap/zigct.zig` documents the `launch` arguments). The repository does not vendor the
compiler: `build.sh` downloads the official 0.17.0 source tarball, verifies its sha256, applies
`patches/0.17.0/*.patch` and builds it with the installed `zig` 0.17.0 (no LLVM, about a minute
in Debug; `ZIGCT_OPTIMIZE=ReleaseSafe` takes ~17 minutes and runs about twice as fast) into `~/.cache/zigui-ide/zigct/0.17.0/bin/zigct`.

What the patch does (see `patches/0.17.0/0001-zigct-comptime-debugger.patch`):

- `src/zct_hook.zig` (new): the frame/locals bookkeeping and the DAP server. When a stop is due,
  the compiler thread itself reads and answers requests until the client resumes (no threads,
  no locks; the compiler runs with `-j1`).
- `src/Sema.zig`: calls the hook at statement boundaries (`zirDbgStmt`), local declarations
  (`zirDbgVar`), body entry/exit (`analyzeBodyInner`, which is also how frames are found),
  backward branches and errors. One `if (zct.enabled)` test each when no session runs.
- `lib/std/zig/AstGen.zig`: AstGen normally emits no `dbg_stmt`/`dbg_var` ZIR inside comptime
  scopes; a flag makes it emit them. This changes the ZIR, so zigct must always run with its
  own `--cache-dir` (the protocol's `cacheDir`), never the real compiler's.
- `src/main.zig`: the `dap-comptime` subcommand (set-up handshake, then `build-obj -fno-emit-bin -j1`)
  and a `terminated` event before the process exits on compile errors. `ZCT_TRACE=1` prints the
  statements and locals to stderr instead (the CT-0 spike mode).

Porting to another Zig version means redoing these hunks; they are small on purpose. The
Zig compiler is MIT licensed; the license text ships in the tarball the script downloads.

Tests: `zig build test` runs the golden transcripts `test/ct/*.script` against
`~/.cache/zigui-ide/zigct/0.17.0/bin/zigct` (or `$ZIGUI_ZIGCT`) and skips them with a message
when it is not built. `ZIGUI_UPDATE_GOLDEN=1 zig build test` rewrites the `.golden` files; read
the diff before committing it.
