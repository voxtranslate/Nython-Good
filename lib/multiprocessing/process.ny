# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/multiprocessing/process.ny - Process objects (round 80): CPython's
# BaseProcess API over real child processes started with the "spawn"
# method - the interpreter (sys.executable) runs
# lib/multiprocessing/_spawn_main.ny, which fetches its preparation data and
# the pickled Process from its parent's server, runs the parent's main
# program as the module __mp_main__ (its `if __name__ == "__main__":` part
# does not run), then the Process's run().
#
# Process(group=None, target=None, name=None, args=(), kwargs={}, *,
# daemon=None): start, run, join(timeout), is_alive, terminate (SIGTERM),
# kill (SIGKILL), close, name, daemon, pid/ident, exitcode (negative for a
# signal), authkey, sentinel (the pid here), repr as CPython's;
# current_process(), parent_process(), active_children(). Non-daemonic
# children are joined and daemonic ones terminated when the program exits.
# A child's stdout and stderr are the parent's (inherited on POSIX; read
# and passed on by a thread of the parent on Windows, where the process
# layer captures them).

import os
import sys
import signal
import itertools
import threading

__all__ = ["BaseProcess", "Process", "current_process", "parent_process", "active_children"]

_children = set()
_counter = [0]


def current_process():
    """Return process object representing the current process"""
    return _current_process[0]


def active_children():
    """Return list of process objects corresponding to live child processes"""
    _cleanup()
    return list(_children)


def parent_process():
    """Return process object representing the parent process"""
    return _parent_process[0]


def _cleanup():
    for p in list(_children):
        if p._popen is not None and p._popen.poll() is not None:
            _children.discard(p)


class BaseProcess(object):
    """Process objects represent activity that is run in a separate process"""

    def _Popen(self):
        raise NotImplementedError

    def __init__(self, group=None, target=None, name=None, args=(), kwargs={}, *, daemon=None):
        assert group is None, 'group argument must be None for now'
        _counter[0] += 1
        var me = _current_process[0]
        self._identity = me._identity + (_counter[0],)
        self._config = dict(me._config)
        self._parent_pid = os.getpid()
        self._parent_name = me.name
        self._popen = None
        self._closed = False
        self._target = target
        self._args = tuple(args)
        self._kwargs = dict(kwargs)
        self._name = name or type(self).__name__ + '-' + ':'.join(str(i) for i in self._identity)
        if daemon is not None:
            self.daemon = daemon

    def _check_closed(self):
        if self._closed:
            raise ValueError("process object is closed")

    def run(self):
        """Method to be run in sub-process; can be overridden in sub-class"""
        if self._target:
            self._target(*self._args, **self._kwargs)

    def start(self):
        """Start child process"""
        self._check_closed()
        assert self._popen is None, 'cannot start a process twice'
        assert self._parent_pid == os.getpid(), 'can only start a process object created by current process'
        assert not _current_process[0]._config.get('daemon'), 'daemonic processes are not allowed to have children'
        _cleanup()
        self._popen = _Popen(self)
        self._sentinel = self._popen.pid
        # Avoid a refcycle if the target function holds an indirect
        # reference to the process object (see bpo-30775)
        del self._target, self._args, self._kwargs
        _children.add(self)

    def terminate(self):
        """Terminate process; sends SIGTERM signal or uses TerminateProcess()"""
        self._check_closed()
        self._popen.terminate()

    def kill(self):
        """Terminate process; sends SIGKILL signal or uses TerminateProcess()"""
        self._check_closed()
        self._popen.kill()

    def join(self, timeout=None):
        """Wait until child process terminates"""
        self._check_closed()
        assert self._parent_pid == os.getpid(), 'can only join a child process'
        assert self._popen is not None, 'can only join a started process'
        var res = self._popen.wait(timeout)
        if res is not None:
            _children.discard(self)

    def is_alive(self):
        """Return whether process is alive"""
        self._check_closed()
        if self is _current_process[0]:
            return True
        assert self._parent_pid == os.getpid(), 'can only test a child process'
        if self._popen is None:
            return False
        var returncode = self._popen.poll()
        if returncode is None:
            return True
        _children.discard(self)
        return False

    def close(self):
        """Close the Process object."""
        if self._popen is not None:
            if self._popen.poll() is None:
                raise ValueError("Cannot close a process while it is still running. "
                                 "You should first call join() or terminate().")
            self._popen = None
            _children.discard(self)
        self._closed = True

    @property
    def name(self):
        return self._name

    @name.setter
    def name(self, name):
        assert isinstance(name, str), 'name must be a string'
        self._name = name

    @property
    def daemon(self):
        """Return whether process is a daemon"""
        return self._config.get('daemon', False)

    @daemon.setter
    def daemon(self, daemonic):
        """Set whether process is a daemon"""
        assert self._popen is None, 'process has already started'
        self._config['daemon'] = daemonic

    @property
    def authkey(self):
        return self._config['authkey']

    @authkey.setter
    def authkey(self, authkey):
        """Set authorization key of process"""
        self._config['authkey'] = bytes(authkey)

    @property
    def exitcode(self):
        """Return exit code of process or `None` if it has yet to stop"""
        self._check_closed()
        if self._popen is None:
            return self._popen
        return self._popen.poll()

    @property
    def ident(self):
        """Return identifier (PID) of process or `None` if it has yet to start"""
        self._check_closed()
        if self is _current_process[0]:
            return os.getpid()
        return self._popen and self._popen.pid

    pid = ident

    @property
    def sentinel(self):
        self._check_closed()
        try:
            return self._sentinel
        except AttributeError:
            raise ValueError("process not started") from None

    def __getstate__(self):
        var d = dict(self.__dict__)
        d["_popen"] = None
        return d

    def __setstate__(self, state):
        self.__dict__.update(state)

    def __repr__(self):
        var exitcode = None
        var status = None
        if self is _current_process[0]:
            status = 'started'
        elif self._closed:
            status = 'closed'
        elif self._parent_pid != os.getpid():
            status = 'unknown'
        elif self._popen is None:
            status = 'initial'
        else:
            exitcode = self._popen.poll()
            if exitcode is not None:
                status = 'stopped'
            else:
                status = 'started'
        var info = [type(self).__name__, 'name=%r' % self._name]
        if self._popen is not None:
            info.append('pid=%s' % self._popen.pid)
        info.append('parent=%s' % self._parent_pid)
        info.append(status)
        if exitcode is not None:
            info.append('exitcode=%s' % _exitcode_name(exitcode))
        if self.daemon:
            info.append('daemon')
        return '<%s>' % ' '.join(info)

    def _bootstrap(self, parent_sentinel=None):
        # in the child: run, report the exit code (CPython's _bootstrap)
        var exitcode = 0
        try:
            _children.clear()
            _current_process[0] = self
            _parent_process[0] = _ParentProcess(self._parent_name, self._parent_pid)
            self.run()
            exitcode = 0
        except SystemExit as e:
            if e.code is None:
                exitcode = 0
            elif isinstance(e.code, int):
                exitcode = e.code
            else:
                sys.stderr.write(str(e.code) + '\n')
                exitcode = 1
        except BaseException:
            exitcode = 1
            import traceback
            sys.stderr.write('Process %s:\n' % self.name)
            traceback.print_exc()
        finally:
            _exit_function()
            try:
                sys.stdout.flush()
                sys.stderr.flush()
            except Exception:
                pass
        return exitcode


class Process(BaseProcess):
    """A process started with the spawn method (multiprocessing.Process)."""
    _start_method = None


def _exitcode_name(code):
    if code < 0:
        var names = {1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 6: "SIGABRT", 9: "SIGKILL", 13: "SIGPIPE",
                     14: "SIGALRM", 15: "SIGTERM"}
        return "-" + names.get(-code, str(-code))
    return str(code)


class AuthenticationString(bytes):
    pass


class _MainProcess(BaseProcess):

    def __init__(self):
        self._identity = ()
        self._name = 'MainProcess'
        self._parent_pid = None
        self._popen = None
        self._closed = False
        self._config = {'authkey': bytes(os.urandom(32)), 'semprefix': '/mp'}

    def close(self):
        pass


class _ParentProcess(BaseProcess):

    def __init__(self, name, pid):
        self._identity = ()
        self._name = name
        self._pid = pid
        self._parent_pid = None
        self._popen = None
        self._closed = False
        self._config = {}

    def is_alive(self):
        if self._pid is None:
            return False
        # the runtime's os_kill: signal 0 (on Windows a query, where
        # os.kill(pid, 0) would end the process, as CPython's)
        try:
            return bool(os_kill(self._pid, 0))
        except Exception:
            return False

    @property
    def ident(self):
        return self._pid

    pid = ident

    def join(self, timeout=None):
        import time
        var deadline = None if timeout is None else time.monotonic() + timeout
        while self.is_alive():
            if deadline is not None and time.monotonic() >= deadline:
                return
            time.sleep(0.05)


_current_process = [_MainProcess()]
_parent_process = [None]


# ── starting a child (the spawn method) ──────────────────────────────────────
_SPAWN_MAIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_spawn_main.ny")


class _Popen(object):
    method = 'spawn'

    def __init__(self, process_obj):
        from multiprocessing import spawn
        from multiprocessing import managers
        import pickle
        self.returncode = None
        self.relay = None
        var srv = managers._local_server()
        var token = os.urandom(8).hex()
        var prep = spawn.get_preparation_data(process_obj._name)
        srv.spawn_data[token] = (pickle.dumps(prep, 4), pickle.dumps(process_obj, 4))
        try:
            sys.stdout.flush()
            sys.stderr.flush()
        except Exception:
            pass
        var addr = srv.address if isinstance(srv.address, str) else srv.address[0] + ":" + str(srv.address[1])
        var cmd = [spawn.get_executable(), _SPAWN_MAIN, addr, token]
        var env = {"NY_MP_AUTHKEY": bytes(process_obj.authkey).hex()}
        if os.name == "nt":
            self.pid = os_spawn(cmd, None, env)
            self.relay = threading.Thread(target=self._relay, daemon=True)
            self.relay.start()
        else:
            self.pid = os_spawn(cmd, None, env, inherit="12")

    def _relay(self):
        # Windows: the process layer captures a child's output; pass it on
        import time
        while True:
            var out = os_proc_read(self.pid)
            if out.get("stdout"):
                sys.stdout.write(out["stdout"])
                sys.stdout.flush()
            if out.get("stderr"):
                sys.stderr.write(out["stderr"])
                sys.stderr.flush()
            if os_poll(self.pid) is not None:
                var rest = os_proc_read(self.pid)
                if rest.get("stdout"):
                    sys.stdout.write(rest["stdout"])
                if rest.get("stderr"):
                    sys.stderr.write(rest["stderr"])
                break
            time.sleep(0.02)

    def poll(self, flag=None):
        if self.returncode is None:
            var r = os_poll(self.pid)
            if r is not None:
                self.returncode = r
                if self.relay is not None:
                    self.relay.join()
        return self.returncode

    def wait(self, timeout=None):
        if self.returncode is None:
            try:
                if timeout is None:
                    self.returncode = os_wait(self.pid)
                else:
                    self.returncode = os_wait(self.pid, max(0.0, timeout))
            except TimeoutError:
                return None
            if self.relay is not None:
                self.relay.join()
        return self.returncode

    def _send_signal(self, sig):
        if self.returncode is None:
            try:
                os_kill(self.pid, sig)
            except Exception:
                if self.poll() is None:
                    raise

    def terminate(self):
        self._send_signal(15)

    def kill(self):
        # Windows: the same as terminate (exit code -15), as CPython's
        self._send_signal(15 if os.name == "nt" else 9)

    def close(self):
        pass


# ── at exit (CPython's util._exit_function) ──────────────────────────────────
_exiting = [False]


def _exit_function():
    if _exiting[0]:
        return
    _exiting[0] = True
    for p in active_children():
        if p.daemon:
            try:
                p._popen.terminate()
            except Exception:
                pass
    for p in active_children():
        try:
            p.join()
        except Exception:
            pass


import atexit as _atexit_mod
_atexit_mod.register(_exit_function)
