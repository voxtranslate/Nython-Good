# Memory management on both engines

Status: **fixed in round 75.** Both engines free what nothing refers to any
more (reference counting) and free groups of objects that only refer to each
other (a generational cycle collector). `__del__` runs, once. The history of
the leak this replaced is at the end.

## The model

CPython's, on both engines:

1. **Exact reference counting.** Every heap object has a count of the
   references to it; the object is destroyed the moment the count reaches
   zero. On the interpreter the count is an intrusive field
   (`Collectable::gc_rc`) maintained by `Value`'s copy/move/destroy; on the
   VM it is `std::shared_ptr`'s use count, as before.
2. **A generational cycle collector** for what counting cannot free: an
   instance whose field points back at it, parent <-> child, a ring, a
   closure stored in the scope it closes over, a bound method stored on its
   own instance, a list that contains itself. It uses *trial deletion*:
   for the objects of the generations being collected, subtract from each
   one's count the references the others hold on it. What still has a
   positive count is referenced from outside the group - from a C++ local,
   another thread's stack, a coroutine stack, a native table, an older
   generation - so it and everything it reaches survive. The rest is
   garbage: it is cleared (its references dropped), which brings the counts
   to zero and frees it.

Why this model and not tracing from roots: a tree-walking interpreter keeps
`Value`s in C++ locals all over the native stack, on other threads' stacks
and (with lazy generators) on coroutine stacks. Counting accounts for all of
them with no stack scanning and no shadow-stack registration, and trial
deletion needs only each object's outgoing references. The same algorithm
works on the VM, where `use_count()` is the count.

### Generations and triggers

Three generations, CPython's thresholds: a generation-0 collection when
tracked allocations minus deallocations exceed 700, generation 1 every 10
of those, generation 2 every 10 of those and only once the objects promoted
into generation 2 since the last full collection are a quarter of those it
kept (CPython's guard against quadratic full collections). On the VM the
generation-0 count is containers created (it cannot see deaths).

Object counts alone were not enough: a few hundred objects that each hold
100,000 floats (a model's parameters) are old before they become garbage,
and building four models in turn kept all four (263 MB) because the counts
put the full collection off. So both engines also run a **full collection
when the C allocator's in-use bytes (`mallinfo2`) have doubled since the
last one** (and grown by 16 MB): memory stays within about twice what is
live, and the work is amortised over what was allocated (Go's `GOGC=100`
rule). After a full collection `malloc_trim` gives free pages back to the
system (the four-model script: 263 MB -> 38 MB after `gc_collect()`).
Collections run only at **safe points**: statement boundaries on the
interpreter (`noteStatement`), instruction boundaries on the VM
(`run_loop`), one relaxed atomic load each when there is nothing to do.
`gc_collect()` runs one immediately.

## The interpreter (include/NyGC.hpp, src/NyGC.cpp, include/NyHeap*.hpp)

`TValue` gained one field, `o`: the object the value keeps alive. For a
list/dict/tuple/set (`COLLECTABLE`) it is the object itself; for a string,
function, bound method or instance (`USERDATA`) it is the heap object that
owns the payload `value.p` points at; for numbers, builtins and classes it
is null. Every copy of a value counts a reference; `value.p`/`value.gc` stay
what they were, so the side tables keyed by them (`func_names`,
`instance_to_class`, `closure_contexts`, `string_ptrs_`, ...) work unchanged.

| Object | What it owns (counted) | Tracked |
|---|---|---|
| `Object` (list, dict, tuple, set, namespace) | its entries | from birth |
| `Context` (a scope) | its variables, its parent scope | from birth |
| `nyheap::Str` (a string; `value.p == &s`) | - | no |
| `nyheap::Func` (a def or lambda; `value.p == &id`) | the scope it closes over, its default values | yes |
| `nyheap::Bound` (a method read as a value) | the function and the instance | yes |
| `nyheap::Inst` (an instance) | its field scope | yes |
| `nyheap::Weak` (`weakref(obj)`) | - (its target is not counted) | no |

A payload's identity is a member of its owning object, so it is valid
exactly as long as the object, and the object's destructor erases every side
table entry keyed by it (`forgetFunction` / `forgetBound` /
`forgetInstance`). A new object allocated at a freed one's address never
inherits the dead one's name, class, fields, closure, defaults or property
setter. (This is not only a leak question: a stale entry attached to a
recycled address is a correctness bug.)

Scopes are born holding one reference, their creator's. A call's scope is
released by its `CtxReaper` when the call returns; it survives only if
something took its own reference: a function defined in it, a child scope,
an instance's fields, a class body (`class_ctx_map_`). The old "escaped
scopes" set, which kept every scope a closure or class ever referred to for
the life of the process, is gone.

Strings are reference counted too. The empty string, the 256 one-byte
strings, single multi-byte characters, `internString` names and the literal
cached in each `StringNode` are immortal (held by their tables), as in
round 73.

### Invariants that keep it safe

- **Counts are plain integers, touched only with the GIL held** (or by the
  only thread before a second one starts). Every `nyconc::GilRelease` region
  was audited: none copies or destroys a `Value`. A runtime box
  (`InterpBox`) that happens to be released by a thread in a blocking wait
  hands its reference to the next safe point (`nygc::release_later`) instead
  of touching the count.
- **A tracked object with a count of zero is being built by native code**
  that holds it by pointer (`new Object`, fill, then wrap in a `Value`) and
  may call back into Nython while doing so (`map(f, xs)`). The collector
  treats it as a root, never as garbage.
- **Traversal may under-report, never over-report.** A reference the
  collector cannot see (a value in a native static table, a runtime box, an
  AST literal) only makes its target look externally referenced: it
  survives. Every reference an object reports is a counted one.
- **Finalizers never run inside a decrement.** An instance with `__del__`
  whose count reaches zero is queued, alive, and finalized at the next
  statement boundary; then it is freed unless `__del__` resurrected it. A
  destructor therefore never runs user code in the middle of a container
  operation.
- **Cyclic garbage is finalized before it is cleared** (PEP 442): all the
  finalizers of an unreachable group run first, the group is re-checked,
  and if a finalizer made any of it reachable again the whole group
  survives this collection. `__del__` runs at most once per object
  (`F_FINALIZED`).
- **Assignment reads before it releases.** `Value::operator=` assigns the
  payload last and `TValue::operator=` takes the new reference before
  dropping the old one: `x = x.next` through a container slot must not
  free the slot it is reading.
- **Freeing is iterative past depth 64** (a trash list): dropping the head
  of a 200,000-node linked list does not overflow the C++ stack.
- **A pointer kept outside a value is a reference or is erased on death.**
  The shared empty event list of `gui_poll_events` (a static `Object*`) now
  holds a reference; it was freed after its first use and returned freed.
  The property getter named by `prop.setter` is held until the setter's def
  runs (`prop_setter_target_`).
- **Statement values are dropped before the next statement starts**
  (`evalStatements`, loop bodies): `L.pop()` as a statement used to keep
  the popped object alive one statement longer.
- **Teardown**: `~NythonExecutor` runs the finalizers still queued, then
  releases the program's roots (globals, class bodies, class variables,
  raised exceptions, dict-key objects) and runs a full collection while the
  side tables still exist. No `__del__` runs during teardown (on the VM
  neither). Objects that outlive their executor (a literal interned in an
  AST freed later) skip the side tables (`nyheap::executor_alive`).

### Tables that hold references

- `exc_instance_map_`: a raised instance travels inside the exception string
  as a **serial number** (`"__exc__:C:__obj__:<serial>"`), and a ring keeps
  the last 256 raised instances plus those an `except` clause is handling.
  It used to keep every raised instance forever, keyed by address; a serial
  cannot be confused with a newer object at a reused address.
- `key_objs_`: objects used as dict keys are kept until the executor ends
  (the key string cannot carry a reference). See "Remaining limits".
- `prop_setter_target_`: above.

## The VM (include/VMGC.hpp, src/VMGC.cpp)

`VMVal` keeps its `shared_ptr` containers. Every list, dict/instance/scope
map, iterator and generator state the VM creates is registered once, by a
`weak_ptr` (which does not keep it alive), in generation 0. A collection
locks the live ones of the generations collected, takes `use_count() - 1`
as each one's count, subtracts the references the candidates' `VMVal`s hold
on each other (`list`, `map`, `iter`, `gen`, `closure_env`, a generator's
locals and saved stack), keeps what is reachable from the rest and clears
the garbage. References it cannot see - a native's `std::function`
captures, a compiled code object's constants - only keep things alive.

- `__del__`: an instance of a class with `__del__` owns its fields through
  `vmgc::FinalDeleter`. When the last reference goes, the fields move to a
  new map that waits for `__del__` at the next instruction boundary, once.
  Unreachable cycles are finalized on the objects themselves, before
  clearing, with the same resurrection check.
- Deep structures: the VM used to **crash** (stack overflow in the
  `shared_ptr` destructors) when a 30,000-node linked list was dropped.
  `VMVal`'s container pointers are `vmgc::DeepPtr`s: past 256 nested
  releases the object is parked and freed iteratively by the outermost one.
- Teardown: `~VirtualMachine` drops the globals, class variables and stacks
  and runs a full collection (no `__del__`).
- `gc_collect()` on the VM also collects the interpreter heap the builtin
  bridge used.

## Builtins (both engines, same names and meaning)

| | |
|---|---|
| `gc_collect(gen=2)` | collect now; returns the number of unreachable objects freed |
| `gc_enable()` / `gc_disable()` / `gc_is_enabled()` | automatic collection (reference counting always runs) |
| `gc_set_threshold(t0, t1, t2)` / `gc_get_threshold()` | the triggers |
| `gc_stats()` | dict: `collections`, `collected`, `uncollectable`, `finalized`, `tracked`, `gen0..2`, `live_objects`, `rss_kb` (+ `live_strings`, `string_bytes`, `freed_by_refcount` on the interpreter) |
| `gc_live_objects()` | heap objects alive (interpreter: containers, scopes, functions, instances; VM: containers) |
| `mem_rss_kb()` / `mem_peak_rss_kb()` | resident / peak resident size of the process |
| `weakref(obj)` | a callable giving the instance while it is alive, `none` after; instances only (TypeError otherwise, as in Python) |

Counts differ between the engines (their objects differ: an interpreter
instance is an object plus a scope), so tests compare them to bounds, not
to each other.

## Measurements

Peak resident size (KB of RSS, `ru_maxrss`), the pre-round-75 build
(e45ac52) against this one, same machine:

| Program | Interpreter before | after | VM before | after |
|---|---|---|---|---|
| 200k × `var L = [1,2,3]; var m = {"a":1}` (this file's benchmark) | 598,200 | 10,668 | 10,868 | 10,644 |
| 200k string-building iterations | 139,904 | 10,876 | 11,084 | 10,748 |
| 100k self-cycles: node ↔ node, `L.append(L)` | 472,848 | 11,468 | 445,200 | 12,180 |
| 50k instances holding a closure over `self` + recursive inner function | 265,712 | 11,364 | 106,900 | 11,388 |
| 200k-node linked list kept alive, then dropped | 441,852 | 418,748 | **crash** (SIGSEGV) | 188,980 |
| six models (ViT, 26 MB of parameters each) built in turn | 362,196 | 286,804 | 271,692 | 217,464 |
| test_nytorch13 | 714,196 | 87,520 | 283,244 | 54,680 |
| test_nytorch14 | 689,324 | 181,716 | 157,016 | 116,268 |
| test_nytorch15 | 1,067,636 | 76,392 | 233,116 | 47,208 |
| test_nytorch16 | 1,114,368 | 150,768 | 267,772 | 86,424 |
| test_nytorch17 | 50,820 | 46,156 | 33,908 | 34,164 |

(Measured before merging the lazy generators and strict reads. After that
merge the interpreter's nytorch peaks are 98 / 193 / 80 / 151 / 47 MB and the
VM's 61 / 119 / 47 / 87 / 34 MB; the loop benchmarks are unchanged.)

What is left is live data. test_nytorch14 keeps every section's models in
global variables to the end, and a float in an interpreter list costs about
280 bytes (a 208-byte `Value` plus its slot in a string-keyed map), so a
ViT's 100k parameters are 26 MB; the linked list is 200k live instances at
about 2 KB each. That is the interpreter's value representation, not
garbage.

The IDE (`tools/ide_memprobe.py`, KB kept per unit): idle 0.00, hover 0.00,
typing 0.00, scroll 0.05, split 0.00 (HANDOFF §0e recorded typing ~18 and
scroll ~8 before this round).

Speed, instructions executed (callgrind; deterministic), pre-round-75 build
against this one - small programs, so each includes freeing everything at
exit, which the old build never did:

| | interpreter | VM |
|---|---|---|
| 20k calls of a 2-argument function | +2.1% | +0.4% |
| 10k method calls | -2.2% | +0.8% |
| fib(16) | +2.4% | +1.4% |
| 10k two-element lists appended + 10k dict inserts | +7.1% | +7.1% |
| 5k instances created | +9.8% | +5.3% |

In test_nytorch15 the collector (collections, finalizer queue, freeing
bookkeeping) is 1.4% of the instructions; `mallinfo2` 0.002%.

## Verification

- `examples/vm_audit55.ny`: 4059 checks, identical output on both engines
  (counts compared to bounds, not between engines).
- `python3 tools/sweep.py --base /tmp/r73/build/nython-cli -j 3` after
  merging the lazy generators and strict reads (5956169/e2b60b6): 350
  runs, 0 not ok, 0 regressions. Before that merge, against the main head
  (ea36a05): 346 runs, 0 regressions.
- `vm_audit56` (lazy generators) on both engines: 120 passed, 0 pending -
  the interpreter's one PENDING check (dropping the last reference to a
  suspended generator runs its `finally`) passes with reference counting.
- Windows (MinGW-w64, `tools/cross_windows.sh build`, under Wine):
  vm_audit55 and vm_audit56 pass on both engines. There `mem_rss_kb()` is 0
  and the heap-growth trigger is off (no `mallinfo2`).
- ASan + UBSan + LSan (`make asan`, `LSAN_OPTIONS=suppressions=tools/lsan.supp`,
  `ulimit -s 65536` because ASan frames overflow the default stack in the
  deep-recursion tests), every `test_*.ny`, `*_test.ny`, `vm_audit*.ny` and
  `gui_tests/test_*.ny` on both engines, on the merged tree (350 runs):
  **no AddressSanitizer error** (no use-after-free, double free or
  overflow) and **no leak** apart from UBSan's own demangler buffer when it
  prints a report. UBSan reported two pre-existing sites, unrelated to
  memory management, since fixed: `evalList` read a tuple node through a
  `ListNode` pointer, and `bigint`'s signed-to-magnitude conversion
  negated -2**63 in the signed type (0 reports on vm_audit27/54/60/61 now). One run fails for the instrumented build only: vm_audit56
  on the VM raises RecursionError in its 500-level recursive generator
  test, because ASan's frames exhaust the native stack that
  `nycoro::native_stack_exhausted()` guards (with a 512 MB stack ASan then
  flags `sigaltstack` inside the coroutine runtime) - the normal build
  passes it on Linux and under Wine. Before the merge the same run (346
  runs) was clean in the same way.
  (The ASan runs came after the defects in HANDOFF §0k were fixed; the
  normal build's tests found those. One kind ASan cannot see at all: a
  stale side-table entry keyed by a freed object's address is never
  dereferenced, and ASan's quarantine delays the address reuse that makes
  it visible - the property-getter bug showed up only in the normal build.)
- Concurrency: vm_audit48 (130 checks) four copies at once on each engine,
  vm_audit49/50 on both engines, all pass; vm_audit55 has four threads
  collecting concurrently. The collector adds no blocking wait and no
  cross-thread pause: it runs on the thread that holds the GIL, at its own
  safe points.
- `tools/ide_e2e.py` 365 passed, 0 failed (merged tree); `tools/ide_lint.py` 0
  unresolved; `tools/ide_memprobe.py --check` passes;
  `tools/ny_classcheck.py` no duplicates.

## Remaining limits

- ~~Objects used as dict keys are kept for the process~~ - **round 76**: the
  key table (`key_objs_`, the VM's `vm_key_objs()`) no longer keeps anything
  alive by itself. A key is a string inside the dict and cannot carry a
  reference, so in a **full** collection the table's references are
  discounted (as if the dicts held them), a reached dict reaches the objects
  its keys name - object keys, and object keys inside tuple keys
  (`Container::gc_traverse` while `nygc::g_key_edges` is set) - and the
  entries of objects found unreachable are dropped before they are cleared
  (`nygc::KeyTable`). Young collections leave the table alone: an old dict is
  not traversed there, so its keys' objects must be kept. A key looked up
  but never stored goes at the next full collection.
- **The VM's collector cannot see references held by natives**: a
  `std::function`'s captures (a `property` descriptor's `setter`, a
  `weakref` closure) and compiled code objects' constants. Cycles through
  them are not collected; nothing is freed wrongly.
- **VM generation 0 counts creations**, not creations minus deaths, and the
  weak_ptr registry keeps a dead container's control block (~100 bytes)
  until the next generation-0 collection (at most ~700 of them).
- **Teardown frees everything**, which costs time at exit for very large
  heaps (it is what makes LeakSanitizer runs meaningful).
- **Raised instances**: a stored exception string (a future's error re-raised
  much later) whose instance has left the 256-entry ring re-raises as a new
  instance of the same class with an empty message.
- The **interpreter's value representation** is unchanged (above): a float
  in a list is ~280 bytes, an instance ~2 KB. Reclaiming garbage does not
  shrink live data.
- ~~The old `GarbageCollector` is still compiled~~ - removed in round 76.
- **Function attributes** (`f.x = v`, round75-sem) are freed with their
  function on the interpreter; on the VM `func_attrs_` is keyed by raw
  code/scope pointers and holds its values as roots: a function attribute
  that refers back to the function is never collected there, and an entry
  can outlive its function's scope. Bound builtin members
  (`lst.append` read as a value) are heap objects (`nyheap::BMember`) since
  round 76, freed with their last reference.
- **Suspended generators** (round75-gen; round 76): `GenObject` traverses
  what the generator's record holds (its pinned scope, values in flight,
  the iterators it reads) and is finalizable while suspended: an
  unreachable one is closed before anything is cleared - finally blocks
  run, the coroutine stack unwinds - and the group is then freed unless the
  recount finds it resurrected. References on a suspended stack still look
  external (they keep what they reach alive). Another thread's suspended
  generator reports no edges, so it is never found unreachable. The VM
  closes a suspended generator in its garbage the same way
  (`VirtualMachine::gc_close_generator`). A generator dropped while
  suspended is closed at the next statement (reference counting destroys
  its object; `~GenObject` queues it for `nygen::run_pending`).

## History: the leak this replaced (rounds 51-74)

Until round 75 the interpreter never freed a container, string, function,
bound method or instance: 200,000 iterations of `var L = [1,2,3]` and
`var m = {"a":1}` peaked at 494-598 MB, and the largest nytorch tests near
1.1 GB. `Object`s were allocated with raw `new` and never deleted; the
`GarbageCollector` class (mark/sweep over `MemoryCell`s, in
`src/GarbageCollector.cpp` until round 76 removed it) was never wired: no allocation went
through it, nothing registered temporaries, and `do_collect()` was
unreachable from `NythonExecutor`. Round 73 reduced the garbage made
(shared literals and one-byte strings); round 75 reclaims it. The VM was
fine for acyclic data but leaked every reference cycle (445 MB on the
self-cycle benchmark below) and crashed freeing long chains.
