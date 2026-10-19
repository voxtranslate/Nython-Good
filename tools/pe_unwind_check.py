#!/usr/bin/env python3
"""tools/pe_unwind_check.py - reject Windows x64 unwind info the unwinder misreads.

    python3 tools/pe_unwind_check.py build-win/nython.exe

Windows (and Wine) read a function's XMM saves relative to its frame base,
the frame register minus FrameOffset*16. MSVC sets the frame pointer after
the whole stack allocation, so that base is the final RSP. GCC can set it
right after `push rbp`, before the allocation, and still records the saves
relative to the final RSP. Every exception that unwinds through such a
function then restores XMM6-XMM15 from the wrong address, and on the topmost
frame of a fiber's stack it reads past the stack's end (the crash vm_audit56
hit on 64-bit Windows at -O2). __builtin_frame_address(0) in an inlined hot
path was enough to make evalCall such a function (see nycoro::stack_position).

This lists every function whose unwind codes establish the frame pointer
before the stack allocation and also save an XMM register, and exits 1 if
there are any.
"""
import bisect
import re
import subprocess
import sys


def objdump(path, tool):
    return subprocess.run([tool, "-p", path], capture_output=True, text=True).stdout


def symbols(path, tool):
    out = subprocess.run([tool, "-C", "--defined-only", path], capture_output=True, text=True).stdout
    syms = []
    for line in out.splitlines():
        parts = line.split(" ", 2)
        if len(parts) == 3 and parts[1] in ("t", "T"):
            try:
                syms.append((int(parts[0], 16), parts[2]))
            except ValueError:
                pass
    syms.sort()
    return syms


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    path = argv[0]
    prefix = argv[1] if len(argv) > 1 else "x86_64-w64-mingw32-"
    text = objdump(path, prefix + "objdump")
    if "Dump of .xdata" not in text:
        print("pe_unwind_check: no .xdata in %s (not a Windows x64 image?)" % path)
        return 0
    xdata = text[text.index("Dump of .xdata"):]
    blocks = re.split(r"\n (?=[0-9a-f]{16} \(rva)", xdata)
    bad = []
    for b in blocks:
        m = re.match(r"([0-9a-f]{16}) \(rva: [0-9a-f]+\): ([0-9a-f]{16}) - ([0-9a-f]{16})", b)
        if not m or "Frame reg:" not in b or "Frame reg: none" in b:
            continue
        # Codes are listed last prolog operation first.
        codes = [l.strip() for l in b.split("\n") if l.strip().startswith("pc+")]
        fp = [i for i, c in enumerate(codes) if "FPReg" in c]
        alloc = [i for i, c in enumerate(codes) if "alloc" in c]
        xmm = any("xmm" in c.lower() for c in codes)
        if xmm and fp and alloc and min(alloc) < fp[0]:
            bad.append(int(m.group(2), 16))
    if not bad:
        print("pe_unwind_check: %s: no function sets its frame pointer before allocating "
              "and saves XMM registers" % path)
        return 0
    syms = symbols(path, prefix + "nm")
    addrs = [a for a, _ in syms]
    for a in bad:
        i = bisect.bisect_right(addrs, a) - 1
        print("pe_unwind_check: 0x%x %s: frame pointer before the allocation, XMM saves "
              "(exceptions unwinding through it restore XMM registers from the wrong place)"
              % (a, syms[i][1] if i >= 0 else "?"))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
