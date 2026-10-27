# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/nypip/_in_process.ny - runs one PEP 517 build-backend hook in a process
# of its own (round 87; after pyproject_hooks' _in_process.py):
#
#     nython _in_process.ny HOOK CONTROL_DIR
#
# CONTROL_DIR/input.json holds {"backend": "mod:obj", "backend_path": [...],
# "kwargs": {...}}; the result goes to CONTROL_DIR/output.json as
# {"return_val": ...}, {"unsupported": true} (an optional hook the backend
# lacks) or {"error": "...", "traceback": "..."}. The working directory is
# the source tree; backend-path entries (inside it) come first on sys.path,
# the build environment's directories through NYTHONPATH.
import json
import os
import sys
import traceback

OPTIONAL = ("get_requires_for_build_wheel", "get_requires_for_build_sdist",
            "prepare_metadata_for_build_wheel", "get_requires_for_build_editable",
            "prepare_metadata_for_build_editable")


def _load(spec, paths):
    for p in reversed(paths):
        sys.path.insert(0, os.path.abspath(p))
    mod_name, _, obj = spec.partition(":")
    __import__(mod_name)
    obj_ = sys.modules[mod_name]
    if obj:
        for part in obj.split("."):
            obj_ = getattr(obj_, part)
    return obj_


def main():
    hook = sys.argv[1]
    control = sys.argv[2]
    with open(os.path.join(control, "input.json"), encoding="utf-8") as f:
        req = json.load(f)
    out = {}
    try:
        backend = _load(req["backend"], req.get("backend_path") or [])
        fn = getattr(backend, hook, None)
        if fn is None:
            if hook in OPTIONAL:
                out = {"unsupported": True}
            else:
                out = {"error": "the backend %s has no %s hook" % (req["backend"], hook)}
        else:
            out = {"return_val": fn(**req.get("kwargs", {}))}
    except BaseException as e:
        out = {"error": "%s: %s" % (type(e).__name__, e), "traceback": traceback.format_exc()}
    with open(os.path.join(control, "output.json"), "w", encoding="utf-8") as f:
        json.dump(out, f)


main()
