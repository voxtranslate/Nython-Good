# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/_winapi.ny - Python's _winapi module (round 87): the Win32 calls
# CPython's subprocess, multiprocessing and asyncio make on Windows, over
# src/builtins/nywin.cpp. Windows only: elsewhere `import _winapi` raises
# ModuleNotFoundError, as CPython's.
#
#     r, w = _winapi.CreatePipe(None, 0)
#     _winapi.WriteFile(w, b"data")             -> (4, 0)
#     _winapi.ReadFile(r, 4)                    -> (b'data', 0)
#     h = _winapi.CreateNamedPipe(r"\\.\pipe\x", _winapi.PIPE_ACCESS_DUPLEX |
#             _winapi.FILE_FLAG_OVERLAPPED, _winapi.PIPE_TYPE_MESSAGE |
#             _winapi.PIPE_READMODE_MESSAGE | _winapi.PIPE_WAIT, 1, 4096, 4096,
#             _winapi.NMPWAIT_WAIT_FOREVER, _winapi.NULL)
#     ov = _winapi.ConnectNamedPipe(h, overlapped=True)
#     _winapi.WaitForMultipleObjects([ov.event], False, 1000)
#
# CloseHandle, CreatePipe, CreateNamedPipe, ConnectNamedPipe, CreateFile,
# ReadFile / WriteFile (synchronous, or overlapped=True: an Overlapped
# object with .event, GetOverlappedResult(wait), getbuffer(), cancel()),
# PeekNamedPipe, SetNamedPipeHandleState, WaitNamedPipe,
# WaitForSingleObject, WaitForMultipleObjects, CreateProcess (STARTUPINFO's
# dwFlags / std handles / wShowWindow / lpAttributeList's handle_list, an
# environment mapping), OpenProcess, GetCurrentProcess, DuplicateHandle,
# GetExitCodeProcess, TerminateProcess, ExitProcess, GetFileType,
# GetStdHandle, GetLastError, GetModuleFileName, GetVersion, GetACP,
# NeedCurrentDirectoryForExePath, GetLongPathName, GetShortPathName,
# LCMapStringEx, CreateJunction, CreateFileMapping, OpenFileMapping,
# MapViewOfFile, UnmapViewOfFile, VirtualQuerySize, CreateEventW, SetEvent,
# ResetEvent; the constants CPython's module has. Handles are ints, unsigned
# as CPython shows them. Blocking calls release the GIL.

import sys

if sys.platform != "win32":
    raise ModuleNotFoundError("No module named '_winapi'", name="_winapi")

_BITS = 64 if sys.maxsize > 2 ** 32 else 32


def _u(h):
    return None if h is None else h & ((1 << _BITS) - 1)


def _s(h):
    if h is None:
        return 0
    h = int(h)
    if h >= 1 << (_BITS - 1):
        h -= 1 << _BITS
    return h


def _load():
    g = globals()
    for name, value in _winapi_consts():
        g[name] = _u(value) if name == "INVALID_HANDLE_VALUE" else value


_load()


class Overlapped:
    """OVERLAPPED structure wrapper (an operation ReadFile, WriteFile or
    ConnectNamedPipe started with overlapped=True)."""

    def __init__(self, _id):
        self._id = _id

    @property
    def event(self):
        return _u(_winapi_overlapped("event", self._id))

    def GetOverlappedResult(self, wait, /):
        n, err = _winapi_overlapped("result", self._id, bool(wait))
        return (n, err)

    def getbuffer(self):
        return _winapi_overlapped("buffer", self._id)

    def cancel(self):
        _winapi_overlapped("cancel", self._id)

    def __del__(self):
        try:
            _winapi_overlapped("free", self._id)
        except Exception:
            pass


Overlapped.__module__ = "_winapi"


def CloseHandle(handle, /):
    """Close handle."""
    _winapi_close(_s(handle))


def CreatePipe(pipe_attrs, size, /):
    """Create an anonymous pipe: (read handle, write handle)."""
    r, w = _winapi_create_pipe(size)
    return (_u(r), _u(w))


def CreateNamedPipe(name, open_mode, pipe_mode, max_instances, out_buffer_size, in_buffer_size,
                    default_timeout, security_attributes, /):
    sys.audit("_winapi.CreateNamedPipe", name, open_mode, pipe_mode)
    return _u(_winapi_create_named_pipe(name, open_mode, pipe_mode, max_instances, out_buffer_size,
                                        in_buffer_size, default_timeout))


def ConnectNamedPipe(handle, overlapped=False):
    if overlapped:
        oid, err = _winapi_connect_named_pipe(_s(handle), True)
        return Overlapped(oid)
    _winapi_connect_named_pipe(_s(handle), False)
    return None


def CreateFile(file_name, desired_access, share_mode, security_attributes, creation_disposition,
               flags_and_attributes, template_file, /):
    sys.audit("_winapi.CreateFile", file_name, desired_access, share_mode, creation_disposition, flags_and_attributes)
    return _u(_winapi_create_file(file_name, desired_access, share_mode, creation_disposition, flags_and_attributes))


def ReadFile(handle, size, overlapped=False):
    if overlapped:
        oid, err = _winapi_read_file(_s(handle), size, True)
        return (Overlapped(oid), err)
    data, err = _winapi_read_file(_s(handle), size, False)
    return (data, err)


def WriteFile(handle, buffer, overlapped=False):
    data = bytes(memoryview(buffer))
    if overlapped:
        oid, err = _winapi_write_file(_s(handle), data, True)
        return (Overlapped(oid), err)
    n, err = _winapi_write_file(_s(handle), data, False)
    return (n, err)


def PeekNamedPipe(handle, size=0, /):
    r = _winapi_peek_named_pipe(_s(handle), size)
    return tuple(r)


def SetNamedPipeHandleState(named_pipe, mode, max_collection_count, collect_data_timeout, /):
    _winapi_set_named_pipe_state(_s(named_pipe), mode, max_collection_count, collect_data_timeout)


def WaitNamedPipe(name, timeout, /):
    _winapi_wait_named_pipe(name, timeout)


def WaitForSingleObject(handle, milliseconds, /):
    return _winapi_wait_single(_s(handle), _s32(milliseconds))


def _s32(ms):
    return ms & 0xFFFFFFFF


def WaitForMultipleObjects(handle_seq, wait_flag, milliseconds=INFINITE, /):
    hs = [_s(h) for h in handle_seq]
    return _winapi_wait_multiple(hs, bool(wait_flag), _s32(milliseconds))


def GetCurrentProcess():
    """Return a handle object for the current process."""
    return _u(_winapi_process("current"))


def OpenProcess(desired_access, inherit_handle, process_id, /):
    sys.audit("_winapi.OpenProcess", process_id, desired_access)
    return _u(_winapi_process("open", desired_access, bool(inherit_handle), process_id))


def GetExitCodeProcess(process, /):
    return _winapi_process("exitcode", _s(process))


def TerminateProcess(handle, exit_code, /):
    _winapi_process("terminate", _s(handle), exit_code)


def ExitProcess(ExitCode, /):
    _winapi_process("exit", ExitCode)


def DuplicateHandle(source_process_handle, source_handle, target_process_handle, desired_access,
                    inherit_handle, options=0, /):
    return _u(_winapi_process("duplicate", _s(source_process_handle), _s(source_handle),
                              _s(target_process_handle), desired_access, bool(inherit_handle), options))


def _env_list(env):
    out = []
    for k, v in env.items():
        if not isinstance(k, str) or not isinstance(v, str):
            raise TypeError("environment can only contain strings")
        if "=" in k[1:] or k == "" or "\0" in k or "\0" in v:
            raise ValueError("illegal environment variable name")
        out.append(k + "=" + v)
    return out


def CreateProcess(application_name, command_line, proc_attrs, thread_attrs, inherit_handles,
                  creation_flags, env_mapping, current_directory, startup_info, /):
    """Create a new process and its primary thread: (process handle,
    thread handle, process id, thread id)."""
    si = None
    handle_list = None
    if startup_info is not None:
        si = [getattr(startup_info, "dwFlags", 0), _s(getattr(startup_info, "hStdInput", None)),
              _s(getattr(startup_info, "hStdOutput", None)), _s(getattr(startup_info, "hStdError", None)),
              getattr(startup_info, "wShowWindow", 0)]
        al = getattr(startup_info, "lpAttributeList", None)
        if al:
            hl = al.get("handle_list")
            if hl:
                handle_list = [_s(h) for h in hl]
    env = _env_list(env_mapping) if env_mapping is not None else None
    hp, ht, pid, tid = _winapi_create_process(application_name, command_line, bool(inherit_handles),
                                              creation_flags, env, current_directory, si, handle_list)
    return (_u(hp), _u(ht), pid, tid)


def GetACP():
    """Get the current Windows ANSI code page identifier."""
    return _winapi_misc("GetACP")


def GetFileType(handle):
    return _winapi_misc("GetFileType", _s(handle))


def GetStdHandle(std_handle, /):
    return _u(_winapi_misc("GetStdHandle", std_handle))


def GetLastError():
    return _winapi_misc("GetLastError")


def GetModuleFileName(module_handle, /):
    return _winapi_misc("GetModuleFileName", _s(module_handle))


def GetVersion():
    return _winapi_misc("GetVersion")


def NeedCurrentDirectoryForExePath(exe_name, /):
    return _winapi_misc("NeedCurrentDirectoryForExePath", exe_name)


def GetLongPathName(path):
    return _winapi_misc("GetLongPathName", path)


def GetShortPathName(path):
    return _winapi_misc("GetShortPathName", path)


def LCMapStringEx(locale, flags, src):
    return _winapi_misc("LCMapStringEx", locale or "", flags, src)


def CreateJunction(src_path, dst_path, /):
    _winapi_misc("CreateJunction", src_path, dst_path)


def CreateEventW(security_attributes, manual_reset, initial_state, name):
    return _u(_winapi_misc("CreateEvent", bool(manual_reset), bool(initial_state)))


def SetEvent(event):
    _winapi_misc("SetEvent", _s(event))


def ResetEvent(event):
    _winapi_misc("ResetEvent", _s(event))


def CreateFileMapping(file_handle, security_attributes, protect, max_size_high, max_size_low, name, /):
    return _u(_winapi_mapping("create", _s(file_handle), protect, max_size_high, max_size_low, name))


def OpenFileMapping(desired_access, inherit_handle, name, /):
    return _u(_winapi_mapping("open", desired_access, bool(inherit_handle), name))


def MapViewOfFile(file_map, desired_access, file_offset_high, file_offset_low, number_bytes, /):
    return _u(_winapi_mapping("map", _s(file_map), desired_access, file_offset_high, file_offset_low, number_bytes))


def UnmapViewOfFile(address, /):
    _winapi_mapping("unmap", _s(address))


def VirtualQuerySize(address, /):
    return _winapi_mapping("size", _s(address))
