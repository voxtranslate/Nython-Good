#!/usr/bin/env python3
"""gen_vm_audit128_pep440.py - the PEP 440 / PEP 508 table vm_audit128 checks
nypip's version handling against (round 87).

    python3 tools/gen_vm_audit128_pep440.py      # needs the `packaging` package

Writes examples/vm_audit128_pep440.json: a corpus of version strings
(generated from every combination of the PEP's segments and spellings, and
invalid ones) with what packaging 22+ makes of each - valid or not, str(),
public, base_version, release, epoch, pre, post, dev, local, the is_*
flags, and the corpus' sort order -, Specifier.contains / SpecifierSet.filter
over it for a list of specifiers, str() of specifier sets, PEP 508 markers
evaluated in two environments and requirements normalised. packaging is not
in Python's standard library; the host's (python3-packaging) is the
reference, and its version is recorded."""
import itertools
import json
import os
import random
import sys

import packaging
from packaging.version import Version, InvalidVersion
from packaging.specifiers import Specifier, SpecifierSet, InvalidSpecifier
from packaging.markers import Marker, InvalidMarker
from packaging.requirements import Requirement, InvalidRequirement

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

rng = random.Random(87)
epochs = ["", "1!", "0!", "2!"]
releases = ["0", "1", "1.0", "1.0.0", "1.1", "1.2", "1.2.3", "2", "2.0", "10", "1.0.0.1", "01.02", "0.9", "3.14"]
pres = ["", "a1", "b2", "rc1", "c3", ".alpha1", "-beta.2", "pre4", "preview5", "a", "RC2", "_a3", ".b0"]
posts = ["", ".post1", "-1", "post2", ".rev3", "r4", ".post", "-post_5", ".POST0"]
devs = ["", ".dev0", ".dev12", "dev3", ".dev", "-DEV4"]
locals_ = ["", "+abc", "+1.2.c", "+ubuntu-1", "+5", "+a.10", "+A_b"]

corpus = set()
for e, r, p, po, d, l in itertools.product(epochs, releases, pres, posts, devs, locals_):
    if rng.random() < 0.0035 or (e == "" and l == "" and rng.random() < 0.02):
        corpus.add(e + r + p + po + d + l)
corpus.update(["1.0", "v1.0", "  1.0  ", "V2", "1.0-1", "1.0_dev1", "1!1.0", "1.0a", "1.0.post", "1.0.dev",
               "0.0.0", "1.01", "1.1.0", "1.10", "1.9", "2.0.0.0", "1.0+abc.5", "1.0+abc.10", "1.0+5", "1.0+abc",
               "1.0a1.post2.dev3", "1.0.post1.dev1", "1.0rc1.dev0", "1.0c1", "1.0.0a0"])
invalid = ["", "1.0.", ".1", "1..0", "a", "1.0-", "1.0+", "1.0+a+b", "1.0 a", "1.0.x", "1!", "!1", "1.0b1b2",
           "1.0++1", "1.0-dev-1", "1.0.post1.post2", "1.0+_", "1.0+.a", "1.0+a.", "-1", "1,0"]
corpus = sorted(corpus) + invalid

versions = []
valid = []
for s in corpus:
    try:
        v = Version(s)
    except InvalidVersion:
        versions.append([s, None])
        continue
    valid.append((s, v))
    versions.append([s, [str(v), v.public, v.base_version, list(v.release), v.epoch,
                         list(v.pre) if v.pre else None, v.post, v.dev, v.local,
                         v.is_prerelease, v.is_postrelease, v.is_devrelease, v.major, v.minor, v.micro]])
order = [s for s, v in sorted(valid, key=lambda x: (x[1], x[0]))]
# equal versions: groups of corpus strings that compare ==
equal = []
for s, v in valid:
    same = sorted(t for t, w in valid if w == v)
    if len(same) > 1 and same not in equal:
        equal.append(same)

specs = ["==1.0", "==1.0.*", "==1.*", "!=1.0", "!=1.0.*", ">=1.0", ">1.0", "<=1.0", "<1.0", "~=1.0", "~=1.1.0",
         "~=2.0", ">=1.0a1", "<2.0", "<2.0.dev0", ">1.0.post1", ">1.0a1", "==1.0+abc", "===1.0", "==1!1.0",
         ">=1!1.0", "<1.0.post1", ">=1.0,<2.0", ">=1.0,!=1.1", "~=1.0.0,!=1.0.3", "==1.0.0.1", ">=0.9,<=1.2.3",
         "", ">=1.0rc1", "==1.2.*,>1.2.1", "!=1.0+abc", ">=1.0.dev0"]
sample = [s for s, v in valid if rng.random() < 0.5][:140]
spec_rows = []
for sp in specs:
    ss = SpecifierSet(sp)
    contains = "".join("1" if ss.contains(s) else "0" for s in sample)
    contains_pre = "".join("1" if ss.contains(s, prereleases=True) else "0" for s in sample)
    filt = list(ss.filter(sample))
    spec_rows.append([sp, str(ss), ss.prereleases, contains, contains_pre, filt])
bad_specs = []
for sp in ["=1.0", "==1.0.*.*", "~=1", ">=1.0.*", "== 1.0 .*", "<>1", "!=1.0+abc.*", "~=1.0+abc", "<=1.0+abc"]:
    try:
        SpecifierSet(sp)
        bad_specs.append([sp, True])
    except InvalidSpecifier:
        bad_specs.append([sp, False])

env_linux = {"implementation_name": "nython", "implementation_version": "0.2.1", "os_name": "posix",
             "platform_machine": "x86_64", "platform_release": "6.1.0", "platform_system": "Linux",
             "platform_version": "#1 SMP", "python_full_version": "3.12.0",
             "platform_python_implementation": "Nython", "python_version": "3.12", "sys_platform": "linux"}
env_win = dict(env_linux, os_name="nt", platform_machine="AMD64", platform_system="Windows", sys_platform="win32",
               platform_release="10", platform_version="10.0.19041")
markers = ['python_version >= "3.8"', 'python_version < "3.12"', "sys_platform == 'win32'",
           'os_name == "posix" and platform_machine == "x86_64"', 'implementation_name == "cpython"',
           '(sys_platform == "linux" or sys_platform == "darwin") and python_full_version >= "3.12.0"',
           'extra == "test"', 'extra == "Test_Extra"', '"linux" in sys_platform', '"x86" not in platform_machine',
           'platform_system != "Windows"', 'python_version ~= "3.10"', 'python_version === "3.12"',
           'platform_release >= "5"', "os.name == 'nt'", 'python_version > "3.12"', 'python_full_version < "3.12.1"',
           'implementation_name == "nython" and implementation_version >= "0.2"']
marker_rows = []
for m in markers:
    mk = Marker(m)
    row = [m, str(mk)]
    for env in (env_linux, env_win):
        for extra in ("", "test", "test-extra"):
            e = dict(env, extra=extra)
            try:
                row.append(mk.evaluate(e))
            except Exception as ex:
                row.append(type(ex).__name__)
    marker_rows.append(row)
bad_markers = []
for m in ['python_version >= ', 'foo == "1"', 'python_version >= "3" and', '"a" == "b" or (os_name', "os_name = 'nt'"]:
    try:
        Marker(m)
        bad_markers.append([m, True])
    except InvalidMarker:
        bad_markers.append([m, False])

reqs = ["requests", "requests>=2.0", "Requests [security, socks] >= 2.8.1, == 2.8.*", "name@ https://x.org/a.whl",
        "pkg[extra]~=1.0; python_version < '3.8'", "a.b-c_d ===1.0", "foo (>=1.0,<2)", "bar[A,b]",
        "baz; os_name == 'nt' and extra == 'X'", "zoo !=1.5, >1.0"]
req_rows = []
for r in reqs:
    q = Requirement(r)
    req_rows.append([r, str(q), q.name, sorted(q.extras), str(q.specifier), q.url, str(q.marker) if q.marker else None])
bad_reqs = []
for r in ["", "foo bar", "foo[", "foo>=", "foo;", "@ http://x", "foo @", "1foo-"]:
    try:
        Requirement(r)
        bad_reqs.append([r, True])
    except InvalidRequirement:
        bad_reqs.append([r, False])

out = {"generated_by": "tools/gen_vm_audit128_pep440.py", "packaging": packaging.__version__,
       "versions": versions, "order": order, "equal": equal, "sample": sample, "specs": spec_rows,
       "bad_specs": bad_specs, "env_linux": env_linux, "env_win": env_win, "markers": marker_rows,
       "bad_markers": bad_markers, "requirements": req_rows, "bad_requirements": bad_reqs}
path = os.path.join(REPO, "examples", "vm_audit128_pep440.json")
with open(path, "w") as f:
    json.dump(out, f, indent=0, sort_keys=True)
    f.write("\n")
print("wrote %s: %d versions (%d valid), %d specifiers, %d markers, %d requirements (packaging %s)"
      % (path, len(versions), len(valid), len(spec_rows), len(marker_rows), len(req_rows), packaging.__version__))
