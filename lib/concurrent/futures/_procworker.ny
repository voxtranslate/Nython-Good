# lib/concurrent/futures/_procworker.ny - the program a ProcessPoolExecutor
# worker process runs (round 79; pickle since round 80 - see
# lib/concurrent/futures/process.ny).
#
#     nython _procworker.ny MAIN_PATH
#
# It reads one message per line on stdin - the base64 of a pickled
# ("init", fn, args) | ("call", fn, args, kwargs, chunk) | ("quit",) - runs
# it, and answers each on stdout with one line that starts with
# process.ny's marker; anything else the called code prints goes out as
# ordinary lines, which the parent passes on. MAIN_PATH (empty when the
# parent was not run from a file) is the parent's main program, run once
# here as the module __mp_main__ when a message names something defined in
# it (pickle then finds "__main__" there).
import sys
import base64
import pickle
import traceback
from concurrent.futures import process as _p

_main_path = sys.argv[1] if len(sys.argv) > 1 else ""
_main_ns = [None]


def _main():
    if _main_ns[0] is None:
        if not _main_path:
            raise pickle.PicklingError("the main program was not run from a file: a worker process cannot import __main__")
        var ns = {"__name__": "__mp_main__", "__file__": _main_path}
        _main_ns[0] = ns
        pickle._ny_set_main(ns)
        var f = open(_main_path)
        var src = f.read()
        f.close()
        exec(compile(src, _main_path, "exec"), ns)
    return _main_ns[0]


def _load(text):
    var data = base64.b64decode(text)
    if b"__main__" in data or b"__mp_main__" in data:
        _main()
    return pickle.loads(data)


def _reply(msg):
    var data = None
    try:
        data = pickle.dumps(msg, 5)
    except BaseException as e:
        data = pickle.dumps(("err", pickle.PicklingError("cannot send the result back: " + repr(e)),
                             traceback.format_exc()), 5)
    sys.stdout.write(_p._MARK + base64.b64encode(data).decode("ascii") + "\n")
    sys.stdout.flush()


while True:
    var line = sys.stdin.readline()
    if not line:
        break
    var req = None
    try:
        req = _load(line.strip())
    except BaseException as e:
        _reply(("err", e, traceback.format_exc()))
        continue
    var op = req[0]
    if op == "quit":
        break
    if op == "init":
        try:
            req[1](*req[2])
            _reply(("ok", None))
        except BaseException as e:
            _reply(("initerr", None, traceback.format_exc()))
        continue
    try:
        var fn = req[1]
        var args = req[2]
        var kwargs = req[3]
        var result = None
        if req[4]:
            result = [fn(*a) for a in args[0]]
        else:
            result = fn(*args, **kwargs)
        _reply(("ok", result))
    except BaseException as e:
        _reply(("err", e, traceback.format_exc()))
