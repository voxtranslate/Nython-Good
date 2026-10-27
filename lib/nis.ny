# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/nis.ny - Python's nis (round 87; CPython 3.11's Modules/nismodule.c,
# deprecated there and removed in 3.13): Sun's NIS (Yellow Pages) through
# libnsl loaded at run time (yp_get_default_domain, yp_match, yp_first /
# yp_next, yp_maplist, yperr_string; src/builtins/nycrypt.cpp; NY_LIBNSL
# names the library).
#
#     import nis
#     nis.get_default_domain()             # nis.error when none is set
#     nis.match("alice", "passwd")         # "passwd" is "passwd.byname"
#     nis.cat("hosts")                     # {key: value}
#     nis.maps()
#
# match / cat / maps take the domain as their last argument (the default
# domain when it is not given), map nicknames as CPython (passwd, group,
# networks, hosts, protocols, services, aliases, ethers) and drop the NUL
# some servers keep at the end of keys and values, as nismodule.c does.
# Errors are nis.error with yperr_string's message ("Local domain name not
# set", "Can't bind to server which serves this domain", "No such map in
# server's domain" ...). Where there is no NIS library (Windows, a system
# without libnsl) importing it raises ModuleNotFoundError, as CPython built
# without it.
import warnings

if _nis_call("why"):
    raise ModuleNotFoundError("No module named 'nis'", name="nis")

warnings._deprecated(__name__, remove=(3, 13))

__all__ = ["match", "cat", "maps", "get_default_domain", "error"]


class error(Exception):
    __module__ = "nis"


_ALIASES = {
    "passwd": "passwd.byname",
    "group": "group.byname",
    "networks": "networks.byaddr",
    "hosts": "hosts.byname",
    "protocols": "protocols.bynumber",
    "services": "services.byname",
    "aliases": "mail.aliases",
    "ethers": "ethers.byname",
}


def _raise(err):
    raise error(_nis_call("errstr", err))


def _mapname(m):
    return _ALIASES.get(m, m)


def _domain(domain):
    if domain is None:
        return get_default_domain()
    if not isinstance(domain, str):
        raise TypeError("argument 'domain' must be str, not " + type(domain).__name__)
    return domain


def _fix(b):
    # nismodule.c: a trailing NUL some servers send is dropped
    if b.endswith(b"\x00"):
        b = b[:-1]
    return b


def _text(b):
    return b.decode("utf-8", "surrogateescape")


def get_default_domain():
    """Get the default NIS domain."""
    r = _nis_call("domain")
    if r[0]:
        _raise(r[0])
    return r[1]


def match(key, map, domain=None):
    """Return the value from the NIS map for the key."""
    if not isinstance(key, str):
        raise TypeError("match() argument 'key' must be str, not " + type(key).__name__)
    if not isinstance(map, str):
        raise TypeError("match() argument 'map' must be str, not " + type(map).__name__)
    dom = _domain(domain)
    m = _mapname(map)
    r = _nis_call("match", key.encode("utf-8", "surrogateescape"), m, dom)
    if r[0]:
        _raise(r[0])
    return _text(_fix(r[1]))


def cat(map, domain=None):
    """Return all key-value pairs of the NIS map as a dictionary."""
    if not isinstance(map, str):
        raise TypeError("cat() argument 'map' must be str, not " + type(map).__name__)
    dom = _domain(domain)
    m = _mapname(map)
    r = _nis_call("cat", m, dom)
    if r[0]:
        _raise(r[0])
    out = {}
    for k, v in r[1]:
        out[_text(_fix(k))] = _text(_fix(v))
    return out


def maps(domain=None):
    """Return a list of all the NIS maps of the domain."""
    dom = _domain(domain)
    r = _nis_call("maps", dom)
    if r[0]:
        _raise(r[0])
    return list(r[1])
