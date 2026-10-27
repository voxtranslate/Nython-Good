# generates examples/vm_audit94.ny: each check's expected value is what
# python3 (CPython 3.11) computes for the same expression
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vm_audit94_spec import HEADER, PREAMBLE, ENTRIES, NYTHON_ONLY, FOOTER

ns = {'__name__': '__gen94__'}
out = [HEADER, PREAMBLE]
exec(PREAMBLE, ns)
count = 0
for e in ENTRIES:
    if e[0] == 'code':
        exec(e[1], ns)
        out.append(e[1].rstrip('\n') + '\n')
    elif e[0] == 'fixed':
        # an expected value written by hand (it cannot be computed here)
        out.append('check(%r, %s,\n      %s)\n' % (e[1], e[2], e[3]))
        count += 1
    else:
        name, expr = e[1], e[2]
        try:
            v = eval(expr, ns)
        except Exception as ex:
            raise SystemExit('check %r failed under python3: %r' % (name, ex))
        want = repr(v)
        try:
            if eval(want, ns) != v:
                raise SystemExit('repr does not round-trip: %r -> %s' % (name, want))
        except SystemExit:
            raise
        except Exception as ex:
            raise SystemExit('repr does not evaluate: %r -> %s (%r)' % (name, want, ex))
        out.append('check(%r, %s,\n      %s)\n' % (name, expr, want))
        count += 1
out.append(NYTHON_ONLY)
out.append(FOOTER)
open('examples/vm_audit94.ny', 'w').write(''.join(out))
print(count, 'checks generated')
