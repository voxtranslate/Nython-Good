# ═══════════════════════════════════════════════════════════════════════════════
import nytorch
import os

# os.ny — Operating System Interface Library
# Filesystem, processes, environment, paths, temp files, permissions, ...
# Usage: import "lib/os.ny"
#
# A thin object layer over the os_* builtins (src/builtins/os*.cpp), which
# behave the same on the interpreter and the VM. Every builtin is also usable
# directly; see HANDOFF.md "Round 74" for the full list.
#
# Note on names: inside a method, a bare call to a function with the SAME
# name as the method resolves to the method itself (Process.shell calling
# shell() recursed until RecursionError). Methods here therefore call the
# os_-prefixed builtin, never the bare one of the same name.
# ═══════════════════════════════════════════════════════════════════════════════

class Path:
    def join(self, a, b, c=none, d=none):
        var p = os_path_join(a, b)
        if c != none:
            p = os_path_join(p, c)
        if d != none:
            p = os_path_join(p, d)
        return p
    def basename(self, p):
        return os_path_basename(p)
    def dirname(self, p):
        return os_path_dirname(p)
    def extension(self, p):
        return os_path_ext(p)
    def split(self, p):
        return os_path_split(p)
    def splitext(self, p):
        return os_path_splitext(p)
    def abspath(self, p):
        return os_path_abspath(p)
    def realpath(self, p):
        return os_path_realpath(p)
    def relpath(self, p, start="."):
        return os_path_relpath(p, start)
    def isabs(self, p):
        return os_path_isabs(p)
    def exists(self, p):
        return os_exists(p)
    def is_file(self, p):
        return os_isfile(p)
    def is_dir(self, p):
        return os_isdir(p)
    def is_link(self, p):
        return os_islink(p)
    def expanduser(self, p):
        return os_path_expanduser(p)
    def expandvars(self, p):
        return os_path_expandvars(p)
    def without_ext(self, p):
        return os_path_splitext(p)[0]
    def normalize(self, p):
        # Collapses separators AND resolves "." and ".." (it only collapsed
        # "//" before), with "/" separators on every platform.
        return os_path_normpath(string_replace(p, "\\", "/"))

class FileSystem:
    def __init__(self):
        self.path = Path()
    def read(self, filepath):
        return read_file(filepath)
    def write(self, filepath, content):
        return write_file(filepath, content)
    def append(self, filepath, content):
        return append_text(filepath, content)
    def delete(self, filepath):
        return os_remove(filepath)
    def rename(self, src, dst):
        return os_rename(src, dst)
    def copy(self, src, dst):
        # Byte-exact copy; false (and no destination file) when src is
        # missing. It used to read the source as text and write an empty
        # destination for a missing source, returning true.
        return file_copy(src, dst)
    def move(self, src, dst):
        try:
            os_move(src, dst)
            return true
        except:
            return false
    def mkdir(self, dirpath):
        return os_mkdir(dirpath)
    def rmtree(self, dirpath):
        if not os_exists(dirpath):
            return false
        return os_rmtree(dirpath)
    def copytree(self, src, dst):
        return os_copytree(src, dst)
    def listdir(self, dirpath):
        return os_listdir(dirpath)
    def listdir_full(self, dirpath):
        var entries = os_listdir(dirpath)
        var result = []
        var i = 0
        while i < len(entries):
            result.append(os_path_join(dirpath, entries[i]))
            i = i + 1
        return result
    def exists(self, p):
        return os_exists(p)
    def is_file(self, p):
        return os_isfile(p)
    def is_dir(self, p):
        return os_isdir(p)
    def stat(self, p):
        return fs_stat(p)
    def size(self, p):
        # -1 for a missing file (fs_stat never returns none, so this used to
        # report 0)
        var info = fs_stat(p)
        if not info["exists"]:
            return -1
        return info["size"]
    def mtime(self, p):
        var info = fs_stat(p)
        if not info["exists"]:
            return -1
        return info["mtime"]
    def walk(self, dirpath):
        # Every file and directory below dirpath, as full paths.
        return fs_walk(dirpath)
    def walk_tree(self, dirpath):
        # [[dirpath, [dirnames], [filenames]], ...] like Python's os.walk
        return os_walk(dirpath)
    def glob(self, pattern):
        return os_glob(pattern)
    def read_lines(self, filepath):
        # [] for a missing file; no phantom "" after a final newline
        if not os_isfile(filepath):
            return []
        var content = read_file(filepath)
        if content == "":
            return []
        var lines = string_split(content, "\n")
        if len(lines) > 0 and lines[len(lines) - 1] == "":
            lines.pop()
        return lines
    def write_lines(self, filepath, lines):
        var content = ""
        var i = 0
        while i < len(lines):
            content = content + str(lines[i]) + "\n"
            i = i + 1
        return write_file(filepath, content)
    def find_files(self, dirpath, extension):
        var all_files = fs_walk(dirpath)
        var result = []
        var i = 0
        while i < len(all_files):
            if string_endswith(all_files[i], extension) and os_isfile(all_files[i]):
                result.append(all_files[i])
            i = i + 1
        return result
    def ensure_dir(self, dirpath):
        if os_isdir(dirpath):
            return true
        return os_mkdir(dirpath)
    def temp_file(self, prefix):
        # A new, empty, uniquely named file (created exclusively). Names used
        # to be built from int(time_ms()), which overflowed on the
        # interpreter, so every call returned the same path.
        return os_mkstemp(prefix + "_", ".tmp")
    def temp_dir(self):
        return os_gettempdir()

class Env:
    def get(self, key):
        return os_getenv(key, "")
    def get_or(self, key, default_val):
        return os_getenv(key, default_val)
    def set(self, key, val):
        os_setenv(key, str(val))
    def unset(self, key):
        return os_unsetenv(key)
    def all(self):
        return os_environ()
    def home(self):
        return os_home()
    def user(self):
        return os_username()
    def cwd(self):
        return os_getcwd()
    def path_list(self):
        return string_split(self.get("PATH"), os_pathsep)
    def is_windows(self):
        return os_platform() == "windows"
    def is_linux(self):
        return os_platform() == "linux"
    def is_mac(self):
        return os_platform() == "darwin"
    def platform(self):
        # "windows", "linux", "darwin", ... (it used to be "windows" or "unix")
        return os_platform()
    def cpu_count(self):
        return os_cpu_count()
    def hostname(self):
        return os_hostname()

class Process:
    def run(self, cmd):
        # Standard output of a shell command (legacy form). For the exit
        # code and stderr use result().
        return os_exec(cmd)
    def result(self, cmd, cwd="", timeout=-1):
        # {code, stdout, stderr, ok}. cmd may be a list ([prog, arg, ...]),
        # which runs without a shell - nothing in the arguments is interpreted.
        return os_run(cmd, cwd, none, none, timeout)
    def run_get_lines(self, cmd):
        var output = os_exec(cmd)
        if output == "":
            return []
        return string_split(output, "\n")
    def run_check(self, cmd):
        # true when the command exits with status 0 (it was always true)
        return os_run(cmd)["code"] == 0
    def shell(self, cmd):
        return os_exec(cmd)
    def which(self, program):
        # full path of the program, or "" when it is not on PATH
        var p = os_which(program)
        if p == none:
            return ""
        return p
    def pid(self):
        # this process's id (it returned the pid of a short-lived shell)
        return os_getpid()
    def spawn(self, cmd, cwd=""):
        return os_spawn(cmd, cwd)
    def poll(self, pid):
        return os_poll(pid)
    def wait(self, pid, timeout=-1):
        return os_wait(pid, timeout)
    def kill(self, pid):
        return os_kill(pid)
    def quote(self, s):
        return shell_quote(s)

class WatchDog:
    def __init__(self, filepath):
        self.filepath = filepath
        self.last_size = -1
        self.last_mtime = -1
        self.last_content = ""
    def has_changed(self):
        # size OR modification time (a same-size rewrite went unnoticed)
        var info = fs_stat(self.filepath)
        if not info["exists"]:
            return false
        var changed = info["size"] != self.last_size or info["mtime"] != self.last_mtime
        self.last_size = info["size"]
        self.last_mtime = info["mtime"]
        return changed
    def read_new(self):
        var content = read_file(self.filepath)
        if content == self.last_content:
            return ""
        var new_part = content
        if string_startswith(content, self.last_content):
            new_part = content[len(self.last_content):]
        self.last_content = content
        return new_part

class TempFile:
    def __init__(self, prefix):
        # created at once, uniquely, in the platform's temp directory (it was
        # always /tmp, with a name that collided)
        self.path = os_mkstemp(prefix + "_", ".tmp")
        self.content = ""
    def write(self, data):
        self.content = data
        write_file(self.path, data)
    def read(self):
        return read_file(self.path)
    def delete(self):
        os_remove(self.path)
    def __enter__(self):
        return self
    def __exit__(self, exc_type=none, exc_value=none, tb=none):
        self.delete()
        return false
