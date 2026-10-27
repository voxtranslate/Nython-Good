# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/h2/settings.ny - HTTP/2 settings (RFC 9113 6.5.2; round 86), as the h2
# package's h2.settings: SettingCodes, ChangedSetting, Settings.
#
# A Settings object is one side's view of one side's settings. A value set
# on it is pending until acknowledge() (the peer's SETTINGS ACK, or our ACK of
# the peer's frame) makes it current: reads give the current value, so a
# change is not relied on before the peer has seen it (RFC 9113 6.5.3).
# Unknown settings are kept and ignored (6.5.2). SettingCodes also names RFC
# 8441's ENABLE_CONNECT_PROTOCOL and RFC 9218's NO_RFC7540_PRIORITIES.
import enum

from h2.errors import ErrorCodes
from h2.exceptions import InvalidSettingsValueError

__all__ = ["SettingCodes", "ChangedSetting", "Settings"]


class SettingCodes(enum.IntEnum):
    """All known HTTP/2 setting codes."""
    HEADER_TABLE_SIZE = 0x1
    ENABLE_PUSH = 0x2
    MAX_CONCURRENT_STREAMS = 0x3
    INITIAL_WINDOW_SIZE = 0x4
    MAX_FRAME_SIZE = 0x5
    MAX_HEADER_LIST_SIZE = 0x6
    ENABLE_CONNECT_PROTOCOL = 0x8
    NO_RFC7540_PRIORITIES = 0x9


def _setting_code_from_int(code):
    try:
        return SettingCodes(code)
    except ValueError:
        return code


class ChangedSetting:
    def __init__(self, setting, original_value, new_value):
        self.setting = setting
        self.original_value = original_value
        self.new_value = new_value

    def __repr__(self):
        return "ChangedSetting(setting=%s, original_value=%s, new_value=%s)" % (
            _setting_name(self.setting), self.original_value, self.new_value)


def _setting_name(s):
    if isinstance(s, SettingCodes):
        return "SettingCodes." + s.name
    return str(s)


_UNLIMITED = 2 ** 32 + 1        # what the h2 package reports for "no limit"


def _validate_setting(setting, value):
    """The error code a received value is an error of, or 0 (RFC 9113 6.5.2)."""
    if setting == SettingCodes.ENABLE_PUSH:
        if value not in (0, 1):
            return ErrorCodes.PROTOCOL_ERROR
    elif setting == SettingCodes.INITIAL_WINDOW_SIZE:
        if not (0 <= value <= 2147483647):
            return ErrorCodes.FLOW_CONTROL_ERROR
    elif setting == SettingCodes.MAX_FRAME_SIZE:
        if not (16384 <= value <= 16777215):
            return ErrorCodes.PROTOCOL_ERROR
    elif setting == SettingCodes.MAX_HEADER_LIST_SIZE:
        if value < 0:
            return ErrorCodes.PROTOCOL_ERROR
    elif setting == SettingCodes.ENABLE_CONNECT_PROTOCOL:
        if value not in (0, 1):
            return ErrorCodes.PROTOCOL_ERROR
    elif setting == SettingCodes.NO_RFC7540_PRIORITIES:
        if value not in (0, 1):
            return ErrorCodes.PROTOCOL_ERROR
    return 0


class Settings:
    """A mapping of SettingCodes (or int) to values, with pending changes.

    client: whose settings these are (ENABLE_PUSH defaults to 1 for a client,
    0 for a server); initial_values: values to start from, current at once
    (what a connection announces in its first SETTINGS frame)."""
    def __init__(self, client=True, initial_values=None):
        self._settings = {
            SettingCodes.HEADER_TABLE_SIZE: [4096],
            SettingCodes.ENABLE_PUSH: [1 if client else 0],
            SettingCodes.INITIAL_WINDOW_SIZE: [65535],
            SettingCodes.MAX_FRAME_SIZE: [16384],
            SettingCodes.ENABLE_CONNECT_PROTOCOL: [0],
        }
        if initial_values is not None:
            for key in initial_values:
                value = initial_values[key]
                code = _validate_setting(key, value)
                if code:
                    raise InvalidSettingsValueError("Setting %d has invalid value %d" % (key, value), error_code=code)
                self._settings[_setting_code_from_int(key)] = [value]

    def acknowledge(self):
        """Make the oldest pending value of each setting current; returns
        {setting: ChangedSetting} for those that changed."""
        changed = {}
        for k in list(self._settings.keys()):
            v = self._settings[k]
            if len(v) > 1:
                old = v.pop(0)
                new = v[0]
                changed[k] = ChangedSetting(k, old, new)
        return changed

    @property
    def header_table_size(self):
        return self[SettingCodes.HEADER_TABLE_SIZE]

    @header_table_size.setter
    def header_table_size(self, value):
        self[SettingCodes.HEADER_TABLE_SIZE] = value

    @property
    def enable_push(self):
        return self[SettingCodes.ENABLE_PUSH]

    @enable_push.setter
    def enable_push(self, value):
        self[SettingCodes.ENABLE_PUSH] = value

    @property
    def initial_window_size(self):
        return self[SettingCodes.INITIAL_WINDOW_SIZE]

    @initial_window_size.setter
    def initial_window_size(self, value):
        self[SettingCodes.INITIAL_WINDOW_SIZE] = value

    @property
    def max_frame_size(self):
        return self[SettingCodes.MAX_FRAME_SIZE]

    @max_frame_size.setter
    def max_frame_size(self, value):
        self[SettingCodes.MAX_FRAME_SIZE] = value

    @property
    def max_concurrent_streams(self):
        return self._settings.get(SettingCodes.MAX_CONCURRENT_STREAMS, [_UNLIMITED])[0]

    @max_concurrent_streams.setter
    def max_concurrent_streams(self, value):
        self[SettingCodes.MAX_CONCURRENT_STREAMS] = value

    @property
    def max_header_list_size(self):
        v = self._settings.get(SettingCodes.MAX_HEADER_LIST_SIZE)
        return None if v is None else v[0]

    @max_header_list_size.setter
    def max_header_list_size(self, value):
        self[SettingCodes.MAX_HEADER_LIST_SIZE] = value

    @property
    def enable_connect_protocol(self):
        return self[SettingCodes.ENABLE_CONNECT_PROTOCOL]

    @enable_connect_protocol.setter
    def enable_connect_protocol(self, value):
        self[SettingCodes.ENABLE_CONNECT_PROTOCOL] = value

    @property
    def no_rfc7540_priorities(self):
        v = self._settings.get(SettingCodes.NO_RFC7540_PRIORITIES)
        return 0 if v is None else v[0]

    def __getitem__(self, key):
        v = self._settings[key]
        if v[0] is None:
            raise KeyError(key)
        return v[0]

    def __setitem__(self, key, value):
        code = _validate_setting(key, value)
        if code:
            raise InvalidSettingsValueError("Setting %d has invalid value %d" % (key, value), error_code=code)
        key = _setting_code_from_int(key)
        if key in self._settings:
            self._settings[key].append(value)
        else:
            self._settings[key] = [None, value]

    def __delitem__(self, key):
        del self._settings[key]

    def __contains__(self, key):
        v = self._settings.get(key)
        return v is not None and v[0] is not None

    def get(self, key, default=None):
        v = self._settings.get(key)
        if v is None or v[0] is None:
            return default
        return v[0]

    def __iter__(self):
        return iter([k for k in self._settings if self._settings[k][0] is not None])

    def keys(self):
        return list(self.__iter__())

    def items(self):
        return [(k, self._settings[k][0]) for k in self.keys()]

    def __len__(self):
        return len(self.keys())

    def __eq__(self, other):
        if isinstance(other, Settings):
            return self._settings == other._settings
        return NotImplemented

    def __ne__(self, other):
        r = self.__eq__(other)
        if r is NotImplemented:
            return r
        return not r

    __hash__ = None

    def __repr__(self):
        return "Settings(%s)" % ", ".join("%s=%s" % (_setting_name(k), v) for k, v in self.items())
