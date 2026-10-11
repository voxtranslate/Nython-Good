# lib/concurrent/futures/_procworker.ny - the program a ProcessPoolExecutor
# worker process runs (round 79; see lib/concurrent/futures/process.ny).
#
#     nython _procworker.ny MAIN_PATH
#
# It reads one JSON request per line on stdin - {"op": "init" | "call" |
# "quit", ...} - runs it, and answers each on stdout with one line that
# starts with process.ny's marker; anything else the called code prints
# goes out as ordinary lines, which the parent passes on. MAIN_PATH (empty
# when the parent was not run from a file) is the parent's main program,
# run once here as the module __mp_main__ when a call needs something
# defined in it.
import sys
import json
import traceback
from concurrent.futures import process as _p

_main_path = sys.argv[1] if len(sys.argv) > 1 else ""
_main_ns = [None]


def _main():
    if _main_ns[0] is None:
        if not _main_path:
            raise _p.PicklingError("the main program was not run from a file: a worker process cannot import __main__")
        var ns = {"__name__": "__mp_main__", "__file__": _main_path}
        var f = open(_main_path)
        var src = f.read()
        f.close()
        exec(compile(src, _main_path, "exec"), ns)
        _main_ns[0] = ns
    return _main_ns[0]


def _decode(v):
    # what needs __main__ loads it first
    var text = json.dumps(v)
    if '"__main__"' in text or '"__mp_main__"' in text:
        return _p.decode(v, _main())
    return _p.decode(v, None)


def _reply(msg):
    sys.stdout.write(_p._MARK + json.dumps(msg) + "\n")
    sys.stdout.flush()


while True:
    var line = sys.stdin.readline()
    if not line:
        break
    var req = json.loads(line)
    var op = req["op"]
    if op == "quit":
        break
    if op == "init":
        try:
            var fn = _decode(req["fn"])
            fn(*_decode(req["args"]))
            _reply({"ok": None})
        except BaseException as e:
            _reply({"initerr": traceback.format_exc()})
        continue
    try:
        var fn = _decode(req["fn"])
        var args = _decode(req["args"])
        var kwargs = _decode(req["kwargs"])
        var result = None
        if req.get("chunk"):
            result = [fn(*a) for a in args[0]]
        else:
            result = fn(*args, **kwargs)
        _reply({"ok": _p.encode(result)})
    except BaseException as e:
        var enc = None
        try:
            enc = _p.encode(e)
        except BaseException:
            enc = _p.encode(Exception(repr(e)))
        _reply({"err": enc, "tb": traceback.format_exc()})
