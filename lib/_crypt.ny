# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/_crypt.ny - CPython's _crypt C module (round 87) over the natives of
# src/builtins/nycrypt.cpp: crypt(word, salt) is crypt(3) of libcrypt loaded
# at run time (NY_LIBCRYPT names it, NY_NO_LIBCRYPT=1 refuses it), or
# Nython's own SHA-512-crypt / SHA-256-crypt / MD5-crypt when there is no
# such library - the same hashes byte for byte; another setting then gives
# libxcrypt's failure token "*0".
#
# Nython's additions: backend() - "libcrypt" or "native" - and
# native_crypt(word, salt), the native algorithms whatever is loaded.
import os as _os


def crypt(word, salt):
    """Hash a *word* with the given *salt* and return the hashed password.

    *word* will usually be a user's password.  *salt* (either a random 2 or 16
    character string, possibly prefixed with $digit$ to indicate the method)
    will be used to perturb the encryption algorithm and produce distinct
    results for a given *word*.
    """
    if not isinstance(word, str):
        raise TypeError("crypt() argument 1 must be str, not " + type(word).__name__)
    if not isinstance(salt, str):
        raise TypeError("crypt() argument 2 must be str, not " + type(salt).__name__)
    if "\x00" in word or "\x00" in salt:
        raise ValueError("embedded null character")
    r = _crypt_crypt(word, salt)
    if isinstance(r, int):
        raise OSError(r, _os.strerror(r))
    return r


def backend():
    return _crypt_backend()


def native_crypt(word, salt):
    return _crypt_native(word, salt)
