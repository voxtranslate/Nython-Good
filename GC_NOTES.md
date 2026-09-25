# Why the interpreter leaks containers, and what the fix is

Status: diagnosed, **not fixed**. This documents what was measured so the work
can be picked up without repeating the investigation.

## The measurement

Identical program, 200,000 iterations of `var L = [1,2,3]` plus `var m = {"a":1}`:

```
tree-walking interpreter   peak 494 MB
bytecode VM                peak   7 MB
```

The VM does not have this problem. That is the single most useful fact here,
because it means the fix does not need inventing — one of the two engines in
this repository already implements it.

## Why the VM is fine

`VMVal` holds its containers as shared pointers:

```cpp
std::shared_ptr<std::vector<VMVal>>                    list;
std::shared_ptr<std::unordered_map<std::string,VMVal>> map;
```

Refcounting is automatic and exact. When the last `VMVal` referring to a list
goes out of scope, the vector is freed. No collector, no mark phase, no shadow
stack.

## Why the interpreter is not

Three independent problems, all of which must be fixed together:

**1. Containers are not allocated through the GC.** There are 24 raw
`new Object(...)` sites in `NythonExecutor.hpp` and zero calls to
`gc->allocate()`. A `MemoryCell` is never created for them, so they are not in
any heap the sweep walks. The collector cannot free what it was never told
about.

**2. Nothing registers temporaries.** `GarbageCollector::mark_persistent()` and
`unmark_persistent()` exist and are called from nowhere outside the GC itself.
The `temporaries` multiset — the shadow stack the mark phase reads — is always
empty. So even if (1) were fixed, the sweep would free objects still held by
`Value` temporaries living in C++ locals, which is a use-after-free. This is the
hazard recorded in round 8 and it is still real.

**3. `do_collect()` is unreachable from the live executor.** It is called only
from `Interpreter.hpp`. `NythonExecutor` — the class that actually runs
programs — never calls it.

The collector itself is *correct*: it marks from `runner->stack_` and from
`temporaries`, then sweeps every heap cell, with double-free protection. It is
complete code wired to nothing.

## What scope reclamation already does

`reapContext()` (rounds 19/21) frees a `Context` and its variable map on scope
exit unless the context escaped. That is why function calls and arithmetic are
flat at ~7 MB while container literals are not: the *map of names* is reclaimed,
but the `Object` a name pointed at is not.

## The fix, in preference order

**Option A — match the VM: make container payloads shared.** Change the
interpreter's list/map payload to a `shared_ptr` the way `VMVal` does. Exact,
immediate, no collector needed, and proven by the other engine.

The cost is that `Value.value.p` is a raw `void*` used as an identity key across
several maps (`instance_properties`, `func_names`, `instance_to_class`,
`string_ptrs_`, `value_closure_id`). Those keys must keep working, so the
migration is: introduce the shared payload, keep the raw pointer as the identity
key, and make the maps not own anything. This is a large but mechanical change
and it is the recommended route.

**Option B — finish wiring the existing collector.** Route the 24 allocation
sites through `gc->allocate()`, register every `Value` temporary via
`mark_persistent`/`unmark_persistent` in `Value`'s copy constructor and
destructor, and call `do_collect()` periodically from the executor.

This is more invasive than it looks: touching `Value`'s copy constructor puts a
mutex-guarded multiset insertion on the hottest path in the interpreter, and
getting registration wrong in either direction is either a leak or a
use-after-free.

**Option C — scope-owned containers.** Extend `reapContext()` to also free
Objects created within that scope which did not escape. Cheapest to write, but
escape analysis for objects is exactly the part that is easy to get wrong, and a
mistake is a use-after-free rather than a leak.

## Why this was not attempted here

Every option above changes object lifetime across the whole interpreter. A bug
in any of them is a use-after-free — silent corruption, not a visible failure —
and the existing 350-example suite would very likely still pass, because a freed
object usually still reads correctly for a while.

That is the specific reason to do this as a dedicated change with its own
verification (ASan build, allocation counters, a stress test that interleaves
escaping and non-escaping containers) rather than as an increment at the end of
a session.

## Interim mitigation

`MEMORY_NOTES.md` documents how to write Nython that does not generate this
garbage in the first place: in-place `append` instead of `x = x + [y]`
(measured 860x faster, 2400x less memory at 4,000 elements), and operation logs
instead of state snapshots for history (measured 373 MB -> 56 MB for 400 edits).
Those are workarounds. This document is the fix.

## Round 73: garbage the interpreter no longer makes

Strings are immutable and, like containers, never freed (`string_store`). Three
sources of *pointless* strings were removed, safely — nothing's lifetime changes,
the same value is simply handed out again instead of a fresh copy:

- **String literals** are made once per AST node (`StringNode::interned`), not
  on every evaluation. A 200,000-iteration loop comparing against two literals:
  48 MB → 10 MB.
- **The empty string and the 256 one-byte strings** are made once
  (`small_strs_`), so character loops (`line[i:i+1]`, `string_lower(ch)`) stop
  leaving one string per character examined: 28 MB → 10 MB on a 100,000-step
  scan.
- **`__parent_class__`**, bound on every method call of a subclass, is interned
  (`internString`) instead of being a new string per call.

To find the next one, `--profile` now reports, per function, the heap objects
still alive and the strings made by its own statements (`self_objects`,
`self_strings`, `self_string_bytes`; `NY_PROFILE_SORT=alloc` sorts by them), and
`NY_PROFILE_OUT=file nython --ide` does the same for the IDE. The object count is
created-minus-destroyed, so call frames that are reaped do not show up.

In the IDE this took typing from 787 KB to ~40 KB kept per keystroke and idle
repainting from 3.45 KB per frame to zero (`tools/ide_memprobe.py`). The
collector itself is still unwired; everything above is about not creating
garbage, not about reclaiming it.
