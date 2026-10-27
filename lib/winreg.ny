# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/winreg.ny - Python's winreg module (round 87): the Windows registry,
# over advapi32 (src/builtins/nywin.cpp). Windows only: elsewhere `import
# winreg` raises ModuleNotFoundError, as CPython's.
#
#     import winreg
#     with winreg.CreateKey(winreg.HKEY_CURRENT_USER, r"Software\Example") as k:
#         winreg.SetValueEx(k, "count", 0, winreg.REG_DWORD, 7)
#         winreg.QueryValueEx(k, "count")          -> (7, 4)
#     winreg.DeleteKey(winreg.HKEY_CURRENT_USER, r"Software\Example")
#
# CloseKey, ConnectRegistry, CreateKey, CreateKeyEx, DeleteKey, DeleteKeyEx,
# DeleteValue, EnumKey, EnumValue, ExpandEnvironmentStrings, FlushKey,
# LoadKey, OpenKey, OpenKeyEx, QueryInfoKey, QueryValue, QueryValueEx,
# SaveKey, SetValue, SetValueEx, DisableReflectionKey, EnableReflectionKey,
# QueryReflectionKey; the HKEYType handle object (PyHKEY: .handle, Close,
# Detach, a context manager, int(), bool(), closed when collected); every
# HKEY_*, KEY_*, REG_* constant; `error` (OSError). Values convert as
# CPython's Reg2Py / Py2Reg: REG_DWORD / REG_QWORD ints, REG_SZ /
# REG_EXPAND_SZ str, REG_MULTI_SZ a list of str, REG_BINARY and the rest
# bytes (None when empty). Errors are CPython's OSError subclasses with
# winerror (a missing key: FileNotFoundError [WinError 2]); the winreg.*
# audit events with CPython's arguments.

import sys

if sys.platform != "win32":
    raise ModuleNotFoundError("No module named 'winreg'", name="winreg")

error = OSError
_BITS = 64 if sys.maxsize > 2 ** 32 else 32


def _u(h):
    return h & ((1 << _BITS) - 1)


def _s(h):
    h = int(h)
    if h >= 1 << (_BITS - 1):
        h -= 1 << _BITS
    return h


def _load():
    g = globals()
    for name, value in _winreg_consts():
        g[name] = _u(value) if name.startswith("HKEY_") else value


_load()


class HKEYType:
    """PyHKEY Object - A Python object, representing a win32 registry key.

    The object closes the registry key when it is destroyed (or Close() is
    called); Detach() returns the handle and gives up ownership of it."""

    def __init__(self, handle):
        self._handle = _u(handle)

    @property
    def handle(self):
        return self._handle

    def Close(self):
        """Closes the underlying Windows handle."""
        h = self._handle
        self._handle = 0
        if h:
            _winreg_close(_s(h))

    def Detach(self):
        """Detaches the Windows handle from the handle object."""
        sys.audit("winreg.PyHKEY.Detach", _s(self._handle))
        h = self._handle
        self._handle = 0
        return h

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.Close()
        return False

    def __int__(self):
        return self._handle

    def __bool__(self):
        return self._handle != 0

    def __hash__(self):
        return id(self) >> 4

    def __repr__(self):
        return "<PyHKEY:0x%0*X>" % (_BITS // 4, self._handle)

    __str__ = __repr__

    def __del__(self):
        try:
            self.Close()
        except Exception:
            pass


HKEYType.__module__ = "winreg"
HKEYType.__name__ = "PyHKEY"
HKEYType.__qualname__ = "PyHKEY"


def _key(k):
    if isinstance(k, HKEYType):
        return _s(k._handle)
    if isinstance(k, bool) or not isinstance(k, int):
        if k is None:
            raise TypeError("None is not a valid HKEY in this context")
        raise TypeError("The object is not a PyHKEY object")
    return _s(k)


def _text(name, s, none_ok=True):
    if s is None and none_ok:
        return None
    if not isinstance(s, str):
        raise TypeError("%s must be str%s, not %s" % (name, " or None" if none_ok else "", type(s).__name__))
    return s


def CloseKey(hkey, /):
    """Closes a previously opened registry key."""
    if isinstance(hkey, HKEYType):
        hkey.Close()
    else:
        _winreg_close(_key(hkey))


def ConnectRegistry(computer_name, key, /):
    """Establishes a connection to the registry on another computer."""
    _text("computer_name", computer_name)
    sys.audit("winreg.ConnectRegistry", computer_name, _key(key))
    return HKEYType(_winreg_connect(computer_name, _key(key)))


def _open(key, sub_key, reserved, access, create, event):
    k = _key(key)
    sub_key = _text("sub_key", sub_key)
    sys.audit(event, k, sub_key, access)
    h = HKEYType(_winreg_open(k, sub_key, reserved, access, create))
    sys.audit("winreg.OpenKey/result", _s(h._handle))
    return h


def CreateKey(key, sub_key, /):
    """Creates or opens the specified key."""
    # (RegCreateKeyW, as CPython: the access allowed; the event says KEY_WRITE)
    return _open(key, sub_key, 0, KEY_WRITE, 2, "winreg.CreateKey")


def CreateKeyEx(key, sub_key, reserved=0, access=KEY_WRITE):
    """Creates or opens the specified key."""
    return _open(key, sub_key, reserved, access, 1, "winreg.CreateKey")


def OpenKey(key, sub_key, reserved=0, access=KEY_READ):
    """Opens the specified key."""
    return _open(key, sub_key, reserved, access, 0, "winreg.OpenKey")


def OpenKeyEx(key, sub_key, reserved=0, access=KEY_READ):
    """Opens the specified key."""
    return _open(key, sub_key, reserved, access, 0, "winreg.OpenKey")


def DeleteKey(key, sub_key, /):
    """Deletes the specified key (it must have no subkeys)."""
    k = _key(key)
    sub_key = _text("sub_key", sub_key, False)
    sys.audit("winreg.DeleteKey", k, sub_key, 0)
    _winreg_delete_key(k, sub_key, 0, 0, 0)


def DeleteKeyEx(key, sub_key, access=KEY_WOW64_64KEY, reserved=0):
    """Deletes the specified key (it must have no subkeys)."""
    k = _key(key)
    sub_key = _text("sub_key", sub_key, False)
    sys.audit("winreg.DeleteKey", k, sub_key, access)
    _winreg_delete_key(k, sub_key, access, reserved, 1)


def DeleteValue(key, value, /):
    """Removes a named value from a registry key."""
    k = _key(key)
    value = _text("value", value)
    sys.audit("winreg.DeleteValue", k, value)
    _winreg_delete_value(k, value)


def EnumKey(key, index, /):
    """Enumerates subkeys of an open registry key."""
    k = _key(key)
    sys.audit("winreg.EnumKey", k, index)
    return _winreg_enum_key(k, index)


def _value(v, t):
    if t == REG_QWORD and isinstance(v, str):
        return int(v)
    return v


def EnumValue(key, index, /):
    """Enumerates values of an open registry key: (name, data, type)."""
    k = _key(key)
    sys.audit("winreg.EnumValue", k, index)
    name, v, t = _winreg_enum_value(k, index)
    return (name, _value(v, t), t)


def ExpandEnvironmentStrings(string, /):
    """Expand environment vars."""
    _text("ExpandEnvironmentStrings() argument", string, False)
    sys.audit("winreg.ExpandEnvironmentStrings", string)
    return _winreg_expand(string)


def FlushKey(key, /):
    """Writes all the attributes of a key to the registry."""
    _winreg_flush(_key(key))


def LoadKey(key, sub_key, file_name, /):
    """Insert data into the registry from a file."""
    k = _key(key)
    sys.audit("winreg.LoadKey", k, sub_key, file_name)
    _winreg_load_save("load", k, sub_key, file_name)


def SaveKey(key, file_name, /):
    """Saves the specified key, and all its subkeys, to the specified file."""
    k = _key(key)
    sys.audit("winreg.SaveKey", k, file_name)
    _winreg_load_save("save", k, file_name)


def QueryInfoKey(key, /):
    """Returns (number of subkeys, number of values, last modified as 100s of
    nanoseconds since Jan 1, 1601)."""
    k = _key(key)
    sys.audit("winreg.QueryInfoKey", k)
    return tuple(_winreg_query_info(k))


def QueryValue(key, sub_key, /):
    """Retrieves the unnamed value for a key, as a string."""
    k = _key(key)
    sub_key = _text("sub_key", sub_key)
    sys.audit("winreg.QueryValue", k, sub_key, None)
    return _winreg_query_value(k, sub_key)


def QueryValueEx(key, name, /):
    """Retrieves the type and value of a specified sub-key: (value, type)."""
    k = _key(key)
    name = _text("name", name)
    sys.audit("winreg.QueryValue", k, None, name)
    v, t = _winreg_query_value_ex(k, name)
    return (_value(v, t), t)


def SetValue(key, sub_key, type, value, /):
    """Associates a value with a specified key (as the key's default REG_SZ value)."""
    k = _key(key)
    sub_key = _text("sub_key", sub_key)
    if type != REG_SZ:
        raise TypeError("type must be winreg.REG_SZ")
    if not isinstance(value, str):
        raise TypeError("value must be str, not %s" % builtin_type(value).__name__)
    sys.audit("winreg.SetValue", k, sub_key, type, value)
    _winreg_set_value(k, sub_key, value)


builtin_type = type


def _convert(t, value):
    # CPython's Py2Reg
    bad = ValueError("Could not convert the data to the specified type.")
    if t in (REG_DWORD, REG_QWORD):
        if value is None:
            return 0
        if isinstance(value, bool) or not isinstance(value, int):
            raise bad
        if value < 0:
            raise OverflowError("can't convert negative int to unsigned")
        if value >= 1 << (32 if t == REG_DWORD else 64):
            raise OverflowError("int too big to convert")
        return _s(value) if t == REG_QWORD else value
    if t in (REG_SZ, REG_EXPAND_SZ):
        if value is None:
            return ""
        if not isinstance(value, str):
            raise bad
        return value
    if t == REG_MULTI_SZ:
        if value is None:
            return []
        if not isinstance(value, list):
            raise bad
        for s in value:
            if not isinstance(s, str):
                raise bad
        return value
    if value is None:
        return None
    if isinstance(value, str):
        raise TypeError("Objects of type 'str' can not be used as binary registry values")
    try:
        return bytes(memoryview(value))
    except TypeError:
        raise TypeError("Objects of type '%s' can not be used as binary registry values"
                        % builtin_type(value).__name__) from None


def SetValueEx(key, value_name, reserved, type, value, /):
    """Stores data in the value field of an open registry key."""
    k = _key(key)
    value_name = _text("value_name", value_name)
    data = _convert(type, value)
    sys.audit("winreg.SetValue", k, value_name, type, value)
    _winreg_set_value_ex(k, value_name, type, data)


def DisableReflectionKey(key, /):
    """Disables registry reflection for 32bit processes running on a 64bit OS."""
    k = _key(key)
    sys.audit("winreg.DisableReflectionKey", k)
    _winreg_reflection("disable", k)


def EnableReflectionKey(key, /):
    """Restores registry reflection for the specified disabled key."""
    k = _key(key)
    sys.audit("winreg.EnableReflectionKey", k)
    _winreg_reflection("enable", k)


def QueryReflectionKey(key, /):
    """Returns the reflection state for the specified key as a bool."""
    k = _key(key)
    sys.audit("winreg.QueryReflectionKey", k)
    return _winreg_reflection("query", k)
