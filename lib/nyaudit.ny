# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/nyaudit.ny - audit policies (Nython's own; round 86): declarative
# allow / deny rules over the audit events of PEP 578 (sys.audit,
# sys.addaudithook) - the events CPython raises, which Nython's engines and
# library raise with CPython's names and arguments (tools/audit_events.json).
#
#     import nyaudit
#     p = nyaudit.Policy(default="deny")          # nothing is allowed ...
#     p.allow("import").allow("compile").allow("exec")
#     p.allow("open", path="/srv/data/*", mode="r")  # ... but what is granted
#     p.allow("socket.*", address="127.0.0.1:*")
#     p.install()                                 # sys.addaudithook(p), frozen
#
# The idea is the one the PEP 578 discussions call "sandboxing with audit
# hooks", given the shape of a capability system (Miller, "Robust
# Composition", 2006): authority is denied by default and granted
# explicitly, each grant scoped by argument patterns (these paths, this
# host) - attenuated authority rather than a blocklist of bad calls - and
# once installed a policy is frozen, so the program it governs cannot grant
# itself more (granted() lends a capability for a with block before that).
# It is a policy over the events the runtime raises, not an isolation
# boundary: native code, or an operation no event covers, is not seen.
#
# Policy(default="allow", log=None, freeze=True)
#     .allow(event, *args, **named) / .deny(event, *args, message=None, **named)
#     .log(event, *args, **named)       record the event (in the log, else on
#                                       stderr) and go on matching
#     .decide(event, args) -> (action, rule)   what the policy would do
#     .install()                        sys.addaudithook(policy); frozen after
#     .granted(event, *args, **named)   a with block allowing it (before install)
#     .text()                           the policy in the file format below
#     .events                           (event, args, decision) seen, with keep=N
# Rules are tried in order and the first that matches decides (log rules
# only record); none matching: the default. An event pattern is an fnmatch
# glob ("os.*"); an argument pattern matches the argument at its position
# (positional patterns) or of its documented name (named ones: open's path,
# mode, flags - tools/audit_events.json's names, in _EVENT_ARGS below) and
# is a glob string (matched against the argument as text: a str or path as
# itself, made absolute when the pattern starts with "/" or "~"; bytes
# decoded; a (host, port) pair as "host:port"; numbers, None, True as
# their str), a callable predicate, a type (isinstance), a tuple of
# patterns (element by element) or ANY. A denied event raises AuditDenied
# (a PermissionError) from the audited call, which is then not made.
# A log (log="file.jsonl", or --audit-log) gets one JSON object per event:
# {"event", "args" (made JSON-safe: other objects as "<type>"), "decision"}.
#
# load(path) / parse(text) read a policy file:
#     # a comment
#     default deny                 (allow is the default)
#     log events.jsonl             (a log of every event)
#     allow import
#     allow open path=/srv/data/* mode=r
#     deny  os.system              message="no shell commands"
#     allow socket.connect address=127.0.0.1:*
#     log   subprocess.*
# or a JSON object {"default": ..., "log": ..., "rules": [[action, event,
# {name: pattern}], ...]}.
# derive(log_path) writes a policy allowing what a logged run did: every
# event seen, open's directories and modes as patterns (a starting point
# to tighten by hand).
#
#     nython --audit-policy policy.txt prog.ny     (installed before prog runs:
#                                                  cpython.run_file is its first event)
#     nython --audit-log events.jsonl prog.ny      (allow everything, log it)
#     nython -m nyaudit derive events.jsonl        (print a policy for that run)
#     nython -m nyaudit check policy.txt           (parse it, print it back)
#
# Not here: removing a policy (PEP 578: hooks cannot be removed), events
# raised by native code that has none (tools/audit_events.json's "nython"
# column says which CPython events Nython raises).

import sys
import json
import fnmatch as _fnmatch
import _thread

__all__ = ["Policy", "Rule", "AuditDenied", "ANY", "load", "parse", "derive", "install", "event_args"]

# the documented argument names of the events (CPython's docs), by which a
# rule names an argument; generated from tools/audit_events.json
_EVENT_ARGS = {
    "builtins.id": ("id",), "builtins.input": ("prompt",), "builtins.input/result": ("result",),
    "builtins.breakpoint": ("breakpointhook",), "compile": ("source", "filename"), "exec": ("code_object",),
    "import": ("module", "filename", "sys.path", "sys.meta_path", "sys.path_hooks"),
    "open": ("path", "mode", "flags"), "code.__new__": ("code", "filename", "name", "argcount",
    "posonlyargcount", "kwonlyargcount", "nlocals", "stacksize", "flags"), "function.__new__": ("code",),
    "object.__getattr__": ("obj", "name"), "object.__setattr__": ("obj", "name", "value"),
    "object.__delattr__": ("obj", "name"), "sys._getframe": ("frame",), "sys._getframemodulename": ("depth",),
    "sys.excepthook": ("hook", "type", "value", "traceback"), "sys.unraisablehook": ("hook", "unraisable"),
    "cpython.run_command": ("command",), "cpython.run_file": ("filename",), "cpython.run_module": ("module-name",),
    "time.sleep": ("seconds",), "_thread.start_new_thread": ("function", "args", "kwargs"),
    "array.__new__": ("typecode", "initializer"), "marshal.dumps": ("value", "version"), "marshal.loads": ("bytes",),
    "mmap.__new__": ("fileno", "length", "access", "offset"), "gc.get_objects": ("generation",),
    "gc.get_referrers": ("objs",), "gc.get_referents": ("objs",), "signal.pthread_kill": ("thread_id", "signalnum"),
    "resource.setrlimit": ("resource", "limits"), "resource.prlimit": ("pid", "resource", "limits"),
    "fcntl.fcntl": ("fd", "cmd", "arg"), "fcntl.ioctl": ("fd", "request", "arg"), "fcntl.flock": ("fd", "operation"),
    "fcntl.lockf": ("fd", "cmd", "len", "start", "whence"), "syslog.openlog": ("ident", "logoption", "facility"),
    "syslog.syslog": ("priority", "message"), "syslog.setlogmask": ("maskpri",), "sqlite3.connect": ("database",),
    "sqlite3.connect/handle": ("connection_handle",), "sqlite3.enable_load_extension": ("connection", "enabled"),
    "sqlite3.load_extension": ("connection", "path"), "pickle.find_class": ("module", "name"), "pty.spawn": ("argv",),
    "glob.glob": ("pathname", "recursive"), "glob.glob/2": ("pathname", "recursive", "root_dir", "dir_fd"),
    "pathlib.Path.glob": ("self", "pattern"), "pathlib.Path.rglob": ("self", "pattern"),
    "pathlib.Path.walk": ("self", "on_error", "follow_symlinks"),
    "shutil.copyfile": ("src", "dst"), "shutil.copymode": ("src", "dst"), "shutil.copystat": ("src", "dst"),
    "shutil.copytree": ("src", "dst"), "shutil.rmtree": ("path", "dir_fd"), "shutil.move": ("src", "dst"),
    "shutil.chown": ("path", "user", "group"), "shutil.make_archive": ("base_name", "format", "root_dir", "base_dir"),
    "shutil.unpack_archive": ("filename", "extract_dir", "format"), "tempfile.mkstemp": ("fullpath",),
    "tempfile.mkdtemp": ("fullpath",), "subprocess.Popen": ("executable", "args", "cwd", "env"),
    "urllib.Request": ("fullurl", "data", "headers", "method"), "http.client.connect": ("self", "host", "port"),
    "http.client.send": ("self", "data"), "webbrowser.open": ("url",), "ftplib.connect": ("self", "host", "port"),
    "ftplib.sendcmd": ("self", "cmd"), "smtplib.connect": ("self", "host", "port"), "smtplib.send": ("self", "data"),
    "poplib.connect": ("self", "host", "port"), "poplib.putline": ("self", "line"),
    "imaplib.open": ("self", "host", "port"), "imaplib.send": ("self", "data"),
    "telnetlib.Telnet.open": ("self", "host", "port"), "telnetlib.Telnet.write": ("self", "buffer"),
    "ctypes.dlopen": ("name",), "ctypes.dlsym": ("library", "name"), "ctypes.addressof": ("obj",),
    "ctypes.cdata": ("address",), "ctypes.cdata/buffer": ("pointer", "size", "offset"),
    "ctypes.create_string_buffer": ("init", "size"), "ctypes.create_unicode_buffer": ("init", "size"),
    "ctypes.string_at": ("ptr", "size"), "ctypes.wstring_at": ("ptr", "size"), "ctypes.set_errno": ("errno",),
    "ctypes.set_last_error": ("error",),
    "socket.__new__": ("self", "family", "type", "protocol"), "socket.bind": ("self", "address"),
    "socket.connect": ("self", "address"), "socket.getaddrinfo": ("host", "port", "family", "type", "protocol"),
    "socket.gethostbyaddr": ("ip_address",), "socket.gethostbyname": ("hostname",),
    "socket.getnameinfo": ("sockaddr",), "socket.getservbyname": ("servicename", "protocolname"),
    "socket.getservbyport": ("port", "protocolname"), "socket.sendmsg": ("self", "address"),
    "socket.sendto": ("self", "address"), "socket.sethostname": ("name",),
    "os.system": ("command",), "os.exec": ("path", "args", "env"), "os.spawn": ("mode", "path", "args", "env"),
    "os.posix_spawn": ("path", "argv", "env"), "os.kill": ("pid", "sig"), "os.killpg": ("pgid", "sig"),
    "os.listdir": ("path",), "os.scandir": ("path",), "os.mkdir": ("path", "mode", "dir_fd"),
    "os.remove": ("path", "dir_fd"), "os.rename": ("src", "dst", "src_dir_fd", "dst_dir_fd"),
    "os.rmdir": ("path", "dir_fd"), "os.chmod": ("path", "mode", "dir_fd"), "os.chown": ("path", "uid", "gid", "dir_fd"),
    "os.chdir": ("path",), "os.link": ("src", "dst", "src_dir_fd", "dst_dir_fd"), "os.symlink": ("src", "dst", "dir_fd"),
    "os.truncate": ("fd", "length"), "os.utime": ("path", "times", "ns", "dir_fd"), "os.putenv": ("key", "value"),
    "os.unsetenv": ("key",), "os.walk": ("top", "topdown", "onerror", "followlinks"),
    "os.fwalk": ("top", "topdown", "onerror", "follow_symlinks", "dir_fd"), "os.lockf": ("fd", "cmd", "len"),
    "os.getxattr": ("path", "attribute"), "os.setxattr": ("path", "attribute", "value", "flags"),
    "os.listxattr": ("path",), "os.removexattr": ("path", "attribute"),
}


def event_args(event):
    """The documented argument names of an audit event (a tuple; () unknown)."""
    return _EVENT_ARGS.get(event, ())


class AuditDenied(PermissionError):
    """An audit policy refused an event: raised from the audited call."""

    def __init__(self, event, args=(), rule=None, message=None):
        self.event = event
        self.args_ = tuple(args)
        self.rule = rule
        self._text = message if message else "audit policy denies " + event + _short_args(args)
        PermissionError.__init__(self, self._text)

    def __str__(self):
        return self._text


class _AnyType:
    def __repr__(self):
        return "ANY"

ANY = _AnyType()


def _short_args(args):
    var parts = []
    for a in tuple(args)[:3]:
        var r = _text(a)
        if len(r) > 60:
            r = r[:57] + "..."
        parts.append(r)
    return "(" + ", ".join(parts) + (", ..." if len(tuple(args)) > 3 else "") + ")"


def _text(a):
    # an argument as a pattern sees it
    if isinstance(a, str):
        return a
    if isinstance(a, (bytes, bytearray)):
        return bytes(a).decode("utf-8", "surrogateescape")
    if isinstance(a, tuple) and len(a) >= 2 and isinstance(a[0], str) and isinstance(a[1], int):
        return a[0] + ":" + str(a[1])
    var fs = getattr(type(a), "__fspath__", None)
    if fs is not None:
        try:
            return _text(fs(a))
        except Exception:
            pass
    if a is None or isinstance(a, (int, float)):
        return str(a)
    return "<" + type(a).__name__ + ">"


def _abs(s):
    import os.path
    if s.startswith("~"):
        s = os.path.expanduser(s)
    return os.path.normpath(os.path.abspath(s))


def _match_value(pat, a):
    if pat is ANY:
        return True
    if isinstance(pat, type):
        return isinstance(a, pat)
    if isinstance(pat, tuple):
        if not isinstance(a, (tuple, list)) or len(a) != len(pat):
            return False
        for p, x in zip(pat, a):
            if not _match_value(p, x):
                return False
        return True
    if isinstance(pat, str):
        var t = _text(a)
        if pat.startswith("/") or pat.startswith("~"):
            if t.startswith("<"):
                return False
            return _fnmatch.fnmatchcase(_abs(t), _abs(pat) if pat.startswith("~") else pat)
        return _fnmatch.fnmatchcase(t, pat)
    if callable(pat):
        return bool(pat(a))
    return pat == a


class Rule:
    """One rule: an action ("allow", "deny", "log"), an event glob and the
    argument patterns (positional, then by documented name)."""

    def __init__(self, action, event, args=(), named=None, message=None):
        if action not in ("allow", "deny", "log"):
            raise ValueError("a rule's action is allow, deny or log, not " + repr(action))
        if not isinstance(event, str) or not event:
            raise TypeError("a rule's event is a non-empty glob string")
        self.action = action
        self.event = event
        self.args = tuple(args)
        self.named = dict(named or {})
        self.message = message

    def matches(self, event, args):
        if not _fnmatch.fnmatchcase(event, self.event):
            return False
        args = tuple(args)
        for i, p in enumerate(self.args):
            if i >= len(args) or not _match_value(p, args[i]):
                return False
        if self.named:
            var names = _EVENT_ARGS.get(event, ())
            for k, p in self.named.items():
                if k not in names:
                    return False
                var i = names.index(k)
                if i >= len(args) or not _match_value(p, args[i]):
                    return False
        return True

    def text(self):
        var out = [self.action.ljust(5), self.event]
        for p in self.args:
            out.append(_pat_text(p))
        for k, p in self.named.items():
            out.append(k + "=" + _pat_text(p))
        if self.message:
            out.append("message=" + json.dumps(self.message))
        return " ".join(out)

    def __repr__(self):
        return "<nyaudit.Rule " + self.text() + ">"


def _pat_text(p):
    if p is ANY:
        return "*"
    if isinstance(p, str):
        return json.dumps(p) if (" " in p or p == "" or '"' in p) else p
    return "<" + type(p).__name__ + ">"


class Policy:
    """Allow / deny rules over audit events; install() makes it a hook."""

    def __init__(self, default="allow", log=None, freeze=True, keep=0):
        if default not in ("allow", "deny"):
            raise ValueError("default must be 'allow' or 'deny', not " + repr(default))
        self.default = default
        self.rules = []
        self.freeze = freeze
        self.installed = False
        self.denied = 0
        self.keep = keep
        self.events = []
        self._busy = set()          # the threads in the hook now
        self._log = None
        self._log_path = None
        if log is not None:
            self.set_log(log)

    def _check_open(self):
        if self.installed and self.freeze:
            raise RuntimeError("the audit policy is installed and frozen: it cannot be changed")

    def _add(self, action, event, args, named):
        self._check_open()
        var message = named.pop("message", None) if action == "deny" else None
        self.rules.append(Rule(action, event, args, named, message))
        return self

    def allow(self, event, *args, **named):
        """Allow events matching event (a glob) and the argument patterns."""
        return self._add("allow", event, args, named)

    def deny(self, event, *args, **named):
        """Deny them (AuditDenied; message= gives its text)."""
        return self._add("deny", event, args, named)

    def log(self, event, *args, **named):
        """Record them in the log (and go on to the next rule)."""
        return self._add("log", event, args, named)

    def set_log(self, log):
        self._check_open()
        if isinstance(log, str):
            self._log_path = log
            self._log = open(log, "a", encoding="utf-8")
        else:
            self._log = log

    def decide(self, event, args):
        """(action, rule): what the policy does with this event - "allow" or
        "deny", and the rule that decided (None for the default)."""
        for r in self.rules:
            if r.action == "log":
                continue
            if r.matches(event, args):
                return (r.action, r)
        return (self.default, None)

    def _logs(self, event, args):
        for r in self.rules:
            if r.action == "log" and r.matches(event, args):
                return True
        return False

    def __call__(self, event, args):
        var me = _thread.get_ident()
        if me in self._busy:
            return        # the policy's own work (its log's writes) is not judged
        self._busy.add(me)
        var decision = None
        try:
            var d = self.decide(event, args)
            decision = d
            if self._log is not None:
                self._write(self._log, event, args, d[0])
            elif self._logs(event, args):
                self._write(sys.stderr, event, args, d[0])
            if self.keep:
                self.events.append((event, tuple(args), d[0]))
                if len(self.events) > self.keep:
                    del self.events[0]
        finally:
            self._busy.discard(me)
        if decision[0] == "deny":
            self.denied += 1
            var rule = decision[1]
            raise AuditDenied(event, args, rule, rule.message if rule is not None else None)

    def _write(self, out, event, args, decision):
        var rec = {"event": event, "args": [_jsonable(a) for a in args], "decision": decision}
        out.write(json.dumps(rec) + "\n")
        try:
            out.flush()
        except Exception:
            pass

    def install(self):
        """Add the policy as an audit hook (sys.addaudithook); frozen from now
        on when freeze is true. Returns the policy."""
        if self.installed:
            return self
        sys.addaudithook(self)
        self.installed = True
        return self

    def granted(self, event, *args, **named):
        """A with block during which events matching the rule are allowed
        (put first): a capability lent for that block. Not once the policy
        is installed and frozen."""
        return _Grant(self, Rule("allow", event, args, named))

    def text(self):
        """The policy in the policy-file format."""
        var out = ["default " + self.default]
        if self._log_path:
            out.append("log " + self._log_path)
        for r in self.rules:
            out.append(r.text())
        return "\n".join(out) + "\n"

    def __repr__(self):
        return "<nyaudit.Policy default=" + self.default + ", " + str(len(self.rules)) + " rules" + (", installed" if self.installed else "") + ">"


class _Grant:
    def __init__(self, policy, rule):
        self.policy = policy
        self.rule = rule

    def __enter__(self):
        self.policy._check_open()
        self.policy.rules.insert(0, self.rule)
        return self.rule

    def __exit__(self, *exc):
        try:
            self.policy.rules.remove(self.rule)
        except ValueError:
            pass
        return False


def _jsonable(a, depth=0):
    if a is None or isinstance(a, (bool, int, float, str)):
        if isinstance(a, float) and a != a:
            return "nan"
        return a
    if isinstance(a, (bytes, bytearray)):
        return {"bytes": bytes(a).decode("latin-1")}
    if depth < 3 and isinstance(a, (tuple, list)):
        return [_jsonable(x, depth + 1) for x in a]
    if depth < 3 and type(a) is dict and len(a) <= 64:
        var d = {}
        for k in a:
            d[str(k)] = _jsonable(a[k], depth + 1)
        return d
    var fs = getattr(type(a), "__fspath__", None)
    if fs is not None:
        try:
            return _jsonable(fs(a), depth + 1)
        except Exception:
            pass
    return "<" + type(a).__name__ + ">"


# ── the policy file ─────────────────────────────────────────────────────
def _split_words(line):
    # words, with "..." quoted (JSON string syntax) as one
    var out = []
    var i = 0
    var n = len(line)
    while i < n:
        var c = line[i]
        if c == " " or c == "\t":
            i += 1
            continue
        if c == "#":
            break
        var j = i
        var word = ""
        while j < n and line[j] not in " \t":
            if line[j] == '"':
                var k = j + 1
                while k < n and line[k] != '"':
                    if line[k] == "\\":
                        k += 1
                    k += 1
                word += json.loads(line[j:k + 1])
                j = k + 1
            else:
                word += line[j]
                j += 1
        out.append(word)
        i = j
    return out


def _pattern_of(word):
    return ANY if word == "*" else word


def parse(text):
    """A Policy from the policy-file format (or its JSON form)."""
    var t = text.lstrip()
    if t.startswith("{"):
        var d = json.loads(t)
        var p = Policy(default=d.get("default", "allow"), log=d.get("log"), freeze=d.get("freeze", True))
        for r in d.get("rules", []):
            var named = dict(r[2]) if len(r) > 2 and r[2] else {}
            for k in list(named):
                named[k] = _pattern_of(named[k])
            var args = [_pattern_of(x) for x in (r[3] if len(r) > 3 else [])]
            p._add(r[0], r[1], args, named)
        return p
    var p = Policy()
    for lineno, line in enumerate(text.splitlines(), 1):
        var words = _split_words(line)
        if not words:
            continue
        var head = words[0]
        if head == "default":
            if len(words) != 2 or words[1] not in ("allow", "deny"):
                raise ValueError("policy line " + str(lineno) + ": default allow|deny")
            p.default = words[1]
            continue
        if head == "log" and len(words) == 2 and "=" not in words[1] and ("/" in words[1] or "." in words[1].split("/")[-1]) and not _looks_event(words[1]):
            p.set_log(words[1])
            continue
        if head not in ("allow", "deny", "log"):
            raise ValueError("policy line " + str(lineno) + ": unknown directive " + repr(head))
        if len(words) < 2:
            raise ValueError("policy line " + str(lineno) + ": " + head + " needs an event")
        var args = []
        var named = {}
        for w in words[2:]:
            var eq = w.find("=")
            if eq > 0:
                named[w[:eq]] = _pattern_of(w[eq + 1:])
            else:
                args.append(_pattern_of(w))
        p._add(head, words[1], args, named)
    return p


def _looks_event(w):
    # "log subprocess.*" names events; "log events.jsonl" a file
    return w in _EVENT_ARGS or "*" in w or w.endswith(".*")


def load(path):
    """A Policy read from a policy file (text or JSON)."""
    with open(path, encoding="utf-8") as f:
        return parse(f.read())


def install(policy):
    """Install a policy (a Policy, a policy file's path, or its text)."""
    if isinstance(policy, str):
        policy = load(policy) if "\n" not in policy else parse(policy)
    return policy.install()


def derive(log_path, default="deny"):
    """A policy allowing what a logged run did (the log of --audit-log or of
    a Policy's log=): each event seen, and for open its directories and modes
    - a starting point to tighten by hand. Returns its text."""
    import os.path
    var seen = []
    var opens = []
    with open(log_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            var rec = json.loads(line)
            var e = rec.get("event")
            if not isinstance(e, str):
                continue
            if e == "open":
                var a = rec.get("args", [])
                var path = a[0] if a and isinstance(a[0], str) else None
                var mode = a[1] if len(a) > 1 and isinstance(a[1], str) else "*"
                if path is not None:
                    var d = os.path.dirname(_abs(path))
                    var key = (d, mode)
                    if key not in opens:
                        opens.append(key)
                    continue
            if e not in seen:
                seen.append(e)
    var out = ["# derived by nyaudit from " + log_path, "default " + default]
    for e in seen:
        out.append("allow " + e)
    for d, mode in opens:
        out.append("allow open path=" + _pat_text(os.path.join(d, "*")) + " mode=" + _pat_text(mode))
    return "\n".join(out) + "\n"


def _cli_install(policy_path, log_path):
    # nython --audit-policy FILE / --audit-log FILE (the prelude's
    # _ny_audit_startup calls this before the program's first statement)
    var p = load(policy_path) if policy_path else Policy(default="allow")
    if log_path:
        p.freeze = False
        p.set_log(log_path)
        p.freeze = True
    p.install()
    return p


def _main(argv):
    if len(argv) >= 2 and argv[0] == "derive":
        sys.stdout.write(derive(argv[1], argv[2] if len(argv) > 2 else "deny"))
        return 0
    if len(argv) == 2 and argv[0] == "check":
        sys.stdout.write(load(argv[1]).text())
        return 0
    sys.stderr.write("usage: nython -m nyaudit derive LOG [allow|deny] | check POLICY\n")
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
