# vm_audit76.ny - Python's OS-facing and testing modules (lib/): fnmatch,
# glob, shutil, tempfile, pathlib, subprocess, platform, getpass, logging,
# unittest, queue - on both engines.
#
# Written in the subset Nython and Python share, so the same file runs
# under python3 (the real standard library) and both Nython engines, and
# every expected value below is what CPython computes:
#     python3 examples/vm_audit76.ny
#     ./build/nython-cli examples/vm_audit76.ny
#     ./build/nython-cli --vm examples/vm_audit76.ny
#
# Also pins the engine fixes made with these modules: `not` binds looser
# than comparisons, builtins called through a namespace keep their keyword
# arguments (os.makedirs(p, exist_ok=True)), path-like objects are accepted
# by open() and the os functions, os.utime, the exception being handled is
# visible to logging.exception (_ny_exc_current).
#
# Everything happens in a per-process temporary directory that is removed
# at the end; nothing depends on the network or on wall-clock timing.
try:
    true
except NameError:
    true = True
    false = False
    none = None

import os
import sys
import fnmatch
import glob
import shutil
import tempfile
import pathlib
import subprocess
import platform
import getpass
import logging
import unittest
import queue
import threading
import time
from pathlib import Path, PurePosixPath, PureWindowsPath

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def raises(fn, *args, **kw):
    # the exception's type name, or "no error"
    try:
        fn(*args, **kw)
    except Exception as exc_r:
        return type(exc_r).__name__
    return "no error"

def raises_msg(fn, *args, **kw):
    try:
        fn(*args, **kw)
    except Exception as exc_m:
        return type(exc_m).__name__ + ": " + str(exc_m)
    return "no error"

TMP = tempfile.mkdtemp(prefix="vm_audit76_")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WIN = os.name == "nt"

# A message naming paths under TMP, with TMP shown as T and "/" for the
# separator, whether the path appears as it is or as a repr (an OSError's
# message quotes its filename with repr, doubling Windows' backslashes)
def tpath(text_t):
    text_t = text_t.replace(repr(TMP)[1:-1], "T").replace(TMP, "T")
    if WIN:
        text_t = text_t.replace("\\\\", "/").replace("\\", "/")
    return text_t

# Windows keeps only a read-only flag: a writable file reads 0o666 and a
# directory 0o777 whatever mode was set (as CPython reports there)
def fmode(m):
    return 0o666 if WIN else m
def dmode(m):
    return 0o777 if WIN else m

def T(*parts):
    return os.path.join(TMP, *parts)

def write_file(path_w, text_w):
    fh_w = open(path_w, "w")
    fh_w.write(text_w)
    fh_w.close()

def read_file_text(path_r):
    fh_r = open(path_r)
    text_r = fh_r.read()
    fh_r.close()
    return text_r

def rel(path_x):
    return str(path_x)[len(TMP):].replace("\\", "/")

class ListStream:
    # a stream that keeps what is written (log handlers, test runners)
    def __init__(self):
        self.parts = []
    def write(self, s):
        self.parts.append(s)
    def flush(self):
        pass
    def getvalue(self):
        return "".join(self.parts)

# ── engine fixes ─────────────────────────────────────────────────────────────
check("not binds looser than <", not 1 < 0, True)
check("not binds looser than in", not 5 in [1, 2], True)
check("not binds looser than ==", not 2 == 3, True)
check("not and", not 1 == 1 and True, False)
check("not or", not 1 == 2 or False, True)
def va_args(*va):
    return va
class VaHolder:
    def get(self, *va):
        return va
check("*args is a tuple", [va_args(1, 2), va_args(), VaHolder().get(3), "%s-%s" % va_args("a", "b"),
                           type(va_args(1)).__name__ == type((1,)).__name__], [(1, 2), (), (3,), "a-b", True])
check("lambda *args is a tuple", (lambda *va: va)(1, 2), (1, 2))
def gen_va(*va):
    yield va
check("generator *args is a tuple", list(gen_va(1, 2)), [(1, 2)])
class CmBase:
    @classmethod
    def who(cls, suffix=""):
        return cls.__name__ + suffix
class CmChild(CmBase):
    pass
cm_value = CmChild.who
check("classmethod read as a value", [getattr(CmChild, "who")(), cm_value("!"), getattr(CmChild(), "who")(), CmBase.who()],
      ["CmChild", "CmChild!", "CmChild", "CmBase"])
os.makedirs(T("mk", "a"), exist_ok=True)
os.makedirs(T("mk", "a"), exist_ok=True)
check("os.makedirs exist_ok through the namespace", os.path.isdir(T("mk", "a")), True)
os.utime(T("mk", "a"), (1000000000, 1000000000))
check("os.utime", os.path.getmtime(T("mk", "a")), 1000000000.0)
write_file(T("mk", "f.txt"), "pathlike")
fh_p = open(Path(T("mk", "f.txt")))
check("open(Path)", [fh_p.read(), fh_p.name == T("mk", "f.txt")], ["pathlike", True])
fh_p.close()
check("os.listdir(Path)", sorted(os.listdir(Path(T("mk")))), ["a", "f.txt"])
check("os.path.join(Path, str)", rel(os.path.join(Path(TMP), "q")), "/q")
check("os.path.exists(Path)", os.path.exists(Path(T("mk", "f.txt"))), True)
class OpenMember:
    def open(self, mode="r"):
        return "member"
    def use_builtin(self, flag=True):
        fh_b = open(T("mk", "f.txt"))
        text_b = fh_b.read()
        fh_b.close()
        return text_b
om_value = OpenMember().use_builtin
check("method called as a value: builtins, not class members", [om_value(), om_value(flag=False), getattr(OpenMember(), "use_builtin")()],
      ["pathlike", "pathlike", "pathlike"])

# ── fnmatch ──────────────────────────────────────────────────────────────────
fn_names = ["", "a", "abc", "a.txt", "ab", "aXbYc", "x9", "]", "!", "-", "[", "a[b", "a\nb", "f.c", "f.h", ".hid", "^"]
fn_pats = ["*", "*.txt", "a*b*c", "?", "[abc]", "[!abc]", "[a-c]*", "[]]", "[!]]", "[a-]", "[z-a]", "[!]",
           "[", "a[", "*[0-9]", "**a**", "*.[ch]", "[!.]*", "[^a]", "a?b", "[a-cx-z]?"]
fn_rows = []
for fp in fn_pats:
    fn_rows.append("".join(["1" if fnmatch.fnmatchcase(nm, fp) else "0" for nm in fn_names]))
check("fnmatchcase table", fn_rows,
      ['11111111111111111', '00010000000000000', '00100100000000000', '01000001111000001',
       '01000000000000000', '00000001111000001', '01111100000110000', '00000001000000000',
       '01000000111000001', '01000000010000000', '00000000000000000', '00000000000000000',
       '00000000001000000', '00000000000000000', '00000010000000000', '01111100000110000',
       '00000000000001100', '01111111111111101', '01000000000000001', '00000000000110000',
       '00001010000000000'])
check("fnmatch.filter", fnmatch.filter(["a.py", "b.txt", "c.py", "d.PY"], "*.py"),
      ["a.py", "c.py"] if os.name != "nt" else ["a.py", "c.py", "d.PY"])
check("fnmatch normcase", fnmatch.fnmatch("A.TXT", "*.txt"), os.name == "nt")
check("fnmatch translate", [fnmatch.translate("*.txt"), fnmatch.translate("a*b*c"),
                            fnmatch.translate("[!a-c]?"), fnmatch.translate("[a-]x")],
      ['(?s:.*\\.txt)\\Z', '(?s:a(?>.*?b).*c)\\Z', '(?s:[^a-c].)\\Z', '(?s:[a\\-]x)\\Z'])
check("fnmatch bytes", fnmatch.fnmatchcase(b"abc", b"a*"), True)
check("fnmatch mixed types", raises(fnmatch.fnmatchcase, "abc", b"a*"), "TypeError")

# ── glob ─────────────────────────────────────────────────────────────────────
for gd in ["g/a/b/c", "g/x", "g/.hid/sub"]:
    os.makedirs(T(*gd.split("/")))
for gf in ["g/a/1.txt", "g/a/2.py", "g/a/b/3.txt", "g/a/b/c/4.txt", "g/x/.dot.txt",
           "g/top.txt", "g/.hid/h.txt", "g/.hid/sub/s.txt", "g/a[1].txt"]:
    write_file(T(*gf.split("/")), "x")
GROOT = T("g")

def gl(pattern_g, **kw_g):
    return sorted([p_g.replace("\\", "/") for p_g in glob.glob(pattern_g, root_dir=GROOT, **kw_g)])

check("glob *", gl("*"), ["a", "a[1].txt", "top.txt", "x"])
check("glob * include_hidden", gl("*", include_hidden=True), [".hid", "a", "a[1].txt", "top.txt", "x"])
check("glob .*", gl(".*"), [".hid"])
check("glob */", gl("*/"), ["a/", "x/"])
check("glob deep", gl("*/*/*.txt"), ["a/b/3.txt"])
check("glob ** recursive", gl("**", recursive=True),
      ["a", "a/1.txt", "a/2.py", "a/b", "a/b/3.txt", "a/b/c", "a/b/c/4.txt", "a[1].txt", "top.txt", "x"])
check("glob **/ recursive", gl("**/", recursive=True), ["a/", "a/b/", "a/b/c/", "x/"])
check("glob **/*.txt", gl("**/*.txt", recursive=True), ["a/1.txt", "a/b/3.txt", "a/b/c/4.txt", "a[1].txt", "top.txt"])
check("glob **/*.txt hidden", gl("**/*.txt", recursive=True, include_hidden=True),
      [".hid/h.txt", ".hid/sub/s.txt", "a/1.txt", "a/b/3.txt", "a/b/c/4.txt", "a[1].txt", "top.txt", "x/.dot.txt"])
check("glob ** not recursive", gl("**/*.txt"), ["a/1.txt"])
check("glob literal", [gl("top.txt"), gl("nope.txt"), gl("a/")], [["top.txt"], [], ["a/"]])
check("glob escape", [gl(glob.escape("a[1].txt")), gl("a[1].txt"), glob.escape("a*b?c[d]")],
      [["a[1].txt"], [], "a[*]b[?]c[[]d]"])
check("glob has_magic", [glob.has_magic("a*"), glob.has_magic("abc"), glob.has_magic("[x]")], [True, False, True])
check("glob absolute", sorted([rel(p_a) for p_a in glob.glob(os.path.join(GROOT, "a", "*.py"))]), ["/g/a/2.py"])
check("iglob", sorted([p_i.replace("\\", "/") for p_i in glob.iglob("a/b/*", root_dir=GROOT)]), ["a/b/3.txt", "a/b/c"])
check("glob ?", gl("?op.txt"), ["top.txt"])

# ── shutil ───────────────────────────────────────────────────────────────────
os.makedirs(T("sh"))
write_file(T("sh", "a.txt"), "hello")
os.chmod(T("sh", "a.txt"), 0o640)
os.utime(T("sh", "a.txt"), (1500000000, 1500000000))
check("copyfile", [rel(shutil.copyfile(T("sh", "a.txt"), T("sh", "b.txt"))), read_file_text(T("sh", "b.txt"))],
      ["/sh/b.txt", "hello"])
check("copyfile does not copy times", os.path.getmtime(T("sh", "b.txt")) != 1500000000.0, True)
os.makedirs(T("sh", "d"))
check("copy into dir", rel(shutil.copy(T("sh", "a.txt"), T("sh", "d"))), "/sh/d/a.txt")
check("copy copies mode", Path(T("sh", "d", "a.txt")).stat().st_mode & 0o777, fmode(0o640))
check("copy2", rel(shutil.copy2(T("sh", "a.txt"), T("sh", "d", "c2.txt"))), "/sh/d/c2.txt")
check("copy2 copies mtime", os.path.getmtime(T("sh", "d", "c2.txt")), 1500000000.0)
check("copy2 copies mode", Path(T("sh", "d", "c2.txt")).stat().st_mode & 0o777, fmode(0o640))
os.chmod(T("sh", "b.txt"), 0o600)
shutil.copymode(T("sh", "a.txt"), T("sh", "b.txt"))
check("copymode", Path(T("sh", "b.txt")).stat().st_mode & 0o777, fmode(0o640))
shutil.copystat(T("sh", "a.txt"), T("sh", "b.txt"))
check("copystat", os.path.getmtime(T("sh", "b.txt")), 1500000000.0)
check("SameFileError", tpath(raises_msg(shutil.copyfile, T("sh", "a.txt"), T("sh", "a.txt"))),
      "SameFileError: 'T/sh/a.txt' and 'T/sh/a.txt' are the same file")
check("SameFileError hierarchy", [issubclass(shutil.SameFileError, shutil.Error), issubclass(shutil.Error, OSError)], [True, True])
check("copyfile missing", tpath(raises_msg(shutil.copyfile, T("sh", "missing"), T("sh", "x"))),
      "FileNotFoundError: [Errno 2] No such file or directory: 'T/sh/missing'")
check("copyfile to dir", raises(shutil.copyfile, T("sh", "a.txt"), T("sh", "d")), "IsADirectoryError")
check("copyfile to missing dir", raises(shutil.copyfile, T("sh", "a.txt"), T("sh", "nodir", "x")), "FileNotFoundError")
os.makedirs(T("sh", "src", "sub"))
write_file(T("sh", "src", "x.py"), "x")
write_file(T("sh", "src", "y.pyc"), "y")
write_file(T("sh", "src", "sub", "z.txt"), "z")
check("copytree", rel(shutil.copytree(T("sh", "src"), T("sh", "dst"))), "/sh/dst")
tree_files = []
for walk_root, walk_dirs, walk_files in os.walk(T("sh", "dst")):
    for walk_f in walk_files:
        tree_files.append(rel(os.path.join(walk_root, walk_f)))
check("copytree contents", sorted(tree_files), ["/sh/dst/sub/z.txt", "/sh/dst/x.py", "/sh/dst/y.pyc"])
shutil.copytree(T("sh", "src"), T("sh", "dst2"), ignore=shutil.ignore_patterns("*.pyc", "sub"))
check("copytree ignore_patterns", sorted(os.listdir(T("sh", "dst2"))), ["x.py"])
check("copytree exists", tpath(raises_msg(shutil.copytree, T("sh", "src"), T("sh", "dst2"))),
      "FileExistsError: [Errno 17] File exists: 'T/sh/dst2'")
shutil.copytree(T("sh", "src"), T("sh", "dst2"), dirs_exist_ok=True)
check("copytree dirs_exist_ok", sorted(os.listdir(T("sh", "dst2"))), ["sub", "x.py", "y.pyc"])
check("ignore_patterns", sorted(shutil.ignore_patterns("*.c", "a*")("/x", ["a.c", "b.c", "ab", "z"])), ["a.c", "ab", "b.c"])
shutil.rmtree(T("sh", "dst"))
check("rmtree", os.path.exists(T("sh", "dst")), False)
check("rmtree missing", tpath(raises_msg(shutil.rmtree, T("sh", "dst"))),
      "FileNotFoundError: [Errno 2] No such file or directory: 'T/sh/dst'")
shutil.rmtree(T("sh", "dst"), ignore_errors=True)
rm_errors = []
def rm_onerror(func_e, path_e, exc_info_e):
    rm_errors.append([tpath(path_e), exc_info_e[0].__name__])
shutil.rmtree(T("sh", "dst"), onerror=rm_onerror)
check("rmtree onerror", rm_errors, [["T/sh/dst", "FileNotFoundError"]])
check("rmtree file", raises(shutil.rmtree, T("sh", "a.txt")), "NotADirectoryError")
check("move file", [rel(shutil.move(T("sh", "b.txt"), T("sh", "moved.txt"))), os.path.exists(T("sh", "b.txt"))],
      ["/sh/moved.txt", False])
check("move into dir", rel(shutil.move(T("sh", "moved.txt"), T("sh", "d"))), "/sh/d/moved.txt")
write_file(T("sh", "dup.txt"), "1")
write_file(T("sh", "d", "dup.txt"), "2")
check("move exists", tpath(raises_msg(shutil.move, T("sh", "dup.txt"), T("sh", "d"))),
      "Error: Destination path 'T/sh/d/dup.txt' already exists")
check("move dir", [rel(shutil.move(T("sh", "dst2"), T("sh", "dst3"))), sorted(os.listdir(T("sh", "dst3")))],
      ["/sh/dst3", ["sub", "x.py", "y.pyc"]])
check("move into itself", tpath(raises_msg(shutil.move, T("sh", "dst3"), T("sh", "dst3", "inner"))),
      "Error: Cannot move a directory 'T/sh/dst3' into itself 'T/sh/dst3/inner'.")
du = shutil.disk_usage(TMP)
check("disk_usage", [du.total > 0, du.free >= 0, du.used >= 0, len(du), du[0] == du.total, type(du).__name__, repr(du).startswith("usage(total=")],
      [True, True, True, 3, True, "usage", True])
# a path is returned when it is executable: any existing file on Windows,
# where PATHEXT (not a mode bit) makes a name a command
check("which", [shutil.which("cmd" if WIN else "sh") is not None, shutil.which("definitely-not-a-cmd-zz"), shutil.which(T("sh", "a.txt"))],
      [True, None, T("sh", "a.txt") if WIN else None])
os.chmod(T("sh", "a.txt"), 0o755)
if WIN:
    write_file(T("sh", "tool.bat"), "@echo off\n")
    check("which path=", (shutil.which("tool", path=T("sh")) or "").lower() == T("sh", "tool.bat").lower(), True)
else:
    check("which path=", shutil.which("a.txt", path=T("sh")) == T("sh", "a.txt"), True)
term = shutil.get_terminal_size((99, 33))
check("get_terminal_size", [len(term), term.columns > 0, term.lines > 0, term[0] == term.columns], [2, True, True, True])
check("archive formats", "tar" in [fmt[0] for fmt in shutil.get_archive_formats()], True)
os.makedirs(T("arc", "pkg", "inner"))
write_file(T("arc", "pkg", "one.txt"), "one")
write_file(T("arc", "pkg", "inner", "two.txt"), "two")
arc_name = shutil.make_archive(T("arc", "out"), "tar", root_dir=T("arc"), base_dir="pkg")
check("make_archive", rel(arc_name), "/arc/out.tar")
shutil.unpack_archive(arc_name, T("arc", "unpacked"))
check("unpack_archive", [read_file_text(T("arc", "unpacked", "pkg", "one.txt")),
                         read_file_text(T("arc", "unpacked", "pkg", "inner", "two.txt"))], ["one", "two"])
check("unknown archive format", raises(shutil.make_archive, T("arc", "x"), "nope"), "ValueError")

# ── tempfile ─────────────────────────────────────────────────────────────────
check("gettempdir", [isinstance(tempfile.gettempdir(), str), os.path.isdir(tempfile.gettempdir())], [True, True])
check("gettempprefix", tempfile.gettempprefix(), "tmp")
td = tempfile.mkdtemp(prefix="pre_", suffix="_suf", dir=TMP)
check("mkdtemp", [os.path.isdir(td), os.path.basename(td).startswith("pre_"), td.endswith("_suf"),
                  os.path.isabs(td), os.path.dirname(td) == TMP], [True, True, True, True, True])
check("mkdtemp mode", Path(td).stat().st_mode & 0o777, dmode(0o700))
mk_fd, mk_path = tempfile.mkstemp(suffix=".dat", prefix="ms_", dir=TMP)
check("mkstemp", [isinstance(mk_fd, int), os.path.isfile(mk_path), os.path.basename(mk_path).startswith("ms_"),
                  mk_path.endswith(".dat"), os.path.getsize(mk_path)], [True, True, True, True, 0])
check("mkstemp mode", Path(mk_path).stat().st_mode & 0o777, fmode(0o600))
try:
    os.close(mk_fd)
except AttributeError:
    file_close(mk_fd)        # Nython: a file handle (see lib/tempfile.ny)
with tempfile.TemporaryDirectory(dir=TMP) as tdir:
    write_file(os.path.join(tdir, "f"), "x")
    tdir_seen = [os.path.isdir(tdir), os.path.exists(os.path.join(tdir, "f"))]
check("TemporaryDirectory", [tdir_seen, os.path.exists(tdir)], [[True, True], False])
tdo = tempfile.TemporaryDirectory(prefix="keep_", dir=TMP)
check("TemporaryDirectory repr", [repr(tdo).startswith("<TemporaryDirectory '"), os.path.basename(tdo.name).startswith("keep_")], [True, True])
tdo.cleanup()
check("TemporaryDirectory cleanup", os.path.exists(tdo.name), False)
ntf = tempfile.NamedTemporaryFile(dir=TMP, suffix=".bin")
ntf.write(b"abc")
ntf.seek(0)
check("NamedTemporaryFile", [ntf.read(), os.path.exists(ntf.name), ntf.name.endswith(".bin")], [b"abc", True, True])
ntf_name = ntf.name
ntf.close()
check("NamedTemporaryFile delete", os.path.exists(ntf_name), False)
with tempfile.NamedTemporaryFile("w+", dir=TMP, delete=False) as ntf2:
    ntf2.write("text")
    ntf2_name = ntf2.name
check("NamedTemporaryFile delete=False", read_file_text(ntf2_name), "text")
with tempfile.NamedTemporaryFile(mode="w+", dir=TMP) as ntf3:
    ntf3.write("line1\nline2\n")
    ntf3.seek(0)
    ntf3_lines = ntf3.readlines()
    ntf3_name = ntf3.name
check("NamedTemporaryFile text", [ntf3_lines, os.path.exists(ntf3_name)], [["line1\n", "line2\n"], False])
with tempfile.TemporaryFile(dir=TMP) as tf:
    tf.write(b"temp")
    tf.seek(0)
    check("TemporaryFile", tf.read(), b"temp")
spool = tempfile.SpooledTemporaryFile(max_size=10, mode="w+")
spool.write("small")
spool_small = spool._rolled
spool.write(" and now bigger")
spool.seek(0)
check("SpooledTemporaryFile", [spool_small, spool._rolled, spool.read()], [False, True, "small and now bigger"])
spool.close()

# ── pathlib ──────────────────────────────────────────────────────────────────
PP = PurePosixPath
WP = PureWindowsPath
pp = PP("/usr/lib/python3.tar.gz")
check("pure parts", [pp.parts, pp.drive, pp.root, pp.anchor, pp.name, pp.stem, pp.suffix, pp.suffixes],
      [("/", "usr", "lib", "python3.tar.gz"), "", "/", "/", "python3.tar.gz", "python3.tar", ".gz", [".tar", ".gz"]])
check("pure parent(s)", [str(pp.parent), [str(x) for x in pp.parents], str(pp.parents[-1]), len(PP("a/b").parents)],
      ["/usr/lib", ["/usr/lib", "/usr", "/"], "/", 2])
check("pure normalising", [str(PP("a//b/./c/")), str(PP("//a/b")), str(PP("///a")), str(PP("")), str(PP("a/../b"))],
      ["a/b/c", "//a/b", "/a", ".", "a/../b"])
check("pure / operator", [str(PP("a") / "b" / "c"), str("x" / PP("y")), str(PP("/a") / "/b"), str(PP("a").joinpath("b", "c"))],
      ["a/b/c", "x/y", "/b", "a/b/c"])
check("pure with_*", [str(PP("a/b.txt").with_name("c.py")), str(PP("a/b.txt").with_suffix(".md")),
                      str(PP("a/b.txt").with_stem("z")), str(PP("a/b.tar.gz").with_suffix(""))],
      ["a/c.py", "a/b.md", "a/z.txt", "a/b.tar"])
check("pure with_* errors", [raises(PP("").with_name, "x"), raises(PP("a").with_suffix, "b"), raises(PP("a").with_name, "x/y")],
      ["ValueError", "ValueError", "ValueError"])
check("relative_to", [str(PP("/a/b/c").relative_to("/a")), raises(PP("/a/b").relative_to, "/c"),
                      PP("/a/b").is_relative_to("/a"), PP("/a/b").is_relative_to("/c")],
      ["b/c", "ValueError", True, False])
check("match", [PP("a/b.py").match("*.py"), PP("/a/b/c.py").match("b/*.py"), PP("/a/b/c.py").match("/*.py"),
                PP("a/b.py").match("a/*.py"), WP("A/B.PY").match("*.py")], [True, True, False, True, True])
check("equality/order", [PP("a") == PP("a"), PP("a") == PP("b"), WP("A") == WP("a"), PP("a") == WP("a"),
                         PP("a") < PP("b"), [str(x) for x in sorted([PP("b"), PP("a/c"), PP("a")])]],
      [True, False, True, False, True, ["a", "a/c", "b"]])
check("hash", [hash(PP("a/b")) == hash(PP("a/b")), len(set([PP("a"), PP("a"), PP("b")]))], [True, 2])
check("repr/str", [repr(PP("a/b")), repr(WP("c:/x")), PP("a/b").as_posix(), WP("a\\b").as_posix(), PP("a").__fspath__()],
      ["PurePosixPath('a/b')", "PureWindowsPath('c:/x')", "a/b", "a/b", "a"])
check("as_uri", [PP("/a b/c").as_uri(), WP("c:/x y/z").as_uri(), raises(PP("a").as_uri)],
      ["file:///a%20b/c", "file:///c:/x%20y/z", "ValueError"])
wp = WP("C:/Users/me.txt")
check("windows flavour", [str(wp), wp.parts, wp.drive, wp.root, wp.is_absolute(), WP("c:a").is_absolute(),
                          str(WP("\\\\server\\share\\x").parent), WP("nul").is_reserved(), str(WP("c:\\a") / "d:b")],
      ["C:\\Users\\me.txt", ("C:\\", "Users", "me.txt"), "C:", "\\", True, False, "\\\\server\\share\\", True, "d:b"])
pbase = Path(TMP) / "pl"
pbase.mkdir()
check("Path type", [type(pbase).__name__ in ["PosixPath", "WindowsPath"], isinstance(pbase, Path),
                    isinstance(pbase, pathlib.PurePath), pbase.exists(), pbase.is_dir(), pbase.is_file()],
      [True, True, True, True, True, False])
pf = pbase / "a.txt"
check("write_text/read_text", [pf.write_text("hello\nworld\n"), pf.read_text(), pf.stat().st_size, pf.is_file()],
      [12, "hello\nworld\n", 14 if WIN else 12, True])
check("write_bytes/read_bytes", [pf.write_bytes(b"\x00\x01"), pf.read_bytes()], [2, b"\x00\x01"])
check("write_text type", raises(pf.write_text, b"x"), "TypeError")
(pbase / "sub" / "deep").mkdir(parents=True)
(pbase / "sub" / "x.py").write_text("x")
(pbase / "sub" / "deep" / "y.py").write_text("y")
(pbase / "sub" / ".h.py").write_text("h")
check("iterdir", sorted([rel(x) for x in pbase.iterdir()]), ["/pl/a.txt", "/pl/sub"])
check("Path.glob", sorted([rel(x) for x in pbase.glob("sub/*.py")]), ["/pl/sub/.h.py", "/pl/sub/x.py"])
check("Path.rglob", sorted([rel(x) for x in pbase.rglob("*.py")]), ["/pl/sub/.h.py", "/pl/sub/deep/y.py", "/pl/sub/x.py"])
check("Path.glob **", sorted([rel(x) for x in pbase.glob("**/*.py")]), ["/pl/sub/.h.py", "/pl/sub/deep/y.py", "/pl/sub/x.py"])
check("Path.glob */", sorted([rel(x) for x in pbase.glob("*/")]), ["/pl/sub"])
check("mkdir exists", tpath(raises_msg((pbase / "sub").mkdir)), "FileExistsError: [Errno 17] File exists: 'T/pl/sub'")
(pbase / "sub").mkdir(exist_ok=True)
check("mkdir no parent", tpath(raises_msg((pbase / "nope" / "x").mkdir)),
      "FileNotFoundError: [Errno 2] No such file or directory: 'T/pl/nope/x'")
check("unlink missing", raises((pbase / "missing").unlink), "FileNotFoundError")
(pbase / "missing").unlink(missing_ok=True)
pg = pbase / "g.txt"
pg.touch()
check("touch", [pg.exists(), pg.read_text()], [True, ""])
check("touch exist_ok=False", raises(pg.touch, exist_ok=False), "FileExistsError")
ph = pg.rename(pbase / "h.txt")
check("rename", [rel(ph), pg.exists(), ph.exists()], ["/pl/h.txt", False, True])
ph2 = ph.replace(pbase / "a.txt")
check("replace", [rel(ph2), (pbase / "a.txt").read_text()], ["/pl/a.txt", ""])
check("rename missing", tpath(raises_msg((pbase / "zz").rename, pbase / "yy")),
      "FileNotFoundError: [Errno 2] No such file or directory: 'T/pl/zz' -> 'T/pl/yy'")
check("resolve", rel(Path(str(pbase) + "/sub/../a.txt").resolve()), "/pl/a.txt")
check("absolute", [Path("rel_x").absolute().is_absolute(), Path("rel_x").absolute().name], [True, "rel_x"])
check("cwd/home/expanduser", [Path.cwd() == Path(os.getcwd()), Path.home() == Path(os.path.expanduser("~")),
                              Path("~/x").expanduser() == Path(os.path.expanduser("~/x"))], [True, True, True])
check("samefile", (pbase / "a.txt").samefile(str(pbase) + "/sub/../a.txt"), True)
def can_symlink(d):
    # as CPython's test.support.os_helper.can_symlink: Windows without
    # developer mode (and Wine, whose CreateSymbolicLinkW makes nothing)
    # cannot create one
    probe = os.path.join(d, "symlink_probe")
    try:
        os.symlink(os.path.join(d, "a.txt"), probe)
    except OSError:
        return False
    made = os.path.islink(probe)
    if made:
        os.remove(probe)
    return made
has_link = can_symlink(str(pbase))
if has_link:
    os.symlink(str(pbase / "a.txt"), str(pbase / "link"))
    check("symlink", [(pbase / "link").is_symlink(), (pbase / "link").exists(), rel((pbase / "link").readlink()),
                      rel((pbase / "link").resolve())], [True, True, "/pl/a.txt", "/pl/a.txt"])
else:
    check("symlink (none can be made here)", True, True)
check("rmdir non-empty", raises((pbase / "sub").rmdir), "OSError")
with (pbase / "o.txt").open("w") as fh_o:
    fh_o.write("abc")
check("Path.open", (pbase / "o.txt").open().read(), "abc")
# a file dropped without close() is closed when its last reference goes
# (round 77: it stayed open, and Windows cannot delete an open file)
if os.path.isdir("/proc/self/fd"):
    n_fds = len(os.listdir("/proc/self/fd"))
    for _ in range(40):
        (pbase / "o.txt").open().read()
    check("dropped files are closed", len(os.listdir("/proc/self/fd")) - n_fds <= 1, True)
else:
    check("dropped files are closed (no /proc here)", True, True)
st_o = (pbase / "o.txt").stat()
check("stat result", [st_o.st_size, st_o[6], len(st_o)], [3, 3, 10])
if hasattr(Path, "walk"):
    walked = sorted([(rel(w[0]), sorted(w[1]), sorted(w[2])) for w in pbase.walk()])
else:
    walked = sorted([(rel(w[0]), sorted(w[1]), sorted(w[2])) for w in os.walk(str(pbase))])
check("walk", walked, [("/pl", ["sub"], ["a.txt", "link", "o.txt"] if has_link else ["a.txt", "o.txt"]), ("/pl/sub", ["deep"], [".h.py", "x.py"]),
                       ("/pl/sub/deep", [], ["y.py"])])
check("other flavour", raises(pathlib.WindowsPath if os.name != "nt" else pathlib.PosixPath, "x"), "NotImplementedError")

# ── subprocess ───────────────────────────────────────────────────────────────
# Portable children: this interpreter itself (sys.executable -c ...), so
# these run on Windows too, where there is no sh/cat/printf on PATH.
def py_child(code):
    return [sys.executable, "-c", code]
cp_p = subprocess.run(py_child("import sys\nprint('out')\nprint('err', file=sys.stderr)\nsys.exit(3)"),
                      capture_output=True, text=True, cwd=REPO)
check("portable run capture", [cp_p.returncode, cp_p.stdout, cp_p.stderr], [3, "out\n", "err\n"])
check("portable run input", subprocess.run(py_child("import sys\nprint(sys.stdin.read().upper(), end='')"),
                                           input="abc", capture_output=True, text=True, cwd=REPO).stdout, "ABC")
check("portable check_output", subprocess.check_output(py_child("print('hi')"), text=True, cwd=REPO), "hi\n")
portable_cpe = None
try:
    subprocess.run(py_child("import sys\nsys.exit(2)"), check=True, capture_output=True, cwd=REPO)
except subprocess.CalledProcessError as e_pcpe:
    portable_cpe = e_pcpe.returncode
check("portable CalledProcessError", portable_cpe, 2)
po_p = subprocess.Popen(py_child("import sys\nx = input()\nprint('got ' + x)\nsys.exit(7)"),
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, cwd=REPO)
po_out, po_err = po_p.communicate("hello\n")
check("portable Popen communicate", [po_out, po_p.returncode], ["got hello\n", 7])
portable_to = "no timeout"
try:
    subprocess.run(py_child("import time\ntime.sleep(5)"), timeout=0.5, cwd=REPO)
except subprocess.TimeoutExpired:
    portable_to = "TimeoutExpired"
check("portable timeout", portable_to, "TimeoutExpired")

# The POSIX tools (sh, cat, printf, pwd, sleep, true/false) and signal
# numbers: not on Windows, as CPython's test_subprocess skips them there.
if os.name != "nt" and shutil.which("sh") is not None:
    cp = subprocess.run(["sh", "-c", "echo out; echo err 1>&2; exit 3"], capture_output=True)
    check("run capture", [cp.returncode, cp.stdout, cp.stderr, cp.args], [3, b"out\n", b"err\n", ["sh", "-c", "echo out; echo err 1>&2; exit 3"]])
    check("CompletedProcess repr", repr(subprocess.run(["sh", "-c", "exit 0"])), "CompletedProcess(args=['sh', '-c', 'exit 0'], returncode=0)")
    check("run text", subprocess.run(["sh", "-c", "printf 'a\\r\\nb\\rc'"], capture_output=True, text=True).stdout, "a\nb\nc")
    check("run bytes", subprocess.run(["printf", "a\\377"], stdout=subprocess.PIPE).stdout, b"a\xff")
    check("run input", subprocess.run(["cat"], input="h\u00e9", capture_output=True, text=True).stdout, "h\u00e9")
    check("run input bytes", subprocess.run(["cat"], input=b"xy", capture_output=True).stdout, b"xy")
    check("run input str without text", raises(subprocess.run, ["cat"], input="x", capture_output=True), "TypeError")
    check("run stderr=STDOUT", subprocess.run(["sh", "-c", "echo out; echo err 1>&2"], stdout=subprocess.PIPE,
                                              stderr=subprocess.STDOUT, text=True).stdout, "out\nerr\n")
    check("run DEVNULL", subprocess.run(["sh", "-c", "echo x"], stdout=subprocess.DEVNULL).stdout, None)
    check("run shell", subprocess.run("echo $((6*7))", shell=True, capture_output=True, text=True).stdout, "42\n")
    check("run cwd", subprocess.run(["pwd"], cwd=TMP, capture_output=True, text=True).stdout.strip(), os.path.realpath(TMP))
    check("run env replaces", subprocess.run(["sh", "-c", "echo $FOO-$VM76_UNSET"],
                                             env={"FOO": "bar", "PATH": os.environ.get("PATH", "/bin:/usr/bin")},
                                             capture_output=True, text=True).stdout, "bar-\n")
    cpe = None
    try:
        subprocess.run(["sh", "-c", "echo partial; exit 2"], capture_output=True, check=True)
    except subprocess.CalledProcessError as e_cpe:
        cpe = e_cpe
    check("CalledProcessError", [cpe.returncode, cpe.cmd, cpe.output, cpe.stdout, cpe.stderr, str(cpe)],
          [2, ["sh", "-c", "echo partial; exit 2"], b"partial\n", b"partial\n", b"",
           "Command '['sh', '-c', 'echo partial; exit 2']' returned non-zero exit status 2."])
    check("CalledProcessError hierarchy", [issubclass(subprocess.CalledProcessError, subprocess.SubprocessError),
                                           issubclass(subprocess.TimeoutExpired, subprocess.SubprocessError)], [True, True])
    check("CalledProcessError signal", str(subprocess.CalledProcessError(-9, "cmd")), "Command 'cmd' died with <Signals.SIGKILL: 9>.")
    toe = None
    try:
        subprocess.run(["sleep", "5"], timeout=0.2)
    except subprocess.TimeoutExpired as e_to:
        toe = e_to
    check("TimeoutExpired", [toe.cmd, 0.1 <= toe.timeout <= 0.2, str(toe)[:len("Command '['sleep', '5']' timed out after 0.")]],
          [["sleep", "5"], True, "Command '['sleep', '5']' timed out after 0."])
    check("missing program", raises_msg(subprocess.run, ["no-such-program-vm76"]),
          "FileNotFoundError: [Errno 2] No such file or directory: 'no-such-program-vm76'")
    check("check_output", subprocess.check_output(["echo", "hi"]), b"hi\n")
    check("check_output text", subprocess.check_output(["sh", "-c", "echo hi"], text=True), "hi\n")
    check("check_output fails", raises(subprocess.check_output, ["sh", "-c", "exit 1"]), "CalledProcessError")
    check("check_call", [subprocess.check_call(["true"]), raises(subprocess.check_call, ["false"])], [0, "CalledProcessError"])
    check("call", subprocess.call(["sh", "-c", "exit 5"]), 5)
    check("getoutput", subprocess.getoutput("echo hi; echo err >&2"), "hi\nerr")
    check("getstatusoutput", [subprocess.getstatusoutput("exit 4"), subprocess.getstatusoutput("echo ok")], [(4, ""), (0, "ok")])
    check("list2cmdline", subprocess.list2cmdline(["a b", "c\"d", "e\\", ""]), "\"a b\" c\\\"d e\\ \"\"")
    fh_sp = open(T("sp_out.txt"), "w")
    subprocess.run(["echo", "to file"], stdout=fh_sp)
    fh_sp.close()
    check("run stdout=file", read_file_text(T("sp_out.txt")), "to file\n")
    check("run Path arg", subprocess.run(["cat", Path(T("sp_out.txt"))], capture_output=True).stdout, b"to file\n")
    inh = subprocess.run([sys.executable, "-c", "import subprocess\nsubprocess.run(['echo', 'inherited'])\nprint('after')"],
                         capture_output=True, text=True, cwd=REPO)
    check("stdout=None is inherited", [inh.stdout, inh.returncode], ["inherited\nafter\n", 0])
    pop = subprocess.Popen(["sh", "-c", "read x; echo got $x; echo e >&2; exit 7"], stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    pop_out, pop_err = pop.communicate("hello\n")
    check("Popen communicate", [pop_out, pop_err, pop.returncode, pop.poll()], ["got hello\n", "e\n", 7, 7])
    pop2 = subprocess.Popen(["cat"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    pop2.stdin.write("l1\nl2\n")
    pop2.stdin.close()
    check("Popen pipes", [list(pop2.stdout), pop2.wait()], [["l1\n", "l2\n"], 0])
    pop3 = subprocess.Popen(["sh", "-c", "printf 'abc\\ndef'"], stdout=subprocess.PIPE)
    check("Popen read", [pop3.stdout.readline(), pop3.stdout.read(), pop3.wait()], [b"abc\n", b"def", 0])
    pop4 = subprocess.Popen(["sleep", "10"])
    check("Popen poll running", pop4.poll(), None)
    check("Popen wait timeout", raises(pop4.wait, 0.1), "TimeoutExpired")
    pop4.kill()
    check("Popen kill", pop4.wait(), -9)
    pop4.kill()
    with subprocess.Popen(["sh", "-c", "exit 3"], stdout=subprocess.PIPE) as pop5:
        pop5_out = pop5.stdout.read()
    check("Popen context manager", [pop5_out, pop5.returncode], [b"", 3])
    check("Popen repr", repr(pop5), "<Popen: returncode: 3 args: ['sh', '-c', 'exit 3']>")
check("PIPE/STDOUT/DEVNULL", [subprocess.PIPE, subprocess.STDOUT, subprocess.DEVNULL], [-1, -2, -3])

# ── platform ─────────────────────────────────────────────────────────────────
un = platform.uname()
check("uname", [len(un), un[0] == platform.system(), un.node == platform.node(), un.release == platform.release(),
                un.machine == platform.machine(), un.version == platform.version(), list(un)[:5] == [un.system, un.node, un.release, un.version, un.machine]],
      [6, True, True, True, True, True, True])
check("system", platform.system(), {"linux": "Linux", "darwin": "Darwin", "win32": "Windows"}.get(sys.platform, platform.system()))
check("platform()", [platform.platform().startswith(platform.system()), platform.platform(terse=True).startswith(platform.system()),
                     "--" not in platform.platform(), platform.platform()[-1:] != "-"], [True, True, True, True])
if sys.platform == "linux":
    check("platform linux", [platform.platform().startswith("Linux-" + platform.release()), platform.architecture()[1],
                             platform.libc_ver()[0] in ["glibc", ""]], [True, "ELF", True])
check("architecture", platform.architecture()[0] in ["32bit", "64bit"], True)
check("python_implementation", platform.python_implementation() in ["CPython", "Nython"], True)
pvt = platform.python_version_tuple()
check("python_version", [len(pvt), ".".join(pvt) == platform.python_version(), all([x.isdigit() for x in pvt])], [3, True, True])
check("machine", isinstance(platform.machine(), str) and platform.machine() != "", True)

# ── getpass ──────────────────────────────────────────────────────────────────
env_user = None
for env_name in ["LOGNAME", "USER", "LNAME", "USERNAME"]:
    if os.environ.get(env_name) and env_user is None:
        env_user = os.environ.get(env_name)
gu = getpass.getuser()
check("getuser", [isinstance(gu, str), len(gu) > 0, env_user is None or gu == env_user], [True, True, True])
check("GetPassWarning", issubclass(getpass.GetPassWarning, Exception), True)

# ── logging ──────────────────────────────────────────────────────────────────
check("levels", [logging.DEBUG, logging.INFO, logging.WARNING, logging.ERROR, logging.CRITICAL, logging.NOTSET, logging.WARN, logging.FATAL],
      [10, 20, 30, 40, 50, 0, 30, 50])
check("getLevelName", [logging.getLevelName(10), logging.getLevelName("ERROR"), logging.getLevelName(15)], ["DEBUG", 40, "Level 15"])
logging.addLevelName(25, "NOTICE")
check("addLevelName", [logging.getLevelName(25), logging.getLevelName("NOTICE")], ["NOTICE", 25])
la = logging.getLogger("vm76.a")
lab = logging.getLogger("vm76.a.b")
check("getLogger same object", logging.getLogger("vm76.a") is la, True)
check("hierarchy", [lab.parent is la, la.parent is logging.getLogger(), logging.getLogger().name, logging.getLogger() is logging.root],
      [True, True, "root", True])
lxyz = logging.getLogger("vm76.x.y.z")
lx = logging.getLogger("vm76.x")
check("placeholder fix-up", [lxyz.parent is lx, lx.parent is logging.root], [True, True])
check("getChild", [la.getChild("b") is lab, la.getChild("c.d").name], [True, "vm76.a.c.d"])
check("effective level", [la.getEffectiveLevel(), la.level, la.isEnabledFor(logging.INFO), la.isEnabledFor(logging.WARNING)],
      [30, 0, False, True])
la.setLevel("DEBUG")
check("setLevel name", [la.level, lab.getEffectiveLevel(), lab.isEnabledFor(logging.DEBUG)], [10, 10, True])
check("bad level", [raises(la.setLevel, "NOPE"), raises(la.setLevel, 1.5)], ["ValueError", "TypeError"])
ls_a = ListStream()
ha = logging.StreamHandler(ls_a)
ha.setFormatter(logging.Formatter("%(levelname)s|%(name)s|%(message)s"))
la.addHandler(ha)
la.propagate = False
lab.debug("debug %s %d", "x", 5)
la.info("info")
lab.warning("dict %(k)s", {"k": "v"})
check("handler output", ls_a.getvalue(), "DEBUG|vm76.a.b|debug x 5\nINFO|vm76.a|info\nWARNING|vm76.a.b|dict v\n")
ha.setLevel(logging.WARNING)
ls_a.parts = []
lab.info("hidden")
lab.error("shown")
check("handler level", ls_a.getvalue(), "ERROR|vm76.a.b|shown\n")
ha.setLevel(logging.NOTSET)
class OnlyB(logging.Filter):
    def filter(self, record):
        return "b" in record.getMessage()
fb = OnlyB()
ha.addFilter(fb)
ls_a.parts = []
la.info("abc")
la.info("xyz")
ha.removeFilter(fb)
check("filter object", ls_a.getvalue(), "INFO|vm76.a|abc\n")
ls_a.parts = []
la.addFilter(lambda rec: rec.levelno >= logging.ERROR)
la.warning("w")
la.error("e")
la.filters = []
check("filter callable", ls_a.getvalue(), "ERROR|vm76.a|e\n")
nf = logging.Filter("vm76.a")
check("Filter by name", [bool(nf.filter(logging.makeLogRecord({"name": "vm76.a.b"}))),
                         bool(nf.filter(logging.makeLogRecord({"name": "vm76.ab"}))),
                         bool(nf.filter(logging.makeLogRecord({"name": "vm76.a"})))], [True, False, True])
ls_a.parts = []
try:
    raise ValueError("boom")
except ValueError:
    la.exception("failed %d", 3)
exc_lines = ls_a.getvalue().strip().split("\n")
check("exception()", [exc_lines[0], exc_lines[1], exc_lines[-1]],
      ["ERROR|vm76.a|failed 3", "Traceback (most recent call last):", "ValueError: boom"])
ls_a.parts = []
la.error("with info", exc_info=KeyError("k"))
check("exc_info=exception", ls_a.getvalue().strip().split("\n")[-1], "KeyError: 'k'")
la.disabled = True
ls_a.parts = []
la.error("off")
la.disabled = False
check("disabled", ls_a.getvalue(), "")
ls_f = ListStream()
hf = logging.StreamHandler(ls_f)
la.addHandler(hf)
hf.setFormatter(logging.Formatter("{levelname}:{name}:{message}", style="{"))
la.warning("brace %s", "style")
hf.setFormatter(logging.Formatter("$" + "{levelname}-$" + "{message}", style="$"))
la.warning("dollar")
hf.setFormatter(logging.Formatter("%(levelno)d %(process)s %(threadName)s"))
la.warning("x")
check("formatter styles", ls_f.getvalue().split("\n")[:3],
      ["WARNING:vm76.a:brace style", "WARNING-dollar", "30 %d MainThread" % os.getpid()])
check("formatter validate", [raises(logging.Formatter, "%(message)", validate=True), raises(logging.Formatter, "{message", style="{"),
                             raises(logging.Formatter, "x", style="$"), raises(logging.Formatter, "x", style="?")],
      ["ValueError", "ValueError", "ValueError", "ValueError"])
la.removeHandler(hf)
fmt_t = logging.Formatter("%(asctime)s %(message)s")
fmt_t.converter = time.gmtime
rec_t = logging.makeLogRecord({"msg": "m", "created": 0.0, "msecs": 5.0})
check("formatTime", [fmt_t.formatTime(rec_t), fmt_t.formatTime(rec_t, "%Y/%m/%d %H"), fmt_t.format(rec_t)],
      ["1970-01-01 00:00:00,005", "1970/01/01 00", "1970-01-01 00:00:00,005 m"])
fmt_d = logging.Formatter("%(custom)s|%(message)s", defaults={"custom": "dflt"})
check("Formatter defaults", [fmt_d.format(logging.makeLogRecord({"msg": "m"})), fmt_d.format(logging.makeLogRecord({"msg": "m", "custom": "own"}))],
      ["dflt|m", "own|m"])
class UtcFormatter(logging.Formatter):
    converter = time.gmtime
check("converter on the class", UtcFormatter("%(asctime)s").formatTime(logging.makeLogRecord({"created": 86400.5, "msecs": 500.0})),
      "1970-01-02 00:00:00,500")
rec = logging.LogRecord("n", logging.INFO, "/p/mod.py", 7, "a %s", ("b",), None)
check("LogRecord", [rec.getMessage(), rec.levelname, rec.filename, rec.module, rec.lineno, rec.process == os.getpid(),
                    0 <= rec.msecs < 1000, rec.thread == threading.get_ident(), rec.threadName, repr(rec)],
      ["a b", "INFO", "mod.py", "mod", 7, True, True, True, "MainThread", '<LogRecord: n, 20, /p/mod.py, 7, "a %s">'])
ad = logging.LoggerAdapter(la, {"user": "ann"})
ls_ad = ListStream()
had = logging.StreamHandler(ls_ad)
had.setFormatter(logging.Formatter("%(user)s %(message)s"))
la.addHandler(had)
ad.info("hello %s", "there")
check("LoggerAdapter", [ls_ad.getvalue(), ad.name, ad.getEffectiveLevel()], ["ann hello there\n", "vm76.a", 10])
la.removeHandler(had)
check("extra overwrite", raises(la.info, "m", extra={"message": 1}), "KeyError")
log_path = T("log.txt")
fh_log = logging.FileHandler(log_path, mode="w", delay=True)
check("FileHandler delay", os.path.exists(log_path), False)
fh_log.setFormatter(logging.Formatter("%(message)s"))
la.addHandler(fh_log)
la.warning("to file")
la.removeHandler(fh_log)
fh_log.close()
check("FileHandler", [read_file_text(log_path), fh_log.baseFilename == os.path.abspath(log_path)], ["to file\n", True])
ls_root = ListStream()
logging.basicConfig(stream=ls_root, level=logging.INFO, format="%(levelname)s:%(name)s:%(message)s", force=True)
logging.info("root info")
logging.debug("root debug")
logging.getLogger("vm76.prop").warning("propagated")
check("basicConfig", ls_root.getvalue(), "INFO:root:root info\nWARNING:vm76.prop:propagated\n")
check("basicConfig errors", [raises(logging.basicConfig, stream=ls_root, filename="x", force=True),
                             raises(logging.basicConfig, nonsense=1, force=True)], ["ValueError", "ValueError"])
logging.basicConfig(stream=ls_root, force=True)
ls_root.parts = []
logging.warning("basic format")
check("BASIC_FORMAT", [ls_root.getvalue(), logging.BASIC_FORMAT], ["WARNING:root:basic format\n", "%(levelname)s:%(name)s:%(message)s"])
logging.disable(logging.WARNING)
ls_root.parts = []
logging.warning("disabled")
logging.error("enabled")
logging.disable(logging.NOTSET)
check("disable", ls_root.getvalue(), "ERROR:root:enabled\n")
check("lastResort", [logging.lastResort.level, logging.getLogger("vm76.none").hasHandlers()], [30, True])
nh = logging.NullHandler()
lnull = logging.getLogger("vm76.null")
lnull.addHandler(nh)
lnull.propagate = False
lnull.error("nothing")
check("NullHandler", [lnull.hasHandlers(), repr(lnull)], [True, "<Logger vm76.null (INFO)>"])
check("handler repr", [repr(logging.StreamHandler(ls_root)).startswith("<StreamHandler "), repr(logging.NullHandler())],
      [True, "<NullHandler (NOTSET)>"])
logging.basicConfig(force=True, handlers=[logging.NullHandler()])

# ── unittest ─────────────────────────────────────────────────────────────────
ut_log = []

class UtSample(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        ut_log.append("setUpClass")
    @classmethod
    def tearDownClass(cls):
        ut_log.append("tearDownClass")
    def setUp(self):
        ut_log.append("setUp")
        self.addCleanup(ut_log.append, "cleanup")
    def tearDown(self):
        ut_log.append("tearDown")
    def test_a_ok(self):
        """First line of the doc.

        More."""
        self.assertEqual(1 + 1, 2)
    def test_b_fail(self):
        self.assertEqual([1, 2, 3], [1, 2, 4])
    def test_c_error(self):
        raise KeyError("oops")
    @unittest.skip("not now")
    def test_d_skip(self):
        pass
    @unittest.expectedFailure
    def test_e_xfail(self):
        self.assertTrue(False)
    def test_f_subtests(self):
        for sub_i in range(3):
            with self.subTest(i=sub_i):
                self.assertNotEqual(sub_i, 1)
    def helper(self):
        pass

ut_stream = ListStream()
ut_runner = unittest.TextTestRunner(stream=ut_stream, verbosity=2)
ut_suite = unittest.TestLoader().loadTestsFromTestCase(UtSample)
check("loader count", [ut_suite.countTestCases(), unittest.TestLoader().getTestCaseNames(UtSample)],
      [6, ["test_a_ok", "test_b_fail", "test_c_error", "test_d_skip", "test_e_xfail", "test_f_subtests"]])
ut_result = ut_runner.run(ut_suite)
ut_out = ut_stream.getvalue().split("\n")
check("verbose lines", ut_out[:7],
      ["test_a_ok (__main__.UtSample.test_a_ok)", "First line of the doc. ... ok",
       "test_b_fail (__main__.UtSample.test_b_fail) ... FAIL",
       "test_c_error (__main__.UtSample.test_c_error) ... ERROR",
       "test_d_skip (__main__.UtSample.test_d_skip) ... skipped 'not now'",
       "test_e_xfail (__main__.UtSample.test_e_xfail) ... expected failure",
       "test_f_subtests (__main__.UtSample.test_f_subtests) ... "])
check("subtest line", ut_out[7], "  test_f_subtests (__main__.UtSample.test_f_subtests) (i=1) ... FAIL")
check("result counts", [ut_result.testsRun, len(ut_result.failures), len(ut_result.errors), len(ut_result.skipped),
                        len(ut_result.expectedFailures), len(ut_result.unexpectedSuccesses), ut_result.wasSuccessful()],
      [6, 2, 1, 1, 1, 0, False])
ran_lines = [ln for ln in ut_out if ln.startswith("Ran ")]
check("summary", [ran_lines[0][:len("Ran 6 tests in ")], ut_out[-2]],
      ["Ran 6 tests in ", "FAILED (failures=2, errors=1, skipped=1, expected failures=1)"])
check("error blocks", [ln for ln in ut_out if ln.startswith("ERROR: ") or ln.startswith("FAIL: ")],
      ["ERROR: test_c_error (__main__.UtSample.test_c_error)", "FAIL: test_b_fail (__main__.UtSample.test_b_fail)",
       "FAIL: test_f_subtests (__main__.UtSample.test_f_subtests) (i=1)"])
check("failure text", [[ln for ln in ut_result.failures[0][1].split("\n") if ln.startswith("AssertionError")][0],
                       ut_result.errors[0][1].strip().split("\n")[-1]],
      ["AssertionError: Lists differ: [1, 2, 3] != [1, 2, 4]", "KeyError: 'oops'"])
check("failure message", "AssertionError: Lists differ: [1, 2, 3] != [1, 2, 4]" in ut_result.failures[0][1], True)
check("fixture order", ut_log[:5] + ut_log[-2:], ["setUpClass", "setUp", "tearDown", "cleanup", "setUp", "cleanup", "tearDownClass"])
check("skip does not run setUp", ut_log.count("setUp"), 5)
ut_stream1 = ListStream()
ut_result1 = unittest.TextTestRunner(stream=ut_stream1, verbosity=1).run(unittest.TestLoader().loadTestsFromTestCase(UtSample))
check("dots", ut_stream1.getvalue().split("\n")[0], ".FEsxF")
class UtOk(unittest.TestCase):
    def test_one(self):
        self.assertIn(1, [1])
    def test_two(self):
        self.assertIsNone(None)
ut_stream2 = ListStream()
ut_result2 = unittest.TextTestRunner(stream=ut_stream2).run(unittest.TestLoader().loadTestsFromTestCase(UtOk))
check("ok run", [ut_stream2.getvalue().split("\n")[0], ut_stream2.getvalue().split("\n")[-2], ut_result2.wasSuccessful()],
      ["..", "OK", True])

class UtAsserts(unittest.TestCase):
    def runTest(self):
        pass
uta = UtAsserts()
def fail_msg(fn, *args, **kw):
    try:
        fn(*args, **kw)
    except AssertionError as e_fm:
        return str(e_fm)
    return "no failure"
check("assertEqual msgs", [fail_msg(uta.assertEqual, 1, 2), fail_msg(uta.assertEqual, "a", "b"),
                           fail_msg(uta.assertEqual, 1, 2, "extra"), fail_msg(uta.assertNotEqual, 3, 3)],
      ["1 != 2", "'a' != 'b'\n- a\n+ b\n", "1 != 2 : extra", "3 == 3"])
check("assertEqual multiline", fail_msg(uta.assertEqual, "one\ntwo\nthree\n", "one\ntoo\nthree\n"),
      "'one\\ntwo\\nthree\\n' != 'one\\ntoo\\nthree\\n'\n  one\n- two\n?  ^\n+ too\n?  ^\n  three\n")
check("assertEqual list", fail_msg(uta.assertEqual, [1, 2, 3], [1, 2, 4]),
      "Lists differ: [1, 2, 3] != [1, 2, 4]\n\nFirst differing element 2:\n3\n4\n\n- [1, 2, 3]\n?        ^\n\n+ [1, 2, 4]\n?        ^\n")
check("assertEqual list lengths", fail_msg(uta.assertEqual, [1, 2], [1, 2, 3]),
      "Lists differ: [1, 2] != [1, 2, 3]\n\nSecond list contains 1 additional elements.\nFirst extra element 2:\n3\n\n- [1, 2]\n+ [1, 2, 3]\n?      +++\n")
check("assertEqual tuple", fail_msg(uta.assertEqual, (1, 2), (1, 3)).split("\n")[0], "Tuples differ: (1, 2) != (1, 3)")
check("assertEqual dict", fail_msg(uta.assertEqual, {"a": 1, "b": 2}, {"a": 1, "b": 3}),
      "{'a': 1, 'b': 2} != {'a': 1, 'b': 3}\n- {'a': 1, 'b': 2}\n?               ^\n\n+ {'a': 1, 'b': 3}\n?               ^\n")
check("assertEqual set", fail_msg(uta.assertEqual, set([1, 2]), set([2, 3])),
      "Items in the first set but not the second:\n1\nItems in the second set but not the first:\n3")
check("assertEqual long", fail_msg(uta.assertEqual, "x" * 100, "x" * 99 + "y"),
      "'xxxx[34 chars]xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' != 'xxxx[34 chars]xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxy'\n- xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n?                                                                                                    ^\n+ xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxy\n?                                                                                                    ^\n")
check("assertEqual long list", fail_msg(uta.assertEqual, list(range(30)), list(range(29)) + [99]).split("\n")[0],
      "Lists differ: [0, 1[42 chars]14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29] != [0, 1[42 chars]14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 99]")
check("assert true/false", [fail_msg(uta.assertTrue, 0), fail_msg(uta.assertFalse, [1])], ["0 is not true", "[1] is not false"])
check("assertIs", [fail_msg(uta.assertIs, 1, None), fail_msg(uta.assertIsNot, None, None), fail_msg(uta.assertIsNone, 5),
                   fail_msg(uta.assertIsNotNone, None)], ["1 is not None", "unexpectedly identical: None", "5 is not None", "unexpectedly None"])
check("assertIn", [fail_msg(uta.assertIn, 3, [1, 2]), fail_msg(uta.assertNotIn, 1, [1, 2])],
      ["3 not found in [1, 2]", "1 unexpectedly found in [1, 2]"])
check("assertIsInstance", [fail_msg(uta.assertIsInstance, "s", int), fail_msg(uta.assertNotIsInstance, 1, int)],
      ["'s' is not an instance of <class 'int'>", "1 is an instance of <class 'int'>"])
check("comparisons", [fail_msg(uta.assertGreater, 1, 2), fail_msg(uta.assertGreaterEqual, 1, 2), fail_msg(uta.assertLess, 2, 1),
                      fail_msg(uta.assertLessEqual, 2, 1)],
      ["1 not greater than 2", "1 not greater than or equal to 2", "2 not less than 1", "2 not less than or equal to 1"])
check("assertAlmostEqual", [fail_msg(uta.assertAlmostEqual, 1.0, 1.1), fail_msg(uta.assertAlmostEqual, 1.0, 1.00000001),
                            fail_msg(uta.assertAlmostEqual, 1.0, 1.2, delta=0.5), fail_msg(uta.assertAlmostEqual, 1, 3, delta=1),
                            fail_msg(uta.assertNotAlmostEqual, 1.0, 1.0), fail_msg(uta.assertAlmostEqual, 1.0, 1.04, places=1)],
      ["1.0 != 1.1 within 7 places (0.10000000000000009 difference)", "no failure", "no failure",
       "1 != 3 within 1 delta (2 difference)", "1.0 == 1.0 within 7 places", "no failure"])
check("assertAlmostEqual both", raises(uta.assertAlmostEqual, 1, 2, places=1, delta=1), "TypeError")
check("assertCountEqual", [fail_msg(uta.assertCountEqual, [1, 1, 2], [2, 1, 1]), fail_msg(uta.assertCountEqual, [1, 1, 2], [1, 2, 3])],
      ["no failure", "Element counts were not equal:\nFirst has 2, Second has 1:  1\nFirst has 0, Second has 1:  3"])
check("assertRaises callable", [fail_msg(uta.assertRaises, ValueError, int, "x"), fail_msg(uta.assertRaises, ValueError, int, "5")],
      ["no failure", "ValueError not raised by int"])
ar_empty = {}
with uta.assertRaises(KeyError) as ar_cm:
    ar_empty["missing"]
check("assertRaises context", [type(ar_cm.exception).__name__, str(ar_cm.exception)], ["KeyError", "'missing'"])
def ar_none():
    with uta.assertRaises(ValueError):
        pass
check("assertRaises not raised", fail_msg(ar_none), "ValueError not raised")
def ar_other():
    with uta.assertRaises(ValueError):
        raise KeyError("k")
check("assertRaises other passes through", raises(ar_other), "KeyError")
check("assertRaises tuple", fail_msg(uta.assertRaises, (KeyError, ValueError), int, "x"), "no failure")
check("assertRaisesRegex", [fail_msg(uta.assertRaisesRegex, ValueError, "invalid lit", int, "x"),
                            fail_msg(uta.assertRaisesRegex, ValueError, "^nomatch", int, "x").startswith('"^nomatch" does not match "invalid literal')],
      ["no failure", True])
check("assertRegex", [fail_msg(uta.assertRegex, "abc", "b+"), fail_msg(uta.assertRegex, "abc", "x"), fail_msg(uta.assertNotRegex, "abc", "b")],
      ["no failure", "Regex didn't match: 'x' not found in 'abc'", "Regex matched: 'b' matches 'b' in 'abc'"])
check("fail/skipTest", [fail_msg(uta.fail, "boom"), raises(uta.skipTest, "why")], ["boom", "SkipTest"])
uta.longMessage = False
check("longMessage False", fail_msg(uta.assertEqual, 1, 2, "only"), "only")
uta.longMessage = True
uta.maxDiff = 10
check("maxDiff", fail_msg(uta.assertEqual, [1, 2, 3], [1, 2, 4]).split("\n")[-1],
      "Diff is 48 characters long. Set self.maxDiff to None to see it.")
check("TestCase str/id/repr", [str(UtSample("test_a_ok")), UtSample("test_a_ok").id(), repr(UtSample("test_a_ok")),
                               UtSample("test_a_ok").shortDescription(), UtSample("test_b_fail").shortDescription()],
      ["test_a_ok (__main__.UtSample.test_a_ok)", "__main__.UtSample.test_a_ok", "<__main__.UtSample testMethod=test_a_ok>",
       "First line of the doc.", None])
check("bad method name", raises(UtSample, "nope"), "ValueError")
check("TestCase equality", [UtSample("test_a_ok") == UtSample("test_a_ok"), UtSample("test_a_ok") == UtSample("test_b_fail")], [True, False])
ft_calls = []
ftc = unittest.FunctionTestCase(lambda: ft_calls.append("run"), setUp=lambda: ft_calls.append("setUp"))
ft_res = unittest.TestResult()
ftc.run(ft_res)
check("FunctionTestCase", [ft_calls, ft_res.testsRun, ft_res.wasSuccessful()], [["setUp", "run"], 1, True])
@unittest.skipIf(True, "skipped class")
class UtSkipped(unittest.TestCase):
    def test_x(self):
        raise RuntimeError("should not run")
@unittest.skipUnless(False, "unless")
class UtSkipped2(unittest.TestCase):
    def test_y(self):
        raise RuntimeError("should not run")
sk_res = unittest.TestResult()
unittest.TestSuite([unittest.TestLoader().loadTestsFromTestCase(UtSkipped), unittest.TestLoader().loadTestsFromTestCase(UtSkipped2)]).run(sk_res)
check("skip classes", [sk_res.testsRun, [r[1] for r in sk_res.skipped], sk_res.wasSuccessful()], [2, ["skipped class", "unless"], True])
class UtUnexpected(unittest.TestCase):
    @unittest.expectedFailure
    def test_passes(self):
        pass
us_res = unittest.TestResult()
unittest.TestLoader().loadTestsFromTestCase(UtUnexpected).run(us_res)
check("unexpected success", [len(us_res.unexpectedSuccesses), us_res.wasSuccessful()], [1, False])
class UtSetupFails(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raise RuntimeError("class setup")
    def test_never(self):
        pass
sf_res = unittest.TestResult()
unittest.TestSuite([unittest.TestLoader().loadTestsFromTestCase(UtSetupFails)]).run(sf_res)
check("setUpClass failure", [sf_res.testsRun, len(sf_res.errors), str(sf_res.errors[0][0])], [0, 1, "setUpClass (__main__.UtSetupFails)"])
class UtLogs(unittest.TestCase):
    def test_logs(self):
        with self.assertLogs("vm76.ut", level="INFO") as cm_logs:
            logging.getLogger("vm76.ut").info("first")
            logging.getLogger("vm76.ut.child").warning("second")
        self.assertEqual(cm_logs.output, ["INFO:vm76.ut:first", "WARNING:vm76.ut.child:second"])
        self.assertEqual(len(cm_logs.records), 2)
    def test_no_logs(self):
        with self.assertLogs("vm76.ut2"):
            pass
lg_res = unittest.TestResult()
unittest.TestLoader().loadTestsFromTestCase(UtLogs).run(lg_res)
check("assertLogs", [lg_res.testsRun, len(lg_res.failures), lg_res.failures[0][1].strip().split("\n")[-1] if lg_res.failures else ""],
      [2, 1, "AssertionError: no logs of level INFO or higher triggered on vm76.ut2"])
check("TestResult repr", [repr(lg_res).startswith("<unittest."), repr(lg_res).endswith("TestResult run=2 errors=0 failures=1>")], [True, True])
ut_script = T("ut_main.py")
write_file(ut_script, "\n".join(["import unittest",
                                  "class A(unittest.TestCase):",
                                  "    def test_ok(self):",
                                  "        self.assertEqual(2, 2)",
                                  "    def test_bad(self):",
                                  "        self.assertEqual(1, 2)",
                                  "if __name__ == '__main__':",
                                  "    unittest.main()", ""]))
ut_run = subprocess.run([sys.executable, ut_script], capture_output=True, text=True, cwd=REPO)
ut_err = ut_run.stderr.split("\n")
check("main() failing", [ut_run.returncode, ut_err[0], ut_err[-2]], [1, "F.", "FAILED (failures=1)"])
ut_run2 = subprocess.run([sys.executable, ut_script, "-v", "A.test_ok"], capture_output=True, text=True, cwd=REPO)
check("main() -v name", [ut_run2.returncode, ut_run2.stderr.split("\n")[0], ut_run2.stderr.split("\n")[-2]],
      [0, "test_ok (__main__.A.test_ok) ... ok", "OK"])
ut_run3 = subprocess.run([sys.executable, ut_script, "-k", "bad"], capture_output=True, text=True, cwd=REPO)
check("main() -k", [ut_run3.returncode, ut_run3.stderr.split("\n")[0]], [1, "F"])

# ── queue ────────────────────────────────────────────────────────────────────
qq = queue.Queue()
for qi in range(5):
    qq.put(qi)
check("Queue FIFO", [qq.qsize(), qq.empty(), qq.full(), [qq.get() for _ in range(5)], qq.empty()], [5, False, False, [0, 1, 2, 3, 4], True])
check("Queue Empty", [raises(qq.get_nowait), raises(qq.get, timeout=0.01), raises(qq.get, False)], ["Empty", "Empty", "Empty"])
qb = queue.Queue(maxsize=2)
qb.put(1)
qb.put(2)
check("Queue Full", [qb.full(), raises(qb.put_nowait, 3), raises(qb.put, 3, timeout=0.01), qb.maxsize], [True, "Full", "Full", 2])
check("Queue negative timeout", raises(qb.get, True, -1), "ValueError")
ql = queue.LifoQueue()
for qx in "abc":
    ql.put(qx)
check("LifoQueue", [ql.get() for _ in range(3)], ["c", "b", "a"])
qp = queue.PriorityQueue()
for qx in [(3, "c"), (1, "a"), (2, "b"), (1, "a2"), (5, "e"), (0, "z"), (4, "d")]:
    qp.put(qx)
check("PriorityQueue", [qp.get() for _ in range(7)], [(0, "z"), (1, "a"), (1, "a2"), (2, "b"), (3, "c"), (4, "d"), (5, "e")])
qs = queue.SimpleQueue()
qs.put(1)
qs.put_nowait(2)
check("SimpleQueue", [qs.qsize(), qs.get(), qs.get_nowait(), qs.empty(), raises(qs.get, block=False)], [2, 1, 2, True, "Empty"])
work_q = queue.Queue(maxsize=3)
done_q = queue.Queue()
def q_producer(count_p, base_p):
    for k_p in range(count_p):
        work_q.put(base_p + k_p)
def q_consumer():
    while True:
        item_c = work_q.get()
        if item_c is None:
            work_q.task_done()
            break
        done_q.put(item_c * 2)
        work_q.task_done()
q_consumers = [threading.Thread(target=q_consumer) for _ in range(3)]
for qt in q_consumers:
    qt.start()
q_producers = [threading.Thread(target=q_producer, args=(20, k_q * 100)) for k_q in range(3)]
for qt in q_producers:
    qt.start()
for qt in q_producers:
    qt.join()
work_q.join()
for qt in q_consumers:
    work_q.put(None)
for qt in q_consumers:
    qt.join()
q_out = []
while not done_q.empty():
    q_out.append(done_q.get())
check("producers/consumers", [len(q_out), sorted(q_out) == sorted([2 * v for v in list(range(20)) + list(range(100, 120)) + list(range(200, 220))]),
                              work_q.unfinished_tasks], [60, True, 0])
qtd = queue.Queue()
check("task_done too many", raises_msg(qtd.task_done), "ValueError: task_done() called too many times")

# ── cleanup and report ───────────────────────────────────────────────────────
shutil.rmtree(TMP)
check("temp dir removed", os.path.exists(TMP), False)

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT76 PASSED ===")
