# HANDOFF.md — resuming this work in a new session

Read this first. `CLAUDE.md` describes the project as it was designed;
this file describes it **as it actually is**, including the traps.

Last updated: round 86, part G — **§0z** (CPython's audit events (PEP 578) raised where CPython raises them, with its names and arguments, on both engines and in the library - a table generated from CPython's docs and probes (tools/audit_events.json), the prelude-caller rule for engine audit points, events from natives behind the VM's bridge; lib/nyaudit.ny audit policies, `--audit-policy` / `--audit-log`; vm_audit121)
Round 87, part K — **§0z6** (the semantic gaps round 86 found, fixed on both engines: input() with replaced sys.stdin/stdout, assigned `__defaults__`/`__kwdefaults__`/`__bases__` with CPython's checks (a layout model checked against CPython), tempfile.mkstemp's descriptor, sendmsg/recvmsg addresses, the `*`/`**` messages, Python-language dict keys and `super` as a name, class names and nested-class reprs with their module, TLS handshakes cancelled by asyncio.run, the false DeadlockError under Wine (a loop thread left marked blocked); and `tools/difftest.py` - differential testing against CPython over generated programs with delta debugging - and what it found: operators of non-numbers, in-place operator messages, `1 // 'a'` read as a comment, slices of non-subscriptables, yield from send, lambda qualnames, an instance's `__name__`; vm_audit126)
Round 86, part H — **§0z2** (nylsp: a Language Server (LSP 3.17) over the real parser - incremental sync into a piece table, diagnostics from the parser/NyScope/NyxAI, scope-aware completion, hover, signature help, definition/references across files, scope-correct rename by each file's binding rule, symbols, folding, formatting, semantic tokens with deltas, code actions, inlay hints; error recovery by indentation islands; `nython -m nylsp`; vm_audit122)
Round 86 (main session) — **§0z5** (program text never read as a path: an f-string field naming a file read it, one naming a directory hung the parser, `f"{...}"` hung on Windows; os.read/os.write on Windows' standard descriptors in binary; nylsp's stdin on Windows; nyaudit's path patterns on Windows; the round 86 suites under Wine; vm_audit125).
Round 86, part I — **§0z3** (HTTP/2 and HPACK beyond CPython: lib/hpack.ny (RFC 7541), lib/h2/ (RFC 9113 sans-I/O H2Connection with h2's API, hyperframe's frames, RFC 9218 priorities and scheduler, asyncio client/server with ALPN, h2.sync for http.client/urllib http2=), permessage-deflate (RFC 7692) for websocket.ny and a new websocket_asyncio.ny; HPACK admission control; two engine fixes - awaiting a coroutine's own __await__, prelude chunks loaded under threads; vm_audit123)
Round 86, part J — **§0z4** (Python-language source behaves as CPython where Nython is lenient: `is` identity, + with no str/non-str or list/tuple mixing, no int iteration, no dict keys as attributes, list.sort() None, literal spellings as names - one mark per node from the scope pass, read only on the lenient paths; strict ordering in sorted/min/max and CPython's messages everywhere; an int iterable wherever Nython code iterates; `--python-compat-report`; vm_audit124)
Round 85 (main session) — **§0y3** (the verification of round 85 merged; exceptions native code swallows let go of, generators weakly referenceable and hashable, the scripted-input harness under Wine, bytes.partition's separator object, the round 84 suites on Windows; vm_audit120)
Round 85, part F — **§0y2** (Python's binding rule for Python-language source - `.py`, `# nython: python`, code compiled from them, ast trees: a name a function binds is its local, UnboundLocalError; exec in such a function; a census of lib/ (`tools/ny_scopecheck.py`, `--scope-report`) and 435 ported modules marked Python-language; `-W nython-scope` warnings for Nython code; vm_audit119)
Round 85, part E — **§0y** (the names CPython's system modules have and Nython's lacked, measured by tools/api_diff.py against CPython 3.11/3.12 - 82.5% -> 94.1% of 9676 names: a posix module and the rest of posixmodule.c, time's clocks, signal's masks/waits/set_wakeup_fd, socket's ancillary data and constants, select.epoll, sys's int digit limit and unraisablehook, gc.get_objects/referents/referrers, ssl.RAND_*, hashlib.scrypt; subprocess on posix_spawn; vm_audit118)
Round 84, part A — **§0x** (memoryview and the buffer protocol on both engines - PEP 3118/688 exporters, casts, N-dim views, exported bytearrays that cannot resize; bytes-like arguments taking any buffer across the engines and the libraries; bytes % args, PEP 461; vm_audit112)
Round 84, part B — **§0x2** (the Unicode database - unicodedata complete from compact generated tables; str's case mappings and predicates by it on both engines; PEP 3131 identifiers; the CJK codecs ported from CPython's cjkcodecs; utf-7; mbcs/oem on Windows; idna's nameprep; Unicode-aware fuzzy matching; vm_audit113)
Round 84, part C — **§0x3** (tkinter, ttk and turtle over Nython's own GUI backend: a Tcl subset, Tk's core, pack/grid/place, the classic and ttk widgets, photo images, dialogs; CPython's tkinter package and turtle.py; vm_audit114)
Round 84, part D — **§0x4** (curses without ncurses: terminfo, tparm, ncurses' screen model and update algorithm, input and mouse, panels; a VT/xterm emulator the test compares with CPython+ncurses through; vm_audit115)
Round 84 (main session) — **§0w2** (the functions CPython implements in C are builtins: a table generated from CPython, sealed when their module has run; natives carry their module's names; PEP 562 module __getattr__/__dir__; int() through __index__/__trunc__, float() overflow; PEP 701 f-strings; an unbound name hidden by a method of that name; the library searched before the importer's ancestors; vm_audit117)
Round 84, ctypes and Windows — **§0w1** (ctypes structures passed and returned by value on every ABI without libffi - SysV eightbyte classification, AAPCS64, Win64, i686; Windows callback trampolines per float mask and stdcall; the Windows gaps round 83 left: zipapp path-hook recursion, liblzma's header errors, faulthandler's SIGSEGV, mmap's messages, AF_UNIX)
Round 84, part 0 — **§0w** (the semantic gaps rounds 82-83 found: module attribute messages, BaseException's members and builtins' docstrings as values, a finally body seeing its exception, strict and starred comprehension targets, sys.audit, True/None spelled by the program's language)
Round 83, ctypes — **§0v4** (ctypes over libffi loaded at run time, or Nython's own caller built on the calling conventions' register files; type's own members; a metaclass's operators on its classes)
Round 83, part B — **§0v** (Python's system and command-line modules: errno, fcntl, termios, tty, pty, resource, syslog, mmap, faulthandler, tracemalloc, locale, gettext, getopt, optparse, fileinput, filecmp, sched, cmath, colorsys, readline, rlcompleter, site, sysconfig, webbrowser, zipimport, zipapp, encodings, stringprep, bz2, lzma; module.__dict__ and hashable modules on both engines; VM comprehension results freed; vm_audit109).
Round 83, part C — **§0v3** (sqlite3 over libsqlite3 loaded at run time, its callbacks run by suspending a coroutine; dbm/shelve; the email package and the mail modules; smtplib/poplib/imaplib/ftplib/telnetlib/xmlrpc/wsgiref/cgi/netrc; plistlib; audioop and the audio-file modules; vm_audit110).
Round 83, part A — **§0v2** (Python's language-tooling modules: ast from the real parser's ast mode, tokenize/token, symtable, dis/opcode over the VM's bytecode with its adaptive view, marshal, pickletools, pydoc, pyclbr, tabnanny, py_compile, compileall, modulefinder, this, antigravity; tokens carry an end and a multi-line string its first line; vm_audit108).
Round 82, follow-ups (2) — **§0u5** (`import name` finds `.py` modules and packages, `.ny` first; quoted imports from anywhere; `threading.Lock` is Python's ownerless lock; tasks see their loop's thread in threading; `_thread`; vm_audit107).
Round 82, follow-ups — **§0u4** (asyncio where part B left it different from CPython - TaskGroup groups, wait(), CancelledError(), the default executor, create_server(None), sendfile, pipes, async generator hooks; a `gc` module; `fileno()` the OS descriptor; vm_audit106).
Round 82, part C — **§0u** (NyxAI: lib/aiagent.ny made a programming agent that works offline - BM25F retrieval, program facts from the real parser (`ny_facts`), a rule engine, test generation, docstrings, review and fixes, a completion model - and the IDE's AGENT view; vm_audit105, e2e `agent`).
Round 82, part B — **§0u2** (asyncio's missing half: the event-loop API over a persistent native loop, transports and protocols over TCP/UDP/Unix with flow control, streams rebuilt on StreamReaderProtocol, subprocesses waited for on the reactor, add_signal_handler and asyncio.run's Ctrl+C, TLS and start_tls, 3.12's cancellation rules, eager tasks, structured-concurrency reports; a GC heap-sampling fix that made many tasks quadratic, a VM break/continue-out-of-except leak; vm_audit104).
Round 82, part A — **§0u3** (the interpreter's remaining
costs: Python exceptions travelling by a pending flag instead of C++
throws, startup 2.5x/4x fewer instructions, loop targets bound from
enumerate/zip without a tuple; vm_audit103).
Round 81, follow-ups — **§0t4** (gaps the round's agents found: class lambdas bound, `del C.m`, `list.pop`'s index, UnboundLocalError, set iterators; a package's `__spec__` on Windows; vm_audit102).
Round 81, part A — **§0t** (the semantic gaps round 80 left:
`except ... as e` unbinding, a live `globals()` and the real `__main__`,
`__spec__` and `sys.meta_path`/`path_hooks` in the import statement,
attribute hooks assigned later, live list iteration, "P() takes no
arguments", CPython's default repr, `f_lineno` jumps and pdb's `jump`,
`sys.getrefcount`/`stdlib_module_names`/`displayhook`, `-OO`, deep
recursion on extension stacks; both engines).
Round 81, part B — **§0t2** (the tree-walking interpreter 3.09x faster - a
self-optimizing AST interpreter: in-node caches with guards, polymorphic
inline caches for method calls, attribute stores and class attributes,
speculative lexical addressing, slimmer Values, `return`/`break` through
`try`/`with` without C++ throws; `NY_ASTSPEC=0` turns it off; vm_audit100).
Round 81, part C — **§0t3** (live debugging: `nython --debug-port N`, a
DAP-style debug server over bdb with step back and Why? over a ring buffer
of recent statements; the IDE's live mode and PROFILE panel with a flame
graph from cProfile's new calling context tree). Round 80 — **§0s** (part A: the correctness gaps rounds
78-79 found - two interpreter crashes, object's members on every class,
`except <expression>`, numeric keys across int/float/Fraction/Decimal,
`sys.modules`/`__import__`/importlib/pkgutil/runpy, relative imports,
sys's facts and `sys.excepthook`, `-O`, a live `os.environ`, prelude code
immune to rebound builtins, `${...}` only in Nython source) and **§0s2**
(part B: os.fspath/scandir/file descriptors, posixpath/ntpath/stat/pwd/grp,
a full codecs module, multiprocessing over pickle with a work-stealing Pool;
both engines) and **§0s3** (part C: the VM 3.15x faster - a specializing
adaptive interpreter with inline caches, deoptimization and a type epoch;
`tools/bench/`).
Round 79 — **§0r** (zlib/DEFLATE written natively with an
opt-in Zopfli-style optimal parse; binascii, gzip, zipfile, tarfile, pickle
byte-identical to CPython's, copyreg, array; `__slots__` and `__class__`
assignment) and **§0r2** (decimal checked against 1,981 vectors, difflib
with patience/histogram diffs, tomllib, configparser, shlex, html, an XML
parser written in Nython under ElementTree and minidom, ipaddress,
graphlib, contextvars per task, concurrent.futures with real processes,
zoneinfo, mimetypes; live module namespaces) and **§0r3** (`sys.settrace`/
`setprofile` on both engines at one byte test when unused, PEP 667 frame
locals, bdb/pdb/cProfile/profile/pstats/timeit/trace/cmd/code, and Whyline-
style "Why?" questions in the debugger by dynamic slicing); both engines. Round 78 — **§0q** (lazy `range`, live dict views, lazy
zip/map/filter/enumerate/reversed), **§0q2** (frame objects, weak references to
functions/classes/sets, coroutine and async generator objects) and **§0q3**
(the data-model gaps: name mangling, methods bound whatever their first
parameter, `super` as a value, builtin values' dunders, data descriptors,
hashed keys, protocol results checked); both engines. Round 77 — **§0p** (bytes; signals; sockets, TLS, HTTP,
urllib, WebSockets and the network libraries made real; asyncio and the
async protocols; modules with their own scope and packages; sets; the
command line and argparse; per-execution classes, slices, eval/exec,
complex numbers, `__setattr__`, docstrings, collections; positional-only
parameters; annotations, `__new__`, PEP 487/560/604, metaclasses,
NotImplemented; `type()` giving type objects; ~60 Python standard-library
modules (abc, enum, dataclasses, typing, inspect, traceback, warnings,
weakref among them) and a ReDoS-immune regex engine; real tracebacks; both
engines).
Round 76 — **§0o** (the "Not done" lists of rounds 74-75
closed: static scope checks, lambda closures, error columns, async tasks
as coroutines, rwlock succession, objects used as dict keys and suspended
generators collected; both engines). Round 75 — **§0n** (real SDL3, HiDPI, every test in the
sweep), **§0m** (strict attribute and key reads with optional chaining
and `??`, the scope ruling and `global`, suffix literals; both engines),
**§0l** (lazy generators) and **§0k** (garbage collection on both
engines). Round 74 is **§0e** (IDE responsiveness: native
text services and a responsive layout ladder; the Code::Blocks feature set;
non-throwing control flow on both engines; the build system) and **§0f**
(the OS layer: files, paths, processes, environment and time, with one
implementation for both engines) **§0g** (threads, synchronisation and
async on both engines) **§0h** (nytorch: one native tensor engine for
both engines, real models) **§0i** (Python values and builtins on both
engines) and **§0j** (exceptions, classes, scope and syntax on both
engines). §0d is
round 73 (the IDE to VS Code's model, verified by driving it). Earlier
rounds: §0/§0b language-level work, §5.3 terminal command line / undo /
multi-cursor (71b/71c), §0c nytorch autograd (72), §5.10 nytorch class-name
collisions.

---

## 0z2. Round 86, part H — nylsp, a Language Server for Nython (vm_audit122)

`examples/vm_audit122.ny` (169 checks, Nython-only: it drives the server as an
editor does - `sys.executable -m nylsp` as a child with pipes, framed JSON-RPC,
a fixture workspace under a per-pid temp dir) passes on both engines. Sweep
470 runs, 0 not ok and `tools/ide_e2e.py` 463 passed in the agent's worktree.

Every editor that speaks the Language Server Protocol (VS Code, Neovim, Emacs,
Helix, Sublime, Kate ...) gets the analyses Nython's own IDE has:
`nython -m nylsp` (stdio), `--tcp PORT` (one connection on 127.0.0.1),
`--log FILE`. The package header (`lib/nylsp/__init__.ny`) lists every method.

- **`lib/nylsp/protocol.ny`**: JSON-RPC 2.0 with LSP's Content-Length framing;
  JSON-RPC's and LSP's error codes; reads are non-blocking, so a
  `$/cancelRequest` is seen while a request runs (queued requests are answered
  RequestCancelled at once, the running one at its next check).
- **`lib/nylsp/workspace.ny`**: URIs and paths; the workspace scan and a
  per-module index (exports, imports, mtime, the importers graph) through the
  engines' own module search (`.ny` before `.py`, packages, relative and
  quoted imports); `workspace/symbol` by the native `fuzzy_rank`.
- **`lib/nylsp/server.ny`**: initialize/initialized/shutdown/exit with honest
  capabilities (exit status 0 after shutdown, 1 otherwise;
  ServerNotInitialized before initialize, InvalidRequest after shutdown);
  utf-16 (default), utf-8 and utf-32 position encodings; didOpen/didChange
  (incremental, UTF-16 ranges applied to a native piece table)/didSave/
  didClose; publishDiagnostics (syntax errors - several, by the recovery
  below -, NyScope's const/nonlocal errors, UnboundLocalError reads, the
  places where Nython's binding rule and Python's disagree as information
  with quick fixes, undefined names, unknown modules and imported names,
  NyxAI's review rules as coded warnings; importers re-checked when a
  module's exports change); completion (scope-aware names, keywords,
  builtins; after a dot the members of classes/instances/modules/packages/
  builtin types, bases across files; module names after import; nothing in
  strings or comments) + resolve; hover (signature, docstring, kind and the
  type inferred from the binding); signatureHelp (from the text, so it works
  while the call is typed); definition/declaration/typeDefinition across
  files through imports and re-exports; references/documentHighlight;
  prepareRename/rename as a WorkspaceEdit that follows each file's binding
  rule (Nython's in `.ny`, Python's in `.py`/`# nython: python`), members
  through instances and subclasses in other modules, keyword arguments
  (builtins and names outside the workspace refused); documentSymbol
  (hierarchical) and workspace/symbol; foldingRange (blocks, brackets,
  `#region`, comment blocks, import groups); formatting/rangeFormatting (the
  native formatter as Myers hunks); semanticTokens full and delta (the
  standard legend and modifiers); codeAction (NyxAI's fixes as quick fixes,
  `source.fixAll.nyxai`, `global x`/`var x` for binding-rule notes);
  inlayHint (parameter names at call sites); `$/progress` while the
  workspace is indexed (between requests); `nython/stats`,
  `nython/analysis`, `nython/documentText`.
- **`src/builtins/nylsp.cpp`** (+ `include/builtins/nylsp.hpp`), reached by
  `_ny_lsp(op, ...)` (text.cpp's dispatch; registered in `registerBuiltins`):
  the real parser twice - ast mode (Python's tree shape with token spans)
  and the engines' own parse (the SyntaxError, NyScope's errors and report) -;
  a binding analysis mirroring NyScope for both rules; the piece table; the
  semantic tokens and their delta; members, type resolution, call sites. It
  includes only the parser/lexer/NyScope headers, not NythonExecutor.hpp
  (seconds to compile).
- **Error recovery by indentation islands** (after Moonen's island grammars,
  2001, and tree-sitter's recovery): when the source does not parse, the
  statement around the error is cut out by the indentation and bracket
  structure and replaced, keeping the line count, by `pass` - or `if 1:` when
  an indented block follows, so that block stays an island the analysis
  still sees; a compound header whose bracket never closes is cut alone (its
  body survives); indentation errors blank their lines; a cut that does not
  help grows to the enclosing block; at most 10 rounds, each cut a
  diagnostic. Completion, hover, symbols and tokens keep working on a line
  being typed.
- **Incremental**: an edit touches only the piece table; the document is
  re-parsed when asked; edits inside one line reuse the last analysis; the
  index re-reads files whose mtime changed and re-checks importers up to
  three steps. Latency on ide_tools.ny (3070 lines), unloaded: first parse +
  symbols 50-100 ms, completion 2-15 ms, hover 0-10 ms, typing in a line
  8-35 ms (median); `self.` in nython_ide.ny's chain (1115 items) ~48 ms
  fresh, 0-4 ms cached; indexing the repository (1062 files) 10-16 s.

### Not done
- No inference of other modules' return values, container item types or
  values through calls (the binding's value and annotations only).
- Call/type hierarchy, code lens, document links, linked editing, selection
  ranges, on-type formatting, pull diagnostics, notebooks, file operations,
  renaming files/modules, semanticTokens/range; names inside f-strings are
  found and renamed but not coloured; NyxAI review only up to
  `maxReviewLines` (4000); the IDE does not use nylsp (it keeps its own
  services).
- Found, not fixed: lib/gui.ny line 16029 uses an undefined `ACC` in a dead
  `... if false else ...` branch (nylsp flags it).

---
## 0z. Round 86, part G — CPython's audit events everywhere CPython raises them, and audit policies (vm_audit121)

PEP 578's hooks are only as useful as the events the runtime raises. Round 84
gave Nython `sys.audit`/`sys.addaudithook` and five events; this round raises
the rest of CPython's, with its names and its arguments, on both engines.

- **The table** (`tools/gen_audit_events.py` -> `tools/audit_events.json`,
  191 events): the docs' `audit-event` directives (a CPython `Doc/` with
  `--doc DIR`, else the "Audit events table" they make on docs.python.org for
  3.11/3.12/3.13 - which version raises what), the host Pythons' `Lib/*.py`
  (raised from Python: a `sys.audit("name"` there), and probes: every
  python3.11-3.13 found runs a battery under a hook recording each event's
  argument types and whether a `sys.audit(` line raised it (dangerous calls -
  sethostname, ensurepip, a browser - vetoed by the hook). Each record:
  module, args (3.12's documented names), raised_from, versions, probe_types,
  docs, platform, and `nython` (where Nython raises it - engine, prelude,
  library - or why not). The probes found that CPython's docs name two events
  it never raises (`sys.set_asyncgen_hooks_firstiter/finalizer`: the C code
  raises `sys.set_asyncgen_hook_firstiter/finalizer`), that POSIX's
  `os.spawn*` raise os.fork (os.spawn is Windows-only), that a ctypes call
  raises nothing (`ctypes.call_function` is the private `_ctypes`
  function's), that `compile` gets the source as bytes, that input()'s
  result is reported only from a terminal, and that `cpython._PySys_ClearAuditHooks`
  reaches C hooks only.
- **The rule for engine audit points**: test `nyrt::audit_on()` (one byte)
  first; then the event goes to the prelude's `_ny_audit_fire`; and **not
  when the caller is the prelude** (`NythonExecutor::preludeCaller(ctx)` -
  the scope chain reaches `prelude_ctx_`; `auditCtx()` gives the running
  function's scope where no ctx is passed; VM `prelude_running()`): the
  prelude stands where CPython's C code does, so its own `id()` in a repr,
  `exec` in a helper or a generator's frame read by an async generator raise
  nothing. The engine's own identity for reprs is `_ny_id` (interpreter
  idHex) / `vm_identity` (VM default repr) - not id(), which audits.
- **A native reached through the VM's builtin bridge** raises into the
  VM's hooks: `NythonExecutor::auditForward()` (set by main.cpp's
  install_vm_builtin_bridge) converts the arguments (BridgeConv) and calls
  `VirtualMachine::bridge_audit_event`; the bridge lambda rethrows a
  `VMException` as it is (a hook's exception keeps its class).
- **The prelude chunk "audit"** (`src/NyPreludeAudit.cpp`, a unit of its
  own): what only a program with a hook needs - `_ny_audit_compile` /
  `_exec` / `_open`, the os events' `_ny_audit_dirfd` / `_id` / `_fsenc`,
  `_ny_audit_excepthook` / `_unraisable`, code.replace, `_ny_function_new`.
  The first `sys.addaudithook` loads it before the hook is in the list, so
  every caller that tests `_ny_audit_hooks` (or `audit_on()`) finds it
  defined; code.replace and `_ny_function_new` have stubs in the startup
  prelude that load it. With these in the startup prelude `-c pass` cost
  3.75% more instructions on both engines. An event whose arguments need a
  helper is written `if _ny_audit_hooks: _ny_audit_fire(...)`.
- **Measured against the base (4406438)**: `tools/bench/run.py` (the work,
  no hook) geomean 1.01x on the VM and 1.03x on the interpreter - noise on
  a shared machine, every benchmark's result equal to python3's; callgrind
  instructions: `-c pass` +1.6% (interpreter and VM: the startup prelude's
  inline guards and stubs, all lexing and parsing), `-c "import os"` +3.1%
  (the os chunk's audited wrappers and CPython's os.makedirs). Verified:
  sweep 470 runs, 0 not ok; `tools/ide_e2e.py` 463 passed; ide_lint,
  ide_memprobe, ny_classcheck, cbp (79 units) clean.
- Engine-level events: builtins.id, builtins.input/result (a terminal only),
  compile (bytes, filename; a tree with None - before lib/ast.ny takes it),
  exec (the code object: a source is compiled first - `_ny_audit_exec`),
  sys.settrace/setprofile, time.sleep (3.13's), object.__getattr__ for a
  function's `__code__`/`__defaults__`/`__kwdefaults__` and a generator's
  `gi_frame`/`gi_code`, object.__setattr__/__delattr__ for a function's
  `__code__`/`__defaults__`/`__kwdefaults__` and a class's `__bases__`,
  `__name__`, `__qualname__`, `__module__`, `__doc__` (setAttr/delAttrValue,
  set_attr/del_attr: `auditAttrStore`/`audit_attr_store`), function.__new__
  (`types.FunctionType(code, globals)` now works for a code object compile()
  made - the prelude's `_ny_function_new`), cpython.run_file/run_command/
  run_module/run_stdin (to a policy installed by the command line).
- Prelude: builtins.breakpoint, the frame's f_code, a traceback's tb_frame,
  a coroutine's cr_frame/cr_code, an async generator's ag_frame/ag_code,
  `__class__` assignment (`_ny_set_class`), sys._getframe, the new
  sys._getframemodulename (3.12) / _current_frames / _current_exceptions
  (the calling thread's only), sys.set_asyncgen_hook_*, sys.excepthook
  (CPython's rules: a hook's RuntimeError suppresses the report) and
  sys.unraisablehook, code.replace() (new: copies either kind of code object,
  code.__new__), and the os module: every function CPython's posixmodule.c
  audits, with its argument conventions (-1 for a dir_fd not given, uid_t
  ids, os.putenv/unsetenv/system encoded on POSIX, os.open's flags with
  O_CLOEXEC); the natives os.system/remove/unlink/rmdir/chmod/chdir/symlink/
  utime/unsetenv got prelude wrappers that audit and call them, and
  os.makedirs is CPython's (one os.mkdir per directory).
- Library: _thread / threading (3.12's start_new_thread), array, marshal,
  mmap, resource, fcntl (an argument not given is None in the event),
  syslog, sqlite3 (connect, connect/handle, enable_load_extension,
  load_extension), pickle.find_class, pdb.Pdb, glob, pathlib (glob, rglob,
  walk), shutil (each of CPython's - and shutil.chown, which raised
  NotImplementedError, is CPython's over os.chown), tempfile, subprocess
  (CPython's executable/args shaping), urllib.Request, http.client, ctypes
  (dlopen, dlsym, addressof, cdata, cdata/buffer, the buffers, string_at,
  wstring_at, errno), socket (every audited function and method).
- `sys.audit` checks nothing while no hook exists (`sys.audit(5)` is None),
  as CPython's.
- **`lib/nyaudit.ny`** (Nython's own): declarative policies - `Policy(default=
  "deny")`, `.allow/.deny/.log(event_glob, *arg_patterns, **named)` by the
  documented argument names, first match decides, `AuditDenied` (a
  PermissionError) from the audited call, frozen once installed, `granted()`
  lends a capability for a with block; a text file format and a JSON form;
  `derive(log)` writes a policy allowing what a logged run did. After the
  PEP 578 sandboxing discussions and the object-capability literature
  (Miller 2006): default-deny, grants attenuated by argument patterns, no
  self-loosening. `nython --audit-policy FILE` installs one before the
  program's first statement (cpython.run_* is its first event), `--audit-log
  FILE` logs every event as JSON lines, `nython -m nyaudit derive LOG`.
- Not done: msvcrt/winreg/_winapi (no such modules), nntplib and ensurepip
  (absent), sys.monitoring, xattr-free platforms' os.*xattr, os.startfile/
  add_dll_directory/listdrives (Windows), ctypes.set_exception (SEH), the
  import system's own open/compile/exec events for a module's file (Nython's
  import raises `import` only), input() reading a replaced sys.stdin (it
  reads the process's stdin whatever sys.stdin is - found, not fixed).
## 0z3. Round 86, part I — HTTP/2, HPACK and WebSocket compression (vm_audit123)

Beyond CPython's standard library (it has none of this): the RFCs are the
spec, the python-hyper packages' API shapes (`hpack`, `h2`, hyperframe) and
the websockets package's (permessage-deflate factories, asyncio
connect/serve) where an API was needed. Every sans-I/O module is written in
the subset of the language CPython also runs, so vm_audit123 loads them in
python3 with a `sys.meta_path` finder (SourceFileLoader over the `.ny`
files) and runs the same checks there: **242 checks; 242 pass on the
interpreter and the VM, 233 under python3** (the http.client /
urllib and lib/websocket.ny sections are Nython-only).

Verified at the end: `tools/sweep.py` 470 runs, 0 not ok (with the API
baseline check and cbp); `tools/ide_e2e.py` 463 passed, 0 failed; class
check clean; vm_audit123 passed 28 times in a row under 4-8 parallel runs.

Interop was checked outside the test as well (not in the suite: they need
packages and tools the container lacks by default): curl 8.5 / nghttp2 1.59
against h2.server (`--http2-prior-knowledge`, `--http2` over TLS with ALPN,
uploads, 300 KB downloads, `-Z` parallel streams); h2.client against the
`h2` 4.4.1 package's server; frames byte for byte against hyperframe 6.1.0
(which serializes an ExtensionFrame with a zero length - ours is right);
websocket.ny with deflate against websockets 17.2 both ways (it refuses a
window of 8 bits, as it says; we accept it - below).

### Modules

- **`lib/hpack.ny`** — RFC 7541: static table, FIFO dynamic table with O(1)
  lookups by insertion number, integers, the Huffman code (Appendix B's
  lengths only - the code is canonical, the codes are rebuilt and checked
  against the RFC's table), a nibble-at-a-time decoder table (nghttp2's
  approach) built on first use, every representation, table size updates
  (the smallest since the last block, then the final, 4.2), the decoder's
  limits and errors. Encoder output equals Appendix C byte for byte (the
  hpack package's choices: static table first, incremental indexing,
  never-indexed when sensitive). huffman=True codes a string only when that
  does not make it longer.
- **`lib/h2/`** — `connection` (H2Connection: the whole RFC 9113 state
  machine, sans I/O; the module header lists what is enforced), `frame`
  (hyperframe's API, + RFC 9218's PRIORITY_UPDATE), `events`, `errors`,
  `exceptions`, `settings`, `config`, `stream`, `utilities` (field
  validation, RFC 9113 8.2/8.3), `priority` (RFC 9218: Structured Fields
  dictionary parsing, the scheduler), `_aio` (the asyncio driver both sides
  share: a read task, a write task that asks the scheduler which stream
  sends the next frame, flow control waits counted as `blocked`), `client`
  (connect/request; TLS with ALPN "h2" or prior-knowledge h2c), `server`
  (serve(handler): one task per stream; graceful close by RFC 9113 6.8's two
  GOAWAYs and a PING), `sync` (a blocking session for http.client).
- **http.client / urllib.request** — `HTTPSConnection(..., http2=True)`
  offers ALPN h2,http/1.1 and speaks HTTP/2 when it is selected
  (`HTTP2Response`, `version` 20, trailers); `HTTPConnection(...,
  http2="prior_knowledge")`; `urlopen(..., http2=...)`,
  `HTTPSHandler(http2=)`, `HTTPHandler(http2=)`. Off by default.
- **`lib/permessage_deflate.ny`** — RFC 7692: the extension header grammar,
  client and server factories (every parameter, the answer checked), the
  per-message codec over raw DEFLATE with Z_SYNC_FLUSH, context takeover,
  BFINAL streams, RSV1 rules, max_size enforced while inflating.
- **`lib/websocket.ny`** — permessage-deflate negotiated by default
  (`compression="deflate"`, as the websockets package; `compression=None`,
  `extensions=[...]`), `conn.extension`.
- **`lib/websocket_asyncio.ny`** — the asyncio client and server
  (`async with connect(...)`, `async with serve(...)`), same protocol rules,
  deflate included.

### Beyond the packages (the innovations)

- **HPACK: what to index** (`hpack.SmartIndexing`, opt-in). RFC 7541 fixes
  the FIFO eviction but leaves admission to the encoder: short credentials
  never indexed (7.1.1/7.1.3), a "cache on second hit" doorkeeper for values
  predicted to be one-hit wonders (high character entropy, or a name whose
  values rarely repeat - Maggs & Sitaraman 2015, TinyLFU's doorkeeper), and
  7.1.2's penalty for names with many distinct values (no longer compared
  with nor added to the table). `compression_report()` on vm_audit123's
  browsing-session corpus: requests 5223 -> 5039 octets (4 KiB table),
  10662 -> 5542 (1 KiB); responses 8205 -> 7337 (1 KiB) but 6174 -> 6324
  (+2.4%) with 4 KiB - a table with room loses little to one-off entries and
  a literal without indexing names a static entry past 14 in two octets.
- **RFC 9218 server scheduling** (`h2.priority.PriorityScheduler`, used by
  h2.server): urgency strictly first; within an urgency the non-incremental
  responses one at a time in stream order and the incremental ones round
  robin - with the non-incremental queue taking part in the round robin as
  ONE member, so neither kind starves the other (RFC 9218 10 warns about it
  and leaves it open). The server announces SETTINGS_NO_RFC7540_PRIORITIES;
  PRIORITY_UPDATE received before its stream is buffered (7.1). vm_audit123
  watches the order on the wire: `BCDECDECDEFA` for u=5, u=1, u=3 i, u=3 i,
  u=3, u=3.
- **permessage-deflate with 8-bit windows**: zlib cannot compress with a
  256-byte raw window; asked for 8, the compressor runs at 9 bits, whose
  matches never reach back more than 2^9 - 262 = 250 bytes (MAX_DIST), so
  the peer's 256-byte window holds them all.
- **CONTINUATION flood** (the 2024 vulnerability class): a field block
  growing past 4x the header-list limit is ENHANCE_YOUR_CALM.

### Engine changes (all marked "round 86")

1. `include/NyPrelude.hpp`, `_ny_await_iter`: an `__await__` that returns a
   coroutine's own `__await__()` (a `_NyCoroWrapper` over a coroutine not
   started yet) is awaited as that coroutine. It was driven by hand
   (`_ny_drive_await`), and a hand-driven coroutine's native waits park the
   task without letting the loop run - a wait for another task never ended
   (`await connect(...)` of websocket_asyncio, the websockets package's
   shape). Both engines (the prelude is theirs).
2. `include/NythonExecutor.hpp` (`ensureMirror`, `mirrors_loading_`,
   `MirrorLoading`) and `include/VirtualMachine.hpp` (`load_mirror`, the
   same): a lazily loaded prelude chunk was marked loaded before its
   definitions ran; with threads the GIL can change hands during the load,
   and another thread then used memoryview without members ("object of type
   'memoryview' has no len()", half the runs of the http.client test, whose
   server runs on another thread). A thread finding a chunk being loaded by
   another waits for it (GIL released, 200 us steps); the loading thread
   carries on as before. vm_audit123 has six threads make the process's
   first memoryviews at once: the round 85 binary failed it in 4 runs of 4.

### Not done

- Server push from h2.server (the sans-I/O push_stream exists; the client
  refuses pushes, as the brief asked); the h2c upgrade's HTTP/1.1 half
  (RFC 9113 removed it; the HTTP/2 half, initiate_upgrade_connection, is
  there); RFC 8441's extended CONNECT (WebSockets over HTTP/2) beyond
  validating `:protocol`; RFC 7540 dependency-tree scheduling (PRIORITY is
  parsed and reported only, as RFC 9113 allows); ALTSVC is sent and
  reported, not acted on.
- http.client keeps its one-request-at-a-time model on HTTP/2 (h2.sync can
  multiplex; http.client does not expose it); urllib's opener opens one
  connection per request as for HTTP/1.1.
- websocket.ny's sync code was not rebuilt on a sans-I/O core shared with
  websocket_asyncio.ny: the two implement the same rules twice.
- Found, not fixed: a TLS server's handshake can still be completing when
  asyncio.run shuts down (Nython's TLS handshakes finish later than
  CPython's); the client_connected_cb task it then starts is not among the
  tasks asyncio.run cancels, and its done callback runs once the loop is
  closed ("Exception in default exception handler"). CPython has the same
  window, rarely hit. A coroutine driven by hand still cannot wait for
  another task of its loop (engine change 1 covers the common shape only).
## 0z4. Round 86, part J — Python-language source behaves as CPython where Nython is lenient (vm_audit124)

**The rule.** Round 85 (§0y2) gave Python-language source - a `.py` file,
a file whose leading comments say `# nython: python`, code compile() /
exec() / eval() compile from one, an ast tree, a def opting in on its def
line - Python's binding rule. This round gives it the rest of Python's
semantics wherever Nython has a convenience. Valid Python now means there
what CPython makes of it:

| Python-language source | now (CPython's) | Nython-language source (unchanged) |
|---|---|---|
| `1 is int`, `"a" is str`, `obj is C` | identity: False | Nython's type test |
| `"a" + 1`, `1 + "a"`, `"a" + None`, `True + "a"`, `"a" + obj`, `s += 1` | TypeError, CPython's messages (`can only concatenate str (not "int") to str`, `unsupported operand type(s) for +: 'int' and 'str'`) | concatenation of the text |
| `[1] + (2,)`, `t += [2]` | TypeError (`can only concatenate list (not "tuple") to list`) | a list |
| `sum(["a", "b"])` | TypeError (0 + "a") | `"0ab"` |
| `for x in 5`, `[x for x in 5]`, `(x for x in 5)`, `list(5)`, `iter(5)`, `tuple/set/sorted/sum/max/any(5)`, `enumerate(5)`, `zip(5, 5)`, `map(f, 5)`, `yield from 5`, `xs.extend(5)` | TypeError: 'int' object is not iterable | range(n) |
| `{"a": 1}.a`, `getattr(d, "a", x)`, `hasattr(d, "a")` | AttributeError / x / False | the key |
| `d.a = 1`, `setattr(d, "a", 1)` | AttributeError: 'dict' object has no attribute 'a' | sets the key |
| `xs.sort()`, `xs.reverse()` | None | the list (for chaining) |
| `xs[len(xs)] = v` | IndexError: list assignment index out of range | the list grows |
| `true = 3`, `none`, `null`, `undefined`, `false`, `def f(elseif=1)`, `f"{true}"` | ordinary names | literals / a keyword |

and in **every** file (defects, both engines):
- sorted / min / max / list.sort order only what Python orders: values it
  cannot compare are CPython's TypeError ("'<' not supported between
  instances of 'str' and 'int'"; min/max compare `item < best` / `item >
  best` as CPython's min_max, so the operands are named in its order).
  They fell back to type name, then text: `sorted([1, "a"])` sorted and
  `max("a", 1)` answered. Bytes compare by their bytes; a NaN compares
  false; two sets are compared item by item as before (CPython orders them
  by inclusion - not done).
- `[1, 2]["0"]` (and `(1, 2)["0"]`, `[1]["__len__"]`) is a TypeError on the
  interpreter: it found the item the list keeps under the key "0".
- Messages as CPython's: `"a" * "b"` / `[1] * 1.5` / `None * "a"` "can't
  multiply sequence by non-int of type 'str'"; `[1] + 1` "can only
  concatenate list (not "int") to list"; `"abc"[1.0]` "string indices must
  be integers, not 'float'" on the VM; `a, b = 2` / `a, *b = None` "cannot
  unpack non-iterable int object" (it said "'int' object is not
  subscriptable").
- Interpreter: `sorted(it, key=f)` over an object iterator (scandir's) lost
  `key=` - a builtin `__next__` called (len) took the call's keyword
  arguments (`iterableBuiltin` now runs the iteration under
  `KwScope(this, nullptr)`). The lenient ordering had hidden it.

**An int is iterable in Nython code wherever Nython iterates** (the
decision this round was asked to make): `for i in n`, comprehensions,
generator expressions and every builtin that consumes an iterable - list,
tuple, set, frozenset, iter, sorted, sum, min, max, any, all, enumerate,
zip, map, filter, list.extend, a list's `+=`, `*n` in displays and calls,
`yield from`. The engines disagreed: the interpreter's `list(5)` raised and
its `iter(5)` worked, the VM's the other way round. Not `x in n` (round
77's TypeError stays) and not unpacking (`a, b = 2`, `for a, b in [2]`:
CPython's TypeError on both, as for statements' targets already were): a
fixed count of targets taken from a number is never meant. In
Python-language source an int iterates nowhere.

**Mechanism: one mark, set where the rule is known, read on the lenient
paths only.**
- NyScope's walk (`src/NyScope.cpp`) sets `Node::py_src = 1` - a byte in
  what was padding after `Node::_type` (include/Node.hpp): no node grows -
  on every node it walks in a scope under Python's rule, and
  `FunctionNode::py_rule` / `LambdaNode::py_rule` to the body's own rule
  (the def-line opt-in included).
- Interpreter: the node's flag where the node is at hand - evalBinary's
  `is` (identity) and binaryOp (the node's 1/0 in opc's upper bits,
  `binaryOp(opcRule(opc, bn->py_src), l, r, ctx)`; a plain opc - sum's -
  asks `pyCode()`. **Not a parameter**: binaryOp has six register
  arguments, a seventh went on the stack and gave evalBinary a frame
  pointer, +3 instructions per operator, +0.26% on fib), evalAugAssignment,
  evalFor's int branch, comprehension clauses, generator expressions'
  clauses (NyGen's `open(..., py)`), evalAttribute / evalAugAssignment's
  attribute read (after a read succeeded, `pyDictKeyRead(obj, attr)`: was
  it a plain dict's key? - a test inside getAttrValue cost deltablue 3.3M
  instructions), attribute stores -> `dictAttrStoreCheck`. Builtins ask `pyCode()` - the running
  lambda's `py_rule` (a lambda body has no statements), else the running
  statement's `py_src` (`cur_stmt()`) - on their rare paths only:
  iterItems' and NyGen `open`'s int case, sum's lenient +, list.sort /
  reverse's result, setItem past the end, getattr / hasattr / setattr.
  `callerPython()` (exec/compile's rule) asks it too.
- VM: `VMCode::py`, set by the compiler from the root's / function's /
  lambda's mark (`push_code` makes class bodies and comprehensions inherit
  it), read as `vm_py()` (the top frame's code - a builtin's caller) on the
  same rare paths: binop's str + non-str and list + tuple, BINARY_ADD's
  str(instance), loop_iter / iter_items' int case, `get_attr` /
  `lookup_attr` / `try_get_attr(..., py)` from LOAD_ATTR (the frame's
  code) and getattr / hasattr, STORE_ATTR / setattr on a plain dict
  (`dict_keys_hidden`), list.sort / reverse, set_sub past the end. `x is
  <type word>` compiles to COMPARE_IS instead of COMPARE_IS_TYPE in
  Python code - decided at compile time.
- **The specializing VM keeps the distinction without a check of its
  own**: no specialized form handles a lenient case (BINARY_ADD_NUM takes
  numbers, LOAD_ATTR_* never a plain dict - its MAP form needs a class
  name -, FOR_ITER_RANGE a range object, CALL_METHOD_BUILTIN calls the
  method table, whose sort reads vm_py()), so a failed guard falls to the
  generic path, which reads the code's flag. Same for the interpreter's
  self-optimizing nodes (round 81): their fast paths are numbers and
  instances' own fields.
- Lexer: `Lexer::python_names` (`nython::scope::lexer_python`: this
  thread's RuleScope - exec/compile from Python code -, else
  python_source; never the prelude, "stdin") leaves `true`, `false`,
  `none`, `null`, `undefined`, `elseif` Identifiers (tested after the
  keyword loop: inside it the test cost the lexer 0.9M instructions at
  startup). f-string fields' sub-lexers inherit it; `ast.parse` forces it
  (CPython's parser: `ast.parse("true")` is a Name). `super` stays
  Nython's, and the def-line opt-in cannot change tokens (the literal
  spellings stay literals in such a function).

**The libraries.** The 435 Python-language library files got all of this.
65 of them spelled Nython's literals - 4,709 `none`/`true`/`false` tokens,
rewritten to `None`/`True`/`False` by a token-aware pass (no f-string
field or exec'd template used them). Their identity tests (`t is int`,
`x is _empty`, `line is NeedMoreData`, `origin is tuple`) are identity
now whatever the left operand holds (Nython's `is` made `x is C` a type
test for an instance of C). The sweep found nothing else in them that
relied on a leniency; the strict ordering found `lib/gui.ny`'s table sort
(a key of "" for missing cells and numbers otherwise: now `[rank, number,
text]`). `examples/vm_audit96.ny` and `vm_audit119.ny` (Python-language
test files) tell the engine by `sys.implementation.name`: `true` is a
NameError there now.

**Innovation: `nython --python-compat-report FILE...`** - a static
portability lint for Nython-language code meant to run under CPython too:
for each file, every construct whose meaning differs from Python's, as
`file:line:col: kind: message` - `concat` (a str joined with a value
that is certainly not one: a number, a bool, None, a display, len(...),
arithmetic), `int-iter` (`for i in 10`, `for i in len(xs)`, list/sorted/
enumerate/zip/map of an int expression, a comprehension over one),
`is-type` (`x is int` with a builtin type word the program does not bind,
and on the left what is not known to be a class - not `type(x)`,
`x.__class__`, a name bound only to those, to a type word or by a loop
over an `__mro__`/`__bases__`, nor a name or field named as classes are:
`cls`, `tp`, `typ`, `base`, `origin`, a capital letter, `*type`,
`*class`; Nython's `is` compares classes by identity too),
`dict-attr` (`conf.port` read or set where `conf` is bound only to dict
displays in its scope), `literal` (true/false/none/null/undefined, checked
against the source text so desugarings are not reported), `sort-value`
(list.sort()/reverse()'s value used) and `binding` (the round-85 binding
differences, from the same pass as --scope-report). Python-language parts
(py_src) are skipped. The idea is Python 2.6's `-3` switch (PEP 361:
warnings at the places where Python 3 would differ) and 2to3's fixer list,
and the "differences from CPython" pages PyPy and Jython keep: the
incompatibilities named and located instead of found by failures. Run
over the 435 Python-language library files with their marker taken out
(so the lint sees them as Nython code) it reports the 68 binding cases
round 85 counted and 6 is-type lines, all false positives (a variable
holding a class or a function: `tf is str` for sqlite3's text_factory,
`parse_float is float`, `possible is object`) - and nothing else. That is
how the lint was tuned: before, `max(0, i + n)` was an int-iter (only
positional arguments count now) and 112 more identity tests of class
variables (`t is int` after `t = type(v)`, `for b in cls.__mro__: if b is
object`, `member_type is int`) were is-type lines.

**Cost** (instructions executed, valgrind cachegrind, new / base 4406438 -
machine load does not enter; tools/bench's programs, all Nython-language):

| | VM | interpreter |
|---|---|---|
| `-c pass` (startup) | 1.0009 | 1.0013 |
| bm_closures | 1.0003 | 1.0015 |
| bm_deltablue | 0.9999 | 0.9997 |
| bm_dict_str | 1.0010 | 0.9999 |
| bm_exceptions | 1.0007 | 0.9999 |
| bm_fannkuch | 0.9985 | 1.0000 |
| bm_fib | 1.0002 | 1.0016 |
| bm_generators | 1.0004 | 1.0009 |
| bm_nbody | 1.0012 | 0.9986 |
| bm_raytrace | 1.0004 | 0.9979 |
| bm_richards | 1.0006 | 0.9976 |
| bm_spectral_norm | 1.0001 | 1.0008 |
| bm_str_case | 1.0015 | 0.9988 |

Within ±0.2% everywhere. `tools/bench/run.py --base` (wall time, the
machine shared with other agents): geometric mean 0.98x, 0.98x, 1.00x on
the VM in three runs and 1.00x on the interpreter - noise, the base
against a copy of itself gave 1.01x. What it took (each found with callgrind diffs
against the base): startup +1.25M instructions with the lexer's literal
test inside the keyword loop (now after it, +0.27M: the scope pass's mark
and Node's byte); deltablue +3.3M with the dict-key test inside
getAttrValue (now a post-check, `pyDictKeyRead`); closures +0.4% (VM)
with set checks in sort_less and a direction argument (now none, and a
template); fib +0.26% (interpreter) from a seventh argument to binaryOp,
which put it on the stack and gave evalBinary a frame pointer (now
`opcRule`); hasattr/getattr asked pyCode() on every call (now only for a
container receiver whose read succeeded).

**Not done**
- `[*5]` / `f(*5)` in Python-language source say "'int' object is not
  iterable" (CPython: "Value after * must be an iterable, not int").
- `d.f()` calling a function stored under a dict's key `f` still calls it
  in Python-language source (CPython: AttributeError) - reads, stores,
  getattr/hasattr/setattr are strict, the method call path is not.
- `super` stays a hard keyword in Python-language source; the def-line
  opt-in changes semantics, not tokens.
- Two sets in sorted()/min()/max() are compared item by item (both
  engines, as before), not by inclusion.
- The lint's is-type cannot tell a variable holding a class or a function
  from a value it does not see bound (6 lines in the library run above).
- Found, not fixed: type names in messages are the module-qualified class
  names (`can only concatenate str (not "m.Obj") to str`, `'m.Obj' object
  has no attribute 'x'`) for a class defined in an imported module, on
  both engines; CPython says `Obj`.

**Verified**: vm_audit124 219 passed on both engines, 151 under python3
(the shared part; Nython-only checks skipped there); vm_audit53/72/74/76/
79-83/96/97/104/109/110/119/120 pass on both; sweep 470 runs, 0 not ok;
`tools/ide_e2e.py` 463 passed, 0 failed; ide_lint, ny_classcheck, cbp
check clean.

---


**Merged with parts G, H and I** (main session): J's rewrite of the Nython
literal words in Python-language lib files met G's and I's new code in seven
files (array, http/client, shutil, socket, subprocess, threading,
urllib/request); after the merge 101 lowercase `none`/`true`/`false` that G
and I had written there were respelled by a token-aware pass (a literal word
is a plain name in Python-language source now, so each would have been a
NameError), and a scan of all 459 Python-language lib files found none left.
**New code in a `# nython: python` file must spell `True`/`False`/`None`.**
Verified merged (G, H, I, the main session's fixes and J): sweep 478 runs,
0 not ok; `tools/ide_e2e.py` 463 passed; memory probe, lint, class check,
cbp (80 units) and the API baseline clean; under Wine (64-bit) vm_audit124
219, vm_audit119 85 and vm_audit125 14 pass on both engines.

## 0z6. Round 87, part K — the semantic gaps round 86 found, and a differential tester (vm_audit126, `tools/difftest.py`)

`examples/vm_audit126.ny` (NN checks) passes on both engines and under python3
(all of them there: the Python-language parts run as a `.py` child on the same
engine, the rest is valid Python whose meaning agrees). Sweep: SWEEP.

**1. input() with replaced streams.** `input()` read the process's stdin
whatever `sys.stdin` was. CPython's builtin_input_impl uses the objects off a
terminal: `sys.stderr.flush()` (errors ignored), `sys.stdout.write(str(prompt))`,
`sys.stdout.flush()` (a missing or failing flush ignored), `sys.stdin.readline()`,
"object.readline() returned non-string" for anything but str/bytes, EOFError on
an empty line, the trailing "\n" taken off; `sys.stdin = None` (or deleted) is
"input(): lost sys.stdin" (stdout, stderr too). The engines' input (core.cpp,
`VirtualMachine::vm_input`) compare sys.stdin/stdout with the streams sys
starts with (`_ny_stdin` / `_ny_stdout`, by identity) and hand a replaced pair
to the prelude's `_ny_input`; the console path is unchanged (and keeps
`builtins.input/result`, which CPython raises on its terminal path only).
`NythonExecutor::sysMember` reads sys's live namespace.

**2. `f.__defaults__` / `f.__kwdefaults__` assigned** were only remembered.
Now CPython's checks ("__defaults__ must be set to a tuple object", "...a dict
object"; None and `del` remove them) and the values are what later calls use:
a tuple's values go to the last positional parameters (CPython's
`co_argcount - len(defaults)` alignment), a dict's to the keyword-only ones;
the tuple set is the one read back (`f.__defaults__ is t`), `()` reads `()`,
inspect.signature sees them (`_ny_fn_info` reads the same tables).
- Interpreter: `fn_default_mask_` - per function value (and per node, for the
  method calls that bind through the node without the value) which parameters
  have a default now; `fn_defaults_val_` / `fn_defaults_node_` hold the
  values. `paramHasDefault(defs, i, callee_ptr, node)` replaces the AST test in
  every binder; it reads the table only while it is not empty (one test).
- VM: a function value made with defaults has its own vector (`VMVal::list`,
  shared by its copies): rewritten in place. One made without has none - and
  its identity (`func_key`: code, closure, list) says so - so its defaults go
  to `fn_defaults_set_` by that identity; `fn_defaults_of(fn)` is what
  call_function and fn_info read.
- Also: "f() missing 2 required keyword-only arguments: 'k' and 'm'" (both
  engines said "positional"): `ny_arity_error` takes keyword-only names marked
  "\x01" and reports CPython's way (positional ones first).

**3. `C.__bases__` assigned** changed nothing. Now CPython's type_set_bases:
`lib/_nybases.ny` (imported by the prelude's `_ny_bases_check` the first time;
Python-language, and itself runnable under CPython) checks in CPython's order
and words - "can only assign tuple to C.__bases__, not list", "...non-empty
tuple...", "C.__bases__ must be tuple of classes, not 'int'", "a __bases__
item causes an inheritance cycle", "type 'bool' is not an acceptable base
type", "multiple bases have instance lay-out conflict", "__bases__ assignment:
'int' deallocator differs from 'A'", "...'list' object layout differs from
'A'", "duplicate base class A", the MRO error with the heads CPython lists,
"cannot set/delete '__bases__' attribute of immutable type 'int'" - over a
model of CPython's instance layouts (a class's tp_base = best_base of its
bases, whether a type is GC-tracked = its deallocator, the type a layout comes
from = compatible_with_tp_base walked up, the slots it adds). Checked against
CPython: 507 assignments over 29 kinds of class (heap classes with and
without slots, int/list/dict/str/float subclasses, exceptions with and
without their own layout, builtins) give CPython's answer and message in every
case. Then the engines rebuild the class: interpreter `setClassBases` (the
base nodes, `class_parent`, `subclasses_` moved, `++class_names_ver_` for
classDerivesFrom's memo, `mro_cache_` and the hook caches cleared,
`specInvalidate()`); VM `set_class_bases` (`VMCode::bases`/`parent_class`,
`subclasses_`, `mro_cache_` and the caches cleared, `vm_types_changed()`).
Method lookups, super(), isinstance/issubclass, `except` follow the new MRO at
once, and so do the subclasses' (their MROs are computed from the bases).
- New: `C.__base__` (both engines, `_nybases.base_of`).
- New: `int.x = v` / `type(None).x = v` is CPython's TypeError "cannot set
  'x' attribute of immutable type 'int'" (it was an AttributeError naming
  builtin_function_or_method / type).

**4. tempfile.mkstemp** returned a Nython file handle. It is CPython's
`_mkstemp_inner` now: `os.open(name, O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW
(|O_NOINHERIT)(|O_BINARY unless text=True), 0o600)` in a loop over random
names (FileExistsError -> next name; Windows' PermissionError for a directory
of that name too), the audit event per name tried, `(fd, abspath)`. bytes
components give a bytes path (mkstemp and mkdtemp; the other functions still
refuse bytes). pydoc and cgitb (`os.close(fd)`, `os.fdopen(fd, 'w')`) work
with it; vm_audit76's `except AttributeError: file_close(fd)` fallback is dead.

**5. socket.sendmsg / recvmsg** went through `_ny_os_call` (os_posix.cpp),
which had no address. Now natives of the socket layer (`_net_sendmsg` /
`_net_recvmsg` in net.cpp): the address parsed as sendto's (`parse_addr`, the
socket's family), the socket's timeout and the parked-task waits as send/recv
keep them, recvmsg's fourth item the sender's address (None on a connected
stream socket). POSIX only (Windows has no sendmsg in CPython either).

**6. `*x` / `**x` of the wrong kind**: CPython's messages and order.
- `[*x]`, `(*x,)`, `[a, *x]`, `f(a, *x)`: "Value after * must be an iterable,
  not NoneType"; `{*x}`: "'NoneType' object is not iterable" (the set
  display's own); `f(*x)` alone: "__main__.f() argument after * must be an
  iterable, not NoneType", checked after the keywords (CPython's
  CALL_FUNCTION_EX: `f(*None, **None)` reports the **); `f(**x)`: "...
  argument after ** must be a mapping, not int"; `{**x}`: "'int' object is
  not a mapping"; "keywords must be strings"; "got multiple values for
  keyword argument 'a'" (a ** mapping and a keyword, or two mappings). The
  callee is named as CPython's `_PyObject_FunctionStr` (the prelude's
  `_ny_function_str`: module.qualname(), qualname() for builtins).
- An int after `*` iterates in Nython code (round 86's ruling) and is the
  TypeError above in Python-language source. The starred displays' helpers
  are natives now (`_ny_list_cat`, `_ny_set_cat` and their `_py` forms, both
  engines); NyScope renames the callee to the `_py` form in Python-language
  scopes (a new VariableNode: the VM compiles a name from its token).
- VM: `f(*x)` alone compiles to x itself and CALL_EX's count bit 4 (checked
  there, after MAP_MERGE); LIST_EXTEND checks; MAP_MERGE's arg 1 marks a
  method call (the callee for the messages is under the map being built).
- Interpreter: `evalCallArgs(..., CallWho*)` - the callee, or the receiver and
  the method's name, for the messages only.

**7. Dict keys as attributes in Python-language source**: part J made reads,
stores, getattr/hasattr/setattr strict; the method call (`d.f()` calling a
function stored under "f"), `del d.k` and `delattr(d, "k")` were not. Now
AttributeError "'dict' object has no attribute 'f'" on both engines (the
interpreter's method-call branch on the attribute node's `py_src`, the VM's
CALL_METHOD / DELETE_ATTR on the code's `py`; one byte test each).

**8. `super` in Python-language source** is a name: the lexer leaves `super`
an Identifier unless `(` follows (`super = 1`, `super + 1`, a parameter or
lambda parameter or comprehension variable named super, `def take(super=3)`);
`super(...)` stays the engines' builtin call. NyScope records each
`super(...)` call in Python-language source; when a scope it sees binds the
name super (a parameter, an assignment, a module's own `def super()`), the
call becomes an ordinary call of the name (`Collector::super_calls`). So that
such a call still works when the name is the builtin again (`del super`), the
builtin `super` called by its name is now implemented on both engines
(`NythonExecutor::superBuiltin`, the VM's `super_proxy_of(frame)` - what
LOAD_SUPER makes, from the calling frame; the explicit two-argument form
too).

**9. Class names in messages**: a class of an imported module is keyed
"pkg.mod.Obj" (round 77) and the messages used that key ("'pkg.mod.Obj'
object is not callable"). They use the class's `__name__` now, as CPython's
tp_name: `msgClassName` (interpreter: typeNameOf for instances, the
not-iterable / not-subscriptable / no attribute / not callable / unary /
item assignment / unpack / `__init_subclass__` messages, "type object 'Obj'
has no attribute") and `bare_class_name(shown_class_name(...))` at the VM's
(vm_type_name, attr_error_text, unary_dunder - which used the raw key). Reprs
were module + qualname for a module's top-level classes only: a nested class
or one a function made said `<class '__main__.Inner'>` and `__module__`
"__main__" wherever it was defined. Now `<class 'pkg.mod.Obj.Inner'>` and
its module: the interpreter takes the module of the context the class
statement ran in (`class_ctx_map_` -> `moduleCtx`), the VM records it at
MAKE_CLASS (`VMCode::module_name`), and both reprs are `__module__` +
`__qualname__`. Also "unsupported operand type(s) for ** or pow()"
(CPython's words, both engines).

**10. A TLS handshake when asyncio.run() ends.** The server side ran its
handshake in an internal task (`_spawn_internal`), which asyncio.run's
`_cancel_all_tasks` does not see: the handshake went on after run() returned,
and started the client_connected_cb task after the loop was closed. It is a
task of the loop now (`loop.create_task(self._accept_tls(...))`, CPython's
`_accept_connection2`): cancelled with the others, the socket closed
(`_tls_handshake`'s `except BaseException: sock.close()`). The client side
(a handshake in the program's own task) was already cancelled and closed;
vm_audit126 checks both against a server that never answers / a client that
never sends its ClientHello, and that run() returns at once.

**11. The false DeadlockError under Wine** (vm_audit104's task_api, about one
run in two on both engines, round 85's build too). Root cause in
src/NyConc.cpp: a task put on a loop from another thread (`new_task_locked`:
call_soon_threadsafe's callback, run_coroutine_threadsafe, the executor's
result) notified the loop's condition variable but left the loop thread's
record `blocked_forever` - which only `make_ready` cleared, and the loop
itself only once it woke. A thread that blocked for good in between (the
executor's worker back at its queue: 'asyncio_0') ran the all-threads-blocked
check, saw the loop thread still marked, and raised. Under Wine the woken
thread runs late, so the window is wide. `new_task_locked` and
`async_loop_stop` now clear the loop thread's mark as `make_ready` does (and
wake a polling loop). The detector is unchanged. WINE.

**12. More of the same kind** - what `tools/difftest.py` (below) and probes
written from its findings turned up, fixed on both engines:
- `& | ^ << >>` of values that are no numbers gave 0 (`None >> 1`, `1.5 << 1`
  on the interpreter's shift path, `[1] | 1` / `"a" ^ "b"` / `x ^= "s"` on the
  VM): CPython's "unsupported operand type(s)" TypeError (the interpreter's
  binaryOp shift case, the VM's binop tail - every operator now). The VM's
  `- | & ^` of two lists were set operations, from before sets were a type
  (the interpreter raised): a TypeError on both.
- An augmented assignment's TypeError names the in-place operator, as
  CPython's ("unsupported operand type(s) for //=: 'int' and 'str'", "**="
  not "** or pow()"): the interpreter rewrites binaryOp's message in
  evalAugAssignment (`augRethrow`, in the handler: the other errors pass
  untouched); the VM compiles an augmented assignment's operator with arg 2
  and `binop_aug` does the same (arg 1 keeps its older meaning). `x @= 2`
  named no operands on the VM.
- `1 // 'ab'`, `x // [2]`, `x // {..}`, `x // ~y` read as a `//` comment
  (Nython's), so the line's tail vanished (a parse error further on, or a
  statement silently cut short). The lexer's heuristic takes a quote, `[`,
  `{` or `~` after `//` as an operand; in Python-language source `//` is
  always floor division.
- `x[a:b]` of a value with no slice method - `1.5[1:2]`, `None[0:1]`, an
  instance without `__getitem__`, a class: "'float' object is not
  subscriptable" / "type 'C' is not subscriptable" (it said "'float' object
  has no attribute 'slice'": the parser spells a slice `x.slice(a, b)`).
- `dict(seq)` / `d.update(seq)`: CPython's messages with the element's index
  ("dictionary update sequence element #1 has length 3; 2 is required",
  "cannot convert dictionary update sequence element #0 to a sequence" for a
  number or None); `NythonExecutor::dictUpdatePairs` (both interpreter
  sites), the VM's `dict_pair_check`.
- "tuple.index(x): x not in tuple"; getattr/hasattr/setattr/delattr's
  "attribute name must be string, not 'int'" (no "getattr(): " prefix, as
  3.11-3.13; vm_audit57 expected the old text and was corrected);
  "list.append() takes exactly one argument" on the VM; `isinstance(1, 2)`,
  `issubclass(1, int)` read False - CPython's TypeErrors for a number or None
  given as a class (a string still names a type in Nython code).
- A value sent through `yield from` to an iterator without `send()` (a
  list's, a str's, map's, an object without send) was dropped and the
  iterator stepped; CPython raises "'list_iterator' object has no attribute
  'send'" (NyGen.cpp's yield_from, the VM's YIELD_FROM_OP; a generator
  expression still takes it as next() does).
- `[a for a, *b in [5]]` counted up to 5 (the prelude's `_ny_star_shape`
  listed the item, Nython code iterating an int): "cannot unpack
  non-iterable int object", as an unpacking statement already said; and in
  Python-language source `[a for a, *b in 5]` iterated the int: "'int'
  object is not iterable" (NyScope names `_ny_star_iter`'s `_py` form there,
  as it does the starred displays' helpers).
- A lambda in a lambda was named `<lambda>`: CPython's
  `<lambda>.<locals>.<lambda>` (the parser pushes the lambda's qualname
  while it parses the body, as for a def) - the callee in "argument after *"
  messages too.
- `obj.__name__` / `obj.__qualname__` of an instance read its class's on
  the interpreter (the tag-derived special attribute); CPython and the VM
  raise AttributeError (an instance's own field or a class attribute of
  that name is still found first).

### tools/difftest.py - differential testing, after McKeeman 1998

`python3 tools/difftest.py [--count N] [--seed S] [-j 2]` generates programs
(Csmith-style, Yang et al. 2011, scaled down to Python: a seeded grammar of
classes with operator dunders and inheritance, closures, comprehensions,
generators and yield from, exceptions, unpacking, slicing, formatting,
numeric tower, augmented assignment, str/dict/set methods), runs each on
python3, the interpreter and the VM, and compares tagged observation lines
(every observation goes through a guard that prints the repr or the
exception's type and text, so a difference never hides the next). Each
disagreement group is reduced by delta debugging (ddmin over the statement
lists at every depth, then hierarchical expression reduction) under its
signature (engine, the kind of each side's line, the exception types), and
written to `--out` as a runnable `finding_<hash>.py` with the three outputs
in its header; a difference both engines make the same way is one finding
("interp+vm"). `--run P` / `--reduce P` work on one program; `--lang ny`
compares the interpreter with the VM on `.ny` programs. Generated programs
are deterministic (no ids, hashes of strings, set orders, time), and
`PYTHONHASHSEED=0` is set.

Its first runs (180 programs) gave about 60 disagreement groups; the ones
fixed are item 12 (and the class-name messages of item 9, which it found
first). The rest is under "Not done". Run it after any change to operators,
calls, generators or messages: a clean run is `0` groups for the units the
engines agree on.

### Not done

- A builtin subclass's constructor iterates an int in Python-language
  source: `class L(list): ...; L(2)` gives `[0, 1]`, `class D(dict)`:
  `D(2)` a dict-update error, `C1(2) + 1` (CPython: "'int' object is not
  iterable"). The prelude's mirror classes (`_NyB_list` ...) are
  Nython-language code and do the iterating; they would need the caller's
  rule.
- `abs(S("s"))` / `ord(L())` for a str/list subclass name the payload's type
  ("bad operand type for abs(): 'str'", CPython 'S'): builtins are handed the
  value, not the instance.
- `super(int, 1).x`: "super() argument 1 must be a type, not ..." where
  CPython gives "'super' object has no attribute 'x'".
- A dict key that is an instance of a str (int ...) subclass is stored as
  its value: `{C1("1"): 1}` shows `{'1': 1}` and its key's type is str
  (CPython keeps the key object; a set keeps it on Nython too). Keys are
  encoded by value so that `d["1"]` finds it; keeping the object needs a
  side table on both engines.
- `"s" % [1]`, `"s" % range(2)`: "not all arguments converted" - CPython
  takes any non-tuple with `__getitem__` as a mapping there and converts
  nothing (only a dict is a mapping to the shared formatter).
- Comparison messages for builtin subclasses name the payload's type
  ("'>' not supported between instances of 'C0' and 'list'", CPython 'C0'
  and 'C0').
- `'a'(*None)`: "a() argument after * ..." where CPython says "a argument
  after * ..." (`_PyObject_FunctionStr` of a non-function is its str).
- An int subclass with `__getitem__`: `max(C1(1), C1(2))` compares the
  instances as sequences ("'<' not supported between instances of 'int' and
  'list'"; CPython compares the ints) and `list(C1(1))` iterates the int
  payload (CPython uses `__getitem__`); a plain class with `__getitem__` in
  max's error names 'list'.

## 0z5. Round 86 (main session) — program text is never a path, raw standard descriptors on Windows, the round 86 suites under Wine (vm_audit125)

Verified with G, H and I merged and this: sweep 476 runs, 0 not ok;
`tools/ide_e2e.py` 463 passed; memory probe, lint, class check, cbp (80
units) and the API baseline clean. **Windows (Wine, 64-bit)**, both engines:
vm_audit121 87 passed (the POSIX-only cases skipped), vm_audit122 169,
vm_audit123 235, vm_audit125 14 - 122 had never finished there (the
f-string hang, then nylsp's stdin, then the test's URIs) and 121 stopped at
`os.kill(pid, 0)`. The 24 other suites that start processes, run on this
build and on round 85's under Wine: no regression; vm_audit105 failed on
both - its `@fix` check wrote the fixture in text mode (`"\r\n"` on
Windows, as CPython writes it) and read it back with the raw `read_file`;
it reads it back in text mode now and passes there (118) - and vm_audit104
fails about one run in two on both with a false `DeadlockError` in its
`task_api` section (asyncio.to_thread, run_coroutine_threadsafe from a
thread, wait() with a sleep pending): pre-existing, open (round 87, part
K).

`examples/vm_audit125.ny` (14 checks) passes on both engines and under
python3 (11 there; the rest are Nython-only) and under Wine; on the round 85 binary the
interpreter reads the file named `total` beside the test as an f-string
field's expression and raises its `1 / 0`.

- **Program text was read as a file when it named one** (both engines,
  every platform). `SourceCode(const std::string&)` takes a file name and
  decided "file or text?" by asking the file system whether the string
  named something. The parser reads an f-string's replacement field (and
  a Nython string's `${...}`) with a lexer of its own over the field's
  text, built through that constructor: `f"{x}"` in a directory holding a
  file named `x` read and ran that file as the field's expression (a
  file there named `total` holding `1 / 0` raised ZeroDivisionError from
  `f"{total}"`), and a field naming a directory - `f"{lib}"`, `f"{src}"`
  run from the repository root - hung the parser: the stream never reached
  its end (`SourceCode::read` waited for eof on a stream that had failed).
  On Windows `f"{...}"` hung wherever it was parsed (Win32 strips a path's
  trailing dots, so `...` names the current directory): that was
  vm_audit122's hang under Wine (the `${...}` in a check's name). The same
  constructor read the text of the prelude and its mirror chunks (both
  engines), the builtin exception classes' source, `lang_eval`'s code and
  the editor's syntax check / def-use / facts (text.cpp carried a band-aid
  appending "\n" when the text named a path). Every text caller now goes
  through `SourceCode::from_text`; the constructor takes a string as a file
  only when it names a regular file (`utils::IsRegularFile`), and
  `line()`/`read()` stop when the stream fails. **Never pass program text
  to `SourceCode(string)`.**
- **os.read / os.write on fds 0-2 move bytes as they are on Windows.**
  CPython puts the standard descriptors in binary mode at startup
  (`config_init_stdio`); Nython left the CRT's text mode on them, so
  `os.read(0, n)` turned "\r\n" into "\n" and `os.write(1, b)` turned "\n"
  into "\r\n" - a Language Server's `Content-Length` headers could not be
  read, nor its replies parsed. `RawStdFd` (src/builtins/os_fd.cpp) switches
  such a descriptor to binary for the call; Nython's own text streams keep
  text mode (print's "\n" is "\r\n" on Windows, as CPython's sys.stdout
  writes it).
- **subprocess reads the child's bytes as written on Windows.** The
  Windows process layer turned every captured "\r\n" and lone "\r" into
  "\n" (round 77, so os_exec's and the IDE's captured lines did not end in
  "\r"), so `subprocess.run(..., capture_output=True).stdout` was not what
  the child wrote. `os_spawn`/`os_run` take `raw_output=True`; subprocess
  (and asyncio's subprocesses, through `_native_opts`) pass it, and text
  mode translates newlines in lib/subprocess.ny as before. Other callers
  keep the translation. A Windows test that expected "\n" from a child's
  print now sees "\r\n", as under CPython.
- **nylsp on Windows**: `StdioTransport` waited for stdin with
  `select()`, which takes sockets only there (CPython's select raises
  WSAENOTSOCK for a pipe); a thread now reads the input and hands chunks
  over through a queue (lib/nylsp/protocol.ny). src/builtins/nylsp.cpp
  names the lexer's `TokenType` (winnt.h declares one of its own).
- **lib/nyaudit.ny path patterns on Windows**: a pattern written with "/"
  (`deny open path=/etc/* mode=w*`) never matched there - the argument was
  made absolute (`Z:\etc\x`), the pattern not - and a pattern `derive()`
  wrote from a log (`Z:\...\*`) was not recognised as a path at all, so the
  derived policy denied the program's own files. Both sides are now
  absolute and case-folded with "\\" separators on Windows
  (`os.path.normcase`); a drive-letter or UNC pattern is a path pattern.
  The installed-policy test used to open `/etc/nyaudit_121_never` for
  writing to show the deny rule working; when the rule did not match (as
  under Wine) the file was made in the host's /etc. It opens a file in a
  directory of the test's own now.
- **vm_audit122 on Windows**: its client wrote `"file://" + path`, not a
  URI on Windows (`file://Z:\tmp\...` - nylsp read `Z:` as a host and
  indexed nothing); it writes `file:///Z%3A/...` now, VS Code's form (the
  same string as before on POSIX).
- **vm_audit121 on Windows**: the child skips the cases Windows has no
  call for, in CPython too (`POSIX_ONLY`: fork/exec/spawn/posix_spawn,
  `os.kill(pid, 0)` - TerminateProcess there, which ended the child -,
  chown, fd-relative calls, symlinks without the privilege, fcntl/resource/
  syslog/pty, a file URL spelled from a POSIX path, libc, sendmsg), and the
  records are compared after what CPython itself reports differently on
  Windows (`plat()`: "\\" in paths, WindowsPath, os.system's command and
  the environment as str, no shutil.chown). sqlite3's case is compared only
  where libsqlite3 loads. `os.system("exit 0")` replaces `"true"` (both
  shells have it).

## 0y3. Round 85 (main session) — exceptions native code swallows, generators as weak references and keys, the harness under Wine, the round 84 suites on Windows (vm_audit120)

Verified with all of round 85 merged (parts E and F and this): sweep 468
runs, 0 not ok; `tools/ide_e2e.py` 463 passed; memory probe, lint, class
check, cbp (78 units) and the API baseline clean.

`examples/vm_audit120.ny` (19 checks) passes on both engines and under
python3; on the round 84 binary the interpreter fails it (the swallowed
exceptions stay alive) and both engines raise at the first weak reference
to a generator.

- **Exceptions that native code catches and carries on from are let go**
  (interpreter). The exception ring (`rememberRaised`, `kExcRing` = 256)
  keeps a raised instance alive for the string that carries it; round 84
  made a completed except clause and a suppressing `with` forget theirs.
  Everything else that catches one - a for loop, list()/sorted()/unpacking
  ending an iterator on StopIteration, iteration by `__getitem__` ending on
  IndexError, hasattr and getattr's default, next()'s default,
  `__getattribute__` falling back to `__getattr__`, a module's
  `__getattr__` in a from-import, `yield from` and the send/throw of a
  delegate, close() catching GeneratorExit - kept it until 256 more
  exceptions had been raised: `excSwallowed(flow, type)` matches and
  forgets (`forgetRaised(flow, false)`: an enclosing clause handling the
  same exception keeps it), at each of those sites in NythonExecutor.hpp
  and src/NyGen.cpp.
- **A runtime error leaving an except clause** (no object yet) holds the
  exception the clause handled for its `__context__` (`pending_ctx_`,
  `tbHandlerExit`) until its object is made - which happened only when the
  next exception was caught. A generator closed (or dropped) while paused
  inside an except clause raised GeneratorExit there, close() swallowed
  it, and the clause's exception stayed alive. Forgetting a flow clears
  `pending_ctx_` when it is that flow.
- **src/NyGen.cpp**: the StopIteration a generator raises (`raise_stop`)
  and an instance thrown into a generator (`exc_string_for`) were stored in
  `exc_instance_map_` by address, outside the ring, and never removed; they
  go through `rememberRaised` (a serial, the ring) as `raise` does.
- **Weak references to generators** (both engines; CPython allows them -
  asyncio's WeakSets of tasks, weakref.finalize on a generator): the
  interpreter's `makeWeakRef` takes a `GenObject` as it takes a set; the
  VM's `WeakCell` has a kind 5 holding a `weak_ptr` to the `GenState`.
  **Generators and the lazy iterators hash by identity** on the
  interpreter (`dictKey`: "unhashable type: 'generator'"); the VM already
  did.
- **`bytes.partition` / `rpartition`** give the separator object they were
  passed when it is found (CPython's `stringlib_partition` keeps `sep_obj`:
  `b"a-b".partition(mv)[1] is mv`); a bytearray's result holds bytearray
  copies, as CPython's.
- **The scripted-input harness under Wine** (`src/builtins/gui_harness.cpp`
  for real SDL3, `thirdparty/sdl3-stub/src/sdl3_stub.cpp`): the event
  script is appended to while it is read; at EOF the reader called
  `clearerr` and tried again later. The Windows C runtime never returns
  lines appended to a file that was *empty* when the stream met its end, so
  tkinter's `_ny_drive` (which starts from an empty script) delivered
  nothing and vm_audit114 failed under Wine. The reader keeps the offset of
  the next unread line and `fseek`s there before reading again after EOF
  (binary mode: offsets are bytes).
- **The round 84 suites on Windows** (`tools/cross_windows.sh build`,
  `build-win/nywin`, both engines): 111 (55), 112, 113 (392), 114 (215),
  115 (82 - the pty programs are POSIX-only), 116 (34), 117 (33), 120.
  vm_audit112 needed two Windows branches, both CPython's behaviour there:
  no `os.readv`/`os.writev` (os.write is checked instead), and `ctypes.c_int`
  is `c_long` where int and long have one size (CPython's ctypes/__init__.py),
  so its PEP 3118 format is `<l` (`<L` for c_uint).
- **Round 85 under Wine** (both engines, 64-bit): vm_audit111 55, 112 133,
  113 392, 114 215, 116 34, 117 33, 118 27 (its posix-only checks are skipped
  on Windows; `ssl.RAND_*` too when no libcrypto is loaded - a bare Wine prefix
  has none), 119 85, 120 19 - all passing. The Windows build needed one fix:
  `_sig_pthread`'s lambda had no return statement in its `_WIN32` branch
  (src/NyConc.cpp; MinGW deduced `void` and the native table rejected it).
- **Round 85 under 32-bit Wine** (`ARCH=i686`, both engines): vm_audit111 55,
  112 133, 113 392, 114 215, 116 34, 117 33, 118 27, 119 85, 120 19 - all
  passing. Two fixes: the libffi-less i686 callback trampolines read 32
  argument words (16 were too few for vm_audit111's callback with a 40-byte
  structure among five others; a cdecl callee only reads its arguments, the
  caller pops them; stdcall stays at 12); vm_audit112's size_t/pointer values
  and the trailing padding of a structure ending in a 4-byte pointer depend
  on the pointer width (`PBITS`). The 32-bit link warns that one guard
  section of `nyrt::class_dir_names()` is padded differently in core.o and
  main.o (16 vs 12 bytes, the same 12-byte vector): harmless.
- **Round 85 on AArch64 under qemu-user** (`make cli BUILD=build-arm64
  CXX=aarch64-linux-gnu-g++`, `qemu-aarch64 -L /usr/aarch64-linux-gnu`, both
  engines): vm_audit112 135, 117 33, 120 19 pass; vm_audit111 54 of 55,
  116 and 119 pass every check that runs in the process - the ones that
  fail start `sys.executable` as a child, which cannot run here (no
  binfmt_misc: exit 127). vm_audit111 with `NY_FFI_NO_LIBFFI=1` (the built-in
  caller) passes its structures-by-value calls and callbacks on AArch64 -
  the round 84 paths written to the AAPCS64 but never run until now.

### Not done
- In a Python-language file, valid Python still meets Nython's
  conveniences: `"a" + 1` concatenates, `for x in 5` is a range, `1 is int`
  is a type test, `{"a": 1}.a` reads the key, `true`/`none`/`undefined`/
  `null`/`elseif` are not names; and in every file `sorted([1, "a"])` /
  `max("a", 1)` compare leniently, the interpreter's `[1, 2]["0"]` is 1,
  `list(5)`/`iter(5)` disagree between the engines (round 86, part J).
- From part E's report: `import encodings.undefined` is a SyntaxError
  (`undefined` is a hard keyword in a dotted import name); `builtins.super`
  is there on the interpreter only.

---

## 0y. Round 85, part E — the names CPython's system modules have and Nython's lacked (vm_audit118)

`examples/vm_audit118.ny` (155 checks on Linux; 154 under python3.11, where
os.unshare is 3.12's) passes on the interpreter, the VM and python3. Every
expected value is CPython's: fixed ones written in the test, the host's own
(constants, the sysconf/pathconf/confstr tables, interfaces, groups, what
the file system answers for xattrs on the test's own file) asked of a
python3 child (`host(...)`, skipped without one).

### The measure: `tools/api_diff.py` (the innovation)
A living conformance measure, after the compatibility dashboards PyPy and
GraalPy keep against CPython. Every module of `lib/` CPython also has (and
its packages' submodules), plus the engines' os, sys, time, gc, math,
builtins and posix, is imported under python3.11 and python3.12 (the union
of their names, each tagged with the versions that have it) and under both
engines (`hasattr`, so PEP 562 `__getattr__` counts); per module: CPython's
names, each engine's, the missing ones by kind (function, class, constant,
module; `-v`) and the coverage; then the totals. Public names are dir()'s
without a leading underscore, less modules a module merely imported (os.sys)
and less other modules' names it re-exports outside its `__all__`
(os.Mapping) - which also hides a few real ones (functools.get_cache_token
was found by hand). `--write-baseline FILE` / `--check FILE`: the check
needs no CPython - it imports the baseline's modules under both engines and
fails when a name the baseline has is gone; `tools/sweep.py` runs it as one
row (`tools/api_baseline.json`, Linux; skipped without python3 or for a
binary of another platform). A full measure takes about a minute.

| | CPython names | missing | coverage |
|---|---|---|---|
| before (e8aea6f), 420 modules | 9676 | 1695 | 82.5% |
| after | 9676 | 574 | 94.1% |

| module | before | after |
|---|---|---|
| os | 170/378 (45.0%) | 378/378 |
| posix | no module | 328/328 |
| socket | 79/432 (18.3%) | 431/432 (CAPI) |
| ssl | 27/128 (21.1%) | 124/128 (MemoryBIO, SSLObject, SSLSession) |
| signal | 45/69 | 69/69 |
| select | 9/32 | 32/32 |
| time | 25/38 | 38/38 |
| sys | 61/77 | 72/77 (3.12's perf trampolines, monitoring, getunicodeinternedsize) |
| gc | 22/25 | 25/25 |
| termios, tty | 217/240, 219/242 | all |
| hashlib, codecs, fcntl | 19/20, 79/81, 56/58 | all |
| locale | 85/92 | 91/92 (3.11's format, removed in 3.12) |

### os and posix
- **`src/builtins/os_posix.cpp`** (new unit, `_ny_os_call` ops that
  os_fd.cpp forwards): statvfs/fstatvfs, sysconf/pathconf/fpathconf/confstr
  and CPython's name tables (`os_posix_sysconf.inc` generated from
  CPython's), getgrouplist, getpriority/setpriority/nice, the uid/gid
  setters, getresuid/getresgid/setres*, setgroups/initgroups, the scheduler
  (sched_get_priority_max/min, getscheduler/setscheduler, getparam/setparam,
  rr_get_interval, setaffinity, yield), wait3/wait4/waitid (EINTR: handlers
  run, the wait resumes), pipe2, lockf, posix_fadvise/posix_fallocate,
  copy_file_range, splice, memfd_create, pidfd_open, eventfd/eventfd_read/
  eventfd_write, getrandom, getxattr/setxattr/listxattr/removexattr (path,
  descriptor, follow_symlinks), posix_spawn/posix_spawnp (file actions,
  setpgroup, setsid, setsigmask, setsigdef, resetids, scheduler), chroot,
  ctermid, fchdir, fdatasync, sync, setpgrp, tcgetpgrp/tcsetpgrp, setns/
  unshare, abort, and the constants (CLD_*, EFD_*, EX_*, F_LOCK..., GRND_*,
  MFD_*, NGROUPS_MAX, O_FSYNC, POSIX_FADV_*, POSIX_SPAWN_*, PRIO_*, P_*,
  RTLD_*, RWF_*, SCHED_*, SPLICE_F_*, ST_*, TMP_MAX, WEXITED/WSTOPPED/WNOWAIT,
  XATTR_*, CLONE_*). Also the clocks, signal masks, socket and epoll ops below.
- **`src/NyPreludePosix.cpp`** (new unit, the mirror chunk "posix", loaded
  by the os chunk; editing it rebuilds one file): the Python side -
  CPython's argument checks and messages, `os.statvfs_result`,
  `os.waitid_result`, `os.sched_param`, **register_at_fork** (os.fork and
  os.forkpty run the callbacks: before last-registered first, a raising one
  reported through sys.unraisablehook), **popen** with CPython's
  `_wrap_close` over subprocess, the spawn* family on fork + exec (os.py's
  `_spawnvef`: 127 when the program cannot run), fwalk (dirfd opened by
  path), getenvb, P_WAIT/P_NOWAIT/P_NOWAITO, device_encoding, the
  supports_* sets (CPython's lists less what Nython's functions do not take;
  supports_dir_fd is empty), and `__module__` "posix" for every posix name,
  "os" for os.py's, "posixpath" for os.path's.
- **`lib/posix.ny`** (and `lib/nt.ny` for Windows): os's own objects for
  every name CPython's posix has; `posix.environ` a bytes dict. Natives show
  posix as their module (NyRuntime.hpp builtin_public), so
  `os.getcwd.__module__ == "posix"` and pickles name posix.
- `os.pipe()`, `os.pipe2()` ... return real tuples (os_fd.cpp's `tuple_of`
  set its "__tuple__" mark through a cast that never reached the container:
  every native "tuple" of os was a list).
- **subprocess on posix_spawn**: the process layer's `start_process`
  (os_proc.cpp) uses posix_spawnp where it means the same as its fork +
  execvp (CPython's _posixsubprocess vfork path): not for an env= that sets
  PATH for a bare name, nor a cwd= without glibc 2.29's addchdir_np;
  `NY_SPAWN_FORK=1` forces fork. `subprocess.run(["true"])`, 200 runs, min
  of 3: 2.3 -> 1.7 ms; with 300,000 objects alive in the parent 24.9 -> 1.6
  ms (fork copies the page tables; CPython 1.6 / 2.3 ms).

### time, signal, socket, select, selectors
- time: clock_gettime(_ns), clock_getres, clock_settime(_ns),
  pthread_getcpuclockid, the CLOCK_* of <time.h>; thread_time() is
  CLOCK_THREAD_CPUTIME_ID on Linux (it was the process's).
- signal: **set_wakeup_fd** (the C handler writes each signal's number to
  the descriptor - asyncio's self-pipe; CPython's checks), siginterrupt
  (SA_RESTART per signal, kept for later installs), pthread_kill and
  time.pthread_getcpuclockid (NyConc's thread records now keep their
  pthread), pthread_sigmask, sigpending, sigwait, sigwaitinfo/sigtimedwait
  (struct_siginfo), pidfd_send_signal, ItimerError (`signal.itimer_error`,
  as CPython names it), valid_signals as sigfillset's (glibc keeps 32 and
  33), SIG_BLOCK..., SIGRTMIN/SIGRTMAX, SIGCLD/SIGPOLL/SIGPWR/SIGIOT/
  SIGSTKFLT, and Signals/Handlers/Sigmasks made on first use (module
  `__getattr__`; the module's SIGINT stay ints, equal to the members).
- socket: sendmsg/recvmsg with ancillary data, **send_fds/recv_fds**,
  CMSG_LEN/CMSG_SPACE, close/dup/fromfd, gethostbyname_ex, getprotobyname,
  has_dualstack_ipv6, if_nameindex/if_nametoindex/if_indextoname,
  sethostname, error/timeout/gaierror/herror/SocketType, every integer
  constant CPython has where this platform's headers define it
  (`os_posix_socket.inc`, generated from CPython's; the Linux headers' enum
  members and Bluetooth's kernel values written out), and AddressFamily/
  SocketKind/MsgFlag/AddressInfo on first use.
- select.epoll (Linux: register/modify/unregister/poll/fromfd/close, a
  context manager; the wait releases the GIL and resumes after a signal's
  handler with the time left), the EPOLL*/POLL* constants, PIPE_BUF;
  selectors.BaseSelector and EpollSelector (DefaultSelector stays the socket
  layer's, which parks an async task instead of blocking its loop).

### sys, gc, the rest
- **sys.get/set_int_max_str_digits, enforced** (CPython 3.11's gh-95778):
  int(str) in a base that is not a power of two (NyFormat.hpp
  `parse_int_str`) and str/repr/print/f-strings/format/%d of an int (the
  interpreter's `toText`, the VM's `vm_str`/`vm_repr`, NyFormat's
  `format_int`/`format_value`) raise ValueError past 4300 digits with
  CPython's messages; `-X int_max_str_digits=N`, `PYTHONINTMAXSTRDIGITS`
  (an invalid one exits 1 as CPython's "Fatal Python error"),
  sys.flags.int_max_str_digits (-1 unset), sys.int_info's 4300. The engines'
  own uses of the text (dict keys, the VM's big ints kept as decimal) are
  not limited; a literal in source is not checked (CPython: SyntaxError).
- **sys.unraisablehook / sys.__unraisablehook__**: the engines' "Exception
  ignored in" reports - a `__del__`, a weakref callback, a generator closed
  by finalization - go to a program's hook (`_ny_unraisable` in the prelude;
  `UnraisableHookArgs`, with a traceback); with the default hook the
  engines print as before. lib/weakref.ny's callbacks and os.register_at_fork
  report through it too.
- sys.getallocatedblocks, getdlopenflags/setdlopenflags,
  get/set_coroutine_origin_tracking_depth (the depth is kept; coroutines
  have no cr_origin yet), abiflags, pycache_prefix, thread_info.
- **gc.get_objects(generation)** over the collectors: the interpreter's
  tracked objects (`nygc::each_tracked`), the VM's values in its tracked
  containers of that generation (`vmgc::for_each_value_in`) and its globals;
  lib/gc.ny adds what the running frames and modules hold directly.
  get_referents follows CPython's traversal for the builtin containers (a
  list's items last first, a dict's values - and keys when one is not a
  str -), get_referrers scans get_objects and the module namespaces;
  is_tracked as CPython 3.11 untracks.
- ssl: RAND_bytes/RAND_status/RAND_add/RAND_pseudo_bytes over libcrypto
  (tls.cpp), DER/PEM conversion, cert_time_to_seconds, get_protocol_name,
  get_server_certificate, 3.11's wrap_socket, OPENSSL_VERSION_NUMBER/INFO,
  the OP_/ALERT_/SSL_ERROR_/VERIFY_/PROTOCOL_ constants (OpenSSL 3's),
  HAS_*, get_default_verify_paths as DefaultVerifyPaths, the enums.
- hashlib.scrypt (native RFC 7914, its vectors checked; OpenSSL's limits
  and messages), functools.get_cache_token (abc's, on first use), locale's
  gettext/dgettext/dcgettext/textdomain/bindtextdomain/
  bind_textdomain_codeset (glibc's libintl), codecs.utf_32_ex_decode and
  readbuffer_encode, _sqlite3.enable_shared_cache (sqlite3's 3.11 wrapper
  warns), termios' remaining constants, fcntl.FICLONE/FICLONERANGE.
- threading's Lock/RLock/Condition/Event have `_at_fork_reinit`
  (concurrent.futures registers it now that os.register_at_fork exists).
- collections.namedtuple's classes are named as asked (`type(p).__name__`
  was `_NT`), with `__module__` the caller's and CPython's docstring.

### Engine changes (all marked "round 85")
- `include/NyPrelude.hpp`: `prelude_posix_source()` and the "posix" chunk
  in `builtin_mirror_chunk`; the os chunk's member list ends with
  `_ny_load_chunk("posix")` / `_ny_posix_extend(m)`; sys's new members
  (`_ny_sys_extend` and the functions before `_ny_stdlib_names`:
  `_ny_get/set_int_max_str_digits`, `_NyUnraisableHookArgs`,
  `_ny_unraisablehook`, `_ny_unraisable`, dlopen flags, coroutine depth,
  `_NySysThreadInfo`); sys.int_info's default_max_str_digits 4300.
- `include/NythonExecutor.hpp`: ensureMirror loads "posix" without the base
  mirror; `_ny_gc_objects` registered; toText of a big int checks the digit
  limit; `reportUnraisable(flow, obj)` (the exception caught by tbCaught so
  it has its traceback) used by runWeakCallback and runFinalizer.
- `include/VirtualMachine.hpp`: load_mirror likewise; int() parses under
  nycall (the digit limit's ValueError); `int_text_check` in vm_str/vm_repr;
  `report_unraisable(ev, obj)` in the weak-callback queue, gc_run_finalizer
  and gen_finalize; native `_ny_gc_objects`.
- `include/NyBigInt.hpp`: `nypy::int_max_str_digits()`,
  `int_digits_check_in/out`. `include/NyFormat.hpp`: the checks in
  parse_int_str, format_int, format_value. `include/NyRuntime.hpp`: CliFlags
  int_max_str_digits -1, `nyrt::int_max_str_digits()`, builtin_public's os
  natives in module posix (nt). `include/NyGC.hpp`/`src/NyGC.cpp`:
  `each_tracked`. `include/VMGC.hpp`/`src/VMGC.cpp`: `for_each_value_in`.
  `include/builtins/os.hpp`: `os_call_posix`.
- `src/NyConc.cpp`: ThreadRec keeps its pthread; the signal trampoline
  writes to the wakeup fd; per-signal SA_RESTART; `_sig_set_wakeup_fd`,
  `_sig_siginterrupt`, `_sig_pthread`. `src/NyGen.cpp`: report_ignored goes
  through reportUnraisable. `src/main.cpp`: -X int_max_str_digits,
  PYTHONINTMAXSTRDIGITS. `src/builtins/core.cpp`: `_ny_sys_info`'s
  int_max_str_digits/allocated_blocks/libc_version, `_ny_gc_objects`.
  `src/builtins/pycore.cpp`: int() under nyCall. `src/builtins/os_fd.cpp`:
  forwards to os_call_posix; real tuples. `src/builtins/os_proc.cpp`: the
  posix_spawn path. `tls.cpp`: `_tls_rand`; `hashing.cpp`: `_hash_scrypt`;
  `nysqlite.cpp`: `_sql_shared_cache`; `nysysmods.cpp`: termios/fcntl
  constants. `nython.cbp`: the two new units.

### Not done
- os: no dir_fd anywhere (supports_dir_fd is empty), so fwalk opens each
  directory by path; posix_spawn's `setsid` needs glibc 2.26; spawn* fork.
  Windows: nt's own extras (startfile, _getfinalpathname ...) are absent and
  nothing here was run under Wine (os_posix.cpp is POSIX-only and returns
  "unknown operation" there; the chunk binds only nt's names).
- sys: 3.12's perf trampolines, sys.monitoring, getunicodeinternedsize;
  coroutines record no cr_origin; a big-int literal in source is not
  limited; 3.12's checks (validating a string before the limit,
  sys.flags.int_max_str_digits 4300) are not followed - 3.11's are.
- The interpreter's generator finalized when its object dies gives the hook
  `object=None` (the object is being destroyed); CPython gives the
  generator.
- gc: is_finalized is always False; get_referents of other objects than the
  builtin containers, instances, functions, modules and classes gives
  their type only.
- socket: sendmsg's destination address, CAPI; family/type of a socket are
  plain ints (not AddressFamily members).
- ssl: MemoryBIO/SSLObject/SSLSession; OP_* are OpenSSL 3's values whatever
  library was loaded.
- `_sqlite3.version` and `locale.format` (3.11's, removed in 3.12) are left
  out: Nython's library is 3.12's.
- NyBuiltinFns.hpp: not regenerated - its os, posix, signal, socket, select,
  time and gc rows already list the new functions (a regeneration would also
  add round 84's curses and CJK rows).

---

## 0y2. Round 85, part F — Python's binding rule for Python-language source (vm_audit119)

**The rule.** Nython's ruling (round 75) stays for `.ny` code: inside a
function a plain assignment rebinds the nearest existing binding.
Python-language source binds as CPython does: a name a function binds
anywhere (assignment, augmented assignment, for/with/except-as targets,
`del`, import, def/class, a walrus - in a comprehension it binds in the
function around it -, match captures) is a local of the whole function
unless declared global/nonlocal, and reading it unbound is
UnboundLocalError ("cannot access local variable 'x' where it is not
associated with a value"). Python-language source is: a `.py` file; a file
whose leading comment block says `# nython: python`; code compile() /
exec() / eval() compile when called from such a file (compile() records
the rule in the code object, `_NyCode._ny_pyrule`; code *named* after a
source file - `compile(src, "prog.ny", "exec")`, as runpy/pdb/cProfile/
importlib run a program - is that file's language: `nython::scope::
code_rule`); and ast trees (lib/ast.ny's `_ny_compile` is Python-language).
A Nython function opts in with `# nython: python` on its def line (its
nested functions too) - the per-function hybrid.

**One implementation, in the static pass** (`src/NyScope.cpp`, run by
`Parser::parse`, which now passes the file name and source): for a
function under Python's rule, the set of names it binds minus its
global/nonlocal names (`py_locals`) is its locals; every read, assignment
target and del target of one is marked `VariableNode::py_bind = 1`
(`include/ASTNodes.hpp`). The engines only follow the marks:
- interpreter: `evalVariable` -> `readPyLocal` (the function's own scope,
  the node's NameCache slot at depth 0; UnboundLocalError), `assignName`
  (defineByName in the scope), `evalDelete` (own scope only);
- VM: `LOAD_LOCAL` / `DELETE_LOCAL` (new generic ops after FIN_EXC_OF; the
  frame's own env then locals; not quickened), stores as `DEFINE_NAME`;
  lib/dis.ny and lib/opcode.ny know the two ops (`haslocal`).
`self`/`this` are never marked (STORE_SELF/LOAD_SELF stay).

**exec in a Python-language function without namespaces** (CPython: it
cannot create or change the function's locals): the snippet is parsed
with `RuleScope(python, top_locals)` and its top-level writes are marked
`py_bind = 2`; the interpreter runs it in a child scope of the function's
(reads see the locals, writes are dropped with it), the VM skips the
write-back of `run_code_with_locals`. `global x` inside it reaches the
module. (As 3.13's PEP 667: `locals()` afterwards does not show them.)

**Census** (`python3 tools/ny_scopecheck.py`, over `nython --scope-report
files...`, a hidden flag whose lines are NyScope's `differences()`): every
function assignment / augmentation / del of a name an enclosing function
or the module binds with no declaration (and every read before a local
binding), classified (a) rebinding meant (it uses the outer value: needs
global/nonlocal - `--fix` inserts them), (b) clobber (write-first over a
def/class/import: a bug under Nython's rule - `--fix-locals` writes `var`),
(c) unclear. lib/**/*.ny + the IDE's .ny files: 527 files, **68 cases: (a)
0, (b) 4, (c) 64**, every one in a CPython-ported module where CPython's
code means a local (imaplib's `dat`, smtplib's `msg`, poplib, aifc: names
the module's `__main__` test code binds; difflib's `_mdiff` generators,
ElementTree, pydoc, dataclasses: inner functions' locals named as the
enclosing function's). One was a live bug: `email/_parseaddr.ny`'s
`getdelimited` had `quote = False`, which replaced the module's quote(), so
`email.utils.parseaddr('"a b"@example.com')` raised "'bool' object is not
callable"; also timeit's main() (`repeat`), mailcap's findmatch (`test`),
mimetypes on Windows (`add_type`). Nython's own libraries (gui, ide_*,
nytorch, aiagent, nyxai, _tkinter, ...) have none.

**Marked**: the 435 CPython-ported `# nython: module` files got a second
line `# nython: python` (marking them fixes all 68). Left Nython-language:
`lib/_tkinter/` (Nython's Tk), `lib/nyxai/`, `_nyvt`, `ide_debugserver`,
`websocket` (Nython's own), the generated `_nydocs` and `html/entities`
(their generators write the header), and every non-module library. What
the marker controls now: Python's binding rule; `${...}` stays text (as
`module` already did); True/None are spelled `True`/`None` when such a file
is the main program (`nython -m <module>`).

**Warnings**: `-W nython-scope[:filter]` / `NY_SCOPE_WARN=1|all|<substr>`
print each such case of a Nython-language file as it is parsed ("1": files
outside the library directories), e.g. `f.ny:4:5: warning: function 'add'
augments 'total', rebinding the module's 'total' (line 1) without a
declaration - Python's rule makes it a local of the function: declare
'global total' to keep rebinding it, or 'var total' for a local
[nython-scope]`.

**Cost**: `-c pass` 184.93M -> 185.07M instructions (interpreter), 209.17M
-> 209.30M (VM) - the pass now walks raw pointers instead of copying
shared_ptrs, which paid for the new bookkeeping; benchmarks within
+0.05% instructions.

**Not done**: CPython's "cannot access free variable 'x' where it is not
associated with a value in enclosing scope" (a closure reading an
enclosing local not yet bound reads a same-named module variable or raises
NameError); a class body in a function reading a name the body binds
later finds the enclosing function's variable (CPython reads the module's).

---

## 0x. Round 84, part A — memoryview and the buffer protocol, bytes % args (vm_audit112)

`examples/vm_audit112.ny` (135 checks) passes on both engines and under
python3.12 (132 under python3.11: the PEP 688 checks need 3.12; where
3.12 changed an answer - ctypes structure formats with their padding, `len()`
of a 0-dim view, the half-float format - both are carried, Nython giving
3.12's). Every expected value is CPython's. Sweep 451 runs, 0 not ok in a copy of the tree outside the main checkout (in this worktree vm_audit110 on the VM fails on a main-checkout file, see "Found, not fixed"); tools/ide_e2e.py 463 passed, 0 failed; ide_lint, the class check and the cbp check clean.

### The model (CPython's memoryobject.c)
- **A buffer is native memory**: the address of its first item, a format
  and item size, a shape and strides in bytes. A view's state is plain
  fields (`_ny_a` address, `_ny_f` format, `_ny_i` itemsize, `_ny_sh`/`_ny_st`
  shape and strides, `_ny_ro`, `_ny_fl` contiguity, `_ny_x` exports, `_ny_mb`
  its managed buffer); items are read and written at their addresses by
  `src/builtins/nybuffer.cpp`'s `_mv_*` natives (served by the concurrency
  runtime's dispatcher, `nyconc::register_extension`, so both engines run
  them natively, no bridge): `_mv_fmt`, `_mv_get`/`_mv_set` (every native
  format, `@` optional, and the struct byte orders for comparisons; half
  floats by CPython's `PyFloat_Pack2`/`Unpack2`), `_mv_read`/`_mv_write`/
  `_mv_move`, `_mv_tolist`, `_mv_tobytes` (C or Fortran order), `_mv_store`
  (C-ordered bytes into a strided layout), `_mv_cmp` (== item by item,
  format-aware).
- **Loaded on first need.** The class `memoryview` is in the startup prelude
  (NyPrelude.hpp: its `__new__`, `_ny_is_exporter`, and stubs of the helpers
  below); its members, the managed buffers and the helpers are the mirror
  chunk `"buffer"` - `src/NyPreludeBuffer.cpp`, a unit of its own
  (`builtin_mirror_chunk("buffer")` returns `prelude_buffer_source()`, so
  editing it rebuilds one file, not every file that includes NyPrelude.hpp).
  The first view, or the first bytes-like argument that is not
  bytes/bytearray, loads it through the new native `_ny_load_chunk(name)`
  (interpreter `ensureMirror`, VM `load_mirror`); the chunk defines its
  members on `_NyMemoryview` and puts them on `memoryview` (`_ny_mv_attach`,
  `__qualname__` `memoryview.x`). Parsed at every start it cost 6 ms of CPU
  (18%: `-c pass` 33.5 -> 39.6 ms on the interpreter, 38.8 -> 45.5 on the
  VM); now a start costs what it did before the round (side by side with the base binary on the same loaded machine: 39.0 vs 39.0 ms on the interpreter, 47.7 vs 47.8 on the VM), and the first view pays about 5 ms once. A stub calls the real function by its name, which the
  chunk rebinds in the prelude's scope (interpreter) / the VM's globals.
  **A new helper a library calls must be stubbed the same way** if a program
  can reach it before a view exists.
- **A `_NyMBuf` is CPython's managed buffer**: one export of an object,
  shared by every view made from it (slices, casts, `memoryview(m)`,
  `toreadonly()`); `views` counts the registered views. The export is given
  back when the last view is released (`release()`, a `with` block) or when
  the managed buffer is collected (`__del__`): CPython's rule that a slice
  keeps the export after its parent is released, and that a dropped view
  gives it back.
- **Exporters**: bytes and bytearray through the engines' new natives
  `_ny_buf_export(obj)` -> `[address, length, readonly, owner]`,
  `_ny_buf_unexport`, `_ny_buf_exports`, `_ny_buf_addr` (interpreter
  `src/builtins/core.cpp`, VM `globals_[...]`); everything else through
  `__buffer__(flags)` (PEP 688): array.array, mmap, ctypes data,
  multiprocessing.shared_memory, pickle.PickleBuffer, memoryview itself (its
  exports counted: `release()` refused while one lives, "memoryview has 1
  exported buffer") and any class of a program; `__release_buffer__(view)`
  is called when that export is given back. Nython's own exporters build
  their views with `_ny_memview_raw(obj, address, nbytes, readonly, fmt,
  itemsize, shape, strides, release, owner)`.
- **A bytearray's storage does not move while exported**: the export count
  lives in `nyheap::Bytes::exports` (interpreter) and in the shared
  element's `i` of a VM bytearray (`VMVal::ba_exports()`); every operation
  that would change the size raises CPython's `BufferError: Existing exports
  of data: object cannot be re-sized` (append, extend, insert, pop, remove,
  clear, `+=`, `*=`, `del`, slice assignment of another length - after
  their own argument errors, as CPython's), and a change of the same size
  is written in place, never by swapping the string's buffer
  (`nypy::ba_assign`, `ba_resize_check` in NyBytes.hpp; the builtin bridge's
  copy-back too). VM bytes are values: a view of them holds a bytearray copy
  made once at export (the interpreter's views of bytes are zero-copy).

### memoryview
Everything CPython 3.12 has: `tobytes(order)`, `tolist` (N-dim nested),
`hex(sep, bytes_per_sep)`, `toreadonly`, `release` and the context manager,
`cast(format, shape)` with CPython's rules and messages (C-contiguous only,
one side a byte format, the product of the shape, 1D <-> ND, zeros in the
shape), `obj`, `nbytes`, `readonly`, `itemsize`, `format`, `ndim`, `shape`,
`strides`, `suboffsets`, `c_contiguous`/`f_contiguous`/`contiguous`;
indexing in every native format (`bBhHiIlLqQnNfdeP?c`), `m[i, j, k]`,
first-dimension slicing with steps (a view of a view keeps the base),
slice assignment of the same structure (overlap-safe), item assignment with
CPython's range checks and messages, `==` by value (format-aware, struct's
unpacking for other formats, NaN unequal to itself), `hash` (read-only byte
formats only, cached), `len`, iteration, `bytes(m)`, `bytearray(m)`,
`list(m)`, `<memory at 0x...>` / `<released memory at 0x...>`, pickling
refused, read-only attributes, `__buffer__`/`__release_buffer__`,
CPython's argument messages; `collections.abc.Sequence` and `Buffer`
include it.

### Everything that takes a bytes-like object takes a buffer
- **Engines** (both): a bytes-like argument that is an exporter becomes its
  bytes through the prelude's `_ny_buffer_bytes` (interpreter `bufferBytes`
  in `toBArg`, VM `buffer_bytes` in `to_barg`): `bytes()`/`bytearray()`,
  every bytes method's arguments (`join`'s items, `find`, `startswith`,
  `replace`, `split` ...), `in`, `bytes + buffer`, `bytearray += buffer`,
  slice assignment, `int.from_bytes`.
- **Libraries**: struct (`pack_into`/`unpack_from`/`iter_unpack` into and
  from any buffer, written in place), zlib, bz2, lzma, gzip, binascii,
  base64, hashlib, hmac, io (`BytesIO.getbuffer()` a live view - write,
  writelines, truncate and close raise BufferError while it is exported;
  `readinto` into any writable buffer, filled in place; `write` of any
  buffer), files (`write` of any buffer; `readinto`/`readinto1` read
  straight into the buffer's memory - the new native `file_readinto(h,
  address, n)`, no bytes object in between), sockets (`send`/`sendall`/
  `sendto` of buffers, `recv_into` straight into the buffer's memory -
  `_net_recv_into`, no bytes object in between -, `recvfrom_into`, new), os
  (`write` of buffers; new `readv`, `writev`, `pread`, `pwrite`, `preadv`,
  `pwritev` - POSIX only, as CPython's; natives `pread`/`pwrite` in
  `src/builtins/os_fd.cpp`), mmap (slices, `write`, `find` take buffers;
  `__buffer__` - the mapped memory itself, read-only for ACCESS_READ; close
  and resize raise BufferError while exported, CPython's messages;
  `_mmap_addr`), array.array (now native C values in a bytearray, read and
  written in place - `buffer_info()` is the real address; `__buffer__` with
  the typecode as format, "w" for "u" as 3.12; "cannot resize an array that
  is exporting buffers"), ctypes (`__buffer__` with CPython 3.12's PEP 3118
  formats: `<i`, `<q` for an 8-byte long, `&<i`, `(3)<i` for array fields,
  `T{<i:x:4x<d:y:}` with the padding, `B` for unions; `from_buffer` of any
  writable buffer - bytearray, mmap, array, memoryview - sharing the memory
  and keeping the export in `_objects`; `from_buffer_copy` of any
  bytes-like object), multiprocessing.shared_memory (`buf` a memoryview of
  the block; `shm_addr`; close refused while it is exported), pickle.
  PickleBuffer (a view; `raw()` a flat memoryview; READONLY_BUFFER gives a
  read-only view, as CPython's), sqlite3 (`Binary = memoryview`; Blob
  writes take buffers), wave/aifc/sunau (`memoryview(data).cast('B')`,
  CPython's code), `_compression`, pathlib's `write_bytes`, subprocess's
  input. The round-83 workarounds are gone.

### bytes % args (PEP 461)
`nypy::bytes_percent_format` (NyBytes.hpp, the number formatting shared with
str's `%` in NyFormat.hpp), both engines (`bytesPercent` / `bytes_percent`):
`%b`/`%s` (bytes, bytearray, `__bytes__`, any buffer), `%a`/`%r` (ascii()),
`%c` (an int in range(256) or one byte), the numeric codes with every flag,
width and precision, `*` widths, `%(key)s` with bytes keys from a mapping
(a dict, or anything with `__getitem__`), bytearray % args giving a
bytearray, and CPython's errors ("%b requires a bytes-like object, or an
object that implements __bytes__, not 'str'", "%x format: an integer is
required, not float", "float argument required, not str", "%c arg not in
range(256)", "not all arguments converted during bytes formatting" ...).
An object's conversions go through the prelude's `_ny_pct_arg` (`%d`:
`__int__` then `__index__`; `%x`/`%o`/`%c`: `__index__`; `%f`: `__float__`
then `__index__`), so they do not depend on the engines' `int()`/`float()`.

### Engine changes (all marked "round 84")
- NyBytes.hpp: `ba_resize_check`, `ba_assign`, `ba_resizing_method`,
  `bytes_method(..., exports)` (a resizing method on an exported bytearray
  runs on a copy, then `ba_assign`), `bytes_pad`, `bytes_percent_format`.
  NyHeap.hpp: `Bytes::exports`. NyExcTypes.hpp: `BufferError` (both tables).
  NyRuntime.hpp: `memoryview` is a prelude builtin class.
- Interpreter (NythonExecutor.hpp): `bufferBytes`; `toBArg` takes any
  exporter; `bytesBinary` `+` with a buffer and `%` (`bytesPercent`,
  `pctBytesArg`); `+=`/`*=`, slice assignment, `del` of items and slices
  checked against exports and written in place; `ensureMirror("buffer")`
  needs no mirror base; natives registered: `_ny_buf_*`, `_ny_load_chunk`,
  `file_readinto` (core.cpp / io.cpp).
- VM (VirtualMachine.hpp): `VMVal::ba_exports`; `buffer_bytes`, `to_barg`,
  `bytes_binop` `+`/`%` (`bytes_percent`, `pct_bytes_arg`),
  `binop_inplace`, `DELETE_SUBSCR`, slice stores and `call_bytes_method`
  checked against exports; `load_mirror("buffer")` needs no base; natives
  `_ny_buf_export/_unexport/_exports/_addr`, `_ny_load_chunk`.
- main.cpp: the builtin bridge's copy-back of a bytearray writes an exported
  one in place (same size) or raises BufferError.
- Natives: `src/builtins/nybuffer.cpp` (new), `_mmap_addr` (nymmap.cpp),
  `pread`/`pwrite`/`shm_addr` (os_fd.cpp), `_net_recv_into` (net.cpp),
  `file_readinto` (io.cpp).

### Not done
- Reading memoryview's members from the class before any view exists
  (`memoryview.cast`, `dir(memoryview)`, `hasattr(memoryview, "tobytes")`)
  finds only the stub: the chunk is loaded by the first view or the first
  non-bytes buffer argument (`_ny_load_chunk("buffer")` loads it by hand).
- `memoryview(o).obj` for a class with `__buffer__` is `o` itself (CPython
  3.12: an internal `_buffer_wrapper` around it); bytes and bytearray have
  no `__buffer__` attribute of their own (CPython 3.12 has them; the engines
  export them natively, and `collections.abc.Buffer` counts them).
- `inspect.BufferFlags` (3.12) is not there: it is an `enum.IntFlag`, and
  importing enum would cost inspect's every import 25-45 ms; a module
  `__getattr__` (PEP 562) would make it on first read, but neither engine
  calls one (below).
- `class M(memoryview)` is accepted (CPython: "type 'memoryview' is not an
  acceptable base type").
- `suboffsets` (PIL-style indirect buffers) are always `()`: no exporter
  makes them. Formats beyond one native item (`"2i"`, struct strings other
  than ctypes' own `T{...}`) can be made by a `__buffer__` but not indexed
  ("memoryview: format ... not supported", as CPython's).
- VM views of a bytes value read a copy made at export (VM bytes are
  values); a bytearray's are zero-copy on both engines.
- The ctypes formats are 3.12's (`<q` for long, padding in `T{}`); 3.11's
  differ and are not given.

### Found, not fixed (engine gaps outside this round's scope)
- `int(x)` ignores `__index__` (CPython 3.8+ falls back to it after
  `__int__`); `float(2**1100)` gives `inf` (CPython: OverflowError "int too
  large to convert to float") - `_ny_pct_arg` and `_ny_mv_pack` do their
  own conversions to stay correct.
- `"s" + memoryview(b"x")` concatenates the repr (str's `+` is lenient
  with a non-str right operand; CPython: TypeError).
- `b"abc".partition(memoryview(b"b"))` returns the separator as bytes
  (CPython returns the separator object as given).
- A module's `__getattr__` (PEP 562) is never called, on either engine:
  `mod.missing` raises AttributeError at once (lib/sqlite3's deprecated
  names rely on one).
- The VM's module search climbs four directories above the script's
  (`VirtualMachine::module_dirs`, the interpreter climbs from the importing
  file's): run from a worktree under `/home/user/Nython-Good/.claude/
  worktrees/`, `examples/x.ny` reaches `/home/user/Nython-Good/lib/`, so a
  module this tree lacks is taken from the main checkout - vm_audit110 on
  the VM imported its `lib/ast.ny` (dbm.dumb's optional `import ast`) and
  failed on `_ny_ast`. The same tree copied elsewhere passes.

## 0x2. Round 84, part B — the Unicode database, Unicode-correct str, the CJK codecs (vm_audit113)

`examples/vm_audit113.ny` (389 checks: 380 shared, 9 Nython-only; 392 on
Windows, where 3 check mbcs/oem/code_page_*) passes on both engines - on
Linux and as the MinGW build under Wine (`tools/cross_windows.sh build`,
`build-win/nywin`) - and the 380 under python3.11
(`tools/vm_audit113_spec.py` generates it: every expected value is CPython 3.11's, Unicode 14.0.0 - so
python3.12/3.13, on Unicode 15.0/15.1, fail its database checks, as they
should). `tools/check_cjk_codecs.py` (below): 10,232 digests, 0 differ on
either engine (`--quick`'s 10,160 under Wine too). Sweep 451 runs, 1 not
ok (vm_audit110 on the VM, as with the base binary: see "Not done");
`tools/ide_e2e.py` 463 passed, 0 failed; lint, class check and cbp check
clean.

### The Unicode database (Unicode 14.0.0, CPython 3.11's)
- `include/NyUniData.hpp` / `src/NyUniData.cpp` over tables generated by
  **`tools/gen_unicodedata.py`** from python3's own database (read back
  through unicodedata and the str methods, then checked once against the
  UCD files: the quick-check bits against DerivedNormalizationProps.txt,
  Cased/Case_Ignorable/XID_*/Lowercase/Uppercase against
  DerivedCoreProperties.txt, the composition pairs against
  CompositionExclusions.txt - all identical). One record per code point
  holds what CPython's two records hold (category, combining class, bidi
  class, east asian width, mirrored, quick-check bits, the str flags with
  CPython's masks, the case mappings as deltas or extended-case indexes).
- **Layout (innovation)**: one three-level trie over 968 merged records
  where CPython has two two-level indexes over two record tables
  (`gen_unicodedata.py --stats`): 76 KB with the decomposition index,
  against 222 KB for CPython's layout of the same data. A lookup is three
  dependent loads instead of two; str's predicates answer ASCII inline
  before it. All of the database (with decompositions, compositions,
  numeric values, the 3.2.0 delta, aliases and named sequences) is ~200 KB
  of the binary; the binary grew by 812 KB in all this round (16.49 ->
  17.30 MB; ~165 KB of it the CJK codecs, most of the rest str's methods
  inlined in both engines).
- `lib/unicodedata.ny` complete: category, bidirectional, combining,
  east_asian_width, mirrored, decomposition, decimal/digit/numeric with
  CPython's defaults and errors, name, lookup (aliases from
  NameAliases.txt, named sequences from NamedSequences.txt - both committed
  under tools/unicode/ - CPython's case rules: HANGUL SYLLABLE and CJK
  UNIFIED IDEOGRAPH names as spelled, "name too long"), normalize /
  is_normalized (CPython's nfd_nfkd / nfc_nfkc and its quick check, ported),
  `UCD` and `ucd_3_2_0` (CPython's change records and its five corrected
  decompositions, derived from python3's ucd_3_2_0 - including CPython's
  quirk that ucd_3_2_0.numeric reads the decimal change). `\N{...}` takes
  the aliases too (src/NyUniNames.cpp). NormalizationTest-14.0.0.txt's
  parts 0 and 3, a quarter of part 2 and a twelfth of part 1 are in the
  test (the generator fetches the file, or `NORMTEST=path`).
- Nython's addition: `unicodedata.stream_safe(s)` (UAX #15 §13, the
  Stream-Safe Text Format: a CGJ before the 31st non-starter in a row).

### str follows the database (both engines: include/NyStr.hpp)
- Full case mapping (SpecialCasing: "ß".upper() == "SS", "İ".lower() is
  two code points), the final-sigma rule, casefold (CaseFolding's full
  folding), title/capitalize (title case for the first letter, as 3.8+)/
  swapcase/istitle with titlecase letters, every is* predicate as CPython
  defines it (isdecimal/isdigit/isnumeric distinct now - all three were
  isdigit), isidentifier per PEP 3131, Unicode whitespace for
  split()/strip(), splitlines on every line boundary. ASCII strings take
  inline paths (`tools/bench/bm_str_case.ny`, half ASCII and half Latin/
  Greek/Cyrillic words: the ASCII half 6-8% faster than before on both
  engines, the other half within 5% of the old approximations while
  correct; run.py's whole-benchmark figure on a loaded machine: VM 0.93x,
  interpreter 1.00x).
- `int()`/`float()`/`complex()` of a str read Unicode decimal digits and
  spaces (`nypy::uni_to_ascii`, CPython's
  _PyUnicode_TransformDecimalAndSpaceToASCII); bytes are read as they are.
  Decimal() follows (lib/decimal.ny's \d is Unicode).
- The lexer (both engines): identifiers with non-ASCII characters are
  checked as XID_Start XID_Continue* and NFKC-normalized (`ﬁ = 1` binds
  `fi`); in a Python-mode file anything else is CPython's SyntaxError
  ("invalid character '€' (U+20AC)"); Nython source keeps other identifiers
  (emoji) as written.
- re: its tables (include/NyReTables.hpp, round 77) were already CPython's
  sre; vm_audit113 checks \w \d \s and IGNORECASE (ß, ſ, K, ǅ, Σ) against it.
- **Fuzzy matching (innovation)**: `fuzzy_score`/`fuzzy_positions`/
  `fuzzy_rank` (include/NyFuzzy.hpp, the IDE's Quick Open) compare search
  keys - NFKD without combining marks, case-folded (the folding search of
  UTS #10 §8, ICU's primary strength) - so "resume" finds "résumé",
  "strasse" "Straße", "file" "ﬁle", "abc" "ＡＢＣ"; positions are the
  original characters; ASCII scores unchanged.

### Codecs
- **The CJK codecs**: `src/builtins/nycjk.cpp` is CPython's
  Modules/cjkcodecs ported (the codec functions with CPython's own macros,
  multibytecodec.c's loops and error handling), over mapping tables
  generated from python3's codecs by **`tools/gen_cjk_codecs.py`**: each
  internal table (gb2312, gbkext, gbcommon, gb18030ext, ksx1001, cp949,
  cp949ext, big5, cp950ext, big5hkscs, jisx0208, jisx0212, jisxcommon,
  jisx0213_*, cp932ext) read back from the codec that consults it first.
  big5 big5hkscs cp950 gb2312 gbk gb18030 hz euc_jp euc_jis_2004
  euc_jisx0213 shift_jis shift_jis_2004 shift_jisx0213 cp932
  iso2022_jp(_1, _2, _2004, _3, _ext) iso2022_kr euc_kr cp949 johab.
  **`tools/check_cjk_codecs.py`** compares every codec with python3 over
  every lead byte with every trail byte, the EUC three-byte sets,
  gb18030's 1.6 million four-byte sequences, each ISO-2022 set's 94x94,
  every code point encoded with three handlers, the JIS X 0213/HKSCS
  combining pairs and incremental use (`--quick` skips the all-code-point
  encodes): 0 differ on either engine.
- **Compression (innovation)**: the encoding maps are not stored - they are
  the inverses of the decoding maps plus 530 stored differences (of
  77,418 entries; 454 of them cp932's own extension) - and the rest is
  DEFLATEd (inflated by the native zlib on first use): 89 KB for every CJK
  table, where the same maps as CPython stores them are 602 KB of u16 rows.
- `lib/_multibytecodec.ny` (MultibyteCodec, incremental encoder/decoder
  with CPython's getstate/setstate, stream reader/writer), `lib/_codecs_{cn,
  hk,iso2022,jp,kr,tw}.ny`, the 24 `lib/encodings/` modules (CPython's,
  unchanged). str.encode/bytes.decode go native with a builtin handler
  (include/NyCodecs.hpp); a registered handler is called from
  `_multibytecodec.ny` (the native stops and returns where it is).
- **utf-7** native (include/NyCodecs.hpp, CPython's encoder and decoder,
  incremental); **mbcs/oem/code_page_*** on Windows (src/builtins/
  nycodecs.cpp over MultiByteToWideChar/WideCharToMultiByte, CPython's
  algorithm - strict errors at "position 0--1" as CPython reports them;
  checked as the MinGW build under Wine, not on a Windows machine).
- **idna**'s nameprep is RFC 3491's now (stringprep + ucd_3_2_0's NFKC;
  it was lower-casing).
- The single-byte code pages were all there already: none missing - all
  72 of CPython 3.11's charmap modules (cp037 ... cp1258, iso8859_1-16,
  koi8_*, mac_*, ptcp154, tis_620, palmos ...), each checked on every byte.
- email: Charset/Header/EmailMessage in iso-2022-jp, euc-jp, gb2312,
  euc-kr and big5 (header encode/decode, a message body set and read
  back) - the CJK half of email that needed these codecs.

### Engine changes (both engines unless said)
- `include/NyStr.hpp` (str's shared implementation): character classes and
  case mappings from the database, the full mappings and final sigma,
  casefold, title/capitalize/swapcase with title case, istitle/isupper/
  islower with titlecase letters, isdecimal/isnumeric no longer isdigit,
  isidentifier per PEP 3131; ASCII inline in each.
- `include/NyFormat.hpp`: `nypy::uni_to_ascii`, called by int()/float()
  (interpreter: src/builtins/pycore.cpp; VM: the int/float natives in
  include/VirtualMachine.hpp). Interpreter: `int(b"...")`'s error shows the
  bytes (it showed a str).
- `src/Lexer.cpp`: PEP 3131 identifiers (XID check, NFKC); a Python-mode
  file's "invalid character" token, raised by `src/Parser.cpp`'s atom() as
  CPython's SyntaxError.
- `src/NyUniNames.cpp`: `\N{...}` takes name aliases; CPython's lookup
  rules (`getcode`); `lookup_seq`/`name_3_2_0` for unicodedata.
- Interpreter (`include/NythonExecutor.hpp`): a bound method kept as a
  class attribute stays bound - `makeBoundMethod` returns it as it is and
  `invokeMember` calls it as it is (the VM did this already).
- `include/NyCodecs.hpp`: utf-7; the CJK codecs for str.encode/bytes.decode.
- `include/NyFuzzy.hpp`: search keys (fuzzy natives of both engines).
- New natives through the hashing bridge (src/builtins/hashing.cpp):
  `_ny_ucd` (src/builtins/nyunicode.cpp) and `_ny_mbc`
  (src/builtins/nycjk.cpp); `_ny_codec` gains "acp"/"cp_encode"/"cp_decode"
  (src/builtins/nycodecs.cpp, Windows); `nyz_inflate` in nyzlib.cpp.

### Not done
- One Unicode version, 14.0.0: the tables must be regenerated with
  python3.11 (`python3 tools/gen_unicodedata.py`; 3.12 has 15.0, 3.13 15.1,
  and vm_audit113's database checks fail under them, as they should).
- Not there: CPython's `_codecs_*.__map_*` capsules,
  `_multibytecodec.__create_codec`, `unicodedata.ucnhash_CAPI`. A
  registered (Python) error handler makes a CJK codec run through
  lib/_multibytecodec.ny's loop - correct, slower.
- Nython source keeps a non-XID identifier (emoji) as written; only a
  Python-mode file gets CPython's SyntaxError. NFKC applies to both.
- Found, not this part's: in this worktree `vm_audit110 --vm` fails its
  dbm section (the base binary too) - the branch has no lib/ast.ny (round
  83, part A) and the VM's `import ast` inside lib/dbm/dumb.ny loads the
  main checkout's /home/user/Nython-Good/lib/ast.ny, whose `_ny_ast` this
  build lacks. Gone once merged; how the VM reached a directory outside
  its installation was not traced.

## 0x3. Round 84, part C — tkinter, ttk and turtle over Nython's own GUI backend (vm_audit114)

`examples/vm_audit114.ny` (215 checks) passes on both engines. Under a
python3 without tkinter (this container's) it prints a skip line and 0
checks; with tkinter but no display it would run the Tcl-layer and variable
checks on `Tcl()` (that branch has not run anywhere).

Tk is written in Nython over the `gui_*` natives (the SDL3 backend or the
headless stub), so tkinter programs run without Tcl/Tk installed:
- **`lib/_tkinter/`** (package): `tcl.ny` - a Tcl subset (set/unset/incr/
  append/lappend, list, llength, lindex, lrange, concat, join, split,
  string, expr, if/while/for/foreach, break/continue/return/catch/error,
  eval, puts, info, proc, global, uplevel, subst, format, rename); `core.ny`
  - the application: event loop with timers and idle work, bindings and
  bindtags, focus with Tab traversal, grab, wm, winfo, the option database,
  clipboard, selection, fonts, images, `tk`, `bgerror`; `geom.ny` - pack,
  grid and place after tkPack.c / tkGrid.c / tkPlace.c; the classic widgets
  (`widgets.ny`, `entry.ny`, `text.ny`, `canvas.ny` with real PostScript,
  `menu.ny`); `image.ny` - photo images (PNG/GIF/PPM, put/get/copy with
  zoom and subsample, write) and bitmaps; `ttk.ny` - ttk's style engine
  (themes default/clam/alt/classic, elements, layouts, state maps) and the
  simple widgets; `ttk2.ny` - Entry, Combobox, Spinbox, Scrollbar, Scale,
  Progressbar, Notebook, Panedwindow, Treeview; `dialogs.ny` -
  tk_messageBox, tk_dialog, the file dialogs over the native one,
  tk_chooseColor.
- **`lib/tkinter/`**: CPython 3.12's package (with two 3.13 additions) -
  constants, ttk (3.13's), font, messagebox, simpledialog, filedialog,
  commondialog, dialog, colorchooser, scrolledtext, dnd. `TkVersion` /
  `TclVersion` 8.6; `tkinter._nython` is True.
- **`lib/turtle.ny`**: CPython 3.12's turtle.py, one line changed (marked
  "Nython:": an f-string nesting its own quote, PEP 701, which the lexer
  did not read).
- Nython's additions: `_ny_accessibility()` (role, name, state and bounds of
  every viewable widget), damage-only repainting at idle (`_ny_frames()`
  counts frames), and the scripted-input harness `_ny_drive` / `_ny_queue` /
  `_ny_snapshot` the test drives the widgets with.

**Engine changes** (both engines where both had the defect; marked
`(round 84)`):
- `abs()` / `round()` of a builtin-subclass instance whose own class
  defines `__abs__` / `__round__` calls it (`abs(Vec2D)` raised TypeError;
  `nyrt::payload_dunder`, interpreter `ownDunder()` in `unwrapBuiltinArgs`,
  VM `own_dunder()` in `unwrap_native_args`).
- Interpreter: a handled exception is forgotten when its clause ends
  (`forgetRaised`: `exc_instance_map_` / `exc_ring_`), unless an enclosing
  clause handles the same one - the 256-entry ring kept caught exceptions,
  and with them the locals of every frame they passed through, alive (a
  PhotoImage outlived its last reference). Also when `with` suppresses.

### Not done
- Tcl: namespaces beyond `::name`, upvar, arrays beyond `name(index)`,
  clock/file/channels (regexp is Python's re); `createfilehandler`, `send`;
  results are plain values, not Tcl_Obj.
- ttk: the Windows/macOS native themes and the vsapi element factory
  (clam/alt/classic draw with the default theme's elements); Treeview's
  8.7 additions; Notebook tabs only along the top; no Panedwindow sash grips.
- Photo images: `-gamma`/`-palette` stored but not applied; no SVG or
  `-metadata`. Tk's own Tcl file dialog (the native one is always used).
- Menu tear-offs and `-columnbreak`; text peers and full `-tabs`; canvas
  stipples and text `-angle`; `place configure .w` with no options gives
  the info string.
- The exception ring still keeps exceptions caught inside native code.
- Stub harness: scripted input goes to the most recent window unless
  `window N` is used; text-input events carry no modifier state; the key
  name `ctrl+slash` is unknown (`ctrl+/` works).

## 0x4. Round 84, part D — curses without ncurses, and a VT/xterm emulator to test it (vm_audit115)

`examples/vm_audit115.ny` (611 checks) passes on both engines; under
python3.11 with ncurses 6.4, 585. Under Wine 82 per engine (the pty groups
skipped: no pty or terminfo tools there).

Ten curses programs (basic, windows, pads, panels, scroll, textpad, input,
mouse_resize, colors, resume) run under a pty on xterm-256color and vt100;
after each step the emulated cells, cursor, alternate-screen state and
bells/flashes are compared with CPython+ncurses running the same program
live (or with its recorded screens, `tools/gen_vm_audit115.py`). Also:
terminfo entries against `infocmp` (tic-compiled 32- and 16-bit entries,
the hex directory layout, `TERMINFO_DIRS`, the built-in entries), tparm
cases, the emulator's parser, output byte counts.

- **`src/builtins/nycurses.cpp`** (`_curses_*` natives, reached by the VM
  through the sysmods bridge): terminfo in both formats (magic 0432 and
  01036, extended capabilities, the full search path, letter and hex
  layouts) with built-in xterm-256color and vt100 entries
  (`nycurses_tables.inc` from `tools/gen_nycurses_tables.py`;
  `NY_TERMINFO_BUILTIN=1` forces them); tparm's whole language with
  lib_tparm.c's corner cases, delays stripped or slept as tputs does;
  ncurses' screen model (windows, subwindows, pads, wide and combining
  characters, background rules); doupdate after tty_update.c (hashmap.c
  line matching, hardscroll.c scrolling, ClrBottom, TransformLine with
  el/el1/ich/dch/rep/ech, the mvcur cost model); input in ncurses' program
  tty mode with a key trie from the k* capabilities and ESCDELAY, SGR 1006
  and X10 mouse with click merging, SIGWINCH through a self-pipe giving
  KEY_RESIZE; on Windows the Console API in VT mode.
- **`lib/_curses.ny`** (CPython's `_curses` API, constants and messages;
  Nython's `nython_stats()` - bytes written, updates, the update mode
  `NY_CURSES_UPDATE` set - and `nython_terminfo()`), **`lib/_curses_panel.ny`**
  (ncurses' panel algorithms), **`lib/curses/`** (CPython 3.11's
  `__init__`, ascii, textpad, has_key, plus panel).
- **`lib/_nyvt.ny`**: a VT100/xterm emulator after Paul Williams' DEC
  parser (SGR with 256 and direct colours, scroll regions, insert/delete,
  the alternate screen, cursor save/restore, wide characters, mouse modes
  and replies); python3 can load it too.
- Beyond ncurses: each attribute change takes the cheapest of the
  individual exit codes, sgr0-then-set and `sgr`; colours are re-sent only
  when they change; on ECMA-48 terminals one change is one `CSI ... m`;
  `rep` for ASCII runs in a UTF-8 locale; ACS characters written as Unicode
  in a UTF-8 locale (lib_wacs.c's table). Scrolling workload: 7709 bytes
  (ncurses 7981); the test's 19 program runs: 12527 bytes (ncurses 18555).
- Engine: interpreter `importDotted` binds the submodule over a same-named
  attribute (`import curses.has_key` left `curses.has_key` the function;
  `Object::set` never overwrites). The VM already did.

### Not done
- ncurses' putwin/getwin file format (Nython writes its own,
  `NYCURSESWIN1`); slk soft labels, ripoffline; curses' own line editing in
  nocbreak mode; multibyte input assembled by `getch` (it returns bytes;
  `get_wch`/`getstr` decode UTF-8); xmc terminals, null padding,
  Berkeley-DB terminfo.
- Under Wine the console size reads 24x80 whatever the pty says and keys
  never reach `getch` (Wine keeps line mode): the pty programs are tested
  on POSIX only.
- `os.popen` is missing (the test works around it).

## 0w. Round 84 (main session) — the semantic gaps rounds 82-83 found (vm_audit116)

`examples/vm_audit116.ny` (34 checks) passes on both engines and under python3.
Sweep 449 runs, 0 not ok; `tools/ide_e2e.py` 463 passed, 0 failed; the memory
probe, lint, class check and cbp check clean.

- **A module's missing attribute** reads "module 'sys' has no attribute
  'x'" (both engines said "'dict' object has no attribute 'x'":
  `attributeErrorText` / `attr_error_text`).
- **Interpreter: `{}.append(x)` made the dict a list** (`[, x]`): the
  generic list/set method block in `callMethod` took any container; a plain
  dict now raises AttributeError for append/add/extend/insert/sort/... as
  the VM did.
- **BaseException's own `__init__`/`__str__`/`__repr__` are values**
  (`e.__str__()`, `ValueError.__init__`, `getattr(e, "__repr__")` raised
  AttributeError on both engines - cgitb, email, traceback-printing code
  read them): the prelude's `_NyExcExtra`, read where an exception class's
  lookup found nothing (`objectMember` / `object_member`, beside
  `_NyObjectExtra`), over three natives giving the engine's own results
  (`_ny_exc_init` - args and fields from (args, kwargs) as a constructor
  sets them -, `_ny_exc_str`, `_ny_exc_repr`). str(), repr() and
  constructors still go to the engines directly.
- **An instance's `__module__`** is its class's; **`__weakref__`** is None
  (absent with `__slots__` that do not name it).
- **Builtins have CPython's docstrings**: `len.__doc__`, `int.__doc__`,
  `str.upper.__doc__`, `[].append.__doc__`, `(5).__doc__`,
  `ValueError.__doc__`, `object.__doc__`, `range.__doc__`,
  `math.sqrt.__doc__` ... (they raised AttributeError or were None).
  `lib/_nydocs.ny` (1,303 keys, 130 KB, texts stored once) is generated by
  `tools/gen_builtin_docs.py` from the host python3 (3.11) and imported the
  first time a builtin's `__doc__` is read (the prelude's
  `_ny_builtin_doc`); the engines compute the key (`builtinDocKey` /
  `builtin_doc_attr`, `nyrt::builtin_doc_key`: `math_sqrt` is math.sqrt, the
  dict builtin is tagged `map`). A user class's docstring stays its own
  (None without one, a subclass of a builtin too). The prelude's builtin
  classes (range, property, staticmethod, slice, complex, the dict views
  ...) have `__module__ == "builtins"` (`nyrt::is_python_builtin_class`;
  they said `__main__`).
- **A finally body run while an exception propagates sees it**, as in
  CPython: `sys.exc_info()`, a bare `raise`'s lookup and the `__context__`
  of an exception raised there (they saw an enclosing clause's exception,
  or none). Interpreter: `evalTry`'s `run_finally_exc(e)` registers it in
  `handling_exc_`/`handling_obj_` while the body runs. VM: a try with a
  finally gets a hidden `__excN__` variable (`ExceptionEntry::fin_held`)
  that a new generic opcode, **`FIN_EXC_OF`** (appended after the
  specialized ones so no opcode number moves), fills from the finally state
  at the body's start and `DELETE_NAME` clears at its end; leaving the body
  by an exception, a break/continue (`drop_fin_states`) or a trace jump
  clears it too.
- **Comprehension targets unpack as Python unpacks** (both engines; a for
  statement's since round 82): exactly that many values, CPython's
  ValueError/TypeError (missing values were None and extra ones dropped -
  `bindTarget` now uses `forUnpackParts`, the VM's `store_target` the strict
  `UNPACK_SEQ`). **Starred comprehension targets** (`[b for a, *b in xs]`,
  nested ones too) were a SyntaxError: the parser rewrites the target to its
  names and wraps the iterable in the prelude's `_ny_star_iter(it, spec)`
  (`Parser::starTargetSpec`: the shape, 1 for the starred element), which
  reshapes each item with CPython's "expected at least N" errors. Not in an
  async comprehension (SyntaxError, stated).
- **`sys.audit` / `sys.addaudithook`** (PEP 578): hooks in the prelude
  (`_ny_audit_hooks`, `_ny_audit_fire`), called in order for every event; a
  hook raising RuntimeError on "sys.addaudithook" keeps the new hook out, as
  CPython's. Events raised by the runtime, with CPython's arguments: `exec`
  and `compile` (exec/eval of a source raise compile then exec; compile()
  compile), `import` (module, None, sys.path, sys.meta_path,
  sys.path_hooks - when a module file is loaded), `open` (path, mode
  without b/t, the os flags CPython computes: Linux's values),
  `builtins.input`, plus every library module's own (ftplib, smtplib,
  telnetlib, webbrowser ... called `sys.audit` where the runtime had it).
  The engines' audit points cost one byte test until a hook is added
  (`nyrt::audit_on`).
- **VM: a comprehension's renamed targets (`__cN_x`) go with it** unless
  something made inside it (a lambda, def, generator expression or class:
  a MAKE_FUNCTION/MAKE_CLASS among its instructions) may read them later:
  they kept the last item alive, and in a class body they were class
  attributes. (`DELETE_NAME` ignores a `__cN_` name never bound.)
- **True/False/None are spelled as the program's language spells them**:
  Python's (`True`, `None`) when the main program is a `.py` file or its
  leading comments say `# nython: python`, Nython's (`true`, `none`)
  otherwise (`print(True)` printed `true` in a .py program).
  `NYTHON_SPELLING=python` / `=nython` overrides. One setting per process,
  chosen by main.cpp before the program runs (`nypy::python_spelling`,
  `spell_bool`/`spell_none` in NyFormat.hpp, read by Value.cpp, the
  interpreter's `toText`, `VMVal::to_string` and the shared formatter); JSON,
  `--trace` recordings and the debugger keep Nython's.

### Not done
- `type(time.time)` is `staticmethod` (lib/time.ny wraps its functions so a
  class attribute holding one is not bound - CPython's builtins are not
  descriptors); a way to mark a Nython function "builtin" (no binding,
  `builtin_function_or_method` type, the module's name) is not there.
- `math.sqrt.__name__` is `math_sqrt` and its `__module__` `builtins`
  (natives named `<module>_<name>`); `sys.getrefcount.__name__` is
  `_ny_getrefcount`; `str.upper` shows as `<built-in function str.upper>`
  (CPython: `<method 'upper' of 'str' objects>`, a method_descriptor).
- Audit events not raised: `builtins.id`, `object.__setattr__`,
  `sys._getframe`, `os.*`, `socket.*`, `subprocess.Popen`, `ctypes.*`,
  `urllib.Request`, `pickle.find_class` ... - only the ones listed above and
  the library modules' own. exec's event carries the source string, not a
  code object.
- A starred target in an async comprehension.

## 0w2. Round 84 (main session) — C-implemented functions as builtins, module __getattr__, PEP 701 f-strings, the gaps the round's agents found (vm_audit117)

Verified with all of round 84 merged (a0af3f7: parts A-D and this): sweep
461 runs, 0 not ok; `tools/ide_e2e.py` 463 passed; memory probe, lint, class
check, cbp (76 units) clean.

`examples/vm_audit117.ny` (33 checks) passes on both engines and under
python3.12 (32 under python3.11, which has no PEP 701).

time.time, operator.add, heapq.heappush, bisect.insort, zlib.crc32,
binascii.hexlify, struct.pack, functools.reduce, os.fspath, os.scandir ...
are written in Nython; in CPython they are builtin functions, and code
relies on what that means: a builtin stored as a class attribute is not
bound (`converter = time.gmtime` in logging.Formatter, `timer =
time.perf_counter`), `inspect.isbuiltin` is true, `type(f)` is
`builtin_function_or_method`. lib/time.ny wrapped its functions in
`staticmethod` to get the first (so `type(time.time)` was staticmethod);
every other module bound them as methods.

- **A table generated from CPython** (`tools/gen_builtin_fns.py` ->
  `include/NyBuiltinFns.hpp`, `nyrt::cpython_builtin_fns(module)`): for
  every module lib/ provides (and the engines' os, sys, time, gc), the
  public names that are builtin functions of a module in any CPython
  3.10-3.13 found (942 names, 86 modules; bound methods of an instance, as
  random.random is, are not).
- **The engines seal a module when it has run** (interpreter
  `runModuleFile` / the os namespace builder -> `sealCModule`; VM
  `load_module_file` / its os builder -> `seal_cmodule`): the prelude's
  `_ny_seal_cmodule(module, names)` marks each plain function the module
  binds under one of its names with the native `_ny_mark_builtin`, and a
  function written under a private name (`_ny_os_fspath`) takes the public
  one (`__name__`, `__qualname__`). A program's own functions and the
  library's that CPython writes in Python (os.walk, json.dumps) are
  never touched (a Nython native is a builtin whatever CPython does:
  os.makedirs is `os_makedirs`).
- **A marked function** is static (the interpreter's `__static__` tag plus
  `__nybuiltin__`, `isNyBuiltinTag`; the VM's `VMCode::is_static` plus
  `VMCode::nybuiltin`): not bound through a class or an instance; `type()`
  is builtin_function_or_method; its repr is `<built-in function name>`;
  `C.__dict__` holds the function itself (no staticmethod object); its
  `__self__` is its module (`moduleValueByName` / `module_value_by_name`:
  sys.modules, the engine's own, builtins). It keeps `__code__`,
  `__defaults__` and its def's signature (`inspect.signature` gives it:
  CPython has text signatures for some builtins and none for others).
- **Natives carry their module's names** (`nyrt::builtin_public`):
  math.sqrt is `sqrt` of `math` (it was `math_sqrt` of builtins),
  sys.getrefcount `getrefcount` of sys, sys.exception `exception`,
  sys.settrace `settrace` (repr `<built-in function settrace>`), the os_*
  natives os binds as they are (getcwd, getpid ...) os's; `__self__` is
  the module (`len.__self__` is builtins).
- The prelude's `_ny_builtins_module()` (the builtins module, imported on
  first need) did not exist although both engines' sys.modules builders
  called it: `sys.modules["builtins"]` was missing. lib/builtins.ny now
  finds itself through `_ny_modules()` (sys's setup imports it before sys
  has its `modules` attribute).
- VM: `math.floor`, `math.ceil`, `math.trunc` (wrapped to honour
  `__floor__`/`__ceil__`/`__trunc__`) printed as `<native>` and had no
  `__name__`: the wrapper carries the native's tag.

**The gaps the round's agents found** (both engines unless noted):
- **PEP 562**: a module's own `__getattr__` supplies a name it lacks (`m.x`,
  `getattr`/`hasattr`, `m.f(...)`, `from m import x`, `__all__` in `from m
  import *`) and its `__dir__` answers `dir(m)` (interpreter
  `moduleGetattr` in `getAttrValue`, `callMethod`, `bindFromNamespace`; VM
  `lookup_attr`, `vm_call_method`, `bind_from_namespace`). lib/sqlite3's
  deprecated names rely on it.
- **"cannot import name 'x' from 'm' (path)"**, CPython's text: the
  module's file, or "(unknown location)" (`importWhere` / `import_where`).
- **`int(x)` falls back to `__index__`, then `__trunc__`** (it raised
  TypeError); `float(x)` to `__index__`; **`float()` of an int too large
  is OverflowError** "int too large to convert to float" (it was inf).
- **The installation's own `lib/` is searched before the importing file's
  ancestors** (interpreter `moduleDirs`, VM `module_dirs`): a program run
  from inside another checkout loaded that checkout's library modules (the
  agents' worktrees, nested in the main checkout, got its lib/ast.ny).
- **Interpreter: an unbound name read as `undefined`, not NameError, when
  any method or nested function had that name** (`knownName` counted every
  function value's name; asyncio's `Future.result` hid a missing `result`
  depending on which function values were alive - a pdb check failed after
  an unrelated merge). Only top-level functions and classes count now.
- **PEP 701 f-strings**: a replacement field may use the f-string's own
  quote, nest f-strings, span lines and hold comments
  (`f"{", ".join(xs)}"`, `f"{d["k"]}"`). The lexer reads the string after
  an `f` prefix with its fields copied as written
  (`Lexer::read_fstring_field` / `read_nested_string`: nested strings of
  any quote, brackets counted, a format spec's own fields followed). Raw
  f-strings (`rf"..."`) still end at their first quote.

### Not done
- `os.remove` is the `os_unlink` native, so its `__name__` is `unlink`
  (CPython has two functions); `__module__` of os's natives is `os`
  (CPython: `posix`, which Nython does not have as a module).
- A marked function still accepts keyword arguments for parameters CPython
  makes positional-only (`time.sleep(secs=1)`), and has `__code__`.
- `str.upper` shows as `<built-in function str.upper>` (CPython:
  `<method 'upper' of 'str' objects>`, a method_descriptor).
- `"s" + memoryview(b"x")` concatenates its repr (TypeError in CPython);
  `bytes.partition(sep)` gives the separator as bytes, not the object.
- Python's binding rule (an assignment in a function makes a local) for
  Python-language files: two agents hit Nython's rule in ported code.
- 158 public functions CPython has in these modules are missing in Nython
  (os: sysconf, statvfs, pread/pwrite, setuid/setgid..., sched_*,
  posix_spawn, getrandom, the xattr calls, eventfd, memfd_create, wait3/4,
  waitid ...; time.clock_gettime/clock_settime/clock_getres;
  signal.pthread_kill/sigtimedwait/sigwaitinfo/set_wakeup_fd/siginterrupt;
  socket.if_nameindex/CMSG_LEN/CMSG_SPACE/sethostname; sys's
  set_int_max_str_digits/unraisablehook/getallocatedblocks;
  gc.get_objects/get_referents/get_referrers; codecs' utf_7; ssl.RAND_*;
  hashlib.scrypt; locale's gettext functions). The generator's probe lists
  them.

## 0w1. Round 84 (main session) — ctypes structures by value on every ABI, and the Windows gaps round 83 left

Verified on fdfd393 (cherry-picked onto 263695d): sweep 451 runs, 0 not
ok; `tools/ide_e2e.py` 463 passed; memory probe, lint, class check, cbp
clean.

`examples/vm_audit111.ny` (55 checks) passes on both engines on Linux
(through libffi, and with `NY_FFI_NO_LIBFFI=1` on the built-in caller) and
under Wine 64-bit (no libffi there: the built-in caller); vm_audit109, 110
and 116 pass under Wine with the platform facts below.

**ctypes without libffi, structures included** (src/builtins/ffi.cpp). The
built-in caller (round 83) handled scalars; structures passed or returned by
value needed libffi. Now each ABI's own rules decide where a structure goes,
and only what no fixed prototype can express still needs libffi
(`need_libffi`: the error names the structure):
- **x86-64 System V**: the eightbyte classification (`sysv_classify`:
  INTEGER / SSE / MEMORY per eightbyte, over the structure's flattened
  leaves `spec_leaves`, laid out by `struct_layout` as the compiler lays
  them out). A structure of up to 16 bytes travels in its registers - the
  general and the vector register files are separate, so the same 6 + 8
  register prototype still calls any mix - and a MEMORY one is copied to the
  stack words (`N_STACK_CALL` is 16). A result comes back as `RII` / `RDD` /
  `RID` / `RDI` (two registers of each class) or, MEMORY, through the hidden
  pointer in RDI.
- **AAPCS64**: a composite of up to 16 bytes in x registers; a larger result
  through x8 (`RBlob<N>`: the compiler passes x8 for a returned aggregate of
  that size); a homogeneous floating-point aggregate (`aapcs_hfa`) needs
  libffi.
- **Windows x64**: sizes 1/2/4/8 travel as integers, anything else by
  reference to a copy; a result of other sizes through the hidden pointer in
  RCX.
- **32-bit x86**: a structure is its stack words; a result of up to 8 bytes
  comes back in EDX:EAX (Windows; System V i386 returns every structure in
  memory).
- On x86-64 System V callbacks receive structures by value too (the pool's
  dispatcher reads them from the registers or the stack as the caller put
  them).

**Windows callbacks** (`CFUNCTYPE`/`WINFUNCTYPE` without libffi; they
raised "callbacks need libffi on this platform"): Win64
passes the first four arguments in either RCX..R9 or XMM0..3 by position, so
a trampoline is chosen per float mask of those four (`P64<M,K>`,
`tramp_i/d/f<M,S>`, `g_pool[3][16][16]`: result class x mask x slot); 32-bit
x86 has cdecl pools and stdcall trampolines per argument word count
(`StdTramp`, 0-12 words), as stdcall callees pop their arguments.

**Windows fixes** (found running round 83's suites under Wine):
- `nython app.pyz` recursed without end: zipimporter's path hook imported
  `os.path` lazily while the hook ran, which asked the hook again. The
  prelude's `_ny_path_hooks_spec` caches the entry as "no finder" while the
  hooks run (the engines search it natively) and removes the entry if a
  hook raises.
- `lzma.decompress(garbage)` said "Corrupt input data" where liblzma says
  "Input format not supported by decoder": the native .lzma decoder now
  checks the header as liblzma does (properties, and through FORMAT_AUTO a
  dictionary size of 2^n or 2^n + 2^(n-1) and a plausible size).
- `faulthandler._sigsegv()` returned and exited 0: Windows' SIGSEGV handler
  gives the flow back, so the raise is repeated until the previous handler
  ends the process, as CPython does.
- mmap's errors were "[WinError N] ... failed": they carry
  `FormatMessage`'s text now (`fail_win`).
- `socket.AF_UNIX` is defined only where the platform has it (Windows had it
  as None, so `hasattr(socket, "AF_UNIX")` said True and the libraries took
  the Unix branch); lib/sockets.ny and asyncio read it with `getattr`.
- Test expectations that were Linux facts are platform facts now: `c_long`
  is 32 bits and `c_int is c_long` on Windows, `find_library`, the mmap
  error for an over-long map, `complex(-1.0, sin(pi))` from Wine's libm,
  filecmp's separators, a thread id's width, mailcap's image entry.

### Not done
- AArch64 structure paths are written to the ABI but were not run (qemu-user
  runs here; the libffi-less caller was checked on x86-64 and under Wine).
- HFAs on AArch64, and structures in variadic calls, still need libffi.
- Under Wine the interpreter's full vm_audit110 run sees one mbox flush raise
  PermissionError (Wine's rename over an open file); the check passes run
  alone.
- lzma compression needs liblzma (only the decoder is native).

## 0v4. Round 83, ctypes — ctypes, and type's own members (vm_audit111)

`examples/vm_audit111.ny` (53 checks) passes on both engines and under python3
(Linux; CPython's values throughout).
Sweep 447 runs, 0 not ok; `tools/ide_e2e.py` 463 passed, 0 failed; the
memory probe, class check and cbp check clean.

- **`ctypes`** (`lib/ctypes/__init__.ny`, `util.ny`, `wintypes.ny`; native
  `src/builtins/ffi.cpp`). CPython's object model: every instance is a view
  of native memory (`_b_addr`, `_b_base_`, `_b_needsfree_`, `_objects`
  keeping what its pointers point into alive); fields, array elements and
  pointer contents share their parent's memory. The simple types with
  CPython's platform aliases (`c_int is c_long` where they have one size),
  Structure/Union with `_fields_` in the body or assigned once later
  (recursive structures), bit fields laid out as the C compiler does
  (GCC/Clang's rule; MSVC's on Windows - CPython 3.12's own layout differs
  for some mixed-type runs), `_pack_`, `_anonymous_`, inheritance,
  BigEndian/LittleEndian structures; arrays (`T * n`, cached, through a
  metaclass `__mul__`), pointers, `cast`, `byref`, `memmove`/`memset`,
  `string_at`/`wstring_at`, string and unicode buffers, `from_buffer` (of
  ctypes objects), `from_buffer_copy`, `from_address`, `in_dll`; `CDLL`/
  `PyDLL` (`WinDLL`/`OleDLL` on Windows), function pointers with
  `restype`/`argtypes`/`errcheck`, CPython's ArgumentError messages and arity
  rules (cdecl takes extra arguments: a variadic call), structures returned
  and passed by value, `CFUNCTYPE` callbacks (qsort with a Python
  comparator), function pointers from an address, `use_errno`.
- **The native side is served by the concurrency runtime's dispatcher**
  (`nyconc::register_extension`, new): both engines get the `_ffi_*`
  builtins and a callback calls back into either engine through
  `Engine::call`, re-taking the GIL the call released (`nyconc::GilReacquire`,
  new). The dispatcher's argument/result interfaces carry bytes now
  (`Args::is_bytes/as_bytes`, `Ret::BYTES`) and `Engine::unbox_num` gives a
  callback's float result.
- **Calls go through libffi, loaded at run time** (libffi.so.8/7, .dylib,
  libffi-8.dll), as tls.cpp loads OpenSSL: any signature, structs by value,
  variadic functions (`ffi_prep_cif_var`), closures. **Without libffi a
  built-in caller** (Nython's own, `NY_FFI_NO_LIBFFI=1` forces it) relies on
  the calling conventions' register files: on x86-64 System V and AArch64
  (Linux) integer and float arguments fill separate registers in order and
  the excess goes on the stack in order, so one fixed prototype (8 integer
  words, 8 doubles, 8 stack words; variadic on x86-64 so %al is set) calls
  any function of scalar arguments, variadic ones included, and a pool of 32
  trampolines per result class reads every register for callbacks; Windows
  x64 gets one prototype per int/float mask of the first four arguments
  (positional registers); 32-bit x86 passes stack words (cdecl; stdcall by
  word count). Structures by value and long double need libffi (the error
  says so). `_ffi_backend()` says which is in use.
- **type's own members read from the builtin type**: `type.__new__(mcs,
  name, bases, ns)` written explicitly in a metaclass, `type.__init__`,
  `type.__call__(cls, ...)` (the instance without the metaclass's
  `__call__`), `type.__setattr__`/`__delattr__` (past a metaclass's hooks),
  `type.__getattribute__`, `type.__prepare__`, `type.mro`,
  `type.__subclasses__`, `type.__instancecheck__`/`__subclasscheck__` raised
  AttributeError on both engines (only `super().__new__` worked). The
  engines route them (`nyrt::type_own_member`) to the prelude's
  `_ny_type_m_*`, over natives that were registered but never written on
  the interpreter and absent on the VM (`_ny_type_new`, `_ny_type_call`).
- **A metaclass's operators apply to its classes** (`C * 3`, `2 * C`,
  `C | D`... with `__mul__`/`__rmul__`/`__or__` on the metaclass): both
  engines raised "unsupported operand type(s) for *: 'type' and 'int'" -
  the operator protocol looked at instances only. Arithmetic and bitwise
  operators, then the reflected form on the right operand's metaclass
  (interpreter `binaryOp` when any metaclass exists, VM `binop` for CLASS
  operands). ctypes builds its array types this way (`c_int * 4`).
- **The parser rewrote every `sizeof(x)` call to `len(x)`** (both engines),
  so a program's own `sizeof` - ctypes' - was never called. The builtin
  `sizeof` stays an alias of `len` for old code.

### Not done
- ctypes: memoryview of a ctypes object; `from_buffer` of a bytearray (its
  storage is not fixed native memory); paramflags (output parameters of
  prototypes); callbacks returning structures or called on threads Nython
  did not start; `pythonapi` is the process's symbols (Nython has no C API);
  COM; pickling ctypes instances. Bit-field structures and packed ones are
  passed by value to libffi as words of their alignment (right for integer
  members).
- `type.__dict__` is still missing.

## 0v. Round 83, part B — Python's system and command-line modules (vm_audit109)

`examples/vm_audit109.ny` (255 checks on Linux) passes on both engines
and under python3 (3.11: 253 checks - the Nython-only lzma fallback check and
the 3.12-only tty.cfmakeraw check are skipped there). Every expected value is
CPython's; bz2 streams are compared byte for byte with libbz2's.
`import errno` / `mmap` / `locale` / `optparse` ... all failed before.
Sweep 441 runs, 0 not ok; `tools/ide_e2e.py` 463 passed, 0 failed.

### Native parts (one entry point: `include/builtins/sysmods.hpp`)
- **`src/builtins/nysysmods.cpp`** (`_sys_*`): the errno table (an `#ifdef`
  per name in CPython's errnomodule order, so `errorcode` picks CPython's
  name for a shared number: EAGAIN, EDEADLOCK, ENOTSUP; WSAE* on Windows),
  the fcntl/termios/resource/syslog/locale constants from the C headers,
  fcntl/ioctl/flock/lockf (the blocking ones release the GIL), tcgetattr/
  tcsetattr/tcsendbreak/tcdrain/tcflush/tcflow/tcgetwinsize/tcsetwinsize,
  openpty/forkpty/fork/login_tty/waitpid (EINTR retried, signal handlers
  run)/the wait-status macros/execv/execve/_exit/ttyname, getrlimit/
  setrlimit/prlimit/getrusage/getpagesize, openlog/syslog/closelog/
  setlogmask, setlocale/localeconv/nl_langinfo/strcoll/strxfrm. **The
  process keeps LC_NUMERIC "C"** under a program's setlocale - the engines
  format floats with the C library - and the program's numeric locale is put
  in place only while localeconv/nl_langinfo/setlocale(cat, None) read it.
- **`src/builtins/nymmap.cpp`** (`_mmap_*`): mmap(2)/mremap, or
  CreateFileMapping/MapViewOfFile with `tagname` on Windows.
- **`src/builtins/nybz2.cpp`** (`_bz2_*`): bzip2 written here. Compression
  is libbz2's algorithm step for step (the initial RLE, fallbackSort's BWT
  with its exact tie-breaking, MTF/RUNA/RUNB, 2-6 Huffman tables with 4
  refinement passes, 17-bit length limiting by weight halving, the lazy bit
  writer), so the output is **byte-identical to libbz2's** at every level -
  checked on 34 inputs (periodic blocks, 1.2 MB of zeros, several blocks)
  against CPython's bz2. Decompression is resumable at block boundaries and
  reads every stream except the obsolete randomised blocks.
- **`src/builtins/nylzma.cpp`** (`_lzma_*`): liblzma loaded at run time
  (dlopen/LoadLibrary as tls.cpp loads OpenSSL; `NY_LIBLZMA` names one to
  try first, `NY_NO_LIBLZMA=1` pretends it is absent) for everything
  CPython's `_lzma` does. **Without it, a native decoder** (range coder,
  LZMA1, LZMA2 chunks, the .xz container with its index and CRC32/CRC64/
  SHA-256 checks, .lzma, raw, the delta filter), resumable at any input
  boundary - 425 cases against CPython's output, fed in 1-byte, 7-byte and
  whole pieces - so reading .xz works everywhere; a compressor then raises
  LZMAError naming the library.
- **`src/builtins/nycmath.cpp`** (`_cmath_*`): cmathmodule.c's algorithms
  and errno rules; the special-value tables (`nycmath_tables.inc`) were
  made by asking CPython for each entry.
- **`src/builtins/nyfault.cpp`** (`_fault_*`, `_tm_*`): faulthandler's dumps
  with write(2) only, reading each engine's frame records through the new
  `nyconc::Engine::walk_frames` (the live frames, or a parked thread's from
  its saved state); which engine runs the program is told by its frames
  (both engines exist in either mode - the interpreter's host object is a
  VirtualMachine - and only the running one has frames). Fatal handlers on
  an alternate signal stack, user signals, the watchdog thread.
  tracemalloc's records come from **replaced global operator new/delete**
  (one atomic byte test while tracing is off), with the allocating
  thread's Python stack.
- **`src/builtins/nyreadline.cpp`** (`_rl_*`): readline over the prompt's
  own line editor (`NythonREPL.hpp`'s MultilineEditor), not libreadline.

### Modules (`lib/`)
errno, fcntl, termios, tty, pty, resource, syslog, mmap, faulthandler,
tracemalloc, locale, gettext, getopt, optparse, fileinput, filecmp, sched,
cmath, colorsys, readline, rlcompleter, site (+ `_sitebuiltins`),
sysconfig, webbrowser, zipimport, zipapp, encodings (a package: 70
single-byte code pages and the Unicode codecs from CPython; `codecs.lookup`
imports it on a miss), stringprep (Unicode 3.2 tables generated from
CPython's ucd_3_2_0, and CPython's str.lower as a table), `_compression`,
bz2, lzma. Each file's header says what is not there. POSIX-only modules
(fcntl, termios, tty, pty, resource, syslog) raise ModuleNotFoundError on
Windows. `io.open_code` and `encoding="locale"` (UTF-8: Nython is always
in UTF-8 mode) were added to lib/io.ny for site.

### Engine changes (all marked "round 83")
- **`include/builtins/sysmods.hpp`** (new): `dispatch_sysmods` /
  `sysmods_builtin_names` and the per-file dispatchers; declares
  `nyfault_set_vm_engine`.
- **`include/NythonExecutor.hpp`**: includes sysmods.hpp; `registerBuiltins`
  registers `sysmods_builtin_names()`; `callBuiltin`'s `_`-prefixed block
  calls `dispatch_sysmods` after `_re_`. The round-81 `__spec__`/
  `__loader__` hook in the container attribute read also answers
  `__dict__` for a module namespace (`module.__dict__` raised
  AttributeError; it is the live `vars(module)` now). `dictKey`: a module
  namespace is hashed by identity (`hash(sys)`, `set(sys.modules.values())`
  raised "unhashable type: 'dict'").
- **`include/VirtualMachine.hpp`**: the same `__dict__` hook and
  module-identity hashing (`vkey`); `vm_call_method` makes
  `self.__class__(...)` before asking `__getattr__` (a class with
  `__getattr__` was asked for `__class__` - filecmp.dircmp); a list/dict/set
  comprehension's hidden accumulator `__compN__` is deleted (DELETE_NAME)
  once its result is on the stack - it kept the result alive until the
  comprehension ran again (`del` freed nothing, tracemalloc saw no memory
  go) and was a class attribute in a class body.
- **`include/NyPrelude.hpp`**: the `#@ os` chunk gets fork, forkpty,
  openpty, login_tty, waitpid, ttyname, the W* macros,
  waitstatus_to_exitcode, execv/execve/execl/execle/execlp/execlpe/execvp/
  execvpe (`_execvpe` searches `get_exec_path` with the Python-semantics
  `_ny_osp_dirname`/`_ny_osp_join` - the legacy `os_path_dirname("sh")` is
  "."), WNOHANG/WUNTRACED/WCONTINUED (POSIX) and `_exit` (all platforms);
  `_ny_module_spec_attr` answers `__dict__` with `vars(module)`;
  `_ny_load_spec` sets a submodule loaded through a path hook as its
  package's attribute (`import pkg.sub` then `pkg.sub`), as CPython's
  `_find_and_load_unlocked` does.
- **`include/NyConc.hpp`, `src/NyConc.cpp`**: `after_fork_child()` (the
  child of a fork: GIL off and fresh, this thread the main thread);
  `ThreadSnap` + `thread_snapshot()` (try_lock, no allocation; a task stands
  for its loop thread); `Engine::FrameEmit` and the virtual
  `walk_frames(estate, emit, sink)` (default: nothing).
- **`src/builtins/threading.cpp`**: `ny_interp_walk()` (an interpreter
  thread's frames without allocating; prelude frames left out);
  `InterpEngine` notes the live frames in `swap_in` and overrides
  `walk_frames`.
- **`src/VMConc.cpp`**: `VMConcEngine::walk_frames` (the live
  `call_stack_` or a parked thread's `VMThreadState::calls`);
  `VMConc::install` registers the engine with nyfault (the first VM made).
- **`include/NythonREPL.hpp`**: `ReadlineState` / `readline_state()` (the
  history, auto_history, completer delimiters, the line being completed,
  insert_text, the completion hook); `MultilineEditor` shares the history,
  completes on Tab through the hook (a second Tab lists), respects
  auto_history and starts a line with insert_text.
- **`src/main.cpp`**: `main_bootstrap`/`source_of` - a zip archive (PK
  magic, a shebang line allowed before it) or a directory with
  `__main__.ny`/`.py` runs `zipimport._run_main(path)`; `rl_complete_code`
  and the completion hooks in `interactive_interp` / `interactive_vm`.
- **`nython.cbp`**: the seven new units.
- **The process's global `operator new`/`delete` are replaced**
  (`nyfault.cpp`) for tracemalloc: one relaxed atomic load while tracing is
  off.

### Found on the way, fixed
- `codecs.charmap_encode`'s parameter is named `str` (CPython's name), so
  its `isinstance(rep, str)` asked about the argument, not the type: an
  error handler's replacement was never encoded through the map
  (`"a\u4e00b".encode("cp1251", "replace")` raised).
- lib/gettext.ny was taken from Debian's patched gettext.py (a langpack
  lookup, tab-indented comments): CPython's `find()` now.
- lib/io.ny: `open_code()`; `encoding="locale"` is UTF-8 (Nython is always
  in UTF-8 mode, `sys.flags.utf8_mode == 1`).
- examples/vm_audit91.ny: its pdb sessions start with `gc.collect()`; a cycle
  collection inside the traced call ran weakref callbacks (asyncio's
  WeakSets) that the debugger stepped into - GC timing, which any change in
  allocation patterns moves (this round's did).

### Not done
- **Nython's `str.lower`/`upper` cover Latin-1, Latin Extended-A, Greek
  and Cyrillic only** (`NyStr.hpp`'s `cp_lower`/`cp_upper`): Roman numerals
  (U+2160), circled letters, titlecase digraphs (U+01C5), Armenian,
  Georgian... are left as they are. stringprep carries CPython's lowercase
  map as a table instead.
- The VM's comprehension targets (`__cN_x`) stay bound after the
  comprehension (the last item stays alive; in a class body they are class
  attributes): a lambda made in the element may read them later, so they
  are not deleted as the accumulator now is.
- `frame.f_lineno`/`f_lasti` of a running module-level frame
  (`_ny_frame_sync`) copy the module's variables into the frame object,
  which keeps them alive until the next read (vm_audit109 orders its
  tracemalloc checks around it).
- A module the import statement makes for a hook loader whose
  `create_module` returns None (`_ny_module_new`) is not live through
  `vars()`/`__dict__`: `exec(code, vars(m))` fills a copy. zipimport makes
  a `types.ModuleType`, which is.
- No memoryview, so mmap has no buffer protocol (`bytes(m)` copies;
  `readinto(m)` cannot write into it) - **done in round 84, §0x**; no `sys.audit` (pty and webbrowser
  skip their audit events).
- encodings: no CJK codecs (big5, gb2312/gbk/gb18030, shift_jis, euc_jp/kr,
  iso2022_*, hz, johab, cp932/949/950), utf_7, mbcs/oem.
- readline: `set_startup_hook`/`set_pre_input_hook` are kept but the editor
  does not call them; the display-matches hook is not used; no vi mode or
  inputrc bindings.
- faulthandler: no C stack, no Windows structured exceptions; frames of
  Nython-written stdlib functions (time.sleep is lib/time.ny) appear in
  dumps where CPython's C functions do not.
- tracemalloc: sizes are the C++ allocations' (not CPython's object sizes);
  domain 0 only.
- lzma without liblzma: no BCJ filters, no compression. bz2: the obsolete
  randomised blocks are refused.
- Not run under Wine this round (the native files pass a MinGW
  `-fsyntax-only` check, Windows branches included).

## 0v3. Round 83, part C — sqlite3, the email package, mail/network protocols, data formats (vm_audit110)

`examples/vm_audit110.ny` (264 checks) passes on both engines and under
python3.11 and python3.12 (3.13 removed uu, mailcap, audioop, cgi, telnetlib
... and checks X.509 key usage, so it fails those sections). Every expected
value is CPython's (computed by python3); the 3.12-only checks
(`autocommit=`) carry CPython's values on 3.11 too. The sqlite3 checks are
skipped with a notice where libsqlite3 is not installed, the TLS checks
where there is no `openssl` command, the LMTP check where there are no Unix
sockets.

### sqlite3 over libsqlite3 loaded at run time
- **`src/builtins/nysqlite.cpp`** (natives `_sql_*`, reached by the VM through
  the builtin bridge): libsqlite3 is `dlopen`ed / `LoadLibrary`d on first use
  (`NY_LIBSQLITE3` names a library to try first; `libsqlite3.so.0`,
  `libsqlite3.dylib`, `sqlite3.dll`/`winsqlite3.dll`), as tls.cpp does with
  OpenSSL; without it `import sqlite3` raises ImportError naming the library.
  Optional entry points (window functions, backup, blob I/O, serialize,
  load_extension, db_config, trace_v2) are looked up separately and their
  absence reported when used.
- **Callbacks without calling back into an engine**: SQLite calls user
  functions, aggregates, window functions, collations, the authorizer, the
  progress handler and the trace callback from inside `sqlite3_prepare/step/
  exec`. Every such SQLite call of a connection that has callbacks runs on a
  **NyCoro coroutine of its own**; a callback *suspends* it and the native
  returns `[1, op, kind, fid, key, args]` to `lib/_sqlite3.ny`, which calls the
  program's function as ordinary Nython code and resumes the operation with
  `_sql_resume(op, status, value)`. So callbacks run identically on both
  engines (no VM value crosses into the interpreter's call path), raise and
  trace as ordinary code, may use the connection themselves (a nested
  operation is a coroutine of its own) and see threads normally; a
  connection without callbacks runs SQLite directly. The GIL is released
  while SQLite works (`nyconc::GilRelease` around each resume / call).
- **Rule: every SQLite call that can take a connection's mutex runs with the
  GIL released** (`nogil(...)` in nysqlite.cpp - reset, finalize, bind,
  column reads, errinfo, changes, create_function ...). A thread whose
  statement is paused in a callback holds that (recursive) mutex while it
  runs the callback's Nython code; another thread waiting for it with the GIL
  held deadlocked them both (8 threads sharing a `check_same_thread=False`
  connection with a user function). Values are made only after the GIL is
  back.
- **A cursor takes its statement out of the connection's cache** and gives
  it back once reset (`Connection._statement` / `_give_back`, one dict
  operation each way): CPython holds the GIL from the cache lookup to
  `sqlite3_step`, Nython's GIL may change hands in between, and two threads
  then bound and stepped the same statement (SQLITE_MISUSE, rows lost).
- `_sql_row` is given the columns to read as bytes as flags, never the
  converter functions: a VM function reaches the interpreter's natives
  through the bridge as no value (converters got str on the VM).
- Nython-only: `Connection.set_profile_callback(cb)` (`cb(sql, ns)` for each
  finished statement, SQLite's SQLITE_TRACE_PROFILE), `iterdump(filter=)`
  (3.13's), an LRU statement cache of `cached_statements` entries.
- **`lib/_sqlite3.ny`** is CPython 3.12's C module `_sqlite3` written in
  Nython: connect (paths/bytes/PathLike, `:memory:`, uri=, timeout=,
  detect_types=, isolation_level=, autocommit= with
  LEGACY_TRANSACTION_CONTROL, check_same_thread=, factory=,
  cached_statements=), CPython's transaction rules (the implicit
  `BEGIN ` before DML in legacy mode, COMMIT/ROLLBACK/BEGIN in autocommit=False
  mode, rollback on close), Connection/Cursor/Row/Blob/PrepareProtocol,
  adapters and converters (PARSE_DECLTYPES / PARSE_COLNAMES, `__conform__`),
  the statement checks (`lstrip_sql`, is_dml, "You can only execute one
  statement at a time.", the SQL length limit), the exception classes with
  `sqlite_errorcode`/`sqlite_errorname`, every SQLITE_* constant, and
  CPython's messages. `lib/sqlite3/` is CPython's package (dbapi2, dump,
  `__main__`).
- `dbm` is CPython **3.13**'s (dbm.sqlite3 first, then dbm.gnu/dbm.ndbm -
  ImportError on Nython - then dbm.dumb), `shelve` 3.12's.

### The email package and the mail modules
- `lib/email/` is CPython 3.12's package file for file (message, parser,
  feedparser, generator, policy, headerregistry, header, utils, mime/*,
  charset, encoders, contentmanager, iterators, errors, base64mime,
  quoprimime, _header_value_parser, _encoded_words, _parseaddr,
  _policybase). A corpus of 25 messages through every policy (parse,
  items, walk, decoded payloads, Generator at 40 columns, BytesGenerator),
  decode_header/getaddresses, the header registry over 14 addresses,
  parsedate over 7 dates and Header encoding: 974 results byte-identical to
  CPython 3.12's on both engines.
- `quopri`, `uu`, `mailbox` (mbox, Maildir, MH, Babyl, MMDF), `mailcap`.

### Protocols, data formats, audio
- `smtplib` (SMTP, SMTP_SSL, LMTP over TCP or a Unix socket, starttls,
  CRAM-MD5/PLAIN/LOGIN, send_message with Bcc and SMTPUTF8), `poplib`,
  `imaplib` (with literals and continuation requests), `ftplib` (active and
  passive, FTP_TLS with a protected data channel), `telnetlib`,
  `xmlrpc.client`/`xmlrpc.server`, `wsgiref`, `cgi`/`cgitb`, `netrc` -
  CPython 3.12's code over lib/socket.ny and lib/ssl.ny, tested against
  servers the test runs on localhost (and over TLS with a throwaway CA).
- `plistlib` (XML and binary): 60 random property lists dump to the bytes
  CPython 3.12 gives, both formats, sorted and not.
- `audioop` is CPython's C module written in Nython: 1,948 results of a
  fuzz (every 16-bit value through u-law/A-law, every function at widths
  1-4, ratecv, ADPCM with states) identical to CPython 3.12's on both
  engines. `wave`, `aifc`, `sunau`, `chunk`, `sndhdr`, `imghdr` are CPython's.
  The modules 3.12 deprecated warn at import as CPython's do
  (`warnings._deprecated`, new in lib/warnings.ny).

### Engine changes (both engines)
- **No `def init` constructor alias for a class with a `__new__` of its
  own** (`NythonExecutor::runConstructor` with `own_new`;
  `VirtualMachine::find_ctor(..., alias=false)` on the `__new__` path of
  `instantiate`). email.headerregistry's header classes define `init` as an
  ordinary method that `BaseHeader.__new__` calls with keyword arguments;
  Nython's legacy alias ran it a second time as the constructor with the
  constructor's arguments (KeyError: 'params'). Classes without `__new__`
  keep the alias.
- **VM: a builtin subclass instance stored by a builtin method keeps its
  class** (`VirtualMachine::unwrap_native_args`): `list.append`, `set.add`
  store their argument as given, and `list.insert`, `dict.setdefault`/`get`/
  `pop` unwrap only their first argument. A `str` subclass instance (an email
  header) appended to a `list` subclass came back as a plain str on the VM.
- **`float(b"1.5")` / `float(bytearray(...))`** parse the bytes, with
  CPython's ValueError (`could not convert string to float: b'x'`) -
  `pycore.cpp` `B_FLOAT`, the VM's `def("float")`. sqlite3 converters
  receive bytes.
- **A module that is not found is not marked imported** (interpreter
  `evalImport`: `imported_modules_.erase`; VM `vm_import`:
  `globals_.erase(guard_key)`): a second `try: import pydoc` "succeeded"
  without binding the name - a NameError at the first use (xmlrpc.server
  after cgitb had looked for pydoc).
- `src/builtins/nysqlite.cpp` registered in `registerBuiltins()` and the
  `callBuiltin` chain (`dispatch_sqlite` for `_sql_*`), `_sql_` in
  `isKwmapBuiltin`'s prefixes; `include/builtins/nysqlite.hpp`; the unit in
  `nython.cbp`.

### Library changes outside the new modules
- `lib/socket.ny`: `_GLOBAL_DEFAULT_TIMEOUT` (create_connection's default),
  `getservbyname`/`getservbyport` (/etc/services, else the well-known ports).
- `lib/urllib/parse.ny`: `unwrap` and the private `_split*` helpers.
- `lib/warnings.ny`: `_deprecated` (CPython's).
- `lib/copy.ny`: `copy()`/`deepcopy()` of a builtin-subclass instance whose
  class defines `__reduce_ex__`/`__reduce__` use it (the fast path for
  builtin values skipped it; email's headers are str subclasses with a
  `__reduce__`); `copy()` uses it before its atomic/container shortcuts.

### Adapted in the ports (each marked "(Nython: ...)")
- `sys.audit` is called only where the runtime has it (smtplib, poplib,
  imaplib, ftplib, telnetlib).
- `errno`, `locale`, `tokenize`, `ast` and `pydoc` are used when present
  (round 83's other parts add them): xmlrpc.client/poplib/imaplib/mailbox
  carry the errno values they need; cgi falls back to UTF-8 for the query
  string; cgitb's variable dump needs tokenize and carries pydoc's
  HTMLRepr/TextRepr; dbm.dumb reads its index with a small literal parser
  without ast; xmlrpc.server's DocXMLRPCServer needs a pydoc with HTMLDoc.
- memoryview (Nython has none): wave/aifc/sunau take `tobytes()`/`bytes()`,
  `sqlite3.Binary` is `bytes`, email's raw_data_manager registers bytes and
  bytearray.
- `True.__doc__` (email._policybase's docstring merging reads `__doc__` of
  every class attribute) - read with getattr.

### Found, not fixed
- `(True).__doc__` and other builtin values' `__doc__` raise AttributeError.
- `getattr(e, n)` fails for some names `dir(e)` lists: an exception's
  `__init__`, `__repr__`, `__str__`, `__module__`, `__weakref__`; an
  instance's `__module__`, `__weakref__` (cgitb's report reads them all).
- No `sys.audit`/`sys.addaudithook`.
- `bytes % args` (PEP 461) raises TypeError on both engines (round 77's
  deliberate message); the test's IMAP server encodes a str instead.
- Interpreter: `{}.append(x)` turns the dict into a list (`[, x]`) instead
  of raising AttributeError (the VM raises). Found through Nython's scope
  rule - a function's `results = {}` rebinds a module's `results` list.

### Not done
- `dbm.gnu`/`dbm.ndbm` raise ImportError (no `_gdbm`/`_dbm` native); `dbm`
  uses dbm.sqlite3 or dbm.dumb.
- The CJK codecs (iso-2022-jp, euc-jp, shift_jis, gb2312, big5 ...) are not
  in Nython's codec table, so email charsets that need them fail (the
  default-policy fuzz differs from CPython only there).
- `mailbox` locks with dot-locking only (there is no `fcntl` module);
  cgitb's variable dump needs `tokenize`, DocXMLRPCServer a `pydoc` with
  HTMLDoc, cgi's locale-dependent decoding `locale` (round 83's other parts
  provide them; until then the fallbacks above apply).
- `Connection.load_extension` is wired up but not tested (no extension
  library in the container); `telnetlib.Telnet.interact` needs a terminal
  and is not tested.
- Windows: `sqlite3.dll` / (64-bit) `winsqlite3.dll` are looked for, but
  the MinGW cross build and Wine were not run this round.
- bytes %-formatting (PEP 461), see above.
## 0v2. Round 83, part A — Python's language-tooling modules over Nython's own parser and VM (vm_audit108)

`examples/vm_audit108.ny` (224 checks on Nython) passes on both
engines (also with `NY_ASTSPEC=0` and `NY_QUICKEN=0`), under python3.12
(206) and under python3.11 (191: the PY312-guarded checks are
skipped there). It is generated: `python3.12 tools/gen_vm_audit108.py`
evaluates every check's expression under CPython 3.12 and writes its value
as the expectation (as vm_audit94 is made from CPython 3.11); the
Nython-only checks at the end (dis and opcode over the VM's bytecode, the
adaptive view, antigravity) are written by hand.

Merged onto round 84 part 0 (76638aa): sweep 451 runs, 0 not ok; `tools/ide_e2e.py` 463
passed; vm_audit108 224/224 on both engines. In ast mode the parser keeps a
starred comprehension target as Python's Starred (round 84's lowering is not
applied there).

**New modules** (lib/): `ast`, `token`, `tokenize`, `symtable`, `dis`,
`opcode`, `marshal`, `pickletools`, `pydoc`, `pyclbr`, `tabnanny`,
`py_compile`, `compileall`, `modulefinder`, `this`, `antigravity`. Each
header says what is there and what is not.

- **`ast.parse` is the real parser's tree.** `_ny_ast(source, mode,
  filename)` (src/builtins/text.cpp, `AstExporter`) runs
  `Parser::parseAst`, the parser every program goes through, in an *ast
  mode* (`Parser::ast_mode_`): where it would desugar it keeps Python's
  shape (`PyAstNode`, include/ASTNodes.hpp - decorators, chained
  comparisons, slices, f-strings, starred displays and unpacking
  assignments, match, except clauses, imports, with items, async
  constructs), it does not mangle private names, runs no NyScope check,
  keeps asserts, and records each node's tokens (`ast_spans_`, the
  parentheses written around an expression in `ast_outer_`, flags in
  `ast_flags_`; 23 parse functions are wrapped by `NY_AST_SPANNED`, one
  well-predicted branch when ast mode is off). The exporter emits
  CPython-shaped maps (columns UTF-8 byte offsets) that lib/ast.ny makes
  into its node classes. `ast.dump` of a 94-construct corpus is identical
  to CPython 3.12's with and without attributes, unparse round-trips it;
  **anything new the parser desugars needs its ast-mode branch**.
- **Tokens have an end** (`Token::end_row/end_col`, computed in
  `Lexer::make_token` from the token's bytes) and **a string token that
  spans lines is located where it starts** - a docstring's or a multi-line
  string statement's line was its last one in tracebacks, line events and
  `--trace` (vm_audit91/44/92/101 and the e2e suite pass unchanged).
- **f-strings are located part by part** in ast mode as CPython 3.12 does
  (`Parser::fstrPositions`): the literal's source text - an f-string, or a
  run of literals the lexer joined - is split as the value is and the two
  are matched part for part, so each literal run, field (`{` to `}`),
  format spec (`:` to `}`) and the nodes of a field's expression get exact
  positions; a field's tokens are moved to the source's coordinates and
  kept in `Parser::ast_extra_toks_` (spans index them from `kAstExtra`).
  An f-string nested in a field, a raw f-string, or one whose escape makes
  a brace has its parts at the whole string.
- **`compile(tree, filename, mode)`** on both engines hands the tree to
  the prelude's `_ny_compile_ast` -> `ast._ny_compile`, which compiles the
  tree's unparsed source written with each statement on its tree's line
  (tracebacks and line events are the tree's linenos); `compile(src, f,
  mode, ast.PyCF_ONLY_AST)` returns the tree.
- **`dis` / `opcode` are about Nython's VM**, not CPython's bytecode:
  `_ny_vm_code(f | source | code, adaptive)` returns a code object as JSON
  (`VirtualMachine::code_json`) on both engines - on the VM the function's
  own running code, on the interpreter its node compiled with the VM's
  compiler; `_ny_vm_code(None)` is the instruction set (`opnames_json`).
  Offsets are instruction indexes, jumps "to N". **`dis(f,
  adaptive=True)` on the VM shows the instructions round 80's quickening
  rewrote** (LOAD_NAME_FAST, BINARY_ADD_NUM, FOR_ITER_RANGE ...), as
  CPython 3.12's adaptive view; on the interpreter it is the compiled form.
- marshal is format 4 byte for byte (FLAG_REF set as CPython sets it for
  values held by a variable and built from literals - CPython's rule is
  the reference count); pickletools is CPython's file adapted
  (`dis`/`genops`/`optimize` byte-identical); pydoc is CPython's text half.

**Engine changes** (all commented `round 83`):
- `include/Token.hpp`: `end_row`/`end_col` (copied by the copy/move
  constructors and assignments).
- `include/Lexer.hpp`, `src/Lexer.cpp`: `token_start_off` (set in
  `reset_token`); `make_token` computes the end and locates a String/Bytes
  token spanning lines at its start; `optimize()` gives a joined literal
  its last piece's end and puts an f-string's `f` token at the run's
  start; `force_python_strings` (lib/ast.ny parses Python source).
- `include/INode.hpp` (`NodeType::PY_AST`), `include/ASTNodes.hpp`
  (`PyAstNode`), `include/Parser.hpp`/`src/Parser.cpp`: ast mode
  (`ast_mode_`, `parseAst`, `ast_spans_`/`ast_outer_`/`ast_flags_`,
  `NY_AST_SPANNED`, `importAst`, `tryAst`, `patAst`, `fstringAst`,
  `fstrPositions`, `ast_extra_toks_`, `mg()` not mangling in ast mode, and
  the ast-mode branches of the statement and expression parsers).
- `src/builtins/text.cpp`: `_ny_ast` (`AstExporter`); `string_first_line`
  clamps a line of 0 to 1.
- `include/NythonExecutor.hpp`: `_ny_ast`/`_ny_vm_code` registered;
  `compile` and `_ny_vm_code` take keyword arguments; `compileBuiltin`
  sends an AST or `PyCF_ONLY_AST` to `_ny_compile_ast`; `vmCodeInfo`;
  `makeBoundMethod` returns a bound method unchanged and `invokeMember`
  calls one with its own instance (a bound method stored in a class -
  pydoc's `repr = _repr_instance.repr` - was bound again); `typeNameOperand`
  / `typeWordShadowed` (a type word bound to something other than the
  builtin is that value in `is`: `module is not object` with a parameter
  `object`); `snippetSource`'s message for compile ("... or AST object");
  `float.fromhex` through `nypy::float_fromhex`. `src/builtins/core.cpp`:
  `_ny_vm_code` dispatched.
- `include/VirtualMachine.hpp`: names for 17 opcodes `op_name` lacked;
  `json_q`, `code_json`, `opnames_json`, `vm_code_info`, the
  `_ny_vm_code` global; `vm_compile` sends an AST / `PyCF_ONLY_AST` to
  `_ny_compile_ast`; `snippet_source`'s compile message;
  `COMPARE_IS_TYPE` arg 2 for builtin type words (`type_word_shadowed`);
  `float.fromhex` through `nypy::float_fromhex`.
- `include/NyBytes.hpp`: `nypy::float_fromhex` (CPython's grammar:
  `float.fromhex('0.8')` was 0.8 on both engines - strtod needs `0x`).
- `include/NyPrelude.hpp`: `_ny_compile_ast`; `_NyModuleType.__repr__`
  declares `var f` - **a prelude function's plain assignment rebinds a
  program global of that name on the interpreter** (repr() of the module
  inspect.getmodule makes replaced a program's function `f` with its
  `__file__`); the prelude has no other such assignment
  (scanned).
- `include/NyExcTypes.hpp`, `include/NyRuntime.hpp`: IndentationError
  (a SyntaxError) and TabError (an IndentationError) are builtin classes.

### Not done
- ast: `type_comments` (no TypeIgnore / type_comment), `feature_version`
  (accepted, ignored), 3.12's `type X = ...` and generic def/class (the
  parser reads neither); syntax errors give CPython's bracket messages and
  "invalid syntax", not its more specific wordings.
- dis: no CACHE entries, positions without columns, `co_code` keeps an
  argument's low byte only (the Instruction objects have the full one),
  free/cell variables not analysed; on the interpreter `adaptive=True` is
  the compiled form.
- marshal: code objects (ValueError, both ways); FLAG_REF can differ from
  CPython's for a value CPython built at run time (its rule is the
  reference count) - both read back alike.
- pydoc: no HTML, no server, no MODULE REFERENCE, no topics; help() in the
  prelude does not go through it. pickletools: no `-t` (no doctest module).
  py_compile / compileall check syntax and write nothing. antigravity
  opens nothing (there is no webbrowser module).
- Found, not changed: under `nython -m mod` sys.path[0] is the module's
  directory, not the current one (CPython's), so `nython -m pyclbr name`
  does not find a module of the current directory by name; on the
  interpreter, `import builtins` run inside a module that is the main
  program, after it defined a name a builtin has, gives that module's
  definition (tokenize and py_compile keep the builtins they shadow at
  import time); ~~builtin types have no `__doc__` (AttributeError) and
  `type.__subclasses__(C)` is an AttributeError on both engines~~ (both
  fixed by the time this part was merged: round 84 part 0 §0w and round 83's
  ctypes §0v4; pydoc's workarounds stay harmless); `inspect.getmodule()`
  makes a new module object per call.

## 0u5. Round 82, follow-ups (2) — Python source modules, quoted imports from anywhere, Python's lock (vm_audit107)

`examples/vm_audit107.ny` (22 checks) passes on both engines and under
python3 (the quoted-import checks are Nython-only and count as passed
there). Agent C's and part B's reports listed these; each was reproduced
first:

- **`import name` finds `name.py`**, a package's `__init__.py` and a
  namespace package of `.py` modules (both engines' `findModulePath` /
  `find_module_path`, the legacy single-name path, `-m`, importlib's
  `find_spec`, `__package__`/`__path__` for a `.py` package:
  `nyrt::is_package_init`). **Every directory is searched for `name.ny`
  before any is for `name.py`** (`nyrt::module_exts`), so the library's
  `.ny` modules are never shadowed by a stray `.py` file - CPython's
  sys.path order lets a `random.py` beside a script replace the standard
  library's; a `.ny` file beside the script still wins, as before. Within
  one directory `dual.ny` wins over `dual.py`.
- **A quoted import is also looked for in each library directory and in
  the installation's root** (`nyrt::quoted_import_candidates`): the
  library's files name each other `"lib/x.ny"`, which resolved only from
  the repository's directory or below it; a program anywhere can now
  `import "lib/heapq.ny" as hq`.
- **`threading.Lock` is Python's primitive lock**: a native mutex in a new
  mode (`Mutex::pylock`, `pylock_create()`): no owner - any thread releases
  it, and its holder acquiring it again *waits* for that (it raised
  DeadlockError: the acquire-here/release-there idiom, a lock used as a
  binary signal, failed on both engines). It takes no part in the wait-for
  graph or in lock-order checking (a lock used as a signal would be
  reported falsely), but still counts as held for the GIL hand-over; its
  release by another thread finds the acquirer's record by id (a task's
  record may be gone). CPython's errors and reprs (`release unlocked lock`,
  RLock's `cannot release un-acquired lock`, `can't specify a timeout for a
  non-blocking call`, `timeout value must be positive`). RLock stays an
  owned recursive mutex, as CPython's.
- **Inside an asyncio task, `threading.get_ident()`, `current_thread()`
  and `threading.local` are the loop thread's** (`thread_os_id()`), as in
  CPython - a task is not a thread; asyncio's per-thread policy map and
  `loop._thread_id` use it too. (`thread_id()` stays the record id - the
  native runtime's own per-task notion.)
- **`lib/_thread.ny`**: `start_new_thread` (daemon, an escaping exception
  reported as "Exception ignored in thread started by"), `allocate_lock`/
  `LockType`, `RLock`, `get_ident`, `get_native_id`, `interrupt_main`
  (the handler runs in the main thread; nothing when SIG_DFL/SIG_IGN),
  `exit`, `stack_size` (validated; always 0), `TIMEOUT_MAX`, `error`,
  `_count`, `_local`.
- threading's Lock, Condition, Semaphore and Event free their native
  objects in `__del__` (`sync_free`), as asyncio's do since §0u4.

### Not done
- `threading.get_native_id()` is the runtime's record id, not the OS's
  thread id; `stack_size()` sets nothing.
- A single-threaded program that acquires a held `threading.Lock` without
  a timeout waits forever, as in CPython (an owned `mutex_create` lock
  still raises DeadlockError).

## 0u4. Round 82, follow-ups — asyncio as CPython, a `gc` module, real file descriptors (vm_audit106)

`examples/vm_audit106.ny` (25 checks) passes on both engines and under
python3 (3.11). Part B's report listed what it left different from
CPython or out; done here, each reproduced first:

- **TaskGroup** raises every failure as a `BaseExceptionGroup` (an
  ExceptionGroup when all are Exceptions), a single one included - it
  raised a lone failure bare - with the children's errors in the order they
  failed and the body's last (it put the body's first); a child's
  SystemExit/KeyboardInterrupt is raised as itself; a failed child aborts
  the group from the loop (`call_soon`), as CPython's done callback does,
  so two children failing in one step both report (`except*` sees both).
  vm_audit67 was adapted (one failure is a group of one).
- **`wait()` refuses coroutines** (3.11: "Passing coroutines is forbidden,
  use tasks explicitly.").
- **`task.cancel()` without a message** gives `CancelledError()` with empty
  args (the runtime's "thread 'task-f' was cancelled" text was the
  argument): `check_cancel_locked` raises an empty message for a task, and
  **both engines now make a runtime error with no message `Type()`**
  (`excArgsFromMessage` / `exc_args_from_message`: empty args; StopIteration
  and GeneratorExit already were). vm_audit49 (the native async API) checked
  that str(e) mentioned "cancelled"; it now checks the type.
- **The default executor** is a `concurrent.futures.ThreadPoolExecutor`
  (`thread_name_prefix="asyncio"`), made on first use (it was a thread per
  call; `_DefaultExecutor` is gone).
- **`create_server(host=None)`** listens on every wildcard address
  getaddrinfo gives (IPv4 and IPv6; it bound 0.0.0.0 only), skipping a
  family the host cannot open (this container has no IPv6 sockets -
  CPython does the same).
- **`loop.sock_sendfile`** (the kernel's `os.sendfile` where there is one,
  falling back to reading blocks, `fallback=`), **`loop.sendfile`** through a
  transport (CPython's `_SendfileFallbackProtocol`: reading paused, writing
  paced by the transport's flow control, the protocol restored after) and
  the parameter checks; **`os.sendfile(out, in, offset, count)`** is new
  (Linux/macOS, `src/builtins/os_fd.cpp` + the prelude's POSIX members).
- **`loop.connect_read_pipe` / `connect_write_pipe`** with CPython's
  `unix_events` pipe transports (`_UnixReadPipeTransport`,
  `_UnixWritePipeTransport`: non-blocking fd, add_reader/add_writer,
  write buffering with flow control, the reader's end closing seen as the
  write end becoming readable); POSIX only (NotImplementedError on Windows).
- **Async generator hooks**: `sys.set_asyncgen_hooks` /
  `get_asyncgen_hooks` (an `asyncgen_hooks` struct sequence; per OS thread,
  keyed by the new native `thread_os_id()` - inside a task `thread_id()` is
  the task's own record, so the loop's thread is what CPython's thread
  state stands for). The prelude's `_NyAsyncGen` calls firstiter on its
  first step (`__anext__`/`asend`/`athrow`/`aclose`, and `async for`
  through `_ny_aiter`) and the finalizer from `__del__` when it has not
  finished. The loop installs its hooks while it runs (as CPython's
  `run_forever`), keeps started generators in a WeakSet, and
  `shutdown_asyncgens()` closes them (it closed nothing) - so `asyncio.run`
  runs the `finally` of a generator the program abandoned.
- **A `gc` module** (`lib/gc.ny`; there was none - `import gc` failed):
  enable/disable/isenabled, collect(generation) with `callbacks`,
  get_count/get_threshold/set_threshold/get_stats, garbage, is_tracked,
  freeze, get/set_debug, over the engines' `gc_*` builtins (its header says
  what is approximated: collect is always full, get_objects/get_referrers
  are not provided).
- **Found on the way: a file object's `fileno()` was its handle number**
  (1000 and up), not the OS descriptor, on both engines - `os.*` accepted it
  (`fd_arg` maps handles), but `select`/`poll` took it literally, saw an
  invalid descriptor and reported it ready (the write-pipe transport closed
  itself at once). `NythonFile.fileno()` now returns the descriptor (new
  native `file_fileno`, `src/builtins/io.cpp`); `fd_arg` still accepts a
  handle number.

### Verified
- vm_audit106 27/27 on both engines (26 under python3: the native-object
  check is Nython-only); vm_audit67, 104, 49,
  97, 76, 77, 93 on both engines; `python3 tools/sweep.py` 437 runs, only
  vm_audit49's pinned message failing (adapted, then 54/54 on both
  engines); `tools/ide_e2e.py` 463 passed; `ide_memprobe --check` passes;
  lint, classcheck, cbp clean.

- **"Task exception was never retrieved" / "Future exception was never
  retrieved"**: NyConc's Task records whether its error was handed to anyone
  (`err_seen`: an await, `task_result`, gather - which takes every child's
  outcome, as CPython's - a hand-driven coroutine, async_run's main task);
  the new native `task_error_unseen(h)` tells asyncio's `Task.__del__`,
  which reports through the loop's exception handler as CPython's
  `Future.__del__`; asyncio's own Future reports from its `_log_traceback`.
  So that a dropped finished task is collected at all, the task registry
  (`_tasks`) lets go of a task when its body ends (`_forget_when_done`; it
  kept finished ones until the table doubled).
- **The native objects under asyncio's Event, Lock, Semaphore and Queue are
  freed** with them (`__del__` -> the new native `sync_free(h)`, which drops
  an event/semaphore/mutex/condition/rwlock/barrier/latch/atomic/channel
  only while nothing waits on it - a waiter holds it by address; part B
  found them kept for the life of the process).

### Not done
- ~~`threading.get_ident()` inside a task is still the task's record id
  (CPython: the thread's); only the asyncgen hooks use `thread_os_id()`.~~
  **Done in §0u5.**

## 0u. Round 82, part C — NyxAI, a programming agent that works offline (vm_audit105, e2e `agent`)

`lib/aiagent.ny` (pre-round-73 keyword matching that indexed empty lists as
dicts) is now an agent that answers from the workspace's code, with no model
and no network, deterministically. The parts are a package of their own,
`lib/nyxai/` (`# nython: module` files), put together by `lib/aiagent.ny`'s
`NyxAgent` and wired into the IDE by `ide_agent.ny`.

### The native part: `ny_facts(source)` (`src/builtins/text.cpp`)
Walks the AST the engines run (as `text_defuse` does) and returns, per
function: name, qualname, enclosing class and def, lines (def, first
decorator, end - indentation-based so trailing comments count), decorators
(source text), async/generator, docstring and its line, parameters (name,
inspect's kind, default as source text and its kind - literal/list/dict/
set/call:<callee>/name/expr, annotation text), return annotation, returns
([line, has value, text]), raises ([line, exception, text]), calls ([line,
callee text]), names read and written, `global`/`nonlocal`, except clauses
with their types, McCabe's complexity (decision points as radon counts
them) and whether control can fall off the end; per class: bases, doc,
methods, decorators; imports; unreachable statements (after return/raise/
break/continue or an if/try whose every branch ends so); bare excepts;
`== None` comparisons; the module's own top-level facts. Expressions are
rendered back to text by a small unparser. Registered in
`NythonExecutor::registerBuiltins` (the VM reaches it through the bridge).

### lib/nyxai
- `facts.ny` — `ProgramModel`: modules, `FunctionInfo`/`ClassInfo`, name
  resolution across files (same module, `from m import f`, `mod.f`,
  `self.m`/`cls.m`/`super().m` through workspace base classes, a class call
  as its `__init__`, else the only function of that name), the call graph,
  callers, reachability, the import graph (quoted imports matched by path),
  external imports, globals read/written; `rule_facts()` and
  `default_rules()` for the rule engine.
- `index.ny` — `WorkspaceIndex`: BM25F (Robertson & Zaragoza 2009) over
  function/class/module chunks and document sections (Markdown headings),
  fields name 4 / doc 2 / comments 1.5 / code 1 / path 1; identifiers split
  at camelCase/snake_case and stemmed lightly; a definition of a symbol the
  query names x2 over its uses; one step of score propagation over the call
  graph (0.3 of a neighbour's score, after Shakery & Zhai 2003); each hit
  cites file:line of its best-matching line; incremental `update_file`/
  `remove_file`; JSON `save`/`load`; `refresh()` re-indexes by mtime.
- `rules.ny` — `RuleEngine`: facts as tuples, rules with `?variables`,
  `("not", ...)` and `("test", fn)` conditions, functions as conclusions;
  alpha memories by predicate and by (predicate, position, value), semi-
  naive joins from the new fact (Forgy's Rete at a small scale), stratified
  negation (an unstratifiable program raises ValueError), `why()`
  derivations. `default_rules`: reaches, recursive, isa (exception
  hierarchy), handles, may_raise / raises_via through calls not handled
  there, impure (module writes, I/O) / pure, called, unused.
- `review.ny` — `Reviewer`: unused-import, unused-variable (def-use from
  `text_defuse`, closures counted), unreachable-code, shadowed-builtin,
  mutable-default, bare-except, none-comparison, too-complex (McCabe > 10),
  missing-self, inconsistent-return (PEP 8); each finding file:line, a
  message, a suggestion, and line edits for the mechanical ones;
  `fix_text` applies non-overlapping edits and returns difflib's unified
  diff (patience).
- `testgen.ny` — `TestGenerator`: parameter domains from annotations,
  defaults, else type probing in a child (int, str, list, float: the first
  that raises neither TypeError nor AttributeError, as Pynguin does);
  boundary values one parameter at a time; the docstring's doctests; random
  inputs (a seeded LCG) checking determinism and that nothing but declared
  (or boundary-observed) exceptions is raised - a counterexample is shrunk
  greedily in one child (QuickCheck); everything runs in a child process
  (`sys.executable`) with a timeout, and the child logs each case before it
  runs, so a call that never returns costs only that case (reported, the
  rest run in a fresh child). The module it writes asserts what was
  observed (assertEqual on values whose repr evaluates back, assertAlmostEqual
  on floats, assertRaises, a type check otherwise) and runs with
  `nython test_x.ny` and `nython -m unittest test_x`; for a `.py` module the
  test loads it by path (importlib.util), so `python3 -m unittest` runs it
  too (Nython's `import name` finds only `.ny` files - not changed).
- `docgen.ny` — `draft_docstring`/`docstring_edit`: Google style; summary
  from the name or the existing first line, Args with types from
  annotations/defaults and how the body uses each (iterated, called,
  indexed, may be None, passed to f()), Returns from the annotation or the
  returned expressions' kind, Raises with the condition the raise is control
  dependent on (`text_defuse`'s predicates: "If m < 1.") and what calls let
  through (the rule engine's raises_via).

### lib/aiagent.ny
`NyxAgent(root, state_dir)`: `index_workspace()` (loads and refreshes a
saved index or builds one, trains the completion model), `file_changed()`,
`sync()` (what changed on disk, by mtime),
`ask()`, `explain()`, `test()`, `doc()`, `review()`, `fix()` (a diff;
`apply()` writes it), `rerank()`, `run_command(verb, arg)`; replies are
`AgentReply` objects (items with style and an optional file:line link).
The round-72 classes keep their names and interfaces, now on these parts:
`CodeKnowledgeBase` ranks documents by BM25; `CodeAnalyzer.analyze()` is the
review rules (same dict shape the IDE read); `ReasoningEngine` is the rule
engine (a word condition is the fact mentions(stem), so "terror" no longer
matches "error"); `GitHubLearner`/`DocumentLearner` fetch through
urllib.request with a configurable `raw_base`; the empty-list-as-dict
writes (`self.rules[self.rule_count] = ...`), `most_accessed`'s infinite
loop and `forget`'s None entries are gone.

### The completion model (`lib/nytorch/agent_learn.ny`)
`code_tokens()` (one native regex pass), `CodeTokenModel` - an online
trigram/bigram/unigram model with Witten-Bell interpolation and a cache of
recent identifiers (Hindle et al. ICSE 2012; Tu, Su & Devanbu FSE 2014) -
and `CompletionRanker`, which adds the round-72 category MLP
(`TokenLanguageModel`, gradient steps on a sample of each file's category
pairs) and re-orders a candidate list: exact-case prefix matches, then
case-insensitive ones, then fuzzy ones, the model's order within each.
`completion_mrr()` measures the mean reciprocal rank of the token the user
went on to type in the list the IDE shows (ac_index_rank) after its first
character: on vm_audit105's held-out file 0.639 before training, 0.975
after two files of the same project. The MLP's gradient steps are the slow
part, so they are sampled (24 pairs a file, 240 in all); the n-gram counts
see every token.

### The IDE (`ide_agent.ny`, `IDEAgent` between IDELive and NythonIDE)
Terminal `@ask/@explain/@test/@doc/@review/@fix`; palette "Agent: Ask...",
"Explain Symbol", "Generate Tests", "Draft Docstring", "Review File", "Fix
File", "Apply Fix", "Discard Fix", "Index Workspace" (symbol commands use
the word under the caret); the activity bar's sparkle view is now AGENT:
the last answer, every file:line a link, Apply/Discard for a fix or a
docstring (the diff is shown first; applying replaces the editor's text as
one undo group). Answers are also written to the Output panel. The index
lives in the IDE's temporary directory (`<tmp>/nyide_agent/<path key>`); a
saved or reloaded file is re-indexed at once, every command first refreshes
by mtime; `_ac_open_now` re-ranks the completion list once the model is
trained. e2e `agent`; memprobe `agent` (hover with an answer shown) and
`agentkey` (typing with re-ranking).

### Also
- `nython -m unittest test_x [Test.test_m ...]` (lib/unittest.ny's
  `_ny_unittest_cli`): the names' tests (a test_x.py is loaded by path), or
  the working directory's test*.ny/py files. Run as `__main__`, unittest.ny
  is a second copy of the module, so the CLI uses the imported `unittest`'s
  loader and runner (as CPython's unittest/__main__.py does).
- `text_defuse` bound nothing for `from m import a as b` (the parser joins
  name and alias with `\x05`; only " as " was looked for) - it binds `b` now.
- vm_audit105: 118 checks, both engines (~10 s each).

### Not done
- No free-text generation: answers are ranked, cited excerpts and facts.
- Test generation covers functions and static methods (and methods of
  classes constructible without arguments); not generators, async
  functions, or user-defined argument types.
- Retrieval is lexical (no synonyms/embeddings); the index is per root.
- The rule engine is monotonic (no retraction); `handles` is per function,
  not per try block.

## 0u2. Round 82, part B — asyncio's missing half: the loop API, transports and protocols, subprocesses, Unix sockets, signals, TLS (vm_audit104)

`lib/asyncio.ny` became the package `lib/asyncio/` (`__init__.ny` holds
everything; `subprocess`, `events`, `protocols`, `transports`, `streams`,
`futures`, `tasks`, `locks`, `queues`, `runners`, `timeouts`,
`base_events`, `coroutines`, `taskgroups`, `exceptions` re-export from it,
so `asyncio.subprocess.PIPE` and `from asyncio.subprocess import PIPE`
work after `import asyncio`). CPython 3.12's semantics and messages; the
module's header lists what is there and what is not. `examples/vm_audit104.ny`
(113 checks on both engines; the shared part passes under python3.11 - 108,
eager tasks and Queue.shutdown skipped -, 3.12 - 109 - and 3.13 - all 110;
under Wine 102 pass on both engines, subprocesses included - the POSIX-only
parts and TLS skipped) pins it.

### The event loop is a persistent native loop
- `new_event_loop()` gives a `SelectorEventLoop` over `async_loop_new()`
  (src/NyConc.cpp): a native `Loop` that outlives a run. Tasks and callbacks
  are put on it before it runs and from any thread (`async_loop_spawn`,
  `async_loop_call` - thread-safe, they wake a polling loop);
  `run_until_complete`/`run_forever` run it on the calling thread
  (`async_loop_run(loop, task)`) and leave what is unfinished for the next
  run; `stop()` (`async_loop_stop`) ends a run after the batch that was ready
  (asyncio's rule; a stop before the run gives one batch); `close()`
  (`async_loop_close`) cancels what is left, lets it unwind and frees it.
  The classic `loop.run_until_complete(start_server(...)); loop.run_forever()`
  works. `async_current_loop()` maps a running task to its loop object.
- `call_soon`/`call_later`/`call_at` make a `Handle`/`TimerHandle` whose
  `_run` is one callback task of the loop (`async_loop_call(loop, delay, fn)`
  - a CALL_LATER with an absolute deadline, so a timer set before the loop
  runs fires at its time). Callback tasks are *ephemeral*: their records
  are freed as soon as they have run. FIFO with task wake-ups, as asyncio's
  ready queue. `current_task()` is None inside a callback.
- `asyncio.run`/`Runner` are CPython's: a loop per Runner, the main task,
  `_cancel_all_tasks`, `shutdown_asyncgens`, `shutdown_default_executor`;
  Ctrl+C installs the Runner's SIGINT handler: the first one cancels the
  main task and `KeyboardInterrupt` is raised once it has unwound (a main
  task that handles the cancellation returns normally); the default handler
  is restored after.
- Task: CPython's `Task(coro, loop=, name=, context=, eager_start=)` over a
  native task; `cancel(msg)` (the native `task_cancel(h, msg)` - the
  CancelledError carries msg), `cancelling()`/`uncancel()` counted on the
  object, `get_coro/get_context/get_stack`, done callbacks run by a watcher
  task. `wait_for` and `timeout()`/`timeout_at()` are 3.12's (an
  `async with Timeout` that cancels the task and turns its CancelledError
  into TimeoutError *only* when no other cancellation is pending, so an
  outer cancel stays a CancelledError). `eager_task_factory`: the native
  `async_create_task_eager` puts the new task at the front of the ready
  queue and the creator right behind it - the new task runs until its first
  wait (or to its end) inside `create_task`. Barrier is 3.11's state
  machine; `Queue.shutdown` is 3.13's (getters woken through the channel's
  close).
- Exception handlers: `set/get/call/default_exception_handler` with
  CPython's contexts; the default one logs through the `asyncio` logger
  (`logging`, loaded on first use). Debug mode (`set_debug`,
  `PYTHONASYNCIODEBUG`, `run(debug=True)`) records where handles were made
  and logs callbacks slower than `slow_callback_duration`.
- `run_in_executor`: a ThreadPoolExecutor given by `set_default_executor`
  or any concurrent.futures executor; the default is a thread per call
  (concurrent.futures is heavy to import). `to_thread` goes through it.

### Transports and protocols
All of `asyncio.protocols`/`transports`; `_SocketTransport` serves TCP,
Unix and TLS sockets: the socket is non-blocking, a reader task waits for
it on the loop's reactor (`sock.wait_readable()` parks the task) and calls
the protocol (`data_received`, `eof_received` - a true result keeps the
connection half-open - or a `BufferedProtocol`'s `get_buffer`/
`buffer_updated`); `write()` sends at once what the socket takes and
buffers the rest for a writer task, calling `pause_writing()` above the high
water mark and `resume_writing()` at the low one
(`set_write_buffer_limits`, 64 KB/16 KB by default). `pause_reading`/
`resume_reading`/`is_reading`, `abort`, `write_eof`, `get_extra_info`
(socket, sockname, peername, sslcontext, ssl_object, peercert, cipher).
`create_connection` (resolution in the executor unless the host is
numeric; CPython's argument checks and "Connect call failed" errors),
`create_server` -> `Server` (`serve_forever`, `start_serving`, `close`,
`wait_closed` waiting for the connections too, `sockets`, `async with`),
`connect_accepted_socket`, `create_datagram_endpoint` (UDP; `sendto`,
`error_received`), `create_unix_connection`/`create_unix_server` (a stale
socket file is replaced), `add_reader`/`add_writer` (a task per descriptor,
level-triggered), `sock_*`. The streams are CPython's code over the
protocols (`StreamReaderProtocol`, `FlowControlMixin`; `drain()` really
waits while the transport is paused; `StreamWriter.start_tls`).

### Subprocesses
`create_subprocess_exec/_shell` -> `Process` (stdin/stdout/stderr streams,
`communicate`, `wait`, `returncode`, `pid`, `send_signal`/`terminate`/
`kill`), `loop.subprocess_exec/_shell` with a `SubprocessProtocol`
(`pipe_data_received`, `pipe_connection_lost`, `process_exited`, then
`connection_lost`). Built on `os_spawn` (lib/subprocess.ny's plan:
PIPE/STDOUT/DEVNULL/None) plus one new native, `os_proc_fds(pid)` - the
pipes' descriptors - so **the pipes are waited for on the loop's reactor**
(`_net_select` on them parks the pump task; `os_proc_read` drains; stdin is
made non-blocking and written with `os.write`, the task waiting for the
pipe while it is full). Chosen over a pipe-watching thread: no thread per
child, no extra wake-ups, and a 300 KB `communicate()` input cannot
deadlock against the child's output (both directions are serviced by the
same loop). On Windows, whose pipes cannot be polled (`os_proc_fds` gives
-2), the pump polls `os_proc_read` with a 1-50 ms backoff and stdin is
written by `os_proc_write` in an executor thread. The exit status is
polled (`os_poll`, 1-50 ms backoff) once the pipes have closed.

### Signals
`loop.add_signal_handler(sig, cb, *args)` installs a Nython signal handler
(round 77's layer: it runs on the main thread at the next safe point, in a
task or between tasks) that schedules the Handle as a loop callback;
`remove_signal_handler` restores SIG_DFL (default_int_handler for
SIGINT). CPython's errors (`sig N cannot be caught`, coroutine callbacks,
invalid numbers). POSIX only, as CPython (NotImplementedError on Windows).

### TLS
`ssl=` on `create_connection`/`create_server`/`open_connection`/
`start_server`/`create_unix_*`, `ssl_handshake_timeout`, `loop.start_tls`
and `StreamWriter.start_tls`: the socket is wrapped by lib/ssl.ny (the TLS
layer is the socket's) with the handshake done in the task (parked, with
the handshake timeout as the socket's timeout), then the transport reads
and writes it as a plain one; `start_tls` stops the old transport's reader
(a paused reader never reads the ClientHello) and makes a new transport
over the same descriptor. Closing sends close_notify. vm_audit104 makes a
throwaway CA with openssl (strict-X509 compliant: python3.13 checks key
usage).

### Structured-concurrency reports (the innovation)
After Smith's "Notes on structured concurrency" and Trio's nurseries,
which make it impossible for a task to outlive the block that started it:
asyncio cannot forbid it without breaking programs, so it reports it.
`asyncio.run(main, orphans="warn"|"raise"|"ignore")`, `Runner(orphans=)`,
on by default ("warn") in debug mode. Tracked tasks record where they were
created (`sys._getframe`) and by which task; when a task ends while a task
it created still runs, and when the run's main task ends with tasks left,
each is reported to the loop's exception handler ("Task 'kid' outlived the
task that created it (parent) and is still running (created at f.ny:12)");
`Runner.orphans` lists the reports (`_OrphanReport`: name, why, created_at,
parent, coro); "raise" cancels them and raises `OrphanedTasksError` (unless
main itself failed). TaskGroup children never trigger it (the group awaits
them). Untracked loops pay nothing.

### Engine changes (all marked "round 82")
- `src/NyConc.cpp`: `Loop` gains `handle`, `steps`, `stop_at`,
  `since_poll`, `stopping`, `prune_at`; `LoopObj`; `Task` gains `ephemeral`,
  `has_cancel_msg`/`cancel_msg` (before it starts), `coro_id`; `ThreadRec`
  gains `has_cancel_msg`/`cancel_msg`; `Coro` gains `dropped`; `Awaitable`
  gains an absolute deadline (`has_at`/`at`) used by `run_call_later`.
  Builtins `async_loop_new/spawn/call/run/stop/close`,
  `async_current_loop`, `async_current_task_user` (0 in a callback or the
  loop's own tasks: `current_task()` is None there), `async_create_task_eager`,
  `async_task_detach` (a task nothing will ask about any more - an asyncio
  Task object that was collected, a transport's reader - is freed when it
  has finished; awaiting a coroutine whose freed task ran it is "cannot
  reuse already awaited coroutine"); `task_cancel(h, msg)`. `grant()` counts steps, frees finished ephemeral
  tasks and prunes a persistent loop's task list as it doubles (engine
  values released with the GIL held); `run_loop_until` polls the reactor
  without waiting every 32 steps while tasks stay ready (a `while not done:
  await sleep(0)` waiting for a socket starved it); `loop_poll_io(no_wait)`.
  `task_entry` lets go of a finished task's coroutine function and
  arguments (and of the coroutine record when its object is already gone -
  a coroutine spawned and dropped at once kept everything it was called
  with forever). `item_of` keeps the coroutine an `__await__` made alive
  with the item (a gather of asyncio Futures returned handle numbers: the
  coroutines were collected before the gather ran them).
- `src/builtins/os_proc.cpp`: `os_proc_fds(pid)`; registered in
  `include/NythonExecutor.hpp`'s builtin list (the VM reaches it through the
  bridge).
- `src/VMConc.cpp` `raise_in_vm`: a typed runtime error is raised through
  `raise_native_exception`, so it has the arguments its message stands for
  (an OSError's errno/strerror - `signal.signal(SIGKILL, f)` gave the VM an
  OSError without errno).
- `include/VirtualMachine.hpp` compiler: `break`/`continue` inside except
  clauses of the innermost loop delete those clauses' hidden exception
  variables (`release_loop_excs`, `LoopCtx::exc_base`) as the clause's end
  does. Kept, the exception stayed "being handled": every later exception
  got it as `__context__`, an endless chain (an accept loop leaked ~12 KB
  per connection).
- `src/NyGC.cpp`, `src/VMGC.cpp` `collect_due`: the heap (mallinfo2) is
  sampled at most every 4 ms and never more than ~5% of the time. It ran at
  every safe point with work - each coroutine object's `__del__` is one -
  and mallinfo2 walks the free lists: 2000 tasks awaiting a helper
  coroutine took 7 s (interpreter) / 2.7 s (VM) instead of 0.5 / 0.4 s; the
  VM's stream echo benchmark went from 44 s to 0.8 s.

### Measured (this container, under load from other builds; interpreter / VM / CPython 3.11)
| | interpreter | VM | CPython |
|---|---|---|---|
| 10000 call_soon callbacks | 0.49 s | 0.31 s | 0.03 s |
| 2000 protocol echo round trips | 0.23 s | 0.19 s | 0.22 s |
| 2000 stream echo round trips | 2.3 s | 0.90 s | 0.13 s |
| gather of 2000 tasks (sleep(0) each) | 0.33 s | 0.19 s | 0.03 s |
| 1000 start_server/open_connection round trips | 5.4 s | 2.9 s | - |
Memory is flat across thousands of connections through `start_server` on
both engines (before the fixes above: +54 KB (interpreter) / +70 KB (VM)
of RSS per connection). `import asyncio` takes ~0.14 s on the interpreter
(a 5000-line module and its 15 submodules; lib/subprocess is loaded with
the first child).

### Not done / found
- `shutdown_asyncgens()` closes nothing (no `sys.set_asyncgen_hooks`);
  "Task exception was never retrieved" is not logged; loop.sendfile,
  sock_sendfile, connect_read_pipe/connect_write_pipe, child watchers and
  the Proactor loop are not provided.
- time.sleep (and every blocking call) in a task or a callback parks it
  instead of blocking the loop (Nython's colorless I/O) - a CPU-bound
  callback is what debug mode reports as slow.
- The runtime's handles for events, semaphores and queues (asyncio.Event,
  Lock, Queue, each Future while awaited) are never freed (pre-existing:
  no release native); tasks that `gather` makes from coroutines stay in the
  runtime's table (Task objects detach theirs when they are collected).
- Interpreter: a `while` loop whose except clause `continue`s keeps the
  last 256 raised exceptions (the exception ring, bounded) - not a leak,
  but their frames stay alive until the ring turns over.
- A TaskGroup with one failing child still raises the error itself rather
  than an ExceptionGroup (vm_audit67 pins the old behaviour).

## 0u3. Round 82, part A — the interpreter's remaining costs (vm_audit103, `tools/bench/`)

Round 81 part B's "Not done" list: Python exceptions on the interpreter
were C++ throws, startup was ~0.4G instructions (mostly the parser
copying `Token`s), and `for a, b in enumerate(xs)` built and unpacked a
tuple per step. All three are done, with no behaviour change where the
old behaviour was Python's - the sweep, `ide_e2e`, vm_audit100 (and with
`NY_ASTSPEC=0`) are the oracle - and two places where it was not
(below, "Found and fixed"). `examples/vm_audit103.ny` (43 checks; the
interpreter, `NY_ASTSPEC=0`, the VM and python3) runs every new path and
its fallback.

### Benchmarks
`tools/bench/`, round 81 (eab9350) -> now. **Instructions** are
callgrind's counts (they do not move with the machine's load): the timed
work is the whole run minus the same file run without its final `main()`
call (startup, parsing, the module's setup), which is shown separately.

| benchmark | interpreter, work: r81 | now | | VM, work: r81 | now | | setup, interpreter | setup, VM |
|---|---|---|---|---|---|---|---|---|
| closures | 4.294G | 4.329G | 0.992x | 2.957G | 2.955G | 1.001x | 526M -> 206M | 893M -> 228M |
| deltablue | 4.368G | 4.376G | 0.998x | 3.130G | 3.132G | 0.999x | 604M -> 232M | 969M -> 252M |
| dict_str | 1.851G | 1.862G | 0.994x | 1.405G | 1.406G | 0.999x | 624M -> 236M | 989M -> 256M |
| exceptions | 4.369G | 0.943G | 4.631x | 1.113G | 1.116G | 0.998x | 525M -> 206M | 892M -> 227M |
| fannkuch | 8.102G | 8.113G | 0.999x | 3.909G | 3.911G | 0.999x | 522M -> 205M | 887M -> 226M |
| fib | 1.985G | 2.032G | 0.977x | 1.251G | 1.251G | 1.000x | 516M -> 203M | 881M -> 225M |
| generators | 3.213G | 3.267G | 0.984x | 3.300G | 3.300G | 1.000x | 525M -> 206M | 891M -> 227M |
| nbody | 2.923G | 2.943G | 0.993x | 2.419G | 2.422G | 0.999x | 537M -> 209M | 903M -> 231M |
| raytrace | 3.890G | 3.846G | 1.012x | 2.578G | 2.579G | 1.000x | 554M -> 214M | 922M -> 237M |
| richards | 4.448G | 4.497G | 0.989x | 3.222G | 3.223G | 1.000x | 566M -> 217M | 933M -> 240M |
| spectral_norm | 4.109G | 3.283G | 1.252x | 3.103G | 2.679G | 1.158x | 522M -> 205M | 888M -> 226M |
| geomean | | | 1.166x | | | 1.013x | | |

So the work itself costs what it did, except where this round removed
it: the exceptions benchmark (4.6x fewer instructions), spectral_norm
(1.25x on the interpreter, 1.16x on the VM: `for i, x in enumerate(...)`
rows bound without a tuple / unpacked by the strict `UNPACK_SEQ`) and
raytrace (1%). Elsewhere the interpreter executes 0.1-2.3% more: the
pending-flag checks (`raisedBy`: two byte compares per binary operation,
one per argument, per `if` test, per `return`), which pay for the 4.6x.
Every run is 0.31-0.39G instructions cheaper on the interpreter and
0.65-0.73G on the VM before its work starts.

**Time** (`python3 tools/bench/run.py -n 7 --python --base ...`: the
benchmark's own `bench_time`, min of 7 runs interleaved with the
baseline; a 4-vCPU Xeon VM, load 0.5-3 - right after a reboot, before the
other agents' builds started. The VM's work is instruction for
instruction round 81's (above), so its column - 0.95x to 1.00x but for
spectral_norm - is the size of this machine's noise and layout effects):

| benchmark | interpreter r81 | now | | VM r81 | now | | python3 | interpreter / python3 |
|---|---|---|---|---|---|---|---|---|
| closures | 0.447 | 0.449 | 1.00x | 0.299 | 0.301 | 0.99x | 0.0469 | 9.6x |
| deltablue | 0.596 | 0.675 | 0.88x | 0.383 | 0.383 | 1.00x | 0.0229 | 29.5x |
| dict_str | 0.223 | 0.223 | 1.00x | 0.178 | 0.188 | 0.95x | 0.0231 | 9.7x |
| exceptions | 0.465 | 0.139 | 3.35x | 0.115 | 0.121 | 0.95x | 0.0049 | 28.4x |
| fannkuch | 0.845 | 0.853 | 0.99x | 0.426 | 0.427 | 1.00x | 0.0387 | 22.0x |
| fib | 0.212 | 0.219 | 0.97x | 0.108 | 0.113 | 0.96x | 0.0171 | 12.8x |
| generators | 0.372 | 0.385 | 0.97x | 0.341 | 0.351 | 0.97x | 0.0271 | 14.2x |
| nbody | 0.270 | 0.273 | 0.99x | 0.224 | 0.226 | 0.99x | 0.0164 | 16.6x |
| raytrace | 0.512 | 0.520 | 0.98x | 0.287 | 0.300 | 0.96x | 0.0316 | 16.5x |
| richards | 0.560 | 0.555 | 1.01x | 0.346 | 0.365 | 0.95x | 0.0487 | 11.4x |
| spectral_norm | 0.490 | 0.395 | 1.24x | 0.317 | 0.268 | 1.18x | 0.0330 | 12.0x |
| geomean | | | 1.12x | | | 0.99x | | |

(deltablue's 0.88x is one fast baseline run: the medians are 0.701 s and
0.699 s.) Under the other agents' load (8-9) the same runs gave the
interpreter 0.92x-1.15x on these benchmarks and the VM 0.86x-1.11x - the
measurement, not the code.

**Time follows instructions only loosely, and why was measured as far
as this machine allows** (it exposes no performance counters). Under
cachegrind fib executes 9% fewer instructions than round 81 (startup
included), yet its L1 instruction-cache misses went from 2.9M to
4.2M-9.7M: the interpreter's hot path is ~305 64-byte lines (19 KB, the
same before and after) spread over very large functions (`evalCall` 26 KB,
`lookupName` 40 KB), and how many of them meet in one of the 64 sets of a
32 KB 8-way L1i is decided by where the linker puts each function - the
same objects linked in four other orders gave 4.2M, 6.1M, 7.9M and 9.7M.
Timed the same way at load 1-3, five link orders of round 81's objects
ran fib's work in 0.226-0.240 s and five of this round's (before its last
trims of the checks) in 0.239-0.251 s (nbody
0.281-0.296 vs 0.300-0.308, richards 0.603-0.651 vs 0.607-0.675): the
layout alone moves these benchmarks by ~5%, and what remained then (~3-6%
on fib and nbody, within the noise on richards) was more than the
instructions explained - the GCC inlining decisions moved with the new
code (`evalSubscript` is a call now, it was inlined into `evalNode`). The
trims that followed (`raisedBy`, the NRVO fixes, `flow()` through a TLS
pointer) brought the final build to the table above. This is
the effect Mytkowicz et al. measured ("Producing wrong data without doing
anything obviously wrong!", ASPLOS 2009) and Stabilizer (Curtsinger &
Berger, ASPLOS 2013) randomizes away; the cure is layout -
profile-guided hot/cold splitting (`-fprofile-use`) or a post-link
optimizer (BOLT) - not done here: it changes the build on every platform.
Whole runs (`--wall`, what `time nython bm_x.ny` sees) are faster on both
engines: geomean 1.22x (interpreter) and 1.30x (VM) over the 11 whole
runs; exceptions 3.05x / 1.42x, fib 1.15x / 1.50x, spectral_norm 1.22x /
1.38x.

### Exceptions without C++ throws (the design and where it comes from)
The literature has two models for exceptional control flow in an
interpreter: table-driven unwinding (C++'s "zero-cost" exceptions,
CPython 3.11's exception table) and an error indicator returned by value
(CPython up to 3.10: every C function returns NULL with `PyErr_Occurred()`
set, and every caller checks). The interpreter used the first for Python
exceptions - a `std::string` thrown and caught by `evalTry` - and paid
for it: `__gxx_personality_v0` scans the call-site table of every frame
it passes, and the evaluator's functions are very large (65% of the
exceptions benchmark). Round 80 gave the VM the second model
(`fast_exc_pending`); this round gives it to the interpreter, **confined
by a permission** so the old model stays the fallback everywhere the
second cannot be proven safe:

- `FlowState::pending == kPendExc` (4) with the exception string in
  `FlowState::exc` - the string a throw would carry, so everything that
  reads it (`excTypeOf`, `excInstanceOf`, `tbSee`/`tbCaught`, the clause
  matching) is unchanged. `pendExc` sets it, `takeExc` takes it.
- **Statements** may leave by it where a `return` may: `canPend(ctx)` is
  `fast_ctx == ctx` (round 74's rule: every construct between a function's
  statement and its `evalBody` checks the flag; `SuspendFast` constructs
  turn it off). `evalRaise` (via `raiseFlow`) and `evalAssert` use it.
- **Expressions** may raise by it only when the evaluator asking checks
  the flag right after: `evalP(n)` is `evalNode(n, ctx, pend=true)`, and
  `pend` is handed to the evaluators that use it - `evalCall` (its fast
  paths: a plain def, the method inline cache, the general def path, a
  builtin's error caught at the call), `evalBinary` (and a division by
  zero), `evalUnary`, `evalSubscript` (a missing key / index:
  `getItem(..., exc_out)`, `keyErrorFlow`), `evalAttribute`,
  `evalAssignment`/`evalAugAssignment`/`evalVarDecl`/`evalIf`/`evalWhile`'s
  test/`evalReturn`. Any other evaluator gets `pend == false` and its
  children throw as before - so a pending exception never reaches code
  that would go on with the value. An evaluator given `pend` returns None
  whenever it leaves an exception pending, so its caller reads the flag
  only for a None result (`raisedBy(v)`: CPython's "NULL, then
  `PyErr_Occurred()`") - one byte compare on the value just returned in
  the common case, the thread-local flag only for a None.
- **A frame** records the exception leaving it (`tbUnwind`, in
  `evalBody`) and hands it on by the flag only when its call site asked
  (`runFunctionBody(fn, fc, pend)`); otherwise it is thrown there - so
  builtins calling back into Nython code (`sorted(key=)`, `map`), the
  prelude's callbacks, threads and anything else native see the C++ throw
  they always did. A generator's body (`nygen::run_body`) throws it at the
  coroutine's base; `exec`'s code and `lang_eval` run under `SuspendFast`
  (they run statements in the caller's scope, and must not use its
  flags).
- `evalTry` takes an exception that arrives by the flag as its catch
  clauses take a thrown one (same `tbSee`, `pyEvException`, matching,
  `tbCaught`, `handling_exc_`, `UnbindAs`, `tbHandlerExit`); one that goes
  on (no clause matches, a handler or the else clause raised) goes by the
  flag when the statement may (a thrown one too: the rest of its way up
  is then throw-free). `evalWith` likewise (`__exit__` with the exception,
  suppression). Loops, `if`, blocks and `nygen::for_loop` leave on it as
  on a pending return.
- **Rules**: an evaluator given `pend` checks `raisedBy` after each child
  it evaluated with it and returns (None) before anything else; anything
  that runs user code while a flag is set takes it out first and puts it
  back; code that evaluates statements in a caller's scope runs under
  `SuspendFast`. Every `pendExc` site is marked `round 82`.

What remains in the exceptions benchmark is what Python does too: the
exception objects, their traceback entries (`makeTbValue`) and frame
objects, `__init__` calls. Two costs on that path went as well:
`classDerivesFrom` (every except clause tested, four questions per
exception made) walked `class_by_name` by string - memoized while no
class name is bound anew (`class_names_ver_`); `rememberRaised` /
`excInstanceOf` used string streams.

### Startup
`-c pass` under callgrind: interpreter **399M -> 159M instructions (2.51x)**,
VM **769M -> 181M (4.24x)**; wall time (min of 30 runs, interleaved)
interpreter 90 -> 54 ms, VM 170 -> 60 ms. A benchmark file up to its
`main()` (startup, its parse, `import time`, module-level code):
interpreter 516-624M -> 203-236M, VM 881-989M -> 225-256M.
- The parser copied the current token - two strings - at every
  `token()`, `see()`, `have()` (`Parser::token()` and the lexer's
  accessors returned `Token` by value through virtual calls): ~60% of the
  interpreter's startup. They return `const Token&` now (`IParser`,
  `ILexer`, `Lexer`, `Parser`; `Parser` and `Lexer` are `final`, so the
  calls are direct); a mangled identifier (`__x` in a class) is a copy
  kept in `Parser::mangled_` (a deque: its address stays).
- The lexer copied a `TokenDef` (a string) per keyword for every
  identifier it read (`for (auto kw : Keywords())`), built a `Token` per
  token in `reset_token`, and `tokenize()` copied the token vector twice
  (`optimize` by value, the return value).
- The VM's startup parsed the prelude twice (its own and its builtin
  bridge's interpreter): `VirtualMachine::shared_prelude_ast()` parses it
  once per process; neither engine changes the AST (the interpreter
  rewrites only a class statement's expression bases, which the prelude
  has none of).
- `hasYield` (once per def) ran its chain of `dynamic_cast`s for leaves.

### Loop targets
`for i, x in enumerate(xs)` / `for a, b, c in zip(...)`: when the targets
are a flat list of names as long as each row, `nygen::for_loop` binds
them from the iterator's parts (`machine_next_parts`, the same guard and
finish as `machine_next`) - no tuple per step; enumerate's index is a
machine int incremented in place. The dict paths (`d.items()`) already
made no pair. The rest falls back to the tuple, and every loop kind binds
through `bindForItem`: a list or tuple item bound in place, anything else
iterated (`forUnpackParts`), the count checked.

### Found and fixed
- **A `finally` that returns, breaks or continues while an exception
  propagates** re-raised the exception after it on the interpreter
  (round 81's fast `try`: `def f(): try: raise E finally: return 1` raised
  E); it replaces the exception now, as in Python (`run_finally_exc`
  reports it; `tbFinally` keeps the new record).
- **A for statement's targets were not unpacked as Python's**: the
  interpreter bound missing values to None, dropped extra ones and bound
  only the first target of a string item; the VM indexed the item
  through a temporary (missing values an IndexError, an object with
  `__iter__` "not subscriptable"). Both engines now raise CPython's
  "too many values to unpack (expected 2)" / "not enough values to unpack
  (expected 3, got 2)" / "cannot unpack non-iterable int object" and
  iterate strings, objects and sets (VM: `UNPACK_SEQ` with
  `kUnpackStrict`, quickened as before). Comprehension targets are as
  they were on both engines (lax: see Not done).
- **VM: `break`/`continue` inside a `finally` body** left the try's state
  on the operand stack, which the loop's `FOR_ITER` then read as its
  iterator: the loop ended (`for i in range(3): try: ... finally:
  continue` ran once). `Compiler::drop_fin_states` pops it first.

### Engine changes (file, function: what)
Every change is marked `round 82` in the source.

- `include/NythonExecutor.hpp` (the interpreter):
  - `FlowState`: `pending == kPendExc` (4) and the string `exc`;
    `pendExc`, `takeExc`, `canPend`, `isLoopFlow`, `pendingSet`,
    `raisedBy(v)` (the flag read only when `v` is None: every evaluator
    given `pend` returns None whenever it leaves an exception pending);
    `NY_LOOP_FLOW` leaves on an exception as on a return.
  - `evalNode(node, ctx, pend = false)` hands `pend` to `evalCall`,
    `evalBinary`, `evalUnary`, `evalSubscript`, `evalAttribute`,
    `evalAssignment`, `evalAugAssignment`, `evalVarDecl`, `evalIf` (each
    gained a `bool pend = false` parameter, evaluates its children with
    `evalNode(child, ctx, pend)` and checks `raisedBy` after each);
    `evalP(n, ctx)` is `evalNode(n, ctx, true)`. `evalVarDecl` and
    `evalAssignment` return their one named result on that path too
    (NRVO: an early `return NONE_VALUE` made every declaration copy its
    value).
  - `evalStatements`: its statements evaluated with `pend` when
    `fast_ctx == ctx`; `evalWhile`: its test likewise; `evalReturn`: its
    value likewise (one named result, so it is still built in place).
  - `evalRaise` (now over `raiseFlow`, which returns what it used to
    throw) and `evalAssert`: by the flag when `canPend`.
  - `evalTry`: an exception from the body, the else clause or a handler by
    the flag; an unmatched / re-raised one goes on by the flag
    (`may_pend`); `run_finally_exc` returns whether the finally body's own
    flow replaced the exception (then it is dropped, as in Python).
    `tbFinally`: keeps the new record when the body left by a flag.
  - `evalWith`: an exception by the flag runs `__exit__` as the catch
    clause does; an unsuppressed one goes on by the flag.
  - `evalBody(body, fc, pend = false)`: an exception leaving by the flag
    is recorded (`tbUnwind`) and handed on by the flag or thrown, marked
    `tbUnwound()` so `runFunctionBody`/`runBodyHooked` do not record it
    twice. `runFunctionBody(fn, fc, pend = false)`: a thrown exception
    caught there goes on by the flag when `pend`. `runBodyHooked`.
  - `evalCall`: the receiver and the arguments of the two fast paths
    evaluated with `pend`; `pend` passed to `methodFast`,
    `runFunctionBody` (plain def, method cache, general def path); a
    builtin's error caught at the call when `pend`.
  - `getItem(obj, idx, ctx, exc_out = nullptr)`: a list/tuple IndexError
    or dict KeyError put in `exc_out`; `keyErrorFlow` (what
    `raiseKeyError` throws); `evalAttribute`'s missing attribute;
    `zeroDivMessage` (nypy::arith's messages; `evalBinary` asks only when
    the divisor is zero).
  - `runSnippetFrame` (exec/eval) runs under `SuspendFast`.
  - `bindForItem`, `forUnpackParts`, `forUnpackCount`, `seqAt`: a for
    statement's targets unpacked as Python does (`bindUnpacked` and
    evalFor's three binding sites use them).
  - `classDerivesFrom` memoized (`derives_memo_`, `class_names_ver_`
    bumped where `class_by_name` is written and in `evalClassDecl`'s bases
    rewrite), the walk in `classDerivesFromWalk`.
  - `rememberRaised`, `excInstanceOf`: no string streams.
  - `loadPrelude`: `VirtualMachine::shared_prelude_ast()`.
  - `hasYield`: leaves answer at once.
  - `flow()`: the per-thread `FlowState` reached through a
    constant-initialized pointer (`t_flow_`, set by `flowInit()`), so a use
    is a TLS load and a test - the function-local `thread_local` put its
    guard and constructor at every inlined use and kept `pendingSet` out of
    line (2.7M calls in fib); `pendingSet` always inlined.
  - `->token()` copies replaced by `->tok()` (34 sites; `tbRecord`,
    `frameWhere`, `pyEvException`, ...).
  - `resumeInto`'s while: leaves on an exception as on a return.
- `src/NyGen.cpp`: `Saved::exc`; `run_body` throws a body's exception that
  came by the flag; `resume_function` keeps the resumer's and the
  generator's pending exception string (only when one is pending);
  `for_loop` leaves on an exception as on a return, binds through
  `bindForItem`, and binds enumerate/zip rows from their parts
  (`native_next_parts`, `machine_next_parts`); `enum_advance` (a machine
  int incremented in place).
- `include/VirtualMachine.hpp` (the VM): `kUnpackCount`/`kUnpackStrict`;
  `Compiler::visit_for` unpacks a for statement's targets with `UNPACK_SEQ
  n|kUnpackStrict` (it indexed a temporary); `UNPACK_SEQ`'s strict form
  (Python's unpacking) and the count mask in its quickening
  (`UNPACK_SEQ_LIST`); `Compiler::fin_body_loops_`/`drop_fin_states` (a
  break/continue in a finally body pops the try's state; `SavedBody::fbl`
  saves it per function); `shared_prelude_ast()` used by `load_prelude`.
- Parser and lexer (both engines): `IParser`/`ILexer`/`Parser`/`Lexer`
  token accessors return `const Token&`; `Parser::mg` keeps mangled copies
  in `mangled_`; `Parser::see` reads the type in place; `Parser` and
  `Lexer` are `final`; `Lexer::curr()` inline (`curr_edge()` out of line);
  `Lexer::tokenize()` returns `const std::vector<Token>&` and moves into
  `optimize`; `reset_token` in place; the keyword/operator/delimiter
  tables walked by reference.
- `src/builtins/lang.cpp`: `lang_eval` runs under `SuspendFast`.
- `src/main.cpp`: `run_program`'s unused copy of the token vector (`auto tokens = lexer->tokenize()`) dropped.

### Memory
Peak RSS (MB, Linux, one run each), round 81 -> now:

| | interpreter | VM |
|---|---|---|
| `-c pass` | 24.5 -> 21.1 | 30.4 -> 21.9 |
| fib / nbody / richards | 24.5 / 24.9 / 26.0 -> 21.6 / 22.1 / 22.5 | 30.2 / 30.6 / 31.3 -> 24.3 / 24.8 / 25.4 |
| closures / deltablue | 26.6 / 29.2 -> 26.7 / 28.9 | 34.3 / 37.6 -> 30.7 / 34.5 |
| dict_str / exceptions | 47.8 / 36.5 -> 48.0 / 36.8 | 56.2 / 30.7 -> 53.2 / 25.9 |

The parse no longer makes transient copies of every token (-3 to -4 MB
on most runs), and the VM keeps one prelude AST instead of two (-5 to
-6 MB). The pending exception adds one `std::string` to the per-thread
`FlowState`. `ide_memprobe --check`: idle 0.01 KB/frame, hover 0.05,
typing 3.15 KB/key, scroll/split/live/profile 0.00-0.03 (all under their
ceilings).

### Windows
`tools/cross_windows.sh build` and `ARCH=i686 tools/cross_windows.sh
build` (the units, flags and libraries of `nython.cbp`) build the final
source; `pe_unwind_check` passes on the 64-bit `nython.exe`; the one
warning is the existing `K_FROZENSET` switch in `vm_key_value`.
Under Wine: vm_audit103 43/43 and vm_audit100 on both engines, 64-bit
and 32-bit.

`tools/bench/run.py --engine interp --bin build-win/nywin --base <round
81's build> -n 3` (the interpreter, `bench_time`, min of 3 interleaved
runs under Wine on the same machine at load ~7, so +-10%):

| | closures | deltablue | dict_str | exceptions | fannkuch | fib | generators | nbody | raytrace | richards | spectral_norm | geomean |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 64-bit r81 (s) | 0.954 | 1.188 | 0.367 | 0.838 | 1.488 | 0.581 | 0.930 | 0.479 | 0.959 | 1.316 | 0.783 | |
| 64-bit now (s) | 0.920 | 1.203 | 0.406 | 0.305 | 1.373 | 0.535 | 0.930 | 0.473 | 0.974 | 1.266 | 0.619 | |
| | 1.04x | 0.99x | 0.90x | **2.75x** | 1.08x | 1.09x | 1.00x | 1.01x | 0.98x | 1.04x | 1.27x | 1.13x |
| 32-bit r81 (s) | 0.989 | 1.359 | 0.386 | 0.698 | 1.520 | 0.559 | 0.929 | 0.515 | 1.021 | 1.478 | 0.865 | |
| 32-bit now (s) | 0.966 | 1.168 | 0.422 | 0.259 | 1.464 | 0.587 | 0.911 | 0.568 | 1.015 | 1.334 | 0.690 | |
| | 1.02x | 1.16x | 0.92x | **2.70x** | 1.04x | 0.95x | 1.02x | 0.91x | 1.01x | 1.11x | 1.25x | 1.13x |

### Not done / found
- Comprehension targets (`[x for a, b in pairs]`) still pad missing
  values with None and drop extra ones, on both engines (`bindTarget`,
  the VM's lax `UNPACK_SEQ`).
- `sys.exc_info()` and a bare `raise` inside a `finally` body run while an
  exception propagates do not see that exception on either engine
  (CPython: they do), and on the interpreter an exception raised there
  gets no `__context__` (the VM sets it).
- Exceptions raised by native code below a non-`pend` call site (a
  builtin's own callback, a generator's next() from a builtin) are still
  thrown; a traceback entry still makes its frame object eagerly
  (`tbRecord` → `frameObject`): the largest part of what the exceptions
  benchmark costs now, with the exception objects themselves.
- **The flag checks are not free**: the timed work of the call-heavy
  benchmarks is 0.1-2.3% more instructions (a check is a byte compare on
  the value returned plus the `pend` argument), and the final build runs
  them at 0.97x-1.01x of round 81 on a quiet machine (fib 0.97x,
  generators 0.97x, raytrace 0.98x). Not recovered here; the next step is
  layout (`-fprofile-use` hot/cold splitting, BOLT), which the spread over
  link orders (Benchmarks above) says is worth ~5% by itself.
- The remaining per-call costs (fib, richards, generators): `Value`
  copies (a bigint and a long double in every one), the per-call
  `Context` (a name string, a map, GC tracking), name lookups before the
  cached depth.

## 0t4. Round 81, follow-ups — what the round's agents found (vm_audit102)

`examples/vm_audit102.ny` (51 checks) passes on the interpreter, with
`NY_ASTSPEC=0`, on the VM and under python3. Every item was reproduced
first (`/tmp`-style probes compared with python3), then fixed:

- **A lambda put in a class binds as a def does** (interpreter): `C.m =
  lambda self: 1; f = o.m; f()` raised "missing 1 required positional
  argument: 'self'" - `makeBoundMethod` bound only FUNCTION nodes. It now
  binds a lambda too, and `bindLambdaParams` puts a bound lambda's instance
  first (its defaults are read under the lambda itself). `o.m()` always
  worked; a lambda stored on an instance is still not bound.
- **`del C.m` removes the method** (interpreter): the call path's
  class-body scans (`callMethod`: the class's own body, the MRO bases, the
  parent chain, the legacy super path) found the deleted def again. They
  now skip a member `del` removed (`memberDeleted`, over round 77's
  `class_vars_deleted_`); deleting an override reveals the base's method,
  deleting the base's raises AttributeError, assigning it again works.
- **`list.pop` takes an integer index** (both engines): `[1, 2].pop("x")`
  gave None on the interpreter (it fell through to the old dict-style pop)
  and popped 2 on the VM (the older pop ignored a non-int). Now CPython's
  "'str' object cannot be interpreted as an integer"; `__index__` objects,
  bools and int subclasses work; more than one argument is a TypeError.
- **UnboundLocalError** (both engines): reading a name a function binds
  (an assignment, `+=`, a loop/except/with target, a def, an import, a
  parameter - not declared global/nonlocal) while it is unbound raised
  `NameError: name 'x' is not defined`. The static scope pass
  (`src/NyScope.cpp`) now records each function's reads and flags those of
  names it binds (`VariableNode::local_read`); the interpreter's
  `evalVariable` and the VM's `LOAD_NAME` (through `VMCode::local_reads`)
  raise CPython's `UnboundLocalError: cannot access local variable 'x'
  where it is not associated with a value` instead - looked at only where
  a NameError would be raised, so no hot path pays. Nython's scope ruling
  is untouched: a function that assigns `x` still reads a global `x`
  before its own assignment (CPython raises there; Nython rebinds the
  nearest binding, round 75), so the error appears only when no binding
  exists anywhere.
- **A set iterator notices the set changing size** (both engines): `it =
  iter(s); next(it); s.add(9); next(it)` went on over a copy. The VM's
  `set_iter` (a native generator like round 78's `dict_iter`) and the
  interpreter's set cursor (`Cursor::VEC` with the set and its size) raise
  "Set changed size during iteration", again at every later step, as
  CPython's setiterator; part A had done the same for loops.
- **A package's `__spec__` on Windows**: `submodule_search_locations` was
  rebuilt from `__file__` (`lib/collections`) while round 80 gives
  `__path__` native separators (`lib\collections`), so vm_audit99's
  "a package's __spec__" failed under Wine. The spec now uses the module's
  `__path__`, as CPython's `module.__path__` is the spec's list.
- Verified: vm_audit102 51/51 on both engines, with `NY_ASTSPEC=0` and
  under python3; vm_audit99 125/125 on both engines; `python3
  tools/sweep.py` 431 runs, 0 not ok.


### Platforms (round 81 with its follow-ups, eab9350; AArch64 at ae70e3b)
- **Windows 64-bit under Wine** (`tools/cross_windows.sh build`, then
  `python3 tools/sweep.py --bin build-win/nywin`): the full sweep, 431
  runs, 0 not ok; `pe_unwind_check` clean.
- **Windows 32-bit under Wine** (`ARCH=i686`): vm_audit99 (3000 frames
  deep under `setrecursionlimit(5000)` included), 100, 101, 102, 98, 95,
  91, 88, 56 pass on both engines.
- **AArch64 under qemu-user** (`make cli BUILD=build-arm64
  CXX=aarch64-linux-gnu-g++ -j1`): vm_audit100, 102, 95, 91, 88, 56, 49
  pass on both engines. vm_audit99, 98 and 105 stop at their first child
  process: they run `sys.executable`, an AArch64 binary this container can
  only start through qemu (no binfmt_misc), so the shell gets garbage - an
  environment limit, not a failure of the code under test (round 80 noted
  the same for vm_audit98).

## 0t3. Round 81, part C — live debugging and the Profile view (vm_audit101, e2e `live`/`profile`)

`examples/vm_audit101.ny` (125 checks, Nython-only) passes on both engines:
it starts real programs with `nython [--vm] --debug-port N`, drives the
server with a DAP client written in the test, and reads real `-m cProfile`
dumps. `tools/ide_e2e.py` gained `live` (37 checks, the program's stdin
through the Output panel's input line among them) and `profile` (15) - the
whole suite 442 passed, 0 failed;
`tools/ide_memprobe.py` gained `live` and `profile` probes (0 KB/event).

### The debug server (`lib/ide_debugserver.ny`, `DebugServer(bdb.Bdb)`)
- `nython --debug-port N file.ny args` (main.cpp: rewritten to `-m
  ide_debugserver --port N file.ny args`; `--debug-port 0` picks a port and
  prints it on stderr; `--vm` works) listens on 127.0.0.1, waits for a
  client, runs the program once `configurationDone` arrives. `-m
  ide_debugserver --connect H:P` calls a listening client; `--ring N`,
  `--no-ring`, `--stop-on-entry`.
- Wire: DAP's `Content-Length` framing and message shapes. Requests:
  initialize (capabilities incl. `supportsStepBack`, filters raised /
  uncaught), launch/attach (stopOnEntry), setBreakpoints (moved to the next
  statement and verified with `text_defuse`; condition, hitCondition `5
  ==5 >5 >=5 <5 <=5 %5`, logMessage with `{expr}`), setExceptionBreakpoints,
  configurationDone, threads, continue, next, stepIn, stepOut, pause,
  stackTrace (paging), scopes (Locals, Globals), variables (children by
  reference, made when asked; start/count), evaluate (an expression; in the
  "repl" context a statement whose bindings reach the frame), setVariable
  (a local through PEP 667's f_locals, a module variable, a list item, a
  dict value, an attribute), exceptionInfo, source, stepBack,
  reverseContinue, disconnect/terminate, and Nython's `nython/history`,
  `nython/whyValue`, `nython/whyNot`, `nython/seek`, `nython/ping`. Events:
  initialized, process, stopped (entry/breakpoint/step/pause/exception),
  output (log points, condition errors, the uncaught traceback), exited,
  terminated.
- Threads: a socket thread reads; it answers initialize / setBreakpoints /
  pause / threads / disconnect itself and queues the rest for the program's
  thread, setting one attention flag the trace function tests per line -
  that is how a pause reaches a running loop. While paused the program's
  thread blocks on the queue and answers frame requests. The program's
  stdin/stdout/argv are untouched (checked in vm_audit101; the IDE's Run
  input line works under it).
- Exceptions: "raised" stops once per exception object where it is raised
  (StopIteration/GeneratorExit/SystemExit skipped); "uncaught" stops post
  mortem on the traceback's frames (their last locals), then the
  traceback is printed as Python's and the status is 1.
- Just my code: frames in `lib/` and the prelude are not traced (call
  events return None, as CPython allows); only the main thread is debugged.
- **The hot path** (`trace_dispatch`): file/function/depth come from the
  call event (`self._top`), the line and a fresh locals dict from one
  `_ny_frame_sync(frame)` (the native layer under f_lineno/f_locals; the
  property and the PEP 667 proxy cost ~25 µs a line on the interpreter),
  one bound method is returned for every event. Without the ring and with
  no breakpoint in the file and no step pending, a line costs the
  attention test, one dict lookup and one compare.
- **Engine gap found, worked around**: `frame.f_globals` and `globals()`
  are copies on both engines (CPython's are the live module dict): a write
  never reaches the program. The server writes module variables through
  the namespace it exec'd the program in (live - `exec(code, ns)` reads
  `ns`) and through the module object for imported modules
  (`_globals`/`_set_global`). (Part A of round 81 made `f_globals` and
  `globals()` live views of the module on both engines; the server's own
  route still works and was kept - vm_audit101 passes either way.)

### Step back and Why? on the live program (the innovation)
- Omniscient debugging (Lewis, "Debugging Backwards in Time", AADEBUG
  2003; Pothier, Tanter & Piquer, "Scalable Omniscient Debugging", OOPSLA
  2007 - TOD) records everything; here the trace function keeps only the
  last N statements (2000) in a ring buffer: per statement the call's
  (file, function, depth), the line, and the dict of that frame's
  variables `_ny_frame_sync` made. `history_lines()` renders them as the
  `--trace` JSON lines, and `lib/ide_debugger.ny`'s `DebugSession`
  (`load_lines`, new) replays them: stepBack / next / stepIn / stepOut /
  continue / reverseContinue move a cursor through the history (the stack
  rebuilt from depths, the recorded variables shown, evaluate limited to
  them, setVariable refused), forward steps reach "the present" where the
  live program waits, and continue from there goes on live; a breakpoint
  met while travelling stops there, the present included. `nython/whyValue`
  and `nython/whyNot` run round 79's dynamic slicer over the history.
- Approximated: only the last N statements (a write before them answers
  "was not set by a recorded statement"); a step's bindings are exact but
  an object they point to (a list, a dict, an instance) is rendered when
  the history is read, so a later mutation shows at earlier steps (the
  slicer still sees `xs.append(v)` as writing `xs` - text_defuse's static
  write set); renderings are short (8 items, 6 keys, `<Cls object>`).
- Cost, measured (tools: a 100,000-iteration loop in a function and a
  50,000-iteration one at module level, min of 3 interleaved runs, a busy
  4-core machine):

  | | plain | traced, `--no-ring` | traced + ring | ring per statement |
  |---|---|---|---|---|
  | interpreter, function | 201 ms | 4100 ms (20x) | 8866 ms (2.2x tracing) | +16 µs |
  | interpreter, module   | 85 ms  | 1986 ms (23x) | 4629 ms (2.3x) | +18 µs |
  | VM, function          | 18.5 ms | 1457 ms (79x) | 2963 ms (2.0x) | +5 µs |
  | VM, module            | 8.1 ms | 679 ms (84x)  | 2015 ms (3.0x) | +9 µs |

  Tracing is what any bdb-style live debugger pays (a Python-level trace
  function per line, as CPython's pdb before PEP 669); the ring about
  doubles it (a module frame's dict is a copy of all globals, hence the
  higher module cost). Before the hot-path rewrite the ring cost 4.4x
  tracing (rendering every variable per line).

### The IDE (`ide_live.ny`, `IDELive` between IDETools and NythonIDE)
- Run > Start Live Debugging (Alt+F5; also a button in Run and Debug):
  the program runs as `nython --debug-port N` with its output and input in
  the Output panel; `lib/ide_debugclient.ny`'s `LiveDebugClient` connects
  (retrying while the program starts) and is polled once per frame
  (`NythonIDE._tick` -> `_live_tick`). The same view, toolbar, keys and
  gutter breakpoints as record-and-replay: Continue/Pause (F5/F6), F10/F11/
  Shift+F11, Step Back (Ctrl+Shift+F11, through the server's history),
  Restart, Stop; VARIABLES is a tree (chevrons; children fetched by
  reference on first open; double-click or the context menu's Set Value
  sets one); WATCH and the Debug Console evaluate in the selected frame;
  CALL STACK selects a frame (its line and locals); "Raised Exceptions" /
  "Uncaught Exceptions" checkboxes; Why? (the "?" on a variable, the
  palette, the editor's context menu) is answered by the server and its
  rows travel through the history. Breakpoints edited during a session are
  sent at once (`brk_gen`).
- Run > Profile with cProfile (Flame Graph): `nython -m cProfile --stacks
  -o OUT file.ny`, then the PROFILE panel (`lib/ide_profile.ny`): the table
  (ncalls as calls/primitive, tottime, percall, cumtime, percall; click a
  heading to sort, again to flip), the selection's callers and callees, and
  an icicle flame graph (Gregg, CACM 2016) with a tooltip per bar; a click
  on a row, caller, callee or bar selects the function and opens its
  source. "Profile: Copy Folded Stacks" gives flamegraph.pl's input.
- **cProfile `--stacks` / `Profile(stacks=True)`** (Nython's addition):
  the profiler also keeps the calling context tree (Ammons, Ball & Larus,
  PLDI 1997) - one node per call path, one dict lookup per call - so the
  flame graph is exact. Without it the graph is derived from cProfile's
  caller->callee aggregates as gprof does (a callee's subtree under each
  caller scaled by that edge's share of its time; recursion folded), and
  says so. `dump_stats` appends the tree as a `{"cct": ...}` line;
  `pstats._load` skips it.

### Not done
- Data breakpoints, function breakpoints, goto/restartFrame (frames cannot
  jump), completions, loadedSources; threads other than the main one are
  not debugged; pause waits for the next line a user frame runs (not
  inside time.sleep or input()); live debugging runs the interpreter (the
  server itself works on `--vm`, as vm_audit101 shows, but the IDE has no
  switch for it); the IDE's flame graph does not zoom.
- `f_globals` / `globals()` are not live on either engine (worked around
  in the server, not fixed). **Fixed by part A** (live views on both
  engines); the server's workaround still works and was kept.

### Merged onto round 80 (2eb1221)
- No conflicts. The agent's sweep had one failure, `vm_audit66 --vm` "lock
  wait interrupted", under load: the test sent SIGINT a fixed 0.6 s after
  starting each child, and a child still importing `lib/thread.ny` got it
  before its `try` (the interrupt went uncaught). **The children now write a
  ready file just inside their `try`, and the signal waits for it** (plus
  0.3 s to be inside the wait). vm_audit66 then passed on both engines on a
  machine loaded by two agents' builds.
- Verified after merging: the sweep 425 runs, 0 not ok; vm_audit101 125,
  66, 44, 91, 92 on both engines; `ide_e2e` 442/442 (`live` and `profile`
  included); `ide_lint`, `ny_classcheck`, `cbp.py check` clean;
  `ide_memprobe --check` passes (0 KB kept, the `live`/`profile` probes too)
  - its first run timed out in the `scroll` probe waiting for a frame at a
  load average of 13.5 on 4 cores (two agents building); the rerun at the
  same load passed. Not investigated further.

## 0t2. Round 81, part B — a self-optimizing AST interpreter (vm_audit100, `tools/bench/`)

The tree-walking interpreter (`include/NythonExecutor.hpp`, the default
engine) is **3.09x faster** (geometric mean of the 11 benchmarks of
`tools/bench/`, Linux; 2.87x x64 and 2.69x i686 under Wine) with no behaviour
change: the sweep and `ide_e2e` are the oracle, and `examples/vm_audit100.ny`
(114 checks; the interpreter, the interpreter with `NY_ASTSPEC=0`, the VM and
python3) runs every specialized path long enough for it to specialize and
then changes what it saw - a global rebound to another type or shadowed
later, a builtin shadowed, a function replaced by a lambda, a class
attribute or method changed (in the class or a base, or deleted), a field
shadowing a method or class attribute, `__class__` reassigned, `__get__`
added to a cached attribute's class, a new field layout, an int overflowing
a specialized add, `exec` adding a name, closures, generators, recursion,
threads, `return`/`break`/`continue` through `try`/`finally`/`with` (a
`finally` that returns, breaks or raises), tracing and profiling switched
on mid-loop.

### Benchmarks (`tools/bench/run.py --engine interp -n 5 --python --base <round-80 binary>`, min of 5, seconds)
| bench | round 80 | now | speedup | instructions (callgrind) | VM now | python3 |
|---|---|---|---|---|---|---|
| closures | 1.582 | 0.539 | 2.93x | 11.92G -> 4.27G | 0.373 | 0.050 |
| deltablue | 2.673 | 0.789 | 3.39x | 12.93G -> 4.45G | 0.515 | 0.023 |
| dict_str | 0.753 | 0.290 | 2.60x | 4.46G -> 1.94G | 0.242 | 0.029 |
| exceptions | 0.938 | 0.535 | 1.75x | 7.58G -> 4.30G | 0.122 | 0.006 |
| fannkuch | 2.775 | 1.094 | 2.54x | 18.79G -> 8.10G | 0.461 | 0.046 |
| fib | 1.027 | 0.244 | 4.22x | 7.07G -> 1.99G | 0.142 | 0.019 |
| generators | 1.238 | 0.476 | 2.60x | 8.71G -> 3.23G | 0.382 | 0.056 |
| nbody | 1.060 | 0.308 | 3.44x | 7.79G -> 2.95G | 0.237 | 0.018 |
| raytrace | 2.265 | 0.569 | 3.98x | 11.55G -> 3.88G | 0.318 | 0.035 |
| richards | 3.367 | 0.690 | 4.88x | 19.00G -> 4.50G | 0.397 | 0.052 |
| spectral_norm | 1.792 | 0.612 | 2.93x | 13.15G -> 4.12G | 0.329 | 0.038 |
| **geometric mean** | | | **3.09x** | **2.78x fewer** | | |

Instructions are each benchmark's run under callgrind less the startup
(~0.48G, the prelude and `import time`, which `bench_time` leaves out too).
The VM is unchanged (0.99x by time, its instruction counts within 0.2%);
the interpreter is now within 1.2-2.4x of it except for exceptions (4.4x).
Every run's result line equals python3's.

### Windows (MinGW, under Wine; the round-80 tree cross-built the same way as the base)
- x64 (`tools/cross_windows.sh build`; `pe_unwind_check` clean): **2.87x**
  (min of 3; closures 3.13x, deltablue 3.05x, dict_str 2.38x, exceptions
  1.80x, fannkuch 2.46x, fib 4.06x, generators 2.65x, nbody 3.19x,
  raytrace 2.62x, richards 2.91x, spectral_norm 4.05x).
- i686 (`ARCH=i686`): **2.69x** (closures 2.30x, deltablue 2.96x, dict_str
  2.50x, exceptions 1.80x, fannkuch 2.36x, fib 3.08x, generators 2.37x,
  nbody 2.86x, raytrace 2.77x, richards 3.58x, spectral_norm 3.58x).
- vm_audit100 passes on both (interpreter, `NY_ASTSPEC=0`, VM), and so do
  vm_audit53, 55, 56, 72, 79, 88, 91, 98. The i686 link's "duplicate
  section `.data$_ZZN4nyrt15class_dir_names...`" message comes from the
  round-80 tree too.

### Where the time went (callgrind, before)
- **Value copies and the allocator** - the interpreter's equivalent of the
  VM's 40%: in fib, `Value`'s copy/move constructors, destructor and default
  constructor 17%, malloc/free 21%, memcpy 4% and `std::string` assignment 2%
  - most of it the `Token` every `Value` carried (two strings and a vector:
  copied by each copy, never set). `shared_ptr` releases 2.5% (every eval
  function took its node by value).
- **Lookups by string and by pointer**: in richards `OrderedMap::find_slot`
  6.3% (a name looked up scope by scope, a field, a class namespace), the
  side tables (`func_names`, `instance_to_class`, `class_ctx_map_`,
  `instance_properties` as `std::map`s) 6.5%, string comparisons and
  `strlen` against literals 5% (`fnTag` copies, `rfind("__class__:")`
  tests, the builtin dispatch chain's names), `findClassMember` /
  `getAttrValue` walking the MRO for every method call 3%; in dict_str
  `__dynamic_cast` 1.7% (`contOf`).
- **The generic paths for simple things**: `1 + 1` through `binaryOp`
  (operands copied, the operator's text compared), literals parsed from
  their token text on each evaluation (`strtol` 1.2% of fib), a vector, a
  keyword map and four side-table lookups per call.
- **Exception unwinding**: raytrace threw a C++ exception for every
  `return` inside `try`/`finally` (2,381 throws, 4% of its time); the
  exceptions benchmark spends ~65% in the unwinder (unchanged - see "Not
  done").

### What was done (and from where)
The model is Würthinger et al.'s self-optimizing AST interpreter (DLS 2012,
the Truffle node model): a node keeps what it observed - a value, an
operator code, a scope depth and slot, a receiver class - and takes a short
path behind a cheap guard; a failed guard runs the general code, unchanged.
Nodes are not replaced (the AST is shared with the parser, the debugger and
the static scope checks), so the state lives in fields of the node
(`ASTNodes.hpp`, "round 81"). The general paths stay the specification:
every fast path sits next to the code it skips, with the argument why each
skipped step would have answered no.

- **Values**: a `Value` no longer carries a `Token` (two strings and a
  vector, copied with every Value; nothing ever set it -
  `Value::token_default()` answers the few readers); its constructors and
  destructor are inline; `TValue` has no padding (80 bytes, from 112);
  `bigint` keeps two limbs inline (`LimbVec`, no allocation below 2^128)
  and has no vtable. Eval functions take `const node_ptr&` (a shared_ptr
  copy - two atomic operations - per node evaluated before).
- **Kinds by flag** (`nygc::F_KSTR/F_KINST/F_KFUNC/F_KCONT`, set by the
  constructors): `heapKind`, `contOf`, `isInstanceVal`, `isStringValue`,
  `bytesOf` answer without hash/tree lookups or `dynamic_cast`; an
  instance's class and field scope come from its object (`instPropsOf`,
  `instClassNode`); the instance side tables are hashed.
- **Literals and operators**: an int/float literal is made once; a binary
  or augmented operator's code is worked out once; int/float arithmetic and
  comparisons skip the general dispatch (`numBinary`, exact overflow to big
  ints); `x += 1` on a name stores without a second lookup.
- **Names** - speculative lexical addressing, guarded: a name node hashes
  its name once and remembers the depth and slot it was found at; that slot
  is tried first at that depth (its key still there makes it the entry)
  and the scopes before it are still searched, so a name added later to an
  inner scope (a local, `exec`, a frame's `f_locals`) is seen. Static
  (depth, slot) resolution was not taken: scopes here are dynamic (`exec`
  namespaces, PEP 667 `f_locals` writes, plain assignment rebinding the
  nearest binding, live module namespaces) and the guarded form costs one
  key comparison. `self`/`this` the same; whether an assigned name is a
  builtin's is remembered while that set is unchanged.
- **Calls**: a def or lambda with plain parameters, called with as many
  plain positional arguments, takes them on the C++ stack (`ArgBuf`), its
  code and scope from its heap object (`nyheap::Func::code`), and binds
  distinct parameter names by appending to the fresh scope. **Method calls
  on instances** go through a polymorphic inline cache per call site
  (Hölzle, Chambers & Ungar, ECOOP 1991; 4 classes, exponential backoff when
  filling keeps failing, `methodICFill`/`methodFast`): the method, the
  namespace and slot that hold it, and the namespaces before it in the MRO
  with the versions of their key sets (`NyOrderedMap::version`). Attribute
  stores on instances: a 2-way cache of the same kind (`storeFast`); field
  reads keep their slot (`fieldAt`). **Class attributes and methods read as
  values** (`Strength.REQUIRED`, `f = obj.m`): a per-node cache of the
  namespace and slot that answered (`classLoadFast`), whose value then goes
  through the same last steps as the general walk (`classNsResult`).
- **A builtin value's own method** (`s.strip()`, `d.get(k)`,
  `xs.append(x)`): for a str, a plain dict or a list and a name its kind's
  table has, straight to that table (`builtinMethodFast`;
  `builtinMethodKinds` decides per site); `isinstance` is called directly,
  not after ~300 name comparisons in `dispatch_tensor`.
- **Control flow**: `return`/`break`/`continue` inside `try`/`finally` and
  `with` set the pending flag instead of throwing (round 74 did it for the
  rest): the statement checks the flag as each clause ends and runs the
  finally body / `__exit__` with it cleared, then restores it
  (`leaveWithPending`) - a raytrace frame's `return` inside `try` threw.
- **Containers**: `xs[i]`/`xs[i] = v` find the slot from the index
  (`seqSlot`); ordering, `in`, `==` and `seqItems` likewise; the marker keys
  are hashed once and tried at the end first (`markerSlot`); lists and
  tuples are built by appending; emptied small maps are kept per thread for
  the next scope or container (`Container.cpp`, `MapPool`).
- **Invalidation**: one specialization epoch (`spec_epoch_`,
  `specInvalidate()`), bumped by whatever can change what a cache assumed
  about classes - an MRO computed or dropped, a class namespace set
  (`setClassContext`) or dropped, `class_vars_` written or deleted, a
  function's kind tag changing (property/staticmethod/classmethod), a
  `__getattribute__`/`__setattr__` hook appearing, `__slots__` flags, the
  death of a function a cache names (`F_KICREF`). Caches own no references:
  they hold slot numbers and pointers valid for the epoch they were made in,
  plus the executor that made them.
- Not taken: rewriting nodes in place (the AST is shared); superinstructions;
  exceptions without a throw (the interpreter's Python exceptions are still
  C++ throws - see "Not done").

### What each part bought (instructions, callgrind, geometric mean of the 11 benchmarks)
| step | fewer instructions | biggest gains |
|---|---|---|
| 1: Values without tokens, inline limbs, kind flags, `const node_ptr&`, cached literals and operator codes, `numBinary`, name caches, plain calls on the stack, method-call and store caches, field slots (8672f55) | 2.42x | fib 3.28x, richards 3.33x, spectral_norm 2.81x |
| 2: `self` caches, distinct-name binding, aug-assign and `xs[i]` fast paths, the map pool, `isinstance` direct, try/with without throws, builtin values' methods, class-attribute cache, sequence comparisons by slot (72a75c6) | 1.14x | dict_str 1.34x, richards 1.27x, raytrace 1.19x |
| 3: lists and tuples built by appending, marker keys at the end (b7bb7b8) | 1.01x | closures 1.08x, spectral_norm 1.04x |
| total | 2.78x | (3.09x by time) |
| of which the general paths alone (`NY_ASTSPEC=0`) | 1.91x | fib 2.25x, spectral_norm 2.43x |
| and the caches and specialized paths on top | 1.46x | richards 2.71x, deltablue 1.92x, raytrace 1.87x, fib 1.58x |

By time (min of 3, interleaved): step 1 2.67x, step 2 1.15x, step 3 1.06x;
`NY_ASTSPEC=0` 1.98x over round 80, the caches 1.46x over that. The caches
cost nothing measurable where they do not apply except in the exceptions
benchmark (4% more instructions with them: more and larger frames for the
unwinder to walk).

### Rules for anyone changing the interpreter now
- **Anything that changes a class bumps the epoch**: a new write to
  `class_vars_`, `class_ctx_map_`, `mro_cache_`, `slot_flags_`, a function's
  tag in `func_names`, or a hook cache must call `specInvalidate()`.
- **A new step before the class walk or the kind's method table** in
  `getAttrValue`, `callMethod` or `evalCall` must be mirrored in the fast
  path that skips it (`classLoadFill`, `builtinMethodKinds`/
  `builtinMethodFast`, `methodICFill`, `storeICFill`) or excluded there.
- A construct that runs statements and does not check the pending flag
  must suspend it (`SuspendFast`); one that runs user code while a
  return is pending must clear the flag around it (`leaveWithPending`).
- `NY_ASTSPEC=0` turns every cache and specialized path off (the general
  paths run); it is the first thing to try when a result differs.

### Memory
Peak RSS against round 80: **+0.8 MB at startup** (`pass`: 23.4 -> 24.2 MB)
- the AST's nodes carry their caches (a name node's hash, depth and slot,
a call's argument and signature facts, an operator's code; the inline
caches themselves are made on a site's first use: ~110 bytes per method-call
way, 4 ways, ~50 per store way, 2 ways, ~70 per class-attribute read) - and
the map pool keeps up to 64 emptied maps per thread. Programs that hold
values use less, because a `Value` is 80 bytes (from 112) and owns no token
strings: dict_str -24%, exceptions -18%, closures -16%, deltablue -9%,
vm_audit55 -27%, vm_audit73 -11%, vm_audit100 -11%; the small benchmarks
are within +1.3 MB. The IDE's `ide_memprobe --check` still finds no growth
per frame, key, scroll or split.

### Verified (b7bb7b8 + docs)
- The sweep: 425 runs, 0 not ok. `ide_e2e` 390 passed, 0 failed;
  `ide_memprobe --check` (no growth); `ny_classcheck`; `cbp.py check` (61
  units; no new .cpp).
- vm_audit100 (114) on the interpreter, with `NY_ASTSPEC=0`, on the VM and
  under python3; vm_audit26 27 53 55 56 57 60 64 72 74 76 79 80 81 82 83 85
  86 88 89 91 98 on the interpreter and with `NY_ASTSPEC=0`; 53 72 74 76 79
  80 81 82 83 98 on the VM.
- The VM's instruction counts (fib, closures) are within 0.2% of round 80's.

### Merged with parts A and C
- Conflicts only in `evalStatements` (part A's jump resumption kept, over
  part B's in-place statement list), `evalCall`'s first lines (part A's
  extension-stack test kept; B's fast paths come after it, and every
  function body still passes `runFunctionBody`'s recursion-limit check)
  and the class-attribute store (a hook assigned on a class clears A's
  hook caches and bumps B's epoch).
- vm_audit99/100/101 pass on the interpreter, with `NY_ASTSPEC=0` and on
  the VM (99 and 100 under python3); `python3 tools/sweep.py` 429 runs, 0
  not ok; `tools/ide_e2e.py` 442 passed; memprobe 0.00 KB everywhere.
- The merged interpreter against part B's own binary
  (`run.py --engine interp -n 5`): 1.03x geometric mean (noise both ways;
  generators re-run with `-n 11`: 0.97x) - part A's changes cost nothing
  measurable, so the 3.09x over round 80 stands.

### Not done / found
- **Python exceptions are still C++ throws** on the interpreter: the
  exceptions benchmark spends ~65% in the unwinder (`__gxx_personality_v0`
  scanning the call-site tables of the evaluator's very large functions),
  so it gained least (1.75x). The VM's round-80 answer (a pending
  exception travelling by return value) would need every eval function to
  check a flag after every sub-evaluation; not attempted.
- Startup is ~480 million instructions (~0.14 s), most of it the parser
  copying `Token`s (`Parser::token()` returns one by value); the benchmarks'
  `bench_time` excludes it, every run pays it.
- Tuples made by `enumerate`/`zip`/`items()` in a `for` with a tuple target
  are still built and unpacked (spectral_norm: 10% in `makeListValue`).
- Remaining costs (fib, richards): `Value` copies (a `bigint` and a
  `long double` in every one), the per-call `Context` and its map, name
  lookups in the scopes before the cached depth, the builtin dispatch
  chain's string comparisons (`callBuiltin`, `iterableBuiltin`).
- Found, not fixed (pre-existing, both checked against the round-80
  binary): on the interpreter a lambda stored as a class attribute after
  the class statement (`C.m = lambda self: 1`) is not bound when read as a
  value (`b = o.m; b()` raises TypeError; the VM and python3 bind it);
  `del C.m` leaves `o.m()` callable on the interpreter (the class-body scan
  in `callMethod` finds the deleted def; the VM and python3 raise
  AttributeError); `[1, 2].pop("x")` returns None on the interpreter and
  pops 2 on the VM (python3 raises TypeError). **All three fixed in the
  follow-ups, §0t4.**
- The round-80 note on `C.__setattr__ = f` set after instances stored
  attributes (ignored on both engines) still holds; the store cache
  checks the same hook test (`instanceAttrHook`) as the general path.
  (Part A fixed it on both engines; the merge keeps both the hook-cache
  clear and this part's epoch bump.)
- vm_audit66 (signals) failed once on the VM in a sweep run under heavy
  load (exit 1); it passed 12/12 runs of the new binary and 12/12 of the
  round-80 one afterwards, and in the final sweep.

## 0t. Round 81, part A — the semantic gaps round 80 left (vm_audit99)

`examples/vm_audit99.ny` (125 checks) passes on the interpreter, the VM and
python3.11; every expected value is CPython's (a jump into a `with` body:
3.11 and 3.12 word the error differently, the check accepts both). Both
engines the same way unless said.

### except E as e
- The name is unbound when the clause ends, however it ends (falling off,
  return, break/continue, an exception out of it), before the try's own
  finally runs - CPython's `try: body finally: e = None; del e`, with no
  line event of its own. Interpreter: `evalTry`'s `UnbindAs` guard around
  the handler body. VM: `Compiler::visit_unbinding_clause` compiles the
  body as a try/finally whose finally stores None and deletes the name.
  `except <expression> as e` (the parser's lowered catch-all) unbinds its
  clauses' names too (`ExceptNode::unbind_names`, set in
  `Parser::tryStmt`).

### globals(), locals(), vars(), exec, sys.modules["__main__"]
- `globals()` is the module's live namespace: the prelude's
  `_NyGlobalsDict` (dictview chunk, a `_NyInstanceDict`), one per module
  (`globals() is globals()`), whose value is the module's variables as they
  are now (the engines' payload of a view whose field `__ny_globals_of__`
  is the module object, None for the program - `globalsOf` / `globals_of`)
  and whose stores and deletions bind and unbind them (`_ny_main_set` /
  `_ny_main_del` for the program, setattr/delattr on a module's live
  namespace). `type(globals()).__name__` is "dict" and it is a dict
  instance, but `type(globals()) is dict` is False.
- `locals()` and `vars()` at a module's top level are that view; so are
  `vars(module)` and `f.__globals__`; inside `exec(src, ns)`, `globals()` is
  `ns` itself. `exec(src, globals())` / `eval(src, globals())` run in that
  module's scope (exec and eval are payload-transparent now:
  `nyrt::payload_transparent`); a dict subclass given as exec's globals or
  locals, or any mapping as its locals (collections.OrderedDict, a
  UserDict - read through its `keys()`/`__getitem__`, the prelude's
  `_ny_mapping_snapshot`), gets what the code binds or rebinds through its
  `__setitem__` (it was lost in a copy). A name the code deletes is not
  deleted from such a mapping.
- `sys.modules["__main__"]` (`_NyMainModule`): setting or deleting an
  attribute binds or unbinds the program's global; its `__dict__` (a
  property - `vars()` honours a class's own `__dict__` now on both engines)
  is the program's globals view. The program has `__spec__` (None).

### __spec__, __loader__, sys.meta_path, sys.path_hooks
- A module the engines imported gets `__spec__` / `__loader__` when first
  read (`_ny_module_spec_attr`: importlib.machinery's ModuleSpec and
  SourceFileLoader for its file, BuiltinImporter's for sys/os/math/
  builtins) - lazily, so an import costs what it did.
- The import statement asks the prelude's `_ny_import_via_hooks(name)` for
  a module that is not loaded yet (CPython's `_find_and_load` order):
  `sys.meta_path`'s default entries stand for the engines' own search
  (`_NyNativeFinder("builtin")`, `("path")`, marked `_ny_kind`); a program's
  finder before them is asked first, after them only for what they cannot
  find; with `sys.path_hooks`, each sys.path entry (a package's `__path__`
  for a submodule) is offered to the hooks and the finder kept in
  `sys.path_importer_cache` (None for an entry no hook takes - the engines'
  own directory search). A spec is loaded as `_load_unlocked`
  (create_module, the module's attributes, sys.modules, exec_module). With
  no finder or hook of a program's own it returns None at once, and only
  for a module not loaded yet: importing 22 stdlib modules (json, re,
  collections, decimal, datetime, enum, dataclasses, typing...) took
  0.646 s on the interpreter before and 0.650 s after (VM 0.59 s / 0.51-
  0.55 s), and 40,000 imports of loaded modules 0.028 s / 0.69 s on both
  binaries (min of 3 interleaved runs against 2eb1221's build). The
  benchmark suite (`tools/bench/run.py --base`, 2eb1221): VM 1.04x,
  interpreter 1.04x geomean - no change outside noise.
- `import builtins` is lib/builtins.ny whatever sits beside the script
  (examples/builtins.ny, a demo, shadowed it - CPython's BuiltinImporter
  comes first).

### Attribute hooks assigned later
- `C.__setattr__ = f`, `__delattr__`, `__getattribute__` (and `__new__`)
  assigned to a class - or deleted from it - after instances stored
  attributes: the hook caches are cleared (interpreter `setAttr` /
  `delAttrValue` on a class; VM `set_attr` / `del_attr` - EpochCaches, so the
  specialized code sees it too).

### Live list iteration
- VM: `for x in some_list` iterates the list itself by index (a loop's own
  `list_iterator` on the stack, `stack_list_iter`, served by FOR_ITER's
  in-place branch and by FOR_ITER_LIST when specialized): an item appended
  in the loop is reached, a list that shrank ends it. `iter(list)`,
  enumerate/zip/map/filter over a list (`vm_iter_open`) and a GET_ITER not
  followed by FOR_ITER are live too (`list_iter`, a native generator; an
  exhausted one stays exhausted). The O(n) copy per loop is gone; a set's
  loop walks the set's own items too (see "More of this kind").
- Interpreter: `iter(list)` was live already; its list loop read the length
  once (appends unseen) - it is read at each step now (a set's size is
  checked instead).

### Classes that take no arguments
- `P(1, 2)` for a class with neither `__init__` nor `__new__` of its own:
  `TypeError: P() takes no arguments` (`object(1)`, `class C(object)`,
  `P(x=1)` too); `object.__init__(self, x)` reached from an `__init__`
  (`super().__init__(x)` included) and `object.__new__(cls, x)` from a
  `__new__` give CPython's "takes exactly one argument" errors - the
  prelude's `_ny_ctor_check`, run by object's `__init__`/`__new__` only when
  given arguments. Exceptions and builtin subclasses take their arguments as
  before. object's own `__init__` is no longer called by an instantiation
  (it did nothing). Interpreter `runConstructor` / `superCall`; VM
  `instantiate` / `check_no_ctor_args` / super's ctor path.
- Repository code that relied on the leniency: none found - every example,
  test and GUI test (the sweep, both engines) and the IDE (e2e, lint)
  pass with no change to lib/, the IDE or examples/.

### The default repr
- `<__main__.P object at 0x...>` - the class's `__module__` and
  `__qualname__`, the address id() gives - for repr, str, format,
  f-strings, containers and the object protocol's `to_string()`
  (`defaultInstanceRepr` / `vm_default_repr`). Adapted:
  `examples/gui_tests/test_25_object_protocol.ny` (it expected `<Child
  instance>`). Nothing in the IDE or lib/ relied on the old form.

### f_lineno jumps (pdb's jump)
- A trace function may set `frame.f_lineno` from a 'line' event of that
  frame, with CPython's rules and 3.12's messages: not from 'call' ("can't
  jump from the 'call' trace event of a new frame"), 'return'/'exception'
  ("can only jump from a 'line' trace event") or outside a trace function;
  "line N comes before / after the current code block"; to the first line
  with a statement on or after N; not into a for loop's body or a with body
  ("can't jump into the body of a for loop" - 3.12's message for both), nor
  an except clause ("can't jump into an 'except' block as there's no
  exception"). It may enter if/elif/else, while bodies, try bodies, else
  and finally blocks; what it leaves is just left (no finally or `__exit__`
  runs, as in CPython); jumping to a for loop's line starts the loop again
  (3.11's behaviour). The target's own line event is not reported, as
  CPython's is not. pdb's `jump` works (it already set f_lineno).
- Interpreter: `frameJump` analyses the code block's statements over the
  AST (`jumpWalk`: each statement with its chain of blocks); the jump is a
  `JumpSignal` thrown when the trace function returns (`pyEvLine`), caught
  by `evalStatements` of the deepest block holding both statements, which
  goes on at the target, entering blocks on the way down (`jumpResume`,
  `resumeInto`). Cost when not tracing: one thread-local byte per block
  entry (`jumpResuming`); `evalScript` is `evalStatements` now.
- VM: `vm_frame_jump` works over the bytecode: the blocks an instruction
  is in come from the code itself (FOR_ITER ranges, the exception table's
  handlers, finally blocks and with bodies - `vm_blocks_at`); `run_loop`
  pops what the left blocks keep on the stack, pushes a normal state for a
  finally entered, clears a left handler's exception and moves `ip`
  (`vm_apply_jump`) - no cost when not tracing.
- `f.__code__ is frame.f_code` - one code object per function
  (`_ny_code_of`, over a code identity `_ny_fn_info` now gives as its 8th
  item): trace functions compare them, and could not.

### sys
- `sys.getrefcount(x)`: the real count (interpreter `gc_rc`, VM the shared
  count) less the call's own reference, plus one for the argument -
  CPython's numbers for `y = x`, a list holding it...; 2**32-1 for values
  without a count (ints, floats, bools, None, VM strings), as 3.12 reports
  immortal objects.
- `sys.stdlib_module_names`: a frozenset of lib/'s modules and packages and
  the engines' own (builtins, math, os, sys).
- `sys.displayhook` / `__displayhook__` (`_ny_displayhook`, CPython's: None
  not shown, the repr on sys.stdout, the value kept in `_`); the
  interactive prompt (-i and the REPL, both engines) calls a program's own
  hook instead of showing the value itself (`_ny_prompt_display`).
- `-OO` drops docstrings (`__doc__` None - the parser's `docstringOf`).

### Deep recursion
- Both engines stopped near 1100 frames (8 MB of native stack, ~7 KB a
  Nython frame) whatever the recursion limit. A call near the end of a
  thread's own stack now goes on on an extension stack - the segmented
  stack generators and async tasks already had (`nygen::call_on_new_stack`
  / `body_on_new_stack`, the VM's `run_frame_plain` extension) - so
  `sys.setrecursionlimit(5000)` then 3000 frames works on both engines, in
  threads too, wherever NyCoro runs (fibers on Windows, 32-bit included:
  1 MB segments of reserved address space, made only that deep). The
  recursion limit itself is unchanged (the interpreter keeps its margin of
  100: 4899 frames at 5000, the VM 4998 as CPython).
- Found and fixed: the interpreter crashed (SIGSEGV) on recursion that did
  not pass `evalCall` - `def __eq__(self, o): return self == o`, a property
  reading itself; it is a RecursionError now (`runFunctionBody` checks the
  frame depth against the recursion limit).

### More of this kind (found and fixed)
- `frame.f_globals` is the module's live globals() view (`sys._getframe(1).
  f_globals[name] = v` binds a global of the caller's module, a common
  metaprogramming idiom; `f_globals is globals()`). Interpreter
  `frameGlobals`, VM `frame_globals` (a prelude frame keeps its copy).
- A set changed in size while a loop walks it is CPython's RuntimeError
  "Set changed size during iteration" (the interpreter's loop checks the
  size at each step; the VM's loop walks the set's own items through
  `stack_set_iter` - it walked a copy - and checks the size in FOR_ITER).
  `iter(s)` / `next()` by hand still walk without the check (fixed in
  the follow-ups, §0t4).
- Functions show as CPython's `<function Qualname at 0x...>` (the address
  id() gives): `<function outer.<locals>.inner at 0x...>`, `<function
  K.s at 0x...>` for a staticmethod (the interpreter showed
  `<function s__static__>`). Interpreter `toText` (`idHex`, shared with the
  default instance repr), VM `VMVal::repr`.
- `__class__` read in a method is the class defining it (CPython's implicit
  cell, the class super() uses): the NameError path of the interpreter's
  `evalVariable` (the running method's `owner_stack_`) and of the VM's
  LOAD_NAME (`VMCode::owner_class`) - no cost to names that resolve.
- `exec(src, g, mapping)`: a locals mapping that is not a dict
  (collections.OrderedDict) is read through `keys()`/`__getitem__` and
  written back through `__setitem__`.
- `import builtins` from a script beside a `builtins.ny` (see above).
- Interpreter SIGSEGV on recursion through operators (see Deep recursion).

### Not done / found
- Reading a function's local before it is assigned (or after `del`) is a
  NameError, not CPython's UnboundLocalError (a NameError subclass:
  `except NameError` catches both); the scope ruling of round 75 decides
  what is local at run time, so the engines would need a static scan. (Fixed in the follow-ups, §0t4: NyScope flags the
  reads, so no run-time scan was needed.)
- The program has no `__loader__` and no `__builtins__` global.
- A jump from a for loop's header event into its body is refused on the
  interpreter (CPython allows it: the iterator is on the stack there), as
  is one from an except clause's own line into its body; jumping out of
  `except E as e:` unbinds `e` on the interpreter (CPython's cleanup is
  skipped by the jump).
- `__spec__` read as a global name inside an imported module is None (the
  module object has the real one); the program's `__loader__` is not set.
- `builtins._` is not set by the display hook (the program's `_` is).

### Verified
- vm_audit99: 125 passed on the interpreter, the VM and python3.11.
- vm_audit53/72/74/76/79/80/81/82/83 pass on both engines;
  `tools/ny_classcheck.py` clean; `tools/cbp.py check` 61 units.
- `python3 tools/sweep.py`: 425 runs, 0 not ok.
- `tools/ide_e2e.py` 390 passed, 0 failed; `tools/ide_lint.py` 0
  unresolved; `tools/ide_memprobe.py --check` 0.00 KB per frame/event/key.
- **Merged with part C** (only the docs conflicted): vm_audit99 and
  vm_audit101 125/125 on both engines (vm_audit99 under python3 too) - the
  live `f_globals`/`globals()` views and the jumpable line events did not
  disturb the debug server; `python3 tools/sweep.py` 427 runs, 0 not ok;
  `tools/ide_e2e.py` 442 passed, 0 failed (part C's `live`/`profile`
  scenarios included); `tools/ide_memprobe.py --check` 0.00 KB on every
  probe (`live`/`profile` too); lint, classcheck, cbp clean.

## 0s3. Round 80, part C — a specializing adaptive interpreter for the VM (vm_audit98, `tools/bench/`)

The VM is **3.15x faster** (geometric mean of 11 benchmarks, Linux; 2.42x
x64 and 2.40x i686 under Wine) with no behaviour change: the sweep and
`ide_e2e` are the oracle, and `examples/vm_audit98.ny` (72 checks, the
interpreter, the VM and python3; also with `NY_QUICKEN=0`) exercises every
specialized path and its deoptimization (a method added to a base after a
site specialized, `__class__` reassigned, globals and builtins rebound, an
int overflowing into a big int, a site turning polymorphic, descriptors and
`__getattr__` appearing later, `__slots__`, generators, threads rebinding a
global while another calls, tracing switched on mid-loop).

### Benchmarks (`tools/bench/run.py -n 5 --python --base <old binary>`, min of 5, seconds)
| bench | before | after | speedup | python3 |
|---|---|---|---|---|
| closures | 0.794 | 0.298 | 2.66x | 0.045 |
| deltablue | 0.824 | 0.360 | 2.29x | 0.022 |
| dict_str | 0.372 | 0.191 | 1.94x | 0.023 |
| exceptions | 0.740 | 0.105 | 7.03x | 0.005 |
| fannkuch | 0.958 | 0.414 | 2.31x | 0.039 |
| fib | 0.557 | 0.106 | 5.26x | 0.017 |
| generators | 0.794 | 0.332 | 2.39x | 0.027 |
| nbody | 0.735 | 0.214 | 3.44x | 0.016 |
| raytrace | 0.921 | 0.293 | 3.14x | 0.029 |
| richards | 1.190 | 0.348 | 3.42x | 0.047 |
| spectral_norm | 1.024 | 0.304 | 3.36x | 0.033 |

The VM is still 6-22x slower than python3. Each benchmark's result line is
compared with python3's.

### What was done (and from where)
- **Profile first** (callgrind; no perf here): ~40% of the time was `pop()`
  and `VMVal` move/copy/destroy (a `VMVal` is 216 bytes: 2 strings, 7
  shared pointers), ~10% `frame_visible` (a walk over every frame per name
  lookup), and in the exceptions benchmark 85% was the C++ unwinder.
- **Generic paths** (1.31x alone): reused frames (`FrameStack`; a
  `std::deque` allocated a node per call), cheaper `VMVal` copies/moves,
  push/pop by reference, in-place generic ops, O(1) name walks when the top
  frame has no closure environment, a `LOAD_METHNAME` placeholder for the
  method name, direct str/list method calls (no `std::function` per call).
- **Quickening** (PEP 659; Brunthaler, "Inline Caching Meets Quickening",
  ECOOP 2010): a generic instruction counts down two runs, then rewrites
  itself into a specialized form with an inline cache (37 new ops after
  `FOR_PREP`: attribute loads/stores, method calls, global/name loads,
  int/float/str arithmetic and comparisons, subscripts, Python calls with
  exact arguments, builtin calls, iteration); a failed guard runs the
  generic case (`redispatch:`), 32 misses rewrite it back with exponential
  backoff (4, 8 ... 255 runs). **Polymorphic inline caches** (Hölzle,
  Chambers & Ungar, ECOOP 1991) at method-call and attribute-store sites:
  up to 4 receiver classes.
- **Invalidation**: one process-wide type epoch instead of per-class
  versions - every write to a class table goes through wrappers that bump
  it, and the compiler enforces that (`ClassVars`, `EpochMap`, `EpochSet`,
  `EpochCache`, `EpochFlag`); dict/global/local caches hold a slot number
  and check the key still sits there (exact: `NyOrderedMap`'s slots are
  stable).
- **Exceptions without a C++ throw** inside the loop (`RAISE`, re-raise,
  `RAISE_ERROR` jump to `fast_exc_pending`; a frame run by a specialized
  call returns its exception with a sentinel): the exceptions benchmark
  executes 7.5x fewer instructions.
- Not taken: superinstructions (the profile did not point at pairs),
  computed goto (~1% mispredicted indirect jumps, so ~3% at most), unboxing
  `VMVal` (too invasive; now the largest remaining cost).
- Switches: `NY_QUICKEN=0`, `NY_QUICKEN_SKIP=names,attrs,calls,arith,
  iter,subscr`, `NY_QUICK_STATS=1`, `NY_VM_TRACE=2` (shows specialized ops).

### Rules for anyone changing the VM now
- **Write class tables only through their wrappers** (`class_vars_.find_mut`
  / `all_mut` / `operator[]`, the `Epoch*` types): a write that skips them
  leaves a stale cache, a silent wrong answer.
- **`VMVal` is not an aggregate any more**: brace-initialising it with more
  than its type does not compile.
- Caches hold no owning references (slot numbers, compared map identities,
  pointers valid for the current type epoch); a reused frame releases all
  it held when popped; caches are per code object, under the GIL.
- Specialized instructions still raise line events (the trace check stays
  one byte per instruction); specialized calls run the traced frame loop
  whenever a hook is set; builtin fast paths step aside under a profiler.
- Memory: `Instruction` stays 12 bytes (`static_assert`), 16 bytes per
  code object, a 72-byte cache entry per specializable instruction on the
  first specialization attempt (code run once never allocates), 120 bytes
  per polymorphic site; peak memory about +1 MB.

### Merged onto parts A and B
- Two semantic conflicts, no textual one: part C's fast call path named the
  `kMaxFrames` part A had replaced with `nyrt::recursion_limit()` (it did not
  compile), and **`LOAD_NAME_MOD`/`LOAD_NAME_GLOBAL` read the program's frame
  for prelude code**, which part A had made invisible to it - with a program's
  top-level `list = []`, abc.ABC's `__slots__ = ()` called the program's list
  (`v5_spec_compliance_test` on the VM). `plain_function_frame` now excludes
  prelude code; vm_audit98 checks it in a subprocess on both engines.
- Windows 64-bit (under Wine): built, `pe_unwind_check` clean; the sweep 423
  runs, 421 ok - vm_audit96's `pkgutil.extend_path` check failed on both
  engines: **a package's `__path__` mixed separators on Windows**
  (`\\tmp\\pk/relx`: the engines strip `/__init__.ny` from a path they built
  with `/`) and importlib's PathFinder joined with `/` too, so the two never
  compared equal. Both now use the native separator, as CPython (the engines'
  `__path__`, `PathFinder.find_spec`, `_spec_for_path`); vm_audit96 then
  passes 115/115 under Wine on both engines (the sweep was not run again).
- Windows 32-bit (i686, under Wine): vm_audit98, 96, 97 (240, POSIX-only
  checks skipped), 95 (with the 32-bit decimal limits), 93, 91, 88, 56 pass
  on both engines.
- AArch64 (qemu-user): vm_audit98 (the 72 checks that do not spawn
  `sys.executable`, also with `NY_QUICKEN=0`), 95, 91, 89, 88, 56, 49 pass on
  both engines; 96 and 98's subprocess check cannot run there (no
  binfmt_misc in this container).
- Verified after both fixes (all of round 80): the sweep 423 runs, 0 not
  ok; vm_audit96/97/98 on both engines and python3 (98 also with
  `NY_QUICKEN=0`); `ide_e2e` 390/390; `ide_lint`, `ny_classcheck`,
  `cbp.py check` (61 units) clean; `ide_memprobe --check` passes.

### Not done / found
- `C.__setattr__ = f` assigned after instances stored attributes is ignored
  on both engines (the attribute-hook cache is not cleared for it).
- The VM's list iterator walks a copy of the list (an O(n) copy per loop,
  changes during the loop unseen).
- The quickening statistics counters are `long` (32-bit on Windows,
  diagnostic only); the cache entry could shrink to 40 bytes.
- Remaining cost: 216-byte `VMVal` copies, class-name string comparisons,
  map lookups in generic code, `isinstance` and object construction.

## 0s2. Round 80, part B — the OS layer's gaps, codecs, multiprocessing (vm_audit97)

`examples/vm_audit97.ny` passes 262/262 on the interpreter, the VM and
python3, and 240/240 under Wine on both engines (22 POSIX-only checks skip
there cleanly).

### os, os.path, stat, pwd, grp
- A lazily loaded prelude chunk `#@ os` plus native `src/builtins/os_fd.cpp`:
  `fspath`/`fsencode`/`fsdecode`/`PathLike` (`__fspath__` honoured by the
  path functions and `open`), `scandir`/`DirEntry` (cached stat, context
  manager) and `walk` over it (3.12's), **real file descriptors** (`open`
  with `O_*` flags, `read`/`write`/`close`/`closerange`/`pipe`/`dup`/`dup2`,
  inheritable and blocking flags, `lseek`, `fsync`, `isatty`, `truncate`/
  `ftruncate`, `fdopen`; `open(fd)` and `opener=`), ids, `umask`,
  `getlogin`, `chown`/`lchown`/`fchown`, `mkfifo`/`mknod`, `major`/`minor`/
  `makedev`, `getloadavg`, `sched_getaffinity`, `cpu_count`,
  `get_exec_path`, `access` with `F_OK`..., the path constants,
  `removedirs`/`renames`/`kill`; os.path `splitdrive`, `lexists`,
  `samefile`/`sameopenfile`/`samestat`, `ismount`, `isjunction`,
  `isdevdrive`, `splitroot`. `os.path.splitext` returns a tuple.
- `lib/posixpath.ny`, `ntpath.ny`, `genericpath.ny` are CPython's (checked
  against python3 on a battery of paths; on Windows `os.path` delegates to
  ntpath); `lib/stat.ny` complete (`os.stat_result` agrees); `lib/pwd.ny`,
  `lib/grp.ny` (ModuleNotFoundError on Windows). tarfile uses them for owner
  names and chowns on extraction as root.
- **One os module per program** on both engines (also `sys.modules["os"]`,
  part A): a module made per import was freed with a function's local
  `import os` and its address, still in the interpreter's
  `namespace_objs_`, typed the next dict made there as a module.
- `os.environ`: part A's `_NyEnviron` (merged: part B had written a second
  `_Environ` reading the live environment on each access; CPython's is a
  copy taken at startup that writes through, which is part A's).
- Windows: `os.stat` fills `st_ino`/`st_dev`/`st_nlink`
  (GetFileInformationByHandle); `os.path.exists(os.devnull)` is true.

### codecs
- `lib/codecs.ny`: the whole API (registry, CodecInfo, incremental and
  stream classes, `open`, `EncodedFile`, BOMs, `register_error`/
  `lookup_error`, the `_codecs` functions); all eight error handlers on
  every codec in both directions with CPython's positions and messages;
  utf-8, utf-8-sig, utf-16/32 (le/be), latin-1, ascii, cp437, cp850, cp1252,
  mac-roman, unicode_escape, raw_unicode_escape, idna, punycode, and the
  bytes-to-bytes hex/base64/zlib/quopri/rot13. One native table
  (`include/NyCodecs.hpp`, `NyCodecTables.inc`, `src/builtins/nycodecs.cpp`)
  serves `str.encode`/`bytes.decode` too (`NyBytes.hpp` delegates to it; a
  codec or handler only Python provides goes through the prelude's
  `_ny_codec_encode`/`_decode`).

### multiprocessing (spawn) and ProcessPoolExecutor over pickle
- `lib/multiprocessing/`: Process; Queue/SimpleQueue/JoinableQueue; Pipe/
  Connection; Lock/RLock/Semaphore/BoundedSemaphore/Event/Condition/Barrier
  across processes through a lock server (a thread per process; AF_UNIX on
  POSIX, TCP loopback on Windows; an HMAC check of the authkey; everything
  pickled); Value/Array/RawValue/RawArray and
  `shared_memory.SharedMemory` (mmap / CreateFileMapping); Pool and
  ThreadPool; Manager (a server process); `connection.Listener`/`Client`;
  `get_context("spawn")`. All of it works under Wine.
- **Innovation: work stealing in Pool** (Blumofe & Leiserson, 1999): each
  worker has its own deque and steals half of the longest. Makespans with 4
  workers and uneven tasks: expensive-last 0.51 s (FIFO chunk 1) / 1.35 s
  (chunk 4) -> 0.50 s (ideal 0.45); heavy-tailed 0.98 / 1.01 -> 0.87 (ideal
  0.74); 400 empty tasks 0.95 / 0.30 -> 0.55 - the balance of chunk 1 with
  less overhead.
- `concurrent.futures.ProcessPoolExecutor` sends pickle (round 79's JSON
  carrier is gone; `mp_context` is accepted and ignored).
- pickle: a native fast path for plain data at protocols 4-5
  (`src/builtins/nypickle.cpp`, CPython's bytes, its 1000-item batches with
  the trailing empty batch); os functions pickle as `posix.getpid` /
  `nt.getpid`; `__mp_main__` maps to `__main__`.

### Engine changes
- Interpreter: `makeOsNamespace` loads the os chunk and binds its
  `_ny_os_members`, cached (`os_ns_cache_`); `codecHook` for `str.encode`
  and `bytes.decode`. VM: `define_os_module` likewise (`os_ns_`, the module's
  `class_name` is "os"), `open()` routes an int path or `opener=` to
  `_ny_open_fd`, `codec_hook`; **`del L[1:3]` emptied the strings it kept**
  (an element moved onto itself) - fixed.
- `src/main.cpp` BridgeConv: shared references and cycles survive the
  interpreter-VM bridge (`built` memo), and `copy_back` no longer writes
  None over functions held in containers.
- New units `src/builtins/os_fd.cpp`, `nycodecs.cpp`, `nypickle.cpp` (in
  `nython.cbp`).

### Not done
- multiprocessing: no fork/forkserver, no waitable OS sentinels, no feeder
  thread, no ShareableList; server objects are not freed before their
  server exits; a Barrier's action runs in the process that gets index 0; a
  Pipe end held by a killed process is not closed; ctypes types are given
  as strings.
- os: no `dir_fd`; Windows has no ownership, FIFO or device functions;
  under Wine `os.getppid()` is 0.
- codecs: no cp1251, CJK, utf-7...; idna's nameprep only lower-cases.
- The interpreter's `namespace_objs_` can still go stale for other freed
  namespace objects (only os is cached); the VM's `exec("import os", ns)`
  binds in the globals.

### Verified after merging onto part A
- Linux, both engines: the sweep 421 runs, 0 not ok; vm_audit97 262 and
  vm_audit96 116 on both engines (262 / 115 under python3); vm_audit46,
  76, 77, 93, 94, 91, 92, 44 still pass; `ide_e2e` 390/390; `ide_lint`,
  `ny_classcheck`, `cbp.py check` (61 units) clean; `ide_memprobe --check`
  0 KB kept.
- The merge conflicted in `makeOsNamespace` / `define_os_module` (part A's
  `sys.modules["os"]` and part B's cache: both kept) and duplicated
  `os.environ` (part A's `_NyEnviron` kept, part B's `_Environ` removed).

## 0s. Round 80, part A — the correctness gaps rounds 78-79 found (vm_audit96)

`examples/vm_audit96.ny` (116 checks) passes on the interpreter, the VM and
python3.11; every expected value is CPython's except one Nython-only check
(code that is not marked Python still interpolates `${...}`). Both engines
the same way unless said. Sweep: 419 runs, 0 not ok; ide_e2e 390/390;
ide_lint and ide_memprobe clean.

### Crashes (interpreter)
- `__class_getitem__ = classmethod(types.GenericAlias)` then `A[int]`: the
  class attribute is a classmethod *object* (its `__func__` a class, so the
  engines do not unwrap it) and `classSubscript` called it as a function's
  AST node. Now a descriptor's `__get__(None, C)` is called with the item
  (the VM raised "'classmethod' object is not callable").
- A generator's bound `__next__` stored as a class attribute and iterated:
  `callClassMethod` declined any member that was not a function, class or
  builtin, and the older path below read the bound member's heap object as a
  FunctionNode (a type confusion, not a lifetime bug: the member is a counted
  `nyheap::BMember`). Now any other callable a class holds - a builtin's bound
  member, a bound method, an object with `__call__` - is called as it is (no
  self added, as Python), and the old path only reads a function's pointer
  as an AST node.

### Object model
- **object's members through every class** (`objectMember` /
  `object_member`): a class naming no base has no `object` in the MRO the
  engines search. Its members are now looked for where a lookup through the
  class found nothing (instance and class reads, method calls, `super()`), so
  attribute reads that succeed pay nothing. `object`'s class body keeps only
  what the engines dispatch to themselves (`__init__`, `__new__`,
  `__setattr__` ...); the rest - `__eq__ __ne__ __lt__ __le__ __gt__ __ge__
  __hash__ __repr__ __str__ __format__ __sizeof__ __dir__` - is the prelude's
  `_NyObjectExtra` (in `object`'s body every class would seem to define
  `__eq__`/`__hash__`/`__repr__` to the protocol dispatch, and `==`/`hash`/
  `repr` would run Nython code for every object). `P.__eq__ is
  object.__eq__`, `Base.__init__(self)`, `super().__hash__()`,
  `object.__repr__(x)` is CPython's `<__main__.P object at 0x...>` (the
  engines' default `repr()` stays `<P instance>`). Measured: no change to
  instance attribute access or method calls (the fallback runs only on a
  miss).
- Builtin exception classes and `object`: `__module__` is `"builtins"`,
  `repr(KeyError)` `<class 'KeyError'>` (`nyrt::class_repr`).
- `ImportError(msg, name=, path=)`, `AttributeError(msg, name=, obj=)`,
  `NameError(msg, name=)` (3.10+), also through `super().__init__(...)`; the
  runtime's own ModuleNotFoundError / AttributeError / NameError carry
  `name` (read back from the message: `nython::ny_exc_name_from_message`).
- VM: `iter([1]).__next__` (a list/tuple/str iterator's `__next__` called or
  read as a value raised AttributeError); each builtin reached through the
  bridge is one object (`bridge_natives_`), and `f_builtins` names natives
  as `load_var` does, so `f_builtins["len"] is len`.
- **`except <expression>:`** (Parser::tryStmt): any expression (`except
  self._error:`, `except errs[0]:`, `except get():`, `except (A,) + (B,)
  as e:`). The forms the engines match by name keep their path; from the
  first clause with an expression on, the clauses become one catch-all whose
  body tests them in order with the prelude's `_ny_exc_match` (CPython's
  check: classes or a tuple of classes, else "catching classes that do not
  inherit from BaseException is not allowed") and re-raises when none
  matches. A *name* bound to a tuple (`ERRS = (A, B); except ERRS:`) is now
  matched element by element (`excClauseMatches` / `match_except_handler`).
- **Numeric keys**: an object with `__hash__` equal to a float or an int of
  the same hash is that number's key (`hashedKey` / `hashed_key` try
  `__float__` then `__int__`): `{Decimal("0.5"), 0.5}` has one element,
  `{0.5: x}[Fraction(1, 2)]`, `{10**30: x}[Decimal(10)**30]`.
  `Fraction.__eq__` returns NotImplemented for an unknown operand (so
  `Fraction(1, 2) == Decimal("0.5")`, through Decimal's reflected `__eq__`).
- `dataclass(slots=True)` rebuilds the class with `__slots__` (CPython's
  `_add_slots`, `_get_slots`; frozen ones get `__getstate__`/`__setstate__`).

### Modules, imports, sys
- **`sys.modules`** is the engines' registry as a real dict
  (`sysModulesValue` / `sys_modules_value`, made at `import sys` or first
  `__import__`): every module registered afterwards is put in it
  (`noteModule` / `note_module`), and an import first asks it (`syncModule` /
  `sync_module`): a name deleted there is loaded again, a value assigned
  there is what `import` binds (any object: `from m import x` reads its
  attributes). `sys`, `os`, `math`, `builtins` (lib/builtins.ny) and
  `__main__` (the prelude's `_NyMainModule`, the program's globals read
  through it) are in it. `os` is one module now (it was made anew by each
  import, each with its own environ snapshot).
- **Relative imports** (`from . import a`, `from .m import x`, `from ..pkg
  import y`, `from ... import z`) were a syntax error - the standard
  library's packages import absolutely for that reason. The parser keeps the
  leading dots (`.` `..` `...` tokens) in the module's name
  (`Parser::importStmt`); both engines resolve it when the statement runs
  with CPython's `_calc___package__` / `_resolve_name` over the importing
  module's `__package__` (else `__name__`, `__path__`) -
  `resolveRelativeImport` / `resolve_relative_import` - and CPython's two
  ImportErrors ("attempted relative import with no known parent package",
  "... beyond top-level package"); the rest is the absolute import.
- Module files get `__package__` and packages `__path__`; `sys.path` is a
  list the engines search (after the importing file's directory; the main
  script's directory is searched from exec'd code too, CPython's
  `sys.path[0]`).
- **`__import__`** (prelude: CPython's level/fromlist/package rules and
  messages) over `_ny_import_module` (an `import name as _ny_m` exec'd into a
  dict); **`lib/importlib/`**: `import_module`, `reload` (the file run again
  in the same module object - `_ny_module_exec`), `invalidate_caches`;
  `util` (`find_spec` - meta-path finders a program installs, the builtin
  modules, the files `import` would find - `module_from_spec`,
  `spec_from_file_location`, `spec_from_loader`, `resolve_name`,
  `LazyLoader`, `decode_source`; `cache_from_source` raises as CPython does
  without a cache tag); `machinery` (`ModuleSpec`, `SourceFileLoader`,
  `PathFinder`, `BuiltinImporter`, `NamespaceLoader`, `FileFinder`,
  `SourceFileLoader.get_code`, suffixes); `abc`; `resources` (`files`,
  `as_file` and the 3.11 functional API). **`lib/pkgutil.ny`**
  (`iter_modules`, `walk_packages`, `get_data`, `resolve_name`,
  `get_importer` - a FileFinder for a directory when no `sys.path_hooks`
  entry claims it - `iter_importers`, `get_loader`/`find_loader`,
  `extend_path`) and **`lib/runpy.ny`** (`run_module` with `alter_sys`,
  `run_path` for a file or a directory with `__main__`; CPython's messages)
  over them. New
  natives (both engines): `_ny_modules`, `_ny_module_new`, `_ny_module_exec`,
  `_ny_find_module`.
- VM: `import sys` / `math` / `os` bound the module among the globals,
  whatever the scope (`define_*_module`): a module's `del sys` removed the
  program's, and `exec("import math as m", ns)` put `m` in the globals; they
  are bound in the importing scope now (`define_var`). The interpreter's
  `import math` put `PI`/`E` into an exec namespace (now only into the
  program's own scope).
- **sys**: the prelude's `_ny_sys_extend(sys)`, called by both engines when
  they make the module: `version_info` (the language level the standard
  library follows, 3.12, as a struct sequence - Nython's own 0.2.1 is
  `sys.implementation.version`, `implementation.name == "nython"`, as PyPy
  does), `hexversion`, `hash_info` (CPython's numeric hash: modulus 2**61-1,
  inf 314159; str hashes are FNV), `float_info`, `int_info`, `flags` (from
  the command line: `-O`, `-i`, `-q`, `-E`, `-s`, `-S`, `-b`),
  `get/setrecursionlimit` (one limit both engines check -
  `nyrt::recursion_limit`; the interpreter keeps its margin of 100 below it
  and stops at the native stack past the default depth), `getsizeof`
  (CPython 3.11's sizes for the builtin types, `__sizeof__` + GC header
  otherwise), `intern`, `path`, `meta_path`/`path_hooks` (not consulted by
  the import statement), `builtin_module_names`, `orig_argv`,
  `getdefaultencoding`/`getfilesystemencoding`, `maxunicode`, `prefix`/
  `exec_prefix`/`base_prefix`/`base_exec_prefix` (the directory holding
  `lib/`), `platlibdir`, `get/setswitchinterval` (the GIL's hand-over
  interval, settable now: `nyconc::set_switch_interval`, kept in whole
  microseconds as CPython). `sys.modules["os.path"]` is `os.path`.
- **`sys.excepthook`** / `sys.__excepthook__`: the default prints the
  traceback on the current `sys.stderr`; a program's own hook is called for
  an uncaught exception instead of the engines' report (the prelude's
  `_ny_format_uncaught` calls it and gives None; then main.cpp's
  `report_uncaught_string(s, hooked)` and the VM's `print_uncaught_traceback`
  print nothing more - the status stays 1, `--trace` still records it). A
  hook that raises: CPython's "Error in sys.excepthook:" ... "Original
  exception was:".
- **`__debug__`** is True; **`-O`** makes it False and the parser drops
  `assert` statements (`-OO` keeps docstrings).
- `locals()`/`globals()` list a program's dunder-named variables (`__x__`,
  `__all__`); the engines' own names and the parser's temporaries stay out
  (`nyrt::user_dunder_name`).
- **`os.environ`** is the prelude's `_NyEnviron` (`os._Environ`): one object
  for every import, setting/deleting/pop/update/clear call putenv/unsetenv so
  `os.getenv` and child processes see them; `os.environb` on POSIX;
  registered as a MutableMapping.
- **Prelude code resolves the real builtins** whatever a program rebinds
  (`list = 5` at top level broke `A.mro()`, every lazily loaded mirror chunk,
  str.translate...). Interpreter: the prelude runs in `prelude_ctx_` - it
  shares the global map while it loads (the engine reads its names there),
  then gets a copy (`splitPreludeScope`); mirror chunks run there and copy
  the names they add to the globals. VM: prelude and mirror code is tagged
  (`VMCode::prelude_code`) and does not see the main program's frame. The
  slots chunk's `_ny_b_*` aliases are gone.
- **`threading._register_atexit`**: callbacks run when the program ends,
  before the non-daemon threads are joined (`runThreadingAtexit` /
  `run_threading_atexit` before `nyconc::join_nondaemon_at_exit`), then
  atexit's. `ThreadPoolExecutor` uses it with non-daemon workers, as CPython
  3.9+.

### Strings
- `str.maketrans` (all three forms) and `str.translate` (any mapping; None
  deletes, an int or a str replaces; CPython's messages): the prelude's
  `_ny_str_maketrans` / `_ny_str_translate`, reached from both engines'
  str method dispatch. (`bytes.maketrans`/`translate` were there.)
- **`${...}` in string literals**: the parser turns a literal holding `${`
  into an f-string (and the interpreter re-interpolated `${name}` at run time
  in any string node - the VM did not: `f"${{x}}"` differed). The rule now:
  `${...}` interpolates in Nython's own string forms - backtick template
  strings everywhere, and ordinary quoted strings in Nython source; it is
  Python's text in raw strings, bytes and f-strings, and in every quoted
  string of a file that declares itself Python: a `.py` file, a `# nython:
  module` library module, or a file with `# nython: python` in its leading
  comment block (`Lexer::python_strings`, the tokens made with
  `TokenClass::Default`). exec/eval code is Nython source. Backward
  compatible: the only `${` interpolation in the repository is vm_audit24's
  (a plain .ny file); the library modules carrying `${` were working around
  it. The run-time re-interpolation is gone (the engines agree).

### Also
- Library paths no longer print as `build/../lib/...` (`nyrt::library_dirs`
  names the parent's `lib/` directly).
- Interpreter: a lambda a module or namespace holds, called as a method
  (`m.f = lambda: 1; m.f()`; `sys.getdefaultencoding()`), raised
  AttributeError - `callMethod`'s namespace path ran only `def` functions.
- A class attribute that is not callable (`label = "text"; C.label()`)
  raises TypeError "'str' object is not callable" (it gave none).
- A bare `import missing` raises ModuleNotFoundError "No module named
  'missing'" with `e.name` (a quoted `import "path"` keeps its message).
- The two crash reproducers run clean under valgrind.

### Not done
- `P(1, 2)` for a class with no `__init__`/`__new__` is not a TypeError
  (CPython: "P() takes no arguments"); the default instance `repr()` stays
  `<P instance>`.
- The import statement does not consult `sys.meta_path` / `sys.path_hooks`
  (importlib.util.find_spec does); no `importlib.metadata`, zipimport, frozen
  or extension modules; `sys.modules["__main__"]` reads the program's
  globals but setting an attribute on it does not create a global.
- `globals()` is a copy: `globals()[name] = v` does not create a global
  (and `vars(sys.modules["__main__"])` does not list the program's).
- Imported modules have no `__spec__` / `__loader__` (importlib.util.find_spec
  derives a spec from `__file__`); no `sys.getrefcount`,
  `sys.stdlib_module_names`; the prompt does not call a replaced
  `sys.displayhook`.
- `os.fspath`, `os.fsencode`, `os.fsdecode` are missing (pkgutil carries
  its own); `surrogateescape` is not a codec error handler yet.
- `except ... as e` leaves `e` bound after the clause (CPython deletes it).
- A Decimal/Fraction key equal to a float is stored as that float: iterating
  the dict gives the float back (CPython keeps the first key object).

---

### Verified after merging onto the branch head (66d7877)
- Linux, both engines: the sweep 419 runs, 0 not ok; vm_audit96 116 on the
  interpreter and the VM, 115 under python3 (one Nython-only check);
  vm_audit24 (the only `${...}` user), 44, 77, 84, 88, 91-94 still pass;
  `ide_e2e` 390/390; `ide_lint`, `ny_classcheck`, `cbp.py check` clean;
  `ide_memprobe --check` passes. The merge had no conflicts.

## 0r3. Round 79, part A — `sys.settrace`/`setprofile`, pdb and the profilers, "Why?" in the debugger (vm_audit91, vm_audit92)

`examples/vm_audit91.ny` (104 checks) passes on the interpreter, the VM and
python3.11 (101 under 3.13: the pure-Python `profile` checks are skipped on
3.12+, where CPython's own `profile.py` sees a stray "return" event after
`sys.settrace` was used); where 3.11 and 3.13 differ (f_locals write-through,
pdb's help layout and function-breakpoint line, trace's layout) Nython
follows 3.13 and the test accepts the running python3's answer.
`examples/vm_audit92.ny` (49, Nython-only) checks `text_defuse` and the
slicer over a real `nython --trace` recording.

### Tracing and profiling hooks, both engines
- `sys.settrace/gettrace/setprofile/getprofile`, `threading.settrace/
  setprofile/gettrace/getprofile` (threads started afterwards); events
  call/line/return/exception (trace) and call/return/c_call/c_return/
  c_exception (profile) with CPython 3.11's rules: the global function's
  result is the frame's `f_trace`, `f_trace_lines`, generators get call on
  each resume and return on each yield, a hook runs with hooks off and one
  that raises is unset with the exception continuing in the traced code,
  calling a type (`str`, `zip`...) makes no c_call.
- **Cost when unused**: one thread-local byte (`nytrace::t_hooks`,
  `include/NyPyTrace.hpp`) tested per statement (interpreter
  `noteStatement`) / per instruction (VM: the same test now also covers
  the old `NY_VM_TRACE` dump) and per call. Measured against 9bc58e4
  (minimum of 9-15 alternating runs): interpreter -1.4%..+1.5%, VM
  -0.1%..+2.7% (the mixed benchmark's +2.6% is a little above the 2% aim;
  medians -2.9%..+3.6% on a shared machine).
- Interpreter: `pyHookCall`/`pyEv*` (call, line, return, exception once per
  frame, handled, leave), line events for `for`/`while` headers on each
  repetition, each `elif` test reached, an except clause's own line, the
  `with` line on exit; `runBodyHooked` only when a hook is set;
  `src/NyGen.cpp` generator events. **exec/eval code now runs in a frame
  of its own** (`runSnippetFrame`, as on the VM), hooks or not.
- VM: a line-start map per code object (a statement's first instruction,
  not a docstring; `elif`, except handlers, the with exit; `try:` gets a
  NOP line start and `pass` compiles to a NOP), CPython 3.11's line rule (a
  line start on a new line or any backward jump), `run_frame_hooked`,
  `vm_end_line` (an implicit return or a finally's re-raise reports the last
  line that ran), c_call at `CALL_KW`/`CALL_FUNCTION`/`CALL_METHOD`/`PRINT`.
- **PEP 667**: `frame.f_locals` of a running function is a write-through
  `_NyFrameLocals` proxy (pdb's `!x = 5` changes `x`); module frames give
  their globals. Assigning `f_lineno` raises ValueError (no jumps).
- Parser (both engines): elif and except clauses carry their own line (it
  was the if's/try's, wrong in tracebacks too); `async @staticmethod`
  works; classes have `__qualname__` (`Outer.Inner`, `f.<locals>.C`);
  `eval("a if c else b")` (was a SyntaxError); `inspect.signature` keeps a
  receiver named `this` on the VM.

### Modules (`lib/`)
`bdb` (CPython's Bdb/Breakpoint), `pdb` (every command, aliases, display,
`commands`, `!` statements, post-mortem, `.pdbrc`/`-c`, `nython -m pdb`;
`breakpoint()` -> `sys.breakpointhook` honouring `PYTHONBREAKPOINT`),
`cProfile` (`_lsprof`'s algorithm: recursion counts `29/3`, callers, its
builtin labels, overhead subtracted), `profile`, `pstats` (every report and
sort; `SortKey`), `timeit` (+ CLI), `trace` (count/trace/listfuncs/
trackcalls, `.cover` files; executable lines from `text_defuse`), `cmd`,
`code`, `codeop`, `reprlib`; `threading` gained the hook setters. `-m
cProfile`, `-m profile`, `-m trace`, `-m timeit` and `-m pdb` were compared
with python3.13's output.

### "Why?" questions in the IDE's debugger (the innovation)
- `lib/ide_debugger.ny`: **dynamic backward slicing over the `--trace`
  recording** joined with static def/use from the real parser.
  `why_value(name, at)` follows each read back to the statement that last
  wrote it, the test it ran under and the call that passed a parameter;
  `why_not(file, line)` names the controlling test that never went that
  line's way (with its last values), or the function nobody called, or the
  step after which execution left the block. After Ko & Myers (the
  Whyline, ICSE 2008), Agrawal & Horgan (PLDI 1990), Korel & Laski (1988),
  Ferrante/Ottenstein/Warren's PDG (1987).
- `text_defuse(source)` (`src/builtins/text.cpp`, both engines): per line
  the statement kind, reads, writes, controlling tests (innermost first,
  with the branch taken), the enclosing function, a docstring flag.
- IDE: `nython.debug.whyValue` / `nython.debug.whyNot` (Run menu, palette),
  a "?" button and context entry on Variables rows, "Why Didn't This Line
  Run?" in the editor's context menu while debugging; a WHY section in Run
  and Debug whose rows move the replay to their step (built once per
  question; the painter only draws). `tools/ide_e2e.py` scenario
  `debug-why` (17 checks).

### Not done
- pdb `jump` (frames cannot change line on either engine).
- Class bodies and comprehensions have no frames (no call/return for them;
  3.12+ counts comprehension lines per item); only the matching except
  clause gets a line event (CPython reports each clause tested); await
  points of a coroutine get no call/return events.
- `--trace` records no step when a `while` test is re-evaluated, so
  `why_not` sees only its first evaluation; a `for` header's next item is
  credited to the header.
- `dump_stats` writes JSON lines (not marshal) and trace's `-f` counts file
  is JSON (not pickle): no file exchange with CPython.
- codeop differs from CPython on `'a b'` and `'try:\n x\n'`.
- Found, worked around: `os.environ` is a snapshot that does not reach the
  process environment; `exec("import math as m", ns)` binds `m` in the
  globals on the VM (`define_math_module`) and copies math's members into
  `ns` on the interpreter; `locals()` leaves out user variables with dunder
  names; cProfile labels natives `builtins.X`; library paths print as
  `build/../lib/...`.

### Verified (merged onto parts B and C)
- Linux, both engines: the sweep 417 runs, 0 not ok; vm_audit91 104 on the
  interpreter, the VM and python3, vm_audit92 49 on both engines, and
  vm_audit93/94/95, 44, 88, 89 still pass; `ide_e2e` 390/390 (the new
  `debug-why` scenario included); `ide_lint`, `ny_classcheck`, `cbp.py
  check` clean; `ide_memprobe --check` passes.
- The merge conflicted only in the lexer, where parts A and C made the same
  comment-line fix.
- Windows 64-bit (under Wine): built, `pe_unwind_check` clean; the sweep 417
  runs, 415 ok and vm_audit92 timing out on both engines. After two fixes
  vm_audit92 passes 49/49 under Wine on both engines (the sweep was not run
  again): it launched
  `./ny_test` (the Linux build) instead of `sys.executable` and hung; and
  **the debugger kept a recording's file names JSON-escaped** (`C:\\\\users`
  with doubled backslashes - `_add_step` reads them from the raw line without
  decoding), so every per-file question (`why_not`, breakpoints by file)
  missed on Windows paths. Each distinct name is now decoded once, when first
  seen.
- AArch64 (qemu-user): vm_audit91 (settrace/pdb/profilers), 88, 89, 90, 56,
  95 (decimal), 49, 67 pass on both engines;
  zlib, pickle, array and zipfile give byte-identical output to x86 on both
  engines (a script compressing at every level/wbits with streaming flushes
  and the optimal parse, CRCs, pickles at every protocol). Suites that spawn
  `sys.executable` (46, 92, 93's CLI part, 94's ProcessPoolExecutor) cannot
  run under qemu-user here: the container has no binfmt_misc, so the AArch64
  binary cannot be executed directly.

## 0r2. Round 79, part C — text formats and utility modules (vm_audit94, vm_audit95)

`examples/vm_audit95.ny` (decimal: ~70 API checks and 1,981 vectors in the
dectest style - add, multiply, divide, divide_integer, remainder(_near),
quantize, the rounding modes, sqrt, exp, ln, log10, power, fma, the logical
operations - at precisions 9, 16 and 34, each with the **result and the
flags** CPython's C decimal gives, `tools/gen_decimal_vectors.py`) passes
2050/2050 on the interpreter, the VM and python3. `examples/vm_audit94.ny`
(the other modules; generated by `tools/gen_vm_audit94.py` from
`tools/vm_audit94_spec.py`, every expected value computed by python3 - rerun
the generator after editing the spec) passes 162 on both engines and 152
under python3 (the other 10 test Nython-only additions).

### Modules (`lib/`; most are CPython 3.11's pure-Python code adapted, so outputs match)
- `decimal` (`_pydecimal`'s algorithms, looking like the C module from
  outside: C's trap messages `[<class 'decimal.ConversionSyntax'>]`,
  boolean flags/traps, libmpdec's signal order in the Context repr; the
  context per thread and per asyncio task through contextvars).
- `difflib` (byte-identical to CPython, HtmlDiff included). **Nython-only**:
  `patience_diff` / `histogram_diff` opcodes (Bram Cohen's patience diff;
  git/JGit's histogram diff), a `DiffMatcher`, and `unified_diff`/
  `context_diff(..., algorithm=)` - a function inserted between two others
  comes out whole instead of split at a shared `}`; the default output is
  CPython's.
- `shlex`, `configparser`, `graphlib`, `ipaddress`, `mimetypes` (reads
  `/etc/mime.types` as CPython; no registry, no CLI).
- `tomllib` (CPython's parser, tomli, MIT) plus **Nython-only**
  `dumps()`/`dump()` that `loads()` reads back.
- `html` (`escape`/`unescape` with the full HTML5 table generated from
  python3 by `tools/gen_html_entities.py`, `html.parser`, `_markupbase`).
- `xml`: `xml.parsers.expat` is **a new XML parser written in Nython**
  reproducing expat's callbacks, error codes, messages and positions
  (checked against pyexpat): incremental, namespaces, internal-subset
  entities, ATTLIST defaults; over it ElementTree/ElementPath (iterparse,
  XMLPullParser, C14N) and `xml.dom.minidom` (expatbuilder). No `xml.sax`,
  pulldom, external entities or DTD validation.
- `contextvars` (complete): the current context is an immutable mapping
  the runtime keeps per thread and per task (copying a context copies one
  reference); each asyncio task starts in its creator's copy (PEP 567), and
  `asyncio.to_thread` runs in a copy of the caller's.
- `concurrent.futures`: CPython's `_base` and `ThreadPoolExecutor` (workers
  are daemon threads drained by an atexit handler - Nython joins non-daemon
  threads before atexit); `ProcessPoolExecutor` with real worker processes
  (`_procworker.ny` over subprocess pipes, the main program re-run as
  `__mp_main__` like spawn), calls carried in a JSON format (plain data,
  module-level functions and classes, instances by `__dict__`, exceptions;
  anything else fails the future with PicklingError) - written before
  pickle existed (part B); switching it to pickle is follow-up work.
- `zoneinfo` (CPython's pure-Python code: TZif v1-v3, the POSIX footer,
  `fold`, caches, TZPATH; tests skip when the zone database is missing; no
  tzdata package fallback).

### Engine changes
- **Per-task contextvars** (`src/NyConc.cpp`): `Task::ctx_data`, copied
  from the creator's `tls["__ny_ctx_data"]` in `new_task_locked()` and
  moved into the task's record in `grant()`.
- **Modules are live namespaces** on both engines (`runModuleFile` /
  `load_module_file`: the module's scope is the namespace map, as
  `exec(src, ns)`): a module function's `global` rebinding is seen by
  importers and `mod.x = v` is seen by the module (this closes part B's
  `zipfile.ZIP_FILECOUNT_LIMIT` item).
- **str methods' keyword arguments** were dropped on both engines
  (`"a b c".split(maxsplit=1)`): `nypy::str_kw_slot()` (CPython's slots
  and messages) in both str method paths.
- **Lexer** (both engines): implicit concatenation with f-strings
  (`"a" f"{x}"`); a comment-only line no longer opens or closes a block;
  `x--y`/`x++y` after an operand are `x - (-y)` / `x + (+y)` (`_pydecimal`'s
  `a--n//a>>1` had been a postfix decrement, making `ln`/`log10`/`**` wrong).
- **Parser**: `except _Stop:` is a type (judged after leading underscores),
  not Nython's catch-all binding.
- Interpreter `evalFor` uses the sequence protocol (`__getitem__` until
  IndexError); VM `vm_eq` compares dict values with `vm_eq`
  (`{"d": date(...)} == {"d": date(...)}` was false).
- Libraries: `urllib.parse.urlparse` splits `;params` only for
  `uses_params` schemes; `WeakValueDictionary`/`WeakKeyDictionary.clear()`.

### Found, not fixed
- Interpreter segfaults: `__class_getitem__ = classmethod(GenericAlias)`
  then `A[int]`; a generator's bound `__next__` stored as a class attribute
  and iterated.
- VM: `iter([..]).__next__` read as an attribute raises AttributeError;
  `import sys` then `del sys` inside a module gives NameError.
- Missing: `__debug__`, `__import__`, `sys.hash_info`, `sys.modules`,
  `os.path.splitdrive`, `os.fspath`, `posixpath`, `str.maketrans`
  (`str.translate` with None values fails); a class does not inherit
  `object.__init__` as an attribute (`Base.__init__(self)` fails when Base
  has none).
- `ValueError.__module__` is `"__main__"`; the interpreter's
  `eval("name", {})` still sees the program's globals; a Decimal and an
  equal float are two set members.
- Syntax: an expression in an except clause (`except self._error:`);
  `"${...}"` in any string literal is Nython interpolation.
- Nython joins non-daemon threads before atexit runs (no
  `threading._register_atexit`).

### Verified (merged onto part B)
- Linux, both engines: the sweep 413 runs, 0 not ok; vm_audit93 176,
  vm_audit94 162 (152 under python3), vm_audit95 2050 on the interpreter,
  the VM and python3; `ide_e2e` 373/373; `ide_lint`, `ny_classcheck`,
  `cbp.py check` clean; `ide_memprobe --check` within its thresholds.
- The merge had no conflicts.
- Windows 64-bit (MinGW from `nython.cbp`, under Wine): built (with the new
  `nyzlib.cpp`), `pe_unwind_check` clean, the sweep 413 runs, 0 not ok -
  after one fix: `os.path.commonpath` on Windows put the root separator
  before the drive (`["C:\\a\\b", "C:\\a"]` gave `\\C:\\a`), so tarfile's
  extraction filters judged every member "outside the destination". It is
  now CPython's `posixpath`/`ntpath.commonpath` (drive and root split off
  first, Windows comparing case-insensitively, `..` kept, CPython's
  ValueErrors), compared with python3's `posixpath` and `ntpath` on both
  engines; vm_audit46 checks it. vm_audit93's three Linux-only expectations
  now follow CPython on Windows (no execute bits in `st_mode`; a 32-bit C
  `long` overflowing first in `array("i", [2 ** 40])`; the filters'
  `!r`-quoted paths).

## 0r. Round 79, part B — zlib, archives, pickle, `__slots__`, `__class__` assignment (vm_audit93)

`examples/vm_audit93.ny` (176 checks) passes on the interpreter, the VM and
python3; every expected value is CPython's, streams/archives/pickles made by
CPython are embedded and read, and (python3 on PATH) CPython decompresses
and reads what Nython wrote.

### DEFLATE, natively (`src/builtins/nyzlib.cpp`, namespace `nyz`)
- No system zlib (the MinGW and 32-bit builds link what `nython.cbp` lists):
  crc32 (slicing-by-8), adler32, crc_hqx; an `Inflater` for raw/zlib/gzip/
  auto streams that resumes on any input chunking (it marks and rolls back
  when input runs out), with zlib's error messages; a `Deflater` after
  zlib's algorithm (its level table and lazy matching, length-limited
  Huffman codes by package-merge, `scan_tree` run-length coding, its choice
  of stored/fixed/dynamic blocks, strategies, every flush mode, preset
  dictionaries, `deflateInit2`'s rules). Sizes are within a few bytes of
  CPython's zlib at every level (6 MB of text: level 9 823,642 vs 823,649).
- Reached through the existing hashing bridge (`hash_builtin_names()` /
  `dispatch_hash` forward `_zlib_*`), so both engines have the natives.
- **Innovation, opt-in**: `zlib.compress_optimal(data, iterations=15)` (or
  `compress(..., nython_optimal=True)`), an optimal parse after Zopfli
  (Alakuijala & Vandevenne, 2013): long hash chains with the match length at
  every distance, an entropy cost model re-estimated each iteration, a
  shortest-path parse and block splitting. Standard DEFLATE (CPython reads
  it), 5-10% smaller than level 9 (word text 21,298 -> 19,773; Nython
  source 13,432 -> 12,726).

### Modules (`lib/`)
- `zlib` (Python's API: `compress`/`decompress`, `compressobj`/
  `decompressobj` with every parameter and `zdict`, `copy`, flush modes,
  `unconsumed_tail`/`unused_data`/`eof`, `crc32`/`adler32`, `error`),
  `binascii` (the 3.11 module), `gzip` (`GzipFile`, multi-member,
  `compress(mtime=0)` byte-identical to 3.11), `zipfile` (r/w/x/a, STORED
  and DEFLATED, ZIP64, data descriptors, sanitized extraction, ZipCrypto
  reading, `zipfile.Path`, `-m zipfile`), `tarfile` (ustar/gnu/pax read and
  write, `:gz` and stream modes, PEP 706 filters, `-m tarfile`), `pickle`
  (after `_pickle.c`: **byte-identical to CPython for builtin values at
  protocols 0-5**, every opcode loaded, the reduce protocol with
  `__getnewargs(_ex)__`/`__getstate__`/`__setstate__`/slot state,
  `dispatch_table`, `reducer_override`, persistent ids, protocol-5
  out-of-band buffers), `copyreg`, `array` (every typecode, CPython's
  overflow messages, pickling). `copy`, `functools.partial` and `weakref`
  follow the new protocols.

### Engines
- `object` has `__reduce_ex__`, `__reduce__`, `__getstate__` (CPython's
  `reduce_newobj`/`object_getstate` in Nython, `copyreg._ny_*`); a class
  without an explicit base reaches them through the `object` fallback
  (`findClassMember` / VM `class_lookup`).
- **`__slots__`**: the prelude's `#@ slots` mirror chunk, loaded the first
  time a class namespace has `__slots__` or `__class__` is assigned:
  `_NyMemberDescriptor` (`member_descriptor`, `<member 'x' of 'C' objects>`)
  per slot, `_ny_init_slots(cls)` doing `type.__new__`'s checks (CPython's
  errors), flags (`_ny_mark_slots`: no `__dict__`, no weak references).
  Dictless instances reject other names, have no `__dict__`/`vars()`, slot
  values stay out of `__dict__`. The chunk calls builtins only through
  `_ny_b_list`... (a program that rebinds `list` broke it).
- **`obj.__class__ = Other`**: CPython's three errors (`_ny_class_layout`,
  `_ny_set_class`), then `_ny_switch_class`: the interpreter retags the
  instance (its class is keyed by identity); the VM, whose values carry
  their class name, rewrites every value pointing at that instance (stack,
  frames, globals, class variables, every container the collector tracks -
  `vmgc::for_each_value`). `del obj.__class__` is a TypeError.

### Not done
- ~~After `zipfile.ZIP_FILECOUNT_LIMIT = 3` from outside, the module's own
  code still sees the old value~~ - modules are live namespaces since part C
  (§0r2).
- Instances of a class without an explicit base still miss most `object`
  members (`hasattr(P(), "__setattr__")` is false, `P.__new__` missing);
  only the three pickle-protocol names were added to the fallback.
- Prelude mirror chunks resolve builtins in the program's globals: only the
  slots chunk is protected from a program rebinding `list`/`dict`/...
- `dataclass(slots=True)` sets `__slots__` without rebuilding the class.
- pickle memoizes str/bytes by value (valid, different only for equal
  strings built at run time); sets are written in insertion order; no
  `pickletools`; no memoryview (`PickleBuffer` wraps bytes/bytearray) -
  **done in round 84, §0x** (a PickleBuffer holds a view).
- zipfile: no bzip2/lzma (RuntimeError as CPython without them), no writing
  of encrypted members, AES, multi-disk; tarfile: no bz2/xz, no chown,
  device/FIFO members not created.
- Missing elsewhere, found here: `sys.version_info`, `__import__`, codecs
  `surrogatepass`/`cp437`, the `stat` module, `os.chown/mkfifo/getuid/
  fspath/scandir`, `os.path.splitdrive/lexists`; builtin exception classes
  report `__module__` `"__main__"`; on the VM `f_builtins["len"] is len` is
  false.
- The VM's class switch misses a reference held only on the native side.

### Verified
- At the agent's c9b4853 (identical code to the merge; the branch head had
  added one doc line): the sweep 409 runs, 0 not ok; `ide_e2e` 373/373;
  `ny_classcheck` and `cbp.py check` clean.
- After merging: vm_audit93 176/176 on the interpreter, the VM and python3;
  vm_audit53, 55, 64, 85, 86, 88, 89, 90 and v5_spec_compliance_test pass on
  both engines.

## 0q. Round 78, part 1 — lazy `range`, live dict views, lazy builtins (both engines)

`range()` and `d.keys()/values()/items()` returned lists, and `zip`/`map`/
`filter`/`enumerate`/`reversed` over lists returned lists (lazy only over
generators): `range(10**12)` exhausted memory, `d.keys() & other` was
impossible, `next(zip(a, b))` failed. They are Python's types now.
`examples/vm_audit90.ny` (65 checks on both engines, 63 under python3 - two
are Nython-only) pins them.

### Where it lives
- **The types are prelude classes** (`include/NyPrelude.hpp`): `range`
  (CPython's `rangeobject.c`: lazy, ints of any size, `len` with
  OverflowError past sys.maxsize, negative indices, slicing to a range, O(1)
  `in` for ints and `==` iteration otherwise, `index`/`count` with CPython's
  messages, `==`/`hash` by the sequence described, repr, read-only
  `start`/`stop`/`step`, `bool`, `reversed`), `dict_keys`/`dict_items`
  (sharing `_NyDictSetView`: `& | - ^` and reflected forms returning sets,
  comparisons with sets and views, `isdisjoint`, `(k, v) in d.items()`,
  unhashable), `dict_values` (identity `==`, hashable), `mappingproxy` (a
  view's `.mapping`; `lib/types.ny`'s `MappingProxyType` is it now). The
  methods are the general case - big ints, slices, set algebra.
- **The engines make them natively and take native paths**
  (`include/NyRange.hpp`, shared arithmetic in uint64 so `stop - start` of
  two int64s cannot overflow): `range(...)` is intercepted in
  `instantiateClass` / `instantiate` (`makeRange` / `make_range_val`: the
  argument checks of CPython's `range_new`; the class has no `__init__`);
  `d.keys()` makes the view holding the dict in the field `_ny_mapping`
  (`makeView` / `make_view`). For a range of 64-bit ints and for views:
  iteration, `len`, `in`, `r[i]`, `list()`/`tuple()`/`set()`/`sorted()`/
  `min`/`max` (materialised natively), `sum(range)` in O(1) (the arithmetic
  series, exact - `sum(range(10**9))` is instant: the allowed innovation).
  A range past 64 bits takes the prelude's methods and iterates through
  `_ny_longrange` (a generator: CPython's `longrange_iterator`).
- **Iterators**: `range_iterator`, `dict_keyiterator`/`valueiterator`/
  `itemiterator` and the `dict_reverse*` ones, `list_reverseiterator`,
  `reversed` (interpreter: `nygen` cursors `RANGE`/`DICT`/`REVSEQ`; VM:
  native generators). A dict iterator re-checks the dict's size each step:
  "dictionary changed size during iteration", sticky as CPython's
  (`GenState::sticky` on the VM). `NyOrderedMap` has `slot_end()`/
  `slot_at(n)` for these walks (a slot number survives growth; a compaction
  only follows an erase, which changes the size). `for k in d` is live too
  now (it walked a snapshot).
- **Loops make no object**: `for x in range(...)` and `for k, v in
  d.items()` (keys/values; the receiver a name or `name.field`) are
  recognised syntactically - the interpreter's `evalFor` counts or walks the
  dict's slots in place (and binds `k, v` without making the pair), the VM
  compiles them to the new `FOR_PREP` opcode, and `GET_ITER` directly
  before `FOR_ITER` gives a range or dict an in-place iterator (an
  `ITERATOR` with `b` set and no item vector: `stack_range_iter`/
  `stack_dict_iter`, advanced by `FOR_ITER`, never visible to the program).
  Anything else - `range` rebound, a receiver that is not a plain dict - is
  called as written.
- **Lazy builtins**: `zip`/`map`/`filter`/`enumerate` are lazy over every
  iterable (`nygen::builtin`, the VM's `gen_lazy_builtin`), `zip(...,
  strict=True)` with CPython's messages; `reversed()` follows Python's
  protocol (`__reversed__`, else `__len__`+`__getitem__`, else "'set' object
  is not reversible"); `len(zip(...))`/`zip(...)[0]` name the type.
- **Kept for Nython programs**: `a..b` is still a list (the VM compiles it
  to `_ny_range_list`, the interpreter's `evalRange` semantics, step -1
  when b < a); `d.entries()` and the flat `keys(d)`/`values(d)`/`items(d)`
  are lists; a range or a view given to one of Nython's own flat natives
  (`random_sample`, `json_encode`, string and tensor functions...) arrives
  as the list of its values (`nyrt::takes_range_objects` lists the builtins
  that see the object: Python's and the protocol helpers; interpreter
  `callBuiltin`, VM builtin bridge in `main.cpp`). The legacy `reduce`
  accepts any iterable (`reduce(f, map(...))` gave none).
- `collections.abc` registers `dict_keys`/`dict_items`/`dict_values`/
  `mappingproxy`; the runtime type table (`nyrt::runtime_type`) knows the new
  iterator names.

### Measured breakage and the decision
Making all of it Python's (no compatibility extension) broke 29 of the
swept files, identically on both engines (58 of 403 runs): 23 legacy test
suites that asserted the old results (`str(range(5)) == "[0, 1, 2, 3, 4]"`,
`map(...) == [...]`, `len(enumerate(...))`, `enumerate(xs)[0]`,
`range(1, 11).filter(...)`), and library code indexing a view (`ks =
d.keys(); ks[i]` in nytorch's module/convnets/tensor, the IDE's inspector,
workbench and debugger commands; `keys(d)` in stdlib/aiagent through the
flat builtin). Every one was in this repository and a mechanical fix
(`list(...)`), so the callers were migrated rather than adding an extension
(`d.keys()[i]` on a view would make indexing loops quadratic and views look
like sequences to duck-typing code; an index materialising a lazy zip would
consume it). `reduce` over a lazy `map` and the flat natives given a range
were real regressions and were fixed in the engines (above).

### Speed (CPU seconds, interleaved runs of the round-77 and round-78 binaries)
| bench | interp before | interp after | VM before | VM after |
|---|---|---|---|---|
| `for i in range(10**7): s += i` | 29.8 | 10.0 | 21.7 | 5.55 |
| ... its peak RSS | 3,351 MB | 18.7 MB | 4,238 MB | 23.1 MB |
| 300k × `for j in range(3)` | 2.05 | 1.15 | 1.60 | 0.74 |
| 50k × (`for k, v in d.items()` + `for k in d.keys()`), 20 keys | 4.08 | 2.22 | 2.56 | 2.17 |
| empty program | 0.04 | 0.05 | 0.10 | 0.08 |

At the end of the round: `tools/sweep.py` 403 runs, 0 not ok;
`tools/ide_e2e.py` 373 passed, 0 failed; `tools/ide_memprobe.py --check`
0.00 KB per frame/key/scroll/hover/split; `tools/ide_lint.py` clean.

### Not done
- A range's `vars()` lists start/stop/step (CPython: no `__dict__`);
  `type(r).__mro__` of a keys/items view includes `_NyDictSetView`.
- `object.__new__(range)` makes an empty range object (CPython refuses).
- Iterating a bigint range gives a `generator` (`_ny_longrange`), not a
  `longrange_iterator`.
- On the interpreter a comprehension over a dict view (`[k for k in
  d.items()]`) goes through a lazy iterator object (the VM's comprehensions
  use GET_ITER/FOR_ITER and walk in place; a comprehension over `range(...)`
  counts on both).

## 0q2. Round 78, part 2 — frames, weak references, coroutine objects (vm_audit89)

All on both engines; `examples/vm_audit89.ny` passes on both and under
python3 (every expected value is CPython 3.11's; two 3.12-only checks are
Nython-only).

### Frame objects
- `sys._getframe(depth)`, `inspect.currentframe()/stack()/trace()/
  getframeinfo()/getouterframes()/getinnerframes()/getargvalues()`,
  `traceback.extract_stack()/walk_stack()/print_stack()` and a traceback's
  `tb_frame` are real frame objects: the prelude's `_NyFrame` (shown as
  `frame`; `types.FrameType`), made by the engines **only when asked for**
  and kept in the frame's record (`PyFrame::fobj` on the interpreter,
  `CallFrame::fobj` on the VM), so the same object comes back while the
  call runs. Fields: `f_code` (`_NyFuncCode`: co_name, co_qualname,
  co_filename, co_firstlineno, co_varnames = the parameters,
  co_argcount...), `f_lineno`, `f_lasti` (approximate: the VM's
  instruction offset, the interpreter's line x 2), `f_locals` (what
  `locals()` gives there - a method's `self` included on both engines now;
  for a module frame its globals), `f_globals`, `f_builtins`, `f_back`,
  `f_trace`, `clear()` (RuntimeError on a running frame).
- Live vs dead: while the call runs, `f_locals`/`f_lineno` are read from
  the running frame (`_ny_frame_sync`, a new dict each read - 3.13's
  snapshot semantics rather than 3.11's one cached dict) and `f_back` is
  the caller's frame (`_ny_frame_back`). When the call ends, a frame
  object referenced elsewhere keeps its last locals and line and links its
  caller's frame object (as CPython's `take_ownership`); one nobody else
  holds just goes. A call nobody asks about pays one pointer test when it
  ends. Frames on another thread or in a suspended generator show what
  they had when last synced (a generator's is synced when it pauses).
- Generators: `gi_frame` is the generator's real frame (its arguments
  before it starts, the locals it paused at, None once finished); the
  generator keeps it while suspended. `inspect.getgeneratorstate/
  getgeneratorlocals`, `getcoroutinestate/getcoroutinelocals`,
  `getasyncgenstate/getasyncgenlocals` (3.12).
- Tracebacks: each entry holds the frame it passed (`_ny_frame`), with
  its last locals (`traceback.TracebackException(capture_locals=True)`
  shows them). On the interpreter the pending traceback record holds the
  frame objects while an exception unwinds; an exception native code
  catches and drops (a generator's close, `hasattr`, a loop's
  StopIteration) would keep them, so they are dropped at the next
  statement and when `close()` swallows GeneratorExit
  (`tbDropFrames`) - a suspended generator's cycle is still collected.
- `logging`: findCaller walks the real frames (CPython's
  `_is_internal_frame`, stacklevel), `stack_info=True` prints the stack,
  `exception()` the whole traceback, `captureWarnings()` routes warnings to
  the `py.warnings` logger.
- Fixed on the way: `globals()` lacked `__name__`/`__file__`, and the
  dicts `locals()`/`globals()` build stored names raw - a dunder name is not
  a plain dict key (`nypy::key_of_str`), so `globals()["__name__"]` was a
  KeyError (both engines); a lambda in a parameter list took the list's defaults
  (`def f(g=lambda n: n, h=2)` lost h's default - the parser, both
  engines); on the VM `next(it)` dropped the value of the StopIteration
  `__next__` raised.

- Cost (this container, loaded): a caught exception passing two frames
  ~+20% on the interpreter (a frame object per frame it passes, its locals
  copied when the frame ends; the code info is made once per function),
  unchanged on the VM within noise; plain calls unchanged.

### Weak references
`weakref(obj)` (and lib/weakref.ny over it) reaches functions and lambdas,
bound methods, sets and frozensets, classes and instances of builtin
subclasses, with callbacks; int/str/list/tuple/dict/bytes/None keep
CPython's TypeError. Classes live as long as the program here, so a
reference to one is never dead. On the VM a function value got an
identity cell (`VMVal::iter`, made by MAKE_FUNCTION; registered with the
cycle collector the first time the function is weakly referenced or used
as a key, so a function kept only by the key table is freed), and a
reference to a set has its callback run at the next collection
(`weak_polled`; a set has no field to hold a notifier).

### Coroutine objects
- Calling an `async def` gives a `_NyCoroutine` (shown as `coroutine`,
  `types.CoroutineType`; the parser's rewriting builds it:
  `_NyCoroutine(handle, function, name, qualname)`). The runtime still runs
  the int handle (`_ny_coro_h`); the engines read it from the object
  without calling anything (`Engine::coro_handle`), so `await`,
  `asyncio.run`, `create_task`, `gather`, `wait_for` take the objects.
- Driven by hand (`async_coro_drive`, `src/NyConc.cpp`): `send(None)` runs
  the coroutine as a task of a private loop on the calling thread until it
  finishes (`StopIteration(value)`) or reaches a yield of an `__await__`
  generator, whose value `send` returns; `throw`/`close` resume it there
  (GeneratorExit / finally blocks run). What the runtime's own awaitables
  wait for (sleep, tasks, locks) is waited for inside the call - CPython
  would hand the future to the runner instead.
- `await x` where `x.__await__()` is a generator (or an iterator) runs it
  (`_ny_drive_await`): driven by hand its yields reach the runner; in a
  task a bare yield gives the other tasks a turn and a yielded awaitable is
  awaited. `cr_running`, `cr_suspended`, `cr_await`, `cr_frame` (the
  body's frame while paused by hand; a frame at the def line before it
  starts; None once finished), `cr_code`, `__name__`/`__qualname__`,
  `__await__()` (a `coroutine_wrapper`), "cannot reuse already awaited
  coroutine", and `RuntimeWarning: coroutine 'f' was never awaited`
  through `warnings` when one is dropped unawaited (`__del__`; the handle
  is released then). An async call costs ~15 µs more on the interpreter
  and ~8 µs on the VM (the object, and its `__del__`).
- `lib/contextlib.ny`'s async parts awaited only int handles (`_await`);
  `collections.abc` registers the coroutine type as CPython does.
- Async generators are `_NyAsyncGen` (`async_generator`): `__anext__`,
  `asend`, `athrow`, `aclose` return awaitables (`async_generator_asend` /
  `_athrow`) that can also be driven by hand; `ag_running`, `ag_frame`,
  `ag_code`, `ag_suspended`. `async for` still reads the generator
  directly. `asyncio.sleep()` is a coroutine now.

### New natives (both engines)
`_ny_frame_get(depth)`, `_ny_frame_sync(f)`, `_ny_frame_back(f)`,
`_ny_frame_globals(f)`, `_ny_builtins_dict()` (NythonExecutor::frameGet ...
/ VirtualMachine::frame_get ...); in the shared runtime (NyConc.cpp, so
registered on both): `async_coro_drive(h, mode, value)`,
`async_coro_info(h)`, `async_coro_drop(h)`, `async_coro_release(h)`,
`_ny_await_manual()`, `_ny_await_yield(y, it, frame)`; the engine adapters
gained `Engine::coro_handle` and an `__await__`-generator path in
`await_target`.

### Not done
- `sys.settrace` / `sys.setprofile`: feasible at almost no cost when
  unused - one more predictable branch per statement on the interpreter
  (beside the `--trace` check in `noteStatement`) and per instruction on
  the VM (folded into the existing `vm_trace_` test), one per call/return
  (FrameGuard / `pop_frame`) - but not written: call/line/return/exception
  events with per-frame `f_trace`, re-entrancy guards and the profile
  events are ~250 lines per engine.
- Writing to `f_locals` does not change the frame's variables (3.11's
  behaviour without `PyFrame_LocalsToFast`; 3.13 writes through).
- `co_varnames` lists the parameters only; positions carry no columns.
- A coroutine wrapped in a running asyncio task shows a frame at its def
  line as `cr_frame` (its real frame is on the task's own stack).
- A bare generator (`types.coroutine` without an `__await__` object) is
  not awaitable; weak references to generators are not supported.

### Round 78 (parts 1 and 2 together), verified at 0cdc138
- Linux, both engines: the sweep 405 runs, 0 not ok; vm_audit89 62 and
  vm_audit90 65 on both engines (61 and 63 under python3); `ide_e2e`
  373/373, `ide_lint` clean, `ide_memprobe --check` within its thresholds.
- Windows 64-bit (MinGW from `nython.cbp`, under Wine): built,
  `pe_unwind_check` clean, the sweep 405 runs, 0 not ok.
- AArch64 (qemu-user): vm_audit49, 55, 56, 64, 67, 89 and 90 pass on both
  engines (coroutine objects and frames over the assembly context switch).
- Merging the two parts conflicted only in the docs and in
  `lib/collections/abc.ny`'s header comment.

## 0q3. Round 78, part 3 — the data-model gaps (vm_audit88)

The gaps the round-77 agents found and left in §0p's "Not done" list, fixed
on both engines the CPython 3.11 way. `examples/vm_audit88.ny` (86 checks)
passes on the interpreter, the VM and under python3.

### Parser (both engines get it)
- **Walrus as an argument**: `f(x := 1)` is a positional argument
  (`parseCallArgs`; `f(x=1)` stays a keyword).
- **Name mangling** (CPython's `_Py_Mangle`): while a class body is parsed,
  every `__name` identifier (two leading underscores, not two trailing) is
  read as `_Class__name` - attributes, body names, methods, nested
  functions, lambdas and comprehensions; the innermost class wins, nothing is
  mangled under an all-underscore class name. `Parser.hpp`: `mangle_stack_`,
  `manglable()`, `mangled()`, `rawToken()`; `next()/prev()/peek()/token()`
  return mangled identifiers. Call keywords and module names in a dotted
  import are not mangled; a function's `__qualname__`/`__name__` show the
  raw name (`nyrt::unmangled_name`); a nested `class __H` binds `_C__H`.
- `class C(*bases)` (a `UnaryNode("*")` base, expanded by both engines);
  `{x}` alone on a line is a set display unless a soft keyword starts a
  statement there; `return`/`break`/`continue` in an `except*` block are
  SyntaxErrors (`checkExceptStarFlow`).
- Async methods are reached through their first parameter whatever its name
  (`async def m(s)`, an async classmethod's `cls`); `@staticmethod` keeps
  the plain path (`next_def_static_`).

### Engines
- **Every function in a class body is a method** whatever its first
  parameter is called (`def m(this, x)`, `def m(s)`): the interpreter's
  `invokeMember`/`makeBoundMethod`, the VM's `VMCode::bind_first`.
  `__new__` is implicitly static, `__init_subclass__`/`__class_getitem__`
  implicitly class methods (`nyrt::implicit_method_kind`), and
  `C.__dict__` shows them as staticmethod/classmethod objects.
- **Calling a non-callable** raises `TypeError: 'int' object is not
  callable` on both (the interpreter returned none or "NameError: 'End'";
  calling bytes crashed it). A name bound nowhere is still a NameError.
- **`super(...)` is a proxy value** (`s = super(C, self); s.m()`): the
  interpreter's `_NySuper`, Python's TypeErrors (argument 1 not a type, one
  argument, more than two), `super(Meta, cls)`; `__thisclass__`,
  `__self__`, `__self_class__`. The legacy `super(args)` "call the parent's
  constructor" shorthand and the VM's bare `super()` statement are gone
  (five old examples now name the constructor: `super().init(...)` for
  their Nython-style `def init`).
- **Builtin values' dunders as values**: `(5).__add__(3)`,
  `int.__add__(2, 3)`, `"ab".__len__()`, `[1].__getitem__(0)`,
  `{}.__contains__("a")`; `(5).__add__("x")` is NotImplemented (the
  prelude's `_NyV_int`/`_NyV_float`, then the type's mirror class);
  `f.__call__`; `real`/`imag`/`numerator`/`denominator` of ints and floats;
  three-argument `pow` and `__rpow__` call the dunders.
- **`type(module)`** is the `module` type (`_NyModuleType`,
  `types.ModuleType`, `ModuleType(name, doc)`); a module prints as
  `<module 'x' from '...'>`.
- **Data descriptors win over instance fields** (property, or anything
  with `__set__`/`__delete__`); non-data descriptors lose to the field.
- **Objects with `__hash__` as set/dict keys** compare with `__eq__` among
  keys of the same hash (and against the int equal to their hash), as
  Python - a `Fraction(2)` and `2` are one key. A non-int `__hash__` is a
  TypeError.
- **Protocol results checked**, Python's messages: `__str__`/`__repr__`
  must return a str, `__len__` an int >= 0, `__bool__` a bool, `__hash__`
  an int, `__iter__` an iterator. A method supplied by `__getattr__` must
  be callable. `object()` takes no attributes. Arity errors name the
  qualname (`C.m() takes ...`).

### Behaviour old Nython code may notice
- `obj.helper(x)` on a class-body `def helper(x)` with no `self` binds
  `obj` to `x` (as Python); call it through the class, or make it a
  `@staticmethod`. Nothing in lib/ or the IDE relied on the old reading.
- `super(args)` no longer calls the parent's constructor; write
  `super().__init__(args)` (or `super().init(args)` for a class whose
  constructor is Nython's `def init`).
- `__str__`/`__repr__` returning None raise TypeError.

### Not done
- An `async` staticmethod still fails (its desugared body calls itself by
  bare name, out of scope there) - as before this round.
- `inspect.signature` on the VM shows a first parameter named `this` as
  `self`; a nested class's `__qualname__` is its bare name.
- `obj.__class__ = Other`, `__slots__`, and slicing a str with an
  `__index__` object are not implemented.
- `(5).__add__(1.5)` gives NotImplemented as CPython; a builtin-subclass
  instance's mirror methods still compute instead.
- A hashed key's speculative `__eq__` calls swallow exceptions; CPython
  calls `__eq__` only on a real hash collision.

### Verified after merging it onto parts 1-2
- Linux, both engines: the sweep 407 runs, 0 not ok; vm_audit88 86/86 on
  the interpreter, the VM and python3 (89: 62/62/61, 90: 65/65/63);
  `ide_e2e` 373/373; `ide_lint`, `ny_classcheck`, `cbp.py check` clean;
  `ide_memprobe --check` 0 KB kept per frame/event/key.
- Windows 64-bit (MinGW from `nython.cbp`, under Wine): built,
  `pe_unwind_check` clean, the sweep 407 runs, 0 not ok.
- AArch64 (qemu-user): vm_audit53, 56, 64, 67, 86, 88, 89 and 90 pass on
  both engines.
- The merge conflicted in the VM's `len` (part 1's native range/view
  lengths beside part 3's checked `__len__`: both kept) and in the parser's
  async desugar (part 2's coroutine-object reference beside part 3's
  first-parameter binding: one `self_ref` that knows both).

## 0p. Round 77 — bytes, the network stack, signals, modules, the CLI, Python compatibility

Everything here works on both engines; the tests named with each part pin
it (all in the sweep: 371 runs, 0 not ok at the end of the round). Many
suites are written in the subset Nython and Python share and pass under
python3 too (vm_audit65, 72) - their expected values are CPython's.

### bytes and strings (`include/NyBytes.hpp`; vm_audit65, 149 checks)
- A real `bytes` and a mutable `bytearray`: literals (`b".."`, `rb".."`),
  indexing to ints, slicing, iteration, comparison, hashing and dict keys,
  `+ * in`, item/slice assignment and `del` on bytearray, `bytes()` /
  `bytearray()` constructors, `str.encode` / `bytes.decode` (utf-8, ascii,
  latin-1, utf-16/32, the `errors=` handlers). One method library serves
  both engines; the VM bridge carries bytes and bytearray changes both ways.
- Builtin types read as namespaces: `str.upper(s)`, `bytes.fromhex`,
  `int.from_bytes`, `dict.fromkeys`; `int.to_bytes`/`bit_length`/...
- String escapes follow Python (`"\xe9"` is U+00E9, octal escapes, `"\0"`,
  an unknown escape keeps its backslash).

### Signals (`src/NyConc.cpp`; vm_audit66)
`signal` module; SIGINT raises KeyboardInterrupt (exit status 130);
handlers run on the main thread at statement boundaries and inside blocking
waits, which then resume with their remaining time (PEP 475); signal
channels (Go's `signal.Notify`); `input()` raises EOFError /
KeyboardInterrupt.

### Sockets, TLS, HTTP, WebSockets (vm_audit68, vm_audit70)
- `src/builtins/net.cpp`: one non-blocking socket table behind
  `lib/socket.ny` (TCP/UDP/IPv6/AF_UNIX, timeouts, `makefile`, Python's
  errors), `lib/select.ny`, `lib/selectors.ny`. Blocking calls release the
  GIL; inside an async task they park the task on its loop's poller
  ("colorless" I/O - the same `sock.recv()` works in both worlds).
- `src/builtins/tls.cpp` loads OpenSSL at run time (no build dependency);
  `lib/ssl.ny` is Python's module, verification and host-name checks on by
  default, SNI, ALPN, `getpeercert`.
- `lib/http/` (client: keep-alive, chunked, 100-continue, CONNECT, HTTPS;
  server: Base/SimpleHTTPRequestHandler, ThreadingHTTPServer; cookiejar),
  `lib/urllib/` (request with the handler chain - proxies from the
  environment, redirects, basic auth, cookies, file:, data: - error, parse),
  `lib/websocket.ny` (RFC 6455 client and server, ws/wss, fragmentation,
  the close handshake, keepalive driven by an RFC 6298 RTT estimator),
  `hashlib`/`hmac`/`base64`/`binascii`/`secrets` over a native digest
  library, `threading`, `socketserver`. `nython -m http.server` serves a
  directory.
- The legacy libraries are real now: `network.ny` (HttpClient with
  retries and Retry-After, RestClient, EventSource, HttpCache, signed
  webhooks), `webserver.ny` (routes with parameters, middleware, sessions,
  signed tokens, static files with 304, templates, WsServer),
  `sockets.ny`, `clientserver.ny` (JSON-RPC 2.0, MQTT topic wildcards,
  phi-accrual failure detection, smooth weighted round-robin).
- `http_get`/`http_post`/`http_request` speak https, IPv6, chunked bodies
  and redirects, with the GIL released (a duplicate in string.cpp held it
  and deadlocked against server threads).

### Async and asyncio (vm_audit67)
`async with`, `async for`, async generators and comprehensions,
StopAsyncIteration, `aiter`/`anext`, `__await__`; cancellation propagates
into awaited tasks; `lib/asyncio.ny`: tasks, gather/wait/wait_for/
as_completed/shield/timeout/TaskGroup, queues, sync primitives, futures,
to_thread, Runner, streams (with `ssl=`).

### Modules (vm_audit67)
`import name` of a `.ny` file runs it in a scope of its own (its names no
longer leak into the importer); `from m import a, b` / `*` (`__all__`);
packages and dotted imports (`lib/http/__init__.ny`); a module's classes
are named `m.Class` so same-named classes stay distinct; NYTHONPATH and
the library beside the interpreter are searched. A namespace package must
hold `.ny` files (`import sys` used to find Linux's `/sys`). Quoted imports
still include the file.

### Sets and math (vm_audit69, vm_audit70)
Sets are a real type with a typed-key index (`1 == 1.0 == true`, O(1)
membership), `frozenset`, the full API and operators; `dict | dict`.
`math` is Python's whole module on both engines (`src/builtins/pymath.cpp`).

### The command line (`src/main.cpp`; vm_audit71, 97 checks with the input section below)
- `nython [options] [-c cmd | -m mod | file | -] [args]`: `-i -q -u -E -V
  -h`, bundles (`-iq`), `--vm`/`--interp` for every way of giving a
  program, `--check`, `--tokenize/--ast/--disasm`, `--profile`, `--trace`;
  `sys.argv` as Python sets it; unknown options exit 2.
- The prompt (`interactive_loop`) shows an expression's repr and keeps `_`;
  errors print as Python's last traceback line on both engines; with piped
  input `-i` stays interactive; NYTHONSTARTUP runs first.
- **SystemExit is real**: `exit()`/`quit()`/`sys.exit()` raise it, finally
  blocks run, `except SystemExit` catches it, the process ends with its
  code (`exit("msg")` prints msg, status 1); at the prompt it ends the
  process with that status.
- `sys.stdin/stdout/stderr` objects (prelude `_NyStdStream`) over the same
  streams as print; `print(*xs, sep=, end=, file=, flush=)` (the extended
  forms are lowered to the prelude's `_ny_print`); `os.get_terminal_size`.
- `lib/argparse.ny` is Python's algorithm, not an imitation: arguments are
  classified as O/A/- and positionals consume chunks against their nargs
  patterns (a backtracking matcher over the same patterns argparse builds
  regexes from), `-qn3` explicit-argument chaining, abbreviations,
  ambiguity errors, negative numbers, REMAINDER/PARSER, Action classes
  whose `__call__` a user subclass overrides, subcommands, mutually
  exclusive groups, parents, fromfile, intermixed parsing. HelpFormatter
  lays out usage and help byte for byte as Python's (checked against
  python3's output). Two deliberate differences: unknown options and
  mistyped choices get a "did you mean" (the runtime's fuzzy matcher), and
  positionals that matched nothing just before an option wait for later
  values (Python 3.13's rule; 3.11 left `cmd --foo x a b` unparsed).

### Python compatibility (vm_audit72, 56 checks, passes under python3)
- **Each execution of a class statement makes a new class.** A class
  statement run again - a factory called twice, a loop - rebound the one
  class, so instances of the first saw the second's methods, class
  attributes and closures. A re-run registers a copy as `Name#n` (classes
  are keyed by name on both engines; `nyrt::shown_class_name` strips the
  suffix wherever a name is shown). Bases are resolved through the scope
  (the class bound to that name), so a factory's `Derived(Base)` gets that
  call's `Base`; on the VM a copy owns copies of its method code so
  `super()` starts from it.
- **Displays and unpacking**: `[*a, b]`, `(*a, b)`, `{*a}`, `{**d, k: v}`
  (lowered to the prelude's `_ny_list_cat` / `_ny_dict_merge`), `[x, *y] =
  seq` and `(a, b) = ...` targets.
- **Annotations**: `x: int = 5`, `self.x: T = v`, `x: T` alone, parameter
  annotations, `-> T`, `/` and `*` markers, trailing commas; they are kept
  (`__annotations__`) and positional-only parameters are enforced - see
  "Classes" and "Parameters" below. `f"{expr=}"`.
- **slice objects**: the prelude's `slice`; `obj[i:j:k]` hands an
  object's `__getitem__/__setitem__/__delitem__` a slice; a slice object
  indexes lists, strings, tuples and bytes.
- **eval / exec / compile**, with or without namespace dicts (on the VM a
  namespace runs as a module scope, so functions defined inside see it).
- **complex**: `2j` literals (the lexer's `0j` path swallowed the next
  character), a prelude `complex` class with Python's arithmetic, powers,
  parsing and repr. `object` exists; `issubclass(bool, int)`.
- **`__setattr__` / `__delattr__`** run for assignments and `del`;
  `object.__setattr__(self, k, v)` and `super().__setattr__(k, v)` store
  directly (`_ny_setattr_raw`); a failed `super()` lookup falls back to
  `object` and otherwise raises AttributeError (the VM returned none).
  `threading.local` is built on it (it called natives that never existed).
- **Docstrings**: `__doc__` of functions, methods, classes and instances
  (the parser records them); `help(x)` prints them.
- **Reflection**: `locals()`, `globals()`, `vars()`, `dir()` (all four
  returned none); `**kwargs` keep the call order on the interpreter (PEP
  468: `nyrt::OrderedKw` replaced the unordered map); `dict(mapping)` uses
  `keys()`.
- **`lib/collections.ny`**: deque (a ring buffer, maxlen, rotate),
  Counter, defaultdict, OrderedDict, namedtuple, ChainMap, UserDict,
  UserList - the native names returned an empty list whatever they were
  given. `import collections` loads it; the bare stub names remain for old
  programs that never import it.

### Parameters, imports, `__future__` (vm_audit72)
- **Positional-only parameters are enforced** (`def f(a, b, /, c)`): the
  parser records how many lead the list (`FunctionNode::posonly`); a
  keyword naming one of them raises Python's TypeError ("f() got some
  positional-only arguments passed as keyword arguments: 'a'"), and a
  `**kw` collector receives such a name instead. Both engines.
- **Module names that are Nython keywords** (`import string`, `from
  re import match`, `import queue`, `io`, `json`...) parse as names
  (`Parser::identifier()` in dotted names); `from m import (a, b as c,)`
  with parentheses and trailing commas; `nyrt::import_name_alias` splits
  `a\x05b` (the parser's encoding of `a as b`) for both engines;
  `nyrt::prefers_lib_module` decides when `import name` loads
  `lib/name.ny` rather than the old builtin namespace of that name.
- `from __future__ import annotations` (PEP 563) and the other `__future__`
  names are accepted; `annotations` keeps annotations as text (below).

### Python's syntax (vm_audit84, 212 checks, passes under python3)
A conformance battery over Python 3.11's grammar (`Grammar/python.gram`,
`type X =` aside): the forms the parser rejected or compiled wrongly, and
the rest of the statement and expression grammar beside them. Mostly
`src/Parser.cpp`; where the engines had to change, both did.
- **Nython's extra keywords are soft** (`nameKeyword` in Parser.cpp: repeat,
  execute, delete, default, final, loop, block, use, static, public,
  private, protected, abstract, print, typeof, sizeof, ref, let, var, const,
  namespace, package, interface, struct, enum, end, fn, fun, function, new,
  do, switch, case, then, extends, inherits, implements, unless, until,
  equals, instanceof, subclassof, parentof, self, this): each is a keyword
  only where its construct starts and a name everywhere else - `new = old +
  1`, `def f(ref, new=1):`, `obj.self`, `match = re.match(...)`, `print =
  log`, `class K: var = 1`, `self` outside a method, keyword arguments
  `f(default=1)`, `nonlocal end`. At the start of a statement the word is a
  name when the next token cannot begin its construct (`usedAsName`: `=`,
  an augmented `=`, `.`, `,`, `[`-less operators, `)` ...), so `print -1`,
  `unless (x):`, `repeat 3:` stay statements; `var`/`let`/`const`/`ref`
  declare only when a name follows (`declFollows`). `match` is a statement
  only on a `match subject:` header line. `this` means the receiver only
  inside a method whose first parameter is self/this. `lib/keyword.ny`:
  `nyhardkwlist` (elseif false none null super true undefined - still
  reserved), `nysoftkwlist`, `isnysoftkeyword`.
- **Imports, del, classes, lambdas**: `import os, sys`, `import a.b as c,
  d`, `from os import path as p`, `import os.path` (both engines bind `os`
  and give `os.path` its namespace); `del a, b`, `del x[0], y.z`, `del (a,
  [b])`; dotted bases `class K(weakref.ref)`, `class E(m.Base,
  metaclass=m.M)`, `class C(**kw)` (stored as keyword `"**"`, merged by
  both engines); lambdas take Python's whole parameter list (`lambda *,
  k:`, `*a, **kw`, `a, /, b`, defaults, keyword-only defaults) and bind
  through the same code as def on the interpreter (`LambdaNode::sig`).
- **Expression statements are evaluated in every form**: a statement that
  starts with `{` is a block only when it is not an expression
  (`braceIsExpression`: a `key: value`/comma display, or an operator/`[`/
  `.`/`(` after the closing brace), so `{}["x"]` raises KeyError and
  `{"a": 1}.items()` runs; `x = 1, 2` and `f(), g()` are tuples.
- **Assignment**: `a = b = c, d = 1, 2` (each target group gets the value),
  `i, = x`, `*rest` anywhere, nested targets; unpacking checks counts on both
  engines with Python's messages ("too many values to unpack (expected 2)",
  "not enough values to unpack (expected at least 3, got 2)"), sets and dicts
  unpack by iteration; assigning to a literal, call or operator is a
  SyntaxError ("cannot assign to literal", ...). A builtin or prelude name
  assigned inside a function becomes a local there (interpreter
  `assignName`: `typeof = 3` in a function clobbered the builtin).
- **Augmented assignment**: `@=` is a token (`TokenType::MatMulAssign`);
  every augmented operator tries the in-place dunder first (`__imatmul__`,
  `__ior__`, `__ipow__`, `__ifloordiv__` ...) then the binary one, on both
  engines (VM opcode `INPLACE_TRY`).
- **for / with targets**: `for a, *b in`, `for (p, q), r in`, `for [m, n]
  in`, `for o.attr in`, `for d[k] in`, `for x, in`; `with (A() as a, B() as
  b):`, `with f() as (x, y):`, `with f() as o.attr:`.
- **Comparisons**: one precedence level for every comparison operator, any
  chain (`a < b == c != d in e`), each middle operand evaluated once (a
  walrus temporary `__cmpN__`).
- **Literals**: `0x_ff`, `0b1_0`, `5.` before `)`/`,`/space, `u"..."`,
  `F"..."`, `rf"..."`/`fr"..."`, `\N{EM DASH}` in strings and bytes
  (`src/NyUniNames.cpp`: all 138,552 Unicode 14 names CPython 3.11 knows,
  derived CJK/Hangul names included, 250 KB compressed in
  `include/NyUniNamesData.hpp`, made by `tools/gen_unicode_names.py`, decoded
  on first use); `lib/unicodedata.ny` has `lookup`, `name`,
  `unidata_version`; f-string fields may be padded (`{ x }`).
- **Subscripts**: `a[1:2, ::3]` hands `__getitem__` a tuple of slice
  objects.
- **Decorators** are any expression (PEP 614: `@buttons[0].clicked`,
  `@(lambda f: f)`).
- **match**: bytes and complex literal patterns (`2 + 3j`), sequence
  patterns match tuples, star captures.
- **return / yield** of `a, b` and `*xs, y` are tuples.
- **print**: `print(x, file=f)` with keywords or `*args` is the call form
  even at statement start (`_ny_print`), and `print` is a value in
  expressions.
- **Exception groups (PEP 654)**: `BaseExceptionGroup` / `ExceptionGroup`
  in the prelude (`__new__` picking ExceptionGroup when every member is an
  Exception, validation messages, `split`, `subgroup`, `derive`, str and
  repr) - asyncio's own ExceptionGroup is now the builtin; `except*` is
  desugared by the parser onto `_ny_star_begin/_match/_raised/_finish`,
  which follow CPython's `PrepReraiseStar`: a naked exception is wrapped,
  each clause gets the matching subgroup, the unhandled rest is re-raised
  with the original group's structure, new raises join it as
  `ExceptionGroup("", [...])`; mixing `except` and `except*` is a
  SyntaxError.
- **Unary operators** on a non-number raise TypeError ("bad operand type for
  unary -: 'str'") on both engines (the interpreter returned none).
- **Exception repr** on the interpreter is `Type(*args)` with each
  argument's repr (`ValueError(1)`; it gave `ValueError('1')`).
- **Walrus in a comprehension** binds in the enclosing function (PEP 572),
  generator expressions included (VM opcode `DEFINE_OUTER`).

### Classes: the machinery typing, dataclasses, enum and abc stand on (vm_audit79, 43 checks, passes under python3)
- **Annotations are kept** (they were parsed and dropped): a function's
  parameter and return annotations are its `__annotations__` (a dict display
  the parser attaches to the FunctionNode, evaluated when the def runs -
  before any decorator, so `@f.register` style decorators see them); `x: T =
  v` in a class body or a module stores `__annotations__["x"]` after the
  value, as CPython does (the parser lowers it; the scope starts with `var
  __annotations__ = {}` when it annotates anything); annotations in a
  function body are not kept. Each value goes through the prelude's
  `_ny_ann(lambda: T, "T")`: an annotation that cannot be evaluated yet - a
  forward reference, a name from a module not imported - is kept as its
  source text (what typing's ForwardRef holds) instead of failing a program
  that never reads it. `from __future__ import annotations` keeps them all
  as text; the parser rebuilds the text from the tokens
  (`Parser::tokenText`). An unannotated function's `__annotations__` is an
  empty dict made on first read.
- **PEP 487**: `class C(Base, flag=1)` passes its keywords to the nearest
  base's `__init_subclass__` (an implicit classmethod; object's raises
  "C.__init_subclass__() takes no keyword arguments" for leftovers), after
  `__set_name__(owner, name)` has run for the class's attributes that define
  it.
- **`__new__`**: instantiation calls the class's own `__new__(cls, ...)`
  (cached per class: classes without one pay nothing) and runs `__init__`
  only when it returned an instance of the class; `object.__new__(cls)` /
  `super().__new__(cls)` make a bare instance (`_ny_object_new`).
- **PEP 560 / generics**: `C[x]` calls `__class_getitem__`; `list[int]`,
  `dict[str, list[int]]`, `tuple[int, ...]`, `type[X]` are the prelude's
  `_NyGenericAlias` (origin/args, Python's repr, callable,
  `__mro_entries__`); `int | None`, `Foo | Bar` are `_NyUnionType` (PEP 604)
  and `isinstance(x, int | str)` works; a base given by an expression
  (`class C(Generic[T])`, `class P(namedtuple(...))`) is evaluated, with
  `__mro_entries__`.
- **Metaclasses**: `metaclass=M` (or a base's). `M.__new__(mcs, name, bases,
  ns, **kw)` runs on the class the statement built - its `super().__new__`
  reaches `type.__new__`, which returns that class with ns's entries applied
  (both engines build classes from the class body, so type.__new__ *adopts*
  the class rather than making one; `constructing_` holds it) - then
  `M.__init__`. Operations on the class go to M: calling it (`__call__`,
  whose `super().__call__` makes the instance - a one-shot flag,
  `type_call_skip_`, so classes instantiated inside that instance's
  `__init__` still go through their own metaclass), `iter`/`for`/
  comprehensions, `len`, `in`, `C[k]`, `repr`/`str`,
  `isinstance`/`issubclass` (`__instancecheck__`/`__subclasscheck__`), and
  the attributes the class lacks (M's methods bound to the class -
  `_NyMetaBound` -, its properties, its `__getattr__`). `type(C)` is M;
  `type(name, bases, ns)` and `M(name, bases, ns)` make classes at run time
  (a class node without a body on the interpreter, a bare VMCode on the VM).
  `super()` in a method whose first parameter is `cls`/`mcs` takes that
  argument as its receiver.
- **The VM's method rule**: a class-body function was a method only when its
  first parameter was literally `self` (the VM strips `self` from the
  parameter list and binds it from the frame). A getter or method written
  `def size(cls)` (metaclasses, property getters taking another name) now
  gets the object as its first argument (`call_with_first`), and an
  unbound method called with any first argument binds it as self
  (`Props.x.fget(None)`).
- **NotImplemented**: a binary or comparison dunder returning it declines -
  the other operand's reflected method is tried, then TypeError (`==`/`!=`
  fall back to identity); every method declining is a TypeError rather than
  the lenient str concatenation; an `__iadd__` declining falls back to
  `__add__`; the right operand's reflected method comes first when its class
  is a subclass of the left's that provides its own (Python's rule). On the
  VM `==` gives the dunder's own result (it was coerced to a bool), and
  ordering objects without the dunder is a TypeError (it compared garbage).
- `C.__mro__` ends with the builtin bases and `object` (`(M, type,
  object)`), `C.__bases__` is a tuple with builtin bases (`(object,)` for a
  class naming none), `C.__subclasses__()` (a registry filled by
  `classCreated`/`class_created`) and `C.mro()` reach every class.
- Also: `...` is the Ellipsis object; class reprs are Python's (`<class
  '__main__.A'>`, `<class 'int'>`); `class A: x = 1` is a one-line body
  (Nython's `class A : Base` read it as a base); `C.__dict__`; a bound
  method's `__func__`, `__self__` and its function's attributes; a
  function's last expression is no longer its return value on the
  interpreter (`def f(): 5` returned 5).

### type() gives type objects (vm_audit80, passes under python3)
- `type(5) is int`, `type(obj)` is its class, `type(C)` is `type` (or C's
  metaclass), `type(x)(v)` makes another, `type(x) in (int, float)`,
  `{int: f}[type(x)]`; `x.__class__` for every value (`(5).__class__ is
  int`). `type()` returned strings, so none of that worked, and libraries
  carried `_tname()` helpers.
- **Compatibility bridge** (`NythonExecutor::typeObjectNames`,
  `VMVal::type_object_named`): a type object is `==` to its name - Python's
  (`"int"`, `"str"`, `"dict"`, `"type"`, a class's name) *and* the legacy one
  type() returned (`"string"`, `"map"`, `"class"`) - so the `type(x) ==
  "list"` comparisons in the libraries and the IDE (about 70) keep working
  unchanged. What
  changed for old code: `str(type(x))` is `"<class 'int'>"` (Python's), so
  tests that compared `str(type(x))` with a name were migrated to
  `type(x) == "int"`. `typeof(x)` (Nython's keyword) is the legacy name as a
  string (`"int"`, `"string"`, `"map"`); `x is int` keeps its membership
  meaning, and the internal `valueIsOfType` uses the legacy name
  (`legacyTypeName`).
- `is` between types is identity: `int is int`, `C is C` were false (a
  type on the left was asked whether it is an instance of the right).
- The other kinds got type objects in vm_audit86 (below); typed maps (a
  `__type__` key) still give their tag, and `isinstance(f, "function")`
  still accepts a legacy name.
- VM: builtin natives were all one dict key (`vkey` had no pointer for
  them: `{int: 1, str: 2}` had one entry) - keyed by what they are now;
  `isinstance(x, T)` compares the native's name (`native_name`), not its
  raw tag; `int is int` (natives were never identical); the dead
  `register_builtins` copies of `len`/`type` that `register_pycore`
  replaced are removed. VM property descriptors have `fget`, `fset` and an
  abstract getter's `__isabstractmethod__` (abc reads it); the
  interpreter's property (its tagged getter) answers `fget`/`fset`, and
  `obj.m(...)` on a function value is `getattr(obj, "m")(...)`.

### Classes and objects, the smaller gaps (vm_audit86, 65 checks; 63 pass under python3)
- **Every class statement makes its own class**: a second statement with a
  name already registered (another function's `class P`, a redefinition) is
  registered as `Name#n`, as a re-run was. The VM gave both functions one
  class (`f1()().m()` ran f2's method); the interpreter resolved a base named
  that way to the newest. A program's own class named like a builtin
  exception still replaces the builtin on the VM.
- **`object`**: `isinstance(x, object)` for every value, `issubclass(T,
  object)` for every type object.
- **`__eq__` without `__hash__`** puts `__hash__ = None` in the namespace
  (unhashable instances); a subclass defining only `__eq__` loses the
  inherited hash, as CPython.
- **property, staticmethod and classmethod are objects** (prelude classes):
  `C.__dict__["p"]` and `C.p` are the property (`fget`/`fset`/`fdel`/
  `__doc__`, `getter`/`setter`/`deleter` copying as CPython,
  `property(fget, fset, fdel, doc)`, 3.11's messages such as "property 'x' of
  'C' object has no setter"); staticmethod/classmethod objects have
  `__func__`/`__wrapped__`, a staticmethod is callable (3.10+). The engines
  unwrap them when a class is made (`unwrapMethodObject` /
  `unwrap_method_object`) and call the prelude property's getter and setter
  directly. Properties on metaclasses work; `super().p` and
  `super(C, obj).attr` read attributes (the interpreter ran the parent
  constructor). The data-descriptor check on stores turns on when a class
  *holds* a data descriptor (the prelude property defines `__set__`, so "a
  class defines `__set__`" would be every program).
- **`dir()`/`vars()`**: `dir(obj)`/`dir(C)` list what CPython 3.11 lists
  (identical for a plain class); `vars(obj)` includes dunder attributes,
  `vars(C)` is `C.__dict__`.
- **Two-argument `super`** outside a method: `super(C, obj).m()`,
  `super(C, C2).m()`, checked as Python (TypeError).
- **Bound and builtin methods**: `type()` is `method` /
  `builtin_function_or_method`, reprs are Python's (`<bound method C.m of
  ...>`, `<built-in method append of list object at 0x...>`), with
  `__name__`, `__qualname__`, `__self__`, `__func__`.
- **Type objects for the remaining kinds**: `NoneType`, `function`,
  `method`, `builtin_function_or_method`, `generator`, and the lazy
  iterators (`zip`, `map`, `filter`, `enumerate`, `islice`, `list_iterator`,
  `str_ascii_iterator`, `dict_keyiterator`, `set_iterator`, ...). Tagged
  `__rtype__:<name>` (`nyrt::RuntimeType`), never global names, each `==` its
  legacy name (`type(f) == "function"`); `type(None)()` is None;
  `types.MethodType(f, obj)` binds; `lib/types.ny` uses them, so `type(f) is
  types.FunctionType`.
- **A dict's methods win over its keys** for `keys values items get pop
  popitem setdefault update clear copy fromkeys` on a plain dict (`d =
  {"get": 1}; d.get("x")` is the method); any other name still reads the key
  (`d.name`, Nython's feature). With `NY_LENIENT_READS=log` a method hiding a
  key is reported once per line - a porting aid for code that relied on the
  old key-first rule.
- `getattr(o, n)` without a default re-raises the AttributeError a getter
  raised; messages show a re-run class's name without `#n`.

### Values and errors as Python has them (vm_audit87, 73 checks; 72 pass under python3)
- **`in` and ordering raise TypeError** with Python's messages: `1 in 5`,
  `x in None`, `1 in "abc"`; `1 < "a"`, `None < 1`, `[] < 3`, list vs tuple,
  dicts. The message names the first pair that cannot be ordered (`[1] <
  ["a"]` names int and str); NaN still compares false. (`sorted`/`min`/`max`
  of mixed types still fall back to ordering by type name.)
- **Exceptions**: `str`/`repr`/`args` as CPython (KeyError's str is its key's
  repr; `repr(e)` shows the args' reprs; `str(e)` ignores a class's own
  `__repr__`). `OSError(errno, strerror[, filename[, winerror[,
  filename2]]])` sets its fields, prints `[Errno 2] x: 'f' -> 'g'`, cuts
  `args` to `(errno, strerror)`, and `OSError(2, "x")` is a
  FileNotFoundError (CPython's errno table, `ny_errno_exc_class` in
  `include/NyExcTypes.hpp`); Unicode errors have `encoding`/`object`/
  `start`/`end`/`reason`; SyntaxError's tuple form gives its fields and `msg
  (file.py, line 3)`; `ImportError.msg`. **The legacy `msg` attribute is
  gone**: `super().__init__` overwrote a subclass's own `self.msg`.
- **Errors raised by the runtime carry their fields**: native OSErrors
  (open, stat, listdir, rename...) have `errno`/`strerror`/`filename`/
  `filename2` (the OS layer quotes names with repr and the engines parse
  them back - `ny_parse_errno_message`); codec errors carry the input as
  `e.object` (a thread-local the codec sets, `last_unicode_error()`); a
  missing key, `set.remove`, `dict.pop`, `del d[k]` raise `KeyError(key)`
  with the key itself.
- **Iteration and generators**: `iter(callable, sentinel)` (a lazy
  `callable_iterator`); the VM's `next()` of a non-iterator is a TypeError
  (it gave none) and `iter(bytes)` works; `gen.throw(type, value, tb)` /
  `gen.throw(instance)` normalized as Python; a bare `raise` in a helper
  called from an except clause re-raises on the VM; generators have
  `__name__`, `__qualname__`, `gi_running`, `gi_suspended`, `gi_frame` (None
  once finished; `f_lineno` is the paused line), `gi_code`, `gi_yieldfrom`.
- **`__format__`**: `f"{obj}"` calls it even for an empty spec and the
  result must be a str; `object.__format__` rejects a non-empty spec;
  `(255).__format__("x")` and friends.
- **`os`**: `os.stat`/`lstat`/`fstat` return an `os.stat_result`
  (indexing, slicing, fields, `st_*_ns`, `st_blocks`, read-only; prelude
  `_NyStructSeq`), `os.get_terminal_size()` (OSError off a terminal, as
  Python), `os.times()`, `os.uname()`; `listdir`/`rename`/`replace`/`mkdir`/
  `link`/`remove` raise OSError with the file names. The flat `os_*`
  builtins keep their contracts.
- **`exec(src, ns)` / `eval(src, ns)`**: `ns` is the live globals of what
  the code defines (`Context::ns_owner`: a scope runs over the dict's map
  without owning it) - later changes to `ns` are seen, `global x` writes
  into it, dunder names are exported. With a separate locals dict the old
  copy-in/copy-out remains.
- **Recursive containers** print `[...]`, `{...}`, `(...)` through any cycle
  (the VM overflowed its stack on a two-list cycle).
- `lib/aiagent.ny` skips malformed stored cells: the shared store file
  `/tmp/nyx_final/nyx_memory.json` (test_all_libs) held cells with a None
  confidence, which is no longer comparable with a number.
- Not done (vm_audit87): ~~`range()` and `dict.keys()/values()/items()` are
  lists; `zip`/`map`/`filter`/`enumerate` over lists return lists~~ (done in
  round 78, §0q); the default instance repr stays `<C
  instance>`; structure sequences are not tuple subclasses; `fileno()` is
  Nython's handle (only `os.stat`/`fstat` translate it);
  `ImportError(name=, path=)` and `AttributeError(name=, obj=)` keywords;
  exception fields show in `vars(e)`; `exec(src, g, l)` with two dicts still
  copies; a dunder name exec binds is copied into the dict when it returns.

### The Python standard library (vm_audit73, 75-78)
Each module is CPython 3.12's API and algorithm, written in Nython, with a
header comment saying what is there and what is not; all are `# nython:
module` files (their own scope). Most tests pass under python3 too.
- vm_audit77 (274): `json` (package: `JSONEncoder`/`JSONDecoder`,
  `JSONDecodeError` with positions, `indent`/`sort_keys`/`default`/
  `object_hook`/`parse_float`..., native scanner `src/builtins/pyjson.cpp`),
  `random` (the Mersenne Twister, `seed` by CPython's algorithm - the same
  sequences as CPython for the same seed - `getstate`/`setstate`, every
  distribution, `src/builtins/pyrandom.cpp`), `datetime` (`_pydatetime`'s
  algorithms with the C module's messages: date/time/datetime/timedelta/
  timezone, strftime/strptime/isoformat/fromisoformat), `time`, `io`
  (StringIO, BytesIO, the stream base classes, TextIOWrapper over a buffer).
- vm_audit75 (1004): `string`, `textwrap`, `pprint`, `csv`, `statistics`,
  `fractions`, `struct`, `calendar`, `uuid`.
- vm_audit76 (273): `fnmatch`, `glob`, `shutil`, `tempfile`, `pathlib`,
  `subprocess`, `platform`, `getpass`, `logging`, `unittest`, `queue`.
- vm_audit73 (292): `itertools`, `functools`, `operator`, `heapq`, `bisect`,
  `copy`, `contextlib`.
- vm_audit78 (147): `re` over a native engine (`include/NyRe.hpp`,
  `src/builtins/nyre.cpp`, Unicode tables generated by
  `tools/gen_re_tables.py`): CPython's `_parser.py` syntax and error
  messages, a backtracking machine with an explicit stack (no recursion,
  so huge subjects and deep nesting cannot overflow), and **selective
  memoization** (Davis, Servant and Lee, *Using Selective Memoization to
  Defeat Regular Expression Denial of Service*, IEEE S&P 2021): the
  (instruction, position) states reachable more than once are remembered
  when they fail, so a pattern without backreferences runs in O(program x
  subject) - `re.match(r"(a+)+$", "a" * 30 + "b")` answers in well under a
  second on both engines; python3 3.11 had not finished after 10 s.
- Gotcha met while merging: a module function stored as a class attribute
  is bound as a method now (Python's rule), so CPython's own
  `staticmethod(...)` wrappers are needed (`TestLoader.sortTestMethodsUsing
  = staticmethod(three_way_cmp)`, the functions of `lib/time.ny`'s `time`
  namespace class).

### The class-machinery modules (vm_audit74, 81-83; most checks also pass under python3)
Each is CPython 3.11/3.12's API and algorithm with its messages, written in
Nython over the class machinery above; each header says what is not there.
- **vm_audit74 (124): `abc`, `numbers`, `collections.abc`, singledispatch on
  ABCs.** `ABCMeta` is a real metaclass (`_py_abc`'s algorithm: abstract
  methods from the namespace and the bases, 3.12's "Can't instantiate
  abstract class X without an implementation for abstract method 'm'",
  `register`, `__subclasshook__`, positive/negative caches invalidated by a
  global token). `lib/collections` is a package now (`git mv` keeps the
  history): `collections/abc.ny` has all 26 ABCs with CPython's hooks and
  mixins and the builtin registrations (`isinstance([], Sequence)`,
  `isinstance({}, Mapping)`); `numbers` is the numeric tower with int,
  float, complex registered and `Fraction` a `Rational`. functools'
  singledispatch dispatches on ABCs (`_compose_mro`/`_c3_mro`) and
  registers by annotation (unions too).
- **vm_audit81 (116): `enum`, `dataclasses`.** `EnumType` is a real
  metaclass: members in definition order, `Color["RED"]`/`Color(1)`/
  `_missing_`, aliases, `@unique`, `auto()`, `IntEnum`/`StrEnum`/mixed-in
  types, `Flag`/`IntFlag` with 3.11's boundaries, the functional API,
  `member`/`nonmember`, `verify`, immutability, members in `match`.
  `EnumType.__prepare__` returns CPython's `_EnumDict` (see the next
  section): `auto()` is resolved on its own line and a name bound twice is
  refused. `@dataclass` with every
  parameter, `field()`, `KW_ONLY`, `InitVar`, ClassVar exclusion (also by
  the text of a string annotation), inheritance, frozen instances,
  `__match_args__`, `fields`/`asdict`/`astuple`/`replace`/
  `make_dataclass`, CPython's messages; all of a class's methods come from
  one `exec` of generated source (as 3.13 does).
- **vm_audit82 (140): `typing`, `types`, `inspect`, `keyword`.** typing:
  the special forms, Union/Optional (flattened, `==` to `X | Y`), the
  generic aliases with substitution, TypeVar/ParamSpec/TypeVarTuple,
  Generic (`C[int]()` sets `__orig_class__`), Protocol and
  `runtime_checkable`, NamedTuple (class and functional forms), TypedDict,
  NewType, `get_type_hints`, `get_origin`/`get_args`, overloads - plus
  **`typing.check_type(value, tp)`**, a recursive runtime check that names
  the path to the first mismatch (`value[1] is str, not int`; the idea of
  typeguard). types: SimpleNamespace, MappingProxyType, ModuleType,
  MethodType and stand-ins (FunctionType, GeneratorType, NoneType ...) whose
  metaclass answers isinstance for the engines' values. inspect:
  `signature` (functions, lambdas, bound methods, classes, partials,
  `__wrapped__`, 32 builtins), `Signature`/`Parameter`/`BoundArguments`
  with 3.11's `str()` and TypeErrors, the predicates, `getmembers`,
  `getdoc`, `getsource` and friends, plus **`inspect.signature_diff(a, b)`**:
  the calls `a` accepts that `b` would reject (a call-substitutability
  check, as type checkers apply to overriding methods). keyword: CPython's
  lists, and `nykwlist` read from the lexer's own table.
- **vm_audit83 (158): `weakref`, `warnings`, `traceback`, `linecache`,
  `atexit`.** weakref: `ref` with callbacks, `proxy`, `WeakMethod`,
  `WeakValueDictionary`/`WeakKeyDictionary`/`WeakSet`, `finalize`. warnings:
  `warn` (stacklevel from the running frames), the filter machinery with all
  six actions and regexes, once-per-location registries, `catch_warnings`,
  `PYTHONWARNINGS` and a new `-W` option, and PEP 702's
  `warnings.deprecated`. traceback: the whole module (`format_exception`
  with chains, `TracebackException`, `StackSummary`, "[Previous line
  repeated N more times]").
- **Engine work they needed (both engines):**
  - *function introspection*: `f.__code__` (`co_varnames`,
    `co_argcount`, `co_flags`, `co_firstlineno`...), `__defaults__`,
    `__kwdefaults__`, `__qualname__` (the parser records it; one a
    program assigns also names the function in call errors),
    `__module__`, `__globals__`;
  - *real tracebacks*: `e.__traceback__` (`tb_next`, `tb_lineno`,
    `tb_frame`), `__context__`/`__cause__`/`__suppress_context__`,
    `raise X from Y`, `sys.exc_info()`/`sys.exception()`/
    `sys._getframe()`; an uncaught exception prints Python's
    "Traceback (most recent call last):" block, chains included, before
    the existing `[Nython] Uncaught exception` / `[VMError]` line (which
    the IDE parses, so it is unchanged);
  - *weakref callbacks*, run at safe points;
  - *data descriptors* (`__set__`/`__delete__` on instance assignment);
  - *`__index__`* for indexing, slicing, `range`, `hex`/`oct`/`bin`/`chr`
    and `%d`; *`__hash__ = None`* makes instances unhashable;
  - *metaclass `__setattr__`/`__delattr__`* for `C.x = v`; *`reversed(C)`*
    through the metaclass; `isinstance(int, type)`, `int.__mro__`,
    `issubclass(MyList, list)`, `issubclass(C, (A, B))` asking each ABC;
  - class and instance `__dict__` list dunder names (they were stored as
    raw keys and read as internal markers); the parser's decorator
    temporaries are left out;
  - `mod.C()` goes through the metaclass and `__new__`; `lambda self:`
    binds self on the VM; a `**kw` collector keeps dunder keys;
  - module scopes start from a snapshot of the builtins and the prelude,
    so a program's top-level `list = []` no longer rebinds `list` inside
    every module;
  - Warning classes and ReferenceError; `-W` (into `sys.warnoptions`) and
    `-X` (accepted, ignored) on the command line;
  - fixes found on the way: `handling_obj_` was not saved across
    generator switches and thread switches (`sys.exc_info()` could give
    another thread's exception); a VM handler's `__excN__` stayed set after
    its clause; `hash(obj)` kept the object alive until a full collection;
    a `"` inside a triple-quoted string was dropped by the lexer; a class
    with annotations lost its docstring.
- **Cost**: a caught runtime error is ~10 µs (~40%) slower on the
  interpreter and ~5% on the VM (it now builds the exception object and a
  traceback entry).
- **Not provided** (each module's header has the full list): frames have
  no locals (`currentframe()` is None, no `inspect.stack`); weak references
  to functions, classes and sets; the abstract-class check is made in
  `ABCMeta.__call__`; registries hold classes strongly. (`__prepare__`,
  classes deriving from builtin types holding a value, `int.__new__` and
  NamedTuple as a real tuple subclass came later in round 77 - next section.)

### The class model: builtin subclasses, __getattribute__, a live __dict__, __prepare__ (vm_audit85, passes under python3)
- **Classes deriving from builtin types hold a value** (`class MyInt(int)`,
  `Celsius(float)`, `Name(str)`, `Blob(bytes)`, `Buffer(bytearray)`,
  `Stack(list)`, `Config(dict)`, `Tags(set)` / `frozenset`, `Point(tuple)`),
  the same way on both engines: an instance is an ordinary instance whose
  hidden field `__ny_payload__` (`nyrt::payload_field()`; a `__ny_*` name, so
  `vars()`, `__dict__` and `dir()` leave it out) holds the value, and where
  the builtin type stands in the class's MRO the engines put the type's
  *mirror class* (`_NyB_int`, `_NyB_list` ... - `nyrt::builtin_mirror`): the
  interpreter's `classMro` uses the mirror's node for a builtin base, the
  VM's `class_lookup` looks in the mirror's namespace at the MRO entry
  "int". The mirrors are Nython (`nyrt::builtin_mirrors_source()` in
  NyPrelude.hpp): each type's operators, reflected operators, comparisons,
  `__hash__` (None for the mutable ones), `__len__/__iter__/__contains__/
  __getitem__/__setitem__/__delitem__`, `__index__/__int__/__float__/
  __round__ ...`, `__repr__`/`__format__` (and `__str__` for str), in-place
  operators that mutate the value (`stack += [4]` keeps the Stack), its
  properties (`real`, `numerator` ...), its class methods (`fromkeys`,
  `from_bytes`, `fromhex` making the subclass) and a delegate for every
  regular method (`MyStr("a").upper()` is a plain str, as in Python), all
  over `_ny_payload(self)`. A subclass's own definitions come first; the
  type's own methods do not call its dunders (`dict.update` does not call
  `__setitem__`), as in CPython; dicts keep `__missing__`.
- **Making one**: the mirror's `__new__` is the type's: `T(*args)` made into
  the value for the immutable types (`MyInt("12")`, `Celsius("2.5")`), an
  empty value that `__init__` fills for the mutable ones (`list.__init__`,
  `dict.__init__` ...), so `super().__new__(cls, v)`, `int.__new__(cls, v)`,
  `str.__new__`, `tuple.__new__(cls, it)`, `float.__new__` work in a user
  `__new__`, and `super().__init__(items)` in a user `__init__`
  (`_ny_payload_new(cls, T, value)`: the value itself when cls is T,
  "int.__new__(S): S is not a subtype of int" otherwise).
- **Builtins get the value**: a builtin called with a payload instance gets
  its value (`math.sqrt(MyInt(16))`, `int(Name("12"))`, `os.path.join`,
  `json.dumps`, `",".join([Name("a")])`, `"abc".find(Name("c"))`, `MyStr in
  "text"`), except the ones that ask for the object itself - its class,
  dunders or identity, or store it (`nyrt::payload_transparent`: type,
  isinstance, repr, str, len, iter, hash, getattr..., min/max - which return
  the instance -, the `_ny_*` prelude natives, the thread/channel/queue
  natives). Interpreter: `callBuiltin`, `toSArg`/`toBArg`; VM: `vm_call`'s
  native path (named builtins only: a bound member stores what it is given),
  `to_sarg`/`to_barg`.
- **Keys**: a payload instance whose class keeps the type's `__hash__` and
  `__eq__` is the same dict key and set element as its value (`{5: "a"}[MyInt(5)]`,
  `{"bob": 1}[Name("bob")]`, `1 in {MyInt(1)}`) - `payloadKey` / `payload_key`.
  Iterating such a dict gives the key back as the plain value (CPython gives
  the first object stored).
- **On demand**: a type's mirror (and the shared helpers) is run the first
  time a class derives from the type, or one of its dunders is read from it
  (`int.__new__`, `dict.__setitem__`, `int.__repr__`), the "dictview" chunk
  at the first instance `__dict__` read; the text is in "#@ name" chunks
  (`nyrt::builtin_mirror_chunk`). A program that never does pays nothing
  (the mirrors cost ~5-10 ms to run).
- **Cost**: plain values take none of these paths (a builtin's arguments are
  looked at only once a payload instance exists, `any_payload_`); an
  operator on a payload instance is a call of the mirror's Nython method
  (`s + MyInt(1)` in a loop: ~3.5x a plain int `+` on the VM, ~5x on the
  interpreter).
- **`__getattribute__`** is dispatched on both engines: a class defining one
  (not object's) has it called for every attribute read on its instances -
  `obj.x`, `obj.m(...)`, `getattr`, `hasattr`, `?.` - then `__getattr__` when
  it raises AttributeError; `object.__getattribute__(self, name)` (prelude,
  `_ny_getattr_raw`) and `super().__getattribute__` are the normal lookup
  without `__getattr__`. The engines' own lookups of special methods
  (operators, `len`, `str`, `iter`) do not go through it, as in CPython.
  Nothing is looked for until some class defines one (`any_getattribute_`;
  per-class answers cached with the `__setattr__` hooks').
- **`obj.__dict__` is live** (it was a copy): `obj.__dict__` and `vars(obj)`
  are one object while it is alive - an instance of the prelude's
  `_NyInstanceDict` (a dict subclass) whose value is a fresh dict of the
  object's fields at every read (`payloadOf` of a view), so every dict
  operation and builtin sees them as they are; `d[k] = v`, `del d[k]`,
  `update`, `pop`, `setdefault`, `popitem`, `clear`, `|=` store and remove
  fields directly (`_ny_setfield` / `_ny_delfield`, past `__setattr__` and
  descriptors, as CPython's instance dict). The view holds the object; the
  object finds its view through a table that does not hold it, so reading
  `__dict__` makes no cycle. `obj.__dict__ = d` replaces the fields.
  Dunder attributes are listed (`self.__marked__`). `C.__dict__` is still a
  copy of the class namespace. Differences: `type(vars(o))` is
  `_NyInstanceDict`, not dict (isinstance(..., dict) holds).
- **`__prepare__`**: a metaclass's `__prepare__(name, bases, **kw)` is
  called before the class body; each name the body binds goes to the
  mapping it returned, in order, through its `__setitem__` (a name bound
  twice is seen twice; a decorated def once, decorated - the parser's
  `__decN__ = D; def f; f = __decN__(f)` is recognised by
  `nyrt::decorator_binding`), and the body then reads back what the mapping holds
  for it (so a mapping that turns `None` or `auto()` into numbers is seen
  by the next lines); the mapping is the `ns` the metaclass's `__new__`
  gets, and `type.__new__` makes it the class's namespace. Interpreter:
  `Context::storeHook` on the class body's scope (evalClassDecl,
  `prepareStore`); VM: `CallFrame::prep_ns`, STORE_NAME / DEFINE_NAME in a
  class body (`prepare_store`). What differs from CPython: the body runs in
  the engine's own namespace, so its reads do not go through the mapping's
  `__getitem__`; `del name` in the body does not call `__delitem__`; a name
  the mapping refuses to hold stays in the class; the mapping does not
  receive `__module__` / `__qualname__`.
- **Libraries**: enum's `EnumType.__prepare__` returns an `_EnumDict` (as
  CPython's): a member name bound twice is "'A' already defined as 1",
  `auto()` gets its value on its own line (`RW = R | W` is exact; the
  deferred `_AutoExpr` workaround is gone), `_generate_next_value_` after a
  member is refused at once; members of a mixed-in builtin type are values
  of it (`int.__new__(enum_class, v)`, StrEnum's `str.__new__`, Flag's
  pseudo-members), so a user `__new__` calling `int.__new__` works, and an
  IntEnum member is the same dict key as its int (`{1: x}[Level.LOW]`);
  only a complex enum still delegates to `_value_`.
  collections.namedtuple and typing.NamedTuple are tuple subclasses
  (`isinstance(p, tuple)`, slicing, hashing and JSON as an array). copy /
  deepcopy make a payload instance again with its value.
- **Engine fixes this needed (both engines unless said):** `self = expr`
  was dropped (the interpreter's `evalAssignment` had no SELF target; the
  VM's `store()` emitted nothing for it and left the value on the stack -
  new op `STORE_SELF`); the VM's `x |= y` (and `/= %= //= **= &= ^= <<=
  >>=`) went straight to `__or__`, so `__ior__` ... were never called (the
  aug-assign now emits the binary op with arg 1, which tries `__i<op>__`
  first); the VM's constructor lookup (`find_ctor`) and `dir()` did not look
  in a builtin base's mirror; `str.upper(MyStr("q"))` (a type's method on a
  subclass instance) was "descriptor 'upper' ... doesn't apply";
  `"%s %s" % TupleSub(...)` / `"%(k)s" % DictSub(...)` use the value's items
  / keys; `T.__new__(S)` for another builtin S is "int.__new__(str): str is
  not a subtype of int"; a builtin subclass instance made by
  `object.__new__` is a TypeError at its first use ("holds no int value"),
  not an endless recursion; a class with an `__iter__` of its own (Flag's,
  a list subclass's) is given to builtins as itself, so `list(flag)`,
  `sorted(x)`, `map(f, x)` iterate through it (`iterOverridden` /
  `iter_overridden`); `f(**DictSub(...))` (the interpreter dropped it
  silently, the VM raised) and any mapping object (keys() and []) for `**`;
  `{**d}` takes a dict subclass's own items, not its `__getitem__`'s, as
  CPython's dict_merge; `for a, b in` over object items unpacks them by
  iterating (interpreter; it bound only `a`); a sequence pattern matches a
  tuple (`case (a, b):` never matched a tuple, on either engine - the test
  was `isinstance(x, list)`).

### Files and time, found under Wine (vm_audit75-77)
- **`open(newline=...)` is Python's** on both engines (the prelude's `open`
  and the VM's native one): `None` translates as the platform does, `""` and
  `"\n"` write text untouched and read line ends as they are, `"\r"`/`"\r\n"`
  replace each `\n` on write; an illegal value or a newline for a binary
  file is a ValueError. An explicit newline opens the native handle raw, so
  the Windows C runtime does not translate underneath: csv's `open(...,
  newline="")` wrote `\r\r\n` there. `open()` takes Python's positional
  order (`file, mode, buffering, encoding, errors, newline`; encoding was
  third).
- **UTC by arithmetic** (`utc_tm` in `src/builtins/os_time.cpp`, Hinnant's
  `civil_from_days`): `time.gmtime`, `datetime.fromtimestamp(t,
  timezone.utc)` and the other UTC conversions no longer ask the C library,
  whose Windows `gmtime_s` refuses times before 1970 (OverflowError there;
  CPython raises OSError on Windows for the same call) and whose 32-bit
  `time_t` ends in 2038. Local time still comes from the platform.
- **`os.utime` / touch on Windows** use `SetFileTime` with backup semantics
  (`win_set_times`): the CRT's `_utime` cannot open a directory
  (PermissionError) and kept whole seconds; times are now set to 100 ns.
- **Local times before 1970 on Windows**: `localtime_s` refuses them too;
  `to_tm` then applies the zone's standard bias (`GetTimeZoneInformation`)
  to the UTC arithmetic above (no DST rule for such dates, as the CRT has
  none either). `datetime.fromtimestamp(t)` for `t` within a day of the epoch
  skips the fold probe on Windows, as CPython does (it raised OverflowError).
- **vm_audit76 is portable**: symlink checks run only where a symlink can be
  made (an unprivileged Windows account cannot), and the subprocess checks
  run a Python child (`[sys.executable, "-c", ...]`) instead of POSIX tools,
  which stay checked where `sh` exists.
- **A cancelled task waiting on a socket was never woken** (an asyncio
  program that had served one connection never returned from
  `asyncio.run` on Windows - vm_audit67 hung under Wine):
  `task_cancel_locked` wakes only a `blocking` task and `wait_io_task` never
  set the flag. On Linux the socket that `Server.close()` closes under the
  accept loop hid it - `poll` flags the closed descriptor (POLLNVAL) and
  wakes the task - but `WSAPoll` fails the whole call for one invalid
  socket, so the reactor spun. Both fixed in `src/NyConc.cpp`: the waiting
  task is `blocking` (not `blocked_forever`: no deadlock to report), and a
  failed `WSAPoll` is retried socket by socket to give the invalid one an
  error, as POLLNVAL would.
- **strftime is Nython's own, the same everywhere** (`format_tm` in
  `src/builtins/os_time.cpp`): every C-locale directive, with glibc's output
  as the reference (CPython on Linux) - Windows' C runtime formatted
  `%c`/`%x`/`%X` by its locale (`1/5/2024 3:04:05 AM`), padded `%Y` to four
  digits, lacked `%e %k %l %s %P %G %V %u %C %n %t` and aborted on a directive
  it did not know. glibc's flags (`%-d`, `%_H`, `%^a`, `%#p`, `%010Y`) and
  widths work on every platform; an unknown directive is copied as written;
  `%z`/`%Z` still ask the C library (only it knows the zone; `time.strftime`
  fills them from the tuple first, as CPython). Checked against python3's
  `time.strftime` on 30,000 (directive, date) pairs, years 1 to 9999, ISO weeks
  at every year boundary.
- **A file dropped without `close()` is closed** when its last reference
  goes (`NythonFile.__del__`, both engines), as CPython's io objects:
  `open(p).read()` kept its handle to the end of the program, and Windows
  cannot delete or rename an open file (vm_audit76's cleanup failed there).
- **`urllib`'s default HTTPS context is made by the first https request**:
  `build_opener()` puts an `HTTPSHandler` in every opener and its constructor
  made the context, so without OpenSSL (a Windows system without its DLLs)
  every `urlopen`, plain http included, raised SSLError - vm_audit70 then
  waited for its server threads forever.
- **`urllib.request.pathname2url`/`url2pathname` on Windows** are CPython's
  `nturl2path` (`C:\x\a.txt` <-> `///C:/x/a.txt`, UNC paths with the slashes
  doubled); they only quoted, so `"file:" + pathname2url(p)` was no URL there.
  Checked under Wine against CPython's own `nturl2path` answers. vm_audit70
  builds its file URL that way (`"file://" + path` is not a URL on Windows).
- **WebSocket servers close a failed connection with a lingering close**
  (`_lingering_close` in `lib/websocket.ny`; RFC 7230 6.6, as Apache): the
  Close frame, a half-close, then up to 1 MB / 2 s of the peer's input read
  and dropped before the socket is closed. A connection failed for a bad
  frame always has unread input (the rest of that frame), and closing a
  socket with unread input sends a TCP reset, which discards what the peer
  has not read yet - on Windows the client never saw the Close frame and got
  ConnectionResetError (vm_audit70's protocol-error checks).
- **Accept loops read their socket once** (`TCPServer.accept` in
  `lib/sockets.ny`, `UnixServer.accept`, `Server.listen` in
  `lib/clientserver.ny`): `stop()` on another thread sets the attribute to
  none, and under Windows' timing the loop then called `none.accept()`
  ("Exception in thread ... AttributeError").
- **vm_audit76 is portable throughout**: paths in messages are compared through
  `tpath` (TMP as `T`, `/` as the separator, raw or repr'd); on Windows the
  permission bits read 0o666/0o777 (only a read-only flag exists), a text file
  written with `\n` is 14 bytes (`\r\n`), `which` finds commands by PATHEXT,
  and `Path("~/x").expanduser()` is compared as a path - CPython's results there.
  Under Wine it runs 243 checks (the POSIX-only ones skipped), on Linux 280.
- **Windows errors carry `winerror`** (after vm_audit87's OSError fields):
  a runtime error reported as `[WinError N] text` (`os.get_terminal_size()`
  off a console, symlinks, sockets in `net.cpp`) becomes `OSError(errno,
  strerror, filename, N)`: `winerror` is N, `errno` the one CPython maps it to
  (`ny_winerror_to_errno`, PC/errmap.h's table with the platform's errno
  constants; Winsock codes are their own errno) and `str(e)` keeps the
  `[WinError N]` form - on Windows only, as in CPython; elsewhere nothing
  changes. vm_audit46 compares the file name in a message with its repr (the
  OS layer quotes names as CPython does, doubling Windows' backslashes).
- **32-bit Windows (i686, under Wine), round 77 at 49cca9a**: 401 runs, one
  failure - vm_audit74 compared `collections.abc.Set._hash()` with 64-bit
  values; CPython's algorithm masks with `sys.maxsize`, and Nython's 32-bit
  values are exactly CPython's for a 32-bit word, so the test now picks by
  `sys.maxsize`. The i686 link warns "duplicate section ...class_dir_names...
  has different size": GCC aligned that function-local static to 8 (padded to
  16 bytes) in one unit and to 4 (12 bytes) in another - the same object,
  only the padding differs, so it is harmless.
- **AArch64 (qemu-user), round 77 at ec3d5b6** (`make cli BUILD=build-arm64
  CXX=aarch64-linux-gnu-g++`, run with `qemu-aarch64 -L
  /usr/aarch64-linux-gnu`): vm_audit49, 54, 55, 56, 60, 64, 65, 67, 69, 72,
  79, 84, 85, 86 and 87 pass on both engines - the assembly context switch
  under generators and async tasks, the memory suites, and the round's
  language, class-model and value suites.

### A running program's input (vm_audit71, tools/ide_e2e.py `run`/`terminal`)
- The IDE closed a program's stdin (`os_spawn(..., input="")`), so its first
  `input()` raised EOFError, and since output was shown a line at a time a
  prompt (no newline) never appeared. `os_spawn(cmd, stdin=true)` keeps the
  pipe open: `os_proc_write(pid, text)` (GIL released; a duplicate descriptor,
  so a concurrent close or reap cannot redirect the write) and
  `os_proc_close_stdin(pid)` (EOF). BrokenPipeError once the child is gone.
- **Input requests**: with `NY_INPUT_REQUEST` set, every read of stdin -
  `input()`, `sys.stdin.readline()/read(n)`, both engines, all through
  `nyconc::read_stdin_line` / `announce_input_request` - first writes
  `nyconc::INPUT_REQUEST_MARK` (`ESC ] ny;input BEL`, an OSC sequence a
  terminal ignores) to stdout. This is Jupyter's stdin channel
  (`input_request`/`input_reply`) carried in-band on the output pipe: the host
  learns that the program waits and that the text since the last newline is
  its prompt, without a side channel or polling `/proc` for a blocked read.
- `BgProc.start(cmd, cwd, interactive)` (ide_ops.ny) strips the marks
  (`_take_requests`, a mark split across reads waits in `.partial`), and has
  `wants_input`, `send_line` (returns the pending prompt + text, the line a
  terminal would show) and `close_input`. Run/Debug jobs and Terminal
  commands are interactive.
- **Output panel**: while the program runs, its last row is the pending
  prompt followed by an input field (`focus == "stdin"`, a LineEdit like
  every other field); a bar marks it while the program waits. When the
  program asks, the panel comes up and the field takes focus - unless text
  was typed in the editor in the last 1.2 s. Enter sends, Up/Down recall
  sent lines, Ctrl+D ends the input, Ctrl+C (no selection) stops the program.
- **Terminal**: a running command reads typed lines (`read x`, `cat`, a
  Nython program's `input()`); its pending prompt replaces the shell prompt;
  Ctrl+D ends its input. It used to answer "A command is still running".
- **Windows**: a child's output is read with `\n` line ends, as Python's text
  mode reads it (universal newlines; `text_newlines` in os_proc.cpp, a `\r`
  that ends one `os_proc_read` chunk waits for the next). Every line
  `os_run`/`os_exec`/`os_proc_read` returned there ended in `\r`. POSIX output
  is passed through byte for byte, as before.

### Not done / known differences
- `obj.__dict__` is live (above), but `type(vars(obj))` is the prelude's
  `_NyInstanceDict` (a dict subclass), and `C.__dict__` is still a copy.
- ~~Coroutine objects are task handles (ints)~~ - real coroutine objects
  since round 78 (§0q).
- ~~Found with vm_audit86, not fixed: no name mangling; on the VM a method
  whose first parameter is not named `self` is not bound; calling a
  non-callable gives none; functions have no `__call__`; `type(module)` is
  `dict`; `super(C, obj)` as a value is the parent-constructor shorthand; an
  instance field is read before a class data descriptor;
  `C.__dict__["__new__"]` is not a staticmethod; `iter(range(n))` is a
  `list_iterator`; objects with `__hash__` are keyed by class name plus
  hash~~ - all fixed in round 78 (§0q, §0q3).
- ~~Frames have no locals; weak references are to instances only~~ - real
  frame objects and weak references to functions, classes and sets since
  round 78 (§0q). Classes deriving from `complex`, `range`,
  `memoryview` ... (types with no mirror class) still hold no value; a dict
  keyed by a payload instance gives the key back as the plain value.
- A metaclass's `__prepare__` mapping sees the body's bindings, but the body
  still runs in the engines' own namespace (reads do not go through the
  mapping, `del` in the body does not reach it - see above), and
  `type.__new__` called by a metaclass for a *different* name than the
  statement's makes a new class rather than adopting it.
- Syntax (vm_audit84): ~~`class C(*bases)`; a statement that is only a set
  display (`{x}` alone on a line) is still a block; `return`/`break`/
  `continue` inside an `except*` clause are not rejected~~ (round 78,
  §0q3); `\N{}` knows no
  name aliases or named sequences, and unicodedata has only `lookup`/`name`;
  `elseif` and `super` stay reserved words; a walrus in a generator
  expression consumed after its function returned binds nowhere visible;
  rebinding `self` in a scope nested inside a method; ~~int's dunder methods
  as values (`(5).__add__`)~~ (round 78, §0q3).
- Video/audio builtins remain stubs (no codec library).

## 0o. Round 76 — the "Not done" lists closed

Every item the round 74-75 sections listed as not done was taken up; what
is still open is listed at the end. Tests: `examples/vm_audit63.ny` (scope,
lambdas, print, columns, lazy iterators; 59 checks), `examples/vm_audit64.ny`
(memory; 26 checks), and new sections of `vm_audit48` (rwlock) and
`vm_audit49` (tasks as coroutines). The new checks were run against round
75's build too: they fail there (vm_audit64: 12 of 26 on the interpreter,
10 on the VM; vm_audit49: 2002 OS threads for 2000 tasks, and the bare
`raise` below).

### Static scope checks (`include/NyScope.hpp`, `src/NyScope.cpp`)

One pass over every parsed program (`Parser::parse`), shared by both
engines, after the whole tree exists. It builds the scopes (module,
functions and lambdas, class bodies, comprehensions), resolves every write
by the round-75 ruling, and:
- **`const` is enforced.** Assigning, augmenting, deleting, re-declaring,
  unpacking into or looping over a const - in its scope, or in a function
  whose plain assignment would rebind it, or through `global`/`nonlocal` -
  is a SyntaxError before the program runs (`cannot assign to constant 'K'
  (declared on line 1)`). A `const` statement that runs again (a loop, a
  second call) re-initialises the same declaration and is fine; a local
  (`var`, a parameter) shadows it; a class attribute of the same name is
  the class's.
- **`nonlocal x` needs an enclosing function that binds x** (class bodies
  skipped, a later binding in that function counts), and is an error at
  module level or together with `global x` - Python's three SyntaxErrors.
- **`global` reaches the binding forms the parser cannot see**: a walrus,
  `except ... as` and `with ... as` of a name declared global bind the
  module's variable (`WalrusNode::global_ref`, `ExceptNode::var_global`,
  `WithNode::alias_global`; `STORE_GLOBAL_NAME` on the VM). The parser now
  keeps `global`/`nonlocal` in the tree as `GlobalNode`s (no-ops on both
  engines) so the pass can see them.
- Not checked: bindings made at run time (code strings run by `lang_eval`,
  `setattr` on a module), and each REPL line is checked on its own.

### Lambdas, print, error columns (interpreter)
- **A lambda closes over its scope by reference**, as `def` does: it calls
  itself through the name it is assigned to (`fact = lambda n: ... fact(n -
  1)` raised NameError), and `[lambda: i for i in range(3)]` gives 2, 2, 2
  (it gave 0, 1, 2, Python and the VM 2, 2, 2). It used to copy every
  visible binding when made, the whole module for each lambda. Its default
  values are evaluated when it is made, as a def's are (`lambda i=i: i`
  keeps each i).
- **`print(a(), b())` evaluates both arguments before printing** (it printed
  `a`'s output, then `a()`'s value, then `b`'s output).
- **Syntax errors name the right column.** `Location::reset` ignored its
  column argument, so every token's column was reset to 1 and every error
  said column 2 (the IDE's diagnostics landed at the start of the line). A
  token is now located where it starts; a column counts characters (a tab
  is one, a UTF-8 sequence is one), and the caret under the source line in
  the command line's report is placed by characters. Tokens that span
  lines keep the row where they end, as before (statement lines for
  tracing and the debugger come from those rows).
- **IndexError reads `list index out of range`** (or tuple) on the
  interpreter too, as on the VM and in Python.

### Lazy iterators
`zip`/`map`/`filter`/`enumerate`/`islice` over a generator, and `iter()`,
print as Python prints them (`<zip object at 0x...>`) and have no `send` or
`throw` (AttributeError; `send()` acted as `next()`). `isinstance(x,
"generator")` is true for every lazy iterator - it read false even for a
generator, on both engines. **Ruling:** `type()` stays `"generator"` for all
of them. Python's names would be `zip`, `map`, ..., but Nython's dict is
already the type `"map"`, and `isinstance(x, "map")` cannot mean both.

### rwlock: competitive succession (`src/NyConc.cpp`)
A waiting reader's or writer's predicate took the lock as the thread woke,
before it had the GIL: the lock sat with a thread that could not run while
every other thread queued behind it, and every unlock woke every waiter.
Now, as for the mutex since round 75, a lock is taken only by a running
thread: an unlock wakes one waiting writer (the heir; no other writer is
woken while it is on its way) or, with no writer waiting, every waiting
reader. Writers still go first. Readers and writers wait in separate
queues. New builtin `rwlock_waiting_writers(rw)`.

| 6 writers x 3000 locks, each sleeping now and then | waits before | after | time before | after |
|---|---|---|---|---|
| interpreter | 33,922 | 144 | 1.48 s | 0.26 s |
| VM | 17,699 | 61 | 0.65 s | 0.09 s |
| 3 writers + 5 readers (interpreter / VM) | 17,597 / 6,649 | 169 / 96 | | |

### Async tasks are coroutines on the loop's thread
A task was an OS thread handed a baton through the GIL's queue: each switch
put one thread to sleep and woke another, and 2000 tasks were 2000 threads.
A task is now a stackful coroutine (`NyCoro`, as the interpreter's
generators) on the thread that runs its loop:
- `grant()` resumes the task's coroutine; a task that blocks - any blocking
  primitive, through the one `block()` they all use - switches back to the
  loop in `task_park()`. At every switch the thread holds the GIL and not
  the runtime mutex, and the engine state moves with it (`switch_state`:
  `Engine::swap_out`/`swap_in`). Everything else is as it was: a task keeps
  its `ThreadRec` (id, thread-locals, its place in the wait-for graph),
  cancellation, timers, `gather`, `wait_for`, and a task blocked on a real
  thread's queue, lock or join still lets the loop's other tasks run.
- **A task blocking inside a generator's body** (the interpreter runs each on
  a coroutine of its own, nested in the task's) leaves through every
  coroutine it is nested in: the generator's coroutine suspends with a
  relay request; the resumer (`nygen::resume_function`, and calls running
  on an extension stack) saves the generator's state as at a yield, calls
  `nyconc::relay_park()` - which relays again or switches to the loop - and
  resumes the generator when the task runs again (`NyConc.hpp`).
- **The interpreter got a real per-thread state swap** (`InterpEngine::State`
  in `threading.cpp`: call depth, control flow, last statement, the
  exceptions being handled, the owner stack, the trace stack, the running
  generator). Before, only the `thread_local` parts were per thread, so
  every thread shared one exception stack: a bare `raise` in one thread or
  task could re-raise another's exception (vm_audit49 "bare raise per task"
  gave `['second', 'first']` on round 75's build).
- A task's stack is the generators' (NY_GEN_STACK_KB, 1 MB, committed as
  used) on a 64-bit system and 256 KB on a 32-bit one, where 2000 tasks of
  1 MB took the whole 2 GB address space (the 32-bit Windows sweep:
  MemoryError). A call that finds a coroutine's stack nearly used continues
  on an extension stack on **both engines** now - the interpreter did this
  for generators (`nygen::call_on_new_stack`); the VM's `run_frame` does it
  too (it raised RecursionError there) - so a task recurses to the engine's
  depth limit whatever its stack, and blocks there (relayed through the
  extension). vm_audit49 passes with 64 KB stacks on both engines.
  **Wine** reserves at least 1 MB per fiber stack whatever is asked for
  (Windows itself rounds to 64 KB), so the 32-bit build under Wine holds
  about 1800 suspended tasks (2 GB); vm_audit49 uses 1500 when
  `sys.maxsize` (new, Python's: 2**31 - 1 on 32-bit, 2**63 - 1 on 64-bit,
  both engines) says 32-bit, 2000 otherwise. Linking the 32-bit build
  large-address-aware would give it 4 GB on 64-bit Windows - not done (it
  needs an audit for pointers read as signed 32-bit values).
- `dispatch_io` and `dispatch_network` kept a 64 KB read buffer on the stack
  (and `os_run`'s pipe drain): GCC reserves it for every call of the
  dispatcher, so every builtin the chain passes through them touched 64 KB
  of stack - a crash near the floor of a small coroutine stack. On the heap
  now.
- `thread_wait_count()` counts OS-level sleeps: a task switch is not one.

| | round 75 | round 76 |
|---|---|---|
| 2000 tasks gathered, interpreter / VM | 0.60 s / 0.31 s | 0.23 s / 0.07 s |
| 8000 task switches, interpreter / VM | 0.27 s / 0.25 s | 0.09 s / 0.02 s |
| OS threads while 2000 tasks are alive | 2002 | 1 |

### Memory (both engines)
- **Objects used as dict keys are freed.** A dict keyed by an object stores
  the object's identity as the key text, and the engine keeps the object in
  a table to give it back (`key_objs_`, `vm_key_objs()`); that table kept
  every object ever used - or only looked up - as a key alive until the
  program ended. In a full collection its references are now discounted, a
  dict that is reached reaches the objects its keys name (object keys and
  object keys inside tuple keys), and the entries of objects found
  unreachable are dropped (`nygc::KeyTable` in `NyGC.hpp`; the same steps
  in `VMGC.cpp`). A cycle through a key (a node keyed in a dict it holds)
  is collected. Young collections leave the table alone (an old dict is not
  traversed there), so its entries are roots then.
- **A cycle through a suspended generator is collected** on the interpreter
  (it leaked: a suspended generator's references were invisible). The
  collector now sees what a generator holds through its record (its scope,
  the values in flight, the iterators it reads), and a suspended generator
  is finalizable: an unreachable one is closed before anything is cleared
  (PEP 442's order) - its finally blocks run and its stack unwinds - and
  then freed. References on its suspended stack still look external (they
  keep what they reach alive), so a cycle is found when every reference
  into it is one the collector sees, the usual case. Another thread's
  suspended generator is never found unreachable (only that thread may close
  it). **The VM** collected such cycles already but cleared the generator
  without its finally blocks; it now closes it first, as Python does.
- **Bound builtin members** (`f = xs.append`, an object-protocol member read
  as a value) are heap objects (`nyheap::BMember`) freed with their last
  reference; they were kept, receivers included, for the life of the
  process (2000 `xs.append` reads kept 2000 lists).
- **The old `GarbageCollector` is gone** (`src/GarbageCollector.cpp`, its
  headers, and `include/Evaluator.hpp`, the only code that allocated
  through it and which nothing used).
- **`mem_rss_kb()` / `mem_peak_rss_kb()` work on Windows** (the working set,
  through `K32GetProcessMemoryInfo`, or `psapi.dll`'s on Vista); they read 0.

### Found while verifying
- **VM: `import nytorch` replaced 171 builtins with older copies.**
  `register_nytorch_builtins()` holds an old block of general builtins as
  well as the tensor natives; the VM registers it first at start-up and the
  current versions over it, but `import nytorch` (and `nytorch_classes`)
  registered it again. After the import - `lib/aiagent.ny` does it - `repr`
  left newlines unescaped, `ord("é")` gave 195, `chr(233)` a broken byte,
  `sorted(gen)` a list holding the generator, and the GIL-aware sleeps were
  gone. The import is an acknowledgement now (vm_audit63 checks it).
- **Tests that shared a port or a file between their two sweep runs.** The
  sweep runs each file on both engines at once: `v18_network_test` and
  `v19_io_net_test` bound fixed ports (one run's client could reach the
  other's listener: a hang to the 180 s timeout, an empty recv), and
  `test_os` / `test_aiagent` wrote fixed `/tmp` paths. They bind port 0 and
  read it back (`socket_getsockname`) and use per-pid paths now. This is
  what made the Windows sweep under Wine fail now and then (a different
  file each run; round 75's build did the same).
- **Windows: `socket_bind` set SO_REUSEADDR**, which on Windows lets a second
  socket bind a port in use (both then get connections). Not set there any
  more (Windows' default already rebinds past TIME_WAIT), as Python's
  `socket.create_server` does: a second listener gets a bind error.
- **Two processes overwrote each other's staged programs.** `Toolchain`
  (`lib/ide_toolchain.ny`, the IDE's REPL, command line, profiler and
  PROBLEMS check) staged source as `nyide_<n>_<name>` in the temp directory
  with `n` counting from 1 in every process, and the IDE ran an untitled
  buffer as `nyide_run_<n>.ny`: two IDEs - or a test run on both engines at
  once (`gui_tests/test_27`, 3 failures in 48 parallel runs) - ran each
  other's programs. The names carry the process / session id now, and a
  staged file is removed once its output is captured (they piled up).
  `vm_audit43` committed with a shared `/tmp/ny_audit43_msg.txt` (1 in 40).
- `lib/aiagent.ny`'s `IdeIntegration.format_code` never advanced its loop
  (an infinite loop on any input) and indexed an empty list; fixed. Nothing
  called it.
- On AArch64 under qemu-user, `vm_audit48`'s interpreter run times out its
  20 s thread joins (8 threads x 10k locks run ~10x slower emulated); the
  same work scaled down gives the exact counts, and the VM run passes.

### Not done
- The VM collector still cannot see references held in natives'
  `std::function` captures or code-object constants (cycles through them
  leak, safely), and the interpreter's `Value` is still 208 bytes.
- A finalizer that resurrects a dict keyed by an object whose table entry
  was dropped in the same collection would find that key's object gone
  (`keys()` gives none for it). Not seen in practice.
- An async task that blocks inside a generator's finally block while the
  collector is closing that generator would switch out in the middle of a
  collection (a `__del__` that blocks has the same problem).
- A generator dropped by another thread than the one that started it is
  still left suspended; the end-of-program close still runs only after a
  normal exit.
- Code strings run at run time and REPL lines are not scope-checked against
  each other (see above).

### Verification
- Linux: the sweep (every file, both engines) 355 runs, 0 not ok, no
  regressions against the baseline; `ide_e2e` 365/365; `ide_memprobe
  --check` (idle, hover, typing 0 KB); `ide_lint`, `ny_classcheck`,
  `cbp.py check` clean.
- Windows under Wine, built from `nython.cbp` (`tools/cross_windows.sh`):
  64-bit and 32-bit both 355 runs, 0 not ok, 0 warnings; `pe_unwind_check`
  passes on the 64-bit build. `mem_rss_kb()` reads the working set. (Final
  runs at 04926df; the Linux sweep and `ide_e2e` 365/365 there too.)
- AArch64 (`make cli BUILD=build-arm64 CXX=aarch64-linux-gnu-g++`, run
  with `qemu-aarch64 -L /usr/aarch64-linux-gnu`): vm_audit54, 55 (4059),
  56, 60, 64 and 49 pass on both engines (the asm context switch, async
  tasks on it, generators relaying); vm_audit63 passes but for its 4
  subprocess checks (an AArch64 binary cannot be exec'd without binfmt);
  vm_audit48 passes on the VM and times out on the interpreter (above).

---

## 0m. Round 75 — strict reads, optional chaining, declarations, suffix literals

Three rulings from the user, implemented on both engines with identical
behaviour. `examples/vm_audit57.ny` pins all of it (212 value checks, both
engines). Branch `round75-sem`.

### 1. Missing attributes and dict keys raise; absence has its own syntax

The ruling: *"reading a missing attribute or dict key still returns none,
because the GUI library relies on it. but you should be able to handle like
that with none or undefined, just fix everything so that it works"*. Done as:
reads raise as in Python, the language gives first-class ways to handle
absence, and everything that relied on the lenient reads was migrated.

| On both engines | Now | Before |
|---|---|---|
| `obj.name`, `name` missing | AttributeError: `'C' object has no attribute 'name'`; `type object 'C' ...` for a class; `'NoneType' ...`, `'dict' ...` (a dict read with `.`), `'str'`/`'list'`/`'int'`/`'function'` ... | none |
| `d[k]`, `k` missing | KeyError; `str(e)` is `repr(k)` | none |
| `none[k]`, `5[0]`, `f[0]` | TypeError: `'NoneType' object is not subscriptable` | none |
| `none.m()`, `"s".nosuch()`, `[].nosuch()` | AttributeError | none (the VM called a global native of that name, dropping the receiver) |
| `none.x = v`, `5.x = v`, `len.x = v` | AttributeError | silently dropped |
| `f.x = v`, `f` a function | kept and readable, as in Python | silently dropped |
| `xs.append` read as a value | a bound method | none on the interpreter; on the VM a native even for names that do not exist |
| `del obj.x` | removes it; AttributeError if absent | left `x` holding undefined |
| `del x` | unbinds `x` (a later read is a NameError) | `x` read undefined (interpreter) / none (VM) |

Which methods a builtin value has (for a read, `hasattr` and `?.m()`) comes
from one table both engines use, `include/NyMembers.hpp`: the union of the
names their method dispatch implements, plus the object protocol.

**The graceful forms.**
- `getattr(o, n)`, `getattr(o, n, d)`, `hasattr`, `setattr` and the new
  `delattr` work on every kind of value, as in Python: an AttributeError
  raised by a property or by `__getattr__` counts as absence; any other
  error propagates.
- `d.get(k)`, `d.get(k, d)`, `d.setdefault(k, v)`, `k in d`, `d.pop(k, d)`.
- **Optional chaining.** A `?.` / `?[` link is *absent* when its receiver is
  none or undefined, or when the attribute, key or index it names does not
  exist (a missing attribute, a missing dict key, an index out of range, or
  `__getitem__` raising KeyError / IndexError). An absent link makes the
  whole rest of its postfix chain none, and nothing more in the chain is
  evaluated: not the arguments of a call, not a later index. A present link
  behaves exactly like `.`/`[]`/`()`, and every plain step after it stays
  strict: `a?.b.c` raises when `a.b` exists but is none (write `a?.b?.c`).
  Spellings: `a?.b`, `a?.m(args)` (skipped when `a` has no member `m`),
  `a?[k]` and `a?.[k]`, `a?[i:j]`, `f?.(args)` (skipped when `f` is
  none/undefined). A type error is not absence: `5?[0]` raises TypeError.
  An optional chain cannot be assigned to (SyntaxError).
- `a ?? b` is `a` unless `a` is none or undefined; `b` is evaluated only
  then. It binds looser than `or` and tighter than both ternaries, groups to
  the right, and may be the condition of `x if c else y`.
- `t ??= v` assigns `v` (evaluated only then) when `t` is none or undefined,
  or - for an attribute or key target - missing; the target's object and
  index are evaluated once. For a plain name the name must exist (an unbound
  name is a NameError, as a read of it is).

The C-style ternary keeps working. `??`, `??=` and `?.` are tokens, except
`?.` followed by a digit (`c ? .5 : 1`). `?[` is optional indexing only when
the `?` is glued to its receiver (`a?[k]`), so `c ? [1] : [2]` is still a
ternary; `a?.[k]` is always optional indexing. A user-registered dynamic
`??` operator could never have worked (`?` is lexed before the dynamic
operator scan); `lib/langdef.ny`'s example now uses `$$`.

**`undefined` and none.** Both engines have a value `undefined` distinct from
none (`undefined == none` is false, `undefined == undefined` true, it is
falsy, prints `undefined`, `type()` is `"undefined"`). Where each appears:
- none: the `none` literal, `var x` with no initialiser, a function that
  returns nothing, `d.get(k)` for a missing key, `?.`/`?[` for an absent
  link, `getattr(o, n, none)`.
- undefined: only where the program writes it (the literal, a default
  `b=undefined`, a value copied from one). The runtime never produces it for
  absence: missing reads raise, and `del x` now unbinds.
- `??`, `??=`, `?.` and `?[` treat both as absent.
- The VM compiled the `undefined` literal to nothing (the stack was off by
  one after it) and read a variable holding undefined as none. It is now
  `VMType::UNDEFINED` tagged `"undefined"`, distinct from the untagged
  "not found" sentinel that frames and parameter defaults use
  (`VMVal::is_missing`).

**Implementation.**
- Interpreter: `getAttrValue(obj, name, ctx, out)` is the one non-throwing
  attribute lookup; `evalAttribute`, `hasattr`/`getattr`, `?.`, `??=` and the
  method-call fallback all use it (the `receiver_cache_` hash lookup every
  attribute read used to make is gone). `missingAttribute` / `missingKey`
  raise. `tryGetItem` serves `?[`. A builtin's method read as a value is a
  `__bmethod__:` userdata, cached per receiver and name. Function attributes
  live in `func_attrs_`.
- VM: `lookup_attr` (non-throwing), `get_attr` (raises), `try_get_attr`,
  `try_get_sub`, `bound_member`, `missing_attr` / `missing_key`; new ops
  `JUMP_IF_NONE_KEEP`, `JUMP_IF_MISSING_KEEP`, `JUMP_IF_NOT_NONE_OR_POP`,
  `LOAD_ATTR_OPT`, `LOAD_SUBSCR_OPT`, `CHECK_MEMBER`, `DUP_TOP_TWO`,
  `DELETE_NAME`. Function attributes live in `func_attrs_`, keyed by the
  function value's identity.
- The parser turns `recv?<link> rest...` into an `OptChainNode` (receiver,
  one link, and the rest of the chain written against a `HoleNode`). A hole
  is always the leftmost leaf of the expression that reads it, so the
  interpreter keeps its value in the node (set immediately before, read
  before anything else runs); the VM compiles a hole to nothing - the value
  is already on the stack.
- `NY_LENIENT_READS=log` is a porting aid: a missing attribute/key read (or
  a store on a value that cannot hold it) prints
  `[lenient-read] file:line: AttributeError: ...` once per line and yields
  none, the old behaviour. The build's own tests never set it.

**How the reads that relied on leniency were found.**
1. `NY_LENIENT_READS=log` over every `examples/**/*.ny` and `tests/*.ny` on
   both engines (826 runs): 246 distinct reads at 95 source lines, 77 of
   them in library code (the rest in tests); after the migration only the
   deliberate ones in `vm_audit57` remain.
2. `NY_LENIENT_READS=log python3 tools/ide_e2e.py`: all 354 checks, no
   missing read in any IDE log; the same on the VM-hosted IDE (365 checks,
   after the merge).
3. Static scans: every `v = d[k]` / `d[k] == none` probe in `lib/`, the IDE
   and `examples/lib` (57 hits; the ~45 dict reads became `.get`); every
   `x.name` read in `lib/` and the IDE whose name is assigned or defined
   nowhere (none left); and `tools/ny_attrcheck.py` (new), which lists
   `self.x` reads of attributes assigned only outside construction time
   (none left; run it after adding a class).

**Files migrated** (idiomatic fixes: `.get`, `?.`/`??`, attributes set in
`__init__`):
- `lib/gui.ny`: every event-handler table read (`_eh_counts` /
  `_event_handlers`, 43 reads in about 20 widget classes), the backend event
  fields in `_fill_event`, `c?._in_overlay`, `widget?.is_layout` in
  `gui_place`, `Calendar.has_event`, row/item dicts in the table, status
  bar, command bar and tree widgets.
- `lib/network.ny` (`EventSource.connected` now exists and follows
  connect/disconnect; header, DNS, MIME and cache tables), `lib/webserver.ny`,
  `lib/clientserver.ny`, `lib/sockets.ny`, `lib/stdlib.ny`, `lib/aiagent.ny`,
  `lib/icons.ny`, `lib/nyimgui.ny`, `lib/ide_commands.ny`,
  `lib/ide_debugger.ny`, `lib/langdef.ny` (docstring), `ide_icons.ny`.
- `lib/nytorch/`: `vision.ny` (vocabulary / document-frequency tables),
  `distributed.ny`, `serving.ny`, `compute.ny`, `tensor.ny` (`_mat_es` reads
  the legacy `.rows`/`.cols` with `self?.rows ?? 0`).
- Tests and examples that relied on it: `gui_tests/test_22_imgui.ny` (its
  theme stub lacked the chip colours, so `nyimgui` read none colours),
  `gui_tests/test_23_editor_selection.ny` (IDE stub without `tabs`),
  `test_network.ny` (a missing key expected to read none),
  `vm_audit46.ny` (`len.nope` expected none), `tests/test_webserver.ny`
  (read `.sid` off the session id string - it passed by accident),
  `examples/lib/agent.ny`, `examples/nython_ide.ny` (the v3 demo).
- The shipped IDE (`nython_ide.ny` and its chain, `ide_editor.ny`,
  `ide_project.ny`, `ide_workshop.ny`, `lib/ide_*.ny`) needed no change
  beyond `ide_icons.ny`: `tools/ide_lint.py` had kept it free of missing
  members for rounds.
- `src/builtins/text.cpp`: the formatter spaces `??` / `??=` as operators
  (it would have split `x ??= 1` into the invalid `x ?? = 1`).
- `tools/ide_e2e.py` now also fails when the IDE log contains
  AttributeError, KeyError, NameError, TypeError or `[lenient-read]`.

### 2. Global rebinding: kept, with declarations

The ruling: *"yes if the variable inside the function has not been declared
using let or anything else for declaring variables in our language."* Most
of it was already how both engines behave; it is now specified, and pinned
in `vm_audit57` for every context below.
- A plain `x = v` in a function rebinds the nearest existing binding: the
  enclosing functions' (innermost first), then the module's. When nothing
  binds `x` yet, it creates a local of the function (a later module `x` is
  then rebound by the same function, since it exists).
- `var x`, `let x`, `const x` (equivalent; function-scoped, as `var` always
  was - there is no block scope) declare a local that shadows every outer
  `x` for the rest of that function, from the point the declaration runs:
  an earlier read in the same function still sees the outer `x`, and a
  declaration in an `if` that did not run declares nothing. Invisible to the
  caller and to other calls (recursion has its own).
- Nested functions: an inner plain assignment to a name the enclosing
  function declared rebinds the enclosing local (no `nonlocal` needed); an
  inner `var` shadows it.
- `for` targets, parameters, comprehension variables (their own scope),
  `except ... as`, `with ... as`, `def` and `class` names are local
  declarations.
- Class bodies: a plain assignment defines a class attribute and never
  rebinds an outer name. Methods: the enclosing scope is the module, not the
  class body and not the caller - `count = 5` in a method rebinds a module
  `count`, not `Class.count`, and never a caller's local.
- `global x` (fixed): every later use of `x` in that function is the
  module's - an assignment creates it if it does not exist (it created a
  local) and skips an enclosing function's `x` (it rebound that one). Also
  for `for` targets, unpacking and `+=`. `nonlocal x` rebinds the enclosing
  function's `x`. Parser: `VariableNode::global_ref`; interpreter
  `moduleCtx`/`assignName`; VM `LOAD_GLOBAL_NAME`/`STORE_GLOBAL_NAME`.
- `const` is not enforced (a later assignment is allowed), as before.

### 3. Suffix literals

The ruling: *"it would depend on the operation performs."* A unit suffix
(`T G M K k m u n p f a`) scales by a power of ten; the literal is an exact
integer when the scaled value is whole and a float only when it is
fractional, worked out on the digits in the lexer (not in binary floating
point): `1k == 1000`, `2.5k == 2500`, `1.1k == 1100`, `1T == 10**12`,
`2000m == 2` are ints; `1m == 0.001`, `1500m == 1.5`, `5n` are floats. From
there the operation decides: `1k / 3` is a float, `1k // 3`, `1k * 2`,
`1k % 7`, `1k ** 2` ints, `1k + 0.5` a float. They were always floats; the
suffix checks in `v3_comprehensive_test`, `v4_lambda_functional_test`,
`v5_spec_compliance_test` and `v9_lexer_features_test` (§5.8) expected ints
all along and now pass.

### Verification

- `examples/vm_audit57.ny`: 212 passed, 0 failed on both engines.
- `python3 tools/sweep.py --base /tmp/r73/build/nython-cli` before merging
  the branch head: 204 runs, 0 not ok, 0 regressions. After merging ea36a05
  (the sweep now runs every `examples/*_test.ny`): 346 runs, 0 not ok; `v3`,
  `v4`, `v5` and `v9` pass on both engines. (A base binary cannot parse the
  migrated libraries - they use `?.` and `??` - so its failures there say
  nothing.)
- Every example and test on both engines with `NY_LENIENT_READS=log`: the
  only missing reads left are the deliberate ones in `vm_audit57`.
- `python3 tools/ide_e2e.py`: 365 passed, 0 failed after the merge (354/0
  before it), strict, with the new log checks.
- `tools/ide_lint.py`: 0 unresolved; `tools/ny_classcheck.py`: no
  duplicates; `tools/ny_attrcheck.py`: 0 reads to check;
  `tools/ide_memprobe.py --check`: passes (idle 0, hover 0, typing ~21
  KB/key, scroll 0.15 KB/event, split 0).
- The IDE on the VM: `nython-cli --vm nython_ide.ny` driven through the
  whole e2e suite (the driver pointed at that command instead of
  `nython --ide`) with `NY_LENIENT_READS=log`: 365 passed, 0 failed, no
  missing read in any log. (`--ide` itself always runs the interpreter.)

### Performance

The machine was shared with two other builds (load average ~12 on 4 cores),
so wall-clock timings were noise; these are callgrind instruction counts per
loop iteration (deterministic), main (e45ac52) against this branch. Each
loop iteration is `s = s + <two reads>` plus the loop's own work.

| Loop body | Interpreter before → after | VM before → after |
|---|---|---|
| `p.x + p.y` (fields) | 15,635 → 14,914 (−4.6%) | 11,537 → 11,490 (−0.4%) |
| `d["a"] + d["b"]` | 16,911 → 16,902 (0%) | 12,796 → 12,831 (+0.3%) |
| `p.m()` reading `self.x` | 26,979 → 25,731 (−4.6%) | 13,830 → 13,806 (−0.2%) |
| `d.get("zz", 1)` (missing) | 19,892 → 18,872 (−5.1%) | 12,939 → 12,974 (+0.3%) |
| `getattr(p, "zz", 1)` (missing) | 26,493 → 21,374 (−19%) | 78,199 → 14,579 (−81%) |
| `(p?.x ?? 0) + (p?.zz ?? 1)` | new: 21,741 | new: 14,073 |

A first version was ~4% slower per field read on both engines: the new
lookup default-constructed and copied one more `Value` (it carries a `Token`
with a `std::string`) / `VMVal` per read. A fast path for the common case - a
plain field of an instance or map - restored it; the interpreter also lost
the `receiver_cache_` probe it used to make on every attribute read.
`getattr` with a default no longer goes through a C++ exception on the VM.

### Notes for merging

- `round75-gc` (reference counting): conflicts expected in
  `NythonExecutor.hpp` around `evalAttribute`/`getAttrValue`,
  `specialAttribute`, `getItem`, `setAttr`, `evalDelete`, `callMethod`'s
  tail, and in `VirtualMachine.hpp` around `get_attr`/`lookup_attr`,
  `set_attr`, `get_sub`, the `DELETE_ATTR`/`LOAD_ATTR` ops, the `hasattr`/
  `getattr`/`setattr` natives, `store_var`/`load_var` neighbours
  (`delete_var`, `load_global`) and the `VMVal` helpers. The interpreter's new
  side tables (`bound_members_`, `func_attrs_`) and the VM's `func_attrs_`
  hold values and must count as roots if values become reference counted.
  The interpreter's attribute fast path returns an instance field by value
  straight from its namespace.
- `round75-gen` (stackful coroutines): the interpreter's `HoleNode::slot` is
  written immediately before the expression that reads it and read before
  anything else in that expression runs, so a coroutine switch cannot fall
  between the two - but a switch inside `evalOptChain`'s `evalNode(oc->recv)`
  is fine too, because the slot is written after it returns. The lenient-read
  log's dedupe set is process-global (mutex-guarded).

### Not done

- ~~`const` is not enforced~~ - enforced since round 76 (§0o). `var`/`let`
  have no block scope - as before; not part of the rulings.
- ~~a walrus, `with ... as` or `except ... as` of a global-declared name
  binds a local; `nonlocal x` with no enclosing `x` is not a SyntaxError~~ -
  both fixed in round 76 (§0o). `del x` unbinds the nearest `x` (Python
  would say UnboundLocalError for a global not declared).
- Which methods builtin values have is a union table (`NyMembers.hpp`): a
  name in it that a kind does not really implement reads as a bound method
  whose call then raises - never a spurious AttributeError on the read.
- VM function attributes are keyed by the function value's identity (code,
  closure environment, defaults); two functions made by the same `def` in
  the same frame share them.
- The migration is as complete as the runs and scans that found it: every
  example, test and the IDE e2e ran clean in log mode, and no `x.name` read
  in `lib/` or the IDE names an attribute defined nowhere, but a library
  path no test runs could still read an attribute some objects lack (the
  networking and web-server paths that need real sockets are the least
  exercised).
- ~~The interpreter prints `print(a, b)`'s arguments one by one while
  evaluating them~~ - fixed in round 76 (§0o).

---

## 0n. Round 75 — real SDL3, HiDPI done properly, every test in the sweep

The request: "Real SDL3: nothing has been built against it … use our real
SDL3 and fix everything"; "HiDPI tests: at a simulated 2× display, only the
IDE tests that don't use fixed pixel positions pass … use the best settings
and make sure everything works"; and the two stdlib tests "should be inside
sweep".

### Real SDL3

`tools/build_sdl3.sh` builds SDL 3.4.8, SDL3_ttf 3.2.2 (with its vendored
FreeType and HarfBuzz, as the release binaries are) and SDL3_image 3.4.6 from
source into `/opt/sdl3` - Ubuntu 24.04 has no SDL3 package. Then:

```bash
PKG_CONFIG_PATH=/opt/sdl3/lib/pkgconfig make cli BUILD=build-sdl NYTHON_SDL_STUB=0
PKG_CONFIG_PATH=/opt/sdl3/lib/pkgconfig make     BUILD=build-sdl NYTHON_SDL_STUB=0
```

`BUILD=` puts the real-SDL3 build beside the stub build; the Makefile adds an
rpath when SDL3 lives outside the system library path, so the binary runs
without `LD_LIBRARY_PATH`. Stub builds now define `NYTHON_SDL_STUB`.

**The test harness** (`include/builtins/gui_harness.hpp`,
`src/builtins/gui_harness.cpp`, compiled only for real SDL3) gives the real
backend the stub's two test abilities, so the *same* end-to-end suite runs on
both: the stub's event-script language (`NY_STUB_EVENTS`: move, click, key,
type, wheel, resize, drop, focus, dialog, snap, quit, …) is delivered as real
`SDL_Event`s with the stub's batching, and every draw call is recorded at the
SDL call boundary into the same display-list format. `resize` really resizes
the window. With `NY_REAL_PIXELS=1` each presented frame is read back
(`SDL_RenderReadPixels`) and `snap PATH` also writes `PATH.png` - a real
screenshot of real SDL3 rendering with real fonts. The wrappers are macros
over the SDL names gui.cpp calls, so gui.cpp is unchanged; with no harness
variable set each is one predictable branch and a direct SDL call.

```bash
Xvfb :99 -screen 0 1920x1080x24 &                       # or a real display
NY_IDE_BINARY=build-sdl/nython NY_IDE_ENV="SDL_VIDEODRIVER=x11 DISPLAY=:99" \
    python3 tools/ide_e2e.py
SDL_VIDEODRIVER=offscreen build-sdl/nython --ide        # no display at all
```

`tools/ide_driver.py` takes the binary from `NY_IDE_BINARY` and extra
environment from `NY_IDE_ENV`. Frame headers now carry `density` (pixels per
window point), `scale` (the window's display scale) and `backend`.

Found by running on real SDL3: a snapshot's PNG was written after its display
list, so a driver that waits for the display list could copy a half-written
PNG (fixed: PNG first, each via a temporary name); and SDL_ttf built without
HarfBuzz mis-kerns ("Te xt") - the build script now builds it as releases are.

### HiDPI: two models, one workbench

SDL3 has two HiDPI models (its `docs/README-highdpi.md`): on **Windows and
X11** window coordinates are device pixels and the display's content scale
says how much larger to draw (200%: density 1, content scale 2); on **macOS
and Wayland** they are points and a high-density window has more pixels per
point (density 2, content scale 1). The window's *display scale* - density ×
content scale - is pixels per layout unit on both. Before this round the IDE:

- drew at the display's **content** scale - 1.0 on a Retina Mac, so the whole
  workbench would have been drawn at half size into a 2× surface;
- asked for a 1600×960 window **in points** - on a 200% Windows/X11 panel
  that is 1600×960 pixels, an 800×480 workbench;
- used the stub's fake display, which reported content scale = density = 2,
  a combination no real platform produces - which is how both went unseen.

Now:

- **Layout-unit windows** (`gui_create_window` flag 16, `Window.layout_units`):
  sizes given to create / `set_min_size` / `set_size` are the size at scale
  1; the native side measures points per unit *on the real window* (display
  scale ÷ pixel density) and sizes it, clamped to the display. No platform
  table.
- The IDE draws at the window's display scale: predicted before the window
  exists (`gui_display_scale()` × the new `gui_display_density()`, the
  desktop mode's pixel density), then confirmed from the window once open.
- **Live scale changes**: `SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED` arrives as a
  `"scale"` event (`Window.on_scale`); the IDE rebuilds every metric and font
  (`_metrics()`), keeps the side-bar width and scroll positions in units, and
  a layout-unit window's minimum size follows.
- Raw pixel constants left in the layout (panel and editor minimums, the
  side-bar limit, workshop insets, text-field clip) and the minimap (2 px per
  line, 1 px per character) are now in dp. The saved side-bar width is in
  units.
- **The stub models both platforms faithfully**: `NY_STUB_DPI_SCALE=f` with
  `NY_STUB_DPI_MODE=points` (default; macOS/Wayland) or `=pixels`
  (Windows/X11; the display is f × 1920×1080 pixels). The script command
  `scale F` changes the scale at run time and sends what SDL sends (plus the
  resize Windows does on `WM_DPICHANGED`).
- **The e2e suite is scale-independent**: coordinates in `tools/ide_e2e.py`
  are the IDE's scale-1 metrics passed through `R()`/`D()`, which scale by
  the display scale the last frame reported; pointer positions are divided
  by the frame's density; `resize()` means "the window a person at scale 1
  would have". New scenario `hidpi`: moving to twice the scale and back
  keeps the workbench in units, doubles text size, and input still lands.

Results (full `tools/ide_e2e.py`, 30 scenarios):

| Backend | Display | Result |
|---|---|---|
| stub | 1× | 365 passed, 0 failed |
| stub | 2×, points model (Retina) | 365 passed, 0 failed |
| stub | 2×, pixels model (Windows/X11) | 365 passed, 0 failed |
| real SDL3, X11 (Xvfb) | 1× 1920×1080 | 357 passed, 0 failed |
| real SDL3, X11 (Xvfb) | 4K at 200% (`SDL_VIDEO_X11_SCALING_FACTOR=2`) | 357 passed, 0 failed |

(Real SDL3 runs 8 checks fewer: the `hidpi` scenario's live scale change
needs the stub's `scale` command - a real display's scale cannot be changed
from a script. Before this round, the 200% X11 window came out 1600×960
pixels, an 800×480 workbench; now it is 3200×1920, the same 1600×960 units.)

### Windows: it builds, links and runs again

Nothing had compiled the Windows build since round 74. `tools/cross_windows.sh`
now cross-compiles `nython.exe` from Linux with MinGW, using `nython.cbp`'s
own flags and units, against SDL3/SDL3_ttf/SDL3_image cross-built for
Windows, and runs it under Wine (`build-win/nywin`, which the sweep can take
as `--bin`). What that found, all fixed:

| Defect | Effect on Windows |
|---|---|
| `nython.cbp` missing 7 units (NyConc, VMConc, os_proc, os_time, pycore, text, gui_harness) | Code::Blocks build could not link |
| `text.cpp` included `<dirent.h>` unguarded | clashed with platform_compat's emulation: compile error |
| `M_PI` in nytensor.cpp | not defined by strict C++20 on MinGW: compile error |
| `inline thread_local` member of a non-trivial type | MinGW emits its TLS init per object: "multiple definition" link error |
| harness `nyh::CreateWindow` | collided with the Win32 `CreateWindow` macro |
| `ConsoleManager::setupConsole` called `exit(GetLastError())` when stdin/stdout was not a console | **every run with redirected output exited at once with code 6** - `nython s.ny > out.txt`, Code::Blocks' output capture, the IDE's own Run; it also turned echo off for every script (and left a Linux terminal that way) |
| `Value((long int)x)` in `intValue`, integer literals, tensor results; `(double)(long)bigint` in Value's operators | `long` is 32 bits on Windows (LLP64): every integer above 2^31 wrapped (`123456789012` read as `-1097262572`); the bigint cast also dropped the sign on every platform |
| `os_spawn`/`os_poll`/`os_proc_read`/`os_wait`/`os_kill` raised "not supported on Windows" | **the IDE's Run, Build, terminal and git refresh did not work** (BgProc's fallback was POSIX-only too) |
| IDE scratch files under `/tmp`, toolchain via `{ ...; } 2>&1; echo $?` | no `/tmp`, no POSIX shell |
| fonts from `C:\Windows\Fonts` only | Windows on another drive had no text; macOS had no font list at all |

The process layer on Windows is now the same API as on POSIX
(`src/builtins/os_proc.cpp`): `CreateProcessW` with pipes, spawns serialised so
no child inherits another's pipe ends, `CREATE_NO_WINDOW` (a GUI IDE running
a console program flashes no console), one **Job Object** per process so
`os_kill` ends the whole tree as a POSIX process group does and reports
`-sig`, non-blocking reads through `PeekNamedPipe`, stdin fed from its own
thread, a real `timeout`. Command **strings** run through a POSIX `sh` when
one is found - `NY_SH`, `sh.exe` on `PATH`, Git for Windows or MSYS2 in
their usual places - so the IDE's POSIX command lines (git, build targets,
tools) run unchanged on Windows; otherwise through `cmd.exe` (`NY_SH=cmd`
forces it). `os_shell()` says which; `shell_quote()` quotes for it.
`os_run(..., merge=true)` / `os_spawn(..., merge=true)` send stderr into the
stdout pipe in order (subprocess's `stderr=STDOUT`), on both platforms - the
IDE's BgProc and Toolchain use it (argv lists, no shell text) instead of
`2>&1`, `< /dev/null` and `$?`.

The rest of what running the whole sweep under Wine found:

| Defect | Fix |
|---|---|
| Files written by a Windows program end lines with `\r\n`; text reads kept the `\r` | text-mode handles (`open(p)`, `file_open(p, "r")`) read with universal newlines, as Python does; `"rb"` handles, `read_file` and `file_readlines` stay byte-exact |
| `os_stat`/`file_mtime` used the CRT's whole-second `stat` | Windows reads the FILETIME (100 ns), so "changed since" checks see sub-second edits |
| `os_getppid` was POSIX-only | Toolhelp32 snapshot on Windows |
| `os_chdir` on a file | raises NotADirectoryError on both platforms (Windows reported ENOENT) |
| `process_exec` on Windows used `_popen` | the same CreateProcess path as `os_run`, stderr merged |
| the IDE's toolchain ran `./ny_test` from the checkout - a Linux binary beside `nython.exe` | `NYTHON_EXE`, then `sys.executable`, then the checkout's candidates |
| tests sharing `/tmp` paths raced when the sweep runs both engines at once | per-run temporary directories (temp dir + pid + a random suffix) |
| `NyCoro.cpp` called `GetCurrentThreadStackLimits` (Windows 8+) while the project targets Vista (`_WIN32_WINNT 0x0600`) | looked up at run time; `VirtualQuery`'s allocation base where it is missing |
| vm_audit48 timed out joining its lock-counting threads (interpreter, under Wine) - a **lock convoy on every platform**, from two causes. (1) The interpreter could hand the GIL over at any statement, so often while the running thread held a Nython mutex, and the others then blocked on it. (2) A released mutex was *handed* to a sleeping waiter, which first had to wait for the GIL, so the releasing thread blocked on its next lock - every lock operation became a thread switch, and once formed the convoy never dissolved (8 threads x 10k lock/unlock: 40k blocking waits, 625k context switches, 6 s on Linux, over 20 s under Wine) | (1) lock-holder preemption avoidance, as paravirtualised spinlocks and Linux's time-slice extension do for vCPUs and threads: a due GIL hand-over waits while the thread holds a lock (at most one more switch interval) and happens at the first tick after its last unlock. (2) competitive succession, as HotSpot's monitors, Windows' critical sections since Vista and futex mutexes: unlock wakes one waiter, the *heir*, which competes for the mutex once it runs with the GIL; while an heir is awake no one else is woken. 0.8 s and ~160 waits; a lock held for most of each iteration 2,500 waits -> 48; holders that sleep with the lock held 60k waits / 3.2 s -> 268 / 0.5 s (the VM: 17.5k -> 127). `thread_wait_count()` (sleeps for the GIL or on a sync object) makes all three testable independently of machine speed, and vm_audit48 checks them; each check fails on the build without its half of the change. rwlocks still hand over (not measured) |
| a PE executable reserves a 2 MB main stack (Linux gives 8 MB) | `-Wl,--stack,8388608` in `nython.cbp` and the cross build: the 600-deep `yield from` chain in vm_audit56 hit the VM's native-stack guard (a clean RecursionError, not a crash) |

`tools/cross_windows.sh` installs busybox-w32 as `sh.exe` and as the POSIX
programs Git for Windows keeps beside it (`echo`, `cat`, `sleep`, `kill`,
`grep`, ...), so the tests that start POSIX programs run there as they would
on a Windows machine with Git installed; tests that need a program that is
not there (or a symlink privilege Wine does not grant) skip those checks
and say so rather than fail.

**Result:** the full sweep under Wine, both engines, every file -
348 runs, 0 not ok (with the lazy generators and the lock changes; the same set is clean on Linux, run at the same time). vm_audit46 (the OS layer) is 247/0 there (255/0 on Linux;
the 8 skipped are symlinks and `which`-dependent checks).

#### Building what Code::Blocks builds, 32-bit included

A user's Code::Blocks build (w64devkit, **32-bit**) failed after the
garbage-collection merge while every test here passed. There were three
reasons:
- **Missing units:** `src/NyGC.cpp` and `src/VMGC.cpp` were never added to
  `nython.cbp`.
- **A build that bypassed the project:** the cross build compiled every
  `src/*.cpp` with flags copied into the script, so it could not see what the
  project left out.
- **64-bit only:** all testing was 64-bit.

The fixes:
- **`tools/cbp.py`** reads `nython.cbp` the way Code::Blocks does (its
  units, the project's then the target's options, the libraries, the GUI
  subsystem of a type-0 target).
  - `tools/cross_windows.sh` builds only from it, and keeps the compiler's
    warnings in `$OUT/warnings.log`.
  - `cbp.py check` fails on a source file the project does not list, and
    every sweep runs it.
  - The project itself was not well-formed XML: a bare `&` in the Debug
    target's `2>&1` post-build commands (Code::Blocks' TinyXML accepts it,
    a strict parser does not); now `&amp;`.
- **`ARCH=i686`** builds and runs the 32-bit edition (SDL for i686 in
  `/opt/sdl3-mingw32`, `wine32:i386`). What it found:
  - `unsigned __int128` in `hash()` of ints, which does not exist on 32-bit
    GCC. Replaced by Mersenne reduction mod 2^61-1 in 64-bit arithmetic;
    `hash()` still equals Python's for every int, `2**200+17` included.
  - `NyOrderedMap` shifted a 32-bit `size_t` hash right by 32, which is
    undefined behaviour, and its index tag was empty. The hash is `uint64_t`
    on every platform now.
- **Warnings a Code::Blocks build showed:**
  - Trigraph `"??="` literals (now `"?\?="`).
  - An uninitialised-looking `cp` in `NyJson`.
  - GCC's `-Warray-bounds` false positive on MinGW's `NtCurrentTeb()`
    (GCC bug 99578), silenced in `NyCoro.cpp`'s Windows code only.
- **Result:** the 64-bit and 32-bit builds of the project file both compile
  with **0 warnings** under the project's own `-Wall -O2`.

Building at the project's `-O2` found one more bug, in the 64-bit build only:
**a raise from deep recursion inside a generator crashed** (vm_audit56). The
trace in Wine showed the unwinder losing its way at the first frame of an
extension stack:

- **The cause:** `nycoro::stack_exhausted()` read `__builtin_frame_address(0)`.
  Inlined into `evalCall`, `runFunctionBody` and others, it forced those
  functions to keep a frame pointer. For a function with a large frame, GCC
  then sets `rbp` right after `push rbp`, before the stack allocation, but
  records the XMM6/XMM7 saves relative to the final RSP.
- **Why that breaks:** the Windows x64 unwinder (and Wine's, which follows
  it) reads those saves relative to the frame base, `rbp - FrameOffset*16`.
  - Every exception unwinding through such a frame restored XMM registers
    from the wrong address. That is a silent corruption on a real 64-bit
    Windows machine.
  - At the top of a fiber's stack the read went past the stack's end: the
    crash.
  - `-O1` hid it: smaller frames, so 900 calls fitted in one 1 MB generator
    stack and no extension stack was used.
- **The fix:** `nycoro::stack_position()` takes the address of a local, so no
  frame pointer is forced.
- **The guard:** `tools/pe_unwind_check.py` scans a Windows x64 image's
  unwind tables for any function that sets its frame pointer before
  allocating and saves XMM registers. The 64-bit cross build runs it after
  linking. It flags a 12-line reproduction and passes its fixed form.

**Result at e4108e6** (the full sweep, both engines, every file, plus the
`nython.cbp` unit check: 351 runs each): Linux 0 not ok (0 regressions
against round 73); the 64-bit build of `nython.cbp` under Wine 0 not ok; the
32-bit build under 32-bit Wine 0 not ok. Each build runs under its own
Wine loader (`/usr/lib/wine/wine64`, `/usr/lib/wine/wine`): with `wine32`
installed, a plain `wine` picks the 32-bit one, which cannot open a 64-bit
prefix.

### Every test file in the sweep

`tools/sweep.py` now also runs every `examples/*_test.ny` (70 files). The two
stdlib tests already passed on both engines (the round-74 value and thread
work fixed them); seven others failed on both engines:

- stale expectations from before floats printed as floats and lists as
  Python lists (`advanced_test`, `v4_lambda_functional_test`,
  `v13_systems_test`, `v14_systems_test`, `v14_all_systems_test` - inputs
  like `tensor([1.0, 2.0])` produce `[6.0, 8.0]`, as Python and NumPy do);
- `rl_test.ny` read a `/tmp` file nothing created - rewritten to write its
  own file and assert the handle API, `keep_newline`, and file objects;
- a real gap: the legacy flat tensor ops turned integer inputs into floats.
  They now follow NumPy's promotion rule - integers stay integers through
  `+ - *`, dot, sum, max/min, abs/neg/sign and `relu`; `/`, mean, sqrt, exp
  become floats; an integer sum or dot accumulates exactly in int64 and falls
  back to float only on overflow (or a result a double cannot hold).
- `1k`-style literals (`v3`/`v4`/`v5`/`v9`) are the suffix ruling, §0m.

§5.8's "content-level failures in old version-numbered example files" is
closed by this: those files are swept now and pass.

---

## 0k. Round 75 — garbage collection on both engines

The request: "make sure the garbage collectors works very well in the whole
language, vm and interpreter ... Interpreter memory: it never frees
containers, so the biggest nytorch tests peak near 1 GB, fix it so that
should also use the garbage collector". `GC_NOTES.md` is the full design
note; this is the summary and the traps.

### What was wrong

- **Interpreter**: nothing was ever freed - lists, dicts, tuples, strings,
  function values, bound methods, instances, and every scope a closure or
  class had referred to. `GarbageCollector.cpp` was complete code wired to
  nothing (GC_NOTES, history).
- **VM**: `shared_ptr` freed acyclic data, but every reference cycle leaked
  (an instance whose field points at itself, a closure over `self` stored on
  `self`, autograd graphs), and dropping a 30,000-node linked list **crashed**
  (recursive `shared_ptr` destructors overflowed the stack).

### What it is now (CPython's model, both engines)

- **Reference counting**, exact and immediate. Interpreter:
  `Collectable::gc_rc`, counted by every `Value` copy through the new
  `TValue::o` (the object a value keeps alive). VM: `use_count()`.
- **A generational cycle collector** using trial deletion (subtract the
  references the candidates hold on each other; what keeps a count is
  referenced from outside - a C++ local, another thread's stack, a native
  table - and survives with all it reaches; the rest is cleared). Three
  generations, thresholds 700/10/10, collections only at safe points
  (statement boundaries / instruction boundaries), plus a full collection
  whenever the allocator's in-use bytes have doubled since the last one
  (object counts alone let a few hundred parameter-heavy objects pile up),
  followed by `malloc_trim`.
- **Interpreter heap objects** (`include/NyHeap.hpp`): `Str`, `Func`,
  `Bound`, `Inst`, `Weak`. The identity `value.p` points at is a member of
  the owning object, and its destructor erases every side-table entry keyed
  by it. Scopes are counted: born with the creator's reference, released by
  `CtxReaper`; the "escaped scopes" set is gone.
- **VM** (`src/VMGC.cpp`): containers registered by `weak_ptr` at creation;
  `vmgc::DeepPtr` frees deep chains iteratively.
- **`__del__`** runs once, at the next statement (interpreter) / instruction
  (VM) boundary, never inside a decrement; cyclic garbage is finalized
  before it is cleared and survives if a finalizer resurrects it (PEP 442).
- **Builtins, both engines**: `gc_collect`, `gc_enable`, `gc_disable`,
  `gc_is_enabled`, `gc_set_threshold`, `gc_get_threshold`, `gc_stats`,
  `gc_live_objects`, `mem_rss_kb`, `mem_peak_rss_kb`, `weakref`.
- `examples/vm_audit55.ny` (4059 checks, identical output on both engines).
- `make asan` builds `build-asan/nython-cli` (ASan + UBSan + LSan).

### Defects found on the way (all fixed)

- `gui_poll_events` cached its shared empty event list in a `static
  Object*` without a reference: freed after the first empty poll, returned
  freed afterwards (the GUI tests crashed on both engines).
- `@prop.setter` left the property's getter unreferenced while the setter's
  `def` rebound the name; the next `def` reused the getter's address and
  inherited its identity (`vm_audit53`: `t.celsius` read `t.fahrenheit`).
- `keys()`/`values()`/`items()` of an instance cast its identity to a
  `Collectable*` and `dynamic_cast` it (a bogus vtable read).
- An expression statement's value (`L.pop()`) stayed alive one statement
  longer; `__del__` ran late.
- Raised instances were kept forever, keyed by address; they are a serial
  number plus a ring of the last 256 now.

### Traps

- **A pointer kept outside a `Value` is a reference or a bug.** A freed
  address is reused immediately (often by the next object of the same
  size), so a stale side-table entry or a cached raw pointer silently
  describes a different object. ASan does *not* catch this (its quarantine
  delays reuse); the normal build's tests did. Hold a reference
  (`nygc::incref`) or erase the entry in the object's destructor.
- A tracked object with a count of zero is under construction by native
  code and is a collector root: `new Object` + fill + wrap is safe even if
  filling calls back into Nython.
- Never touch a `Value` without the GIL (`nyconc::holds_gil()`); an
  `InterpBox` released without it defers its reference
  (`nygc::release_later`).
- Contexts are born with one reference: a new `new Context(...)` site needs
  a `CtxReaper` (or hands its reference to an owner), or it leaks.
- VM containers must be registered where they are created
  (`vmgc::track_*`); a missed one only leaks its cycles.

### Numbers

Peak RSS, pre-round-75 build → this one (interpreter / VM, MB):

| | interpreter | VM |
|---|---|---|
| 200k container literals (GC_NOTES benchmark) | 598 → 11 | 11 → 11 |
| 200k string-building iterations | 140 → 11 | 11 → 11 |
| 100k self-cycles | 473 → 11 | 445 → 12 |
| 50k closure-over-self instances | 266 → 11 | 107 → 11 |
| drop a 200k-node linked list | 442 → 419 (live data) | crash → 189 |
| test_nytorch13 / 14 / 15 / 16 / 17 | 714 / 689 / 1068 / 1114 / 51 → 88 / 182 / 76 / 151 / 46 | 283 / 157 / 233 / 268 / 34 → 55 / 116 / 47 / 86 / 34 |

(Before the generators/strict-reads merge; after it the interpreter's
nytorch peaks are 98 / 193 / 80 / 151 / 47 MB, the VM's 61 / 119 / 47 / 87 /
34.) What remains in test_nytorch14 is live: the test keeps every section's
models in globals, and a float in an interpreter list is ~280 bytes.
IDE (`ide_memprobe.py`): idle 0, hover 0, typing 0 KB/key, scroll 0.05.

Speed (callgrind instructions, before → after): calls +2.1% / +0.4%
(interpreter / VM), method calls -2.2% / +0.8%, fib +2.4% / +1.4%,
containers +7.1% / +7.1%, instances +9.8% / +5.3% (the last two include
freeing everything at exit). Full table in `GC_NOTES.md`.

### Not done

- ~~Objects used as dict keys are kept until the executor ends~~ - freed
  since round 76 (§0o), on both engines.
- The VM collector cannot see references inside natives' `std::function`
  captures or code-object constants: cycles through them leak (safely).
- The interpreter's value representation (208-byte `Value`, string-keyed
  maps for lists) is unchanged, so live data is still large.
- ~~The old `GarbageCollector.cpp` is still compiled and unused~~ - removed
  in round 76.
- round75-sem (merged): function attributes (`func_attrs_`) go with their
  function (`forgetFunction`, `Func::gc_traverse`/`gc_clear`). ~~Its bound
  builtin members are immortal~~ - heap objects since round 76 (§0o).
- round75-gen (merged): a generator's hold on the scope it runs in is a
  counted reference (`nygen::pin`/`unpin`; `defer_reap` is no longer
  needed). A generator dropped while suspended is destroyed at refcount
  zero, `~GenObject` queues it, and `run_pending` closes it at the next
  statement (vm_audit56's interpreter PENDING check now passes). The
  references a suspended generator's coroutine stack and `Gen` fields hold
  are invisible to the collector: a cycle through a suspended generator is
  not collected (it leaks; nothing is freed wrongly).

---

## 0l. Round 75 — lazy generators on the interpreter

The request: "Generators: on the interpreter they still collect every value
up front, so an infinite generator hangs there. The VM handles them
correctly." The interpreter ran a generator function's whole body when it
was called and returned a list in disguise (`__gen__`/`__idx__`), so an
infinite generator hung, side effects ran early, `send()` delivered nothing
and generator expressions were lists. The VM was lazy but had no `throw()`,
its `close()` skipped `finally`, `return v` and `yield from`'s value were
lost, generator expressions were eager and deep recursion crashed it.

### Design as built

- **`include/NyCoro.hpp`, `src/NyCoro.cpp` — stackful coroutines.** Each
  generator body runs on a C stack of its own: `mmap` with `MAP_NORESERVE`,
  a `PROT_NONE` guard page below, 1 MB reserved (`NY_GEN_STACK_KB`),
  committed by the kernel as touched; finished stacks go to a pool of 64
  (pages below the top 64 KB are `madvise`d away only if the stack went
  that deep). The switch is 15 instructions of assembly on x86-64 SysV and
  AArch64 (callee-saved registers, MXCSR/x87 CW, FPCR): 41 ns for a
  resume + suspend pair, against 593 ns with `swapcontext` (a
  `sigprocmask` system call each way), which stays as the fallback
  (`-DNYCORO_FORCE_UCONTEXT`, and any other POSIX target). Windows uses
  fibers (`CreateFiberEx`/`SwitchToFiber`), pooled like the stacks (a
  fiber's start routine loops over the coroutines it is lent to; creating
  one costs ~20 us). The fiber backend was built with MinGW-w64 and its
  standalone test (switching, exception transport, nesting, the stack
  floor, FP state) run under Wine: 178 ns per resume + suspend, 1.1 us per
  create + 4 resumes + destroy with the pool; never on a real Windows
  machine, and the whole of nython.exe was not rebuilt with it here. The
  AArch64 switch is written but not run (no cross toolchain or emulator in
  the container). ASan builds call `__sanitizer_start/finish_switch_fiber` at every
  switch. Threads are identified by never-reused tokens (`thread_token`),
  not `std::thread::id`.
- **`include/NyGen.hpp`, `src/NyGen.cpp` — the generator layer.** A
  generator is a `GenObject` (a Container whose map holds only `__gen__`,
  kernel type `Type::GENERATOR`) owning a `Gen`:
  - *function generators*: calling the function makes the object and binds
    the arguments; the first `next()` creates the coroutine. `yield`
    stores the value and suspends; resuming returns the sent value, or
    throws what `throw()` raised, or GeneratorExit (`close()`).
  - *generator expressions*: a state machine over their clauses (no
    coroutine - the element cannot yield).
  - *lazy builtins*: `zip`/`map`/`filter`/`enumerate` given a generator,
    `islice`, and `iter()` of a list/str/dict/set/range are state
    machines too. Over lists they still return lists (existing code relies
    on it).
- **Hooks in `NythonExecutor.hpp`** (all marked `nygen`): YIELD /
  YIELD_FROM, `runFunctionBody`, `evalFor` (a generator is pulled one value
  per iteration), `evalComprehensionNode` (GEN is lazy; the others pull a
  generator one value at a time), `iterItems` (drains), `callBuiltin`
  (islice/take and generator arguments), `callMethod`, `containsValue`,
  `getItem`, `isTruthy`, `typeNameOf`, `toText`, `valuesEqual`,
  `evalVarDecl` (unpacking), `reapContext`, `noteStatement`, `evalCall`.
  `yield_sink_`, `collectGenerator` and `makeGenValue` are gone.

### Invariants

1. **One body runs at a time per thread, nested like calls.** At every
   switch `resume_function` swaps the executor's per-execution state:
   FlowState (fast_ctx/brk_ok/pending/value), `last_stmt`, `call_depth_`
   (the generator's own depth is kept relative), and the parts of
   `handling_exc_`, `owner_stack_` (super()) and the `--trace` frame stack
   that belong to the generator. The resumer never sees the generator's.
2. **No C++ exception crosses a switch.** The coroutine's entry catches
   everything into `std::exception_ptr`; the resumer rethrows it. A
   StopIteration escaping a body becomes RuntimeError (PEP 479). An
   uncaught error keeps the generator's `last_stmt`, so the location points
   into the generator.
3. **A started generator stays on its thread.** A frame on a coroutine
   stack can hold the address of a `thread_local` (the compiler may keep it
   in a register across the switch), so a coroutine must not migrate.
   Resuming a started generator from another thread raises RuntimeError on
   **both engines** (the VM could migrate, but the engines must agree on
   what is an error). A generator not yet started may be run by any thread.
4. **A suspended generator is never freed under live frames.** It is
   finished by resuming it with GeneratorExit (finally blocks and
   `__exit__` run; C++ destructors on its stack run). If it yields again,
   `close()` raises RuntimeError("generator ignored GeneratorExit"); during
   finalization it is then resumed with a forced unwind (`GenKill`, a C++
   exception no `except` catches) up to four times, and only then is its
   stack abandoned.
5. **Stack depth.** `evalCall` and `runFunctionBody` check the stack pointer
   against the running coroutine's floor (one thread-local load and a
   compare; nothing on a thread's own stack). Near the floor the call
   continues on an **extension stack** - another coroutine, resumed once,
   run to the end - so recursion inside a generator reaches the usual limit
   (RecursionError at 900 calls) exactly as outside one.
6. **Contexts.** A generator's function context is pinned: the call site's
   `CtxReaper` defers to it, and it is reaped when the generator finishes
   (unless a closure captured it). A generator expression pins the
   enclosing function's context the same way.

### When a generator is finalized (the one gap left to reference counting)

The interpreter still never frees containers (`GC_NOTES.md`), so "when its
last reference goes" cannot be observed yet. What is done instead:

- a generator that a `for` loop's iterable expression, or the arguments of a
  consuming builtin (`any`, `all`, `next`, `sum`, `min`, `max`, `sorted`,
  `list`, `tuple`, `set`, `dict`, `take`, `reversed`), **made itself** is
  closed when the loop / builtin is done (`nygen::fresh`: made during that
  expression, at that call depth, on this thread). So `for x in g(): break`
  runs `g`'s finally at the break and `any(... for ...)` leaves nothing
  suspended, as under CPython. A lazy wrapper (`zip(g(), ...)`) takes over
  the temporaries it was given;
- `GenObject::~GenObject` queues a suspended generator; `noteStatement`
  closes queued ones between statements (never inside the destructor). This
  is the hook for the reference-counting work (below). Until then it only
  runs for objects something else deletes;
- at the end of the program every generator still suspended on the main
  thread is closed, oldest first (`nygen::close_all` in `run_file`), as
  CPython finalizes at shutdown.

`vm_audit56`'s one `pending(...)` check ("dropping the last reference closes
it") is the case only reference counting can cover; it is reported, not
failed, on the interpreter, and passes on the VM.

### The VM (same behaviour, its own machinery)

- `gen_resume(gs, mode, value)` replaces `gen_next`'s core: next/send, throw
  (raised at the paused instruction through the frame's exception table, so
  the generator's own except/finally/with handle it) and close
  (GeneratorExit there). `return v` is StopIteration.value.
- `YIELD_FROM_OP` pauses *at* itself with the subiterator on the saved
  stack and passes send/throw/close on (PEP 380); its value is pushed (and
  popped as a statement - it used to push nothing, so a loop around it lost
  its iterator).
- Generator expressions compile to a nested generator function over
  `iter(first iterable)`.
- A generator paused inside a try/with whose last reference goes (the
  shared_ptr) is moved to a zombie and closed between two instructions;
  every paused generator is closed at the end of `run()`.
- `check_depth()`: RecursionError at 1000 frames or near the thread's stack
  floor (it crashed with SIGSEGV at ~1400 frames; under ASan, `run_loop`'s
  frame is ~120 KB and 8 MB holds ~60 frames).
- `islice`, `take`, lazy `zip/map/filter/enumerate`, lazy `any/all/in`,
  `__unpack_seq__` for unpacking, `StopIteration.value` everywhere an
  exception is made.

### Numbers (this container, 4 cores shared with two other builds)

| | before | after |
|---|---|---|
| 300k yields through a `for` (wall) | interp 0.846 s (eager), VM 0.445 s | interp 0.660 s, VM 0.445 s |
| same, 30k yields, instructions | interp 611 M, VM 482 M | interp 569 M, VM 436 M |
| `sum(x*x for x in 300k list)` | interp 0.997 s, VM 0.699 s | interp 0.719 s, VM 0.823 s (lazy now) |
| 100k `send()` | interp: hung (eager `while True`) | interp 0.376 s, VM 0.238 s |
| 30k one-line calls, instructions (callgrind, minus startup) | interp 578.1 M, VM 398.3 M | interp 577.6 M, VM 400.2 M |
| 200k calls + 100k method calls + fib(22) (wall, best of 3) | interp 0.933 s, VM 0.501 s | interp 0.932 s, VM ~0.50-0.57 s (noisy) |
| resume + suspend (C++ microbenchmark) | - | 41 ns asm, 593 ns ucontext |
| create + 4 resumes + destroy (pooled stack) | - | ~256 ns |

The VM's generator expressions are ~20% slower than its eager list
comprehension was (each value goes through a generator frame); that is the
price of laziness there.

10,000 suspended generators (each paused inside try/finally):

| | VmSize | VmRSS |
|---|---|---|
| interpreter, stacks 256 KB / 1 MB / 8 MB | 2.6 / 10.3 / 82 GB | 142 MB in all three |
| interpreter, no generators | 15 MB | 10.5 MB |
| interpreter before (eager lists) | 58 MB | 51 MB |
| VM | 36 MB | 30 MB |

So a suspended interpreter generator costs ~9 KB more resident memory than
the old eager list (two touched stack pages plus its records); the
reservation is address space only. Each stack is two memory mappings, and
Linux allows 65,530 per process: about 30,000 generators can be suspended
at once (the next one raises MemoryError). Generator churn (40,000 × three
short-lived generators) does not grow the mappings: VmSize tracks VmRSS.

### Verification

- `examples/vm_audit56.ny`: 120 checks, identical on both engines and
  `python3` (threads are skipped there); one `pending` on the interpreter.
- The sweep (`tools/sweep.py --base /tmp/r73/build/nython-cli`, 348 runs
  with every `*_test.ny`), after merging the branch head d3cae88
  (round75-sem and the Windows work): 348 runs, 0 not ok, 0 regressions.
- Strict reads (§0m) and generators: a generator's methods are members
  (`MemberKind::Generator` in `NyMembers.hpp`, both engines), so
  `g.send` read as a value, `hasattr(g, "send")` and `g?.send(x)` work and
  `g.nosuch` raises AttributeError. The optional-chain placeholder
  (`HoleNode::slot`) is read before anything else in its expression runs,
  so a generator can never suspend between setting and reading it.
- ASan build (`make cli OBJDIR=build-asan/obj CLI_TARGET=build-asan/nython-cli
  CXXOPT="-O1 -g -fsanitize=address -fno-omit-frame-pointer"`, run with
  `detect_stack_use_after_return=1`): vm_audit22-26, 48, 49, 52-54, 60,
  test_vm3, test_vm_extended, the full vm_audit56 on the interpreter, a copy
  of vm_audit56 with its recursion depths cut to 150/40 on both engines
  (60 MB main stack), and the probe programs (deep recursion on extension
  stacks, throw/close/ignored GeneratorExit, generator churn, 2,000
  suspended generators, exit finalizers): no reports. The cut depths are
  for the VM: under ASan `run_loop`'s frame is ~120 KB, so 600 nested
  generators need more than 64 MB of stack, and past 64 MB ASan itself
  warns that false positives may follow (sanitizers issue #189).
- `tools/ide_e2e.py` 365/0, `ide_lint`, `ide_memprobe --check`,
  `ny_classcheck`.

### Not done

- Finalization on the last reference (see above) - needs the reference
  counting of round 75's GC work.
- Windows fibers: tested under Wine only (see above). ~~The AArch64 switch
  is untested~~ - round 76 cross-built for AArch64 and ran the generator,
  async, memory and value suites under qemu-user, both engines (§0o).
- Lazy builtins: they print as Python's (`<zip object at ...>`) and `send()`
  raises AttributeError since round 76 (§0o); `type()` stays "generator"
  (ruled there: Nython's dict is the type "map").
- A generator dropped by another thread than the one that started it is
  left suspended (only its own thread may run its finally blocks).
- ~~A lambda calling itself through its own name raised NameError, and
  `print(a(), b())` printed as it evaluated~~ - both fixed in round 76 (§0o).
- The end-of-program close runs only when the program ends normally (not
  after an uncaught exception, where CPython would still finalize).
- ~~Async still runs each task on an OS thread~~ - a task is a coroutine on
  its loop's thread since round 76 (§0o).

### For the reference-counting merge

- **Values live on a suspended coroutine's stack** (locals of the evalNode
  frames between the body's entry and its `yield`: a `for`'s iterable, a
  call's evaluated arguments, `with`'s manager...) and in `Gen` fields
  (`xfer`, `retval`, `delegate`, the cursors' `hold`/`it`, `saved.value`)
  hold references that no traversal of containers can see. A
  trial-deletion cycle collector (CPython's) is safe with this: those
  references stay "external" and keep everything they reach alive; a
  suspended generator's cycles are then never collected (a leak, not a
  use-after-free). A **tracing** collector that marks only from known roots
  must treat every suspended generator's stack as a root, or it frees
  objects a later `next()` uses.
- `~GenObject` must only ever queue: it may run in the middle of any
  container operation. `nygen::run_pending` (called from `noteStatement`)
  closes the queued generators, which unwinds their stacks and so releases
  those references. A destructor running on a thread other than the
  generator's leaves it suspended.
- Contexts: `reapContext` asks `nygen::defer_reap` first (a generator still
  running in the context); the generator reaps it when it finishes.

---

## 0e. Round 74 — responsive IDE, Code::Blocks features, faster engines

The request: make the IDE "totally responsive", bring in features from
Code::Blocks, and fix what is missing or broken across the GUI, nytorch,
OS, the language, threads/mutexes/synchronisation and async.

### Build (commit 9f8c96e)

Every translation unit except `main.cpp` is the same in the IDE and CLI
builds, so they are compiled once into `build/obj/`; `main.cpp` is built per
flavour (`main_ide.o`, `main_cli.o`). `-MMD -MP` records header
dependencies: editing a header rebuilds exactly the objects that include it,
so the stale-object trap in §4 no longer needs `make clean`. Both binaries
build in about 1.5–2.5 minutes.

### Engines: return/break/continue without C++ exceptions (f284623)

A call to a one-line function cost ~20 µs on the interpreter and ~70 µs on
the VM, because every `return` threw a C++ exception, and every
`break`/`continue` threw a `std::string`. callgrind put 80% (interpreter)
and 92% (VM) of a call loop in the unwinder.

- **VM**: `RETURN_VALUE` returns from `run_loop`; each `run_loop` runs
  exactly one frame. Yields set `GenState.yielded` and return.
- **Interpreter**: a thread-local `FlowState` (`pending` = return / break /
  continue, plus the value). Blocks, `if` and every loop check it after each
  statement. `evalBody` at the function-body call sites and the loops
  consume it. Constructs that must see a real exception (try/with/switch/
  class/namespace/import/macro) suspend the fast path (`SuspendFast`).
- 100k calls: interpreter 2341 → 371 ms (function) and 3554 → 485 ms
  (method); VM 7240 → 121 ms and 6414 → 180 ms.
- Found on the way: `while`/`repeat` on the interpreter swallowed every
  exception raised in their body. They now rethrow.

### Interpreter: inherited methods read as values (9f8c96e)

`obj.method` evaluated to `none` when the method was inherited, although
calling it worked. The IDE registers `self.on_resize` (defined in a base
class) as its resize callback, so **resizing never relaid out the
workbench**. `evalAttribute` now walks the bases depth-first (an MRO walk).

### Responsiveness (294c5a6)

Measured with the headless driver on an 1,800-line file:

| | before | after |
|---|---|---|
| keystroke | 381 ms | 34 ms |
| scroll step | 72 ms | 37 ms |
| window resize | 81 ms | 29 ms |

About 16 ms of each "after" figure is frame pacing. Memory kept
(`ide_memprobe.py`): idle 0, hover 0, typing ~18 KB/key, scroll ~8 KB/event.

The profile showed where the time went:

- **Completion** rebuilt its candidates by walking every line on every key.
- **Syntax checking** spawned a second interpreter and waited for it.
- **The SCM gutter** ran Myers diff as a script loop inside the painter.
- **Search, Quick Open, workspace symbols and go-to-definition** read and
  split every file in the interpreter.

All of that is now in **`src/builtins/text.cpp`**, on both engines and
pinned by `examples/vm_audit51.ny`:

- `ny_symbols`: a tolerant outline with class bases, method parameters,
  fields, variables, constants and depth.
- `ny_check_syntax` / `ny_check_file`: the real lexer and parser, in process.
- `text_diff` / `text_diff_classify`: Myers diff. `text_diff_classify`
  agrees with `LineDiff.classify` on 60 random edits.
- `fs_list_files`, `fs_search` (case / word / regex, include / exclude
  globs), `fs_symbols`, `fs_todos` and `fs_line_stats` for the workspace.
- `text_fold_ranges` (indentation blocks and `# region`), `text_line_stats`,
  `text_todos` and `text_format_nython`.
- A **completion index** (`ac_index_*`). Candidates stay in C++ and come
  back as cached strings, so a keystroke allocates one result list.

**Layout ladder.** Each step has hysteresis, so resizing across a threshold
does not flicker:

- The side bar floats over the editor, with a shadow and light dismiss,
  when the editor would be narrower than 360 dp.
- The menus fold into a hamburger that lists the menus and has a way back.
- The command centre shrinks, then hides.
- Activity-bar views and panel tabs that do not fit move to a `...` menu.
- Status-bar items drop lowest priority first.

### Code::Blocks features (`ide_tools.ny`, class `IDETools` in the chain)

These are Code::Blocks' everyday features, rebuilt around this IDE's own
models rather than copied:

- **Build targets** come from `[target Name]` sections in `*.nyproj`
  (`main`, `engine` = interp/vm, `args`, `cwd`, `env`, `pre`, `post`).
  Build, Rebuild, Clean, Build and Run, Run Target and Abort (Shift+F5).
  - The build is *time-sliced*: `_build_step` checks one file per slice
    within an 8 ms budget from the frame tick, with `ny_check_file` in
    process, so the IDE keeps drawing while it builds.
  - Errors go to Problems and to a **Build Log** panel.
  - The selected target is saved in `.nyide`.
- **Bookmarks** (Ctrl+Alt+K / L / J, gutter icon, context menu) and
  **folds** move with inserted and deleted lines. A mark carries down with
  its text when Enter is pressed before it, as Scintilla's markers do.
- **Code folding**: gutter chevrons, Ctrl+Shift+[ / ], Fold All, Unfold All
  and fold by level. Scrolling, the caret, go-to, the minimap and clicks
  all work in visual rows. A folded body shows a `...` marker that unfolds
  when clicked, and jumping into a fold opens it.
- **Abbreviations**: 20 snippets plus user snippets from `.nyide`, with tab
  stops written `$<n:text>` (`${}` would be string interpolation in Nython).
  They appear in the completion list with an exact prefix first, as in VS
  Code. While tab stops are active, suggestions do not open by themselves
  (VS Code's `snippetsPreventQuickSuggestions`), and Escape leaves snippet
  mode.
- **Editing**:
  - Insert/overwrite (Insert key, an OVR status item). A run of overtyping
    undoes as one step.
  - Duplicate, transpose, upper / lower / title case.
  - Format Document / Selection (Shift+Alt+F) in the file's own
    indentation unit, as one undo step.
- **Column (box) selection**: Shift+Alt+drag, middle-button drag,
  Ctrl+Shift+Alt+arrows, or *Column Selection Mode* (Shift+arrows and plain
  drags select rectangles, like Code::Blocks' Alt+drag). The box is two
  corners in text-area pixels, so tabs line up by what is on screen. Each
  row becomes one selection of the multi-cursor model, so typing, Backspace
  and Delete act on every row. Copy joins the rows, cut removes them, and
  paste spreads one line per caret when the counts match (VS Code's
  "spread"). Copy, cut and paste with several selections used to act on the
  primary only.
- **Split editor**: two editor groups, side by side (Ctrl+\\) or stacked
  (Ctrl+K Ctrl+\\; Shift+Alt+0 toggles). Each group has its own document,
  caret, selection and scroll, even on the same file. Ctrl+1 / Ctrl+2 move
  the focus, a click in the other group focuses it, and the wheel scrolls
  it without taking the focus. The sash drags, and Join Editor Groups
  closes the split. Painting uses one painter: the other group's view is
  kept in scalars and swapped in, so the split allocates nothing per frame
  (`ide_memprobe.py` measures it against plain hover at the same point).
  The status bar's build target no longer lists the workspace folder on
  every frame.
- **Window integration** (on the GUI merge):
  - The loop now sleeps waiting for input after a frame that painted
    nothing, instead of redrawing continuously. While a program, a build
    or a debug recording runs, the wait drops to one frame so output
    arrives promptly.
  - The window works in pixels (`high_dpi`). The metrics were already
    multiplied by the display scale, so on a Retina or scaled Wayland
    display the workbench used to come out at twice its size.
  - The minimum window size is 400×270 (VS Code's).
  - F11 is real full screen.
  - A file dropped on the window opens; a dropped folder becomes the
    workspace; dropped text lands where it is dropped.
  - `auto_save = onFocusChange` saves when the window loses focus. Coming
    back re-checks the workspace and git.
  - `tools/ide_driver.py` sends pointer positions in points when
    `NY_STUB_DPI_SCALE` is set, so the IDE can be driven at 2×. Note that
    many e2e checks use fixed scale-1 regions, so only the region-free
    scenarios pass at 2×.
- **Background work off the frame thread** (on the OS merge):
  - `BgProc` (Run, Build, tools, the debugger's recording, the terminal)
    runs on `os_spawn` / `os_proc_read` / `os_poll` / `os_kill`. Nothing
    goes to disk, polling starts no process (it used to start `tail` each
    time output grew), and Stop signals the whole process group. Where
    `os_spawn` is unavailable (Windows) it falls back to the file-and-`tail`
    route.
  - Source Control's refresh (branch, HEAD, `git status`) is one background
    process instead of 3–4 synchronous ones after every save.
    `GitRepo.refresh_command()` / `apply_refresh()` are shared with the
    synchronous `refresh()` that `vm_audit43` tests.
- **Keymaps**: VS Code or Code::Blocks (`CB_KEYMAP`: F9, Ctrl+F9, Ctrl+D,
  ...). *Change Keybinding* captures a pressed key. Bindings are saved in
  `.nyide` (`keybinding = Ctrl+Alt+M | command.id`).
- **Tools**:
  - Class wizard: a file with the constructor and `__str__`, which runs.
  - Code statistics per file and in total (code, comment, blank, doc).
  - TODO list panel for the file or the workspace, with owners.
  - User tools with `$(FILE)`, `$(LINE)`, `$(WORD)`, … macros.
  - Environment variables for runs, targets and tools.
  - Saving writes a `.bak` backup when the setting is on.
- **Debugger**: breakpoint conditions (`i == 3`), hit counts (`5`, `>5`,
  `%5`) and log points (`i is {i}`). Log points passed before a stop print
  to the Debug Console. Also Run to Cursor and Add to Watch.
- **Session**: open editors, the active editor and the caret are restored
  on the next start.

Defects found while driving these, all fixed:

- **Two undo steps for one action.** Every action that deletes and then
  inserts recorded two steps: completion accept, replace-one, paste over a
  selection, wrapping a selection in brackets, format, transpose and case
  change. They now use `open_group`/`close_group`.
- **Wheel events had no modifiers.** Wheel events carried no Ctrl/Shift/Alt,
  so Ctrl+wheel zoom and Shift+wheel sideways scroll never worked
  (`gui.cpp`). The stub's `wheel` command takes modifiers now.
- **`K=v cmd` in tool environments.** The shell expanded `$K` before the
  assignment existed, so tool lines like `echo $GREET` saw nothing. The
  environment is now `export`ed first.
- **Wrong completion highlight.** The popup highlighted the first
  `len(prefix)` characters, not the ones the fuzzy matcher matched.

e2e scenarios added: `build`, `cbedit`, `cbtools`, `cbdebug`, `responsive`,
`session`, `columns`, `split`, `window`.

---

## 0j. Round 74 — the language engines: exceptions, classes, scope, syntax

Merged from `round74-lang1`, on top of §0i. After this merge the sweep
has 0 not-ok runs on either engine, for the first time: the long-standing
VM failures of `vm_audit23`/`25` (`@property`) are fixed. New tests:
`vm_audit52` (exceptions), `vm_audit53` (classes) and `vm_audit54`
(comprehensions, patterns, calls).

A divergence battery of 286 programs is compared on the interpreter, the
VM and `python3`:

| Build | All three agree | Interpreter ≠ Python | VM ≠ Python | Interpreter ≠ VM |
|---|---|---|---|---|
| f284623 | 87 | 165 | 171 | 119 |
| before this branch | 179 | 79 | 89 | 66 |
| after | 262 | 23 | 17 | 9 |

- **Exceptions are objects.**
  - Builtin exceptions are real classes.
  - Typed `except` catches exceptions from called functions and runtime
    errors on both engines. The VM lost the exception object whenever it
    unwound a frame.
  - An unmatched `except` passes the error on after `finally`, and
    `finally` runs when an `except` body raises. A bare `raise` re-raises.
  - `with` gives `__exit__` the exception, and a true return from
    `__exit__` suppresses it.
  - `assert` raises AssertionError. `str(e)` is the message.
  - The four PENDING checks in `vm_audit46` are now real, passing checks.
- **Silent errors now raise.**
  - NameError for undefined names.
  - AttributeError for calling a missing method.
  - TypeError when a call does not fit its parameters: too few or too many
    arguments, an unexpected keyword, or multiple values for one parameter.
  - Library calls that were silently wrong were fixed: `EventBus.off`,
    `get_history`, `save_model`, `add_noise`, and two `__exit__`
    signatures.
- **Classes.**
  - C3 MRO over every base; `super()` walks it, forwards keyword arguments
    and passes through a class without `__init__`.
  - On the VM, class bodies run: class attributes, decorators,
    `@property` with setter, `@staticmethod` and `@classmethod`.
  - Defaults are evaluated at definition, including lambda defaults,
    method defaults such as `-1` and `[]`, and `f(**d)`.
  - The operator and object protocols: `__eq__`, including inside
    containers, `in`, `index`, `count` and `remove`; `__iter__`;
    reflected and unary operators; `__mro__` and `__bases__`.
  - The interpreter segfault on `class E(Exception)` is fixed.
- **Scope.**
  - The VM resolves names lexically; it used to search every frame on the
    stack.
  - Comprehensions have their own scope, and loop variables no longer leak
    to globals.
  - VM imports export only the module's own names.
  - `x is Name` is decided at run time.
- **Syntax.**
  - `match` with `|`, guards, sequence, star, mapping, class and `as`
    patterns. Each case is evaluated once, and values are no longer
    compared as strings.
  - Walrus in `if` and `while`. `while (a) < 3` parses.
  - Raw strings, general decorators, starred and nested unpacking.
  - Several `for`/`if` clauses in one comprehension, including over
    strings, dicts and generators.
  - The `@` operator.
  - The VM `switch` default runs, and the stray walrus debug output is
    gone.
- **Speed.** A benchmark of 200k calls, 100k method calls and fib(22):
  interpreter 1.35 → 0.85 s; VM 0.53 → 0.52 s. Removing five hot-path costs
  that the arity and NameError checks had added kept the VM from being
  15–20% slower.
- **Not done.**
  - ~~Interpreter generators are still eager~~ - lazy since round 75 (§0l).
  - Interpreter lambdas bind loop variables by value.
  - ~~Reading a missing attribute still gives `none`~~ — round 75 (§0m):
    it raises AttributeError, and a missing dict key KeyError.
  - ~~Reading a name after `del x` gives `undefined` or `none`~~ (round 75:
    `del x` unbinds, NameError after), not
    NameError.
  - Unpacking with the wrong count raises no ValueError.
  - There is no `object` builtin.
  - ~~Assigning to a global inside a function needs no `global` (to be
    ruled on)~~ — ruled in round 75 (§0m): kept; `var`/`let`/`const` declare
    a local, `global` names the module's variable. (Was: to be
    ruled on).
  - Exception names are listed in both `NyExcTypes.hpp` and
    `NyRuntime.hpp`.

---

## 0i. Round 74 — Python values and builtins on both engines

Merged from `round74-lang2`.
- `examples/vm_audit60.ny` (284 checks) passes on both engines and gives
  the same results under `python3`.
- `vm_audit61` (33 checks) covers behaviour only Nython has.
- Divergence batteries (snippets where Python, the interpreter and the VM
  all agree), values and builtins: 36 → 109 of 120.

- **Shared libraries.** `NyBigInt`, `NyStr`, `NyFormat`, `NyOrderedMap` and
  `builtins/pycore.cpp` are used by both engines.
- **Dicts.** Insertion order is kept. Keys are typed: `1`, `"1"` and `1.0`
  follow Python, and tuple keys work. `__len__` is an ordinary key.
  `copy()`, `dict(a=1)`, `list(d)` and `sorted(d)` work.
- **Integers.** Exact at any size. The VM promotes past 64 bits and never
  overflows. Literals past 64 bits used to read as 0.
- **Formatting.** One formatter serves f-strings (with format specs and
  `!r`/`!s`/`!a`), `format()`, `str.format` and `%`. Float repr and
  `round` half-to-even follow Python.
- **Operators.**
  - `not`/`and`/`or` follow truthiness, and `and`/`or` return an operand.
  - `L += it`, `L *= n` and `s *= 3` work in place.
  - `3*"ab"`, `true+true` and `7.5//2`.
  - `divmod`, `pow(b, e, m)`, and `hex`/`oct`/`bin` of negatives.
  - `-2**2 == -4`.
- **Tuples** are real on the VM and distinct from lists on the interpreter.
- **Strings.**
  - Indexing, slicing and `len` count UTF-8 characters.
  - 74 string methods have one implementation.
  - List and string reads out of range raise IndexError.
  - `del` / `pop` of a missing key raise KeyError.
- **Deliberately lenient**, because library code relies on it:
  - ~~reading a missing dict key gives `none`~~ (round 75: KeyError, §0m)
  - assigning past the end of a list grows it
  - `len(none) == 0`
  - `"a" + 1` concatenates
- **Behaviour change.** Arithmetic on unsupported types (`1 + none`, an
  instance + int) raises TypeError on both engines. It used to give `none`
  on the interpreter and `1` on the VM. `lib/gui.ny`'s `Spotlight` and
  `ToastManager` defaults were fixed for it.
- **VM method calls with keyword arguments** (`obj.f(1, b=2)`) returned
  `none` for every method. `**kw` is `{}` rather than `none` when no
  keywords are passed. On the VM, a native's keyword map carries
  `class_name "__kwargs__"`, and natives take it off with `take_kwargs()`.
- **The VM builtin bridge** passes exact values both ways. Changed
  arguments reach the caller (`tensor2d_set(t, …)` changes `t`), and
  returned containers keep their identity.
- **Stale expectations.** 34 checks in 17 example files (HANDOFF §5.8) now
  expect Python's values.
- **Test isolation.** `vm_audit24` and `vm_audit43` use per-run temp paths.
  The sweep runs both engines at once, and a shared path let one run delete
  the other's git repository (fixed on merge).
- **Speed.** Interpreter: list −52%, map −44%, call −24%. The VM is +1–6%,
  from the ordered map in frame locals.
- **Not done.** The VM gaps listed here when this was merged were
  `@property`, name resolution and top-level `except X as e`. §0j fixed
  all of them.

---

## 0h. Round 74 — nytorch: one tensor engine, real models

Merged from `round74-torch`. `vm_audit47` has 153 value checks against
PyTorch-derived numbers and finite differences, byte-identical on both
engines. All of `test_nytorch9`–`17` and `vm_audit38`–`41` pass on both
engines.

- **One kernel library for both engines.** It lives in
  `include/NyTensor.hpp` and `src/builtins/nytensor.cpp`, in float64 C++.
  - The interpreter reaches it through `dispatch_nt`, first in the
    `callBuiltin` chain. The VM reaches it through `register_nt_natives()`.
  - The kernels: broadcasting; axis reductions; blocked batched matmul;
    views and slicing; stable softmax; conv2d, pooling, BatchNorm,
    LayerNorm and embedding; a seeded RNG with `manual_seed`; NYTENSOR v2
    save/load; STFT, mel and DCT; CTC forward-backward; einsum; NMS.
  - Bad arguments raise typed errors.
  - The VM's stub natives, which returned random numbers or echoed their
    input, are deleted.
- **Tensor representation.** A tensor is a flat row-major list plus a shape
  list, not an opaque handle, because a handle store would leak in the
  interpreter. Fused kernels and in-place optimizer steps keep allocation
  down.
- **The library on top.**
  - `tensor.ny`: Tensor with an iterative backward pass, `no_grad`,
    operators and indexing.
  - `module.ny`: Module with `parameters`, `state_dict`, `train`/`eval`, and
    `Sequential`.
  - Layers, attention, losses on logits with class indices, optimizers
    (SGD, Adam, AdamW, RMSprop) and schedulers, and DataLoader.
  - `lib/nytorch/core.ny` is the single import every submodule starts from.
  - The legacy `Variable` API runs on the same engine.
- **Fake implementations replaced with computing ones**, across parts 13 to
  17 and `advanced`: RL agents, transformers, GNNs and serving; conv nets,
  detection, audio, ARIMA and a CTC-trained ASR model; Neural ODE, KAN,
  PINN and world models; RetNet, RWKV, Mamba, DiT, DDPM and xLSTM; LoRA,
  MoE and S4. The scope limits are written in docstrings (for example,
  Mamba2 uses the Mamba-1 scan).
- **Magnitude pruning** removes exactly floor(s·n) of the smallest weights.
  This ends `test_nytorch17`'s statistical flake.
- **Speed.**
  - Native matmul 128×128: interpreter 318 → 16 ms. The VM's version used
    to return `[]`; it now takes 4 ms.
  - A training step of a [16,64,4] MLP at batch 32: interpreter 788 →
    6.4 ms, VM 787 → 2.5 ms (Module API).
- **Not done.**
  - ~~Interpreter memory is still high: the worst nytorch tests peak near
    1 GB, because the interpreter never frees containers (GC_NOTES).~~
    Fixed in round 75 (§0k): 81-181 MB.
  - The library works around several language bugs (these are in the
    language work), which the torch agent listed:
    - a bare call inside a method resolves to a same-named method
    - constructor `*args` arrive empty
    - a callable instance used as an attribute call returns `none`
    - `__iter__`
    - missing reflected and unary operators
    - `@` is not lexed

---

## 0g. Round 74 — threads, synchronisation and async (both engines)

Merged from `round74-conc`. Tests: `vm_audit48` (threads and
synchronisation, 125 checks), `vm_audit49` (async, 41) and `vm_audit50`
(`lib/thread.ny`, 51). All three pass on both engines, including under CPU
load and parallel runs. helgrind finds 0 data races.

- **One runtime for both engines.** `include/NyConc.hpp` and
  `src/NyConc.cpp` implement and dispatch every concurrency builtin (166
  names). Each engine supplies only an adapter (`InterpEngine` in
  `threading.cpp`, `VMConcEngine` in `src/VMConc.cpp`), so the engines
  cannot drift apart.
- **The GIL.** There is one process-wide lock, because VM threads call
  interpreter builtins through the bridge.
  - It is a first-in-first-out ticket lock. The holder hands it over after
    5 ms when another thread is waiting.
  - Threads switch at every statement on the interpreter, and at frame
    entry and backward jumps on the VM.
  - It is off until the first thread starts. A single-threaded program pays
    one relaxed atomic load per check (+0.04% instructions on the
    interpreter, +0.2–0.7% on the VM).
  - Every blocking call releases it: waits, sleeps, joins, `popen`,
    `os_run`/`os_wait` and the process polls, and the window's idle wait
    for events (added on merge).
- **Interpreter per-thread state** is now `thread_local`. This includes
  `last_stmt`, whose shared pointer was corrupting the heap.
- **VM threads** share one `VirtualMachine`. Each thread's operand stack,
  frame stack and in-flight exception are swapped in with the GIL.
- **Blocking waits** all go through one function, which handles timeouts,
  cooperative cancellation and deadlock detection. A wait-for-graph cycle,
  or every thread blocked with no timeout, raises `DeadlockError` instead
  of hanging. Optional lock-order checking (`lockdep_enable`) raises
  `LockOrderError`.
- **Async.** `async def` compiles to a coroutine factory and `await x` to
  `async_await(x)`.
  - One task runs at a time, in a deterministic order: ready tasks first in,
    first out; timers by deadline, then creation order.
  - The API: `async_run`, `create_task`, `gather`, `gather_settled`,
    `wait_for`, `async_sleep`, `task_cancel`, `async_call_later`.
  - Channels, locks, futures and sleep suspend only the calling task.
- **Primitives**:
  - threads: join with timeout, result, daemon, thread-locals, cancel
  - locks: mutex, recursive mutex, rwlock, condition
  - signalling: semaphore (bounded), event, barrier, latch
  - atomics
  - channels (unbuffered, buffered, unbounded, close, a Go-style `select`
    that picks the first ready case)
  - FIFO, LIFO and priority queues
  - futures with callbacks and `as_completed`, a thread pool, timers, and
    task groups (the first failure cancels the others)
- **`lib/thread.ny`** is rewritten over these natives; the old names still
  work. Its event class is `ThreadEvent`, because `lib/gui.ny` already has
  `Event`.
- **Behaviour change.** `semaphore_acquire` now blocks, as in Python. A lone
  thread waiting forever raises `DeadlockError`. `stdlib_test` and
  `stdlib_v2_test` use `semaphore_try_acquire` for the non-blocking check.
- **Found and fixed on the way:**
  - On the interpreter, inherited methods got none of their default
    arguments.
  - `with` passes the exception to `__exit__`.
  - A pool worker could exit early.
  - Failures of threads nobody joined were swallowed at exit.
- **Not done:**
  - Handles are never freed, so a program that creates millions of
    primitives grows.
  - `--trace`'s function stack is shared between threads.
  - Cancellation is only checked at blocking calls.
  - There are no async generators or streams.
  - On the VM, an exception from another thread keeps its class name but
    loses extra fields.
  - The VM `with` + `return` gaps belong to the language work.

---

## 0f. Round 74 — the OS layer (files, paths, processes, environment, time)

An audit of every os/file/path/env/time/process builtin on both engines found
20 defects (below) and most of Python's os/os.path/shutil/subprocess/glob/
tempfile/time surface missing. Both were addressed. **One implementation per
builtin, both engines:** the VM's own copies of the os/io/time natives
(`register_os_builtins`, `register_io_builtins`, `register_time_builtins`, the
time block in `register_builtins`, `time_now`/`time_ms` in
`register_nytorch_builtins`) were deleted; the VM reaches the interpreter's
implementations through the builtin bridge. `import os/time/io/shell` on the VM
no longer re-installs anything.

Where things are:
- `src/builtins/os.cpp` — files, paths, environment, system info (dispatch_os,
  which forwards to the two below); shared helpers in
  `include/builtins/os.hpp` (`nyos::Args` for kwargs, list/map builders,
  `raise_errno`, path functions).
- `src/builtins/os_time.cpp` — every `time_*` name, `time`, `clock`,
  `monotonic`, `perf_counter`, `sleep_ms`, `uuid` (math.cpp's and
  string.cpp's copies were removed; `sleep`/`thread_sleep` stay in
  threading.cpp).
- `src/builtins/os_proc.cpp` — `os_run`, `os_spawn`/`os_poll`/`os_wait`/
  `os_kill`/`os_proc_read`, the legacy shell captures, `which`,
  `shell_quote`, `sys_argv`.
- `include/NyRuntime.hpp` — sys.argv / script path / executable, the builtin
  exception hierarchy table (`builtin_exc_parent`, `exc_matches`), the
  `"__exc__:Type:msg"` convention (`make_exc`, `parse_exc`), module
  namespaces (`module_members`, `builtin_member`).
- `include/NyPrelude.hpp` — Nython source both engines run at startup: the
  `NythonFile` class and `open()`.

### Contract
- **Legacy names keep their return-value contract** (the IDE depends on
  them): `os_remove`/`os_rename`/`os_mkdir`/`file_copy` return bool,
  `os_listdir` returns `[]` for a missing dir, `read_file` returns `""` for a
  missing file, `file_open` returns -1, `os_exec`/`shell`/`system`/`cmd`
  return the command's stdout.
- **New names raise typed errors like Python**: `os_stat`, `os_lstat`,
  `os_rmdir`, `os_rmtree`, `os_makedirs`, `os_unlink`, `os_copy`,
  `os_copytree`, `os_move`, `os_chmod`, `os_symlink`, `os_readlink`,
  `os_touch`, `os_chdir`, `os_mkstemp`, `os_mkdtemp`, `os_disk_usage`,
  `os_path_getsize`/`getmtime`, `open()`, `os_run`/`os_spawn` (a program that
  cannot start), timeouts (`TimeoutError`). Messages read like Python's:
  `[Errno 2] No such file or directory: '/x'`.
- Natives raise with `throw std::string("__exc__:Type:msg")`
  (`nyos::raise`/`raise_errno`). The bridge (`src/main.cpp`
  install_vm_builtin_bridge) turns that - and any C++ exception - into the
  VM's normal raise path (`VirtualMachine::raise_native_exception`: an
  instance of the builtin exception class + `std::runtime_error`), so it is
  catchable by `except Type` in the same frame on the VM.
- **Keyword arguments to builtins**: the interpreter now passes them to the
  names in `kwmap_builtins` (NythonExecutor.hpp, evalCall) as one trailing
  map - the VM's CALL_KW convention - and `nyos::Args` takes it off. A new
  builtin with kwargs: add it to `kwmap_builtins` and read it with `Args`.

### The 20 audit defects (all fixed; checked by value in vm_audit46)
1. VM `time_ms()` returned SECONDS after `import nytorch` (lib/os.ny,
   stdlib.ny and gui.ny all import it). 2. VM `import time` made `time_now`
   whole seconds and `sleep(0.5)` a no-op — stdlib's `Timer` measured 0.
3. `shell`/`system`/`cmd` returned stdout on the interpreter and the raw wait
   status (768 for exit 3) on the VM. 4. `os_mkdir` recursive on one engine
   only; `mkdir` of an existing dir true on one, false on the other;
   `os_mkdir(file)` true. 5. `os_getenv(unset)` none vs ""; VM natives read
   non-string args as "". 6. `os_path_join("a","/b")` gave `a//b`,
   `dirname("/x")` gave `""`, `ext("/a.b/c")` gave `.b/c`, `os_path_abs` of a
   missing path gave `""`, VM basename ignored `\`. 7. `file_size`/`fs_stat`
   were int32 (3 GB read -1073741824). 8. `file_copy` of a missing source left
   an empty destination. 9. `time_format` ignored its timestamp and returned
   garbage past 63 chars. 10. `open()` returned an int, so `with open(p) as f:
   f.read()` was none. 11. Reading a directory surfaced a raw C++ stream
   failure (now IsADirectoryError). 12. Interpreter builtins' exceptions were
   uncatchable on the VM (bridge translation). 13. `process_exec` merged
   stderr of the last command only; `os_exec` left `\r`, cut at NUL.
   14. `kv_set` truncated multi-line values. 15. `fs_walk` was not recursive;
   `file_readline` split lines over 8 KB; `write_bytes` wrapped 300 to 44.
   16. `import sys` gave `argv = "nython"` and a hard-coded platform; no script
   arguments at all; `os.getcwd()` read none. 17. `int()`, `//`, `//=`,
   `**=`, `abs()`, unary minus and `~` truncated to 32 bits on the
   interpreter (`int(time_ms())` was -2147483648, so every temp file name
   collided). 18. (VM `with` skipping `__exit__` — handed to the
   exception-machinery work, not done here.) 19. lib/os.ny: `listdir_full`
   looped forever, `Process.shell` recursed, `run_check` always true, `pid()`
   was a shell's pid, `copy` of a missing file "succeeded". 20. Dead or
   shadowed duplicates (os.cpp's second `ls`/`mkdir`/`path_exists`, math.cpp's
   `time_*`, data.cpp's `open`) removed.

Also: `time.time()` / `len.x` — any attribute of a builtin — was a
segmentation fault on the interpreter (evalAttribute read the builtin's
std::string as an AST node). `import time; time.time()` now works on both
engines, as do `import os; os.getcwd(); os.path.join(...)`.

### Added (all on both engines)
Paths: `os_path_split/splitext/normpath/abspath/realpath/relpath/isabs/
expanduser/expandvars/commonpath/exists/isdir/isfile/islink/getsize/getmtime`,
`os_glob`/`glob` (`**` recursive), `fnmatch`, `os_sep`/`os_pathsep`/
`os_linesep`/`os_name` constants. Files: `os_stat`/`os_lstat` (int64 size,
mtime/atime/ctime, mode, permissions, is_link, uid, gid, nlink, ino),
`os_walk` (Python's shape), `os_makedirs(exist_ok=)`, `os_rmdir`, `os_rmtree
(ignore_errors=)`, `os_copy`, `os_copytree`, `os_move` (cross-device),
`os_unlink`, `os_chmod`, `os_symlink`, `os_readlink`, `os_islink`,
`os_touch`, `os_access`, `os_mkstemp`, `os_mkdtemp`, `os_gettempdir`,
`os_disk_usage`, `file_seek`/`file_tell`/`file_flush`, `file_readline(h,
keep_newline)`. File objects: `open(path, mode="r")`. Processes: `os_run(cmd,
cwd=, env=, input=, timeout=, check=)` → `{code, stdout, stderr, ok}` (a list
runs via fork+execvp with no shell); `os_spawn` / `os_poll` / `os_wait
(timeout=)` / `os_kill(sig=)` / `os_proc_read`; `os_system`, `os_getpid`,
`os_getppid`, `shell_quote`, `which`. Environment/system: `os_unsetenv`,
`os_environ`, `os_platform`, `os_cpu_count`, `os_hostname`, `os_username`,
`os_home`, `os_uname`. Time: `time_ns`, `monotonic`, `perf_counter`,
`process_time`, `time_format(fmt, ts, utc)` with `%f`, `time_localtime`/
`time_gmtime`, `time_mktime`/`time_timegm`, `time_strptime`, `time_iso`,
`time_parse_iso`, `uuid` (a real v4 UUID; the VM's was `whk_` + 8 hex).
Interpreter-side names the VM already had: `time`, `clock`, `sleep_ms`,
`append`. `sys.argv` (script path + the arguments after it on the command
line, both engines, `--vm`/`--profile`/`--trace` too), `sys.platform`,
`sys.executable`, `__name__` (`"__main__"`, the module name while a module's
top level runs), `__file__`. New exception types registered on both engines:
IsADirectoryError, NotADirectoryError, FileExistsError, ChildProcessError,
ProcessLookupError, InterruptedError, BlockingIOError, BrokenPipeError,
ConnectionRefusedError, ConnectionResetError, LookupError, EOFError,
ModuleNotFoundError, UnicodeError.

### Verification at the end of the round
- `examples/vm_audit46.ny`: 252 passed, 0 failed on both engines (2 pending on
  the interpreter, 4 on the VM - see below).
- `python3 tools/sweep.py --base /tmp/obuild/nython_orig`: 178 runs,
  **0 regressions**, 12 fixed; the only not-ok runs are vm_audit23/25 on the
  VM, not ok on the baseline too. Against the branch head's own binary: 0
  regressions.
- `tools/ide_e2e.py` 227 passed, 0 failed; `tools/ide_lint.py` 0 unresolved.
  `tools/ide_memprobe.py --check` reports hover at ~6 KB/event, above its
  2.0 ceiling - and so does the branch head built from the same commit
  (5.89), so it is not from this round; idle/typing/scroll are unchanged.
- Cost: the interpreter parses the prelude at startup (+~5 ms per process);
  `//` on 64-bit operands is now twice as fast as before the round.

### Not done / pending
- **Exception hierarchy and cross-frame catching** belong to the separate
  exception-machinery work: `except OSError` does not yet catch a
  FileNotFoundError on either engine, an unmatched typed `except` still
  swallows the error, and on the VM an error raised inside a called
  function is not caught by a typed `except` in the caller. vm_audit46
  reports these as PENDING (`check_pending`); turn them into `check` once
  that lands. `NyRuntime.hpp` has the parent table (`builtin_exc_parent`,
  `exc_matches`) ready for evalTry and `match_except_handler`. Because of
  the frame issue, the VM installs a native `open()` (after the prelude) so
  `open(missing)` raises in the caller's frame; the file object is still the
  prelude's.
- The IDE's background jobs (`ide_ops.ny`, `sh -c ... & echo $!` + `tail`)
  were not moved to `os_spawn`/`os_proc_read`; they can be now.
- Windows: `os_run` goes through the shell (stderr/stdin via temp files, no
  timeout); `os_spawn`/`os_poll`/`os_wait`/`os_kill` raise OSError; symlinks
  raise. The _WIN32 branches were written but could not be compiled here.
- VM integers are 64-bit: `int("1" * 30)` is OverflowError there, a bigint on
  the interpreter.

---

## 0d. Round 73 — the IDE to VS Code standard, verified by driving it

The request: continue the IDE "with the real standards of VS Code, making
sure that all the functionalities are really working and all the clicking
items perform the expected task". Until this round nothing that happens on a
click or a keystroke had ever been exercised: the stub could construct the IDE
and quit it, nothing more (§5.3 said so each round). So the round started by
building the means to check, then used it on everything.

### How it is verified now

| Tool | What it does |
|---|---|
| `thirdparty/sdl3-stub` | scripted/live input (`NY_STUB_EVENTS`: move, click, dblclick, drag, wheel, key, type, resize, snap, quit), real SDL key names and modifiers, clipboard, and a capture of every primitive of the last presented frame (`snap PATH`). Text is measured with DejaVu's real advance widths, so captured layouts are exact. |
| `tools/nyshot.py` | turns a captured frame into a PNG (fonts, clipping, alpha) and finds text on screen. |
| `tools/ide_driver.py` | runs `build/nython --ide` with a live input channel; `click_text("Save All")`, `key("ctrl+shift+p")`, `type(...)`, `snap()`, `state()` (the IDE's own `developer.dumpState`, Ctrl+Shift+Alt+J), `hitmap()` (every clickable region, `developer.dumpHitMap`). |
| `tools/ide_e2e.py` | 21 scenarios through real input — editing/undo/save, clipboard and line commands, multi-cursor, palette, Quick Open (`>` `:` `@` `#`), menus, find/replace, every status-bar item, explorer create/rename/delete/refresh, close-with-unsaved, terminal, Run, Problems, debugger, Source Control, Search, views/layout — plus two **dead-click audits** that click every clickable region (editor chrome; then each side view and panel with content in it) and require each to change something. Prints `N passed, M failed`. |
| `tools/ide_lint.py` | static: `self.x` / `th.x` / typed receivers no class defines (Nython returns `none` instead of raising), reserved words as names, a method named `init` (a constructor alias here), **commands registered without an `_exec` branch and click targets nothing routes**. |
| `tools/ide_memprobe.py` | resident memory kept per idle frame, hover event, keystroke and scroll step, with ceilings (`--check`). |
| `tools/sweep.py` | the content-level sweep (§2) on both engines, optionally against a baseline binary, reporting regressions and fixes as sets. |
| `--profile` | now also counts, per function, the objects and strings it leaves alive; `NY_PROFILE_OUT=f nython --ide` profiles the IDE itself. This is what found the memory problems below in minutes. |

### The IDE

One class, `NythonIDE`, in a chain of files (`IDE_FILES.md` has the map):
`ide_core.ny` → `ide_ops.ny` → `ide_paint.ny` → `ide_views.ny` →
`nython_ide.ny`, with window-free models in `lib/ide_workbench.ny`,
`lib/ide_scm.ny`, `lib/ide_debugger.ny`. What it does, all driven by the e2e
suite:

- **Commands.** ~150 VS Code command ids (`workbench.action.files.save`,
  `editor.action.commentLine`, …) with categories, keybindings (alternatives,
  chords like Ctrl+K Ctrl+S, when-clauses such as `editorFocus`,
  `!inputFocus`, `inDebugMode`) in `CommandRegistry`. Menus, the palette,
  context menus, buttons, the status bar and keys all name commands; there is
  one dispatcher (`_exec`). Unknown ids report themselves.
- **Quick Input**: files (Ctrl+P), `>` commands with recently-used first (only
  palette use counts, as in VS Code), `:` line, `@` symbols, `#` workspace
  symbols, pickers (theme, language, EOL, encoding, indentation), prompts
  (new file, rename, commit message…), a path dialog. Every input — here, find,
  search, SCM message, terminal, Debug Console — is a real text field
  (`LineEdit`): caret, Shift/Ctrl movement, selection that typing replaces,
  clipboard, click-to-place, double-click word; pre-filled prompts are selected
  (rename selects the name without its extension).
- **Documents**: untitled/file/virtual/welcome, dirty dot, Save / Save As /
  Save All / Revert, Save · Don't Save · Cancel on close and quit, reopen
  closed editor, preview on single click. The final newline is an empty last
  line, as in VS Code (Ctrl+End goes below the last line of text).
- **Editing**: grouped undo — a typing run, typing over a selection, a
  multi-caret edit, comment toggle, line move, indentation conversion, Replace
  All: one Ctrl+Z each; auto-closing pairs and step-over; line copy/cut/paste
  with no selection; Ctrl+D / Ctrl+Shift+L / Alt+Click carets; bracket
  matching; breadcrumbs from the real enclosing scope.
- **Indentation**, per file: detected on open (tabs vs spaces by vote, size
  by the most common indent step), status bar `Spaces: 4` / `Tab Size: 4`,
  VS Code's picker (Indent Using Spaces/Tabs, Detect, Convert to Spaces/Tabs),
  tabs drawn at tab stops, Enter keeps the line's own whitespace.
- **Workspace watching**: one `file_mtime` per visible folder and open file
  (new builtin) — files made outside appear in the explorer, clean editors
  reload when the file changes on disk, and saving over a newer file asks
  (Overwrite / Revert / Cancel) instead of clobbering it.
- **Source Control** on git: changes and staged lists, stage/unstage/discard,
  commit (Ctrl+Enter), branch checkout/create, log, gutter bars from a Myers
  diff against HEAD, Open Changes as a coloured unified diff.
- **Run and Debug**: Run (Ctrl+F5) streams output and turns errors into
  Problems with locations. F5 records the program with `nython --trace` and
  replays it: breakpoints, continue, step over/into/out, **step back and
  reverse continue** (record-and-replay; after Lewis, "Debugging Backwards in
  Time", 2003), variables, watch, call stack, Debug Console, a timeline
  scrubber, the uncaught exception with its line.
- **Search** across open buffers and disk with case/word/regex, replace all.
  **Extensions** is the catalog of `lib/` modules (description, API, open,
  import). Terminal runs shell commands (with `cd`), `:cmd`, `>expr`, `@agent`.

### Defects found by driving it (all fixed, all with value-asserting tests)

Runtime, both engines unless noted — `examples/vm_audit45.ny`:
- **JSON** (`include/NyJson.hpp`, one codec for both): the interpreter wrote
  strings unescaped (`"say "hi""`) and decoded only flat objects (nested
  objects, arrays, escapes: wrong or `{}`); the VM decoded `\u00e9` as
  `u00e9`. The debugger's variable view depended on it.
- **`print("total", r)`** printed `('total', 6)` on the interpreter — the call
  form was parsed as a print statement of one tuple; the VM flattened *every*
  tuple (`print((1, 2))` → `1 2`) and mangled `sep=`. Now a real call form
  with `sep=`/`end=` on both.
- **Equality** (interpreter): nested lists were never equal (elements compared
  by printed form), **every two maps compared equal**, `[1, 2] != [1, 2]` was
  true. **`true == 1`** was false on the VM only.
- **`list.pop(i)`** ignored `i` on the VM (removed the last item);
  `insert(-1, x)` wrote a key named `"-1"` on the interpreter.
- **`map.clear()`** (interpreter) turned the map into an empty list; later
  `m[k] = v` was silently lost.
- **`--trace`** never recorded the uncaught exception (the file was closed by
  an RAII guard inside the `try` before the `catch` ran).
- **`launch_ide`** terminated on a syntax error in the IDE's sources; now
  reported with its location.
- Background jobs whose output ended in a newline **never finished**
  (`os_exec` strips trailing newlines, so a byte offset drifted); a command
  containing `exit N` killed the wrapper before its status was recorded.
- `gui.cpp`'s rounded-rectangle fill blended corners two or three times
  (dark blobs on any translucent rounded fill).

Memory — the interpreter never frees a string or container (§5.1), so what
repaint and keystrokes allocate is kept. Measured with `ide_memprobe.py`:

| | before | after |
|---|---|---|
| idle frame | 3.45 KB | 0 |
| hover event | 40 KB | 0 |
| keystroke | 787 KB | ~40 KB |
| scroll step (long file) | 161 KB | ~7 KB |

Causes, found with the new allocation profile: **every evaluation of a string
literal made a new permanent string** (now interned per AST node — benefits
every Nython program: a loop with two literals, 48 MB → 10 MB); every
one-character string (`line[i:i+1]`) likewise (now shared); **every method
call on a subclass made a permanent string** for `__parent_class__` (now
interned); autocomplete rebuilt and fuzzy-matched its whole candidate list in
Nython per key (now a session re-ranked by the native `fuzzy_rank`, which
also finds best alignments instead of first occurrences); the highlight cache
was cleared on every edit; the minimap rebuilt a list per line per edit; the
gutter built a `"path:line"` string per line per frame; view title actions
were list literals in paint methods.

IDE-level: menus could not be switched by hovering (a dismiss layer covered
the bar); a key the Quick Input did not handle fell through to the editor
underneath; palette "recently used" counted keybindings; `@dbg.var` rows
were dead clicks; breadcrumbs named the last `def` above the caret even at
top level; the search summary said "1 results in 1 files"; the toolchain ran
whatever `nython` was on PATH instead of the running binary.

### Numbers at the end of the round

```
tools/ide_e2e.py        227 passed, 0 failed (21 scenarios incl. two dead-click audits)
tools/ide_lint.py       0 unresolved
tools/ide_memprobe.py   within ceilings (idle 0, hover 0, typing ~40 KB/key, scroll ~7 KB)
tools/sweep.py --base   176 runs (88 files x 2 engines): 0 regressions against the round-72
                        binary, 8 runs newly passing; still failing: vm_audit23/25 on the
                        VM only (pre-existing, @property decorator, §5.9)
vm_audit42..45          73 / 52 / 46 / 45 passed, both engines
```

### Not done / known gaps

- The interpreter's collector is still unwired (§5.1). This round removed
  the avoidable garbage; ~40 KB per keystroke remains (undo records, the new
  line's tokens, status text) and is kept for the session.
- The VM has no tuple type (`print((1, 2))` shows `[1, 2]` there).
- No split editors, no settings UI beyond the `.nyide` file, no extension
  installation (Extensions lists and imports `lib/` modules), no real language
  server (symbols, go-to-definition and references are text-based).
- The debugger replays a recording: it cannot change a variable's value and
  continue, and a program that needs interactive input cannot be recorded.
- Two pre-existing VM failures remain (`vm_audit23`/`25`, `@property` as a
  decorator — §5.9).

---

## 0. Round 70 — a fresh container, no stub, and a real content-level sweep

This round started from a **container with no SDL3 and no stub** — the stub
built in round-68-era sessions lived under `/home/claude/work/stub/`, outside
the repo, and was gone. Nothing built until one was written from scratch; see
`thirdparty/sdl3-stub/` and the updated `Makefile` (`NYTHON_SDL_STUB=1|0|auto`,
auto-detects and falls back to the stub when no real SDL3 is found). The stub
mirrors the interface `src/builtins/gui.cpp` actually calls, headless, with the
same `NY_STUB_AUTOQUIT` / `NY_STUB_DPI_SCALE` contract this file already
documented. `make cli` and `make` both need nothing else in a clean container.

With a working build, this round also did what §3 always recommended and
earlier rounds mostly didn't: ran every `examples/*.ny`, `examples/gui_tests/*.ny`
and `tests/*.ny` file on **both engines** and grepped the *output*, not just the
exit code, for `N failed` (a file can print "3 failed" and still exit 0 if its
own `check()` helper doesn't call `exit`). That surfaced real bugs the
exit-code-only sweep had never seen, alongside a large pile of **pre-existing**
content-level failures in old version-numbered example files (`v3_..v16_*`,
`arith_test`, `oop_test`, `stdlib_test`, `enhance_test`, `ultimate_test`, …)
that were never part of any documented pass-count claim — those are catalogued
in §5.8 rather than fixed, since chasing ~50 undocumented pre-existing
assertions is its own dedicated project.

Fixed, both engines unless noted (see git log for the individual commits):
- **EOF errors losing their location (§5.6, closed)**: `Lexer::next()`/`curr()`
  returned a bare `Token()` — default `Location{1,1,"stdin"}` — once the parser
  read past the last real token. Now they return the last valid token (the
  lexer's own `End` token, which already carried the right position).
- **`id()`/`hash()` as global functions**: registered as recognised builtin
  names but never actually dispatched anywhere — interpreter fell through
  every `dispatch_*` module to `UNDEFINED`; the VM's `id()` read only
  `a[0].list`, so anything but a `LIST` (an instance, a map, a string, a
  number…) always came back `0`. This is almost certainly what §5.2's "known
  defect: `id()` returns 0" was actually seeing — the *method* form
  `obj.id()` (objectProtocol) already worked.
- **Interpreter silently swallowing exceptions raised inside `__init__`**: the
  three call sites that invoke a class's `__init__` had `catch (...) {}` after
  the `ReturnSignal` catch, discarding *any* exception — NameError, a raised
  user exception, anything — instead of only swallowing the early-`return`
  signal every other call site treats specially. A constructor that hit a real
  error silently produced a half-built instance and kept going. This is what
  finally exposed the next two bugs, both of which were being hidden by it.
- **`examples/nython_ide.ny` (the *unshipped* v3 demo — see `IDE_FILES.md`,
  this is not the same file `--ide` launches) had three real, independent
  bugs**, previously invisible because of the swallow above:
  `Icons()` was called without importing the file that defines it
  (`../ide_icons.ny`, added); `LangWorkshopPanel` was defined ~900 lines
  *after* the class that instantiates it (moved earlier, same fix already
  applied to the shipped IDE per this file's own "IDE Launch Fix" section);
  and DPI-scaling ran on layout constants (`self.TOOLBAR_H` etc.) before their
  base values were ever assigned, reading `none` and poisoning every metric
  derived from it downstream, down to `float(none)`.
- **`json_decode`'s hand-rolled parser could crash the whole process**:
  `std::stod`/`std::stol` on a malformed numeric field were unguarded, so a
  parse failure threw an uncaught C++ exception straight past every Nython
  `try`/`except`, landing in `main.cpp`'s outermost handler as an unhelpful
  `error: stol`. Now falls back to `0` for that one field, matching the
  top-level-primitive parse a few lines above it (and matching the VM's own
  `json_decode`, which already never crashed here).
- **`EditorTab`'s `.ny` file icon was `"?"` instead of `"◈"`**: `tests/test_gui.ny`
  already asserted `"◈"`; `lib/gui.ny`'s `_ext_icon()` still set `"?"`, and the
  duplicate `examples/test_gui.ny` still asserted the stale `"?"` to match.
  `tests/test_gui.ny` was quietly at 1052/1053 because of it.
- **`import nytorch_classes` was a no-op on the VM**: the comment claiming
  "the functions are already registered as globals" was true of the native
  `tensor_*` ops but not of the Nython-level class library (`Tensor` and
  everything built on it) — `Tensor(...)` read as an undefined name. Wired it
  to actually load `lib/nytorch.ny`, the same file the interpreter's handler
  loads. The concern that blocked this before (loading 220+ classes is
  OOM-risky — see `CLAUDE.md`'s IDE-import-weight note) is specific to the
  interpreter's unreclaimed containers (§5.1); the VM's `shared_ptr`-backed
  containers don't have that problem. `examples/nytorch_v2_demo.ny` now runs
  to completion on the VM (previously: `NameError: 'Tensor' is not defined`).
- **VM compound assignment**: `aug_op()` mapped `+= -= *= /= %=` to opcodes and
  silently NOP'd everything else. `x //= 5` compiled to "load x, load 5, NOP,
  store" — the NOP left `5` on the stack to be stored, so `x` became the
  divisor, not the quotient. Added `//= **= &= |= ^= <<= >>=`.
- **VM `isinstance(x, list)`** (the bare builtin, not a string): only a
  `CLASS` or `STRING` second argument was recognised, so this always read
  `false`. The type-constructor builtins (`int`/`float`/`bool`/`str`/`list`/
  `tuple`/`dict`/`set`) are now tagged with the type name they build, and
  `isinstance` accepts that tag. This is what was silently breaking every
  `isinstance(item, list)`-based recursive flatten in the VM audits.
- **VM `case _:`**: compiled as an ordinary `subject == <value of _>`
  comparison — `_` read as an undefined variable, so the wildcard/default arm
  of a `match` never ran. The interpreter's `evalSwitch` already special-cases
  a case value of exactly `"_"`; the VM compiler now does too.
- **VM `list.min()`/`.max()`/`.sum()`** (method-call form): only the global
  `min(list)`/`max(list)`/`sum(list)` form was implemented; the method form
  fell through `call_list_method` and read `none`. Delegated to the existing
  globals.
- **VM `clamp()` vs `tensor_clip()`**: aliased to the same native, which is
  list-only (clips every element of a list). `clamp(-5, 0, 10)` — the scalar
  form the interpreter has always had — hit `tensor_clip`'s "must be a list"
  guard and returned `[]`. Split them; `clamp` is now the scalar builtin,
  `tensor_clip` keeps the list behaviour under its own name.
- **VM object protocol** (§5.2, closed): ported `class_name`/`type_name`/
  `to_string`/`id`/`hash`/`is_a`/`instance_of`/`equals_to`/`fields` to
  `vm_call_method`, mirroring the interpreter's `objectProtocol`. This is
  exactly the interface `test_25_object_protocol.ny` probes for and used to
  skip on the VM.
- **VM typed `except` and `try`/`else`** (§5.9, closed): `ExceptionEntry` held
  one handler total, so only the *first* `except` clause's body was even
  compiled — every clause after it was dead code, and which one ran had
  nothing to do with the raised exception's type. Rewrote it to hold one
  `{type_name, bind_var, handler}` per clause plus an `else_handler`, with a
  new `match_except_handler()` doing the type walk at runtime (mirroring the
  interpreter's `evalTry`). `vm_audit24` now passes 49/49. See §5.9 for the
  two further bugs this closure surfaced — `int()` never raising and a
  genuine infinite loop it exposed in `with`'s exception handling — both also
  fixed, and why that combination is worth reading if you're touching VM
  exception handling again.
- **Stale test**: `vm_audit25`'s "neg modulo" still asserted the pre-fix
  C-style `-7 % 3 == -1`. `CLAUDE.md` documents this was deliberately changed
  to floor-modulo (`== 2`) rounds ago; the assertion was never updated to
  match. Fixed in both the `examples/` and `tests/` copies.

Net result — every suite in `CLAUDE.md`'s 24-suite table now matches its
documented count **on both engines**, except one item in §5.9 (`@property`
decorator syntax on the VM — pre-existing, real, not touched) and one item in
§5.4 that is a design decision, not a bug (`5.0` vs `5` for `10 / 2`).

---

## 0b. Round 71 — division ruling, dead operators wired up, new language constructs

This round had an explicit product decision from the project owner, resolving
the design question §5.4 had been carrying open since round 70: **`/` is
always true division** (returns float — `10 / 2 == 5.0`, matching Python);
**`//` and `\` are floor division** (return int — `10 // 2 == 10 \ 2 == 5`).
The VM's `op_div()` used to special-case exact int/int division and return an
int for `/`, contradicting the interpreter and this ruling — fixed to always
return float for `/`. `examples/arith_test.ny`'s stale assertions were
updated to match.

The rest of the round worked through operators and keywords that exist as
real tokens (`IToken.hpp`) and are documented in `CLAUDE.md`'s grammar notes
but were dead at the parser, the compiler, or both — "there are many
operators to use that are not even used." Fixed, both engines, verified with
`examples/vm_audit35.ny` (new — diffs interpreter vs VM output line for
line) plus the full exit-code and content-level sweeps:

- **`\` (RevDiv) was completely unreachable**: the lexer's backslash
  handling had inverted logic that only ever produced escape/line-
  continuation tokens, never a `RevDiv` token, regardless of context.
  Restructured to check for line-continuation (backslash immediately before
  a newline) first, and emit `RevDiv` otherwise.
- **`instanceof`**: unimplemented on the interpreter (silently evaluated to
  `none`), and a stack-leaking NOP on the VM (left both operands on the
  stack, corrupting everything compiled after it). Now a true alias for
  `is` on both engines, including the VM's compile-time type-name special
  case (`COMPARE_IS_TYPE`) that `is` already had — needed separately, since
  aliasing the runtime opcode alone wasn't enough for `x instanceof SomeType`
  to resolve `SomeType` as a type name rather than a value comparison.
- **`===` / `!==` (strict equality) and `xor` / `^^`**: same stack-
  corrupting NOP pattern on the VM. Added dedicated `COMPARE_SEQ` /
  `COMPARE_SNE` / `LOGICAL_XOR` opcodes; the interpreter already handled
  these correctly.
- **`>>>=`**: silently degraded to a plain assignment (`x >>>= 2` set `x` to
  `2`) on both engines. Now treated as equivalent to `>>=` — Nython's
  integers are arbitrary-width, so there is no fixed-width sign bit to make
  "unsigned" vs "arithmetic" shift meaningfully different; documented as a
  judgment call, not a distinct semantic.
- **`~=`**: not parseable at all (`isAugAssign()` didn't recognise
  `ComplementAssign`). Added, and implemented as `x = ~y` (bitwise-complement
  the right-hand value and assign — the left operand's old value plays no
  part, matching the "complement in place" reading of every other
  `~`-family use in the language). The VM needed a dedicated compile path
  since it doesn't fit the generic load/binary-op/store pattern every other
  compound assignment uses.
- **VM postfix `++` / `--`**: compiled to a no-op (`UNARY_POS`), so `i++`
  parsed but did nothing. Now emits a load/dup/add-or-subtract-1/store
  sequence matching the interpreter's post-increment semantics (evaluates
  to the *old* value, writes back the new one).
- **`enum` / `namespace` / `interface`**: the VM compiler silently dropped
  these entire subtrees — unmatched `visit()` cases fell to a `default:`
  that emitted nothing. All three now compile for real (enum → a map of
  member name to ordinal-or-explicit-value; namespace → a map of the
  block's top-level declarations, bound under the namespace's own name;
  interface → compiled identically to a class, so `implements`/`is` see it
  as a real type in the inheritance chain). Confirmed `package` is
  correctly a no-op on both engines already (matches `PackageNode::eval()`
  on the interpreter — nothing to fix there).
- **Interpreter `namespace` never bound its own name**: `ns.member` always
  read `none ` because `evalNamespace()` evaluated the body and threw the
  result away. Now builds a member map from the namespace's top-level
  var/function/class declarations and binds it under the namespace's name,
  same shape as the VM's new namespace compilation above.
- **Interpreter `interface` was an explicit no-op**: `case
  NodeType::INTERFACE: return NONE_VALUE;` bypassed `InterfaceNode`'s own
  (already-working) `eval()` entirely. Routed through a new
  `evalInterfaceDecl()`, registered exactly like a class, so `implements`
  plus `is`/`isinstance` chain-walking actually sees interface types.
- **`new` had no parser production**: `new A()` and `new A` both silently
  discarded the `new` token and whatever followed enough to keep parsing,
  with no distinct behaviour from bare `A()`/`A`. Added a dedicated rule in
  `unary()` that gives all four forms their own, distinct meaning: `A` is
  the class value itself; `A()` calls it with no `new`; `new A()` and
  `new A` both construct an instance (with and without explicit empty
  parens) — `new` and bare-call construction are equivalent for a
  zero-arg constructor, which is the existing convention every other
  callable in the language already follows.
- **`struct` was entirely missing** (no token, no grammar). Added as a new
  keyword that desugars at *parse time*: `struct Point: x, y=0` becomes a
  synthesized `class Point: def __init__(self, x, y=0): self.x=x; self.y=y`
  — no new evaluation code needed on either engine, since it reuses the
  existing class machinery entirely. The first implementation used a plain
  `VariableNode` for the generated body's `self` reference and passed on
  the interpreter but silently read `none` for every field on the VM —
  traced via `--disasm` to the VM compiling `self.x` through a distinct
  `SelfNode` → `LOAD_SELF` opcode, which a same-named ordinary variable
  node doesn't get (the VM has no bound local literally named `"self"` to
  fall back to). Fixed by generating a real `SelfNode`, not a
  `VariableNode`, for the synthesized body.
- **`module` was entirely missing**. Added as a pure lexer-level alias for
  `namespace` (same `TokenType::NameSpace`, a second literal spelling) —
  confirmed via grep that no existing file in the corpus uses `module` as a
  bare identifier, so there is no collision risk.
- **Hex/octal/binary integer literals evaluated to `0` on the VM**
  (`0xFF`, `0o17`, `0b1010`) — found incidentally while investigating sweep
  counts, not part of the operator/keyword work above, but the same class
  of "dead code path" bug. `NT::INTEGER` compilation called
  `std::stoll(token.value)` directly, which stops parsing at the `x`/`o`/`b`
  and returns `0` for the digits-only prefix. Added `parse_int_literal()`,
  mirroring the interpreter's existing correct prefix-detection logic, used
  at both `NT::INTEGER` compile sites (the literal itself, and default-value
  folding).

Net result: the design-decision half of §5.4 is now closed (see below); the
"many operators … not even used" and "interface, enum, struct, module,
namespace … packages" requests are substantially done — the remaining gap is
multiple inheritance / multiple `implements` beyond `bases[0]`, not tracked
by either engine, and `block:` not opening its own scope (still open, not
addressed this round).

---

## 0c. Round 72 — nytorch gets real autograd, and a genuine VM closure bug

`lib/nytorch/autograd.ny` is new: a `Variable` wrapper implementing actual
reverse-mode automatic differentiation — a dynamic computation graph built
as operations run, and `.backward()` walking it in reverse topological
order to accumulate `d(output)/d(x)` into `x.grad`. This is the mechanism
the word "autograd" in "PyTorch breadth: autograd... absent" (§5.5) refers
to, and nothing in nytorch's ~15,000 existing lines had it — every
optimizer in `optimizers.ny` (`AdamW`, `AdaGrad`, `RMSProp`, `NAdam`,
`Lion`) takes `grads` as an argument the *caller* must already have worked
out by hand. Scoped deliberately to scalars and 1D tensors (the same flat
representation `Tensor` in `activations.ny` already uses — real ND tensor
support doesn't exist, per §5.5, and this doesn't add it). `LinearVar` +
`mse_loss` + `SGDVar` are included as a minimal real layer/loss/optimizer
triple. Verified by `examples/vm_audit38.ny`: hand-derived gradients for
every op, a shared-Variable-used-twice case, vector dot/sum/mean, numerical
gradient checking via finite differences against a composed expression
(the strongest available check — a wrong derivative rule trains silently
in the wrong direction rather than crashing), and an end-to-end 50-step SGD
run whose loss collapses to exactly `0.0` on both engines.

Building it surfaced a real, previously-unknown **VM bug**: `vm_call_method`'s
path for "a callable stored in an instance attribute... then `self.cb(a,
b)`" — exactly the shape every `Variable` op uses (`out._backward_fn = _bw`,
called later as `node._backward_fn()`) — called `exec_code(held.code, args,
obj)` without passing `held.closure_env`, unlike every other call path in
the same file. A closure stored as an attribute and invoked via `obj.attr()`
therefore silently lost every variable it had captured (they read back as
`none`), while the *same* closure called through a plain local reference
(`f = obj.attr; f()`) worked correctly — confirmed with a minimal repro
before trusting the fix. The interpreter never had this bug. Fixed in
`VirtualMachine.hpp` by threading `held.closure_env` through.

Also found and fixed, same root cause, in the **already-shipped**
`activations.ny`: `Tensor.relu()`/`.sigmoid()`/`.gelu()`/`.silu()`/
`.swish()`/`.elu()`/`.softmax()` each call a bare global function of the
*same name* as the method itself (e.g. `def relu(self): return
tensor_apply(self.data, lambda v: relu(v))`). A bare call inside a method
resolves back to that method, not the builtin, on both engines — the
interpreter's own `RecursionError` message even names this exact gotcha
("check for unintended self-recursion, e.g. a method with the same name as
a builtin"). All seven methods were silently wrong (either a stack
overflow or `none` per element, depending on the call path) before this.
`Tensor.tanh()` had already dodged it by calling the builtin under its
other name, `tanh_fn`; the rest now get small differently-named helpers
(`_relu_bi`, `_sigmoid_bi`, …). `autograd.ny`'s own `exp`/`log`/`relu`/
`sigmoid` were written with the identical latent bug and fixed the same
way before being trusted. No existing test asserted the old (wrong) output
— the one file calling these methods directly, `test_nytorch3.ny`, is an
unassertive print-dump predating the `vm_audit` convention.

Verified: `rm -rf build && make cli && make`, headless `--ide` launch exits
0, full exit-code sweep (one known pre-existing failure) and full
content-level sweep (53 known pre-existing failures, all matching §5.8/
§5.9's already-documented debt — nothing new) on both engines.

**Same round, follow-up**: `LinearVar`/`mse_loss`/`SGDVar` alone only prove
the engine is *correct*, not that it can train anything a single linear
unit can't already fit. Added what a real hidden layer needs: `Variable.
select(i)` (pick one element out of a vector Variable) and its exact
inverse `stack_vars(list)` (combine independent scalar Variables into one
vector), since nytorch has no real 2D tensor to hold a weight matrix —
`LinearLayerVar(n_in, n_out)` is `n_out` independent `LinearVar` units
combined via `stack_vars` instead. `MLPVar(sizes)` stacks those with `relu`
between layers. `softmax_cross_entropy(logits, target)` is the standard
numerically-stable log-sum-exp formula built entirely from already-verified
ops (`sub`/`exp`/`sum`/`log`/`select`), not by differentiating through the
native `softmax`/`cross_entropy_loss` builtins (which return raw tensors,
no gradient at all). `AdamVar` is real bias-corrected Adam operating on
`Variable.grad` directly. `LinearVar`'s init now scales by `1/sqrt(n_in)`
(simplified Xavier/He) instead of a fixed range — a fixed-width init left a
multi-layer network badly conditioned as fan-in grew between layers,
caught when a first XOR attempt plateaued at a suspiciously round loss;
confirmed **not** a gradient bug first (numerical check: max
`|analytic − numeric|` ≈ 1e-12, i.e. machine precision, across all 12
parameters of a `[2,4,2]` network) before touching the init. `examples/
vm_audit39.ny` trains `MLPVar([2,6,2])` + `AdamVar` for 400 steps on the
XOR truth table — unsolvable by any single linear layer — collapsing loss
from 2.88 to 0.00046 and classifying all four rows correctly, byte-identical
on both engines (interpreter ~15s, VM ~28ms for the same 400 steps).

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
across `nytorch/` alone — see §5.10 for the full list and why it wasn't
fixed inline (`agent_learn.ny` just doesn't add to it: `AgentKnowledge`,
not `KnowledgeBase`).

**Round 72, final follow-up — real 2D matrix support.** `LinearLayerVar`/
`MLPVar` above proved multi-layer autograd works, but as `n_out`
independent scalar `LinearVar` units combined with `stack_vars` — a
workaround, not a real weight matrix, because nytorch has no native ND
tensor type. `Variable` gained optional `rows`/`cols` shape metadata over
the same flat `.data` list (0 means "not a matrix" — every existing
scalar/1D use is unaffected), and `matmul`/`add_bias_row`/`select_row` are
real batched matrix operations with hand-verified backward rules (`dA = dC
@ B^T`, `dB = A^T @ dC` for matmul; column-sum for the broadcast bias
gradient). `LinearMatVar`/`MLPMatVar`/`batch_var` are the real-matrix
counterparts to `LinearLayerVar`/`MLPVar`. This is a **pure Nython,
script-level** extension, deliberately not a native `src/builtins/
tensor.cpp` change — that native representation is depended on by ~15,000
existing nytorch lines, so the script-level route gets real batched-matmul
layers without that risk (at the cost of native-loop speed: matmul here is
three nested Nython loops, fine for the small demos in this file, not
production-scale). Verified with `examples/vm_audit41.ny`: matmul/
add_bias_row/select_row individually numerical-gradient-checked, then a
full `LinearMatVar`+`MLPMatVar` batched forward pass checked the same way
(max diff ~1e-13). Along the way, the first version of that check used
XOR's literal `(0,0)` point and found a real 0.16 discrepancy — traced
(not a gradient bug) to `LinearMatVar`'s zero-initialized bias making
every hidden unit's pre-activation for that one input row land **exactly**
on relu's non-differentiable point at `x=0`; confirmed by printing the
pre-activations (`[0,0,0,0,0,0]` for that row) and by re-running the check
with inputs that avoid the exact zero vector, which alone brought the diff
to 1e-13 with no code change — the well-known "relu at exactly zero"
subgradient ambiguity, not a bug, and immaterial to training itself (one
measure-zero kink among 400 SGD steps). Finally, `MLPMatVar([2,6,2])` +
`AdamVar` trains on the real XOR table with the whole 4-sample batch going
through each layer as **one** matmul call per step (not four separate
forward passes, unlike the `MLPVar` version above) — loss 2.94 → 0.00127,
all four rows correct, byte-identical on both engines.

---

## 1. Current state

```
356 examples    interpreter 1 failure, VM 0 failures (was: interpreter 1, VM 2)
tests/          0 failures
test_gui        1053 / 1053   (both engines; was 1052/1053, see §0)
test_ide_smoke  40 / 40
gui_tests       test_13 … test_27, all green on both engines
24-suite table  matches CLAUDE.md exactly on both engines, except §5.9
```

The one remaining interpreter failure is `examples/nytorch_v2_demo.ny`,
OOM-killed by the container leak (§5.1) — unchanged and not attempted this
round (see §5.1 for why: a mistake there is a use-after-free, not a test
failure, and needs its own ASan-verified change). The VM now runs this same
file **to completion** (§0) — it was the `nytorch_classes` no-op, not the
container leak, that was failing it before.

Round 71 (§0b) added `examples/vm_audit35.ny` and re-ran the full exit-code
and content-level sweeps afterward: still exactly the one known failure
above, nothing new.

---

## 2. Build and test

SDL3 is **not** available in most dev containers and is not in the Ubuntu
24.04 repositories. A headless stub, committed in this repo since round 70,
stands in for it — no external setup needed:

```
thirdparty/sdl3-stub/include/    SDL3 / SDL3_ttf / SDL3_image headers (headless)
thirdparty/sdl3-stub/src/        sdl3_stub.cpp — the implementation
Makefile                         auto-detects: uses the stub unless a real
                                  SDL3 is found (sdl3-config/pkg-config or the
                                  usual header paths). Force with
                                  NYTHON_SDL_STUB=1 (stub) or =0 (real SDL3,
                                  fails loudly if not actually present).
```

```bash
make clean && make cli    # ~2-3 min, build/nython-cli (REPL by default)
make                       # ~2-3 min, build/nython (IDE by default)
cp build/nython-cli ./ny_test   # lib/ide_toolchain.ny's Toolchain looks for
                                 # ./nython, ./ny_test, ./build/nython in that
                                 # order — gui_tests/test_14 and test_16 (real
                                 # compile/run/profile via popen) need one of
                                 # these to exist, or they report a toolchain
                                 # as "unavailable" and fail for an
                                 # environment reason that has nothing to do
                                 # with the change you're testing.
```

**Header changes need a full rebuild, not an incremental one.** The Makefile
has no header-dependency tracking, so `make cli` after editing
`VirtualMachine.hpp` or `NythonExecutor.hpp` silently relinks the *old*
object files for every `.cpp` that wasn't itself touched. `rm -rf build &&
make cli` before trusting a test run against a header-only change — this cost
real time this round (a fix "worked", the object file just hadn't rebuilt).

**Interrupted builds leave a truncated object set** and fail to link with a
misleading `undefined reference to main`. Do not trust that message — check
`build/cli/` (or `build/ide/`) for missing `.o` files against `src/*.cpp
src/builtins/*.cpp` first; compile the missing ones and relink rather than
assuming a full rebuild is required.

### Stub environment variables

| Variable | Effect |
|---|---|
| `NY_STUB_AUTOQUIT=<n>` | Synthesises one `SDL_EVENT_QUIT` after *n* empty polls, so GUI/IDE event loops terminate headlessly. Use ~120 for sweeps. |
| `NY_STUB_DPI_SCALE=<f>` | Fakes a display scaled *f* times. The script command `scale F` changes it at run time (§0n). |
| `NY_STUB_DPI_MODE=points\|pixels` | Which SDL3 HiDPI model the fake display follows: macOS/Wayland (default) or Windows/X11 (§0n). |

The quit is **latched** — delivered once. An unlatched version made an
application's `while (SDL_PollEvent(&e))` drain loop never terminate and drove
the IDE to 3.8 GB. If you touch the stub, keep the latch.

### Sweep

Exit-code only — catches crashes and timeouts, not wrong answers:

```bash
for x in examples/*.ny examples/gui_tests/*.ny tests/*.ny; do
  NY_STUB_AUTOQUIT=150 timeout 90 ./ny_test "$x" </dev/null >/dev/null 2>&1 || echo "I $x"
  NY_STUB_AUTOQUIT=150 timeout 90 ./ny_test --vm "$x" </dev/null >/dev/null 2>&1 || echo "V $x"
done
```

**Also grep the output**, not just the exit code (§3, and see §0/§5.8 for what
this caught that the loop above didn't): most of this repo's own test files
use a `check(name, got, want)` helper that prints `"N failed"` and keeps
going rather than exiting non-zero, so a file with real failures still shows
up as a pass above.

```bash
for x in examples/*.ny examples/gui_tests/*.ny tests/*.ny; do
  out=$(NY_STUB_AUTOQUIT=150 timeout 90 ./ny_test "$x" </dev/null 2>&1)
  n=$(echo "$out" | grep -oE '[0-9]+ failed' | grep -oE '^[0-9]+' | head -1)
  [ -n "$n" ] && [ "$n" != "0" ] && echo "I $x -> $n failed"
  out=$(NY_STUB_AUTOQUIT=150 timeout 90 ./ny_test --vm "$x" </dev/null 2>&1)
  n=$(echo "$out" | grep -oE '[0-9]+ failed' | grep -oE '^[0-9]+' | head -1)
  [ -n "$n" ] && [ "$n" != "0" ] && echo "V $x -> $n failed"
done
```

---

## 3. How to verify a change (this matters more than it sounds)

**Compare output, not exit codes.** For 38 rounds the suite was measured by exit
status, which only catches crashes; a program that prints a wrong number exits 0
and passes. Most bugs found since came from diffing the two engines' stdout.

**Compare divergence *sets*, not counts.** A build of the original tree lives at
`/tmp/obuild/nython_orig` (rebuild it from `/home/claude/work/nython/src_tree`
if lost). Comparing which *files* diverge, rather than how many, is what caught a
regression that was hidden behind two simultaneous fixes.

**Change both engines in the same commit.** Adding a diagnostic or a feature to
one engine has repeatedly created a divergence — the interpreter and the VM must
agree on what is an error. This happened with `NameError`, with `ImportError`,
and with the object protocol (§5).

**When a new test fails against old code, suspect the test.** Four times a
failing assertion was the test's fault: a recording double missing
`fill_polygon`, then missing `draw_text`; a column arithmetic slip; a hover check
comparing draw *counts* when the styling changed. Check which side is wrong
before changing either.

---

## 4. Traps that have cost real time

**Two IDE implementations.** `nython_ide.ny` at the repository root and its
chain (`ide_core.ny` → `ide_ops.ny` → `ide_paint.ny` → `ide_views.ny`) is what
`--ide` launches. `examples/nython_ide.ny` (v3) is a demo and is **not**
shipped. Six rounds of work went into the wrong one. See `IDE_FILES.md`.

**The shipped IDE's look does not come from `lib/gui.ny`.** Colours are
`IDETheme` in `ide_paint.ny` (VS Code Dark+/Light+ tokens) and icons are
`ide_icons.ny`; `lib/gui.ny` supplies only Window/Renderer/Font. A palette
written into `lib/gui.ny` was invisible for eighteen rounds for this reason.

**Before round 75 Nython returned `none` for a missing member.** A typo'd
method name or an attribute never assigned just evaluated to `none` and the
IDE carried on, drawing at y=0 or doing nothing on a click. Since §0m such
a read raises AttributeError (KeyError for a dict key) - but only when the
line runs, so an untested path can still hide one. Run
`python3 tools/ide_lint.py` after any IDE change.

**Anything allocated while painting is kept forever** on the interpreter
(§5.1): a list literal in a paint method is a new permanent list per frame.
Measure with `python3 tools/ide_memprobe.py`; find the allocator with
`NY_PROFILE_OUT=/tmp/p.csv NY_PROFILE_SORT=alloc ./build/nython --ide`.

**Dead code that looks live.** Two fixes landed in code that never executes and
were reported as working:
- `src/Value.cpp` has a complete set of arithmetic operators — **dead**. The live
  path is in `NythonExecutor.hpp`.
- `evalImport` builds a candidate list named `paths` — **dead**. The resolver
  reads `search_paths`.
- The `NT::SLICE` case in the VM compiler is **dead for subscripts**; the parser
  emits `.slice(...)` method calls.

Verify a fix by running it, not by reading it.

**Grep for behaviour, not names.** Selection was declared "absent" because the
grep looked for `sel_start`/`selections`; the feature exists as
`sel_on`/`sel_row`/`sel_col`. A universal object protocol was built to fill a gap
that was partly already filled.

---

## 5. Outstanding work, in priority order

### 5.1 Container leak — CLOSED (round 75, §0k)
Reference counting and a cycle collector on both engines; `GC_NOTES.md` is
now the design note. What follows is the round-51 diagnosis, kept for
history.

Full diagnosis in **`GC_NOTES.md`**. Summary: identical program, 200k container
literals — interpreter 494 MB, VM 7 MB. The VM uses `shared_ptr` and is fine.
The interpreter's collector is *correct code wired to nothing*: 24 raw
`new Object(...)` sites and zero `gc->allocate()` calls; `mark_persistent()` is
never called so the shadow stack is always empty; `do_collect()` is unreachable
from `NythonExecutor`.

Three routes are given, in preference order. A mistake here is a use-after-free,
not a leak, and the 356-example suite would very likely still pass — so this
needs an ASan build and allocation counters as part of the change.

`MEMORY_NOTES.md` covers how to write Nython that avoids generating the garbage
(`append` over `x = x + [y]`: 860× faster, 2400× less memory at 4,000 elements;
operation logs over state snapshots: 373 MB → 56 MB for 400 edits).

### 5.2 Object protocol is interpreter-only — CLOSED (round 70)
`objectProtocol()` in `NythonExecutor.hpp` gives every instance `class_name`,
`to_string`, `id`, `hash`, `is_a`, `fields` and aliases. Ported the same
interface to the VM's `vm_call_method` (`class_name`/`type_name`/`to_string`/
`id`/`hash`/`is_a`/`instance_of`/`equals_to`/`fields`) — `test_25` no longer
skips on the VM. The previously-noted `id() == 0` defect turned out to be a
different bug (see §0: `id`/`hash` were never dispatched as *global*
functions on either engine — only the *method* form `obj.id()` worked, which
is what this section's `objectProtocol()` already covered).

### 5.3 Built but not adopted by the shipped IDE

*(Round 73: the "not verified — no keyboard injection" caveats below are
obsolete. The stub now takes scripted input and `tools/ide_e2e.py` drives the
terminal, undo, multi-cursor and everything else through real events; a
multi-caret edit is now one undo step. See §0d.)*

**`lib/ide_commands.ny` — CLOSED (round 71b)**: the `:cmd` / `>expr` /
`@agent` terminal command line (paired with `lib/ide_toolchain.ny`'s real
compile/run bridge) is now wired into `nython_ide.ny`'s terminal panel —
`NythonIDE.__init__` constructs a `Toolchain` + `CommandLine`, and
`_term_run`/`_term_dispatch`/`_term_agent`/`_term_profile` execute the
action the command line names. `:run` `:vm` `:tokens` `:ast` `:disasm`
`:build` reuse the existing `_build_run()` pipeline; `:save` `:open <f>`
`:goto <n>` `:find <t>` `:panel <name>` `:theme` `:quit` reuse existing IDE
methods; `:profile` is new — the IDE had no way to reach the profiler at
all before this. `@explain`/`@fix` are backed by `lib/aiagent.ny`'s
pattern-based `CodeAnalyzer` (the same one "Analyse Buffer" already used);
`@ask`/`@test`/`@doc`/`@review` say plainly they are not wired to a live
model rather than fabricating output. Command history (up/down) and
tab-completion also wired. Verified: `make` builds clean, headless
`--ide` launch exits 0 (constructor succeeds), the module's own dedicated
test (`gui_tests/test_27_widgets_cmdline.ny`) still passes 36/36 on both
engines. **Not verified**: the headless SDL3 stub has no synthetic
keyboard/text-input injection, so the new terminal code paths could not be
exercised through a real keydown/textinput sequence in this environment —
only through static review and the construction smoke test above.

**`lib/gui_piecetable.ny` — CLOSED differently than planned (round 71c)**:
adopting `PieceTable` itself as `EditorBuffer`'s storage was assessed and
rejected — it is offset-addressed, `EditorBuffer` is a line-list read
directly (`buf.lines[i]`) at 13+ call sites across `nython_ide.ny`, and a
full swap would mean rewriting every one of those with no headless way to
keyboard-test the result. Instead, `EditorBuffer` (`ide_editor.ny`) learned
the same *technique* `PieceTable` demonstrates — record an inverse, pop-
apply-push between an undo and a redo stack (see `PieceTable.
_apply_inverse`) — applied to its existing line-list storage instead of a
new offset-addressed one. `insert_char`/`delete_char_back`/`insert_newline`
now record four scalars per edit instead of `nython_ide.ny` snapshotting
`buf.get_all_text()) before every keystroke (`self.undo_stack`, capped at 50
snapshots, removed); a new `push_snapshot()` covers the coarser edits that
still reach into `buf.lines` directly (comment toggle, cut/paste, move
line, find/replace-all — the last of these was not undoable at all before
this). This also made undo per-tab rather than one history shared across
every open file, fixing the old behaviour's occasional surprise of Ctrl+Z
switching tabs, and gave `_redo()` — a hardcoded `"Nothing to redo"` stub
before this — a real implementation (Ctrl+Y / Ctrl+Shift+Z, "Redo" menu
item). Verified with `examples/vm_audit36.ny` (new, 53/53 both engines —
`EditorBuffer` is a plain class and directly testable without a window).

**`lib/ide_selection.ny` — CLOSED (round 71c)**: adopted for real
multi-cursor editing, additively — the existing single-selection code
(`sel_on`/`sel_row`/`sel_col`, `_sel_begin`/`_sel_range`/`_sel_delete`,
`_draw_selection`) is untouched, since it already correctly handles
shift-arrow, click-drag, word-select and cut/copy/paste over a selection,
and `SelectionModel` has nothing better to offer there. What's new: `self.
selmodel = SelectionModel()` holds *extra* carets beyond the primary.
Alt+Click adds one; Ctrl+Alt+Down/Up add one below/above the last-added
caret (plain Alt+Up/Down already means "move this line" here, hence
requiring Ctrl too); Escape or a plain click collapses back to one caret.
Typing/Backspace/Enter apply to the primary as before, then replay onto
every extra caret (`_apply_to_extra_carets`, processed last-caret-to-first
so an earlier edit never invalidates a not-yet-processed caret's saved
position; bounds-checked against the current buffer so a caret left over
from a shorter/closed file can't index past the end and crash the IDE).
Verified with `examples/vm_audit37.ny` (new, 10/10 both engines) —
replicates the exact sort-then-apply algorithm against `EditorBuffer` +
`SelectionModel` directly, including the case where two carets share one
line (where processing order actually matters) and a backspace-at-three-
carets case. **Known limitations, not solved this round**: a multi-caret
edit is not one undo step (each caret's edit records its own entry, so one
undo only reverts the last caret processed); arrow-key navigation moves
only the primary caret, extras stay put until the next edit or click;
`nython_ide.ny`'s own new glue code could not be exercised through real
mouse/keyboard events, same headless-stub limitation noted above.

Still tested, working, and unused by `nython_ide.ny`:

| Module | What it provides | Notes |
|---|---|---|
| `lib/nyimgui.ny` | **Partially adopted.** `chips`/`tabs` are used (mode switcher, panel tabs). `slider`/`scrollbar`/`panel`/`toolbar_sep`/`checkbox`/`button`/`tree_node`/`icon_rail` are still unused — the IDE has its own hand-rolled scrollbars/sliders already working; per the note below, swapping them is not a clear win. |
| `lib/gui_motion.ny` | **Partially adopted.** `Fuzzy` is used (command palette ranking, `self.fuzzy.rank(...)`). The `Flex` solver and easing curves beyond pane-open/close animation are unused. |

Note: `CursorManager`, `Splitter`, `ScrollArea` and `FocusManager` in
`lib/gui.ny` are **deliberately** unused — v4 has its own working equivalents,
and replacing them would be churn with regression risk and no visible gain.
The same reasoning is why `nyimgui.ny`'s `slider`/`scrollbar`/`panel` were
left alone this round rather than swapped in speculatively.

### 5.4 Remaining engine divergences — CLOSED (rounds 71-76)
Every item once listed here was checked again in round 76, on both engines:
- `L is L` on a list is true on both (the VM keeps list identity).
- `print is function` is true on both (and `isinstance(print, "function")`).
- `/` is true division and `//` / `\` floor division on both (round 71, §0b).
- Dicts keep insertion order with typed keys, and tuples are real, on both
  (round 74, §0i); `undefined` is a value distinct from none (round 75,
  §0m); out-of-range indexing raises IndexError on both, with Python's words
  (`list index out of range`) since round 76.

### 5.5 Language gaps
- ~~`len()` counts characters but `s[i]` indexes bytes~~ — **CLOSED (round
  74)**: indexing, slicing and `len` all count UTF-8 characters.
- ~~`1.+(2, 3)` evaluates to `none`~~ — **CLOSED (round 74)**: operators are
  members of every value; it gives 6.
- PyTorch breadth: nytorch has one native tensor engine for both engines
  since round 74 (§0h: ND tensors, broadcasting, batched matmul, conv/pool/
  norm, autograd, Module/optimizers, checked against PyTorch numbers). GPU
  dispatch is still absent - no GPU in any environment this was developed
  in, so nothing to verify against - and `torch.nn` beyond the layers,
  losses and optimizers listed in §0h is thin.

### 5.6 End-of-input errors lose their location — CLOSED (round 70)

Located diagnostics worked mid-file but an error at **end of input** used to
fall back to `stdin:1:1`, because `Lexer::next()`/`curr()` returned a
default-constructed `Token()` once the parser read past the last real token,
discarding the position the lexer's own `End` token already carried. Fixed by
returning that `End` token (or the first token, for underflow) instead of a
positionless default. `/tmp/eof.ny` with an unclosed paren now reports
`/tmp/eof.ny:3:1: ...` — the real end-of-file position — instead of
`stdin:1:1`.

### 5.7 IDE visual work — addressed in round 73 (§0d)
The layout follows VS Code (title-bar menus and command centre, activity bar,
side bar, editor group, panel, status bar); every status-bar segment opens its
picker. **Visual work needs a screenshot** — and one can now be taken
headlessly: `ide.screenshot("x.png")` in `tools/ide_driver.py`, or
`python3 tools/nyshot.py frame.dl out.png` on a capture.

### 5.8 Content-level failures in old version-numbered example files — CLOSED (round 75, §0n)

Every `examples/*_test.ny` is in `tools/sweep.py` now and passes on both
engines; what follows is the round-70 record.

(Round 75: the suffix-literal checks in `v3`/`v4`/`v5`/`v9` - `1k` expected
to be `1000`, not `1000.0` - pass now that a whole suffix literal is an int;
§0m.)

Round 70's content-level sweep (§0/§2) found real `N failed` output — not
crashes, not caught by any exit-code sweep — in about three dozen files:
`arith_test.ny`, `enhance_test.ny`, `features_test.ny`, `features_v2_test.ny`,
`oop_test.ny`, `oop_v2_test.ny`, `stdlib_test.ny`, `stdlib_v2_test.ny`,
`ultimate_test.ny`, `v3_comprehensive_test.ny` through `v16_final_test.ny`, and
`test_webserver.ny` (both engines; the last one is plausibly a sandboxed-socket
environment issue rather than a language bug — not investigated).

These are **not** part of any documented pass-count claim — `CLAUDE.md`'s
24-suite table and this file's own historical "N examples: M failures" figure
were always exit-code-only, and these files predate the `vm_audit*` /
`check()`-with-real-assertions convention. Whether each failure is a real
bug, an intentional-but-undocumented divergence, or a stale expectation (the
`vm_audit25` "neg modulo" case in §0 was the third kind) needs the same
per-file "reproduce, trace, decide" treatment as everything else in this
file — it just hasn't been given it yet. Left alone this round rather than
fixed blind, given the volume (~50 individual assertions across ~35 files)
and the risk of a wrong fix in a file nobody has looked at closely before.

### 5.9 VM/interpreter divergences found in round 70 — CLOSED
Typed `except`, `try`/`else` and `int()` raising were fixed on the VM in
round 70 (FIXES_v0.2.1.md has the account, including the `with`-block
handler that looped once `int()` raised). The last item, `@property` as a
decorator on the VM, was closed in round 74 (§0j): VM class bodies run as
statements, so properties with setters, static and class methods and every
decorator work.

### 5.10 nytorch class-name collisions across submodules — CLOSED (round 74, §0h)

Every duplicate top-level class name under `lib/` is gone, and
`tools/ny_classcheck.py` exits 1 on any new one; `vm_audit47` runs it. Round 74's
merges briefly reintroduced three (`Queue`, `PriorityQueue`, `Timer` in both
`lib/stdlib.ny` and `lib/thread.ny`); `stdlib.ny` now imports `thread.ny`'s
thread-safe versions, which answer both APIs. The original finding follows.

Nython has no per-module namespacing for `import "path"` — every class a
submodule defines lands in one shared global namespace, and a later import
simply overwrites an earlier same-named class binding, silently. Building
`lib/nytorch/agent_learn.ny` needed a persistent key/value store and reached
for the obvious name, `KnowledgeBase` — already used elsewhere in nytorch —
and it silently failed: `remember()`/`recall()` both returned `none`
unconditionally. Traced to three **independently written, incompatible**
`class KnowledgeBase` definitions inside `nytorch/` itself (`compute.ny`,
`memory.ny`, `storage.ny` — a fourth, also incompatible, lives outside
nytorch in `lib/aiagent.ny`). `lib/nytorch.ny`'s aggregator imports
`memory.ny` after `storage.ny`, so `memory.ny`'s version — a completely
different shape (`store`/`retrieve`/`keys()`, no `remember`/`recall` at
all) — is the one actually bound by the time any caller uses the name.
Calling a method the active definition doesn't have returns `none` instead
of raising, which is what made this silent rather than an immediate crash.
Confirmed with a minimal reproduction (a class matching `storage.ny`'s
exact shape, defined in isolation, worked correctly) before writing
`agent_learn.ny`'s own store under a different name (`AgentKnowledge`)
rather than adding a fifth colliding definition.

A repo-wide scan for the same pattern (`grep -h "^class " lib/nytorch/*.ny`,
grouped by name) found **ten** colliding class names across `nytorch/`
alone:

```
KnowledgeBase (×3), ReplayBuffer, MambaBlock, GraphSAGE, GATLayer,
FederatedLearner, ExperimentTracker, DataAugmentor, DQNAgent, DDPMScheduler
(×2 each)
```

Not fixed here — resolving it properly means renaming to disambiguate (or
adopting `import X as Y` namespacing throughout, which the language
already supports per CLAUDE.md's "Added" table) and auditing every internal
caller of each colliding name across 17 files to make sure the *intended*
definition is the one still reachable after the rename, which is real work
deserving its own dedicated, carefully-verified change — not something to
do incidentally while building something else. Left as a quantified,
reproducible finding rather than a guess.

---

## 6. Test files and what they pin

| File | Covers |
|---|---|
| `examples/vm_audit28`–`34.ny` | engine parity for language fixes |
| `examples/vm_audit35.ny` | division ruling, instanceof/===/!==/xor/>>>=/~=, postfix ++/--, enum/namespace/module/interface/struct/new, hex/oct/binary literals (round 71) |
| `examples/vm_audit36.ny` | `EditorBuffer` operation-based undo/redo (round 71c) |
| `examples/vm_audit37.ny` | multi-cursor typing algorithm, `EditorBuffer` + `SelectionModel` (round 71c) |
| `examples/vm_audit38.ny` | `lib/nytorch/autograd.ny` reverse-mode autodiff, hand-derived + numerical gradient checks, end-to-end SGD convergence (round 72) |
| `examples/vm_audit39.ny` | `autograd.ny` multi-output layers (`select`/`stack_vars`/`LinearLayerVar`/`MLPVar`), `softmax_cross_entropy`, `AdamVar`; MLP solves XOR (round 72) |
| `examples/vm_audit40.ny` | `lib/nytorch/agent_learn.ny`'s online-learning `CodingAgent` — real tokeniser, `AgentKnowledge` persistence, held-out perplexity improves after training on different code (round 72) |
| `examples/vm_audit41.ny` | `autograd.ny` real 2D matrix support — `matmul`/`add_bias_row`/`select_row`, `LinearMatVar`/`MLPMatVar` batched training solves XOR in one matmul per layer per step (round 72) |
| `examples/vm_audit42.ny` | IDE workbench model: `CommandRegistry` keys/chords/when-clauses, `HitMap`, `Frecency`, `QuickInput`, `LineEdit`, `Notifications`, `NavHistory` (round 73) |
| `examples/vm_audit43.ny` | `EditorBuffer` final-newline model, undo groups, tab-aware newline, in-place line edits, indentation detect/convert; `LineDiff`; `GitRepo` in a throwaway repository (round 73) |
| `examples/vm_audit44.ny` | `DebugSession` replay on a known recording and on a real `--trace` recording, including the uncaught exception (round 73) |
| `examples/vm_audit45.ny` | JSON codec, `print` call form, `list.pop(i)`/`insert`, deep equality, `true == 1`, `file_mtime` (round 73) |
| `examples/vm_audit46.ny` | the OS layer, 252 value checks: paths, files/dirs, file objects, typed errors, os_run/os_spawn, environment, time, full-width integers, sys.argv/`__name__`, lib/os.ny (round 74) |
| `examples/vm_audit56.ny` | lazy generators, both engines and python3: infinite generators, side-effect order, send/throw/close/finally, StopIteration.value, `yield from`, genexps, lazy builtins, unpacking, deep recursion, threads, finalization (round 75, §0l) |
| `examples/vm_audit57.ny` | strict reads (AttributeError/KeyError/TypeError), getattr/hasattr/setattr/delattr, get/setdefault/in, `?.`/`?[`/`?.()`/`??`/`??=` including laziness, `undefined`, the scope rules (plain assignment, var/let/const, global/nonlocal, loops, comprehensions, class bodies, methods, closures), suffix literals (round 75, 212 checks) |
| `examples/vm_audit90.ny` | lazy `range`, live dict views, lazy zip/map/filter/enumerate/reversed, both engines and python3 (round 78, §0q) |
| `tools/ide_e2e.py` | the shipped IDE driven through real input, 20 scenarios + dead-click audits (round 73) |
| `gui_tests/test_13` | Codicons, Dark+ palette, HiDPI scaling |
| `gui_tests/test_14` | toolchain — real compile/run/AST/disasm |
| `gui_tests/test_15` | cursor manager, value inspector, Unicode |
| `gui_tests/test_16` | profiler — measured, not estimated |
| `gui_tests/test_17` | easing, Flex solver, piece table |
| `gui_tests/test_18` | editor buffer, operation-based undo |
| `gui_tests/test_19` | splitter, scroll area, focus ring |
| `gui_tests/test_20` | shipped IDE theme + glyph rendering |
| `gui_tests/test_21` | selection model, fuzzy matching |
| `gui_tests/test_22` | immediate-mode core, ported tabs and chips |
| `gui_tests/test_23` | shipped editor selection (code lifted verbatim) |
| `gui_tests/test_24` | import system, all three forms |
| `gui_tests/test_25` | object protocol (skips on VM) |
| `gui_tests/test_26` | `is` / `is not` |
| `gui_tests/test_27` | ImGui widgets, IDE command line |

`FIXES_v0.2.1.md` is the full round-by-round log — every bug, why it happened,
and what was decided. It is long, but it is the record of *why* things are the
way they are.

---

## 7. Working agreement that produced the best results

1. Reproduce the defect first, minimally.
2. Trace it to a cause in the source before changing anything.
3. Fix both engines together.
4. Write a test that would have caught it — asserting **values**, not just
   termination.
5. Run the full sweep and compare divergence sets against the baseline.
6. Say plainly what was *not* done. A green suite that hides an unadopted module
   or a one-engine feature is worse than an honest gap.
