# Which IDE files are real

There are two IDE implementations in this tree, and since round 73 the
shipped one is split across several files. This note exists because the
distinction is not obvious and has cost several rounds of work aimed at the
wrong file.

## The shipped IDE: `nython_ide.ny` and its chain (repository root)

`nython --ide` (and the binary started with no arguments) runs
`nython_ide.ny`. `launch_ide()` in `src/main.cpp` searches, in order:

    <binary_dir>/nython_ide.ny        <-- almost always wins
    <binary_dir>/../nython_ide.ny
    <binary_dir>/../examples/nython_ide.ny
    nython_ide.ny
    examples/nython_ide.ny
    ...

and exports `NYTHON_HOME` (the folder it found) and `NYTHON_EXE` (itself), so
the IDE finds its icons and the interpreter it runs programs with from any
working directory.

The IDE is one class, `NythonIDE`, built as an inheritance chain so that no
single file is too large for the parser and each has one concern:

| File | Class | Concern |
|---|---|---|
| `ide_core.ny` | `IDECore` | documents (`Doc`), open/save/close/revert, the command registry (~150 VS Code command ids) and the `_exec` dispatcher, editing commands |
| `ide_ops.ny` | `IDEOps(IDECore)` | background jobs (`BgProc`), multi-cursor, find/replace, Quick Input (palette, Quick Open, pickers, prompts), dialogs, Run, diagnostics, settings, workspace, explorer file operations, symbols, file watching, `developer.dumpState` |
| `ide_paint.ny` | `IDETheme`, `IDEPaint(IDEOps)` | layout and every painter: title bar/menus, activity bar, tabs, breadcrumbs, editor, minimap, panel, status bar, overlays. Paint methods allocate nothing per frame (see "Memory" below) |
| `ide_views.ny` | `IDEViews(IDEPaint)` | the side bar views: Explorer, Search, Source Control, Run and Debug, Extensions, Outline, AI |
| `nython_ide.ny` | `NythonIDE(IDEViews)` | state, input routing (mouse, keyboard, text), the frame loop, launch |

Models with no window, testable on both engines:

| File | What |
|---|---|
| `lib/ide_workbench.ny` | `CommandRegistry` (keys, chords, when-clauses), `HitMap`, `Frecency`, `QuickInput`, `LineEdit`, `Notifications`, `NavHistory` — `examples/vm_audit42.ny` |
| `lib/ide_scm.ny` | `GitRepo`, `LineDiff` (Myers diff for gutter bars) — `examples/vm_audit43.ny` |
| `lib/ide_debugger.ny` | `DebugSession`, the record-and-replay debugger over `nython --trace` — `examples/vm_audit44.ny` |
| `ide_editor.ny` | `EditorBuffer` (operation undo, grouped steps, indentation), `SyntaxHighlighter`, `detect_indentation` — `vm_audit36/37/43` |

Also imported: `ide_project.ny` (workspace tree), `ide_icons.ny` (Codicon
glyphs), `ide_workshop.ny` (language workshop panel), `lib/ide_toolchain.ny`
and `lib/ide_commands.ny` (terminal command line), `lib/ide_selection.ny`,
`lib/aiagent.ny`, `lib/gui_motion.ny`, and `lib/gui.ny` (Window, Renderer,
Font — through `ide_editor.ny`).

**Edit these files when changing the IDE.** `python3 tools/ide_lint.py`
checks the chain for names no class defines (Nython returns `none` for a
missing member instead of raising), reserved words used as names, and dead
clicks: commands with no `_exec` branch and click targets nothing handles.

### Verifying a change to the IDE

    python3 tools/ide_lint.py            # static: 0 unresolved
    python3 tools/ide_e2e.py             # drives the real IDE: N passed, 0 failed
    python3 tools/ide_memprobe.py --check  # memory kept per frame / key / scroll

`tools/ide_driver.py` launches the real IDE against the headless SDL3 stub
with a live input channel, clicks and types like a person, and reads back both
what was drawn (the stub's display-list capture, `tools/nyshot.py`, which can
also render a PNG) and what the IDE believes (`developer.dumpState`).

### Memory

The interpreter never frees a list, map, instance or string (`GC_NOTES.md`).
Anything a paint method or a keystroke handler allocates is kept for the rest
of the session, so: no container literals in paint methods (build them once),
caches keyed by a line's text rather than rebuilt per edit, native helpers
(`fuzzy_rank`, `file_mtime`) for per-character or per-candidate loops, and
`python3 tools/ide_memprobe.py` to hold the line. `NY_PROFILE_OUT=file
nython --ide` profiles the IDE itself, with objects and strings allocated per
function (`NY_PROFILE_SORT=alloc` sorts by them).

## `examples/nython_ide.ny` — a v3 demo, NOT shipped

Version 3.0. Around 2,400 lines. Kept as a smaller, self-contained example of
building an editor shell with `lib/gui.ny`, and exercised by the test sweep, but
it is not the product and is effectively never launched (the root file is found
first).
