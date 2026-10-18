# nython: module    (import it by name: it runs in a module scope of its own)
# lib/encodings/__init__.ny - Python's encodings package (round 83, CPython
# 3.12's encodings/__init__.py): the codec search function and its modules.
#
#     import encodings, codecs
#     encodings.normalize_encoding("Latin 1")      # 'Latin_1'
#     encodings.search_function("cp1251").name     # 'cp1251'
#     "Привет".encode("cp1251"); codecs.lookup("koi8_r")
#     encodings.aliases.aliases["utf8"]             # 'utf_8'
#
# search_function(encoding) (normalize, the aliases table, import
# encodings.<module>, its getregentry(), cached), normalize_encoding,
# CodecRegistryError, aliases (CPython's table). Importing the package
# registers search_function with codecs, as CPython's startup does; and
# lib/codecs.ny imports it the first time a name is not one of its own, so
# "x".encode("cp1251") works without an import.
#
# The modules: CPython's own for every single-byte code page (cp037 ...
# cp1258, iso8859_1 ... iso8859_16, koi8_r/u/t, mac_*, ptcp154, tis_620,
# hp_roman8, kz1048...: charmap tables over codecs.charmap_encode/decode),
# for the Unicode codecs (utf_8, utf_8_sig, utf_16/32 and their -le/-be,
# unicode_escape, raw_unicode_escape, latin_1, ascii, charmap - over the
# native codec table, include/NyCodecs.hpp, through lib/codecs.ny's _codecs
# functions), and hex_codec, base64_codec, bz2_codec, zlib_codec, uu_codec,
# rot_13, punycode, undefined; idna and quopri_codec are lib/codecs.ny's
# (idna's nameprep is lower-casing: no Unicode 3.2 normalization tables).
#
# Round 84: the CJK multibyte codecs (big5, big5hkscs, cp950, gb2312, gbk,
# gb18030, hz, euc_jp, euc_jis_2004, euc_jisx0213, shift_jis, shift_jis_2004,
# shift_jisx0213, cp932, iso2022_jp/_1/_2/_2004/_3/_ext, iso2022_kr, euc_kr,
# cp949, johab - CPython's modules over _codecs_cn/hk/iso2022/jp/kr/tw and
# _multibytecodec, native in src/builtins/nycjk.cpp), utf_7, and mbcs/oem
# (Windows' code pages through WideCharToMultiByte; elsewhere their import
# fails and the lookup is a LookupError, as in CPython).

""" Standard "encodings" Package

    Standard Python encoding modules are stored in this package
    directory.

    Codec modules must have names corresponding to normalized encoding
    names as defined in the normalize_encoding() function below, e.g.
    'utf-8' must be implemented by the module 'utf_8.py'.

    Each codec module must export the following interface:

    * getregentry() -> codecs.CodecInfo object
    The getregentry() API must return a CodecInfo object with encoder, decoder,
    incrementalencoder, incrementaldecoder, streamwriter and streamreader
    attributes which adhere to the Python Codec Interface Standard.

    In addition, a module may optionally also define the following
    APIs which are then used by the package's codec search function:

    * getaliases() -> sequence of encoding name strings to use as aliases

    Alias names returned by getaliases() must be normalized encoding
    names as defined by normalize_encoding().

Written by Marc-Andre Lemburg (mal@lemburg.com).

(c) Copyright CNRI, All Rights Reserved. NO WARRANTY.

"""#"

import codecs
import sys
import importlib as _importlib
from encodings import aliases

_cache = {}
_unknown = '--unknown--'
_import_tail = ['*']
_aliases = aliases.aliases

class CodecRegistryError(LookupError, SystemError):
    pass

def normalize_encoding(encoding):

    """ Normalize an encoding name.

        Normalization works as follows: all non-alphanumeric
        characters except the dot used for Python package names are
        collapsed and replaced with a single underscore, e.g. '  -;#'
        becomes '_'. Leading and trailing underscores are removed.

        Note that encoding names should be ASCII only.

    """
    if isinstance(encoding, bytes):
        encoding = str(encoding, "ascii")

    chars = []
    punct = False
    for c in encoding:
        if c.isalnum() or c == '.':
            if punct and chars:
                chars.append('_')
            if c.isascii():
                chars.append(c)
            punct = False
        else:
            punct = True
    return ''.join(chars)

def search_function(encoding):

    # Cache lookup
    entry = _cache.get(encoding, _unknown)
    if entry is not _unknown:
        return entry

    # Import the module:
    #
    # First try to find an alias for the normalized encoding
    # name and lookup the module using the aliased name, then try to
    # lookup the module using the standard import scheme, i.e. first
    # try in the encodings package, then at top-level.
    #
    norm_encoding = normalize_encoding(encoding)
    aliased_encoding = _aliases.get(norm_encoding) or \
                       _aliases.get(norm_encoding.replace('.', '_'))
    if aliased_encoding is not None:
        modnames = [aliased_encoding,
                    norm_encoding]
    else:
        modnames = [norm_encoding]
    for modname in modnames:
        if not modname or '.' in modname:
            continue
        try:
            # Import is absolute to prevent the possibly malicious import of a
            # module with side-effects that is not in the 'encodings' package.
            mod = _importlib.import_module('encodings.' + modname)
        except ImportError:
            # ImportError may occur because 'encodings.(modname)' does not exist,
            # or because it imports a name that does not exist (see mbcs and oem)
            pass
        else:
            break
    else:
        mod = None

    try:
        getregentry = mod.getregentry
    except AttributeError:
        # Not a codec module
        mod = None

    if mod is None:
        # Cache misses
        _cache[encoding] = None
        return None

    # Now ask the module for the registry entry
    entry = getregentry()
    if not isinstance(entry, codecs.CodecInfo):
        if not 4 <= len(entry) <= 7:
            raise CodecRegistryError('module "%s" (%s) failed to register'
                                     % (mod.__name__, mod.__file__))
        if not callable(entry[0]) or not callable(entry[1]) or \
           (entry[2] is not None and not callable(entry[2])) or \
           (entry[3] is not None and not callable(entry[3])) or \
           (len(entry) > 4 and entry[4] is not None and not callable(entry[4])) or \
           (len(entry) > 5 and entry[5] is not None and not callable(entry[5])):
            raise CodecRegistryError('incompatible codecs in module "%s" (%s)'
                                     % (mod.__name__, mod.__file__))
        if len(entry)<7 or entry[6] is None:
            entry += (None,)*(6-len(entry)) + (mod.__name__.split(".", 1)[1],)
        entry = codecs.CodecInfo(*entry)

    # Cache the codec registry entry
    _cache[encoding] = entry

    # Register its aliases (without overwriting previously registered
    # aliases)
    try:
        codecaliases = mod.getaliases()
    except AttributeError:
        pass
    else:
        for alias in codecaliases:
            if alias not in _aliases:
                _aliases[alias] = modname

    # Return the registry entry
    return entry

# Register the search_function in the Python codec registry
codecs.register(search_function)

if sys.platform == 'win32':
    # bpo-671666, bpo-46668: If Python does not implement a codec for current
    # Windows ANSI code page, use the "mbcs" codec instead:
    # WideCharToMultiByte() and MultiByteToWideChar() functions with CP_ACP.
    # Python does not support custom code pages.
    def _alias_mbcs(encoding):
        try:
            # (round 84: _winapi.GetACP() is the _ny_codec native's "acp")
            ansi_code_page = "cp%s" % _ny_codec("acp")
            if encoding == ansi_code_page:
                import encodings.mbcs
                return encodings.mbcs.getregentry()
        except ImportError:
            # Imports may fail while we are shutting down
            pass

    codecs.register(_alias_mbcs)
