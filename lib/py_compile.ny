# nython: module    (import it by name: it runs in a module scope of its own)
# lib/py_compile.ny - Python's py_compile (round 83): "compile" a source
# file - here, check it.
#
#     import py_compile
#     py_compile.compile("prog.py", doraise=True)   # PyCompileError if it
#                                                    # does not compile
#
# compile(file, cfile=None, dfile=None, doraise=False, optimize=-1,
#         invalidation_mode=None, quiet=0)
#     parses the file with the engines' compiler (the builtin compile());
#     a SyntaxError (or a source that does not decode) becomes
#     PyCompileError - its msg CPython's ('  File "f.py", line 2\n ...
#     SyntaxError: ...'), written to stderr unless doraise or quiet;
#     returns the name a cache file would have (cfile, or the PEP 3147
#     path __pycache__/NAME.nython-312.pyc: sys.implementation.cache_tag is
#     None here, so importlib.util.cache_from_source refuses, and the tag is
#     made from the implementation's name and language version) - or None on
#     an error, as CPython.
# PyCompileError (exc_type_name, exc_value, file, msg), PycInvalidationMode
# (TIMESTAMP, CHECKED_HASH, UNCHECKED_HASH), _get_default_invalidation_mode,
# main() (`nython -m py_compile [-q] files...`, `-` reads names from stdin).
#
# What it writes, honestly: NOTHING. Nython has no bytecode cache - both
# engines compile a module from its source each time it is imported - so a
# .pyc would be a file nothing reads; compile() is a syntax check that
# reports as CPython's does, and the path it returns does not exist.

import enum
import importlib.util
import os
import os.path
import sys
import traceback

# the builtin compile, kept before this module defines its own (run as
# `-m py_compile`, a later `import builtins` would see this module's)
_builtin_compile = compile

__all__ = ["compile", "main", "PyCompileError", "PycInvalidationMode"]


class PyCompileError(Exception):
    """Exception raised when an error occurs while attempting to
    compile the file.

    To raise this exception, use

        raise PyCompileError(exc_type,exc_value,file[,msg])

    where

        exc_type:   exception type to be used in error message
                    type name can be accesses as class variable
                    'exc_type_name'

        exc_value:  exception value to be used in error message
                    can be accesses as class variable 'exc_value'

        file:       name of file being compiled to be used in error message
                    can be accesses as class variable 'file'

        msg:        string message to be written as error message
                    If no value is given, a default exception message will be
                    given, consistent with 'standard' py_compile output.
                    message (or default) can be accesses as class variable
                    'msg'

    """

    def __init__(self, exc_type, exc_value, file, msg=''):
        exc_type_name = exc_type.__name__
        if exc_type is SyntaxError or issubclass(exc_type, SyntaxError):
            tbtext = ''.join(traceback.format_exception_only(
                exc_type, exc_value))
            errmsg = tbtext.replace('File "<string>"', 'File "%s"' % file)
        else:
            errmsg = "Sorry: %s: %s" % (exc_type_name,exc_value)

        Exception.__init__(self,msg or errmsg,exc_type_name,exc_value,file)

        self.exc_type_name = exc_type_name
        self.exc_value = exc_value
        self.file = file
        self.msg = msg or errmsg

    def __str__(self):
        return self.msg


class PycInvalidationMode(enum.Enum):
    TIMESTAMP = 1
    CHECKED_HASH = 2
    UNCHECKED_HASH = 3


def _get_default_invalidation_mode():
    if os.environ.get('SOURCE_DATE_EPOCH'):
        return PycInvalidationMode.CHECKED_HASH
    else:
        return PycInvalidationMode.TIMESTAMP


def compile(file, cfile=None, dfile=None, doraise=False, optimize=-1,
            invalidation_mode=None, quiet=0):
    """Byte-compile one Python source file to Python bytecode - here, check
    that it compiles (Nython writes no bytecode file).

    :param file: The source file name.
    :param cfile: The target byte compiled file name.  When not given, this
        defaults to the PEP 3147/PEP 488 location.
    :param dfile: Purported file name, i.e. the file name that shows up in
        error messages.  Defaults to the source file name.
    :param doraise: Flag indicating whether or not an exception should be
        raised when a compile error is found.  If an exception occurs and this
        flag is set to False, a string indicating the nature of the exception
        will be printed, and the function will return to the caller. If an
        exception occurs and this flag is set to True, a PyCompileError
        exception will be raised.
    :param optimize: The optimization level for the compiler.  Valid values
        are -1, 0, 1 and 2.  A value of -1 means to use the optimization
        level of the current interpreter, as given by -O command line options.
    :param invalidation_mode:
    :param quiet: Return full output with False or 0, errors only with 1,
        and no output with 2.

    :return: Path to the resulting byte compiled file (not written here).
    """
    if invalidation_mode is None:
        invalidation_mode = _get_default_invalidation_mode()
    if cfile is None:
        if optimize >= 0:
            optimization = optimize if optimize >= 1 else ''
            cfile = _cache_path(file, optimization)
        else:
            cfile = _cache_path(file, None)
    if os.path.islink(cfile):
        msg = ('{} is a symlink and will be changed into a regular file if '
               'import writes a byte-compiled file to it')
        raise FileExistsError(msg.format(cfile))
    elif os.path.exists(cfile) and not os.path.isfile(cfile):
        msg = ('{} is a non-regular file and will be changed into a regular '
               'one if import writes a byte-compiled file to it')
        raise FileExistsError(msg.format(cfile))
    with open(file, 'rb') as f:
        source_bytes = f.read()
    try:
        source = importlib.util.decode_source(source_bytes)
        builtins_compile(source, dfile or file, 'exec')
    except Exception as err:
        py_exc = PyCompileError(err.__class__, err, dfile or file)
        if quiet < 2:
            if doraise:
                raise py_exc
            else:
                sys.stderr.write(py_exc.msg + '\n')
        return
    return cfile


def _cache_path(path, optimization=None):
    # importlib.util.cache_from_source's PEP 3147 / PEP 488 path. Nython
    # keeps no bytecode cache (sys.implementation.cache_tag is None, so
    # cache_from_source raises NotImplementedError, as CPython's does then):
    # the name is made with the tag "nython-312" (implementation and
    # language version), and nothing is ever written there.
    try:
        if optimization is None:
            return importlib.util.cache_from_source(path)
        return importlib.util.cache_from_source(path, optimization=optimization)
    except NotImplementedError:
        pass
    head, tail = os.path.split(os.fspath(path))
    base, sep, rest = tail.rpartition('.')
    tag = '%s-%d%d' % (sys.implementation.name, sys.version_info[0], sys.version_info[1])
    almost = ''.join([(base if base else rest), '.', tag])
    if optimization is None:
        optimization = '' if sys.flags.optimize == 0 else sys.flags.optimize
    if optimization != '':
        almost = almost + '.opt-' + str(optimization)
    return os.path.join(head, '__pycache__', almost + '.pyc')


def builtins_compile(source, filename, mode):
    return _builtin_compile(source, filename, mode)


def main():
    import argparse

    description = 'A simple command-line interface for py_compile module.'
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument(
        '-q', '--quiet',
        action='store_true',
        help='Suppress error output',
    )
    parser.add_argument(
        'filenames',
        nargs='+',
        help='Files to compile',
    )
    args = parser.parse_args()
    if args.filenames == ['-']:
        filenames = [filename.rstrip('\n') for filename in sys.stdin.readlines()]
    else:
        filenames = args.filenames
    for filename in filenames:
        filename = filename.rstrip('\n')
        try:
            compile(filename, doraise=True)
        except PyCompileError as error:
            if args.quiet:
                parser.exit(1)
            else:
                parser.exit(1, error.msg)
        except OSError as error:
            if args.quiet:
                parser.exit(1)
            else:
                parser.exit(1, str(error))


if __name__ == "__main__":
    main()
