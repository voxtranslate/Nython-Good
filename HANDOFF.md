# HANDOFF.md — resuming this work in a new session

Read this first. `CLAUDE.md` describes the project as it was designed;
this file describes it **as it actually is**, including the traps.

Last updated: round 75 — **§0n** (real SDL3, HiDPI, every test in the
sweep) and **§0m** (strict attribute and key reads with optional chaining
and `??`, the scope ruling and `global`, suffix literals; both engines).
Round 74 is **§0e** (IDE responsiveness: native
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

- `const` is not enforced (a later assignment is allowed), and `var`/`let`
  have no block scope - both as before; not part of the rulings.
- `global x` covers reads, assignments, `+=`, unpacking and `for` targets;
  a walrus, `with ... as` or `except ... as` of a global-declared name still
  binds a local. `nonlocal x` with no enclosing `x` is not a SyntaxError (it
  rebinds a global or creates a local); `del x` unbinds the nearest `x`
  (Python would say UnboundLocalError for a global not declared).
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
- The interpreter still prints `print(a, b)`'s arguments one by one while
  evaluating them (the VM evaluates all first) - seen while testing, not
  touched.

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
- Windows fibers: tested standalone under Wine only (see above); the
  AArch64 switch is untested.
- The lazy builtins report `type()` "generator" and print as
  `<generator object zip at ...>`; Python has separate zip/map/... types.
- `send()` to a lazy builtin or generator expression behaves as `next()`
  (Python raises AttributeError for zip/map; a genexp ignores the value).
- A generator dropped by another thread than the one that started it is
  left suspended (only its own thread may run its finally blocks).
- Found on the way, not generator bugs, not fixed: on the interpreter a
  lambda that calls itself through the name it is assigned to
  (`f = lambda n: ... f(n - 1)`) raises NameError, and `print(a(), b())`
  prints each argument as soon as it is evaluated (`a`'s output, then
  `a()`'s value, then `b`'s output); the VM evaluates all arguments first,
  as Python does.
- The end-of-program close runs only when the program ends normally (not
  after an uncaught exception, where CPython would still finalize).
- Async still runs each task on an OS thread. The coroutines here would
  allow a single-threaded event loop (a task = a coroutine, `await` =
  suspend), which would make tasks cheap and remove the GIL hand-offs from
  async code; not attempted.

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
  - Interpreter memory is still high: the worst nytorch tests peak near
    1 GB, because the interpreter never frees containers (GC_NOTES).
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

### 5.1 Container leak — the last unambiguous defect
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

### 5.4 Remaining engine divergences
- `L is L` on a list: true on the interpreter, false on the VM. The VM appears to
  copy list values on load. Deeper than the `is` operator.
- `print is function`: the engines classify native builtins differently.
- ~~Integer `/`: `5.0` on the interpreter, `5` on the VM~~ — **CLOSED (round
  71)**: owner's ruling is `/` is always true division (float,
  `10 / 2 == 5.0`), `//` and `\` are floor division (int, `10 // 2 == 10 \
  2 == 5`). VM's `op_div()` no longer special-cases exact int/int division;
  `examples/arith_test.ny` updated to match. See §0b.
- Still undecided: dict/set iteration order, tuples (the VM has no tuple
  type), `undefined` vs `none`, out-of-range indexing (interpreter throws, VM
  returns `none`).

### 5.5 Language gaps
- `len()` counts **characters** but `s[i]` and `s[a:b]` index **bytes**. Both
  engines agree, so it is a semantics question. Making indexing character-based
  matches what `len()` implies but changes every string slice in the codebase.
- `1.+(2, 3)` parses (operators are legal member names) but evaluates to `none` —
  integers have no `+` member. Needs primitives boxed or dispatched to a root
  type.
- PyTorch breadth: GPU dispatch is absent (not attempted — no GPU hardware
  in any environment this has been developed in, so there is nothing to
  verify against), and most of `torch.nn` beyond activations/losses/a
  handful of layers is thin. Names match PyTorch where the capability
  exists (`L1Loss`, `SmoothL1Loss`, `LRScheduler`, `ExponentialLR`, …).
  ~~autograd absent~~ — **closed, round 72**: `lib/nytorch/autograd.ny`'s
  `Variable`/`.backward()` is a real reverse-mode automatic differentiation
  engine (dynamic graph + topological sort) — see §0c. ~~real ND tensors
  absent~~ — **closed differently than a native fix would, round 72**: real
  2D matrix support (`matmul`/`add_bias_row`/`select_row`, shape metadata
  on `Variable` over the same flat `.data`) was added as a pure Nython,
  script-level extension rather than a native `src/builtins/tensor.cpp`
  change — see §0c for why (the native representation is depended on by
  ~15,000 existing nytorch lines; the script-level route gets the same
  capability — real batched matmul-based layers — without that risk).
  Still genuinely thinner than PyTorch: no rank >2, no broadcasting beyond
  the one bias-row case, no native-speed matmul (it's three nested Nython
  loops, fine for the small demos here, not for anything performance-
  sensitive).

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

### 5.9 VM/interpreter divergences found this round

**Typed `except`, `try`/`else`, and `int()` raising — CLOSED (round 70, second pass).**
`ExceptionEntry` used to be `{try_start, try_end, handler, alias}` — one
handler total — so only the *first* `except` clause's body was even
compiled; every clause after it was dead code, and which one ran had nothing
to do with the raised exception's type (`vm_audit24`'s "typed except type":
raising `TypeError` was caught by the `except ValueError` clause). `try`/`else`
wasn't compiled at all and read `none`. Rewrote `ExceptionEntry` to hold one
`{type_name, bind_var, handler}` per clause plus an `else_handler`, and added
`match_except_handler()` to pick the right one at runtime — by type equality,
the generic `Exception`/`BaseException`/`Error` names, or a walk up the raised
type's parent chain via `class_reg_` — mirroring the interpreter's `evalTry`
(`NythonExecutor.hpp`), including its behaviour when *no* clause matches
(silently falls through to `finally` rather than re-raising). `vm_audit24` now
passes 49/49.

Fixing this exposed two more real bugs on the way to green, both worth noting
because of what they reveal about testing this codebase:
- **`int(s)` on the VM silently returned `0`** for anything `std::stoll`
  couldn't parse, instead of raising — `int("abc")` looked like a successful
  parse of `0`, not an error a `try`/`except` could catch. It also never
  supported the base argument or `0x`/`0b`/`0o` prefix auto-detection. Brought
  to parity with the interpreter's `int()` (`src/builtins/tensor.cpp`).
- **Fixing `int()` to actually raise surfaced an independent, older bug that
  was previously unreachable**: an uncaught exception raised anywhere after a
  completed `with` block, with nothing else to catch it, walked backward into
  that block's now-stale `SETUP_EXCEPT` handler instead of propagating — the
  backward scan for a `with`'s exception handler never checked whether that
  block had already exited normally via a matching `END_EXCEPT`. This re-ran
  the code after the `with` block, hit the same raise again, and **looped
  forever** (`examples/v10_final_test.ny` and `v11_complete_test.ny` hung on
  `--vm` for the first time only once `int()` started raising). Fixed by
  tracking `SETUP_EXCEPT`/`END_EXCEPT` nesting depth in the backward scan.
  This is exactly why §3's "run the full sweep before *and* after" matters: a
  fix that is locally correct (`int()` raising is right) can awaken a
  completely unrelated latent bug the moment something finally exercises the
  path it lives on. Verified with a full exit-code sweep (no hangs, no new
  crashes) and a full content-level sweep (no new `N failed` files) across
  every example/test file on both engines before committing.

**`@property`-decorated class methods still don't work on the VM.** Not
attempted — an architectural gap in a different part of the compiler, same
risk class as §5.1. `x = property(x)` written as an explicit call
(`self.x = property(getter)`) works fine — `get_attr` checks for a
`{__is_property__: ...}` map and calls `__get__`. But `@property` as
*decorator syntax* on a class method desugars at parse time to
`name = property(name)` as a synthesized assignment following the `def`
(`src/Parser.cpp`, the general decorator path) — and the VM's class compiler
(`visit_class`/`visit_func`) doesn't execute class bodies as a live sequence
of statements the way the interpreter does; it extracts `FUNCTION` nodes
straight into `sub_codes` and has no mechanism for a later statement to
retroactively mark one of them as a property. `obj.decorated_prop` returns the
raw `{__self__:..., __fn__:...}` bound-method map instead of calling it
(`vm_audit23`'s "property fahrenheit", `vm_audit25`'s "prop area"/"prop circ" —
these are now the *only* remaining failures in either file on either engine).
A real fix needs the compiler to recognize the `name = property(name)`
pattern immediately after a same-named method definition, at class-compile
time, and tag that `sub_codes` entry — touching class compilation and every
method-resolution path (`get_attr`, `set_attr`, `vm_call_method`).

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
