# vm_audit97.ny - round 80: the OS layer's remaining gaps, codecs,
# multiprocessing (both engines; the whole file runs under python3 too).
#
#   os      fspath / PathLike, scandir / DirEntry, walk on scandir, file
#           descriptors (open/read/write/close/pipe/dup/dup2/fdopen/lseek/
#           truncate/ftruncate/inheritable/blocking), ids, umask, access,
#           chown, mkfifo, major/minor/makedev, getloadavg, the constants,
#           the live os.environ, os.path's missing members
#   posixpath, ntpath, genericpath (a battery of paths, python3's outputs),
#   stat, pwd, grp, tarfile's owner names
#   codecs  16 codecs x 8 error handlers x 18 inputs (python3's outputs,
#           compared through ascii()), the registry, register_error,
#           incremental and stream codecs, the bytes-to-bytes codecs, idna
#   pickle  the native fast path writes python3's bytes
#   multiprocessing (the spawn context): Process, Queue, Pipe, Lock, RLock,
#           Semaphore, Event, Condition, Barrier, Value, Array, Pool,
#           Manager, shared_memory; ProcessPoolExecutor over pickle
#
# Every expected value is CPython 3.11's. POSIX-only parts are skipped on
# Windows (under Wine), where pwd/grp must fail to import.
#
#     ./build/nython-cli examples/vm_audit97.ny
#     ./build/nython-cli --vm examples/vm_audit97.ny
#     python3 examples/vm_audit97.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import os
import sys
import io
import stat
import time
import queue
import pickle
import codecs
import shutil
import tarfile
import tempfile
import posixpath
import ntpath
import genericpath
import multiprocessing
from multiprocessing import shared_memory
from concurrent.futures import ProcessPoolExecutor

WINDOWS = os.name == "nt"
POSIX = not WINDOWS
LINUX = sys.platform.startswith("linux")

results = []


def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])


def show(f):
    # a result or the error it raised, ASCII only (the same text on every
    # engine: repr() of an unprintable character differs)
    try:
        return ascii(f())
    except UnicodeError as e:
        return type(e).__name__ + ":" + ascii(str(e)) + ":" + str(e.start) + "-" + str(e.end)
    except Exception as e:
        return type(e).__name__ + ":" + ascii(str(e))


def err(f):
    try:
        f()
        return "no error"
    except Exception as e:
        return type(e).__name__ + ": " + str(e)


def _import_pwd():
    import pwd


def _import_grp():
    import grp


# ── what the child processes run (module level: found by name) ──────────────
def w_put(wq, wn):
    wq.put((wn, wn * wn, multiprocessing.current_process().name))


def w_args(wq, wa, wb=0, *, wc=0):
    wq.put((wa, wb, wc, multiprocessing.parent_process().pid))


def w_fail():
    sys.stderr = open(os.devnull, "w")
    raise ValueError("boom")


def w_exit(wcode):
    sys.exit(wcode)


def w_exit_text():
    sys.stderr = open(os.devnull, "w")
    sys.exit("bye")


def w_sleep(wsec):
    time.sleep(wsec)


def w_pipe(wconn):
    wconn.send({"hello": [1, 2, 3]})
    wx = wconn.recv()
    wconn.send(wx * 2)
    wconn.send_bytes(b"raw bytes")
    wconn.close()


def w_count(wv, warr, wlock, wn):
    for wi in range(wn):
        with wlock:
            wv.value = wv.value + 1
    with warr.get_lock():
        for wi in range(len(warr)):
            warr[wi] = warr[wi] + 1


def w_event(we, wq):
    wq.put(we.wait(30))


def w_cond(wc, wv, wq):
    with wc:
        while wv.value == 0:
            wc.wait(30)
        wq.put(wv.value)


def w_barrier(wb, wq):
    wq.put(wb.wait(30))


def w_joinable(wjq, wout):
    while True:
        witem = wjq.get()
        if witem is None:
            wjq.task_done()
            break
        wout.put(witem * 10)
        wjq.task_done()


def w_square(wx):
    return wx * wx


def w_slow(wx):
    time.sleep(0.02 * (wx % 3))
    return -wx


def w_raise(wx):
    raise ValueError("bad " + str(wx))


W_INIT = []


def w_init(wval):
    W_INIT.append(wval)


def w_initval(wx):
    return (W_INIT[0] if W_INIT else None, wx)


def w_pid(wx):
    return os.getpid()


def w_manager(wd, wl, wns):
    wd["child"] = wl[0] + 1
    wl.append(42)
    wns.x = wns.x + 1


def w_shm(wname):
    wm = shared_memory.SharedMemory(wname)
    wm.buf[0:5] = bytes(wm.buf[0:5]).upper()
    wm.close()


class WPoint:
    def __init__(self, wx, wy):
        self.x = wx
        self.y = wy

    def __eq__(self, other):
        return isinstance(other, WPoint) and (self.x, self.y) == (other.x, other.y)

    def __repr__(self):
        return "WPoint(%r, %r)" % (self.x, self.y)


def w_point(wx):
    return WPoint(wx, -wx)


# ── expected values, computed by python3 3.11 ──────────────────────────────────
PATH_DATA = [
    ('posixpath', 'split', [('', ''), ('', '.'), ('', '..'), ('/', ''), ('//', ''), ('///', ''), ('', 'a'), ('a', ''), ('a', 'b'), ('/a/b', ''), ('//a', 'b'), ('///a', 'b'), ('a/.', 'b'), ('a/..', 'b'), ('..', 'a'), ('/..', 'a'), ('a/b/../..', '..'), ('', 'a\\b'), ('', 'a.txt'), ('', '.bashrc'), ('a', 'b.tar.gz'), ('a.b', 'c'), ('/a/b/c.d', ''), ('a//b', 'c'), ('', 'C:\\x\\y'), ('C:', 'x'), ('', 'c:'), ('', 'C:'), ('', '\\\\srv\\share\\x'), ('//srv/share', 'x'), ('/a/b/./c', '..'), ('', '\\\\?\\UNC\\s\\h\\p'), ('', '\\\\.\\dev\\x'), ('', 'C:..\\a'), ('', 'x\\..\\..\\y')]),
    ('posixpath', 'splitext', [('', ''), ('.', ''), ('..', ''), ('/', ''), ('//', ''), ('///', ''), ('a', ''), ('a/', ''), ('a/b', ''), ('/a/b/', ''), ('//a/b', ''), ('///a/b', ''), ('a/./b', ''), ('a/../b', ''), ('../a', ''), ('/../a', ''), ('a/b/../../..', ''), ('a\\b', ''), ('a', '.txt'), ('.bashrc', ''), ('a/b.tar', '.gz'), ('a.b/c', ''), ('/a/b/c.d/', ''), ('a//b//c', ''), ('C:\\x\\y', ''), ('C:/x', ''), ('c:', ''), ('C:', ''), ('\\\\srv\\share\\x', ''), ('//srv/share/x', ''), ('/a/b/./c/..', ''), ('\\\\?\\UNC\\s\\h\\p', ''), ('\\\\', '.\\dev\\x'), ('C:.', '.\\a'), ('x\\..\\.', '.\\y')]),
    ('posixpath', 'splitdrive', [('', ''), ('', '.'), ('', '..'), ('', '/'), ('', '//'), ('', '///'), ('', 'a'), ('', 'a/'), ('', 'a/b'), ('', '/a/b/'), ('', '//a/b'), ('', '///a/b'), ('', 'a/./b'), ('', 'a/../b'), ('', '../a'), ('', '/../a'), ('', 'a/b/../../..'), ('', 'a\\b'), ('', 'a.txt'), ('', '.bashrc'), ('', 'a/b.tar.gz'), ('', 'a.b/c'), ('', '/a/b/c.d/'), ('', 'a//b//c'), ('', 'C:\\x\\y'), ('', 'C:/x'), ('', 'c:'), ('', 'C:'), ('', '\\\\srv\\share\\x'), ('', '//srv/share/x'), ('', '/a/b/./c/..'), ('', '\\\\?\\UNC\\s\\h\\p'), ('', '\\\\.\\dev\\x'), ('', 'C:..\\a'), ('', 'x\\..\\..\\y')]),
    ('posixpath', 'normpath', ['.', '.', '..', '/', '//', '/', 'a', 'a', 'a/b', '/a/b', '//a/b', '/a/b', 'a/b', 'b', '../a', '/a', '..', 'a\\b', 'a.txt', '.bashrc', 'a/b.tar.gz', 'a.b/c', '/a/b/c.d', 'a/b/c', 'C:\\x\\y', 'C:/x', 'c:', 'C:', '\\\\srv\\share\\x', '//srv/share/x', '/a/b', '\\\\?\\UNC\\s\\h\\p', '\\\\.\\dev\\x', 'C:..\\a', 'x\\..\\..\\y']),
    ('posixpath', 'normcase', ['', '.', '..', '/', '//', '///', 'a', 'a/', 'a/b', '/a/b/', '//a/b', '///a/b', 'a/./b', 'a/../b', '../a', '/../a', 'a/b/../../..', 'a\\b', 'a.txt', '.bashrc', 'a/b.tar.gz', 'a.b/c', '/a/b/c.d/', 'a//b//c', 'C:\\x\\y', 'C:/x', 'c:', 'C:', '\\\\srv\\share\\x', '//srv/share/x', '/a/b/./c/..', '\\\\?\\UNC\\s\\h\\p', '\\\\.\\dev\\x', 'C:..\\a', 'x\\..\\..\\y']),
    ('posixpath', 'isabs', [False, False, False, True, True, True, False, False, False, True, True, True, False, False, False, True, False, False, False, False, False, False, True, False, False, False, False, False, False, True, True, False, False, False, False]),
    ('posixpath', 'basename', ['', '.', '..', '', '', '', 'a', '', 'b', '', 'b', 'b', 'b', 'b', 'a', 'a', '..', 'a\\b', 'a.txt', '.bashrc', 'b.tar.gz', 'c', '', 'c', 'C:\\x\\y', 'x', 'c:', 'C:', '\\\\srv\\share\\x', 'x', '..', '\\\\?\\UNC\\s\\h\\p', '\\\\.\\dev\\x', 'C:..\\a', 'x\\..\\..\\y']),
    ('posixpath', 'dirname', ['', '', '', '/', '//', '///', '', 'a', 'a', '/a/b', '//a', '///a', 'a/.', 'a/..', '..', '/..', 'a/b/../..', '', '', '', 'a', 'a.b', '/a/b/c.d', 'a//b', '', 'C:', '', '', '', '//srv/share', '/a/b/./c', '', '', '', '']),
    ('posixpath', 'join', ['a/b', 'a/b', '/b', 'b', 'a/', '/a', 'a/b/c', 'a/b/c/', 'C:\\a/b', 'C:\\a/D:b', 'C:\\a/c:b', 'C:/x', '\\\\s\\h/x', 'a/C:\\b/c']),
    ('posixpath', 'commonprefix', ['/a/b', 'ab', '', 'x']),
    ('ntpath', 'split', [('', ''), ('', '.'), ('', '..'), ('/', ''), ('//', ''), ('///', ''), ('', 'a'), ('a', ''), ('a', 'b'), ('/a/b', ''), ('//a/b', ''), ('///a/', 'b'), ('a/.', 'b'), ('a/..', 'b'), ('..', 'a'), ('/..', 'a'), ('a/b/../..', '..'), ('a', 'b'), ('', 'a.txt'), ('', '.bashrc'), ('a', 'b.tar.gz'), ('a.b', 'c'), ('/a/b/c.d', ''), ('a//b', 'c'), ('C:\\x', 'y'), ('C:/', 'x'), ('c:', ''), ('C:', ''), ('\\\\srv\\share\\', 'x'), ('//srv/share/', 'x'), ('/a/b/./c', '..'), ('\\\\?\\UNC\\s\\h\\', 'p'), ('\\\\.\\dev\\', 'x'), ('C:..', 'a'), ('x\\..\\..', 'y')]),
    ('ntpath', 'splitext', [('', ''), ('.', ''), ('..', ''), ('/', ''), ('//', ''), ('///', ''), ('a', ''), ('a/', ''), ('a/b', ''), ('/a/b/', ''), ('//a/b', ''), ('///a/b', ''), ('a/./b', ''), ('a/../b', ''), ('../a', ''), ('/../a', ''), ('a/b/../../..', ''), ('a\\b', ''), ('a', '.txt'), ('.bashrc', ''), ('a/b.tar', '.gz'), ('a.b/c', ''), ('/a/b/c.d/', ''), ('a//b//c', ''), ('C:\\x\\y', ''), ('C:/x', ''), ('c:', ''), ('C:', ''), ('\\\\srv\\share\\x', ''), ('//srv/share/x', ''), ('/a/b/./c/..', ''), ('\\\\?\\UNC\\s\\h\\p', ''), ('\\\\.\\dev\\x', ''), ('C:..\\a', ''), ('x\\..\\..\\y', '')]),
    ('ntpath', 'splitdrive', [('', ''), ('', '.'), ('', '..'), ('', '/'), ('//', ''), ('///', ''), ('', 'a'), ('', 'a/'), ('', 'a/b'), ('', '/a/b/'), ('//a/b', ''), ('///a', '/b'), ('', 'a/./b'), ('', 'a/../b'), ('', '../a'), ('', '/../a'), ('', 'a/b/../../..'), ('', 'a\\b'), ('', 'a.txt'), ('', '.bashrc'), ('', 'a/b.tar.gz'), ('', 'a.b/c'), ('', '/a/b/c.d/'), ('', 'a//b//c'), ('C:', '\\x\\y'), ('C:', '/x'), ('c:', ''), ('C:', ''), ('\\\\srv\\share', '\\x'), ('//srv/share', '/x'), ('', '/a/b/./c/..'), ('\\\\?\\UNC\\s\\h', '\\p'), ('\\\\.\\dev', '\\x'), ('C:', '..\\a'), ('', 'x\\..\\..\\y')]),
    ('ntpath', 'normpath', ['.', '.', '..', '\\', '\\\\', '\\\\\\', 'a', 'a', 'a\\b', '\\a\\b', '\\\\a\\b', '\\\\\\a\\b', 'a\\b', 'b', '..\\a', '\\a', '..', 'a\\b', 'a.txt', '.bashrc', 'a\\b.tar.gz', 'a.b\\c', '\\a\\b\\c.d', 'a\\b\\c', 'C:\\x\\y', 'C:\\x', 'c:', 'C:', '\\\\srv\\share\\x', '\\\\srv\\share\\x', '\\a\\b', '\\\\?\\UNC\\s\\h\\p', '\\\\.\\dev\\x', 'C:..\\a', '..\\y']),
    ('ntpath', 'normcase', ['', '.', '..', '\\', '\\\\', '\\\\\\', 'a', 'a\\', 'a\\b', '\\a\\b\\', '\\\\a\\b', '\\\\\\a\\b', 'a\\.\\b', 'a\\..\\b', '..\\a', '\\..\\a', 'a\\b\\..\\..\\..', 'a\\b', 'a.txt', '.bashrc', 'a\\b.tar.gz', 'a.b\\c', '\\a\\b\\c.d\\', 'a\\\\b\\\\c', 'c:\\x\\y', 'c:\\x', 'c:', 'c:', '\\\\srv\\share\\x', '\\\\srv\\share\\x', '\\a\\b\\.\\c\\..', '\\\\?\\unc\\s\\h\\p', '\\\\.\\dev\\x', 'c:..\\a', 'x\\..\\..\\y']),
    ('ntpath', 'isabs', [False, False, False, True, True, True, False, False, False, True, True, True, False, False, False, True, False, False, False, False, False, False, True, False, True, True, False, False, True, True, True, True, True, False, False]),
    ('ntpath', 'basename', ['', '.', '..', '', '', '', 'a', '', 'b', '', '', 'b', 'b', 'b', 'a', 'a', '..', 'b', 'a.txt', '.bashrc', 'b.tar.gz', 'c', '', 'c', 'y', 'x', '', '', 'x', 'x', '..', 'p', 'x', 'a', 'y']),
    ('ntpath', 'dirname', ['', '', '', '/', '//', '///', '', 'a', 'a', '/a/b', '//a/b', '///a/', 'a/.', 'a/..', '..', '/..', 'a/b/../..', 'a', '', '', 'a', 'a.b', '/a/b/c.d', 'a//b', 'C:\\x', 'C:/', 'c:', 'C:', '\\\\srv\\share\\', '//srv/share/', '/a/b/./c', '\\\\?\\UNC\\s\\h\\', '\\\\.\\dev\\', 'C:..', 'x\\..\\..']),
    ('ntpath', 'join', ['a\\b', 'a/b', '/b', 'b', 'a\\', '/a', 'a\\b\\c', 'a\\b/c/', 'C:\\a\\b', 'D:b', 'c:\\a\\b', 'C:x', '\\\\s\\h\\x', 'C:\\b\\c']),
    ('ntpath', 'commonprefix', ['/a/b', 'ab', '', 'x']),
    ('posixpath', 'commonpath', ['/a', 'a/b', '/a/b', '/a/b', '']),
    ('ntpath', 'commonpath', ['C:\\a', '\\\\s\\h\\', 'a\\b', 'C:\\A\\b']),
    ('posixpath', 'relpath', ['b/c', '../..', '../../x/y', '.', '.']),
    ('ntpath', 'relpath', ['b\\c', '..\\..', '..\\..\\x\\y']),
    ('posixpath', 'expandvars', ['val', 'valx', '$R80_NOPE', 'a$', '$' + '{R80_V', '$val']),
    ('ntpath', 'expandvars', ['val', 'val', 'val', "'%R80_V%'", '%', '%R80_NOPE%', 'a%b']),
]

CODEC_STRS = ['abc', 'h\xe9llo', 'a\u20acb\u20ac', '\U0001f600x', 'a\udcff', 'x\ud800\udc00y', 'tab\t\\n', '\x00\x7f\x80\xff']
CODEC_BYTES = [b'abc', b'a\xffb', b'\xed\xa0\x80z', b'\xe2\x82', b'\x81\x8d\x90', b'\\x4', b'\\u20ac\\N{DIGIT ONE}', b'\xff\xfe\x00\xd8\x00', b'\x00\x00\x11\x00', b'\xc3\xa9\xe2\x82\xac']
CODEC_DATA = [
    ('utf-8', 'strict', ["b'abc'", "b'h\\xc3\\xa9llo'", "b'a\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xf0\\x9f\\x98\\x80x'", 'UnicodeEncodeError:"\'utf-8\' codec can\'t encode character \'\\\\udcff\' in position 1: surrogates not allowed":1-2', 'UnicodeEncodeError:"\'utf-8\' codec can\'t encode characters in position 1-2: surrogates not allowed":1-3', "b'tab\\t\\\\n'", "b'\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode byte 0xff in position 1: invalid start byte":1-2', 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode byte 0xed in position 0: invalid continuation byte":0-1', 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode bytes in position 0-1: unexpected end of data":0-2', 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode byte 0x81 in position 0: invalid start byte":0-1', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode byte 0xff in position 0: invalid start byte":0-1', "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-8', 'ignore', ["b'abc'", "b'h\\xc3\\xa9llo'", "b'a\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xf0\\x9f\\x98\\x80x'", "b'a'", "b'xy'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", "'ab'", "'z'", "''", "''", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\x00\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-8', 'replace', ["b'abc'", "b'h\\xc3\\xa9llo'", "b'a\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xf0\\x9f\\x98\\x80x'", "b'a?'", "b'x??y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", "'a\\ufffdb'", "'\\ufffd\\ufffd\\ufffdz'", "'\\ufffd'", "'\\ufffd\\ufffd\\ufffd'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\ufffd\\ufffd\\x00\\ufffd\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-8', 'backslashreplace', ["b'abc'", "b'h\\xc3\\xa9llo'", "b'a\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xf0\\x9f\\x98\\x80x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", "'a\\\\xffb'", "'\\\\xed\\\\xa0\\\\x80z'", "'\\\\xe2\\\\x82'", "'\\\\x81\\\\x8d\\\\x90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\\\xff\\\\xfe\\x00\\\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-8', 'xmlcharrefreplace', ["b'abc'", "b'h\\xc3\\xa9llo'", "b'a\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xf0\\x9f\\x98\\x80x'", "b'a&#56575;'", "b'x&#55296;&#56320;y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-8', 'namereplace', ["b'abc'", "b'h\\xc3\\xa9llo'", "b'a\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xf0\\x9f\\x98\\x80x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-8', 'surrogateescape', ["b'abc'", "b'h\\xc3\\xa9llo'", "b'a\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xf0\\x9f\\x98\\x80x'", "b'a\\xff'", 'UnicodeEncodeError:"\'utf-8\' codec can\'t encode characters in position 1-2: surrogates not allowed":1-3', "b'tab\\t\\\\n'", "b'\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", "'a\\udcffb'", "'\\udced\\udca0\\udc80z'", "'\\udce2\\udc82'", "'\\udc81\\udc8d\\udc90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\udcff\\udcfe\\x00\\udcd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-8', 'surrogatepass', ["b'abc'", "b'h\\xc3\\xa9llo'", "b'a\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xf0\\x9f\\x98\\x80x'", "b'a\\xed\\xb3\\xbf'", "b'x\\xed\\xa0\\x80\\xed\\xb0\\x80y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode byte 0xff in position 1: invalid start byte":1-2', "'\\ud800z'", 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode bytes in position 0-1: unexpected end of data":0-2', 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode byte 0x81 in position 0: invalid start byte":0-1', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode byte 0xff in position 0: invalid start byte":0-1', "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-8-sig', 'strict', ["b'\\xef\\xbb\\xbfabc'", "b'\\xef\\xbb\\xbfh\\xc3\\xa9llo'", "b'\\xef\\xbb\\xbfa\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xef\\xbb\\xbf\\xf0\\x9f\\x98\\x80x'", 'UnicodeEncodeError:"\'utf-8\' codec can\'t encode character \'\\\\udcff\' in position 1: surrogates not allowed":1-2', 'UnicodeEncodeError:"\'utf-8\' codec can\'t encode characters in position 1-2: surrogates not allowed":1-3', "b'\\xef\\xbb\\xbftab\\t\\\\n'", "b'\\xef\\xbb\\xbf\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode byte 0xff in position 1: invalid start byte":1-2', 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode byte 0xed in position 0: invalid continuation byte":0-1', 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode bytes in position 0-1: unexpected end of data":0-2', 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode byte 0x81 in position 0: invalid start byte":0-1', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode byte 0xff in position 0: invalid start byte":0-1', "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-8-sig', 'ignore', ["b'\\xef\\xbb\\xbfabc'", "b'\\xef\\xbb\\xbfh\\xc3\\xa9llo'", "b'\\xef\\xbb\\xbfa\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xef\\xbb\\xbf\\xf0\\x9f\\x98\\x80x'", "b'\\xef\\xbb\\xbfa'", "b'\\xef\\xbb\\xbfxy'", "b'\\xef\\xbb\\xbftab\\t\\\\n'", "b'\\xef\\xbb\\xbf\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", "'ab'", "'z'", "''", "''", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\x00\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-8-sig', 'replace', ["b'\\xef\\xbb\\xbfabc'", "b'\\xef\\xbb\\xbfh\\xc3\\xa9llo'", "b'\\xef\\xbb\\xbfa\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xef\\xbb\\xbf\\xf0\\x9f\\x98\\x80x'", "b'\\xef\\xbb\\xbfa?'", "b'\\xef\\xbb\\xbfx??y'", "b'\\xef\\xbb\\xbftab\\t\\\\n'", "b'\\xef\\xbb\\xbf\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", "'a\\ufffdb'", "'\\ufffd\\ufffd\\ufffdz'", "'\\ufffd'", "'\\ufffd\\ufffd\\ufffd'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\ufffd\\ufffd\\x00\\ufffd\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-8-sig', 'backslashreplace', ["b'\\xef\\xbb\\xbfabc'", "b'\\xef\\xbb\\xbfh\\xc3\\xa9llo'", "b'\\xef\\xbb\\xbfa\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xef\\xbb\\xbf\\xf0\\x9f\\x98\\x80x'", "b'\\xef\\xbb\\xbfa\\\\udcff'", "b'\\xef\\xbb\\xbfx\\\\ud800\\\\udc00y'", "b'\\xef\\xbb\\xbftab\\t\\\\n'", "b'\\xef\\xbb\\xbf\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", "'a\\\\xffb'", "'\\\\xed\\\\xa0\\\\x80z'", "'\\\\xe2\\\\x82'", "'\\\\x81\\\\x8d\\\\x90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\\\xff\\\\xfe\\x00\\\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-8-sig', 'xmlcharrefreplace', ["b'\\xef\\xbb\\xbfabc'", "b'\\xef\\xbb\\xbfh\\xc3\\xa9llo'", "b'\\xef\\xbb\\xbfa\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xef\\xbb\\xbf\\xf0\\x9f\\x98\\x80x'", "b'\\xef\\xbb\\xbfa&#56575;'", "b'\\xef\\xbb\\xbfx&#55296;&#56320;y'", "b'\\xef\\xbb\\xbftab\\t\\\\n'", "b'\\xef\\xbb\\xbf\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", 'TypeError:"decoding with \'utf-8-sig\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-8-sig\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-8-sig\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-8-sig\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", 'TypeError:"decoding with \'utf-8-sig\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-8-sig', 'namereplace', ["b'\\xef\\xbb\\xbfabc'", "b'\\xef\\xbb\\xbfh\\xc3\\xa9llo'", "b'\\xef\\xbb\\xbfa\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xef\\xbb\\xbf\\xf0\\x9f\\x98\\x80x'", "b'\\xef\\xbb\\xbfa\\\\udcff'", "b'\\xef\\xbb\\xbfx\\\\ud800\\\\udc00y'", "b'\\xef\\xbb\\xbftab\\t\\\\n'", "b'\\xef\\xbb\\xbf\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", 'TypeError:"decoding with \'utf-8-sig\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-8-sig\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-8-sig\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-8-sig\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", 'TypeError:"decoding with \'utf-8-sig\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-8-sig', 'surrogateescape', ["b'\\xef\\xbb\\xbfabc'", "b'\\xef\\xbb\\xbfh\\xc3\\xa9llo'", "b'\\xef\\xbb\\xbfa\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xef\\xbb\\xbf\\xf0\\x9f\\x98\\x80x'", "b'\\xef\\xbb\\xbfa\\xff'", 'UnicodeEncodeError:"\'utf-8\' codec can\'t encode characters in position 1-2: surrogates not allowed":1-3', "b'\\xef\\xbb\\xbftab\\t\\\\n'", "b'\\xef\\xbb\\xbf\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", "'a\\udcffb'", "'\\udced\\udca0\\udc80z'", "'\\udce2\\udc82'", "'\\udc81\\udc8d\\udc90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\udcff\\udcfe\\x00\\udcd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-8-sig', 'surrogatepass', ["b'\\xef\\xbb\\xbfabc'", "b'\\xef\\xbb\\xbfh\\xc3\\xa9llo'", "b'\\xef\\xbb\\xbfa\\xe2\\x82\\xacb\\xe2\\x82\\xac'", "b'\\xef\\xbb\\xbf\\xf0\\x9f\\x98\\x80x'", "b'\\xef\\xbb\\xbfa\\xed\\xb3\\xbf'", "b'\\xef\\xbb\\xbfx\\xed\\xa0\\x80\\xed\\xb0\\x80y'", "b'\\xef\\xbb\\xbftab\\t\\\\n'", "b'\\xef\\xbb\\xbf\\x00\\x7f\\xc2\\x80\\xc3\\xbf'", "'abc'", 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode byte 0xff in position 1: invalid start byte":1-2', "'\\ud800z'", 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode bytes in position 0-1: unexpected end of data":0-2', 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode byte 0x81 in position 0: invalid start byte":0-1', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", 'UnicodeDecodeError:"\'utf-8\' codec can\'t decode byte 0xff in position 0: invalid start byte":0-1', "'\\x00\\x00\\x11\\x00'", "'\\xe9\\u20ac'"]),
    ('utf-16', 'strict', ["b'\\xff\\xfea\\x00b\\x00c\\x00'", "b'\\xff\\xfeh\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'\\xff\\xfea\\x00\\xac b\\x00\\xac '", "b'\\xff\\xfe=\\xd8\\x00\\xdex\\x00'", 'UnicodeEncodeError:"\'utf-16\' codec can\'t encode character \'\\\\udcff\' in position 1: surrogates not allowed":1-2', 'UnicodeEncodeError:"\'utf-16\' codec can\'t encode character \'\\\\ud800\' in position 1: surrogates not allowed":1-2', "b'\\xff\\xfet\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\xff\\xfe\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x63 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x62 in position 2: truncated data":2-3', "'\\ua0ed\\u7a80'", "'\\u82e2'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x90 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x34 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x7d in position 18: truncated data":18-19', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode bytes in position 2-4: unexpected end of data":2-5', "'\\x00\\x11'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0xac in position 4: truncated data":4-5']),
    ('utf-16', 'ignore', ["b'\\xff\\xfea\\x00b\\x00c\\x00'", "b'\\xff\\xfeh\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'\\xff\\xfea\\x00\\xac b\\x00\\xac '", "b'\\xff\\xfe=\\xd8\\x00\\xdex\\x00'", "b'\\xff\\xfea\\x00'", "b'\\xff\\xfex\\x00y\\x00'", "b'\\xff\\xfet\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\xff\\xfe\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", "'\\u6261'", "'\\uff61'", "'\\ua0ed\\u7a80'", "'\\u82e2'", "'\\u8d81'", "'\\u785c'", "'\\u755c\\u3032\\u6361\\u4e5c\\u447b\\u4749\\u5449\\u4f20\\u454e'", "''", "'\\x00\\x11'", "'\\ua9c3\\u82e2'"]),
    ('utf-16', 'replace', ["b'\\xff\\xfea\\x00b\\x00c\\x00'", "b'\\xff\\xfeh\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'\\xff\\xfea\\x00\\xac b\\x00\\xac '", "b'\\xff\\xfe=\\xd8\\x00\\xdex\\x00'", "b'\\xff\\xfea\\x00?\\x00'", "b'\\xff\\xfex\\x00?\\x00?\\x00y\\x00'", "b'\\xff\\xfet\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\xff\\xfe\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", "'\\u6261\\ufffd'", "'\\uff61\\ufffd'", "'\\ua0ed\\u7a80'", "'\\u82e2'", "'\\u8d81\\ufffd'", "'\\u785c\\ufffd'", "'\\u755c\\u3032\\u6361\\u4e5c\\u447b\\u4749\\u5449\\u4f20\\u454e\\ufffd'", "'\\ufffd'", "'\\x00\\x11'", "'\\ua9c3\\u82e2\\ufffd'"]),
    ('utf-16', 'backslashreplace', ["b'\\xff\\xfea\\x00b\\x00c\\x00'", "b'\\xff\\xfeh\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'\\xff\\xfea\\x00\\xac b\\x00\\xac '", "b'\\xff\\xfe=\\xd8\\x00\\xdex\\x00'", "b'\\xff\\xfea\\x00\\\\\\x00u\\x00d\\x00c\\x00f\\x00f\\x00'", "b'\\xff\\xfex\\x00\\\\\\x00u\\x00d\\x008\\x000\\x000\\x00\\\\\\x00u\\x00d\\x00c\\x000\\x000\\x00y\\x00'", "b'\\xff\\xfet\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\xff\\xfe\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", "'\\u6261\\\\x63'", "'\\uff61\\\\x62'", "'\\ua0ed\\u7a80'", "'\\u82e2'", "'\\u8d81\\\\x90'", "'\\u785c\\\\x34'", "'\\u755c\\u3032\\u6361\\u4e5c\\u447b\\u4749\\u5449\\u4f20\\u454e\\\\x7d'", "'\\\\x00\\\\xd8\\\\x00'", "'\\x00\\x11'", "'\\ua9c3\\u82e2\\\\xac'"]),
    ('utf-16', 'xmlcharrefreplace', ["b'\\xff\\xfea\\x00b\\x00c\\x00'", "b'\\xff\\xfeh\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'\\xff\\xfea\\x00\\xac b\\x00\\xac '", "b'\\xff\\xfe=\\xd8\\x00\\xdex\\x00'", "b'\\xff\\xfea\\x00&\\x00#\\x005\\x006\\x005\\x007\\x005\\x00;\\x00'", "b'\\xff\\xfex\\x00&\\x00#\\x005\\x005\\x002\\x009\\x006\\x00;\\x00&\\x00#\\x005\\x006\\x003\\x002\\x000\\x00;\\x00y\\x00'", "b'\\xff\\xfet\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\xff\\xfe\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', "'\\ua0ed\\u7a80'", "'\\u82e2'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', "'\\x00\\x11'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"']),
    ('utf-16', 'namereplace', ["b'\\xff\\xfea\\x00b\\x00c\\x00'", "b'\\xff\\xfeh\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'\\xff\\xfea\\x00\\xac b\\x00\\xac '", "b'\\xff\\xfe=\\xd8\\x00\\xdex\\x00'", "b'\\xff\\xfea\\x00\\\\\\x00u\\x00d\\x00c\\x00f\\x00f\\x00'", "b'\\xff\\xfex\\x00\\\\\\x00u\\x00d\\x008\\x000\\x000\\x00\\\\\\x00u\\x00d\\x00c\\x000\\x000\\x00y\\x00'", "b'\\xff\\xfet\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\xff\\xfe\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', "'\\ua0ed\\u7a80'", "'\\u82e2'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', "'\\x00\\x11'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"']),
    ('utf-16', 'surrogateescape', ["b'\\xff\\xfea\\x00b\\x00c\\x00'", "b'\\xff\\xfeh\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'\\xff\\xfea\\x00\\xac b\\x00\\xac '", "b'\\xff\\xfe=\\xd8\\x00\\xdex\\x00'", 'UnicodeEncodeError:"\'utf-16\' codec can\'t encode character \'\\\\udcff\' in position 1: surrogates not allowed":1-2', 'UnicodeEncodeError:"\'utf-16\' codec can\'t encode character \'\\\\ud800\' in position 1: surrogates not allowed":1-2', "b'\\xff\\xfet\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\xff\\xfe\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x63 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x62 in position 2: truncated data":2-3', "'\\ua0ed\\u7a80'", "'\\u82e2'", "'\\u8d81\\udc90'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x34 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x7d in position 18: truncated data":18-19', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode bytes in position 2-4: unexpected end of data":2-5', "'\\x00\\x11'", "'\\ua9c3\\u82e2\\udcac'"]),
    ('utf-16', 'surrogatepass', ["b'\\xff\\xfea\\x00b\\x00c\\x00'", "b'\\xff\\xfeh\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'\\xff\\xfea\\x00\\xac b\\x00\\xac '", "b'\\xff\\xfe=\\xd8\\x00\\xdex\\x00'", "b'\\xff\\xfea\\x00\\xff\\xdc'", "b'\\xff\\xfex\\x00\\x00\\xd8\\x00\\xdcy\\x00'", "b'\\xff\\xfet\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\xff\\xfe\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x63 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x62 in position 2: truncated data":2-3', "'\\ua0ed\\u7a80'", "'\\u82e2'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x90 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x34 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x7d in position 18: truncated data":18-19', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x00 in position 4: truncated data":4-5', "'\\x00\\x11'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0xac in position 4: truncated data":4-5']),
    ('utf-16-le', 'strict', ["b'a\\x00b\\x00c\\x00'", "b'h\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'a\\x00\\xac b\\x00\\xac '", "b'=\\xd8\\x00\\xdex\\x00'", 'UnicodeEncodeError:"\'utf-16-le\' codec can\'t encode character \'\\\\udcff\' in position 1: surrogates not allowed":1-2', 'UnicodeEncodeError:"\'utf-16-le\' codec can\'t encode character \'\\\\ud800\' in position 1: surrogates not allowed":1-2', "b't\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x63 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x62 in position 2: truncated data":2-3', "'\\ua0ed\\u7a80'", "'\\u82e2'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x90 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x34 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x7d in position 18: truncated data":18-19', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode bytes in position 2-4: unexpected end of data":2-5', "'\\x00\\x11'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0xac in position 4: truncated data":4-5']),
    ('utf-16-le', 'ignore', ["b'a\\x00b\\x00c\\x00'", "b'h\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'a\\x00\\xac b\\x00\\xac '", "b'=\\xd8\\x00\\xdex\\x00'", "b'a\\x00'", "b'x\\x00y\\x00'", "b't\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", "'\\u6261'", "'\\uff61'", "'\\ua0ed\\u7a80'", "'\\u82e2'", "'\\u8d81'", "'\\u785c'", "'\\u755c\\u3032\\u6361\\u4e5c\\u447b\\u4749\\u5449\\u4f20\\u454e'", "'\\ufeff'", "'\\x00\\x11'", "'\\ua9c3\\u82e2'"]),
    ('utf-16-le', 'replace', ["b'a\\x00b\\x00c\\x00'", "b'h\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'a\\x00\\xac b\\x00\\xac '", "b'=\\xd8\\x00\\xdex\\x00'", "b'a\\x00?\\x00'", "b'x\\x00?\\x00?\\x00y\\x00'", "b't\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", "'\\u6261\\ufffd'", "'\\uff61\\ufffd'", "'\\ua0ed\\u7a80'", "'\\u82e2'", "'\\u8d81\\ufffd'", "'\\u785c\\ufffd'", "'\\u755c\\u3032\\u6361\\u4e5c\\u447b\\u4749\\u5449\\u4f20\\u454e\\ufffd'", "'\\ufeff\\ufffd'", "'\\x00\\x11'", "'\\ua9c3\\u82e2\\ufffd'"]),
    ('utf-16-le', 'backslashreplace', ["b'a\\x00b\\x00c\\x00'", "b'h\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'a\\x00\\xac b\\x00\\xac '", "b'=\\xd8\\x00\\xdex\\x00'", "b'a\\x00\\\\\\x00u\\x00d\\x00c\\x00f\\x00f\\x00'", "b'x\\x00\\\\\\x00u\\x00d\\x008\\x000\\x000\\x00\\\\\\x00u\\x00d\\x00c\\x000\\x000\\x00y\\x00'", "b't\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", "'\\u6261\\\\x63'", "'\\uff61\\\\x62'", "'\\ua0ed\\u7a80'", "'\\u82e2'", "'\\u8d81\\\\x90'", "'\\u785c\\\\x34'", "'\\u755c\\u3032\\u6361\\u4e5c\\u447b\\u4749\\u5449\\u4f20\\u454e\\\\x7d'", "'\\ufeff\\\\x00\\\\xd8\\\\x00'", "'\\x00\\x11'", "'\\ua9c3\\u82e2\\\\xac'"]),
    ('utf-16-le', 'xmlcharrefreplace', ["b'a\\x00b\\x00c\\x00'", "b'h\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'a\\x00\\xac b\\x00\\xac '", "b'=\\xd8\\x00\\xdex\\x00'", "b'a\\x00&\\x00#\\x005\\x006\\x005\\x007\\x005\\x00;\\x00'", "b'x\\x00&\\x00#\\x005\\x005\\x002\\x009\\x006\\x00;\\x00&\\x00#\\x005\\x006\\x003\\x002\\x000\\x00;\\x00y\\x00'", "b't\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", 'TypeError:"decoding with \'utf-16-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\ua0ed\\u7a80'", "'\\u82e2'", 'TypeError:"decoding with \'utf-16-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\x00\\x11'", 'TypeError:"decoding with \'utf-16-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"']),
    ('utf-16-le', 'namereplace', ["b'a\\x00b\\x00c\\x00'", "b'h\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'a\\x00\\xac b\\x00\\xac '", "b'=\\xd8\\x00\\xdex\\x00'", "b'a\\x00\\\\\\x00u\\x00d\\x00c\\x00f\\x00f\\x00'", "b'x\\x00\\\\\\x00u\\x00d\\x008\\x000\\x000\\x00\\\\\\x00u\\x00d\\x00c\\x000\\x000\\x00y\\x00'", "b't\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", 'TypeError:"decoding with \'utf-16-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\ua0ed\\u7a80'", "'\\u82e2'", 'TypeError:"decoding with \'utf-16-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\x00\\x11'", 'TypeError:"decoding with \'utf-16-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"']),
    ('utf-16-le', 'surrogateescape', ["b'a\\x00b\\x00c\\x00'", "b'h\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'a\\x00\\xac b\\x00\\xac '", "b'=\\xd8\\x00\\xdex\\x00'", 'UnicodeEncodeError:"\'utf-16-le\' codec can\'t encode character \'\\\\udcff\' in position 1: surrogates not allowed":1-2', 'UnicodeEncodeError:"\'utf-16-le\' codec can\'t encode character \'\\\\ud800\' in position 1: surrogates not allowed":1-2', "b't\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x63 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x62 in position 2: truncated data":2-3', "'\\ua0ed\\u7a80'", "'\\u82e2'", "'\\u8d81\\udc90'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x34 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x7d in position 18: truncated data":18-19', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode bytes in position 2-4: unexpected end of data":2-5', "'\\x00\\x11'", "'\\ua9c3\\u82e2\\udcac'"]),
    ('utf-16-le', 'surrogatepass', ["b'a\\x00b\\x00c\\x00'", "b'h\\x00\\xe9\\x00l\\x00l\\x00o\\x00'", "b'a\\x00\\xac b\\x00\\xac '", "b'=\\xd8\\x00\\xdex\\x00'", "b'a\\x00\\xff\\xdc'", "b'x\\x00\\x00\\xd8\\x00\\xdcy\\x00'", "b't\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n\\x00'", "b'\\x00\\x00\\x7f\\x00\\x80\\x00\\xff\\x00'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x63 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x62 in position 2: truncated data":2-3', "'\\ua0ed\\u7a80'", "'\\u82e2'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x90 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x34 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x7d in position 18: truncated data":18-19', 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0x00 in position 4: truncated data":4-5', "'\\x00\\x11'", 'UnicodeDecodeError:"\'utf-16-le\' codec can\'t decode byte 0xac in position 4: truncated data":4-5']),
    ('utf-16-be', 'strict', ["b'\\x00a\\x00b\\x00c'", "b'\\x00h\\x00\\xe9\\x00l\\x00l\\x00o'", "b'\\x00a \\xac\\x00b \\xac'", "b'\\xd8=\\xde\\x00\\x00x'", 'UnicodeEncodeError:"\'utf-16-be\' codec can\'t encode character \'\\\\udcff\' in position 1: surrogates not allowed":1-2', 'UnicodeEncodeError:"\'utf-16-be\' codec can\'t encode character \'\\\\ud800\' in position 1: surrogates not allowed":1-2', "b'\\x00t\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n'", "b'\\x00\\x00\\x00\\x7f\\x00\\x80\\x00\\xff'", 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x63 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x62 in position 2: truncated data":2-3', "'\\ueda0\\u807a'", "'\\ue282'", 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x90 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x34 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x7d in position 18: truncated data":18-19', 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x00 in position 4: truncated data":4-5', "'\\x00\\u1100'", 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0xac in position 4: truncated data":4-5']),
    ('utf-16-be', 'ignore', ["b'\\x00a\\x00b\\x00c'", "b'\\x00h\\x00\\xe9\\x00l\\x00l\\x00o'", "b'\\x00a \\xac\\x00b \\xac'", "b'\\xd8=\\xde\\x00\\x00x'", "b'\\x00a'", "b'\\x00x\\x00y'", "b'\\x00t\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n'", "b'\\x00\\x00\\x00\\x7f\\x00\\x80\\x00\\xff'", "'\\u6162'", "'\\u61ff'", "'\\ueda0\\u807a'", "'\\ue282'", "'\\u818d'", "'\\u5c78'", "'\\u5c75\\u3230\\u6163\\u5c4e\\u7b44\\u4947\\u4954\\u204f\\u4e45'", "'\\ufffe\\xd8'", "'\\x00\\u1100'", "'\\uc3a9\\ue282'"]),
    ('utf-16-be', 'replace', ["b'\\x00a\\x00b\\x00c'", "b'\\x00h\\x00\\xe9\\x00l\\x00l\\x00o'", "b'\\x00a \\xac\\x00b \\xac'", "b'\\xd8=\\xde\\x00\\x00x'", "b'\\x00a\\x00?'", "b'\\x00x\\x00?\\x00?\\x00y'", "b'\\x00t\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n'", "b'\\x00\\x00\\x00\\x7f\\x00\\x80\\x00\\xff'", "'\\u6162\\ufffd'", "'\\u61ff\\ufffd'", "'\\ueda0\\u807a'", "'\\ue282'", "'\\u818d\\ufffd'", "'\\u5c78\\ufffd'", "'\\u5c75\\u3230\\u6163\\u5c4e\\u7b44\\u4947\\u4954\\u204f\\u4e45\\ufffd'", "'\\ufffe\\xd8\\ufffd'", "'\\x00\\u1100'", "'\\uc3a9\\ue282\\ufffd'"]),
    ('utf-16-be', 'backslashreplace', ["b'\\x00a\\x00b\\x00c'", "b'\\x00h\\x00\\xe9\\x00l\\x00l\\x00o'", "b'\\x00a \\xac\\x00b \\xac'", "b'\\xd8=\\xde\\x00\\x00x'", "b'\\x00a\\x00\\\\\\x00u\\x00d\\x00c\\x00f\\x00f'", "b'\\x00x\\x00\\\\\\x00u\\x00d\\x008\\x000\\x000\\x00\\\\\\x00u\\x00d\\x00c\\x000\\x000\\x00y'", "b'\\x00t\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n'", "b'\\x00\\x00\\x00\\x7f\\x00\\x80\\x00\\xff'", "'\\u6162\\\\x63'", "'\\u61ff\\\\x62'", "'\\ueda0\\u807a'", "'\\ue282'", "'\\u818d\\\\x90'", "'\\u5c78\\\\x34'", "'\\u5c75\\u3230\\u6163\\u5c4e\\u7b44\\u4947\\u4954\\u204f\\u4e45\\\\x7d'", "'\\ufffe\\xd8\\\\x00'", "'\\x00\\u1100'", "'\\uc3a9\\ue282\\\\xac'"]),
    ('utf-16-be', 'xmlcharrefreplace', ["b'\\x00a\\x00b\\x00c'", "b'\\x00h\\x00\\xe9\\x00l\\x00l\\x00o'", "b'\\x00a \\xac\\x00b \\xac'", "b'\\xd8=\\xde\\x00\\x00x'", "b'\\x00a\\x00&\\x00#\\x005\\x006\\x005\\x007\\x005\\x00;'", "b'\\x00x\\x00&\\x00#\\x005\\x005\\x002\\x009\\x006\\x00;\\x00&\\x00#\\x005\\x006\\x003\\x002\\x000\\x00;\\x00y'", "b'\\x00t\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n'", "b'\\x00\\x00\\x00\\x7f\\x00\\x80\\x00\\xff'", 'TypeError:"decoding with \'utf-16-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\ueda0\\u807a'", "'\\ue282'", 'TypeError:"decoding with \'utf-16-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\x00\\u1100'", 'TypeError:"decoding with \'utf-16-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"']),
    ('utf-16-be', 'namereplace', ["b'\\x00a\\x00b\\x00c'", "b'\\x00h\\x00\\xe9\\x00l\\x00l\\x00o'", "b'\\x00a \\xac\\x00b \\xac'", "b'\\xd8=\\xde\\x00\\x00x'", "b'\\x00a\\x00\\\\\\x00u\\x00d\\x00c\\x00f\\x00f'", "b'\\x00x\\x00\\\\\\x00u\\x00d\\x008\\x000\\x000\\x00\\\\\\x00u\\x00d\\x00c\\x000\\x000\\x00y'", "b'\\x00t\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n'", "b'\\x00\\x00\\x00\\x7f\\x00\\x80\\x00\\xff'", 'TypeError:"decoding with \'utf-16-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\ueda0\\u807a'", "'\\ue282'", 'TypeError:"decoding with \'utf-16-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-16-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\x00\\u1100'", 'TypeError:"decoding with \'utf-16-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"']),
    ('utf-16-be', 'surrogateescape', ["b'\\x00a\\x00b\\x00c'", "b'\\x00h\\x00\\xe9\\x00l\\x00l\\x00o'", "b'\\x00a \\xac\\x00b \\xac'", "b'\\xd8=\\xde\\x00\\x00x'", 'UnicodeEncodeError:"\'utf-16-be\' codec can\'t encode character \'\\\\udcff\' in position 1: surrogates not allowed":1-2', 'UnicodeEncodeError:"\'utf-16-be\' codec can\'t encode character \'\\\\ud800\' in position 1: surrogates not allowed":1-2', "b'\\x00t\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n'", "b'\\x00\\x00\\x00\\x7f\\x00\\x80\\x00\\xff'", 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x63 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x62 in position 2: truncated data":2-3', "'\\ueda0\\u807a'", "'\\ue282'", "'\\u818d\\udc90'", 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x34 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x7d in position 18: truncated data":18-19', 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x00 in position 4: truncated data":4-5', "'\\x00\\u1100'", "'\\uc3a9\\ue282\\udcac'"]),
    ('utf-16-be', 'surrogatepass', ["b'\\x00a\\x00b\\x00c'", "b'\\x00h\\x00\\xe9\\x00l\\x00l\\x00o'", "b'\\x00a \\xac\\x00b \\xac'", "b'\\xd8=\\xde\\x00\\x00x'", "b'\\x00a\\xdc\\xff'", "b'\\x00x\\xd8\\x00\\xdc\\x00\\x00y'", "b'\\x00t\\x00a\\x00b\\x00\\t\\x00\\\\\\x00n'", "b'\\x00\\x00\\x00\\x7f\\x00\\x80\\x00\\xff'", 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x63 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x62 in position 2: truncated data":2-3', "'\\ueda0\\u807a'", "'\\ue282'", 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x90 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x34 in position 2: truncated data":2-3', 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x7d in position 18: truncated data":18-19', 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0x00 in position 4: truncated data":4-5', "'\\x00\\u1100'", 'UnicodeDecodeError:"\'utf-16-be\' codec can\'t decode byte 0xac in position 4: truncated data":4-5']),
    ('utf-32', 'strict', ["b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", 'UnicodeEncodeError:"\'utf-32\' codec can\'t encode character \'\\\\udcff\' in position 1: surrogates not allowed":1-2', 'UnicodeEncodeError:"\'utf-32\' codec can\'t encode character \'\\\\ud800\' in position 1: surrogates not allowed":1-2', "b'\\xff\\xfe\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-1: truncated data":0-2', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4']),
    ('utf-32', 'ignore', ["b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00x\\x00\\x00\\x00y\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", "''", "''", "''", "''", "''", "''", "''", "''", "''", "''"]),
    ('utf-32', 'replace', ["b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00?\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00x\\x00\\x00\\x00?\\x00\\x00\\x00?\\x00\\x00\\x00y\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", "'\\ufffd'", "'\\ufffd'", "'\\ufffd'", "'\\ufffd'", "'\\ufffd'", "'\\ufffd'", "'\\ufffd\\ufffd\\ufffd\\ufffd\\ufffd'", "'\\ufffd\\ufffd'", "'\\ufffd'", "'\\ufffd\\ufffd'"]),
    ('utf-32', 'backslashreplace', ["b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x00c\\x00\\x00\\x00f\\x00\\x00\\x00f\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00x\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x008\\x00\\x00\\x000\\x00\\x00\\x000\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x00c\\x00\\x00\\x000\\x00\\x00\\x000\\x00\\x00\\x00y\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", "'\\\\x61\\\\x62\\\\x63'", "'\\\\x61\\\\xff\\\\x62'", "'\\\\xed\\\\xa0\\\\x80\\\\x7a'", "'\\\\xe2\\\\x82'", "'\\\\x81\\\\x8d\\\\x90'", "'\\\\x5c\\\\x78\\\\x34'", "'\\\\x5c\\\\x75\\\\x32\\\\x30\\\\x61\\\\x63\\\\x5c\\\\x4e\\\\x7b\\\\x44\\\\x49\\\\x47\\\\x49\\\\x54\\\\x20\\\\x4f\\\\x4e\\\\x45\\\\x7d'", "'\\\\xff\\\\xfe\\\\x00\\\\xd8\\\\x00'", "'\\\\x00\\\\x00\\\\x11\\\\x00'", "'\\\\xc3\\\\xa9\\\\xe2\\\\x82\\\\xac'"]),
    ('utf-32', 'xmlcharrefreplace', ["b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00&\\x00\\x00\\x00#\\x00\\x00\\x005\\x00\\x00\\x006\\x00\\x00\\x005\\x00\\x00\\x007\\x00\\x00\\x005\\x00\\x00\\x00;\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00x\\x00\\x00\\x00&\\x00\\x00\\x00#\\x00\\x00\\x005\\x00\\x00\\x005\\x00\\x00\\x002\\x00\\x00\\x009\\x00\\x00\\x006\\x00\\x00\\x00;\\x00\\x00\\x00&\\x00\\x00\\x00#\\x00\\x00\\x005\\x00\\x00\\x006\\x00\\x00\\x003\\x00\\x00\\x002\\x00\\x00\\x000\\x00\\x00\\x00;\\x00\\x00\\x00y\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"']),
    ('utf-32', 'namereplace', ["b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x00c\\x00\\x00\\x00f\\x00\\x00\\x00f\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00x\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x008\\x00\\x00\\x000\\x00\\x00\\x000\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x00c\\x00\\x00\\x000\\x00\\x00\\x000\\x00\\x00\\x00y\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"']),
    ('utf-32', 'surrogateescape', ["b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", 'UnicodeEncodeError:"\'utf-32\' codec can\'t encode character \'\\\\udcff\' in position 1: surrogates not allowed":1-2', 'UnicodeEncodeError:"\'utf-32\' codec can\'t encode character \'\\\\ud800\' in position 1: surrogates not allowed":1-2', "b'\\xff\\xfe\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode byte 0x7a in position 3: truncated data":3-4', "'\\udce2\\udc82'", "'\\udc81\\udc8d\\udc90'", 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 2-4: truncated data":2-5', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', "'\\udcc3\\udca9\\udce2\\udc82\\udcac'"]),
    ('utf-32', 'surrogatepass', ["b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00a\\x00\\x00\\x00\\xff\\xdc\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00x\\x00\\x00\\x00\\x00\\xd8\\x00\\x00\\x00\\xdc\\x00\\x00y\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\xff\\xfe\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-1: truncated data":0-2', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4']),
    ('utf-32-le', 'strict', ["b'a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", 'UnicodeEncodeError:"\'utf-32-le\' codec can\'t encode character \'\\\\udcff\' in position 1: surrogates not allowed":1-2', 'UnicodeEncodeError:"\'utf-32-le\' codec can\'t encode character \'\\\\ud800\' in position 1: surrogates not allowed":1-2', "b't\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-1: truncated data":0-2', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4']),
    ('utf-32-le', 'ignore', ["b'a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", "b'a\\x00\\x00\\x00'", "b'x\\x00\\x00\\x00y\\x00\\x00\\x00'", "b't\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", "''", "''", "''", "''", "''", "''", "''", "''", "''", "''"]),
    ('utf-32-le', 'replace', ["b'a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", "b'a\\x00\\x00\\x00?\\x00\\x00\\x00'", "b'x\\x00\\x00\\x00?\\x00\\x00\\x00?\\x00\\x00\\x00y\\x00\\x00\\x00'", "b't\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", "'\\ufffd'", "'\\ufffd'", "'\\ufffd'", "'\\ufffd'", "'\\ufffd'", "'\\ufffd'", "'\\ufffd\\ufffd\\ufffd\\ufffd\\ufffd'", "'\\ufffd\\ufffd'", "'\\ufffd'", "'\\ufffd\\ufffd'"]),
    ('utf-32-le', 'backslashreplace', ["b'a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", "b'a\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x00c\\x00\\x00\\x00f\\x00\\x00\\x00f\\x00\\x00\\x00'", "b'x\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x008\\x00\\x00\\x000\\x00\\x00\\x000\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x00c\\x00\\x00\\x000\\x00\\x00\\x000\\x00\\x00\\x00y\\x00\\x00\\x00'", "b't\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", "'\\\\x61\\\\x62\\\\x63'", "'\\\\x61\\\\xff\\\\x62'", "'\\\\xed\\\\xa0\\\\x80\\\\x7a'", "'\\\\xe2\\\\x82'", "'\\\\x81\\\\x8d\\\\x90'", "'\\\\x5c\\\\x78\\\\x34'", "'\\\\x5c\\\\x75\\\\x32\\\\x30\\\\x61\\\\x63\\\\x5c\\\\x4e\\\\x7b\\\\x44\\\\x49\\\\x47\\\\x49\\\\x54\\\\x20\\\\x4f\\\\x4e\\\\x45\\\\x7d'", "'\\\\xff\\\\xfe\\\\x00\\\\xd8\\\\x00'", "'\\\\x00\\\\x00\\\\x11\\\\x00'", "'\\\\xc3\\\\xa9\\\\xe2\\\\x82\\\\xac'"]),
    ('utf-32-le', 'xmlcharrefreplace', ["b'a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", "b'a\\x00\\x00\\x00&\\x00\\x00\\x00#\\x00\\x00\\x005\\x00\\x00\\x006\\x00\\x00\\x005\\x00\\x00\\x007\\x00\\x00\\x005\\x00\\x00\\x00;\\x00\\x00\\x00'", "b'x\\x00\\x00\\x00&\\x00\\x00\\x00#\\x00\\x00\\x005\\x00\\x00\\x005\\x00\\x00\\x002\\x00\\x00\\x009\\x00\\x00\\x006\\x00\\x00\\x00;\\x00\\x00\\x00&\\x00\\x00\\x00#\\x00\\x00\\x005\\x00\\x00\\x006\\x00\\x00\\x003\\x00\\x00\\x002\\x00\\x00\\x000\\x00\\x00\\x00;\\x00\\x00\\x00y\\x00\\x00\\x00'", "b't\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"']),
    ('utf-32-le', 'namereplace', ["b'a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", "b'a\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x00c\\x00\\x00\\x00f\\x00\\x00\\x00f\\x00\\x00\\x00'", "b'x\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x008\\x00\\x00\\x000\\x00\\x00\\x000\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x00c\\x00\\x00\\x000\\x00\\x00\\x000\\x00\\x00\\x00y\\x00\\x00\\x00'", "b't\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-le\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"']),
    ('utf-32-le', 'surrogateescape', ["b'a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", 'UnicodeEncodeError:"\'utf-32-le\' codec can\'t encode character \'\\\\udcff\' in position 1: surrogates not allowed":1-2', 'UnicodeEncodeError:"\'utf-32-le\' codec can\'t encode character \'\\\\ud800\' in position 1: surrogates not allowed":1-2', "b't\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode byte 0x7a in position 3: truncated data":3-4', "'\\udce2\\udc82'", "'\\udc81\\udc8d\\udc90'", 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 2-4: truncated data":2-5', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', "'\\udcc3\\udca9\\udce2\\udc82\\udcac'"]),
    ('utf-32-le', 'surrogatepass', ["b'a\\x00\\x00\\x00b\\x00\\x00\\x00c\\x00\\x00\\x00'", "b'h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o\\x00\\x00\\x00'", "b'a\\x00\\x00\\x00\\xac \\x00\\x00b\\x00\\x00\\x00\\xac \\x00\\x00'", "b'\\x00\\xf6\\x01\\x00x\\x00\\x00\\x00'", "b'a\\x00\\x00\\x00\\xff\\xdc\\x00\\x00'", "b'x\\x00\\x00\\x00\\x00\\xd8\\x00\\x00\\x00\\xdc\\x00\\x00y\\x00\\x00\\x00'", "b't\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n\\x00\\x00\\x00'", "b'\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff\\x00\\x00\\x00'", 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-1: truncated data":0-2', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-le\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4']),
    ('utf-32-be', 'strict', ["b'\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c'", "b'\\x00\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o'", "b'\\x00\\x00\\x00a\\x00\\x00 \\xac\\x00\\x00\\x00b\\x00\\x00 \\xac'", "b'\\x00\\x01\\xf6\\x00\\x00\\x00\\x00x'", 'UnicodeEncodeError:"\'utf-32-be\' codec can\'t encode character \'\\\\udcff\' in position 1: surrogates not allowed":1-2', 'UnicodeEncodeError:"\'utf-32-be\' codec can\'t encode character \'\\\\ud800\' in position 1: surrogates not allowed":1-2', "b'\\x00\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n'", "b'\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff'", 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-1: truncated data":0-2', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', "'\\u1100'", 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4']),
    ('utf-32-be', 'ignore', ["b'\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c'", "b'\\x00\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o'", "b'\\x00\\x00\\x00a\\x00\\x00 \\xac\\x00\\x00\\x00b\\x00\\x00 \\xac'", "b'\\x00\\x01\\xf6\\x00\\x00\\x00\\x00x'", "b'\\x00\\x00\\x00a'", "b'\\x00\\x00\\x00x\\x00\\x00\\x00y'", "b'\\x00\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n'", "b'\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff'", "''", "''", "''", "''", "''", "''", "''", "''", "'\\u1100'", "''"]),
    ('utf-32-be', 'replace', ["b'\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c'", "b'\\x00\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o'", "b'\\x00\\x00\\x00a\\x00\\x00 \\xac\\x00\\x00\\x00b\\x00\\x00 \\xac'", "b'\\x00\\x01\\xf6\\x00\\x00\\x00\\x00x'", "b'\\x00\\x00\\x00a\\x00\\x00\\x00?'", "b'\\x00\\x00\\x00x\\x00\\x00\\x00?\\x00\\x00\\x00?\\x00\\x00\\x00y'", "b'\\x00\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n'", "b'\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff'", "'\\ufffd'", "'\\ufffd'", "'\\ufffd'", "'\\ufffd'", "'\\ufffd'", "'\\ufffd'", "'\\ufffd\\ufffd\\ufffd\\ufffd\\ufffd'", "'\\ufffd\\ufffd'", "'\\u1100'", "'\\ufffd\\ufffd'"]),
    ('utf-32-be', 'backslashreplace', ["b'\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c'", "b'\\x00\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o'", "b'\\x00\\x00\\x00a\\x00\\x00 \\xac\\x00\\x00\\x00b\\x00\\x00 \\xac'", "b'\\x00\\x01\\xf6\\x00\\x00\\x00\\x00x'", "b'\\x00\\x00\\x00a\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x00c\\x00\\x00\\x00f\\x00\\x00\\x00f'", "b'\\x00\\x00\\x00x\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x008\\x00\\x00\\x000\\x00\\x00\\x000\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x00c\\x00\\x00\\x000\\x00\\x00\\x000\\x00\\x00\\x00y'", "b'\\x00\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n'", "b'\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff'", "'\\\\x61\\\\x62\\\\x63'", "'\\\\x61\\\\xff\\\\x62'", "'\\\\xed\\\\xa0\\\\x80\\\\x7a'", "'\\\\xe2\\\\x82'", "'\\\\x81\\\\x8d\\\\x90'", "'\\\\x5c\\\\x78\\\\x34'", "'\\\\x5c\\\\x75\\\\x32\\\\x30\\\\x61\\\\x63\\\\x5c\\\\x4e\\\\x7b\\\\x44\\\\x49\\\\x47\\\\x49\\\\x54\\\\x20\\\\x4f\\\\x4e\\\\x45\\\\x7d'", "'\\\\xff\\\\xfe\\\\x00\\\\xd8\\\\x00'", "'\\u1100'", "'\\\\xc3\\\\xa9\\\\xe2\\\\x82\\\\xac'"]),
    ('utf-32-be', 'xmlcharrefreplace', ["b'\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c'", "b'\\x00\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o'", "b'\\x00\\x00\\x00a\\x00\\x00 \\xac\\x00\\x00\\x00b\\x00\\x00 \\xac'", "b'\\x00\\x01\\xf6\\x00\\x00\\x00\\x00x'", "b'\\x00\\x00\\x00a\\x00\\x00\\x00&\\x00\\x00\\x00#\\x00\\x00\\x005\\x00\\x00\\x006\\x00\\x00\\x005\\x00\\x00\\x007\\x00\\x00\\x005\\x00\\x00\\x00;'", "b'\\x00\\x00\\x00x\\x00\\x00\\x00&\\x00\\x00\\x00#\\x00\\x00\\x005\\x00\\x00\\x005\\x00\\x00\\x002\\x00\\x00\\x009\\x00\\x00\\x006\\x00\\x00\\x00;\\x00\\x00\\x00&\\x00\\x00\\x00#\\x00\\x00\\x005\\x00\\x00\\x006\\x00\\x00\\x003\\x00\\x00\\x002\\x00\\x00\\x000\\x00\\x00\\x00;\\x00\\x00\\x00y'", "b'\\x00\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n'", "b'\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff'", 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\u1100'", 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"']),
    ('utf-32-be', 'namereplace', ["b'\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c'", "b'\\x00\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o'", "b'\\x00\\x00\\x00a\\x00\\x00 \\xac\\x00\\x00\\x00b\\x00\\x00 \\xac'", "b'\\x00\\x01\\xf6\\x00\\x00\\x00\\x00x'", "b'\\x00\\x00\\x00a\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x00c\\x00\\x00\\x00f\\x00\\x00\\x00f'", "b'\\x00\\x00\\x00x\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x008\\x00\\x00\\x000\\x00\\x00\\x000\\x00\\x00\\x00\\\\\\x00\\x00\\x00u\\x00\\x00\\x00d\\x00\\x00\\x00c\\x00\\x00\\x000\\x00\\x00\\x000\\x00\\x00\\x00y'", "b'\\x00\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n'", "b'\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff'", 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\u1100'", 'TypeError:"decoding with \'utf-32-be\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"']),
    ('utf-32-be', 'surrogateescape', ["b'\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c'", "b'\\x00\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o'", "b'\\x00\\x00\\x00a\\x00\\x00 \\xac\\x00\\x00\\x00b\\x00\\x00 \\xac'", "b'\\x00\\x01\\xf6\\x00\\x00\\x00\\x00x'", 'UnicodeEncodeError:"\'utf-32-be\' codec can\'t encode character \'\\\\udcff\' in position 1: surrogates not allowed":1-2', 'UnicodeEncodeError:"\'utf-32-be\' codec can\'t encode character \'\\\\ud800\' in position 1: surrogates not allowed":1-2', "b'\\x00\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n'", "b'\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff'", 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode byte 0x7a in position 3: truncated data":3-4', "'\\udce2\\udc82'", "'\\udc81\\udc8d\\udc90'", 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 2-4: truncated data":2-5', "'\\u1100'", "'\\udcc3\\udca9\\udce2\\udc82\\udcac'"]),
    ('utf-32-be', 'surrogatepass', ["b'\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00c'", "b'\\x00\\x00\\x00h\\x00\\x00\\x00\\xe9\\x00\\x00\\x00l\\x00\\x00\\x00l\\x00\\x00\\x00o'", "b'\\x00\\x00\\x00a\\x00\\x00 \\xac\\x00\\x00\\x00b\\x00\\x00 \\xac'", "b'\\x00\\x01\\xf6\\x00\\x00\\x00\\x00x'", "b'\\x00\\x00\\x00a\\x00\\x00\\xdc\\xff'", "b'\\x00\\x00\\x00x\\x00\\x00\\xd8\\x00\\x00\\x00\\xdc\\x00\\x00\\x00\\x00y'", "b'\\x00\\x00\\x00t\\x00\\x00\\x00a\\x00\\x00\\x00b\\x00\\x00\\x00\\t\\x00\\x00\\x00\\\\\\x00\\x00\\x00n'", "b'\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x7f\\x00\\x00\\x00\\x80\\x00\\x00\\x00\\xff'", 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-1: truncated data":0-2', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-2: truncated data":0-3', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4', "'\\u1100'", 'UnicodeDecodeError:"\'utf-32-be\' codec can\'t decode bytes in position 0-3: code point not in range(0x110000)":0-4']),
    ('latin-1', 'strict', ["b'abc'", "b'h\\xe9llo'", 'UnicodeEncodeError:"\'latin-1\' codec can\'t encode character \'\\\\u20ac\' in position 1: ordinal not in range(256)":1-2', 'UnicodeEncodeError:"\'latin-1\' codec can\'t encode character \'\\\\U0001f600\' in position 0: ordinal not in range(256)":0-1', 'UnicodeEncodeError:"\'latin-1\' codec can\'t encode character \'\\\\udcff\' in position 1: ordinal not in range(256)":1-2', 'UnicodeEncodeError:"\'latin-1\' codec can\'t encode characters in position 1-2: ordinal not in range(256)":1-3', "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('latin-1', 'ignore', ["b'abc'", "b'h\\xe9llo'", "b'ab'", "b'x'", "b'a'", "b'xy'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('latin-1', 'replace', ["b'abc'", "b'h\\xe9llo'", "b'a?b?'", "b'?x'", "b'a?'", "b'x??y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('latin-1', 'backslashreplace', ["b'abc'", "b'h\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('latin-1', 'xmlcharrefreplace', ["b'abc'", "b'h\\xe9llo'", "b'a&#8364;b&#8364;'", "b'&#128512;x'", "b'a&#56575;'", "b'x&#55296;&#56320;y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('latin-1', 'namereplace', ["b'abc'", "b'h\\xe9llo'", "b'a\\\\N{EURO SIGN}b\\\\N{EURO SIGN}'", "b'\\\\N{GRINNING FACE}x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('latin-1', 'surrogateescape', ["b'abc'", "b'h\\xe9llo'", 'UnicodeEncodeError:"\'latin-1\' codec can\'t encode character \'\\\\u20ac\' in position 1: ordinal not in range(256)":1-2', 'UnicodeEncodeError:"\'latin-1\' codec can\'t encode character \'\\\\U0001f600\' in position 0: ordinal not in range(256)":0-1', "b'a\\xff'", 'UnicodeEncodeError:"\'latin-1\' codec can\'t encode characters in position 1-2: ordinal not in range(256)":1-3', "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('latin-1', 'surrogatepass', ["b'abc'", "b'h\\xe9llo'", 'UnicodeEncodeError:"\'latin-1\' codec can\'t encode character \'\\\\u20ac\' in position 1: ordinal not in range(256)":1-2', 'UnicodeEncodeError:"\'latin-1\' codec can\'t encode character \'\\\\U0001f600\' in position 0: ordinal not in range(256)":0-1', 'UnicodeEncodeError:"\'latin-1\' codec can\'t encode character \'\\\\udcff\' in position 1: ordinal not in range(256)":1-2', 'UnicodeEncodeError:"\'latin-1\' codec can\'t encode characters in position 1-2: ordinal not in range(256)":1-3', "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('ascii', 'strict', ["b'abc'", 'UnicodeEncodeError:"\'ascii\' codec can\'t encode character \'\\\\xe9\' in position 1: ordinal not in range(128)":1-2', 'UnicodeEncodeError:"\'ascii\' codec can\'t encode character \'\\\\u20ac\' in position 1: ordinal not in range(128)":1-2', 'UnicodeEncodeError:"\'ascii\' codec can\'t encode character \'\\\\U0001f600\' in position 0: ordinal not in range(128)":0-1', 'UnicodeEncodeError:"\'ascii\' codec can\'t encode character \'\\\\udcff\' in position 1: ordinal not in range(128)":1-2', 'UnicodeEncodeError:"\'ascii\' codec can\'t encode characters in position 1-2: ordinal not in range(128)":1-3', "b'tab\\t\\\\n'", 'UnicodeEncodeError:"\'ascii\' codec can\'t encode characters in position 2-3: ordinal not in range(128)":2-4', "'abc'", 'UnicodeDecodeError:"\'ascii\' codec can\'t decode byte 0xff in position 1: ordinal not in range(128)":1-2', 'UnicodeDecodeError:"\'ascii\' codec can\'t decode byte 0xed in position 0: ordinal not in range(128)":0-1', 'UnicodeDecodeError:"\'ascii\' codec can\'t decode byte 0xe2 in position 0: ordinal not in range(128)":0-1', 'UnicodeDecodeError:"\'ascii\' codec can\'t decode byte 0x81 in position 0: ordinal not in range(128)":0-1', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", 'UnicodeDecodeError:"\'ascii\' codec can\'t decode byte 0xff in position 0: ordinal not in range(128)":0-1', "'\\x00\\x00\\x11\\x00'", 'UnicodeDecodeError:"\'ascii\' codec can\'t decode byte 0xc3 in position 0: ordinal not in range(128)":0-1']),
    ('ascii', 'ignore', ["b'abc'", "b'hllo'", "b'ab'", "b'x'", "b'a'", "b'xy'", "b'tab\\t\\\\n'", "b'\\x00\\x7f'", "'abc'", "'ab'", "'z'", "''", "''", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\x00\\x00'", "'\\x00\\x00\\x11\\x00'", "''"]),
    ('ascii', 'replace', ["b'abc'", "b'h?llo'", "b'a?b?'", "b'?x'", "b'a?'", "b'x??y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f??'", "'abc'", "'a\\ufffdb'", "'\\ufffd\\ufffd\\ufffdz'", "'\\ufffd\\ufffd'", "'\\ufffd\\ufffd\\ufffd'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\ufffd\\ufffd\\x00\\ufffd\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\ufffd\\ufffd\\ufffd\\ufffd\\ufffd'"]),
    ('ascii', 'backslashreplace', ["b'abc'", "b'h\\\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\\\x80\\\\xff'", "'abc'", "'a\\\\xffb'", "'\\\\xed\\\\xa0\\\\x80z'", "'\\\\xe2\\\\x82'", "'\\\\x81\\\\x8d\\\\x90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\\\xff\\\\xfe\\x00\\\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\\\xc3\\\\xa9\\\\xe2\\\\x82\\\\xac'"]),
    ('ascii', 'xmlcharrefreplace', ["b'abc'", "b'h&#233;llo'", "b'a&#8364;b&#8364;'", "b'&#128512;x'", "b'a&#56575;'", "b'x&#55296;&#56320;y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f&#128;&#255;'", "'abc'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', "'\\x00\\x00\\x11\\x00'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"']),
    ('ascii', 'namereplace', ["b'abc'", "b'h\\\\N{LATIN SMALL LETTER E WITH ACUTE}llo'", "b'a\\\\N{EURO SIGN}b\\\\N{EURO SIGN}'", "b'\\\\N{GRINNING FACE}x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\\\x80\\\\N{LATIN SMALL LETTER Y WITH DIAERESIS}'", "'abc'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"', "'\\x00\\x00\\x11\\x00'", 'TypeError:"don\'t know how to handle UnicodeDecodeError in error callback"']),
    ('ascii', 'surrogateescape', ["b'abc'", 'UnicodeEncodeError:"\'ascii\' codec can\'t encode character \'\\\\xe9\' in position 1: ordinal not in range(128)":1-2', 'UnicodeEncodeError:"\'ascii\' codec can\'t encode character \'\\\\u20ac\' in position 1: ordinal not in range(128)":1-2', 'UnicodeEncodeError:"\'ascii\' codec can\'t encode character \'\\\\U0001f600\' in position 0: ordinal not in range(128)":0-1', "b'a\\xff'", 'UnicodeEncodeError:"\'ascii\' codec can\'t encode characters in position 1-2: ordinal not in range(128)":1-3', "b'tab\\t\\\\n'", 'UnicodeEncodeError:"\'ascii\' codec can\'t encode characters in position 2-3: ordinal not in range(128)":2-4', "'abc'", "'a\\udcffb'", "'\\udced\\udca0\\udc80z'", "'\\udce2\\udc82'", "'\\udc81\\udc8d\\udc90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\udcff\\udcfe\\x00\\udcd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\udcc3\\udca9\\udce2\\udc82\\udcac'"]),
    ('ascii', 'surrogatepass', ["b'abc'", 'UnicodeEncodeError:"\'ascii\' codec can\'t encode character \'\\\\xe9\' in position 1: ordinal not in range(128)":1-2', 'UnicodeEncodeError:"\'ascii\' codec can\'t encode character \'\\\\u20ac\' in position 1: ordinal not in range(128)":1-2', 'UnicodeEncodeError:"\'ascii\' codec can\'t encode character \'\\\\U0001f600\' in position 0: ordinal not in range(128)":0-1', 'UnicodeEncodeError:"\'ascii\' codec can\'t encode character \'\\\\udcff\' in position 1: ordinal not in range(128)":1-2', 'UnicodeEncodeError:"\'ascii\' codec can\'t encode characters in position 1-2: ordinal not in range(128)":1-3', "b'tab\\t\\\\n'", 'UnicodeEncodeError:"\'ascii\' codec can\'t encode characters in position 2-3: ordinal not in range(128)":2-4', "'abc'", 'UnicodeDecodeError:"\'ascii\' codec can\'t decode byte 0xff in position 1: ordinal not in range(128)":1-2', 'UnicodeDecodeError:"\'ascii\' codec can\'t decode byte 0xed in position 0: ordinal not in range(128)":0-1', 'UnicodeDecodeError:"\'ascii\' codec can\'t decode byte 0xe2 in position 0: ordinal not in range(128)":0-1', 'UnicodeDecodeError:"\'ascii\' codec can\'t decode byte 0x81 in position 0: ordinal not in range(128)":0-1', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", 'UnicodeDecodeError:"\'ascii\' codec can\'t decode byte 0xff in position 0: ordinal not in range(128)":0-1', "'\\x00\\x00\\x11\\x00'", 'UnicodeDecodeError:"\'ascii\' codec can\'t decode byte 0xc3 in position 0: ordinal not in range(128)":0-1']),
    ('cp437', 'strict', ["b'abc'", "b'h\\x82llo'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\u20ac\' in position 1: character maps to <undefined>":1-2', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\U0001f600\' in position 0: character maps to <undefined>":0-1', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\udcff\' in position 1: character maps to <undefined>":1-2', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode characters in position 1-2: character maps to <undefined>":1-3', "b'tab\\t\\\\n'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\x80\' in position 2: character maps to <undefined>":2-3', "'abc'", "'a\\xa0b'", "'\\u03c6\\xe1\\xc7z'", "'\\u0393\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\u256a\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\u2310\\u0393\\xe9\\xbc'"]),
    ('cp437', 'ignore', ["b'abc'", "b'h\\x82llo'", "b'ab'", "b'x'", "b'a'", "b'xy'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x98'", "'abc'", "'a\\xa0b'", "'\\u03c6\\xe1\\xc7z'", "'\\u0393\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\u256a\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\u2310\\u0393\\xe9\\xbc'"]),
    ('cp437', 'replace', ["b'abc'", "b'h\\x82llo'", "b'a?b?'", "b'?x'", "b'a?'", "b'x??y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f?\\x98'", "'abc'", "'a\\xa0b'", "'\\u03c6\\xe1\\xc7z'", "'\\u0393\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\u256a\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\u2310\\u0393\\xe9\\xbc'"]),
    ('cp437', 'backslashreplace', ["b'abc'", "b'h\\x82llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\\\x80\\x98'", "'abc'", "'a\\xa0b'", "'\\u03c6\\xe1\\xc7z'", "'\\u0393\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\u256a\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\u2310\\u0393\\xe9\\xbc'"]),
    ('cp437', 'xmlcharrefreplace', ["b'abc'", "b'h\\x82llo'", "b'a&#8364;b&#8364;'", "b'&#128512;x'", "b'a&#56575;'", "b'x&#55296;&#56320;y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f&#128;\\x98'", "'abc'", "'a\\xa0b'", "'\\u03c6\\xe1\\xc7z'", "'\\u0393\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\u256a\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\u2310\\u0393\\xe9\\xbc'"]),
    ('cp437', 'namereplace', ["b'abc'", "b'h\\x82llo'", "b'a\\\\N{EURO SIGN}b\\\\N{EURO SIGN}'", "b'\\\\N{GRINNING FACE}x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\\\x80\\x98'", "'abc'", "'a\\xa0b'", "'\\u03c6\\xe1\\xc7z'", "'\\u0393\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\u256a\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\u2310\\u0393\\xe9\\xbc'"]),
    ('cp437', 'surrogateescape', ["b'abc'", "b'h\\x82llo'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\u20ac\' in position 1: character maps to <undefined>":1-2', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\U0001f600\' in position 0: character maps to <undefined>":0-1', "b'a\\xff'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode characters in position 1-2: character maps to <undefined>":1-3', "b'tab\\t\\\\n'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\x80\' in position 2: character maps to <undefined>":2-3', "'abc'", "'a\\xa0b'", "'\\u03c6\\xe1\\xc7z'", "'\\u0393\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\u256a\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\u2310\\u0393\\xe9\\xbc'"]),
    ('cp437', 'surrogatepass', ["b'abc'", "b'h\\x82llo'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\u20ac\' in position 1: character maps to <undefined>":1-2', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\U0001f600\' in position 0: character maps to <undefined>":0-1', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\udcff\' in position 1: character maps to <undefined>":1-2', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode characters in position 1-2: character maps to <undefined>":1-3', "b'tab\\t\\\\n'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\x80\' in position 2: character maps to <undefined>":2-3', "'abc'", "'a\\xa0b'", "'\\u03c6\\xe1\\xc7z'", "'\\u0393\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\u256a\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\u2310\\u0393\\xe9\\xbc'"]),
    ('cp850', 'strict', ["b'abc'", "b'h\\x82llo'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\u20ac\' in position 1: character maps to <undefined>":1-2', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\U0001f600\' in position 0: character maps to <undefined>":0-1', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\udcff\' in position 1: character maps to <undefined>":1-2', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode characters in position 1-2: character maps to <undefined>":1-3', "b'tab\\t\\\\n'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\x80\' in position 2: character maps to <undefined>":2-3', "'abc'", "'a\\xa0b'", "'\\xdd\\xe1\\xc7z'", "'\\xd4\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\xcf\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\xae\\xd4\\xe9\\xbc'"]),
    ('cp850', 'ignore', ["b'abc'", "b'h\\x82llo'", "b'ab'", "b'x'", "b'a'", "b'xy'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x98'", "'abc'", "'a\\xa0b'", "'\\xdd\\xe1\\xc7z'", "'\\xd4\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\xcf\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\xae\\xd4\\xe9\\xbc'"]),
    ('cp850', 'replace', ["b'abc'", "b'h\\x82llo'", "b'a?b?'", "b'?x'", "b'a?'", "b'x??y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f?\\x98'", "'abc'", "'a\\xa0b'", "'\\xdd\\xe1\\xc7z'", "'\\xd4\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\xcf\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\xae\\xd4\\xe9\\xbc'"]),
    ('cp850', 'backslashreplace', ["b'abc'", "b'h\\x82llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\\\x80\\x98'", "'abc'", "'a\\xa0b'", "'\\xdd\\xe1\\xc7z'", "'\\xd4\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\xcf\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\xae\\xd4\\xe9\\xbc'"]),
    ('cp850', 'xmlcharrefreplace', ["b'abc'", "b'h\\x82llo'", "b'a&#8364;b&#8364;'", "b'&#128512;x'", "b'a&#56575;'", "b'x&#55296;&#56320;y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f&#128;\\x98'", "'abc'", "'a\\xa0b'", "'\\xdd\\xe1\\xc7z'", "'\\xd4\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\xcf\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\xae\\xd4\\xe9\\xbc'"]),
    ('cp850', 'namereplace', ["b'abc'", "b'h\\x82llo'", "b'a\\\\N{EURO SIGN}b\\\\N{EURO SIGN}'", "b'\\\\N{GRINNING FACE}x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\\\x80\\x98'", "'abc'", "'a\\xa0b'", "'\\xdd\\xe1\\xc7z'", "'\\xd4\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\xcf\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\xae\\xd4\\xe9\\xbc'"]),
    ('cp850', 'surrogateescape', ["b'abc'", "b'h\\x82llo'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\u20ac\' in position 1: character maps to <undefined>":1-2', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\U0001f600\' in position 0: character maps to <undefined>":0-1', "b'a\\xff'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode characters in position 1-2: character maps to <undefined>":1-3', "b'tab\\t\\\\n'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\x80\' in position 2: character maps to <undefined>":2-3', "'abc'", "'a\\xa0b'", "'\\xdd\\xe1\\xc7z'", "'\\xd4\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\xcf\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\xae\\xd4\\xe9\\xbc'"]),
    ('cp850', 'surrogatepass', ["b'abc'", "b'h\\x82llo'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\u20ac\' in position 1: character maps to <undefined>":1-2', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\U0001f600\' in position 0: character maps to <undefined>":0-1', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\udcff\' in position 1: character maps to <undefined>":1-2', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode characters in position 1-2: character maps to <undefined>":1-3', "b'tab\\t\\\\n'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\x80\' in position 2: character maps to <undefined>":2-3', "'abc'", "'a\\xa0b'", "'\\xdd\\xe1\\xc7z'", "'\\xd4\\xe9'", "'\\xfc\\xec\\xc9'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xa0\\u25a0\\x00\\xcf\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u251c\\xae\\xd4\\xe9\\xbc'"]),
    ('cp1252', 'strict', ["b'abc'", "b'h\\xe9llo'", "b'a\\x80b\\x80'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\U0001f600\' in position 0: character maps to <undefined>":0-1', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\udcff\' in position 1: character maps to <undefined>":1-2', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode characters in position 1-2: character maps to <undefined>":1-3', "b'tab\\t\\\\n'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\x80\' in position 2: character maps to <undefined>":2-3', "'abc'", "'a\\xffb'", "'\\xed\\xa0\\u20acz'", "'\\xe2\\u201a'", 'UnicodeDecodeError:"\'charmap\' codec can\'t decode byte 0x81 in position 0: character maps to <undefined>":0-1', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\u201a\\xac'"]),
    ('cp1252', 'ignore', ["b'abc'", "b'h\\xe9llo'", "b'a\\x80b\\x80'", "b'x'", "b'a'", "b'xy'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\u20acz'", "'\\xe2\\u201a'", "''", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\u201a\\xac'"]),
    ('cp1252', 'replace', ["b'abc'", "b'h\\xe9llo'", "b'a\\x80b\\x80'", "b'?x'", "b'a?'", "b'x??y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f?\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\u20acz'", "'\\xe2\\u201a'", "'\\ufffd\\ufffd\\ufffd'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\u201a\\xac'"]),
    ('cp1252', 'backslashreplace', ["b'abc'", "b'h\\xe9llo'", "b'a\\x80b\\x80'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\u20acz'", "'\\xe2\\u201a'", "'\\\\x81\\\\x8d\\\\x90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\u201a\\xac'"]),
    ('cp1252', 'xmlcharrefreplace', ["b'abc'", "b'h\\xe9llo'", "b'a\\x80b\\x80'", "b'&#128512;x'", "b'a&#56575;'", "b'x&#55296;&#56320;y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f&#128;\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\u20acz'", "'\\xe2\\u201a'", 'TypeError:"decoding with \'cp1252\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\u201a\\xac'"]),
    ('cp1252', 'namereplace', ["b'abc'", "b'h\\xe9llo'", "b'a\\x80b\\x80'", "b'\\\\N{GRINNING FACE}x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\u20acz'", "'\\xe2\\u201a'", 'TypeError:"decoding with \'cp1252\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\u201a\\xac'"]),
    ('cp1252', 'surrogateescape', ["b'abc'", "b'h\\xe9llo'", "b'a\\x80b\\x80'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\U0001f600\' in position 0: character maps to <undefined>":0-1', "b'a\\xff'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode characters in position 1-2: character maps to <undefined>":1-3', "b'tab\\t\\\\n'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\x80\' in position 2: character maps to <undefined>":2-3', "'abc'", "'a\\xffb'", "'\\xed\\xa0\\u20acz'", "'\\xe2\\u201a'", "'\\udc81\\udc8d\\udc90'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\u201a\\xac'"]),
    ('cp1252', 'surrogatepass', ["b'abc'", "b'h\\xe9llo'", "b'a\\x80b\\x80'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\U0001f600\' in position 0: character maps to <undefined>":0-1', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\udcff\' in position 1: character maps to <undefined>":1-2', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode characters in position 1-2: character maps to <undefined>":1-3', "b'tab\\t\\\\n'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\x80\' in position 2: character maps to <undefined>":2-3', "'abc'", "'a\\xffb'", "'\\xed\\xa0\\u20acz'", "'\\xe2\\u201a'", 'UnicodeDecodeError:"\'charmap\' codec can\'t decode byte 0x81 in position 0: character maps to <undefined>":0-1', "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\u201a\\xac'"]),
    ('mac-roman', 'strict', ["b'abc'", "b'h\\x8ello'", "b'a\\xdbb\\xdb'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\U0001f600\' in position 0: character maps to <undefined>":0-1', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\udcff\' in position 1: character maps to <undefined>":1-2', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode characters in position 1-2: character maps to <undefined>":1-3', "b'tab\\t\\\\n'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\x80\' in position 2: character maps to <undefined>":2-3', "'abc'", "'a\\u02c7b'", "'\\xcc\\u2020\\xc4z'", "'\\u201a\\xc7'", "'\\xc5\\xe7\\xea'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\u02c7\\u02db\\x00\\xff\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u221a\\xa9\\u201a\\xc7\\xa8'"]),
    ('mac-roman', 'ignore', ["b'abc'", "b'h\\x8ello'", "b'a\\xdbb\\xdb'", "b'x'", "b'a'", "b'xy'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\xd8'", "'abc'", "'a\\u02c7b'", "'\\xcc\\u2020\\xc4z'", "'\\u201a\\xc7'", "'\\xc5\\xe7\\xea'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\u02c7\\u02db\\x00\\xff\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u221a\\xa9\\u201a\\xc7\\xa8'"]),
    ('mac-roman', 'replace', ["b'abc'", "b'h\\x8ello'", "b'a\\xdbb\\xdb'", "b'?x'", "b'a?'", "b'x??y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f?\\xd8'", "'abc'", "'a\\u02c7b'", "'\\xcc\\u2020\\xc4z'", "'\\u201a\\xc7'", "'\\xc5\\xe7\\xea'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\u02c7\\u02db\\x00\\xff\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u221a\\xa9\\u201a\\xc7\\xa8'"]),
    ('mac-roman', 'backslashreplace', ["b'abc'", "b'h\\x8ello'", "b'a\\xdbb\\xdb'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\\\x80\\xd8'", "'abc'", "'a\\u02c7b'", "'\\xcc\\u2020\\xc4z'", "'\\u201a\\xc7'", "'\\xc5\\xe7\\xea'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\u02c7\\u02db\\x00\\xff\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u221a\\xa9\\u201a\\xc7\\xa8'"]),
    ('mac-roman', 'xmlcharrefreplace', ["b'abc'", "b'h\\x8ello'", "b'a\\xdbb\\xdb'", "b'&#128512;x'", "b'a&#56575;'", "b'x&#55296;&#56320;y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f&#128;\\xd8'", "'abc'", "'a\\u02c7b'", "'\\xcc\\u2020\\xc4z'", "'\\u201a\\xc7'", "'\\xc5\\xe7\\xea'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\u02c7\\u02db\\x00\\xff\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u221a\\xa9\\u201a\\xc7\\xa8'"]),
    ('mac-roman', 'namereplace', ["b'abc'", "b'h\\x8ello'", "b'a\\xdbb\\xdb'", "b'\\\\N{GRINNING FACE}x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\\\x80\\xd8'", "'abc'", "'a\\u02c7b'", "'\\xcc\\u2020\\xc4z'", "'\\u201a\\xc7'", "'\\xc5\\xe7\\xea'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\u02c7\\u02db\\x00\\xff\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u221a\\xa9\\u201a\\xc7\\xa8'"]),
    ('mac-roman', 'surrogateescape', ["b'abc'", "b'h\\x8ello'", "b'a\\xdbb\\xdb'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\U0001f600\' in position 0: character maps to <undefined>":0-1', "b'a\\xff'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode characters in position 1-2: character maps to <undefined>":1-3', "b'tab\\t\\\\n'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\x80\' in position 2: character maps to <undefined>":2-3', "'abc'", "'a\\u02c7b'", "'\\xcc\\u2020\\xc4z'", "'\\u201a\\xc7'", "'\\xc5\\xe7\\xea'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\u02c7\\u02db\\x00\\xff\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u221a\\xa9\\u201a\\xc7\\xa8'"]),
    ('mac-roman', 'surrogatepass', ["b'abc'", "b'h\\x8ello'", "b'a\\xdbb\\xdb'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\U0001f600\' in position 0: character maps to <undefined>":0-1', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\udcff\' in position 1: character maps to <undefined>":1-2', 'UnicodeEncodeError:"\'charmap\' codec can\'t encode characters in position 1-2: character maps to <undefined>":1-3', "b'tab\\t\\\\n'", 'UnicodeEncodeError:"\'charmap\' codec can\'t encode character \'\\\\x80\' in position 2: character maps to <undefined>":2-3', "'abc'", "'a\\u02c7b'", "'\\xcc\\u2020\\xc4z'", "'\\u201a\\xc7'", "'\\xc5\\xe7\\xea'", "'\\\\x4'", "'\\\\u20ac\\\\N{DIGIT ONE}'", "'\\u02c7\\u02db\\x00\\xff\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\u221a\\xa9\\u201a\\xc7\\xa8'"]),
    ('unicode_escape', 'strict', ["b'abc'", "b'h\\\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\\\t\\\\\\\\n'", "b'\\\\x00\\\\x7f\\\\x80\\\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", 'UnicodeDecodeError:"\'unicodeescape\' codec can\'t decode bytes in position 0-2: truncated \\\\xXX escape":0-3', "'\\u20ac1'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('unicode_escape', 'ignore', ["b'abc'", "b'h\\\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\\\t\\\\\\\\n'", "b'\\\\x00\\\\x7f\\\\x80\\\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "''", "'\\u20ac1'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('unicode_escape', 'replace', ["b'abc'", "b'h\\\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\\\t\\\\\\\\n'", "b'\\\\x00\\\\x7f\\\\x80\\\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\ufffd'", "'\\u20ac1'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('unicode_escape', 'backslashreplace', ["b'abc'", "b'h\\\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\\\t\\\\\\\\n'", "b'\\\\x00\\\\x7f\\\\x80\\\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x5c\\\\x78\\\\x34'", "'\\u20ac1'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('unicode_escape', 'xmlcharrefreplace', ["b'abc'", "b'h\\\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\\\t\\\\\\\\n'", "b'\\\\x00\\\\x7f\\\\x80\\\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", 'TypeError:"decoding with \'unicode_escape\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\u20ac1'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('unicode_escape', 'namereplace', ["b'abc'", "b'h\\\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\\\t\\\\\\\\n'", "b'\\\\x00\\\\x7f\\\\x80\\\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", 'TypeError:"decoding with \'unicode_escape\' codec failed (TypeError: don\'t know how to handle UnicodeDecodeError in error callback)"', "'\\u20ac1'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('unicode_escape', 'surrogateescape', ["b'abc'", "b'h\\\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\\\t\\\\\\\\n'", "b'\\\\x00\\\\x7f\\\\x80\\\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", 'UnicodeDecodeError:"\'unicodeescape\' codec can\'t decode bytes in position 0-2: truncated \\\\xXX escape":0-3', "'\\u20ac1'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('unicode_escape', 'surrogatepass', ["b'abc'", "b'h\\\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\\\t\\\\\\\\n'", "b'\\\\x00\\\\x7f\\\\x80\\\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", 'UnicodeDecodeError:"\'unicodeescape\' codec can\'t decode bytes in position 0-2: truncated \\\\xXX escape":0-3', "'\\u20ac1'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('raw_unicode_escape', 'strict', ["b'abc'", "b'h\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('raw_unicode_escape', 'ignore', ["b'abc'", "b'h\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('raw_unicode_escape', 'replace', ["b'abc'", "b'h\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('raw_unicode_escape', 'backslashreplace', ["b'abc'", "b'h\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('raw_unicode_escape', 'xmlcharrefreplace', ["b'abc'", "b'h\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('raw_unicode_escape', 'namereplace', ["b'abc'", "b'h\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('raw_unicode_escape', 'surrogateescape', ["b'abc'", "b'h\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
    ('raw_unicode_escape', 'surrogatepass', ["b'abc'", "b'h\\xe9llo'", "b'a\\\\u20acb\\\\u20ac'", "b'\\\\U0001f600x'", "b'a\\\\udcff'", "b'x\\\\ud800\\\\udc00y'", "b'tab\\t\\\\n'", "b'\\x00\\x7f\\x80\\xff'", "'abc'", "'a\\xffb'", "'\\xed\\xa0\\x80z'", "'\\xe2\\x82'", "'\\x81\\x8d\\x90'", "'\\\\x4'", "'\\u20ac\\\\N{DIGIT ONE}'", "'\\xff\\xfe\\x00\\xd8\\x00'", "'\\x00\\x00\\x11\\x00'", "'\\xc3\\xa9\\xe2\\x82\\xac'"]),
]

PICKLE_DATA = [(4, b'\x80\x04\x955\x00\x00\x00\x00\x00\x00\x00]\x94(K\x01\x8c\x01a\x94h\x01K\x01K\x02\x86\x94}\x94\x8c\x01k\x94C\x01v\x94s\x8f\x94(K\x03\x90(K\x04\x91\x94G?\xf8\x00\x00\x00\x00\x00\x00N\x88\x89e.'), (5, b'\x80\x05\x955\x00\x00\x00\x00\x00\x00\x00]\x94(K\x01\x8c\x01a\x94h\x01K\x01K\x02\x86\x94}\x94\x8c\x01k\x94C\x01v\x94s\x8f\x94(K\x03\x90(K\x04\x91\x94G?\xf8\x00\x00\x00\x00\x00\x00N\x88\x89e.'), (4, b'\x80\x04\x95K\x00\x00\x00\x00\x00\x00\x00]\x94(\x8a\t\x00\x00\x00\x00\x00\x00\x00\x00@J\xff\xff\xff\xffJ\x00\x00\x00\x80\x8a\x05\x00\x00\x00\x80\x00M,\x01Jp\x11\x01\x00J\x7f\xff\xff\xffK\xffM\x00\x01M\xff\xffJ\x00\x00\x01\x00\x8a\t\x00\x00\x00\x00\x00\x00\x00\x00\xc0J\xff\xff\xff\x7fe.'), (5, b'\x80\x05\x95K\x00\x00\x00\x00\x00\x00\x00]\x94(\x8a\t\x00\x00\x00\x00\x00\x00\x00\x00@J\xff\xff\xff\xffJ\x00\x00\x00\x80\x8a\x05\x00\x00\x00\x80\x00M,\x01Jp\x11\x01\x00J\x7f\xff\xff\xffK\xffM\x00\x01M\xff\xffJ\x00\x00\x01\x00\x8a\t\x00\x00\x00\x00\x00\x00\x00\x00\xc0J\xff\xff\xff\x7fe.'), (4, b'\x80\x04\x95\x8e\x02\x00\x00\x00\x00\x00\x00(\x8c\x01t\x94\x8c\x01u\x94\x8c\x01v\x94\x85\x94\x86\x94]\x94}\x94)X,\x01\x00\x00xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\x94B,\x01\x00\x00yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\x94]\x94(]\x94(K\x01K\x02e]\x94K\x03aet\x94.'), (5, b'\x80\x05\x95\x8e\x02\x00\x00\x00\x00\x00\x00(\x8c\x01t\x94\x8c\x01u\x94\x8c\x01v\x94\x85\x94\x86\x94]\x94}\x94)X,\x01\x00\x00xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\x94B,\x01\x00\x00yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\x94]\x94(]\x94(K\x01K\x02e]\x94K\x03aet\x94.'), (4, b'\x80\x04\x952\x00\x00\x00\x00\x00\x00\x00}\x94(\x8c\x01a\x94]\x94(K\x01K\x02e\x8c\x01b\x94}\x94\x8c\x01c\x94K\x03K\x04\x86\x94sK\x05\x8c\x04five\x94K\x01K\x02\x86\x94Nu.'), (5, b'\x80\x05\x952\x00\x00\x00\x00\x00\x00\x00}\x94(\x8c\x01a\x94]\x94(K\x01K\x02e\x8c\x01b\x94}\x94\x8c\x01c\x94K\x03K\x04\x86\x94sK\x05\x8c\x04five\x94K\x01K\x02\x86\x94Nu.'), (4, b'\x80\x04\x95\xce\n\x00\x00\x00\x00\x00\x00]\x94(K\x00K\x01K\x02K\x03K\x04K\x05K\x06K\x07K\x08K\tK\nK\x0bK\x0cK\rK\x0eK\x0fK\x10K\x11K\x12K\x13K\x14K\x15K\x16K\x17K\x18K\x19K\x1aK\x1bK\x1cK\x1dK\x1eK\x1fK K!K"K#K$K%K&K\'K(K)K*K+K,K-K.K/K0K1K2K3K4K5K6K7K8K9K:K;K<K=K>K?K@KAKBKCKDKEKFKGKHKIKJKKKLKMKNKOKPKQKRKSKTKUKVKWKXKYKZK[K\\K]K^K_K`KaKbKcKdKeKfKgKhKiKjKkKlKmKnKoKpKqKrKsKtKuKvKwKxKyKzK{K|K}K~K\x7fK\x80K\x81K\x82K\x83K\x84K\x85K\x86K\x87K\x88K\x89K\x8aK\x8bK\x8cK\x8dK\x8eK\x8fK\x90K\x91K\x92K\x93K\x94K\x95K\x96K\x97K\x98K\x99K\x9aK\x9bK\x9cK\x9dK\x9eK\x9fK\xa0K\xa1K\xa2K\xa3K\xa4K\xa5K\xa6K\xa7K\xa8K\xa9K\xaaK\xabK\xacK\xadK\xaeK\xafK\xb0K\xb1K\xb2K\xb3K\xb4K\xb5K\xb6K\xb7K\xb8K\xb9K\xbaK\xbbK\xbcK\xbdK\xbeK\xbfK\xc0K\xc1K\xc2K\xc3K\xc4K\xc5K\xc6K\xc7K\xc8K\xc9K\xcaK\xcbK\xccK\xcdK\xceK\xcfK\xd0K\xd1K\xd2K\xd3K\xd4K\xd5K\xd6K\xd7K\xd8K\xd9K\xdaK\xdbK\xdcK\xddK\xdeK\xdfK\xe0K\xe1K\xe2K\xe3K\xe4K\xe5K\xe6K\xe7K\xe8K\xe9K\xeaK\xebK\xecK\xedK\xeeK\xefK\xf0K\xf1K\xf2K\xf3K\xf4K\xf5K\xf6K\xf7K\xf8K\xf9K\xfaK\xfbK\xfcK\xfdK\xfeK\xffM\x00\x01M\x01\x01M\x02\x01M\x03\x01M\x04\x01M\x05\x01M\x06\x01M\x07\x01M\x08\x01M\t\x01M\n\x01M\x0b\x01M\x0c\x01M\r\x01M\x0e\x01M\x0f\x01M\x10\x01M\x11\x01M\x12\x01M\x13\x01M\x14\x01M\x15\x01M\x16\x01M\x17\x01M\x18\x01M\x19\x01M\x1a\x01M\x1b\x01M\x1c\x01M\x1d\x01M\x1e\x01M\x1f\x01M \x01M!\x01M"\x01M#\x01M$\x01M%\x01M&\x01M\'\x01M(\x01M)\x01M*\x01M+\x01M,\x01M-\x01M.\x01M/\x01M0\x01M1\x01M2\x01M3\x01M4\x01M5\x01M6\x01M7\x01M8\x01M9\x01M:\x01M;\x01M<\x01M=\x01M>\x01M?\x01M@\x01MA\x01MB\x01MC\x01MD\x01ME\x01MF\x01MG\x01MH\x01MI\x01MJ\x01MK\x01ML\x01MM\x01MN\x01MO\x01MP\x01MQ\x01MR\x01MS\x01MT\x01MU\x01MV\x01MW\x01MX\x01MY\x01MZ\x01M[\x01M\\\x01M]\x01M^\x01M_\x01M`\x01Ma\x01Mb\x01Mc\x01Md\x01Me\x01Mf\x01Mg\x01Mh\x01Mi\x01Mj\x01Mk\x01Ml\x01Mm\x01Mn\x01Mo\x01Mp\x01Mq\x01Mr\x01Ms\x01Mt\x01Mu\x01Mv\x01Mw\x01Mx\x01My\x01Mz\x01M{\x01M|\x01M}\x01M~\x01M\x7f\x01M\x80\x01M\x81\x01M\x82\x01M\x83\x01M\x84\x01M\x85\x01M\x86\x01M\x87\x01M\x88\x01M\x89\x01M\x8a\x01M\x8b\x01M\x8c\x01M\x8d\x01M\x8e\x01M\x8f\x01M\x90\x01M\x91\x01M\x92\x01M\x93\x01M\x94\x01M\x95\x01M\x96\x01M\x97\x01M\x98\x01M\x99\x01M\x9a\x01M\x9b\x01M\x9c\x01M\x9d\x01M\x9e\x01M\x9f\x01M\xa0\x01M\xa1\x01M\xa2\x01M\xa3\x01M\xa4\x01M\xa5\x01M\xa6\x01M\xa7\x01M\xa8\x01M\xa9\x01M\xaa\x01M\xab\x01M\xac\x01M\xad\x01M\xae\x01M\xaf\x01M\xb0\x01M\xb1\x01M\xb2\x01M\xb3\x01M\xb4\x01M\xb5\x01M\xb6\x01M\xb7\x01M\xb8\x01M\xb9\x01M\xba\x01M\xbb\x01M\xbc\x01M\xbd\x01M\xbe\x01M\xbf\x01M\xc0\x01M\xc1\x01M\xc2\x01M\xc3\x01M\xc4\x01M\xc5\x01M\xc6\x01M\xc7\x01M\xc8\x01M\xc9\x01M\xca\x01M\xcb\x01M\xcc\x01M\xcd\x01M\xce\x01M\xcf\x01M\xd0\x01M\xd1\x01M\xd2\x01M\xd3\x01M\xd4\x01M\xd5\x01M\xd6\x01M\xd7\x01M\xd8\x01M\xd9\x01M\xda\x01M\xdb\x01M\xdc\x01M\xdd\x01M\xde\x01M\xdf\x01M\xe0\x01M\xe1\x01M\xe2\x01M\xe3\x01M\xe4\x01M\xe5\x01M\xe6\x01M\xe7\x01M\xe8\x01M\xe9\x01M\xea\x01M\xeb\x01M\xec\x01M\xed\x01M\xee\x01M\xef\x01M\xf0\x01M\xf1\x01M\xf2\x01M\xf3\x01M\xf4\x01M\xf5\x01M\xf6\x01M\xf7\x01M\xf8\x01M\xf9\x01M\xfa\x01M\xfb\x01M\xfc\x01M\xfd\x01M\xfe\x01M\xff\x01M\x00\x02M\x01\x02M\x02\x02M\x03\x02M\x04\x02M\x05\x02M\x06\x02M\x07\x02M\x08\x02M\t\x02M\n\x02M\x0b\x02M\x0c\x02M\r\x02M\x0e\x02M\x0f\x02M\x10\x02M\x11\x02M\x12\x02M\x13\x02M\x14\x02M\x15\x02M\x16\x02M\x17\x02M\x18\x02M\x19\x02M\x1a\x02M\x1b\x02M\x1c\x02M\x1d\x02M\x1e\x02M\x1f\x02M \x02M!\x02M"\x02M#\x02M$\x02M%\x02M&\x02M\'\x02M(\x02M)\x02M*\x02M+\x02M,\x02M-\x02M.\x02M/\x02M0\x02M1\x02M2\x02M3\x02M4\x02M5\x02M6\x02M7\x02M8\x02M9\x02M:\x02M;\x02M<\x02M=\x02M>\x02M?\x02M@\x02MA\x02MB\x02MC\x02MD\x02ME\x02MF\x02MG\x02MH\x02MI\x02MJ\x02MK\x02ML\x02MM\x02MN\x02MO\x02MP\x02MQ\x02MR\x02MS\x02MT\x02MU\x02MV\x02MW\x02MX\x02MY\x02MZ\x02M[\x02M\\\x02M]\x02M^\x02M_\x02M`\x02Ma\x02Mb\x02Mc\x02Md\x02Me\x02Mf\x02Mg\x02Mh\x02Mi\x02Mj\x02Mk\x02Ml\x02Mm\x02Mn\x02Mo\x02Mp\x02Mq\x02Mr\x02Ms\x02Mt\x02Mu\x02Mv\x02Mw\x02Mx\x02My\x02Mz\x02M{\x02M|\x02M}\x02M~\x02M\x7f\x02M\x80\x02M\x81\x02M\x82\x02M\x83\x02M\x84\x02M\x85\x02M\x86\x02M\x87\x02M\x88\x02M\x89\x02M\x8a\x02M\x8b\x02M\x8c\x02M\x8d\x02M\x8e\x02M\x8f\x02M\x90\x02M\x91\x02M\x92\x02M\x93\x02M\x94\x02M\x95\x02M\x96\x02M\x97\x02M\x98\x02M\x99\x02M\x9a\x02M\x9b\x02M\x9c\x02M\x9d\x02M\x9e\x02M\x9f\x02M\xa0\x02M\xa1\x02M\xa2\x02M\xa3\x02M\xa4\x02M\xa5\x02M\xa6\x02M\xa7\x02M\xa8\x02M\xa9\x02M\xaa\x02M\xab\x02M\xac\x02M\xad\x02M\xae\x02M\xaf\x02M\xb0\x02M\xb1\x02M\xb2\x02M\xb3\x02M\xb4\x02M\xb5\x02M\xb6\x02M\xb7\x02M\xb8\x02M\xb9\x02M\xba\x02M\xbb\x02M\xbc\x02M\xbd\x02M\xbe\x02M\xbf\x02M\xc0\x02M\xc1\x02M\xc2\x02M\xc3\x02M\xc4\x02M\xc5\x02M\xc6\x02M\xc7\x02M\xc8\x02M\xc9\x02M\xca\x02M\xcb\x02M\xcc\x02M\xcd\x02M\xce\x02M\xcf\x02M\xd0\x02M\xd1\x02M\xd2\x02M\xd3\x02M\xd4\x02M\xd5\x02M\xd6\x02M\xd7\x02M\xd8\x02M\xd9\x02M\xda\x02M\xdb\x02M\xdc\x02M\xdd\x02M\xde\x02M\xdf\x02M\xe0\x02M\xe1\x02M\xe2\x02M\xe3\x02M\xe4\x02M\xe5\x02M\xe6\x02M\xe7\x02M\xe8\x02M\xe9\x02M\xea\x02M\xeb\x02M\xec\x02M\xed\x02M\xee\x02M\xef\x02M\xf0\x02M\xf1\x02M\xf2\x02M\xf3\x02M\xf4\x02M\xf5\x02M\xf6\x02M\xf7\x02M\xf8\x02M\xf9\x02M\xfa\x02M\xfb\x02M\xfc\x02M\xfd\x02M\xfe\x02M\xff\x02M\x00\x03M\x01\x03M\x02\x03M\x03\x03M\x04\x03M\x05\x03M\x06\x03M\x07\x03M\x08\x03M\t\x03M\n\x03M\x0b\x03M\x0c\x03M\r\x03M\x0e\x03M\x0f\x03M\x10\x03M\x11\x03M\x12\x03M\x13\x03M\x14\x03M\x15\x03M\x16\x03M\x17\x03M\x18\x03M\x19\x03M\x1a\x03M\x1b\x03M\x1c\x03M\x1d\x03M\x1e\x03M\x1f\x03M \x03M!\x03M"\x03M#\x03M$\x03M%\x03M&\x03M\'\x03M(\x03M)\x03M*\x03M+\x03M,\x03M-\x03M.\x03M/\x03M0\x03M1\x03M2\x03M3\x03M4\x03M5\x03M6\x03M7\x03M8\x03M9\x03M:\x03M;\x03M<\x03M=\x03M>\x03M?\x03M@\x03MA\x03MB\x03MC\x03MD\x03ME\x03MF\x03MG\x03MH\x03MI\x03MJ\x03MK\x03ML\x03MM\x03MN\x03MO\x03MP\x03MQ\x03MR\x03MS\x03MT\x03MU\x03MV\x03MW\x03MX\x03MY\x03MZ\x03M[\x03M\\\x03M]\x03M^\x03M_\x03M`\x03Ma\x03Mb\x03Mc\x03Md\x03Me\x03Mf\x03Mg\x03Mh\x03Mi\x03Mj\x03Mk\x03Ml\x03Mm\x03Mn\x03Mo\x03Mp\x03Mq\x03Mr\x03Ms\x03Mt\x03Mu\x03Mv\x03Mw\x03Mx\x03My\x03Mz\x03M{\x03M|\x03M}\x03M~\x03M\x7f\x03M\x80\x03M\x81\x03M\x82\x03M\x83\x03M\x84\x03M\x85\x03M\x86\x03M\x87\x03M\x88\x03M\x89\x03M\x8a\x03M\x8b\x03M\x8c\x03M\x8d\x03M\x8e\x03M\x8f\x03M\x90\x03M\x91\x03M\x92\x03M\x93\x03M\x94\x03M\x95\x03M\x96\x03M\x97\x03M\x98\x03M\x99\x03M\x9a\x03M\x9b\x03M\x9c\x03M\x9d\x03M\x9e\x03M\x9f\x03M\xa0\x03M\xa1\x03M\xa2\x03M\xa3\x03M\xa4\x03M\xa5\x03M\xa6\x03M\xa7\x03M\xa8\x03M\xa9\x03M\xaa\x03M\xab\x03M\xac\x03M\xad\x03M\xae\x03M\xaf\x03M\xb0\x03M\xb1\x03M\xb2\x03M\xb3\x03M\xb4\x03M\xb5\x03M\xb6\x03M\xb7\x03M\xb8\x03M\xb9\x03M\xba\x03M\xbb\x03M\xbc\x03M\xbd\x03M\xbe\x03M\xbf\x03M\xc0\x03M\xc1\x03M\xc2\x03M\xc3\x03M\xc4\x03M\xc5\x03M\xc6\x03M\xc7\x03M\xc8\x03M\xc9\x03M\xca\x03M\xcb\x03M\xcc\x03M\xcd\x03M\xce\x03M\xcf\x03M\xd0\x03M\xd1\x03M\xd2\x03M\xd3\x03M\xd4\x03M\xd5\x03M\xd6\x03M\xd7\x03M\xd8\x03M\xd9\x03M\xda\x03M\xdb\x03M\xdc\x03M\xdd\x03M\xde\x03M\xdf\x03M\xe0\x03M\xe1\x03M\xe2\x03M\xe3\x03M\xe4\x03M\xe5\x03M\xe6\x03M\xe7\x03e(M\xe8\x03M\xe9\x03M\xea\x03M\xeb\x03M\xec\x03e.'), (5, b'\x80\x05\x95\xce\n\x00\x00\x00\x00\x00\x00]\x94(K\x00K\x01K\x02K\x03K\x04K\x05K\x06K\x07K\x08K\tK\nK\x0bK\x0cK\rK\x0eK\x0fK\x10K\x11K\x12K\x13K\x14K\x15K\x16K\x17K\x18K\x19K\x1aK\x1bK\x1cK\x1dK\x1eK\x1fK K!K"K#K$K%K&K\'K(K)K*K+K,K-K.K/K0K1K2K3K4K5K6K7K8K9K:K;K<K=K>K?K@KAKBKCKDKEKFKGKHKIKJKKKLKMKNKOKPKQKRKSKTKUKVKWKXKYKZK[K\\K]K^K_K`KaKbKcKdKeKfKgKhKiKjKkKlKmKnKoKpKqKrKsKtKuKvKwKxKyKzK{K|K}K~K\x7fK\x80K\x81K\x82K\x83K\x84K\x85K\x86K\x87K\x88K\x89K\x8aK\x8bK\x8cK\x8dK\x8eK\x8fK\x90K\x91K\x92K\x93K\x94K\x95K\x96K\x97K\x98K\x99K\x9aK\x9bK\x9cK\x9dK\x9eK\x9fK\xa0K\xa1K\xa2K\xa3K\xa4K\xa5K\xa6K\xa7K\xa8K\xa9K\xaaK\xabK\xacK\xadK\xaeK\xafK\xb0K\xb1K\xb2K\xb3K\xb4K\xb5K\xb6K\xb7K\xb8K\xb9K\xbaK\xbbK\xbcK\xbdK\xbeK\xbfK\xc0K\xc1K\xc2K\xc3K\xc4K\xc5K\xc6K\xc7K\xc8K\xc9K\xcaK\xcbK\xccK\xcdK\xceK\xcfK\xd0K\xd1K\xd2K\xd3K\xd4K\xd5K\xd6K\xd7K\xd8K\xd9K\xdaK\xdbK\xdcK\xddK\xdeK\xdfK\xe0K\xe1K\xe2K\xe3K\xe4K\xe5K\xe6K\xe7K\xe8K\xe9K\xeaK\xebK\xecK\xedK\xeeK\xefK\xf0K\xf1K\xf2K\xf3K\xf4K\xf5K\xf6K\xf7K\xf8K\xf9K\xfaK\xfbK\xfcK\xfdK\xfeK\xffM\x00\x01M\x01\x01M\x02\x01M\x03\x01M\x04\x01M\x05\x01M\x06\x01M\x07\x01M\x08\x01M\t\x01M\n\x01M\x0b\x01M\x0c\x01M\r\x01M\x0e\x01M\x0f\x01M\x10\x01M\x11\x01M\x12\x01M\x13\x01M\x14\x01M\x15\x01M\x16\x01M\x17\x01M\x18\x01M\x19\x01M\x1a\x01M\x1b\x01M\x1c\x01M\x1d\x01M\x1e\x01M\x1f\x01M \x01M!\x01M"\x01M#\x01M$\x01M%\x01M&\x01M\'\x01M(\x01M)\x01M*\x01M+\x01M,\x01M-\x01M.\x01M/\x01M0\x01M1\x01M2\x01M3\x01M4\x01M5\x01M6\x01M7\x01M8\x01M9\x01M:\x01M;\x01M<\x01M=\x01M>\x01M?\x01M@\x01MA\x01MB\x01MC\x01MD\x01ME\x01MF\x01MG\x01MH\x01MI\x01MJ\x01MK\x01ML\x01MM\x01MN\x01MO\x01MP\x01MQ\x01MR\x01MS\x01MT\x01MU\x01MV\x01MW\x01MX\x01MY\x01MZ\x01M[\x01M\\\x01M]\x01M^\x01M_\x01M`\x01Ma\x01Mb\x01Mc\x01Md\x01Me\x01Mf\x01Mg\x01Mh\x01Mi\x01Mj\x01Mk\x01Ml\x01Mm\x01Mn\x01Mo\x01Mp\x01Mq\x01Mr\x01Ms\x01Mt\x01Mu\x01Mv\x01Mw\x01Mx\x01My\x01Mz\x01M{\x01M|\x01M}\x01M~\x01M\x7f\x01M\x80\x01M\x81\x01M\x82\x01M\x83\x01M\x84\x01M\x85\x01M\x86\x01M\x87\x01M\x88\x01M\x89\x01M\x8a\x01M\x8b\x01M\x8c\x01M\x8d\x01M\x8e\x01M\x8f\x01M\x90\x01M\x91\x01M\x92\x01M\x93\x01M\x94\x01M\x95\x01M\x96\x01M\x97\x01M\x98\x01M\x99\x01M\x9a\x01M\x9b\x01M\x9c\x01M\x9d\x01M\x9e\x01M\x9f\x01M\xa0\x01M\xa1\x01M\xa2\x01M\xa3\x01M\xa4\x01M\xa5\x01M\xa6\x01M\xa7\x01M\xa8\x01M\xa9\x01M\xaa\x01M\xab\x01M\xac\x01M\xad\x01M\xae\x01M\xaf\x01M\xb0\x01M\xb1\x01M\xb2\x01M\xb3\x01M\xb4\x01M\xb5\x01M\xb6\x01M\xb7\x01M\xb8\x01M\xb9\x01M\xba\x01M\xbb\x01M\xbc\x01M\xbd\x01M\xbe\x01M\xbf\x01M\xc0\x01M\xc1\x01M\xc2\x01M\xc3\x01M\xc4\x01M\xc5\x01M\xc6\x01M\xc7\x01M\xc8\x01M\xc9\x01M\xca\x01M\xcb\x01M\xcc\x01M\xcd\x01M\xce\x01M\xcf\x01M\xd0\x01M\xd1\x01M\xd2\x01M\xd3\x01M\xd4\x01M\xd5\x01M\xd6\x01M\xd7\x01M\xd8\x01M\xd9\x01M\xda\x01M\xdb\x01M\xdc\x01M\xdd\x01M\xde\x01M\xdf\x01M\xe0\x01M\xe1\x01M\xe2\x01M\xe3\x01M\xe4\x01M\xe5\x01M\xe6\x01M\xe7\x01M\xe8\x01M\xe9\x01M\xea\x01M\xeb\x01M\xec\x01M\xed\x01M\xee\x01M\xef\x01M\xf0\x01M\xf1\x01M\xf2\x01M\xf3\x01M\xf4\x01M\xf5\x01M\xf6\x01M\xf7\x01M\xf8\x01M\xf9\x01M\xfa\x01M\xfb\x01M\xfc\x01M\xfd\x01M\xfe\x01M\xff\x01M\x00\x02M\x01\x02M\x02\x02M\x03\x02M\x04\x02M\x05\x02M\x06\x02M\x07\x02M\x08\x02M\t\x02M\n\x02M\x0b\x02M\x0c\x02M\r\x02M\x0e\x02M\x0f\x02M\x10\x02M\x11\x02M\x12\x02M\x13\x02M\x14\x02M\x15\x02M\x16\x02M\x17\x02M\x18\x02M\x19\x02M\x1a\x02M\x1b\x02M\x1c\x02M\x1d\x02M\x1e\x02M\x1f\x02M \x02M!\x02M"\x02M#\x02M$\x02M%\x02M&\x02M\'\x02M(\x02M)\x02M*\x02M+\x02M,\x02M-\x02M.\x02M/\x02M0\x02M1\x02M2\x02M3\x02M4\x02M5\x02M6\x02M7\x02M8\x02M9\x02M:\x02M;\x02M<\x02M=\x02M>\x02M?\x02M@\x02MA\x02MB\x02MC\x02MD\x02ME\x02MF\x02MG\x02MH\x02MI\x02MJ\x02MK\x02ML\x02MM\x02MN\x02MO\x02MP\x02MQ\x02MR\x02MS\x02MT\x02MU\x02MV\x02MW\x02MX\x02MY\x02MZ\x02M[\x02M\\\x02M]\x02M^\x02M_\x02M`\x02Ma\x02Mb\x02Mc\x02Md\x02Me\x02Mf\x02Mg\x02Mh\x02Mi\x02Mj\x02Mk\x02Ml\x02Mm\x02Mn\x02Mo\x02Mp\x02Mq\x02Mr\x02Ms\x02Mt\x02Mu\x02Mv\x02Mw\x02Mx\x02My\x02Mz\x02M{\x02M|\x02M}\x02M~\x02M\x7f\x02M\x80\x02M\x81\x02M\x82\x02M\x83\x02M\x84\x02M\x85\x02M\x86\x02M\x87\x02M\x88\x02M\x89\x02M\x8a\x02M\x8b\x02M\x8c\x02M\x8d\x02M\x8e\x02M\x8f\x02M\x90\x02M\x91\x02M\x92\x02M\x93\x02M\x94\x02M\x95\x02M\x96\x02M\x97\x02M\x98\x02M\x99\x02M\x9a\x02M\x9b\x02M\x9c\x02M\x9d\x02M\x9e\x02M\x9f\x02M\xa0\x02M\xa1\x02M\xa2\x02M\xa3\x02M\xa4\x02M\xa5\x02M\xa6\x02M\xa7\x02M\xa8\x02M\xa9\x02M\xaa\x02M\xab\x02M\xac\x02M\xad\x02M\xae\x02M\xaf\x02M\xb0\x02M\xb1\x02M\xb2\x02M\xb3\x02M\xb4\x02M\xb5\x02M\xb6\x02M\xb7\x02M\xb8\x02M\xb9\x02M\xba\x02M\xbb\x02M\xbc\x02M\xbd\x02M\xbe\x02M\xbf\x02M\xc0\x02M\xc1\x02M\xc2\x02M\xc3\x02M\xc4\x02M\xc5\x02M\xc6\x02M\xc7\x02M\xc8\x02M\xc9\x02M\xca\x02M\xcb\x02M\xcc\x02M\xcd\x02M\xce\x02M\xcf\x02M\xd0\x02M\xd1\x02M\xd2\x02M\xd3\x02M\xd4\x02M\xd5\x02M\xd6\x02M\xd7\x02M\xd8\x02M\xd9\x02M\xda\x02M\xdb\x02M\xdc\x02M\xdd\x02M\xde\x02M\xdf\x02M\xe0\x02M\xe1\x02M\xe2\x02M\xe3\x02M\xe4\x02M\xe5\x02M\xe6\x02M\xe7\x02M\xe8\x02M\xe9\x02M\xea\x02M\xeb\x02M\xec\x02M\xed\x02M\xee\x02M\xef\x02M\xf0\x02M\xf1\x02M\xf2\x02M\xf3\x02M\xf4\x02M\xf5\x02M\xf6\x02M\xf7\x02M\xf8\x02M\xf9\x02M\xfa\x02M\xfb\x02M\xfc\x02M\xfd\x02M\xfe\x02M\xff\x02M\x00\x03M\x01\x03M\x02\x03M\x03\x03M\x04\x03M\x05\x03M\x06\x03M\x07\x03M\x08\x03M\t\x03M\n\x03M\x0b\x03M\x0c\x03M\r\x03M\x0e\x03M\x0f\x03M\x10\x03M\x11\x03M\x12\x03M\x13\x03M\x14\x03M\x15\x03M\x16\x03M\x17\x03M\x18\x03M\x19\x03M\x1a\x03M\x1b\x03M\x1c\x03M\x1d\x03M\x1e\x03M\x1f\x03M \x03M!\x03M"\x03M#\x03M$\x03M%\x03M&\x03M\'\x03M(\x03M)\x03M*\x03M+\x03M,\x03M-\x03M.\x03M/\x03M0\x03M1\x03M2\x03M3\x03M4\x03M5\x03M6\x03M7\x03M8\x03M9\x03M:\x03M;\x03M<\x03M=\x03M>\x03M?\x03M@\x03MA\x03MB\x03MC\x03MD\x03ME\x03MF\x03MG\x03MH\x03MI\x03MJ\x03MK\x03ML\x03MM\x03MN\x03MO\x03MP\x03MQ\x03MR\x03MS\x03MT\x03MU\x03MV\x03MW\x03MX\x03MY\x03MZ\x03M[\x03M\\\x03M]\x03M^\x03M_\x03M`\x03Ma\x03Mb\x03Mc\x03Md\x03Me\x03Mf\x03Mg\x03Mh\x03Mi\x03Mj\x03Mk\x03Ml\x03Mm\x03Mn\x03Mo\x03Mp\x03Mq\x03Mr\x03Ms\x03Mt\x03Mu\x03Mv\x03Mw\x03Mx\x03My\x03Mz\x03M{\x03M|\x03M}\x03M~\x03M\x7f\x03M\x80\x03M\x81\x03M\x82\x03M\x83\x03M\x84\x03M\x85\x03M\x86\x03M\x87\x03M\x88\x03M\x89\x03M\x8a\x03M\x8b\x03M\x8c\x03M\x8d\x03M\x8e\x03M\x8f\x03M\x90\x03M\x91\x03M\x92\x03M\x93\x03M\x94\x03M\x95\x03M\x96\x03M\x97\x03M\x98\x03M\x99\x03M\x9a\x03M\x9b\x03M\x9c\x03M\x9d\x03M\x9e\x03M\x9f\x03M\xa0\x03M\xa1\x03M\xa2\x03M\xa3\x03M\xa4\x03M\xa5\x03M\xa6\x03M\xa7\x03M\xa8\x03M\xa9\x03M\xaa\x03M\xab\x03M\xac\x03M\xad\x03M\xae\x03M\xaf\x03M\xb0\x03M\xb1\x03M\xb2\x03M\xb3\x03M\xb4\x03M\xb5\x03M\xb6\x03M\xb7\x03M\xb8\x03M\xb9\x03M\xba\x03M\xbb\x03M\xbc\x03M\xbd\x03M\xbe\x03M\xbf\x03M\xc0\x03M\xc1\x03M\xc2\x03M\xc3\x03M\xc4\x03M\xc5\x03M\xc6\x03M\xc7\x03M\xc8\x03M\xc9\x03M\xca\x03M\xcb\x03M\xcc\x03M\xcd\x03M\xce\x03M\xcf\x03M\xd0\x03M\xd1\x03M\xd2\x03M\xd3\x03M\xd4\x03M\xd5\x03M\xd6\x03M\xd7\x03M\xd8\x03M\xd9\x03M\xda\x03M\xdb\x03M\xdc\x03M\xdd\x03M\xde\x03M\xdf\x03M\xe0\x03M\xe1\x03M\xe2\x03M\xe3\x03M\xe4\x03M\xe5\x03M\xe6\x03M\xe7\x03e(M\xe8\x03M\xe9\x03M\xea\x03M\xeb\x03M\xec\x03e.'), (5, b'\x80\x05\x95\r\x00\x00\x00\x00\x00\x00\x00\x96\x02\x00\x00\x00\x00\x00\x00\x00ba\x94.')]


PATHS = ["", ".", "..", "/", "//", "///", "a", "a/", "a/b", "/a/b/", "//a/b", "///a/b", "a/./b", "a/../b", "../a",
         "/../a", "a/b/../../..", "a\\b", "a.txt", ".bashrc", "a/b.tar.gz", "a.b/c", "/a/b/c.d/", "a//b//c",
         "C:\\x\\y", "C:/x", "c:", "C:", "\\\\srv\\share\\x", "//srv/share/x", "/a/b/./c/..", "\\\\?\\UNC\\s\\h\\p",
         "\\\\.\\dev\\x", "C:..\\a", "x\\..\\..\\y"]
JOINS = [("a", "b"), ("a/", "b"), ("a", "/b"), ("", "b"), ("a", ""), ("/", "a"), ("a", "b", "c"), ("a", "b/", "c/"),
         ("C:\\a", "b"), ("C:\\a", "D:b"), ("C:\\a", "c:b"), ("C:", "x"), ("\\\\s\\h", "x"), ("a", "C:\\b", "c")]
PICKLE_VALUES = [[1, "a", "a", (1, 2), {"k": b"v"}, {3}, frozenset([4]), 1.5, None, True, False],
                 [2 ** 70, -1, -2 ** 31, 2 ** 31, 300, 70000, -129, 255, 256, 65535, 65536, -2 ** 70, 2 ** 31 - 1],
                 ("t", ("u", ("v",)), [], {}, (), "x" * 300, b"y" * 300, [[1, 2], [3]]),
                 {"a": [1, 2], "b": {"c": (3, 4)}, 5: "five", (1, 2): None},
                 list(range(1005))]

if __name__ == "__main__":
    TMP = os.path.join(tempfile.gettempdir(), "r80_audit97_" + str(os.getpid()))
    if os.path.exists(TMP):
        shutil.rmtree(TMP)
    os.makedirs(TMP)

    class PathObj:
        def __init__(self, p):
            self.p = p

        def __fspath__(self):
            return self.p

    class NoPath:
        __fspath__ = None

    # ── os.fspath, os.PathLike ───────────────────────────────────────────────
    check("fspath", [os.fspath("a"), os.fspath(b"b"), os.fspath(PathObj("c")), os.fspath(PathObj(b"d"))],
          ["a", b"b", "c", b"d"])
    check("fspath errors", [err(lambda: os.fspath(5)), err(lambda: os.fspath(PathObj(5))), err(lambda: os.fspath(None))],
          ["TypeError: expected str, bytes or os.PathLike object, not int",
           "TypeError: expected PathObj.__fspath__() to return str or bytes, not int",
           "TypeError: expected str, bytes or os.PathLike object, not NoneType"])
    check("PathLike", [isinstance(PathObj("x"), os.PathLike), isinstance("x", os.PathLike), issubclass(PathObj, os.PathLike),
                       issubclass(NoPath, os.PathLike), isinstance(5, os.PathLike)],
          [True, False, True, False, False])
    F1 = os.path.join(TMP, "f1.txt")
    with open(PathObj(F1), "w") as f:
        f.write("hello")
    check("path-like arguments", [os.path.exists(PathObj(F1)), os.stat(PathObj(F1)).st_size, os.path.getsize(PathObj(F1)),
                                  os.listdir(PathObj(TMP)), os.path.basename(PathObj(F1)), open(PathObj(F1)).read()],
          [True, 5, 5, ["f1.txt"], "f1.txt", "hello"])
    check("fsencode / fsdecode", [os.fsencode("a" + chr(0xdcff)), os.fsdecode(b"a\xff") == "a" + chr(0xdcff),
                                  os.fsencode(PathObj("x")), os.fsdecode(PathObj(b"y"))],
          [b"a\xff", True, b"x", "y"])

    # ── os.path: the platform's module, and what was missing ─────────────────
    check("os.path tuples", [os.path.split("a/b"), os.path.splitext("x.tar.gz"), os.path.splitdrive("x"),
                             os.path.dirname("a"), os.path.basename("a/")],
          [("a", "b"), ("x.tar", ".gz"), ("", "x"), "", ""])
    check("os.path members", [hasattr(os.path, n) for n in ["lexists", "samefile", "sameopenfile", "samestat", "ismount",
                                                           "getatime", "getctime", "normcase", "commonprefix",
                                                           "splitdrive", "curdir", "pardir", "devnull", "altsep"]],
          [True] * 14)
    check("samefile / samestat", [os.path.samefile(F1, os.path.join(TMP, ".", "f1.txt")),
                                  os.path.samestat(os.stat(F1), os.lstat(F1)), os.path.samefile(F1, TMP)],
          [True, True, False])
    with open(F1) as fa:
        with open(F1) as fb:
            check("sameopenfile", os.path.sameopenfile(fa.fileno(), fb.fileno()), True)
    check("getatime / getctime", [isinstance(os.path.getatime(F1), float), isinstance(os.path.getctime(F1), float)],
          [True, True])
    check("commonprefix", [os.path.commonprefix(["/a/bc", "/a/bd"]), os.path.commonprefix([]),
                           os.path.commonprefix([["a", "b"], ["a", "c"]])], ["/a/b", "", ["a"]])
    if POSIX:
        check("os.path is posixpath's", [os.path.normpath(p) == posixpath.normpath(p) for p in PATHS if "\\" not in p]
              + [os.path.split(p) == posixpath.split(p) for p in PATHS if "\\" not in p],
              [True] * (2 * len([p for p in PATHS if "\\" not in p])))
        os.symlink(os.path.join(TMP, "nowhere"), os.path.join(TMP, "dangling"))
        check("lexists / ismount", [os.path.lexists(os.path.join(TMP, "dangling")), os.path.exists(os.path.join(TMP, "dangling")),
                                    os.path.islink(os.path.join(TMP, "dangling")), os.path.ismount("/"), os.path.ismount(TMP)],
              [True, False, True, True, False])
        os.remove(os.path.join(TMP, "dangling"))
    check("os constants", [os.curdir, os.pardir, os.extsep, os.altsep, os.devnull, os.sep, os.pathsep],
          [".", "..", ".", "/" if WINDOWS else None, "nul" if not POSIX else "/dev/null", "\\" if not POSIX else "/",
           ";" if not POSIX else ":"])
    check("access modes", [os.F_OK, os.R_OK, os.W_OK, os.X_OK, os.SEEK_SET, os.SEEK_CUR, os.SEEK_END, os.O_RDONLY],
          [0, 4, 2, 1, 0, 1, 2, 0])
    check("os.defpath / get_exec_path", [os.defpath == (".;C:\\bin" if WINDOWS else "/bin:/usr/bin"),
                                         os.get_exec_path({"PATH": os.pathsep.join(["p1", "p2"])})], [True, ["p1", "p2"]])

    # ── posixpath, ntpath: python3's results ──────────────────────────────────
    os.environ["R80_V"] = "val"
    if "R80_NOPE" in os.environ:
        del os.environ["R80_NOPE"]
    MODS = {"posixpath": posixpath, "ntpath": ntpath}
    for row in PATH_DATA:
        mod = MODS[row[0]]
        fn = row[1]
        got = None
        if fn == "join":
            got = [mod.join(*j) for j in JOINS]
        elif fn == "commonprefix":
            got = [mod.commonprefix(x) for x in [["/a/bc", "/a/bd"], ["abc", "abd", "ab"], [], ["x"]]]
        elif fn == "commonpath" and row[0] == "posixpath":
            got = [mod.commonpath(x) for x in [["/a/b", "/a/c"], ["a/b", "a/b/c"], ["/a/b/", "/a/b"], ["/a/./b", "/a/b"], ["a", "b"]]]
        elif fn == "commonpath":
            got = [mod.commonpath(x) for x in [["C:\\a\\b", "c:/a/c"], ["\\\\s\\h\\a", "//s/h/b"], ["a\\b", "a/b/c"], ["C:\\A\\b", "c:\\a\\B\\c"]]]
        elif fn == "relpath" and row[0] == "posixpath":
            got = [mod.relpath(a, b) for a, b in [("/a/b/c", "/a"), ("/a", "/a/b/c"), ("/x/y", "/a/b"), ("/a", "/a"), ("/a/b", "/a/c/../b")]]
        elif fn == "relpath":
            got = [mod.relpath(a, b) for a, b in [("C:\\a\\b\\c", "C:\\a"), ("C:\\a", "c:\\A\\b\\c"), ("C:\\x\\y", "C:\\a\\b")]]
        elif fn == "expandvars" and row[0] == "posixpath":
            got = [mod.expandvars(s) for s in ["$R80_V", "$" + "{R80_V}x", "$R80_NOPE", "a$", "$" + "{R80_V", "$$R80_V"]]
        elif fn == "expandvars":
            got = [mod.expandvars(s) for s in ["%R80_V%", "$R80_V", "$" + "{R80_V}", "'%R80_V%'", "%%", "%R80_NOPE%", "a%b"]]
        else:
            f = getattr(mod, fn)
            got = [f(p) for p in PATHS]
        check(row[0] + "." + fn, got, row[2])
    check("path bytes", [posixpath.join(b"a", b"b"), posixpath.normpath(b"a//b/../c"), posixpath.splitext(b"x.y"),
                         ntpath.normpath(b"a/b"), ntpath.splitdrive(b"C:\\x"), posixpath.basename(b"/a/b")],
          [b"a/b", b"a/c", (b"x", b".y"), b"a\\b", (b"C:", b"\\x"), b"b"])
    check("path errors", [err(lambda: posixpath.join("a", b"b")), err(lambda: ntpath.relpath("C:\\a", "D:\\b")),
                          err(lambda: posixpath.commonpath([])), err(lambda: posixpath.commonpath(["/a", "b"])),
                          err(lambda: ntpath.commonpath(["C:\\a", "D:\\b"])), err(lambda: posixpath.relpath("")),
                          err(lambda: posixpath.join(5))],
          ["TypeError: Can't mix strings and bytes in path components",
           "ValueError: path is on mount 'C:', start on mount 'D:'",
           "ValueError: commonpath() arg is an empty sequence",
           "ValueError: Can't mix absolute and relative paths",
           "ValueError: Paths don't have the same drive",
           "ValueError: no path specified",
           "TypeError: expected str, bytes or os.PathLike object, not int"])
    os.environ["USERPROFILE"] = "C:\\Users\\me"
    os.environ["USERNAME"] = "me"
    check("expanduser", [posixpath.expanduser("x"), ntpath.expanduser("~\\x"), ntpath.expanduser("~other\\x")],
          ["x", "C:\\Users\\me\\x", "C:\\Users\\other\\x"])
    if POSIX and "HOME" in os.environ:
        check("posixpath.expanduser HOME", posixpath.expanduser("~/x"), os.environ["HOME"].rstrip("/") + "/x")
    check("abspath", [posixpath.abspath("/a/./b/../c"), posixpath.isabs(os.path.abspath("x")) if POSIX else True,
                      genericpath._splitext("a.b/c.d", "/", None, ".")], ["/a/c", True, ("a.b/c", ".d")])
    check("ALLOW_MISSING", [repr(posixpath.ALLOW_MISSING), posixpath.ALLOW_MISSING is genericpath.ALLOW_MISSING], ["os.path.ALLOW_MISSING", True])
    check("module constants", [posixpath.sep, posixpath.altsep, posixpath.pathsep, posixpath.devnull, ntpath.sep,
                               ntpath.altsep, ntpath.pathsep, ntpath.devnull, ntpath.curdir],
          ["/", None, ":", "/dev/null", "\\", "/", ";", "nul", "."])

    # ── stat ─────────────────────────────────────────────────────────────────
    st = os.stat(F1)
    check("stat on files", [stat.S_ISREG(st.st_mode), stat.S_ISDIR(st.st_mode), stat.S_ISDIR(os.stat(TMP).st_mode),
                            stat.S_ISLNK(st.st_mode), stat.S_IFMT(st.st_mode) == stat.S_IFREG, st[stat.ST_SIZE],
                            stat.S_IMODE(st.st_mode) == st.st_mode & 0o7777],
          [True, False, True, False, True, 5, True])
    check("filemode", [stat.filemode(m) for m in [0o100644, 0o40755, 0o120777, 0o104755, 0o42777 | 0o1000,
                                                    0o20600, 0o60660, 0o10644, 0o140755, 0o644, 0o102644]],
          ["-rw-r--r--", "drwxr-xr-x", "lrwxrwxrwx", "-rwsr-xr-x", "drwxrwsrwt", "crw-------", "brw-rw----",
           "prw-r--r--", "srwxr-xr-x", "?rw-r--r--", "-rw-r-Sr--"])
    check("stat constants", [stat.S_IFDIR, stat.S_IFREG, stat.S_IFLNK, stat.S_IFIFO, stat.S_IFSOCK, stat.S_IFCHR,
                             stat.S_IFBLK, stat.S_ISUID, stat.S_ISGID, stat.S_ISVTX, stat.S_IRWXU, stat.S_IRUSR,
                             stat.S_IWGRP, stat.S_IXOTH, stat.UF_HIDDEN, stat.SF_SNAPSHOT, stat.FILE_ATTRIBUTE_DIRECTORY,
                             stat.ST_MTIME, stat.S_IFDOOR],
          [16384, 32768, 40960, 4096, 49152, 8192, 24576, 2048, 1024, 512, 448, 256, 16, 1, 32768, 2097152, 16, 8, 0])
    check("stat predicates", [stat.S_ISFIFO(0o10644), stat.S_ISSOCK(0o140755), stat.S_ISCHR(0o20600), stat.S_ISBLK(0o60660),
                              stat.S_ISDOOR(0), stat.S_ISPORT(0), stat.S_ISWHT(0), err(lambda: stat.S_ISDIR("x"))],
          [True, True, True, True, False, False, False, "TypeError: an integer is required"])

    # ── os.scandir, os.DirEntry, os.walk ─────────────────────────────────────
    D = os.path.join(TMP, "tree")
    os.makedirs(os.path.join(D, "sub", "deep"))
    with open(os.path.join(D, "a.txt"), "w") as f:
        f.write("abcde")
    with open(os.path.join(D, "sub", "b.txt"), "w") as f:
        f.write("b")
    with os.scandir(D) as it:
        ents = sorted(it, key=lambda e: e.name)
    e0 = ents[0]
    check("scandir entries", [[e.name for e in ents], [e.is_dir() for e in ents], [e.is_file() for e in ents],
                              [e.is_symlink() for e in ents], [e.path == os.path.join(D, e.name) for e in ents]],
          [["a.txt", "sub"], [False, True], [True, False], [False, False], [True, True]])
    check("DirEntry", [repr(e0), e0.stat().st_size, e0.inode() == os.stat(e0.path).st_ino, os.fspath(e0) == e0.path,
                       isinstance(e0, os.DirEntry), e0.is_dir(follow_symlinks=False), e0.stat(follow_symlinks=False).st_size],
          ["<DirEntry 'a.txt'>", 5, True, True, True, False, 5])
    it2 = os.scandir(D)
    it2.close()
    check("scandir close", [list(it2), sorted([e.name for e in os.scandir(PathObj(D))]),
                            sorted([e.name for e in os.scandir(os.fsencode(D))])],
          [[], ["a.txt", "sub"], [b"a.txt", b"sub"]])
    check("scandir errors", [err(lambda: os.scandir(os.path.join(D, "nope"))).split(":")[0],
                             err(lambda: os.scandir(os.path.join(D, "a.txt"))).split(":")[0]],
          ["FileNotFoundError", "NotADirectoryError"])
    walked = [(r[len(D):], sorted(ds), sorted(fs)) for r, ds, fs in os.walk(D)]
    check("walk", walked, [("", ["sub"], ["a.txt"]), (os.sep + "sub", ["deep"], ["b.txt"]),
                           (os.sep + "sub" + os.sep + "deep", [], [])])
    check("walk bottom-up", [r[len(D):] for r, ds, fs in os.walk(D, topdown=False)],
          [os.sep + "sub" + os.sep + "deep", os.sep + "sub", ""])
    pruned = []
    for r, ds, fs in os.walk(D):
        pruned.append(r[len(D):])
        ds[:] = []
    walk_errors = []
    list(os.walk(os.path.join(D, "nope"), onerror=lambda e: walk_errors.append(type(e).__name__)))
    check("walk pruning / onerror", [pruned, walk_errors], [[""], ["FileNotFoundError"]])
    if POSIX:
        os.symlink(os.path.join(D, "sub"), os.path.join(D, "lnk"))
        le = [e for e in os.scandir(D) if e.name == "lnk"][0]
        check("DirEntry symlink", [le.is_symlink(), le.is_dir(), le.is_dir(follow_symlinks=False), le.is_file(),
                                   [r[len(D):] for r, ds, fs in os.walk(D)].count(os.sep + "lnk"),
                                   [r[len(D):] for r, ds, fs in os.walk(D, followlinks=True)].count(os.sep + "lnk")],
              [True, True, False, False, 0, 1])
        os.remove(os.path.join(D, "lnk"))

    # ── file descriptors ─────────────────────────────────────────────────────
    FB = os.path.join(TMP, "fd.bin")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_BINARY", 0)
    fd = os.open(FB, flags, 0o644)
    n1 = os.write(fd, b"0123456789")
    os.close(fd)
    fd = os.open(PathObj(FB), os.O_RDONLY | getattr(os, "O_BINARY", 0))
    fd_reads = [os.read(fd, 3), os.lseek(fd, 0, os.SEEK_CUR), os.lseek(fd, -2, os.SEEK_END), os.read(fd, 10), os.read(fd, 5),
                os.lseek(fd, 1, os.SEEK_SET), os.read(fd, 2), os.fstat(fd).st_size, os.isatty(fd)]
    os.close(fd)
    check("open / read / write / lseek", [n1] + fd_reads,
          [10, b"012", 3, 8, b"89", b"", 1, b"12", 10, False])
    fd = os.open(FB, os.O_RDWR | getattr(os, "O_BINARY", 0))
    os.ftruncate(fd, 4)
    os.fsync(fd)
    os.close(fd)
    os.truncate(FB, 3)
    check("truncate / ftruncate", [os.path.getsize(FB), open(FB, "rb").read()], [3, b"012"])
    check("fd errors", [err(lambda: os.open(os.path.join(TMP, "nope"), os.O_RDONLY)).split(":")[0],
                        err(lambda: os.open(FB, os.O_WRONLY | os.O_CREAT | os.O_EXCL)).split(":")[0],
                        err(lambda: os.write(1, "text")).split(":")[0]],
          ["FileNotFoundError", "FileExistsError", "TypeError"])
    if POSIX:
        check("closed fd errors", [err(lambda: os.read(fd, 1)).split(":")[0], err(lambda: os.close(fd)).split(":")[0]],
              ["OSError", "OSError"])
    try:
        os.open(os.path.join(TMP, "nope"), os.O_RDONLY)
    except OSError as e:
        check("fd error fields", [e.errno, e.filename == os.path.join(TMP, "nope"), e.strerror], [2, True, "No such file or directory"])
    r, w = os.pipe()
    pipe_info = [os.get_inheritable(r), os.get_inheritable(w), os.write(w, b"ping")]
    os.set_inheritable(w, True)
    pipe_info.append(os.get_inheritable(w))
    w2 = os.dup(w)
    pipe_info.append(w2 != w and not os.get_inheritable(w2))
    os.write(w2, b"!")
    os.close(w2)
    os.close(w)
    pipe_info += [os.read(r, 100), os.read(r, 100)]
    os.close(r)
    check("pipe / dup / inheritable", pipe_info, [False, False, 4, True, True, b"ping!", b""])
    fd = os.open(FB, os.O_RDONLY | getattr(os, "O_BINARY", 0))
    fd2 = os.open(F1, os.O_RDONLY | getattr(os, "O_BINARY", 0))
    os.dup2(fd, fd2)
    dup2_read = os.read(fd2, 10)
    os.close(fd2)
    with os.fdopen(fd, "rb") as f:
        os.lseek(fd, 0, os.SEEK_SET)
        fdopen_read = f.read()
    fd = os.open(FB, os.O_RDONLY | getattr(os, "O_BINARY", 0))
    with open(fd, "rb", closefd=False) as f:
        open_fd = f.read()
    still = os.lseek(fd, 0, os.SEEK_SET)
    os.close(fd)
    check("dup2 / fdopen / open(fd)", [dup2_read, fdopen_read, open_fd, still], [b"012", b"012", b"012", 0])
    if POSIX:
        r, w = os.pipe()
        os.set_blocking(r, False)
        check("blocking", [os.get_blocking(r), os.get_blocking(w), err(lambda: os.read(r, 1)).split(":")[0]],
              [False, True, "BlockingIOError"])
        os.close(r)
        os.close(w)

    # ── ids, ownership, devices, the rest ────────────────────────────────────
    check("misc", [os.cpu_count() >= 1, len(os.urandom(16)), type(os.urandom(4)).__name__, os.strerror(2),
                   # (under Wine a program started from Linux has no Windows parent: 0)
                   os.getpid() > 0, os.getppid() > 0 if POSIX else os.getppid() >= 0, os.path.exists(os.devnull)],
          [True, 16, "bytes", "No such file or directory", True, True, True])
    os.environ["R80_LIVE"] = "1"
    live = [os.getenv("R80_LIVE"), "R80_LIVE" in os.environ, os.environ.get("R80_LIVE")]
    del os.environ["R80_LIVE"]
    live += [os.getenv("R80_LIVE"), "R80_LIVE" in os.environ, err(lambda: os.environ["R80_LIVE"])]
    check("os.environ is live", live, ["1", True, "1", None, False, "KeyError: 'R80_LIVE'"])
    if POSIX:
        old = os.umask(0o027)
        check("umask", [os.umask(old), isinstance(old, int)], [0o027, True])
        check("ids", [os.getuid() == os.geteuid() or os.getuid() == 0, isinstance(os.getgid(), int),
                      isinstance(os.getegid(), int), all(isinstance(g, int) for g in os.getgroups()),
                      os.getpgrp() > 0], [True, True, True, True, True])
        os.chown(F1, os.getuid(), os.getgid())
        os.chown(F1, -1, -1)
        os.lchown(F1, -1, -1)
        check("chown / access", [os.access(F1, os.R_OK), os.access(F1, os.W_OK), os.access(F1, os.F_OK),
                                 os.access(os.path.join(TMP, "nope"), os.F_OK), os.access(TMP, os.X_OK)],
              [True, True, True, False, True])
        FIFO = os.path.join(TMP, "fifo")
        os.mkfifo(FIFO, 0o600)
        check("mkfifo", [stat.S_ISFIFO(os.stat(FIFO).st_mode), stat.S_IMODE(os.stat(FIFO).st_mode) & 0o600,
                         err(lambda: os.mkfifo(FIFO)).split(":")[0]], [True, 0o600, "FileExistsError"])
        check("major / minor / makedev", [os.major(os.makedev(8, 3)), os.minor(os.makedev(8, 3)), os.makedev(1, 2) == os.makedev(1, 2)],
              [8, 3, True])
        la = os.getloadavg()
        check("getloadavg", [len(la), all(isinstance(x, float) and x >= 0 for x in la)], [3, True])
        u = os.uname()
        check("uname", [len(u), u.sysname == u[0], isinstance(u.machine, str)], [5, True, True])
        os.link(F1, os.path.join(TMP, "hard"))
        os.symlink("f1.txt", os.path.join(TMP, "soft"))
        check("link / symlink / readlink", [os.stat(F1).st_nlink, os.readlink(os.path.join(TMP, "soft")),
                                            open(os.path.join(TMP, "soft")).read()], [2, "f1.txt", "hello"])
        os.utime(F1, ns=(1500000000123456789, 1600000000987654321))
        check("utime ns", [os.stat(F1).st_mtime_ns, os.stat(F1).st_atime_ns], [1600000000987654321, 1500000000123456789])
    if LINUX:
        aff = os.sched_getaffinity(0)
        check("sched_getaffinity", [isinstance(aff, set), len(aff) >= 1, all(0 <= c < 4096 for c in aff)], [True, True, True])
    os.makedirs(os.path.join(TMP, "rd", "x", "y"))
    os.removedirs(os.path.join(TMP, "rd", "x", "y"))
    os.makedirs(os.path.join(TMP, "rn"))
    with open(os.path.join(TMP, "rn", "f"), "w") as f:
        f.write("z")
    os.renames(os.path.join(TMP, "rn", "f"), os.path.join(TMP, "rn2", "deep", "f"))
    check("removedirs / renames", [os.path.exists(os.path.join(TMP, "rd")), os.path.exists(os.path.join(TMP, "rn")),
                                   open(os.path.join(TMP, "rn2", "deep", "f")).read()], [False, False, "z"])

    # ── pwd, grp, and tarfile's owner names ──────────────────────────────────
    if POSIX:
        import pwd
        import grp
        me = pwd.getpwuid(os.getuid())
        check("pwd", [me.pw_uid == os.getuid(), pwd.getpwnam(me.pw_name) == me, len(me), me[0] == me.pw_name,
                      me in pwd.getpwall(), tuple(me)[2] == me.pw_uid, isinstance(me.pw_dir, str), type(me).__name__],
              [True, True, 7, True, True, True, True, "struct_passwd"])
        check("pwd errors", [err(lambda: pwd.getpwuid(4294000000)), err(lambda: pwd.getpwnam("no_such_user_r80")),
                             err(lambda: pwd.getpwuid("x")), err(lambda: pwd.getpwnam(5)),
                             err(lambda: pwd.getpwuid(-5)), err(lambda: grp.getgrgid("x")), err(lambda: grp.getgrgid(-5))],
              ["KeyError: 'getpwuid(): uid not found: 4294000000'", "KeyError: \"getpwnam(): name not found: 'no_such_user_r80'\"",
               "TypeError: uid should be integer, not str", "TypeError: getpwnam() argument must be str, not int",
               "KeyError: 'getpwuid(): uid not found'", "TypeError: gid should be integer, not str",
               "OverflowError: gid is less than minimum"])
        check("struct_passwd repr", repr(pwd.struct_passwd(("a", "x", 1, 2, "g", "/h", "/s"))),
              "pwd.struct_passwd(pw_name='a', pw_passwd='x', pw_uid=1, pw_gid=2, pw_gecos='g', pw_dir='/h', pw_shell='/s')")
        g = grp.getgrgid(os.getgid())
        check("grp", [g.gr_gid == os.getgid(), grp.getgrnam(g.gr_name) == g, len(g), isinstance(g.gr_mem, list),
                      g in grp.getgrall(), type(g).__name__],
              [True, True, 4, True, True, "struct_group"])
        check("grp errors", [err(lambda: grp.getgrgid(4294000000)), err(lambda: grp.getgrnam("no_such_group_r80"))],
              ["KeyError: 'getgrgid(): gid not found: 4294000000'", "KeyError: \"getgrnam(): name not found: 'no_such_group_r80'\""])
        TAR = os.path.join(TMP, "t.tar")
        with tarfile.open(TAR, "w") as t:
            t.add(F1, arcname="f1.txt")
            fi = tarfile.TarInfo("pipe")
            fi.type = tarfile.FIFOTYPE
            t.addfile(fi)
        with tarfile.open(TAR) as t:
            m = t.getmember("f1.txt")
            check("tarfile owner names", [m.uname == me.pw_name, m.gname == g.gr_name, m.uid == os.getuid()], [True, True, True])
            OUT = os.path.join(TMP, "tarout")
            t.extractall(OUT)
        check("tarfile extracts a FIFO", [open(os.path.join(OUT, "f1.txt")).read(), stat.S_ISFIFO(os.lstat(os.path.join(OUT, "pipe")).st_mode)],
              ["hello", True])
    else:
        check("pwd / grp are POSIX only", [err(_import_pwd).split(":")[0], err(_import_grp).split(":")[0]],
              ["ModuleNotFoundError", "ModuleNotFoundError"])

    # ── codecs: every codec with every error handler ─────────────────────────
    for row in CODEC_DATA:
        enc = row[0]
        h = row[1]
        got = [show(lambda: s.encode(enc, h)) for s in CODEC_STRS] + [show(lambda: b.decode(enc, h)) for b in CODEC_BYTES]
        check("codec " + enc + " " + h, got, row[2])
    check("codecs.lookup names", [codecs.lookup(n).name for n in ["UTF8", "utf_8", "latin1", "ISO-8859-1", "U16", "utf-16le",
                                                                  "UTF_32BE", "646", "us-ascii", "cp437", "IBM850",
                                                                  "windows-1252", "macintosh", "utf-8-sig", "unicode-escape",
                                                                  "raw_unicode_escape", "hex", "base64", "zip", "quopri",
                                                                  "rot13", "idna", "punycode"]],
          ["utf-8", "utf-8", "iso8859-1", "iso8859-1", "utf-16", "utf-16-le", "utf-32-be", "ascii", "ascii", "cp437",
           "cp850", "cp1252", "mac-roman", "utf-8-sig", "unicode-escape", "raw-unicode-escape", "hex", "base64", "zlib",
           "quopri", "rot-13", "idna", "punycode"])
    ci = codecs.lookup("utf-8")
    check("CodecInfo", [isinstance(ci, tuple), len(ci), ci[0] is ci.encode, ci.encode("h" + chr(0xe9)), ci.decode(b"h\xc3\xa9"),
                        ci._is_text_encoding, codecs.lookup("hex")._is_text_encoding, err(lambda: codecs.lookup("nope"))],
          [True, 4, True, (b"h\xc3\xa9", 2), ("h" + chr(0xe9), 3), True, False, "LookupError: unknown encoding: nope"])
    check("bytes-to-bytes codecs", [codecs.encode(b"hello", "hex"), codecs.decode(b"68656c6c6f", "hex"),
                                    codecs.encode(b"hello", "base64"), codecs.decode(b"aGVsbG8=\n", "base64"),
                                    codecs.decode(codecs.encode(b"hello" * 20, "zlib"), "zlib"),
                                    codecs.encode(b"a=b\tc ", "quopri"), codecs.decode(b"a=3Db", "quopri"),
                                    codecs.encode("Hello", "rot13"), codecs.decode("Uryyb", "rot_13")],
          [b"68656c6c6f", b"hello", b"aGVsbG8=\n", b"hello", b"hello" * 20, b"a=3Db=09c=20", b"a=b", "Uryyb", "Hello"])
    check("not text encodings", [err(lambda: "abc".encode("hex")), err(lambda: b"abc".decode("rot13")),
                                 err(lambda: codecs.encode("abc", "hex"))],
          ["LookupError: 'hex' is not a text encoding; use codecs.encode() to handle arbitrary codecs",
           "LookupError: 'rot13' is not a text encoding; use codecs.decode() to handle arbitrary codecs",
           "TypeError: encoding with 'hex' codec failed (TypeError: a bytes-like object is required, not 'str')"])
    check("BOMs", [codecs.BOM_UTF8, codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE, codecs.BOM_UTF32_LE, codecs.BOM_UTF32_BE,
                   codecs.BOM_LE, codecs.BOM32_BE, codecs.BOM64_LE],
          [b"\xef\xbb\xbf", b"\xff\xfe", b"\xfe\xff", b"\xff\xfe\x00\x00", b"\x00\x00\xfe\xff", b"\xff\xfe", b"\xfe\xff",
           b"\xff\xfe\x00\x00"])
    codecs.register_error("r80dots", lambda e: ("." * (e.end - e.start), e.end))
    codecs.register_error("r80q", lambda e: ("<" + str(e.start) + ">", e.end))
    codecs.register_error("r80bytes", lambda e: (b"#", e.end))
    codecs.register_error("r80far", lambda e: ("", 99))
    naive = "na" + chr(0xef) + chr(0xef) + "ve"
    check("register_error", [naive.encode("ascii", "r80dots"), b"a\xffb\xfe".decode("utf-8", "r80q"),
                             naive.encode("latin-1", "r80bytes") == b"na\xef\xefve", naive.encode("cp437", "r80dots"),
                             naive.encode("utf-16-le", "r80dots"), naive.encode("ascii", "r80bytes"),
                             str(b"a\x81", "cp1252", "r80q"), codecs.decode(b"\xff", "ascii", "r80q"),
                             err(lambda: naive.encode("ascii", "r80far")),
                             codecs.lookup_error("strict") is codecs.strict_errors,
                             err(lambda: codecs.lookup_error("nope"))],
          [b"na..ve", "a<1>b<3>", True, b"na\x8b\x8bve", b"n\x00a\x00\xef\x00\xef\x00v\x00e\x00", b"na#ve", "a<1>", "<0>",
           "IndexError: position 99 from error handler out of bounds", True, "LookupError: unknown error handler name 'nope'"])
    check("unknown handlers are looked up on an error only", [b"abc".decode("utf-8", "nope"), "abc".encode("ascii", "nope"),
                                                             err(lambda: b"\xff".decode("utf-8", "nope")),
                                                             err(lambda: b"\x81".decode("cp1252", "nope"))],
          ["abc", b"abc", "LookupError: unknown error handler name 'nope'",
           "LookupError: decoding with 'cp1252' codec failed (LookupError: unknown error handler name 'nope')"])
    ee = UnicodeEncodeError("ascii", "a" + chr(0xe9) + "b", 1, 2, "ordinal not in range(128)")
    de = UnicodeDecodeError("utf-8", b"a\xffb", 1, 2, "invalid start byte")
    check("handler functions", [codecs.replace_errors(ee), codecs.replace_errors(de), codecs.ignore_errors(ee),
                                codecs.backslashreplace_errors(ee), codecs.backslashreplace_errors(de),
                                codecs.xmlcharrefreplace_errors(ee), codecs.namereplace_errors(ee),
                                codecs.lookup_error("surrogateescape")(de), err(lambda: codecs.strict_errors(ee)).split(":")[0],
                                err(lambda: codecs.xmlcharrefreplace_errors(de))],
          [("?", 2), (chr(0xfffd), 2), ("", 2), ("\\xe9", 2), ("\\xff", 2), ("&#233;", 2),
           ("\\N{LATIN SMALL LETTER E WITH ACUTE}", 2), (chr(0xdcff), 2), "UnicodeEncodeError",
           "TypeError: don't know how to handle UnicodeDecodeError in error callback"])
    try:
        b"ab\xffc".decode("utf-8")
    except UnicodeDecodeError as e:
        check("UnicodeDecodeError fields", [e.encoding, e.object, e.start, e.end, e.reason], ["utf-8", b"ab\xffc", 2, 3, "invalid start byte"])

    def r80_search(name):
        if name == "r80upper":
            return codecs.CodecInfo(lambda s, errors="strict": (s.upper().encode("ascii"), len(s)),
                                    lambda b, errors="strict": (bytes(b).decode("ascii").lower(), len(b)), name="r80upper")
        return None
    codecs.register(r80_search)
    check("register a search function", ["abc".encode("r80upper"), b"ABC".decode("r80upper"), codecs.lookup("R80UPPER").name,
                                          codecs.encode("x", "r80upper")], [b"ABC", "abc", "r80upper", b"X"])
    dec = codecs.getincrementaldecoder("utf-8")()
    euro = chr(0x20ac)
    check("incremental utf-8", [dec.decode(b"a\xe2"), dec.decode(b"\x82"), dec.decode(b"\xacb"), dec.decode(b"", True),
                                err(lambda: codecs.getincrementaldecoder("utf-8")().decode(b"\xe2", True)).split(":")[0]],
          ["a", "", euro + "b", "", "UnicodeDecodeError"])
    d16 = codecs.getincrementaldecoder("utf-16")()
    e16 = codecs.getincrementalencoder("utf-16")()
    check("incremental utf-16", [d16.decode(b"\xfe"), d16.decode(b"\xff\x00"), d16.decode(b"a\x00b"), d16.decode(b"", True),
                                 e16.encode("a"), e16.encode("b"), e16.reset(), e16.encode("c")],
          ["", "", "ab", "", b"\xff\xfea\x00", b"b\x00", None, b"\xff\xfec\x00"])
    dsig = codecs.getincrementaldecoder("utf-8-sig")()
    check("incremental utf-8-sig", [dsig.decode(b"\xef\xbb"), dsig.decode(b"\xbfhi"), list(codecs.iterdecode([b"\xc3", b"\xa9", b"!"], "utf-8")),
                                    b"".join(codecs.iterencode(["a", euro], "utf-16-be"))],
          ["", "hi", [chr(0xe9), "!"], b"\x00a\x20\xac"])
    SP = os.path.join(TMP, "s.txt")
    with codecs.open(SP, "w", "utf-16") as f:
        f.write("line1\n")
        f.write("l" + chr(0xe9) + "ne2\nend")
    raw = open(SP, "rb").read()
    with codecs.open(SP, "r", "utf-16") as f:
        first = f.readline()
        rest = f.read()
    with codecs.open(SP, encoding="utf-16") as f:
        lines = f.readlines()
    check("codecs.open streams", [raw[:4], len(raw), first, rest, lines],
          [b"\xff\xfel\x00", 32, "line1\n", "l" + chr(0xe9) + "ne2\nend", ["line1\n", "l" + chr(0xe9) + "ne2\n", "end"]])
    bio = io.BytesIO()
    w8 = codecs.getwriter("utf-8")(bio)
    w8.write("a" + euro)
    r8 = codecs.getreader("utf-8")(io.BytesIO(b"x\xe2\x82\xacy\nz"))
    ef = codecs.EncodedFile(io.BytesIO(b"caf\xe9"), "utf-8", "latin-1")
    check("readers, writers, EncodedFile", [bio.getvalue(), r8.readline(), r8.read(), ef.read()],
          [b"a\xe2\x82\xac", "x" + euro + "y\n", "z", b"caf\xc3\xa9"])
    check("_codecs functions", [codecs.utf_8_decode(b"a\xe2\x82", "strict", False), codecs.utf_8_decode(b"a\xe2\x82\xac", "strict", True),
                                codecs.utf_16_le_encode("ab"), codecs.latin_1_encode(chr(0xe9)), codecs.ascii_decode(b"ok"),
                                codecs.escape_encode(b"a\n\x01'"), codecs.escape_decode(b"a\\n\\x41\\101"),
                                codecs.charmap_decode(b"\x00\x01", "strict", "xy"), codecs.unicode_escape_decode(b"\\t\\u20ac"),
                                codecs.raw_unicode_escape_encode(chr(0xe9) + euro)],
          [("a", 1), ("a" + euro, 4), (b"a\x00b\x00", 2), (b"\xe9", 1), ("ok", 2), (b"a\\n\\x01\\'", 4), (b"a\nAA", 11),
           ("xy", 2), ("\t" + euro, 8), (b"\xe9\\u20ac", 2)])
    buecher = "b" + chr(0xfc) + "cher"
    check("idna / punycode", [(buecher + ".example").encode("idna"), b"xn--bcher-kva.example".decode("idna"),
                              buecher.encode("punycode"), b"bcher-kva".decode("punycode"), "Example.COM".encode("idna"),
                              "a." .encode("idna"), err(lambda: ("x" * 64 + ".com").encode("idna")).split(":")[0]],
          [b"xn--bcher-kva.example", buecher + ".example", b"bcher-kva", buecher, b"Example.COM", b"a.", "UnicodeError"])
    allbytes = bytes(range(256))
    check("surrogateescape / surrogatepass round trips", [allbytes.decode("utf-8", "surrogateescape").encode("utf-8", "surrogateescape") == allbytes,
                                                          len(allbytes.decode("ascii", "surrogateescape")),
                                                          chr(0xd800).encode("utf-8", "surrogatepass"),
                                                          b"\xed\xa0\x80".decode("utf-8", "surrogatepass") == chr(0xd800),
                                                          chr(0xdc80).encode("utf-16-le", "surrogatepass"),
                                                          err(lambda: (chr(0xdcff) + chr(0xdcfe)).encode("utf-16", "surrogateescape")).split(":")[0]],
          [True, 256, b"\xed\xa0\x80", True, b"\x80\xdc", "UnicodeEncodeError"])

    # ── pickle: the native fast path writes python3's bytes ──────────────────
    pk = [pickle.dumps(PICKLE_VALUES[i // 2], PICKLE_DATA[i][0]) == PICKLE_DATA[i][1] for i in range(len(PICKLE_DATA) - 1)]
    check("pickle bytes", pk + [pickle.dumps(bytearray(b"ba"), 5) == PICKLE_DATA[-1][1]], [True] * len(PICKLE_DATA))
    check("pickle round trips", [pickle.loads(PICKLE_DATA[i][1]) == PICKLE_VALUES[i // 2] for i in range(len(PICKLE_DATA) - 1)],
          [True] * (len(PICKLE_DATA) - 1))
    shared = [1]
    back = pickle.loads(pickle.dumps([shared, shared, (shared,)]))
    check("pickle shared references", [back[0] is back[1], back[2][0] is back[0], pickle.loads(pickle.dumps(WPoint(1, 2))),
                                       type(pickle.loads(pickle.dumps(bytearray(b"x"), 5))).__name__],
          [True, True, WPoint(1, 2), "bytearray"])
    sl = ["A", "foo", "..", "B"]
    i3 = 2
    del sl[i3 - 1:i3 + 1]
    check("del a slice of strings", sl, ["A", "B"])

    # ── multiprocessing (the spawn start method) ─────────────────────────────
    ctx = multiprocessing.get_context("spawn")
    check("start methods", [ctx.get_start_method(), "spawn" in multiprocessing.get_all_start_methods(),
                            multiprocessing.current_process().name, multiprocessing.parent_process(),
                            multiprocessing.cpu_count() == os.cpu_count()],
          ["spawn", True, "MainProcess", None, True])
    q = ctx.Queue()
    ps = [ctx.Process(target=w_put, args=(q, i)) for i in range(3)]
    for p in ps:
        p.start()
    got = sorted([q.get(timeout=60) for p in ps])
    for p in ps:
        p.join(60)
    check("Process + Queue", [[g[:2] for g in got], sorted([g[2] for g in got]) == sorted([p.name for p in ps]),
                              [p.exitcode for p in ps], [p.is_alive() for p in ps], all(p.pid > 0 for p in ps),
                              multiprocessing.active_children()],
          [[(0, 0), (1, 1), (2, 4)], True, [0, 0, 0], [False, False, False], True, []])
    p = ctx.Process(target=w_args, args=(q, 1), kwargs={"wb": 2, "wc": 3}, name="worker-x", daemon=True)
    check("Process before start", [p.name, p.daemon, p.exitcode, p.is_alive(), repr(p).startswith("<SpawnProcess name='worker-x' parent=")],
          ["worker-x", True, None, False, True])
    p.start()
    check("Process args / kwargs / parent", q.get(timeout=60), (1, 2, 3, os.getpid()))
    p.join(60)
    check("Process repr after", [repr(p).endswith("stopped exitcode=0 daemon>"), p.exitcode], [True, 0])
    p1 = ctx.Process(target=w_fail)
    p2 = ctx.Process(target=w_exit, args=(7,))
    p3 = ctx.Process(target=w_exit_text)
    for p in (p1, p2, p3):
        p.start()
    for p in (p1, p2, p3):
        p.join(60)
    check("exit codes", [p1.exitcode, p2.exitcode, p3.exitcode], [1, 7, 1])
    p = ctx.Process(target=w_sleep, args=(60,))
    p.start()
    p.join(0.2)
    alive = [p.is_alive(), p.exitcode]
    p.terminate()
    p.join(30)
    pk2 = ctx.Process(target=w_sleep, args=(60,))
    pk2.start()
    pk2.kill()
    pk2.join(30)
    check("join(timeout) / terminate / kill", alive + [p.exitcode, p.is_alive(), pk2.exitcode],
          [True, None, -15, False, -15 if WINDOWS else -9])
    p.close()
    check("close", err(lambda: p.pid), "ValueError: process object is closed")

    a, b = ctx.Pipe()
    p = ctx.Process(target=w_pipe, args=(b,))
    p.start()
    b.close()
    pipe_got = [a.recv()]
    a.send(21)
    pipe_got += [a.recv(), a.recv_bytes(), a.poll(30)]
    eof = err(lambda: a.recv())
    p.join(60)
    rd, wr = ctx.Pipe(duplex=False)
    wr.send_bytes(b"0123456789", 2, 3)
    check("Pipe", pipe_got + [eof, rd.poll(0), rd.recv_bytes(), rd.poll(0.05), err(lambda: rd.send(1)), err(lambda: wr.recv())],
          [{"hello": [1, 2, 3]}, 42, b"raw bytes", True, "EOFError: ", True, b"234", False,
           "OSError: connection is read-only", "OSError: connection is write-only"])

    v = ctx.Value("i", 0)
    arr = ctx.Array("d", [1.0, 2.0, 3.0])
    lock = ctx.Lock()
    ps = [ctx.Process(target=w_count, args=(v, arr, lock, 10)) for i in range(2)]
    for p in ps:
        p.start()
    for p in ps:
        p.join(120)
    carr = ctx.Array("c", b"hello")
    carr.value = b"hi"
    rv = ctx.RawValue("d", 1.5)
    check("Value / Array across processes", [v.value, arr[:], len(arr), arr[-1], carr.value, carr.raw[:3], rv.value,
                                             ctx.Value("i", 5, lock=False).value, ctx.Array("i", 3)[:], err(lambda: arr[5])],
          [20, [3.0, 4.0, 5.0], 3, 5.0, b"hi", b"hi\x00", 1.5, 5, [0, 0, 0], "IndexError: invalid index"])
    rl = ctx.RLock()
    rl.acquire()
    rl.acquire()
    rl.release()
    rl.release()
    lk = ctx.Lock()
    sem = ctx.Semaphore(2)
    bsem = ctx.BoundedSemaphore(1)
    check("locks and semaphores", [lk.acquire(), lk.acquire(False), lk.acquire(True, 0.05), lk.release(), err(lambda: lk.release()),
                                   err(lambda: rl.release()).split(":")[0], sem.acquire(), sem.get_value() if not sys.platform == "darwin" else 1,
                                   sem.acquire(False) and sem.acquire(False), err(lambda: bsem.release())],
          [True, False, False, None, "ValueError: semaphore or lock released too many times", "AssertionError", True, 1,
           False, "ValueError: semaphore or lock released too many times"])
    ev = ctx.Event()
    p = ctx.Process(target=w_event, args=(ev, q))
    p.start()
    ev_before = ev.is_set()
    ev.set()
    check("Event", [ev_before, q.get(timeout=60), ev.is_set(), ev.wait(0.01)], [False, True, True, True])
    p.join(60)
    cv = ctx.Value("i", 0)
    cond = ctx.Condition()
    p = ctx.Process(target=w_cond, args=(cond, cv, q))
    p.start()
    time.sleep(0.3)
    with cond:
        cv.value = 7
        cond.notify_all()
    check("Condition", [q.get(timeout=60)], [7])
    p.join(60)
    bar = ctx.Barrier(2)
    p = ctx.Process(target=w_barrier, args=(bar, q))
    p.start()
    mine = bar.wait(60)
    check("Barrier", [sorted([mine, q.get(timeout=60)]), bar.parties, bar.broken], [[0, 1], 2, False])
    p.join(60)
    q2 = ctx.Queue(maxsize=1)
    q2.put("x")
    check("Queue limits", [q2.full(), q2.qsize(), err(lambda: q2.put_nowait("y")).split(":")[0], q2.get(),
                           err(lambda: q2.get_nowait()).split(":")[0], err(lambda: q2.get(timeout=0.05)).split(":")[0],
                           q2.empty()],
          [True, 1, "Full", "x", "Empty", "Empty", True])
    jq = ctx.JoinableQueue()
    jout = ctx.Queue()
    p = ctx.Process(target=w_joinable, args=(jq, jout))
    p.start()
    for i in range(3):
        jq.put(i)
    jq.put(None)
    jq.join()
    check("JoinableQueue", [sorted([jout.get(timeout=60) for i in range(3)]), err(lambda: jq.task_done())],
          [[0, 10, 20], "ValueError: task_done() called too many times"])
    p.join(60)
    sq = ctx.SimpleQueue()
    sq.put([1, {"two": 2}])
    check("SimpleQueue", [sq.empty(), sq.get(), sq.empty()], [False, [1, {"two": 2}], True])

    with ctx.Pool(2) as pool:
        pool_got = [pool.map(w_square, range(10)), pool.map(w_square, range(7), chunksize=3), list(pool.imap(w_slow, range(6))),
                    sorted(pool.imap_unordered(w_slow, range(6))), pool.starmap(pow, [(2, 3), (3, 2)]),
                    pool.apply(w_square, (9,)), pool.apply_async(w_square, (8,)).get(60),
                    pool.map_async(w_square, [1, 2]).get(60), list(pool.imap(w_square, range(5), chunksize=2))]
        callbacks = []
        r1 = pool.apply_async(w_square, (5,), callback=callbacks.append)
        r1.wait(60)
        r2 = pool.apply_async(w_raise, (1,), error_callback=lambda e: callbacks.append(type(e).__name__))
        r2.wait(60)
        pool_got += [r1.ready(), r1.successful(), r2.successful(), err(lambda: r2.get(60)), err(lambda: pool.map(w_raise, [3])),
                     err(lambda: pool.apply(w_raise, (4,)))]
    check("Pool", pool_got + [callbacks],
          [[0, 1, 4, 9, 16, 25, 36, 49, 64, 81], [0, 1, 4, 9, 16, 25, 36], [0, -1, -2, -3, -4, -5], [-5, -4, -3, -2, -1, 0],
           [8, 9], 81, 64, [1, 4], [0, 1, 4, 9, 16], True, True, False, "ValueError: bad 1", "ValueError: bad 3",
           "ValueError: bad 4", [25, "ValueError"]])
    pool = ctx.Pool(1, initializer=w_init, initargs=("ready",), maxtasksperchild=1)
    pids = pool.map(w_pid, range(3), chunksize=1)
    check("Pool initializer / maxtasksperchild", [pool.apply(w_initval, (1,)), len(set(pids))], [("ready", 1), 3])
    pool.close()
    pool.join()
    check("Pool closed", err(lambda: pool.map(w_square, [1])), "ValueError: Pool not running")

    with ctx.Manager() as mgr:
        md = mgr.dict()
        ml = mgr.list([1])
        mns = mgr.Namespace(x=1)
        p = ctx.Process(target=w_manager, args=(md, ml, mns))
        p.start()
        p.join(60)
        mq = mgr.Queue()
        mq.put("via manager")
        check("Manager", [dict(md.items()), list(ml), mns.x, len(ml), ml[1], md.get("nope", 0), mq.get(timeout=30)],
              [{"child": 2}, [1, 42], 2, 2, 42, 0, "via manager"])

    shm = shared_memory.SharedMemory(create=True, size=16)
    shm.buf[0:5] = b"hello"
    p = ctx.Process(target=w_shm, args=(shm.name,))
    p.start()
    p.join(60)
    check("shared_memory", [bytes(shm.buf[0:5]), shm.size >= 16, shm.name.startswith("psm_") or WINDOWS, len(shm.buf) >= 16,
                            err(lambda: shared_memory.SharedMemory("r80_no_such_block")).split(":")[0],
                            err(lambda: shared_memory.SharedMemory(create=True, size=0))],
          [b"HELLO", True, True, True, "FileNotFoundError", "ValueError: 'size' must be a positive number different from zero"])
    shm.close()
    shm.unlink()

    with ProcessPoolExecutor(max_workers=2, mp_context=ctx) as ex:
        fut = ex.submit(w_point, 3)
        ppe = [fut.result(60), list(ex.map(w_square, range(5))), list(ex.map(w_square, range(5), chunksize=2)),
               err(lambda: ex.submit(w_raise, 2).result(60))]
        try:
            ex.submit(lambda x: x, 1).result(60)
            ppe.append("no error")
        except Exception as e:
            ppe.append(isinstance(e, pickle.PicklingError) or "pickle" in type(e).__name__.lower() or "Pickl" in str(e))
    check("ProcessPoolExecutor over pickle", ppe, [WPoint(3, -3), [0, 1, 4, 9, 16], [0, 1, 4, 9, 16], "ValueError: bad 2", True])

    shutil.rmtree(TMP, ignore_errors=True)
    pass_n = 0
    fail_n = 0
    for r in results:
        if r[1]:
            pass_n = pass_n + 1
        else:
            fail_n = fail_n + 1
            print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
    print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
    if fail_n == 0:
        print("=== VM_AUDIT97 PASSED ===")
