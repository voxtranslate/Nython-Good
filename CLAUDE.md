# CLAUDE.md — Nython Project Context

> **Resuming work in a new session? Read `HANDOFF.md` first.**
> This file describes the project as designed. `HANDOFF.md` describes it as it
> currently *is* — build instructions for the headless environment, the traps
> that have cost real time (two IDE files, dead code that looks live), the
> outstanding work in priority order, and how to verify a change.

## What is Nython

Nython is a Python-like interpreted language implemented in C++20, with its own lexer, parser, bytecode compiler, and virtual machine. Version **v0.2.1**.

## Repository Layout

```
nython/
├── src/                      ← C++ source files
│   ├── main.cpp              ← entry point, REPL, IDE launcher
│   ├── builtins/             ← 12 builtin dispatch modules
│   │   ├── core.cpp          ← print, len, str, int, type, range, ...
│   │   ├── math.cpp          ← abs, sqrt, sin, cos, pow, ...
│   │   ├── string.cpp        ← string_split, string_find, string_lower, ...
│   │   ├── io.cpp            ← file I/O, read_file, write_file, ...
│   │   ├── os.cpp            ← os_listdir, os_mkdir, os_exec, ...
│   │   ├── data.cpp          ← json_encode, json_decode, ...
│   │   ├── tensor.cpp        ← tensor ops for nytorch
│   │   ├── network.cpp       ← http_get, http_post, sockets
│   │   ├── audio.cpp         ← audio builtins (stubs)
│   │   ├── threading.cpp     ← thread_create, thread_sleep, mutex_*
│   │   ├── lang.cpp          ← lang_define_token, lang_eval, ...
│   │   ├── text.cpp          ← editor text services: symbols, syntax check,
│   │   │                        Myers diff, workspace search, folding, format,
│   │   │                        completion index (keeps the IDE's hot paths native)
│   │   └── gui.cpp           ← SDL3 GUI backend (38 gui_* functions)
│   └── ...                   ← Lexer, Parser, Value, GarbageCollector, etc.
├── include/                  ← C++ headers
│   ├── NythonExecutor.hpp    ← main executor, callBuiltin dispatch chain
│   ├── VirtualMachine.hpp    ← bytecode VM (~3800+ lines)
│   ├── Value.hpp             ← Value type system
│   ├── builtins/             ← 12 dispatch headers (gui.hpp, core.hpp, ...)
│   └── ...
├── lib/                      ← Nython standard libraries
│   ├── gui.ny                ← GUI widget library (150+ classes)
│   │                            NOTE: nython_ide.ny does NOT import this
│   ├── nyimgui.ny            ← immediate-mode core (after Dear ImGui)
│   ├── gui_motion.ny         ← easing curves, Flex layout solver, fuzzy match
│   ├── gui_piecetable.ny     ← piece-table buffer, operation-based undo
│   ├── icons.ny              ← 460 Codicon name → codepoint (class Icons_Codicon)
│   ├── ide_commands.ny       ← :cmd / >expr / @agent command line
│   ├── ide_toolchain.ny      ← real compile/run bridge for the IDE
│   ├── ide_selection.ny      ← multi-cursor selection model
│   ├── ide_inspector.ny      ← universal value inspector
│   ├── stdlib.ny             ← standard library
│   ├── argparse.ny, collections.ny, asyncio.ny, socket.ny, ssl.ny,
│   │   select.ny, selectors.ny, signal.ny, websocket.ny, threading.ny,
│   │   socketserver.ny, hashlib.ny, hmac.ny, base64.ny, secrets.ny
│   │                         ← Python's modules (round 77; `# nython: module`
│   │                            files run in a scope of their own)
│   ├── http/, urllib/        ← packages: http.client/server/cookiejar,
│   │                            urllib.request/parse/error
│   ├── nytorch.ny            ← ML framework entry point
│   ├── nytorch/              ← 17 nytorch sub-modules
│   └── ...                   ← network.ny, thread.ny, os.ny, etc.
├── nython_ide.ny             ← THE SHIPPED IDE ← --ide loads this. One class,
│                                NythonIDE, split across a chain of files:
├── ide_core.ny               ←   documents, command registry, _exec dispatcher
├── ide_ops.ny                ←   jobs, find, Quick Input, run, settings, watcher
├── ide_paint.ny              ←   theme + every painter (allocation-free)
├── ide_views.ny              ←   Explorer/Search/SCM/Debug/Extensions/Outline/AI
├── ide_tools.ny              ←   Code::Blocks side: build targets, bookmarks,
│                                folding, snippets, keymaps, wizard, tools
├── ide_editor.ny             ← EditorBuffer, SyntaxHighlighter
├── ide_icons.ny              ← icon set: Codicon glyphs, vector fallback
├── ide_project.ny            ← workspace / project model
├── ide_workshop.ny           ← language workshop panel
├── lib/ide_workbench.ny      ← CommandRegistry, HitMap, QuickInput, LineEdit, ...
├── lib/ide_scm.ny            ← GitRepo + LineDiff (Myers) for Source Control
├── lib/ide_debugger.ny       ← record-and-replay debugger over `--trace`
├── tools/                    ← ide_driver.py / ide_e2e.py (drive the real IDE
│                                headlessly), ide_lint.py, ide_memprobe.py,
│                                nyshot.py (frame capture → PNG), sweep.py
├── assets/fonts/codicon.ttf  ← VS Code icon font (CC BY 4.0, licence beside it)
├── examples/nython_ide.ny    ← a v3 DEMO, not shipped — see IDE_FILES.md
├── examples/                 ← 356 example scripts
├── examples/gui_tests/       ← test_13 … test_27, GUI/IDE/language regressions
├── tests/                    ← test suites
├── thirdparty/sdl3-stub/     ← headless SDL3/SDL3_ttf/SDL3_image stand-in;
│                                Makefile uses it automatically when no real
│                                SDL3 is found (see "Development environment")
├── HANDOFF.md                ← START HERE when resuming
├── FIXES_v0.2.1.md           ← round-by-round log: every bug and why
├── GC_NOTES.md               ← memory management: refcounting + cycle collector (round 75)
├── MEMORY_NOTES.md           ← writing Nython the runtime can afford
├── IDE_FILES.md              ← which IDE file is real (this has bitten before)
├── nython.cbp                ← Code::Blocks project (SDL3 pre-configured)
├── Makefile                  ← Linux build (real SDL3 or the headless stub)
├── SDL3_SETUP.md             ← Step-by-step SDL3 setup guide
└── CLAUDE.md                 ← this file
```

## Build System

### Linux (Makefile)
```bash
make cli        # Build CLI binary (SDL3 required)
make            # Build IDE binary (SDL3 required)
./build/nython-cli --ide   # Launch IDE
```

Real SDL3 is used when found (`sdl3-config`/`pkg-config`, or the usual header
paths); otherwise the Makefile falls back automatically to the headless stub
under `thirdparty/sdl3-stub/` (see "Development environment" below) — no
manual step needed either way. Install real SDL3 with:
```bash
apt install libsdl3-dev libsdl3-ttf-dev libsdl3-image-dev
```
Force one or the other with `NYTHON_SDL_STUB=1` (stub) / `=0` (real, fails
loudly if not found) if auto-detection picks the wrong one.

### Windows (Code::Blocks)
- `.cbp` is pre-configured with SDL3 include/lib paths to `C:\SDL3\`
- Link libraries: `ws2_32`, `SDL3`, `SDL3_ttf`, `SDL3_image`
- Copy `SDL3.dll`, `SDL3_ttf.dll`, `SDL3_image.dll` next to `nython.exe`
- See `SDL3_SETUP.md` for detailed instructions
- The `.cbp` lists its units: **a new `src/**.cpp` must be added to it** (seven
  were missing after round 74 and the Windows build could not link).
- Command strings (`os_exec`, `os_run("...")`, `os_spawn("...")`, the IDE's git,
  build and tool commands) run through a POSIX `sh` when one is found - Git for
  Windows' (Source Control needs git anyway), MSYS2's, or `NY_SH` - else
  through `cmd.exe`. `os_shell()` says which.
- Tested from Linux without Windows: `tools/cross_windows.sh deps && tools/cross_windows.sh build`
  cross-compiles with MinGW against SDL3 built for Windows; `build-win/nywin`
  runs it under Wine and `python3 tools/sweep.py --bin build-win/nywin` sweeps it.
  The build takes its units, flags and libraries from `nython.cbp` itself
  (`tools/cbp.py`), so it builds exactly what Code::Blocks builds.
  `ARCH=i686` builds and runs the **32-bit** edition (w64devkit i686, 32-bit
  MSYS2) into `build-win32/`.
- **`python3 tools/cbp.py check`** (every sweep runs it) fails when a
  `src/**.cpp` is not a `<Unit>` of `nython.cbp` - a unit missing there links
  on Linux and fails only in Code::Blocks (it happened twice).
- `long` is 32 bits on Windows: never cast a Nython integer through `long`
  (use `int64_t`/`long long`, `intValue()`, `bigint_to_i64()`).
- 32-bit builds: `size_t` is 32 bits (never `>> 32` a `size_t`; keep hashes
  `uint64_t`) and there is no `unsigned __int128`.
- Write `"??="` in C++ string literals as `"?\?="` (a trigraph otherwise:
  a warning on every file that includes the line).
- Never use `__builtin_frame_address` in code that can be inlined into the
  engines (use `nycoro::stack_position()`). On Windows x64 it gives a large
  function a frame pointer whose XMM-save unwind info GCC records wrongly,
  so exceptions corrupt XMM registers or crash; `tools/pe_unwind_check.py`
  (run by the 64-bit cross build) rejects any such function.
- The project targets Vista (`_WIN32_WINNT=0x0600`): a newer Win32 API must be
  looked up with `GetProcAddress` (see `stack_limits` in `src/NyCoro.cpp`).
- It links with an 8 MB main stack (`-Wl,--stack,8388608`), as Linux gives;
  the PE default of 2 MB made deep recursion and nested generators stop early.

### Development environment (no SDL3 available)

Most dev/CI containers have no SDL3 and can't install it. The headless stub
committed at `thirdparty/sdl3-stub/` provides the SDL/SDL_ttf/SDL_image
surface `src/builtins/gui.cpp` actually calls, so everything builds and every
GUI/IDE test runs without a display — the Makefile picks it automatically.

```bash
rm -rf build && make cli && make        # ~2-3 minutes total
cp build/nython-cli ./ny_test
NY_STUB_AUTOQUIT=120 ./build/nython --ide    # IDE runs and exits cleanly
```

`NY_STUB_AUTOQUIT=<n>` makes the stub deliver one quit event after *n* empty
polls so event loops terminate; `NY_STUB_DPI_SCALE=<f>` fakes a HiDPI display,
following macOS/Wayland's model (`NY_STUB_DPI_MODE=points`, the default) or
Windows/X11's (`=pixels`). Full detail in `HANDOFF.md`.

### Real SDL3 in a container (round 75)

The stub is not the only option: `tools/build_sdl3.sh` builds the real SDL3,
SDL3_ttf (with HarfBuzz, as releases are) and SDL3_image into `/opt/sdl3`, and
the IDE then runs on a real X server, Xvfb, or SDL's offscreen driver - with
the same scripted-input / frame-capture test harness as the stub
(`src/builtins/gui_harness.cpp`), so the whole e2e suite runs against it:

```bash
tools/build_sdl3.sh
PKG_CONFIG_PATH=/opt/sdl3/lib/pkgconfig make cli BUILD=build-sdl NYTHON_SDL_STUB=0
PKG_CONFIG_PATH=/opt/sdl3/lib/pkgconfig make     BUILD=build-sdl NYTHON_SDL_STUB=0
Xvfb :99 -screen 0 1920x1080x24 &
NY_IDE_BINARY=build-sdl/nython NY_IDE_ENV="SDL_VIDEODRIVER=x11 DISPLAY=:99" python3 tools/ide_e2e.py
```

`NY_REAL_PIXELS=1` makes each `snap` also write a PNG of the real rendering.

### Key build flags
- `-DNYTHON_WITH_IDE=1` (default) — no-arg launch opens IDE; `=0` opens REPL
- SDL3 is unconditional — `NYTHON_HAS_SDL3` flag removed; guards removed from `gui.cpp`

## Architecture

### Builtin dispatch chain (NythonExecutor.hpp callBuiltin)
```
callBuiltin("gui_create_window", args, ctx)
  → dispatch_core()       → UNDEFINED (not handled)
  → dispatch_tensor()     → UNDEFINED
  → ...
  → dispatch_gui()        → Value(handle)  ← matches "gui_" prefix
```

Each `dispatch_*` function returns `UNDEFINED_VALUE` if it doesn't handle the name, and the chain continues to the next module.

### GUI pipeline
```
nython_ide.ny                     ← IDE application (2,110 lines)
  └── import "lib/gui.ny"        ← Widget library (12,932 lines, 150+ classes)
       ├── import nytorch         ← Registers tensor builtins (fast, no classes)
       └── calls gui_*()          ← 38 native functions
            └── src/builtins/gui.cpp  ← SDL3 always active
                 └── SDL3 API calls (SDL_CreateWindow, SDL_RenderFillRect, ...)
```

### SDL3 API usage (no OpenGL)
- `SDL_CreateWindow(title, w, h, flags)` — no x,y in constructor
- `SDL_CreateRenderer(win, NULL)` — no driver index or flags
- `SDL_FRect` (float) for all rendering, not `SDL_Rect` (int)
- `SDL_RenderLine`, `SDL_RenderPoint` — float coordinates
- `SDL_RenderTexture` replaces `SDL_RenderCopy`
- `SDL_DestroySurface` replaces `SDL_FreeSurface`
- `SDL_SetRenderVSync(ren, 1)` — replaces `SDL_RENDERER_PRESENTVSYNC`
- Event types: `SDL_EVENT_QUIT`, `SDL_EVENT_KEY_DOWN`, `SDL_EVENT_MOUSE_MOTION`, etc.
- `ev.key.key` not `ev.key.keysym.sym`
- `TTF_RenderText_Blended(font, text, 0, color)` — extra length param
- `TTF_GetStringSize(font, text, 0, &w, &h)` — replaces `TTF_SizeUTF8`
- `TTF_OpenFont(path, (float)size)` — size is float
- `IMG_Init()` not needed in SDL3_image

### Window constructor
```python
# gui.ny — Window(width, height, title)
var w = Window(1600, 960, "NythonIDE v3.0")
w.run(callback)   # callback(renderer, event) — custom render loop
```
- `x` and `y` default to `-1` (centered)
- `run(callback)` sends `"idle"` events when no SDL events (continuous redraw)
- Without SDL3: `create()` returns `false`, prints message, exits gracefully

### Event modifiers
```python
# Event class has ctrl, shift, alt booleans
if event.key == "p" and event.ctrl:
    spotlight.visible = true
```
SDL3 backend passes modifiers via `SDL_GetModState()`.

## Key Patterns & Gotchas

### Stale object files
At least one "bug" (SIGABRT) was caused by stale `.o` files. Always `make clean && make` after header changes.

### Header-only changes need forced recompile
After editing `NythonExecutor.hpp`: `touch src/main.cpp` then rebuild.

### Kwargs must be explicitly forwarded
Collecting kwargs at the call site is insufficient — they must be passed through to `callBuiltin` or they are silently dropped (e.g., `sorted(key=, reverse=)` bug).

### Closures capture by reference
Like JavaScript, closures in loops see the final value. Use factory functions for per-iteration capture:
```python
# BAD: all closures see i=4
while i < 5:
    def fn(): return i * i
    ...

# GOOD: each closure gets its own n
def make_fn(n):
    def inner(): return n * n
    return inner
```

### GarbageCollector lock bug (fixed)
Lines 77 and 228 in `GarbageCollector.cpp` had temporary locks that were immediately destroyed. Fixed to named variables (`gc_lock`, `dealloc_lock`).
The old `GarbageCollector` itself was removed in round 76 (unused since
round 75's `NyGC`/`VMGC`).

### IDE import weight
`nython_ide.ny` must NOT import `"lib/nytorch.ny"` (loads 220+ classes, causes OOM). The builtins are already registered via `gui.ny`'s bare `import nytorch`.

### Widget constructor signatures
These were aligned to match how the IDE calls them:

| Widget | Constructor |
|--------|-------------|
| Window | `(width, height, title)` |
| ActivityBar | `(x, y, w, h)` + `add_item(icon, label, active)` |
| Spotlight | `(x, y, w, h)` + `add_item(label, id)` |
| AutoComplete | `(x_or_w, y=0, w=0, h=0)` — works with 1 or 4 args |
| TabBar.add_tab | `(name, filename="", path="")` — works with 1 arg |
| TextInput | `(x, y, w, h, placeholder="")` — placeholder optional |
| FileTree | `(x, y, w, h)` + `add_node(path, label, depth, expanded, type)` + `node_count` |

## Test Suites (24 suites, all passing)

| Suite | Tests | Category |
|-------|-------|----------|
| test_vm | 12 | Core VM |
| test_vm2 | 48 | Core VM |
| test_vm3 | 27 | Core VM |
| test_vm4 | 57 | Core VM |
| test_vm_extended | 30 | Core VM |
| test_vm_stress | 37 | Core VM |
| vm_audit22 | 88 | Advanced patterns |
| vm_audit23 | 66 | Advanced patterns |
| vm_audit24 | 49 | Advanced patterns |
| vm_audit25 | 80 | Advanced patterns |
| vm_audit26 | 88 | Closures, generators, inheritance, walrus, etc. |
| vm_audit27 | 84 | enumerate start=, *args/**kwargs, try/else, string methods, isinstance, __repr__, callable classes, dict.items, chained comparisons |
| test_stdlib | 94 | Standard library |
| test_os | 25 | OS operations |
| test_gui | 1053 | GUI widget class logic |
| test_ide_smoke | 40 | IDE widget constructors |
| test_nytorch9 | — | ML agents |
| test_nytorch10 | — | ML distributed |
| test_nytorch11 | — | ML vision |
| test_nytorch12 | — | ML reinforcement |
| test_nytorch13 | 110 | ML LLM |
| test_nytorch14 | 151 | ML optimization |
| test_nytorch15 | 184 | ML cognitive |
| test_nytorch16 | 153 | ML pipeline |
| test_nytorch17 | 199 | ML device-agnostic |
| vm_audit42 | 73 | IDE workbench model: registry, chords, when-clauses, QuickInput, LineEdit |
| vm_audit43 | 52 | EditorBuffer undo groups/indentation/final newline, LineDiff, GitRepo |
| vm_audit44 | 46 | record-and-replay debugger, including a real `--trace` recording |
| vm_audit45 | 45 | JSON codec, print call form, list pop/insert, deep equality, file_mtime |
| vm_audit46 | 252 | OS layer: paths, files, file objects, typed errors, os_run/os_spawn, env, time, full-width ints, sys.argv |
| vm_audit47 | 153 | nytorch: kernels, autograd, Module/optimizers, XOR and a toy CNN, checked against PyTorch numbers and finite differences; one definition per class name |
| vm_audit48 | 143 | threads and synchronisation: mutex/rwlock/condition/semaphore/barrier/latch/atomics/channels/queues/futures/pools, deadlock detection, no lock convoys (rwlock too, round 76) |
| vm_audit49 | 52 | async/await: tasks, gather, wait_for, cancellation, deterministic order; tasks are coroutines (no OS thread per task, blocking inside a generator, per-task exception state) |
| vm_audit50 | 51 | `lib/thread.ny` over the native runtime |
| vm_audit51 | 52 | native editor text services (symbols, syntax check, diff, search, folding, format, completion index) |
| vm_audit60 | 284 | Python values and builtins: dicts, ints, formatting, operators, tuples, strings (same results under python3) |
| vm_audit61 | 33 | Nython-only value behaviour |
| vm_audit62 | 29 | tensor type promotion: integer results for integer-closed ops (NumPy's rule), floats otherwise, exact 64-bit sums |
| vm_audit55 | 4059 | memory: refcounting frees at once, cycles (self, pair, ring, closure over its instance, bound method on its instance, self-containing list/dict) collected, `__del__` once + resurrection, nothing reachable freed (2000-node graph), loops do not grow the heap, threads collecting concurrently, `weakref` |
| vm_audit52 | — | exceptions as objects: typed except across calls, finally/raise, with protocol, NameError/AttributeError/TypeError |
| vm_audit53 | — | classes: C3 MRO, super(), class bodies, properties, the operator and object protocols |
| vm_audit54 | — | comprehensions, match patterns, walrus, unpacking, generators, calls (`**d`, arity) |
| vm_audit56 | 120 | lazy generators: infinite ones with islice/take/zip/any, side-effect order, send/throw/close/GeneratorExit/finally, StopIteration.value, `yield from` (600 deep), genexps, `__iter__` generators, unpacking, errors, threads (same results under python3) |
| vm_audit57 | 212 | strict reads (AttributeError/KeyError), getattr/hasattr/setattr/delattr/get/setdefault, `?.` `?[` `??` `??=`, `undefined`, var/let/const/global/nonlocal scope rules in every context, suffix literals (round 75) |
| vm_audit63 | 59 | round 76: const/nonlocal/global checks (static, SyntaxError), lambda closures and defaults, print's argument order, error columns, lazy iterators |
| vm_audit64 | 26 | round 76: objects used as dict keys freed (cycles through keys too), suspended-generator cycles collected with their finally blocks run, bound builtin members freed |
| vm_audit65 | 149 | round 77: bytes/bytearray (literals, escapes, codecs, methods, bytearray mutation), builtin types as namespaces (same results under python3) |
| vm_audit66 | 33 | round 77: signals - handlers, SIGINT as KeyboardInterrupt, interrupted waits resuming (PEP 475), signal channels |
| vm_audit67 | 44 | round 77: modules with their own scope, from-imports, packages, async with/for/generators, asyncio, VM closures per call |
| vm_audit68 | 32 | round 77: sockets - TCP/UDP/IPv6/AF_UNIX, timeouts, makefile, select/selectors, errors, colorless I/O in tasks |
| vm_audit69 | 40 | round 77: sets and frozensets - typed keys, API, operators, subset comparisons |
| vm_audit70 | 79 | round 77: http.client/server, urllib, cookies, WebSockets (RFC 6455), TLS with a throwaway CA, network/webserver/sockets/clientserver libraries, math, hashlib |
| vm_audit71 | 97 | round 77: the command line on each engine (-c/-m/-i/-, sys.argv, SystemExit statuses, the prompt), argparse against python3's output, sys.stdin/stdout/stderr, print(file=), a running program's stdin (os_spawn(stdin=true), input requests), locals/globals/vars/dir, kwargs order |
| vm_audit72 | 56 | round 77: Python compatibility, passes under python3 too - starred displays, annotations, f"{x=}", slice objects, eval/exec/compile, complex, per-execution classes, collections, object/issubclass, __setattr__/__delattr__, threading.local, docstrings, positional-only parameters, keyword module names |
| vm_audit73 | 292 | round 77: itertools, functools, operator, heapq, bisect, copy, contextlib |
| vm_audit75 | 1004 | round 77: string, textwrap, pprint, csv, statistics, fractions, struct, calendar, uuid |
| vm_audit76 | 273 | round 77: fnmatch, glob, shutil, tempfile, pathlib, subprocess, platform, getpass, logging, unittest, queue |
| vm_audit77 | 274 | round 77: json, random (CPython's sequences for a seed), datetime, time, io, open(newline=) |
| vm_audit78 | 147 | round 77: re - Python's syntax and messages over a native engine immune to catastrophic backtracking (selective memoization) |
| vm_audit79 | 43 | round 77: class machinery, passes under python3 - annotations, PEP 487 (__init_subclass__, __set_name__), __new__, PEP 560/604 generics and unions, metaclasses, NotImplemented and reflected operators, __mro__/__bases__/__subclasses__ |
| vm_audit80 | 15 | round 77: type() gives type objects (type(5) is int, type(obj) is its class, x.__class__), equal to their legacy names on Nython; typeof(x) is the name |
| vm_audit74 | 124 | round 77: abc (ABCMeta, register, subclass hooks), numbers, collections.abc (all 26 ABCs, mixins, builtin registrations), singledispatch on ABCs and annotations |
| vm_audit81 | 116 | round 77: enum (EnumType metaclass, auto, Flag boundaries, functional API) and dataclasses (every parameter, field, KW_ONLY, InitVar, frozen) |
| vm_audit82 | 140 | round 77: typing (Union, generics, TypeVar, Protocol, NamedTuple, TypedDict, get_type_hints, check_type), types, inspect (signature, bind, getsource), keyword |
| vm_audit83 | 158 | round 77: weakref (callbacks, proxies, weak dicts, finalize), warnings (filters, catch_warnings, -W), traceback (real tracebacks, chains), linecache, atexit |
| tools/ide_e2e.py | — | the real IDE driven headlessly (run with python3) |

Run all: `python3 tools/sweep.py` — every `examples/test_*.ny`, `examples/*_test.ny`
(the older feature suites, stdlib_test/stdlib_v2_test included since round 75),
`examples/vm_audit*.ny` and `examples/gui_tests/test_*.ny`, on both engines,
failing on "N failed" output as well as on the exit code.

## Language changes since this file was written

These entries are now **fixed**; they are listed so old notes are not trusted:

- ~~C-style negative modulo~~ — now floor-modulo, `-7 % 3 == 2`, consistent with
  floor `//` on both engines.
- ~~32-bit integer overflow~~ — results were computed at full width and then
  truncated by a cast to `(int)`. `100000 * 100000` is now correct.
- `**` no longer demotes exact integers to double below 2^63.
- ~~EOF errors report `stdin:1:1`~~ — the lexer's `End` token always carried the
  right position; the parser just discarded it once it read past the last real
  token. Fixed in `Lexer::next()`/`curr()` (HANDOFF 5.6, closed).
- ~~`id()`/`hash()` as global functions~~ — registered as recognised builtins but
  never actually dispatched on either engine (`id(x)` read `undefined`/`0`
  regardless of `x`). The *method* form `obj.id()` (object protocol) already
  worked; the bare function form didn't.
- ~~VM: `//=` `**=` `&=` `|=` `^=` `<<=` `>>=`~~ — only `+= -= *= /= %=` were
  wired to an opcode; the rest silently NOP'd, so e.g. `x //= 5` replaced `x`
  with `5` (the divisor) instead of `x // 5`.
- ~~VM: `isinstance(x, list)`~~ (the bare builtin, not the string `"list"`) —
  always read `false`; only `isinstance(x, "list")` worked.
- ~~VM: `case _:`~~ — compiled as a comparison against an undefined variable
  named `_` instead of an always-match wildcard, so it never ran.
- ~~VM: `import nytorch_classes`~~ was a no-op — the native `tensor_*` ops
  were registered, but the Nython-level class library (`Tensor`, …) was never
  actually loaded, unlike on the interpreter.
- ~~VM: typed `except` / `try`/`else`~~ — only the first `except` clause was
  ever compiled, regardless of its declared type; `else` wasn't compiled at
  all. See HANDOFF 5.9.
- ~~VM: `int(s)` never raised~~ — `int("abc")` silently returned `0` instead
  of a catchable `ValueError`, and the base argument / `0x`/`0b`/`0o` prefix
  auto-detection were never implemented.

### Added

| Feature | Notes |
|---|---|
| `1..5` / `1...5` | half-open and inclusive ranges; `a..b..step` |
| `is` / `is not` | membership: `1 is int`, `1 is Object`, `c is Base` (walks the chain) |
| `import X as Y` | binds a namespace; `from "m" import n` also works |
| `catch` | alias for `except`, matching the existing `throw`/`raise` alias |
| Located errors | `file:line:column`, source line, caret — both engines, including EOF. |
| `NameError` / `ImportError` | undefined calls and missing modules were silent |
| Object protocol | `class_name`, `to_string`, `id`, `hash`, `is_a`, `instance_of`, `equals_to`, `fields`, … — both engines |
| `--profile` | real per-function counts and self/total time |
| `gui_hash_id` | native FNV-1a for immediate-mode widget identity |
| `gui_display_scale` | HiDPI content scale |
| `print(a, b, sep=, end=)` | the call form, both engines (round 73) |
| `fuzzy_score` / `fuzzy_positions` / `fuzzy_rank` | best-alignment fuzzy matching, native, both engines |
| `file_mtime(path)` | ms since epoch, -1 if missing (folders too) |
| `--trace OUT file.ny` | statement-level recording for the IDE's debugger |
| `--profile` allocations | per function: objects and strings kept (`NY_PROFILE_SORT=alloc`); `NY_PROFILE_OUT=f nython --ide` profiles the IDE |
| `a?.b` `a?.m(x)` `a?[k]` `a?.[k]` `f?.(x)` | optional chaining (round 75): none when the receiver is none/undefined **or** the member/key/index is missing; the rest of the chain is skipped, arguments included. A present link and every plain step after it stay strict (`a?.b.c` raises if `a.b` is none). Not assignable. |
| `a ?? b`, `t ??= v` | null coalescing (round 75): `b` only when `a` is none or undefined (lazy); `??=` assigns only when `t` is none/undefined or, for an attribute/key, missing; object and index evaluated once |
| `delattr`, `del obj.x` | remove an attribute (AttributeError if absent); `getattr`/`hasattr`/`setattr` work on every kind of value, as in Python |
| `global x` | a real declaration now: creates the module variable and skips an enclosing function's `x` (round 75) |
| suffix literals | `1k == 1000` (int), `2.5k == 2500`, `1.1k == 1100`; a float only when fractional (`1m == 0.001`, `1500m == 1.5`) |
| `NY_LENIENT_READS=log` | porting aid: a missing attribute/key read prints `[lenient-read] file:line: ...` once and yields none instead of raising |

### Known limitations

- ~~**Containers are never reclaimed by the interpreter**~~ — **resolved
  (round 75)**: reference counting plus a generational cycle collector on
  both engines (the VM leaked every reference cycle). Lists, dicts,
  strings, functions, bound methods, instances and scopes are freed, cycles
  included; `__del__` runs once; `gc_collect()`/`gc_stats()`/`weakref()`.
  200k container literals: 598 MB → 11 MB. See `GC_NOTES.md`.
- ~~The VM has no tuple type~~ — **resolved (round 74)**: real tuples on both engines.
- ~~`len()` counts characters but `s[i]` / `s[a:b]` index bytes~~ — **resolved
  (round 74)**: indexing, slicing and `len` all count UTF-8 characters.
- ~~`1.+(2, 3)` evaluates to `none`~~ — **resolved (round 74)**: operators as members.
- ~~Integer `/` differs between engines~~ — **resolved (round 71)**: `/` is
  always true division (float), `//`/`\` are floor division (int) on both
  engines. See "Round 71 fixes" below.
- ~~Interpreter generators are still eager~~ — **resolved (round 75)**:
  generator bodies run on stackful coroutines (`NyCoro`/`NyGen`), lazily,
  with the whole protocol (send/throw/close, `yield from`, StopIteration.value)
  on both engines; generator expressions are lazy on both. See HANDOFF §0l.
  Still open there: a generator dropped mid-iteration is finalized when its
  loop/consumer ends or at program exit, not the moment its last reference
  goes (that needs the interpreter's reference counting).
- Video builtins are stubs (need ffmpeg).
- ~~`@property` doesn't work on the VM~~ — **resolved (round 74)**: VM class
  bodies run (properties with setters, static/class methods, decorators).
- ~~Reading a missing attribute gives `none`~~ — **ruled and done (round
  75)**: reading a missing attribute raises AttributeError and a missing
  dict key KeyError, as in Python, on both engines (so do `none.x`,
  `none[k]`, `none.m()`); absence is handled on purpose with `getattr(o, n,
  d)` / `hasattr` / `d.get(k, d)` / `k in d` / `o?.x` / `d?[k]` / `x ?? d`.
  Every library, the IDE and the tests were migrated (HANDOFF §0m).
- ~~A plain `x = ...` rebinds a global — to be ruled on~~ — **ruled (round
  75)**: kept. Inside a function a plain assignment rebinds the nearest
  existing binding (enclosing functions, then the module); if there is none
  it creates a local. `var`/`let`/`const` (equivalent, function-scoped)
  declare a local that shadows any outer name for the rest of that function
  from the point it runs; `global` names the module's variable, `nonlocal`
  the enclosing function's. for-loop targets, parameters, comprehension
  variables and `except ... as` are local declarations too.
- ~~Interpreter lambdas capture loop variables by value~~ — **resolved
  (round 76)**: lambdas close over their scope by reference, as `def` does
  (`[lambda: i for i in range(3)]` gives 2, 2, 2, as Python), and a lambda
  can call itself through the name it is assigned to.

## Session Workflow

1. **Read `HANDOFF.md`** — environment, traps, outstanding work.
2. Build (`rm -rf build && make cli && make`), copy the CLI binary to
   `./ny_test` (some GUI tests shell out to it — see HANDOFF §2). No SDL3
   install needed; `thirdparty/sdl3-stub/` is used automatically when no real
   SDL3 is found.
3. Run the full sweep on **both engines** before changing anything, so any
   failure afterwards is attributable. Grep the *output* for `N failed`, not
   just the exit code — see HANDOFF §2/§3.
4. Reproduce a defect minimally, trace it to source, fix **both engines
   together**, and add a test asserting values rather than termination.
5. Re-run the sweep and compare divergence *sets* against
   `/tmp/obuild/nython_orig`, not counts:
   `python3 tools/sweep.py --base /tmp/obuild/nython_orig` does both engines
   and prints regressions and fixes as sets. For IDE changes also run
   `python3 tools/ide_lint.py`, `python3 tools/ide_e2e.py` and
   `python3 tools/ide_memprobe.py --check`.
6. Package to `/mnt/user-data/outputs/`.
7. State plainly what was not done. A green suite that hides an unadopted module
   or a one-engine feature is worse than an honest gap.

## Bug fixes — GUI & IDE audit (multi-session)

### src/builtins/gui.cpp
- **`gui_get_error()` / `gui_sdl_version()` always returned `none`**: Root cause — the `evalCall` path in `NythonExecutor.hpp` only routes through `callBuiltin` when the function is registered in `registerBuiltins()`. Unregistered `gui_*` names evaluated to `NONE_VALUE` callee and fell through to `return NONE_VALUE` without ever calling `callBuiltin`/`dispatch_gui`. Fixed by registering `gui_get_error`, `gui_sdl_version`, `gui_create_window`, `gui_load_font`, `gui_measure_text`, `gui_load_image`, `gui_poll_events`, `gui_video_time`, `gui_video_duration` in `registerBuiltins()`. Also added `evalCall` fallback for underscore-prefixed module functions.
- **`ensure_sdl_for_window()`** — removed `SDL_HINT_RENDER_DRIVER "direct3d11"` pre-init hint that caused `SDL_CreateWindow` to silently fail on systems without D3D11.
- **`SDL_WINDOW_HIGH_PIXEL_DENSITY`** removed from window flags — caused `SDL_CreateWindow` to return NULL on some Windows 11 GPU drivers.
- **Software renderer fallback** added: if default renderer fails, tries `"software"` renderer.
- Added `gui_sdl_version()` builtin — returns SDL3 runtime version string (e.g. `"3.2.4"`).
- Added `examples/check_sdl.ny` — diagnostic script to verify SDL3 DLLs and runtime.
- **Removed `SDL_VIDEODRIVER` hint** that forced wayland/x11/offscreen on Windows, preventing window creation.
- **`SDL_WINDOW_HIGH_PIXEL_DENSITY`** flag added to all windows for proper HiDPI.
- **`SDL_HINT_RENDER_DRIVER`** set per-platform (direct3d11 on Windows, metal on macOS).
- **`SDL_Quit()`** called when last window destroyed.
- **`gui_draw_text`**: removed `if(text.empty()) return` guard that skipped space characters.
- **`gui_draw_line`**: fixed thickness — was always offsetting Y (broke vertical/diagonal lines). Now offsets perpendicular to the line direction using `(-dy/len, dx/len)`.
- **`gui_poll_events` wheel**: `ev.wheel.x/y` (scroll amount) was used as cursor position. Fixed to `ev.wheel.mouse_x/y` for position. Added `SDL_MOUSEWHEEL_FLIPPED` correction.
- **`gui_load_font`**: ignored bold/italic — all fonts loaded as regular. Now accepts 4 args `(family, size, bold, italic)`, tries bold-specific font files first, then calls `TTF_SetFontStyle` for synthesis.
- **Key names lowercase + normalised**: `SDL_GetKeyName` returns `"Return"`, `"Escape"`, `"Backspace"`, `"Up"` etc. All widgets expect lowercase `"enter"`, `"escape"`, `"backspace"`, `"up"`. Key names are now lowercased and normalised (`"return"→"enter"`, `"page up"→"pageup"`, etc.) — **keyboards were completely broken before this fix**.
- **`-DNYTHON_WITH_IDE=1`** added to both Release and Debug targets in `nython.cbp`.

### lib/gui.ny
- **`Font.load()` never called**: `Font.__init__` now auto-calls `self.load()`. Added `ensure_loaded()` lazy-retry for fonts built before SDL/TTF was ready. `Renderer.draw_text()` calls `font.ensure_loaded()` before use.
- **`Font.load()` ignored bold/italic**: now passes `self.bold, self.italic` to `gui_load_font`.
- **`"wheel"` vs `"scroll"` event mismatch**: C++ emits `"wheel"` but all 20+ widget scroll handlers check `"scroll"`. Fixed by normalising in `Window._process_event()` and `Window.run()`.
- **`ToastManager.__init__`**: required `window_w` arg but IDE called `ToastManager()` with no args → crash. Made `window_w` required but callers now pass `1600`.
- **`ToastManager.update()`**: `new_count` declared but never incremented → all toasts dropped every frame.
- **`ToastManager.show()`**: `self.toasts[self.count] = t` dict-style assignment on list. Changed to append.
- **`Widget.add_child()`**: `self.children[self.child_count] = widget` dict-style assignment on list. Fixed to append.
- **`Widget.remove_child()`**: `new_count` never incremented → child_count zeroed after any remove.
- **`Panel.add()`, `VBox.add()`, `HBox.add()`**: same dict-style index assignment bugs. All fixed to append.
- **`Card.handle_event()`**: no visibility guard — forwarded events to children even when hidden.
- **Per-frame Font allocations eliminated**: `Toast`, `Modal`/`Dialog`, `VideoPlayer`, `Image`, `ActivityBar` all cached fonts as instance attributes instead of constructing new Font objects every draw call.

### nython_ide.ny
- **`ToastManager(1600)`**: was `ToastManager()` — crash on `window_w` access.
- **Panel tab strip fonts**: `Font(...)` created every frame in `_draw_panel_tab_strip` → cached as `self._font_panel_tab/bold`.
- **Status bar fonts**: `Font(...)` created every frame in `_draw_status_bar` → cached as `self._font_status/bold`.

- **`enumerate(lst, start=N)` kwarg form fixed**: Root cause was two-part —
  (1) `NythonExecutor.hpp` kw_builtins set didn't include `"enumerate"`, so `start=` was silently dropped before reaching callBuiltin; (2) a duplicate `globals_["enumerate"]` in VirtualMachine.hpp (line ~4346) overwrote the correct version that had start-support. Both fixed: `enumerate` added to kw_builtins with `start` key extraction; both VM enumerate definitions updated with full positional + kwarg start support.
- **vm_audit27 added**: 84 tests covering the above plus *args/**kwargs, try/else, string .replace()/.count()/.join(), isinstance with inheritance, __repr__, callable classes (__call__), dict.items()/keys()/values(), chained comparisons, lambda multi-arg, map+filter, method chaining, sorted key=/reverse=, recursion, string %, dict.get(), `in` operator.

## Round 71 fixes (see `HANDOFF.md` §0b for full detail)

**Division, ruled**: `/` is always true division (float — `10 / 2 == 5.0`);
`//` and `\` are floor division (int — `10 // 2 == 10 \ 2 == 5`). This
resolves the "Integer `/` differs between engines" known limitation above —
it's no longer a divergence, the VM's `op_div()` was wrong and is fixed.

**Dead operators, now wired up on both engines** (verified with
`examples/vm_audit35.ny`, diffed interpreter-vs-VM):
- `instanceof` — alias for `is`.
- `===` / `!==` — strict equality/inequality (previously corrupted the VM
  stack as an unhandled NOP).
- `xor` / `^^` — logical xor (same previous VM stack corruption).
- `>>>=` — treated as `>>=` (Nython ints are arbitrary-width, no fixed sign
  bit to distinguish logical vs arithmetic shift).
- `~=` — bitwise-complement-assign: `x ~= y` means `x = ~y`.
- `++` / `--` postfix — now actually mutate on the VM (were a no-op there).
- `\` (RevDiv) — was unreachable at the lexer level; now floor-divides.

**New language constructs**:
- `enum Name: A, B, C` — members are ordinals (or explicit values); compiles
  to a bound name→value map on both engines.
- `namespace Name: ...` / `module Name: ...` (module is a pure alias) — now
  binds its own name on the interpreter (`ns.member` used to read `none`);
  now compiles on the VM at all (used to be a silently-dropped subtree).
- `interface Name: ...` + `class C implements Name` — interface now
  registers as a real type on both engines, so `implements` + `is`/
  `isinstance` chain-walking sees it (interpreter used to no-op interface
  declarations entirely; VM used to drop the subtree).
- `struct Point: x, y=0` — desugars at parse time to a class with a
  synthesized `__init__` that assigns each field via `self.field = field`.
- `new A()` / `new A` — construct an instance, distinct from `A` (the class
  value) and `A()` (call with no `new`, equivalent to `new A()` for a
  zero-arg constructor).

**Also fixed**: hex/octal/binary integer literals (`0xFF`/`0o17`/`0b1010`)
always evaluated to `0` on the VM (`std::stoll` stopping at the prefix
letter) — found incidentally, not part of the operator/keyword work above.

## Round 71b: IDE terminal command line

`nython_ide.ny`'s terminal panel now runs real commands instead of a
four-word stub. `lib/ide_commands.ny` (`:cmd` / `>expr` / `@agent`) and
`lib/ide_toolchain.ny` (the real popen-based compile/run bridge) are wired
into `NythonIDE.__init__`/`_term_run`. See `HANDOFF.md` §5.3 for the full
command list and what is still unverified (no headless keyboard injection
to exercise it end-to-end).

## Round 71c: operation-based undo and multi-cursor editing

Two more `HANDOFF.md` §5.3 modules wired into the shipped IDE:

- **`EditorBuffer` (`ide_editor.ny`) undo is now operation-based**, not a
  whole-document snapshot per keystroke. `insert_char`/`delete_char_back`/
  `insert_newline` record a handful of scalars and replay them through
  `_apply_inverse` (the same pop-apply-push technique `lib/gui_piecetable.
  ny`'s `PieceTable` demonstrates), instead of `nython_ide.ny` copying
  `buf.get_all_text()` before every character. Undo is now per-tab; `_redo()`
  (previously a hardcoded stub) actually works, bound to Ctrl+Y / Ctrl+Shift+Z.
- **Real multi-cursor editing** via `lib/ide_selection.ny`'s `SelectionModel`:
  Alt+Click / Ctrl+Alt+Down / Ctrl+Alt+Up add extra carets; typing/backspace/
  enter apply to all of them. The existing single-selection code is untouched.

See `HANDOFF.md` §5.3 for the full design rationale (why a full `PieceTable`
storage swap was rejected in favor of adopting its technique instead) and
documented limitations (multi-caret edits aren't one undo step; arrow keys
move only the primary caret).

## Round 72: nytorch gets real autograd, and a genuine VM closure bug

`lib/nytorch/autograd.ny` is new — a `Variable` class implementing actual
reverse-mode automatic differentiation (dynamic computation graph +
`.backward()` via reverse topological sort), scoped to scalars and 1D
tensors. Nothing in nytorch had this before; every optimizer in
`optimizers.ny` takes `grads` as an argument the caller must already have
computed by hand. `LinearVar` + `mse_loss` + `SGDVar` show it end to end —
`examples/vm_audit38.ny` trains one for 50 SGD steps and asserts the loss
collapses to `0.0`, verified against hand-derived AND numerical
(finite-difference) gradients on both engines.

Building it found two real bugs:
- **VM**: a closure stored in an instance attribute and invoked as
  `obj.attr()` (exactly the shape `out._backward_fn = _bw; ...;
  node._backward_fn()` uses) silently lost every captured variable —
  `vm_call_method`'s "bare FUNCTION held in an attribute" path called
  `exec_code(held.code, args, obj)` without `held.closure_env`, unlike every
  other call path. The interpreter never had this bug.
- **`activations.ny`**: `Tensor.relu()`/`.sigmoid()`/`.gelu()`/`.silu()`/
  `.swish()`/`.elu()`/`.softmax()` each call a bare global function of the
  *same name* as the method — which resolves back to the method itself, not
  the builtin (the interpreter's own `RecursionError` message names this
  exact gotcha). All seven were silently wrong on both engines; only
  `Tensor.tanh()` had already dodged it via its builtin's other name,
  `tanh_fn`.

Same round, follow-up: `LinearLayerVar`/`MLPVar`/`softmax_cross_entropy`/
`AdamVar` extend the engine to real multi-layer networks — `select()`/
`stack_vars()` stand in for a weight matrix nytorch doesn't have (n
independent `LinearVar` units combined into one vector), and
`examples/vm_audit39.ny` trains one on XOR (unsolvable by a single linear
layer) to loss 0.00046, byte-identical on both engines. See `HANDOFF.md`
§0c for full detail, including the init fix this needed and how it was
confirmed not to be a gradient bug first.

Also new: `lib/nytorch/agent_learn.ny`'s `CodingAgent` — an online-learning
agent built on the same autograd engine. Tokenises real Nython source with
the real keyword vocabulary, trains a small next-token-category model one
gradient step per adjacent pair (genuine online learning, not a deferred
batch retrain), and its perplexity on code it was never trained on
measurably improves after training on *different* code — real structural
generalisation, verified in `examples/vm_audit40.ny`. Building it surfaced
a real, quantified finding: `KnowledgeBase` is independently and
incompatibly defined **three times** inside `nytorch/` alone (plus a
fourth in `lib/aiagent.ny`) — import order silently picks whichever was
defined last, and a caller written against a different one gets `none`
back from every call instead of an error. Ten class names collide this way
across `nytorch/`. See `HANDOFF.md` §5.10 for the full list — not fixed
here, `agent_learn.ny` just doesn't add to it (`AgentKnowledge`, not
`KnowledgeBase`).

Final follow-up: real 2D matrix support. `Variable` gained optional
`rows`/`cols` shape metadata over its existing flat `.data`, and
`matmul`/`add_bias_row`/`select_row` are real batched matrix ops with
hand-verified backward rules — `LinearMatVar`/`MLPMatVar` are the
real-weight-matrix counterparts to `LinearLayerVar`/`MLPVar`, closing the
"real ND tensors... absent" gap as a pure Nython addition rather than a
native `tensor.cpp` change (too risky given ~15,000 existing lines depend
on the current representation). `examples/vm_audit41.ny` trains
`MLPMatVar([2,6,2])` on XOR with the whole batch going through each layer
as one matmul call, not four separate forward passes. Along the way, a
numerical-gradient-check false alarm (0.16 diff, traced to XOR's `(0,0)`
point landing exactly on relu's non-differentiable point at zero, given
zero-initialized bias) turned out not to be a bug — confirmed by printing
the pre-activations and by re-checking with inputs that avoid that one
coincidental point, which alone resolved it. See `HANDOFF.md` §0c for
the full trace.

## Round 73: the IDE to VS Code standard, verified by driving it

The shipped IDE was rewritten around VS Code's model and then exercised end to
end by a headless driver, which found and fixed real defects in the IDE, the
runtime and both engines. Full detail in `HANDOFF.md` §0d; the short list:

- **IDE**: command registry (~150 VS Code ids, chords, when-clauses) behind
  menus, palette, context menus, status bar and keys; Quick Input with `>`
  `:` `@` `#`; document model with dirty tracking and Save/Don't Save/Cancel;
  grouped undo (typing runs, typing over a selection, multi-caret edits,
  comment/move-line/indent conversions are one step each); text fields with
  a real caret and selection (`LineEdit`); per-file indentation detection,
  Spaces/Tabs picker and conversion, tabs rendered at tab stops; workspace
  file watching (explorer refresh, reload of clean editors, save-conflict
  dialog); Source Control on git with Myers gutter bars and a diff view; a
  record-and-replay debugger (breakpoints, step in/over/out, step back,
  reverse continue, variables, call stack, watch); Extensions = the lib
  catalog. The final newline is an empty last line, as in VS Code.
- **Verification**: `tools/ide_e2e.py` (scenarios through real input, plus a
  dead-click audit of every clickable in the editor, views and panels),
  `tools/ide_lint.py` (unknown members, reserved words, dead commands and
  click targets), `tools/ide_memprobe.py` (memory kept per frame/key/scroll).
- **Runtime, both engines**: one JSON codec (`include/NyJson.hpp`; the
  interpreter's was unescaped and flat); `print(a, b, sep=, end=)`;
  `list.pop(i)` (VM ignored `i`), `insert` with negative index; deep `==`/`!=`
  on the interpreter (nested lists were never equal, all maps were equal);
  `true == 1` on the VM; `map.clear()` (turned maps into lists); the uncaught
  exception is now in `--trace` recordings; `launch_ide` reports syntax
  errors instead of terminating; background jobs whose output ended in a
  newline never finished (os_exec strips it).
- **Memory** (IDE, per `ide_memprobe.py`): idle 3.45 → 0 KB/frame, typing
  787 → ~40 KB/key, scrolling 161 → ~7 KB/event, hover 40 → 0.

## Round 74: the OS layer (see `HANDOFF.md` §0f)

- **One implementation per os/io/time builtin, both engines.** The VM's own
  copies were deleted; it reaches the interpreter's through the bridge.
  Files: `src/builtins/os.cpp` (files, paths, env), `os_time.cpp`,
  `os_proc.cpp`; helpers in `include/builtins/os.hpp`; conventions in
  `include/NyRuntime.hpp`; the startup prelude (file objects, `open()`) in
  `include/NyPrelude.hpp`.
- Legacy names keep their return-value contract; the new `os_*` names raise
  typed errors (FileNotFoundError, IsADirectoryError, FileExistsError, ...)
  that the bridge turns into VM exceptions.
- **Builtin kwargs**: names in `kwmap_builtins` (evalCall) get their keyword
  arguments as one trailing map, as the VM's CALL_KW already did; read them
  with `nyos::Args`.
- New: `open()` file objects, `os_run(cmd, cwd=, env=, input=, timeout=)`
  (argv list = no shell), `os_spawn`/`os_poll`/`os_wait`/`os_kill`, `os_walk`,
  `os_glob`, `os_rmtree`/`os_copytree`/`os_move`, `os_stat`, `os_mkstemp`,
  path normpath/relpath/split/splitext/expanduser/..., `time_strftime`/
  `gmtime`/`strptime`/`time_iso`/`monotonic`/`time_ns`, `sys.argv`,
  `__name__`, `__file__`, `import os` / `time.time()` namespaces.
- Interpreter integers: `int()`, `//`, `//=`, `**=`, `abs()`, unary `-`, `~`
  no longer truncate to 32 bits.

## Round 74: threads, synchronisation and async (see `HANDOFF.md` §0g)

- One concurrency runtime for both engines: `include/NyConc.hpp`,
  `src/NyConc.cpp` (engine adapters: `threading.cpp`, `src/VMConc.cpp`).
- One process-wide GIL (FIFO ticket lock, 5 ms hand-over). It is off
  until the first thread starts. A due hand-over waits while the thread holds
  a Nython lock (at most one more interval) and happens right after its last
  unlock, and a released mutex wakes one waiter to compete for it instead of
  being handed to a thread still waiting for the GIL - no lock convoys
  (round 75; `thread_wait_count()` measures it). **Any native code that blocks must release
  it**: wrap the wait in `nyconc::GilRelease unlocked;` and touch no engine
  state inside it.
- `async def` / `await`; channels with `select`; futures, pools, task
  groups; `DeadlockError` / `LockOrderError` instead of hangs.

## Round 74: nytorch (see `HANDOFF.md` §0h)

- One tensor kernel library for both engines: `include/NyTensor.hpp`,
  `src/builtins/nytensor.cpp` (interpreter: `dispatch_nt` first in the
  callBuiltin chain; VM: `register_nt_natives()`). Tensors are flat lists
  plus a shape; float64; broadcasting, axis reductions, batched matmul,
  conv/pool/norm, seeded RNG, save/load v2.
- `lib/nytorch/`: Tensor + autograd (`tensor.ny`), Module/Sequential
  (`module.ny`), layers, losses, optimizers, data; every model class now
  computes (no random-output stubs).
- **One definition per class name under `lib/`**: `python3
  tools/ny_classcheck.py` fails on duplicates (a later same-named class
  silently replaces the earlier one). Run it after adding a class.

## Round 74: Python values and builtins (see `HANDOFF.md` §0i)

- Shared value libraries for both engines: `NyBigInt`, `NyStr`,
  `NyFormat`, `NyOrderedMap`, `builtins/pycore.cpp`.
- Dicts keep insertion order with typed keys; ints are exact at any size;
  one formatter (f-strings with specs, `format`, `str.format`, `%`);
  tuples; UTF-8 character indexing; IndexError/KeyError on out-of-range.
- Arithmetic on unsupported types raises TypeError (it used to give none /
  1). Reading a missing dict key raises KeyError since round 75 (§0m).
- VM natives receive keyword arguments as a trailing map marked
  `class_name "__kwargs__"` (`take_kwargs()`); OS builtins read the same
  map with `nyos::Args`.

## Round 74: the language engines (see `HANDOFF.md` §0j)

- **Exceptions are objects on both engines**: builtin exceptions are real
  classes (`ZeroDivisionError` is an `ArithmeticError`); typed `except`
  catches errors raised in called functions and by the runtime; an
  unmatched `except` passes the error on after `finally`; `with` passes
  `(type, value, tb)` to `__exit__` and a true return suppresses.
- **Errors that used to be silent**: undefined names raise NameError;
  calling a missing method raises AttributeError; a call that does not fit
  the parameters raises TypeError (Python's messages).
- **Classes**: C3 MRO over every base, `super()`, class bodies on the VM
  (`@property`/setter, `@staticmethod`/`@classmethod`), defaults evaluated at
  definition, the operator/object protocols (`__eq__` in containers,
  `__iter__`, `__radd__`, …), `__mro__`/`__bases__`.
- **VM name resolution is lexical** (it used to search every frame).
- **Syntax**: match patterns (`|`, guards, sequence/mapping/class/`as`),
  walrus in `if`/`while`, raw strings, general decorators, starred and
  nested unpacking, several `for`/`if` clauses in comprehensions, `@`.
- Divergence battery (286 programs, interpreter / VM / python3 all agree):
  87 at f284623 → 262 now.

## Round 75: real SDL3 and HiDPI (see `HANDOFF.md` §0n)

- **Real SDL3** builds (`tools/build_sdl3.sh`, `make BUILD=build-sdl
  NYTHON_SDL_STUB=0`) and passes the whole e2e suite on X11, at 1× and at
  200%; the test harness gives the real backend the stub's event scripts and
  display-list capture, plus real-pixel PNGs.
- **HiDPI, both of SDL3's models**: windows can be sized in layout units
  (`Window.layout_units`, `gui_create_window` flag 16) - the same workbench on
  a 200% Windows/X11 panel (twice the points) and a Retina Mac (twice the
  pixels per point). Draw at the window's display scale (`Window.scale()`,
  predicted by `gui_display_scale() * gui_display_density()`), not the
  content scale. `"scale"` events (`Window.on_scale`) report a move to a
  monitor of another scale; the IDE rebuilds its metrics and fonts.
- The e2e suite is scale-independent (`R()`/`D()` in `tools/ide_e2e.py`) and
  passes in full at 2× in both stub models.
- Legacy flat tensor ops follow NumPy's promotion rule: integer inputs stay
  integers through `+ - *`, dot, sum, max/min, abs/neg/sign, `relu`.

## Round 75: memory management on both engines (see `HANDOFF.md` §0k, `GC_NOTES.md`)

- **Interpreter**: exact reference counting (`Collectable::gc_rc`, counted by
  every `Value` copy through `TValue::o`) plus a generational cycle collector
  (trial deletion, `src/NyGC.cpp`). Strings, functions, bound methods and
  instances are heap objects (`include/NyHeap.hpp`) that erase their
  side-table entries when freed; scopes are counted (`CtxReaper` releases).
- **VM**: `shared_ptr` counts as before, plus a cycle collector over
  weak_ptr-registered containers (`src/VMGC.cpp`); deep chains are freed
  iteratively (a 30k-node list used to crash the VM when dropped).
- `__del__` runs once, at the next statement/instruction boundary, never
  inside a decrement; cyclic garbage is finalized first (PEP 442).
- Full collections also run when the heap has doubled since the last one
  (`mallinfo2`), then `malloc_trim`: memory stays within ~2x what is live.
- **A pointer kept outside a `Value` must hold a reference** (`nygc::incref`)
  or be erased when the object dies - a freed address is reused at once, and
  a stale entry then describes a different object. Collections run only at
  safe points; counts are touched only with the GIL held.
- Builtins (both engines): `gc_collect`, `gc_enable`/`gc_disable`/
  `gc_is_enabled`, `gc_set_threshold`/`gc_get_threshold`, `gc_stats`,
  `gc_live_objects`, `mem_rss_kb`, `mem_peak_rss_kb`, `weakref`.
- `make asan` → `build-asan/nython-cli` (ASan + UBSan + LSan).

## Round 75: lazy generators (see `HANDOFF.md` §0l)

- **Interpreter**: a generator function's body runs on a stackful coroutine
  (`include/NyCoro.hpp`, `src/NyCoro.cpp`: mmap'd 1 MB stacks committed as
  touched, guard page, pooled; x86-64/AArch64 register switch, ucontext
  elsewhere, pooled Windows fibers - tested under Wine only) driven by `src/NyGen.cpp`
  (`include/NyGen.hpp`); the hooks in `NythonExecutor.hpp` are small and
  marked `nygen`. `NY_GEN_STACK_KB` sets the stack size.
- **Both engines**: `send`/`throw`/`close` with GeneratorExit and finally at the
  paused yield; StopIteration.value; `yield from` delegates all four and
  evaluates to the subgenerator's return value; StopIteration escaping a body
  is RuntimeError; "generator already executing"; lazy generator expressions;
  `zip`/`map`/`filter`/`enumerate` over a generator and `iter()` are lazy
  (over lists they still return lists); new `islice` and `take(n, it)`;
  `any`/`all`/`next`/`in` stop early; `a, b = gen()` unpacks.
- **Rules**: a started generator is resumed only by the thread that started
  it (RuntimeError, both engines); a generator a `for` loop or a consuming
  builtin made itself is closed when that consumer is done (as CPython's
  reference counting would); every generator still paused at program end is
  closed, oldest first. The VM raises RecursionError at 1000 frames (it
  crashed with SIGSEGV at ~1400).

## Round 75: strict reads, optional chaining, declarations, suffix literals (see `HANDOFF.md` §0m)

- **Missing reads raise, on both engines**: `obj.missing` → AttributeError
  (instances, classes, none, dicts read with `.`, str/list/int/functions...),
  `d[missing]` → KeyError, `none[k]`/`5[0]` → TypeError, `none.m()` /
  `"s".nosuch()` → AttributeError, `none.x = v` → AttributeError. A builtin
  value's method read as a value is bound (`f = xs.append`), from one table
  both engines share (`include/NyMembers.hpp`).
- **Absence on purpose**: `getattr`/`hasattr`/`setattr`/`delattr` for every
  value, `d.get`/`setdefault`/`in`; `a?.b`, `a?.m(x)`, `a?[k]`, `a?.[k]`,
  `f?.(x)` (none when the receiver is none/undefined or the member is
  missing; the rest of the chain is skipped); `a ?? b`; `t ??= v`. The C
  ternary still parses (`c ? .5 : 1`, `c ? [1] : [2]`: `?[` is optional
  indexing only when glued to its receiver). AST: `OptChainNode`/`HoleNode`
  (`ASTNodes.hpp`); VM ops `JUMP_IF_NONE_KEEP`, `JUMP_IF_MISSING_KEEP`,
  `JUMP_IF_NOT_NONE_OR_POP`, `LOAD_ATTR_OPT`, `LOAD_SUBSCR_OPT`,
  `CHECK_MEMBER`, `DUP_TOP_TWO`.
- **`undefined`** is a value distinct from none on both engines (the VM
  compiled the literal to nothing); the runtime never produces it for
  absence. `??`/`?.` treat it as absent. `del x` unbinds `x` (NameError
  after).
- **Scope ruling**: plain assignment rebinds the nearest binding, `var`/
  `let`/`const` declare a local, `global x` creates/targets the module
  variable (`LOAD_GLOBAL_NAME`/`STORE_GLOBAL_NAME` on the VM).
- **Suffix literals** are ints when whole (`1k`, `2.5k`, `1.1k`), floats
  when fractional (`1m`), decided on the digits in the lexer.
- **Migration**: every read the libraries, the IDE and the tests made of a
  missing attribute/key was found with `NY_LENIENT_READS=log` (both engines,
  every example and test, the whole IDE e2e) plus two static scans, and fixed
  idiomatically (`.get`, `?.`, attributes initialised in `__init__`).
  `tools/ny_attrcheck.py` finds `self.x` reads of attributes set only lazily;
  `tools/ide_e2e.py` now fails on AttributeError/KeyError/NameError/TypeError
  or `[lenient-read]` in the IDE log.

## Round 76: the "Not done" lists closed (see `HANDOFF.md` §0o)

- **Static scope checks, both engines** (`src/NyScope.cpp`, run by
  `Parser::parse`): `const` is enforced (assign/augment/delete/redeclare/
  unpack/loop over it is a SyntaxError before the program runs);
  `nonlocal x` needs an enclosing function binding x; a walrus,
  `except ... as` and `with ... as` of a `global` name bind the module's.
- **Interpreter**: lambdas close over their scope by reference (self-
  recursion, Python's late binding; defaults evaluated when made);
  `print(a(), b())` evaluates every argument first; IndexError reads
  `list index out of range`.
- **Error columns**: every syntax error said column 2 (`Location::reset`
  ignored its column); tokens are located where they start, a column counts
  characters, and the caret is placed by characters.
- **Lazy iterators** print as Python's (`<zip object at ...>`), have no
  `send`/`throw`, and `isinstance(x, "generator")` is true for them; `type()`
  stays "generator" (Nython's dict is the type "map").
- **rwlock competitive succession**: a released lock wakes one writer heir
  or every reader, and is taken only by a running thread (6 writers x 3000:
  33,922 thread sleeps -> 144). New `rwlock_waiting_writers`.
- **Async tasks are coroutines** on their loop's thread (`NyCoro`), not OS
  threads: no thread per task (2000 tasks: 2002 threads -> 1), switches
  3-12x faster; a task blocking inside a generator relays out through it
  (`nyconc::relay_requested`/`relay_park`). The interpreter's per-thread
  state is swapped for threads and tasks (`InterpEngine::State`): a bare
  `raise` could re-raise another thread's exception.
- **Memory**: objects used as dict keys are freed (`nygc::KeyTable`, and in
  `VMGC.cpp`), cycles through keys included; a cycle through a suspended
  generator is collected, its finally blocks run first (both engines); bound
  builtin members are heap objects (`nyheap::BMember`); the old
  `GarbageCollector` and the unused `Evaluator.hpp` are removed;
  `mem_rss_kb` works on Windows.

## Round 77: bytes, the network stack, the CLI, Python compatibility (see `HANDOFF.md` §0p)

- **bytes/bytearray** (`include/NyBytes.hpp`), Python string escapes,
  builtin types as namespaces (`str.upper(s)`, `int.from_bytes`).
- **Signals**: `signal` module, SIGINT -> KeyboardInterrupt (status 130),
  handlers at safe points and inside blocking waits (PEP 475).
- **Network**: one non-blocking socket table (`src/builtins/net.cpp`) behind
  `lib/socket.ny`/`select`/`selectors`; TLS loaded at run time
  (`src/builtins/tls.cpp`, `lib/ssl.ny`); `lib/http/` (client, server,
  cookiejar), `lib/urllib/`, `lib/websocket.ny` (RFC 6455), hashlib/hmac/
  base64/secrets; network.ny, webserver.ny, sockets.ny, clientserver.ny are
  real. Blocking calls release the GIL; in async tasks they park the task
  (colorless I/O). `nython -m http.server` serves a directory.
- **Async**: `async with/for`, async generators, `lib/asyncio.ny`.
- **Modules**: `import name` runs a `.ny` file in its own scope (classes
  named `m.Class`), `from m import ...`, packages, NYTHONPATH. **Sets** are
  a real type; **math** is Python's module on both engines.
- **CLI** (`src/main.cpp`): `-c/-m/-i/-q/-u/-E/-`, `--vm` for every form,
  `--check`; the prompt shows reprs and keeps `_`; **SystemExit is real**
  (`exit()` raises it). `sys.stdin/stdout/stderr`; `print(*xs, file=,
  flush=)`; `lib/argparse.ny` is Python's algorithm with Python's help
  layout.
- **Python compatibility**: each execution of a class statement makes a
  new class (re-runs are `Name#n`, shown as Name); `[*a]`, `{**d}`,
  `[x, *y] = s`; annotations; `f"{x=}"`; slice objects reaching
  `__getitem__`; `eval`/`exec`/`compile`; complex numbers and `2j`;
  `object`; `__setattr__`/`__delattr__`; docstrings and `help()`;
  `locals/globals/vars/dir`; `**kwargs` in call order; `lib/collections.ny`
  (deque, Counter, defaultdict, OrderedDict, namedtuple, ChainMap).
- **Program input in the IDE**: `os_spawn(cmd, stdin=true)` +
  `os_proc_write`/`os_proc_close_stdin`; with `NY_INPUT_REQUEST` set a
  program announces each stdin read (`nyconc::INPUT_REQUEST_MARK` on
  stdout). Run shows the pending prompt with an input line in the Output
  panel (focus `"stdin"`), the Terminal forwards lines to a running
  command, Ctrl+D ends input.
- **Gotchas**: `__dict__` is a copy (use `object.__setattr__`); coroutine
  objects are task handles (ints); a prelude name (`slice`, `object`,
  `complex`, `help`) shadows the old placeholder builtin of that name.
- **Classes** (vm_audit79): annotations are kept (`__annotations__`);
  `__new__`, `__init_subclass__` with class keywords, `__set_name__`,
  `__class_getitem__`, `__mro_entries__`, `list[int]`/`X | Y`;
  **metaclasses** (`type.__new__` adopts the class the statement built;
  M's dunders, methods and properties reach the class; `type(n, b, ns)`);
  `NotImplemented` and the reflected-operator protocol; full
  `__mro__`/`__bases__`, `__subclasses__()`. A module function stored as a
  class attribute is bound as a method (wrap it in `staticmethod`, as
  CPython's own code does).
- **`type(x)` gives type objects** (vm_audit80): `type(5) is int`,
  `type(obj) is its class`, `(5).__class__`; a type object `==` its name,
  Python's or the legacy one (`type(x) == "list"`, `"string"`, `"map"`), so
  old code keeps working - but `str(type(x))` is `"<class 'int'>"`. Use
  `typeof(x)` for Nython's name as a string. `int is int` is identity.
- **Class-machinery modules** (vm_audit74, 81-83): abc, numbers,
  collections.abc (collections is a package now), enum, dataclasses,
  typing (+ `check_type`), types, inspect (+ `signature_diff`), keyword,
  weakref, warnings (+ `deprecated`, `-W`), traceback, linecache, atexit.
  Engines: `f.__code__`/`__defaults__`/`__qualname__`, real tracebacks
  (`e.__traceback__`, `__context__`/`__cause__`, `sys.exc_info()`, Python's
  "Traceback (most recent call last):" before the `[Nython]`/`[VMError]`
  line), weakref callbacks, data descriptors, `__index__`, `__hash__ =
  None`, metaclass `__setattr__`, dunder names in `__dict__`, module scopes
  from a builtins snapshot.
- **Standard library** (vm_audit73, 75-78): json, random, datetime, time,
  io, string, textwrap, pprint, csv, statistics, fractions, struct,
  calendar, uuid, fnmatch, glob, shutil, tempfile, pathlib, subprocess,
  platform, getpass, logging, unittest, queue, itertools, functools,
  operator, heapq, bisect, copy, contextlib, re (a native engine with
  selective memoization - no catastrophic backtracking).

## Transcripts

- `/mnt/transcripts/journal.txt` — catalog of all session transcripts
- `/mnt/transcripts/2026-03-26-22-45-41-nython-v021-gui-sdl3-full-session.txt` — latest full session

## IDE Launch Fix (multi-session debug)

**Root cause 1 — LangWorkshopPanel defined after `var ide = NythonIDE()`**
`_build_layout()` tried to instantiate LangWorkshopPanel before the class was defined.
Fixed by moving LangWorkshopPanel before the launch block.

**Root cause 2 — Compound boolean expression with outer parens**
Line 762 of nython_ide.ny:
```python
# BROKEN — Nython parser can't handle (A and B) or C before a colon:
if (string_find(lower, "debug") >= 0 and string_find(lower, "session") >= 0) or string_find(lower, "breakpoint") >= 0:
```
The Nython parser sees `if (expr)` as complete, then hits `or` after `)` and throws
`SyntaxError: Unexpected token: :`. The error was caught silently by `evalImport()`'s
try/catch, making the IDE appear to "return immediately" with no output.
Fixed by removing the outer parentheses.

**Root cause 3 — Nython lexer `optimize()` out-of-bounds**
`optimize()` in Lexer.cpp accessed `tk[i+1]` without checking `i < nb-1`.
For large files (15K+ lines from combined imports), corrupted Dedent tokens.
Fixed: all `i < nb` guards changed to `i < nb-1` before any `tk[i+1]` access.

**Root cause 4 — Unicode characters in string literals**
Em-dashes (—), arrows (→), box-drawing chars (═─│), emoji in string literals
caused the Nython lexer to error. All replaced with ASCII equivalents.

**File split for parser depth limit:**
- `nython_ide.ny` — NythonIDE class + launch (imports the two below)
- `ide_editor.ny` — EditorBuffer, SyntaxHighlighter, RichEditor, OutputConsole
- `ide_workshop.ny` — LangWorkshopPanel
