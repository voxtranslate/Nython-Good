# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/venv/__init__.ny - Python's venv module (round 87): virtual
# environments (PEP 405), CPython 3.12's venv/__init__.py for Nython.
#
#     nython -m venv DIR [--clear] [--system-site-packages] [--without-pip]
#                        [--prompt P] [--upgrade-deps] [--symlinks | --copies]
#     import venv; venv.create("env", with_pip=True)
#
# The environment has CPython's layout:
#     DIR/pyvenv.cfg            home, include-system-site-packages, version,
#                               prompt, executable, command
#     DIR/bin/nython            a symbolic link to the installation's binary
#                               (nython3, nython3.12 link to it); Windows:
#                               DIR\Scripts\nython.exe, a copy (or hard link)
#                               of it with the DLLs beside it
#     DIR/bin/activate ...      bash/zsh, fish, csh, PowerShell (Activate.ps1)
#                               and cmd (activate.bat, deactivate.bat)
#     DIR/lib/nython3.12/site-packages   (Windows: DIR\Lib\site-packages)
# Started through DIR/bin/nython, the engines find pyvenv.cfg (src/NySite.cpp):
# sys.prefix is DIR, sys.base_prefix the installation, the environment's
# site-packages is on sys.path (and the installation's with
# --system-site-packages), and the installer nypip (`nython -m pip`)
# installs there. ensurepip (the default; --without-pip skips it) puts nypip
# itself into the environment, with its pip/pip3/nypip commands.
#
# EnvBuilder(system_site_packages, clear, symlinks, upgrade, with_pip,
# prompt, upgrade_deps) with create(), ensure_directories(),
# create_configuration(), setup_python(), setup_scripts(), post_setup(),
# install_scripts(), replace_variables(), upgrade_dependencies(); create();
# main() - CPython's API.
"""
Virtual environment (venv) package for Python. Based on PEP 405.

Copyright (C) 2011-2014 Vinay Sajip.
Licensed to the PSF under a contributor agreement.
"""
import logging
import os
import shutil
import subprocess
import sys
import sysconfig
import types
import shlex


CORE_VENV_DEPS = ('nypip',)
logger = logging.getLogger(__name__)

_EXE = ".exe" if os.name == "nt" else ""


class EnvBuilder:
    """
    This class exists to allow virtual environment creation to be
    customized. The constructor parameters determine the builder's
    behaviour when called upon to create a virtual environment.

    By default, the builder makes the system (global) site-packages dir
    *un*available to the created environment.

    If invoked using the Python -m option, the default is to use copying
    on Windows platforms but symlinks elsewhere. If instantiated some
    other way, the default is to *not* use symlinks.

    :param system_site_packages: If True, the system (global) site-packages
                                 dir is available to created environments.
    :param clear: If True, delete the contents of the environment directory if
                  it already exists, before environment creation.
    :param symlinks: If True, attempt to symlink rather than copy files into
                     virtual environment.
    :param upgrade: If True, upgrade an existing virtual environment.
    :param with_pip: If True, ensure pip is installed in the virtual
                     environment
    :param prompt: Alternative terminal prefix for the environment.
    :param upgrade_deps: Update the base venv modules to the latest on PyPI
    """

    def __init__(self, system_site_packages=False, clear=False,
                 symlinks=False, upgrade=False, with_pip=False, prompt=None,
                 upgrade_deps=False):
        self.system_site_packages = system_site_packages
        self.clear = clear
        self.symlinks = symlinks
        self.upgrade = upgrade
        self.with_pip = with_pip
        self.orig_prompt = prompt
        if prompt == '.':  # see bpo-38901
            prompt = os.path.basename(os.getcwd())
        self.prompt = prompt
        self.upgrade_deps = upgrade_deps

    def create(self, env_dir):
        """
        Create a virtual environment in a directory.

        :param env_dir: The target directory to create an environment in.

        """
        env_dir = os.path.abspath(env_dir)
        context = self.ensure_directories(env_dir)
        # See issue 24875. We need system_site_packages to be False
        # until after pip is installed.
        true_system_site_packages = self.system_site_packages
        self.system_site_packages = False
        self.create_configuration(context)
        self.setup_python(context)
        if self.with_pip:
            self._setup_pip(context)
        if not self.upgrade:
            self.setup_scripts(context)
            self.post_setup(context)
        if true_system_site_packages:
            # We had set it to False before, now
            # restore it and rewrite the configuration
            self.system_site_packages = True
            self.create_configuration(context)
        if self.upgrade_deps:
            self.upgrade_dependencies(context)

    def clear_directory(self, path):
        for fn in os.listdir(path):
            fn = os.path.join(path, fn)
            if os.path.islink(fn) or os.path.isfile(fn):
                os.remove(fn)
            elif os.path.isdir(fn):
                shutil.rmtree(fn)

    def _venv_path(self, env_dir, name):
        vars = {
            'base': env_dir,
            'platbase': env_dir,
            'installed_base': env_dir,
            'installed_platbase': env_dir,
        }
        return sysconfig.get_path(name, scheme='venv', vars=vars)

    def ensure_directories(self, env_dir):
        """
        Create the directories for the environment.

        Returns a context object which holds paths in the environment,
        for use by subsequent logic.
        """

        def create_if_needed(d):
            if not os.path.exists(d):
                os.makedirs(d)
            elif os.path.islink(d) or os.path.isfile(d):
                raise ValueError('Unable to create directory %r' % d)

        if os.pathsep in os.fspath(env_dir):
            raise ValueError(f'Refusing to create a venv in {env_dir} because '
                             f'it contains the PATH separator {os.pathsep}.')
        if os.path.exists(env_dir) and self.clear:
            self.clear_directory(env_dir)
        context = types.SimpleNamespace()
        context.env_dir = env_dir
        context.env_name = os.path.split(env_dir)[1]
        prompt = self.prompt if self.prompt is not None else context.env_name
        context.prompt = '(%s) ' % prompt
        create_if_needed(env_dir)
        executable = sys._base_executable
        if not executable:  # see gh-96861
            raise ValueError('Unable to determine path to the running '
                             'Python interpreter. Provide an explicit path or '
                             'check that your PATH environment variable is '
                             'correctly set.')
        dirname, exename = os.path.split(os.path.abspath(executable))
        context.executable = executable
        context.python_dir = dirname
        context.python_exe = exename
        binpath = self._venv_path(env_dir, 'scripts')
        incpath = self._venv_path(env_dir, 'include')
        libpath = self._venv_path(env_dir, 'purelib')

        context.inc_path = incpath
        create_if_needed(incpath)
        context.lib_path = libpath
        create_if_needed(libpath)
        # Issue 21197: create lib64 as a symlink to lib on 64-bit non-OS X POSIX
        if ((sys.maxsize > 2**32) and (os.name == 'posix') and
            (sys.platform != 'darwin')):
            link_path = os.path.join(env_dir, 'lib64')
            if not os.path.exists(link_path):   # Issue #21643
                os.symlink('lib', link_path)
        context.bin_path = binpath
        context.bin_name = os.path.relpath(binpath, env_dir)
        # Nython: the environment's interpreter is always bin/nython
        # (Scripts\nython.exe), whatever the installation's binary is named
        # (build/nython-cli)
        context.env_exe = os.path.join(binpath, 'nython' + _EXE)
        create_if_needed(binpath)
        # Assign and update the command to use when launching the newly created
        # environment, in case it isn't simply the executable script (e.g. bpo-45337)
        context.env_exec_cmd = context.env_exe
        return context

    def create_configuration(self, context):
        """
        Create a configuration file indicating where the environment's Python
        was copied from, and whether the system site-packages should be made
        available in the environment.

        :param context: The information for the environment creation request
                        being processed.
        """
        context.cfg_path = path = os.path.join(context.env_dir, 'pyvenv.cfg')
        with open(path, 'w', encoding='utf-8') as f:
            f.write('home = %s\n' % context.python_dir)
            if self.system_site_packages:
                incl = 'true'
            else:
                incl = 'false'
            f.write('include-system-site-packages = %s\n' % incl)
            f.write('version = %d.%d.%d\n' % sys.version_info[:3])
            f.write('implementation = nython %d.%d.%d\n' % tuple(sys.implementation.version[:3]))
            if self.prompt is not None:
                f.write(f'prompt = {self.prompt!r}\n')
            f.write('executable = %s\n' % os.path.realpath(sys._base_executable))
            args = []
            nt = os.name == 'nt'
            if nt and self.symlinks:
                args.append('--symlinks')
            if not nt and not self.symlinks:
                args.append('--copies')
            if not self.with_pip:
                args.append('--without-pip')
            if self.system_site_packages:
                args.append('--system-site-packages')
            if self.clear:
                args.append('--clear')
            if self.upgrade:
                args.append('--upgrade')
            if self.upgrade_deps:
                args.append('--upgrade-deps')
            if self.orig_prompt is not None:
                args.append(f'--prompt="{self.orig_prompt}"')

            args.append(context.env_dir)
            args = ' '.join(args)
            f.write(f'command = {sys.executable} -m venv {args}\n')

    if os.name != 'nt':
        def symlink_or_copy(self, src, dst, relative_symlinks_ok=False):
            """
            Try symlinking a file, and if that fails, fall back to copying.
            """
            force_copy = not self.symlinks
            if not force_copy:
                try:
                    if not os.path.islink(dst):  # can't link to itself!
                        if relative_symlinks_ok:
                            assert os.path.dirname(src) == os.path.dirname(dst)
                            os.symlink(os.path.basename(src), dst)
                        else:
                            os.symlink(src, dst)
                except Exception:   # may need to use a more specific exception
                    logger.warning('Unable to symlink %r to %r', src, dst)
                    force_copy = True
            if force_copy:
                shutil.copyfile(src, dst)
    else:
        def symlink_or_copy(self, src, dst, relative_symlinks_ok=False):
            """
            Try symlinking a file, and if that fails, fall back to copying.
            Nython: copies are hard links where the file system allows them
            (Scripts\\nython.exe is the installation's binary, not a
            launcher of its own).
            """
            if os.path.lexists(dst):
                os.remove(dst)
            if self.symlinks:
                try:
                    os.symlink(src, dst)
                    return
                except Exception:   # may need to use a more specific exception
                    logger.warning('Unable to symlink %r to %r', src, dst)
            try:
                os.link(src, dst)
                return
            except Exception:
                pass
            shutil.copyfile(src, dst)

    def setup_python(self, context):
        """
        Set up a Python executable in the environment.

        :param context: The information for the environment creation request
                        being processed.
        """
        binpath = context.bin_path
        path = context.env_exe
        copier = self.symlink_or_copy
        dirname = context.python_dir
        if os.name != 'nt':
            copier(context.executable, path)
            if not os.path.islink(path):
                os.chmod(path, 0o755)
            for suffix in ('nython3', f'nython3.{sys.version_info[1]}'):
                path = os.path.join(binpath, suffix)
                if not os.path.exists(path):
                    # Issue 18807: make copies if
                    # symlinks are not wanted
                    copier(context.env_exe, path, relative_symlinks_ok=True)
                    if not os.path.islink(path):
                        os.chmod(path, 0o755)
        else:
            # Nython: the binary as Scripts\nython.exe, and the DLLs it loads
            # (SDL3 ...) beside it - the Windows loader looks in the
            # executable's directory
            copier(context.executable, path)
            for f in os.listdir(dirname):
                if os.path.normcase(os.path.splitext(f)[1]) == '.dll':
                    src = os.path.join(dirname, f)
                    if os.path.isfile(src):
                        copier(src, os.path.join(binpath, f))

    def _call_new_python(self, context, *py_args, **kwargs):
        """Executes the newly created Python using safe-ish options"""
        # gh-98251: We do not want to just use '-I' because that masks
        # legitimate user preferences (such as not writing bytecode). All we
        # really need is to ensure that the path variables do not overrule
        # normal venv handling.
        args = [context.env_exec_cmd, *py_args]
        kwargs['env'] = env = os.environ.copy()
        env['VIRTUAL_ENV'] = context.env_dir
        env.pop('PYTHONHOME', None)
        env.pop('PYTHONPATH', None)
        env.pop('NYTHONPATH', None)
        kwargs['cwd'] = context.env_dir
        subprocess.check_output(args, **kwargs)

    def _setup_pip(self, context):
        """Installs or upgrades pip in a virtual environment"""
        try:
            self._call_new_python(context, '-m', 'ensurepip', '--upgrade',
                                  '--default-pip', stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError as err:
            out = err.output.decode('utf-8', 'replace') if isinstance(err.output, bytes) else str(err.output)
            raise RuntimeError('ensurepip failed in %s:\n%s' % (context.env_dir, out)) from None

    def setup_scripts(self, context):
        """
        Set up scripts into the created environment from a directory.

        This method installs the default scripts into the environment
        being created. You can prevent the default installation by overriding
        this method if you really need to, or if you need to specify
        a different location for the scripts to install. By default, the
        'scripts' directory in the venv package is used as the source of
        scripts to install.
        """
        path = os.path.abspath(os.path.dirname(__file__))
        path = os.path.join(path, 'scripts')
        self.install_scripts(context, path)

    def post_setup(self, context):
        """
        Hook for post-setup modification of the venv. Subclasses may install
        additional packages or scripts here, add activation shell scripts, etc.

        :param context: The information for the environment creation request
                        being processed.
        """
        pass

    def replace_variables(self, text, context):
        """
        Replace variable placeholders in script text with context-specific
        variables.

        Return the text passed in , but with variables replaced.

        :param text: The text in which to replace placeholder variables.
        :param context: The information for the environment creation request
                        being processed.
        """
        replacements = {
            '__VENV_DIR__': context.env_dir,
            '__VENV_NAME__': context.env_name,
            '__VENV_PROMPT__': context.prompt,
            '__VENV_BIN_NAME__': context.bin_name,
            '__VENV_PYTHON__': context.env_exe,
        }

        def quote_ps1(s):
            """
            This should satisfy PowerShell quoting rules [1], unless the quoted
            string is passed directly to Windows native commands [2].
            [1]: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_quoting_rules
            [2]: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_parsing#passing-arguments-that-contain-quote-characters
            """
            s = s.replace("'", "''")
            return f"'{s}'"

        def quote_bat(s):
            return s

        # gh-124651: need to quote the template strings properly
        quote = shlex.quote
        script_path = context.script_path
        if script_path.endswith('.ps1'):
            quote = quote_ps1
        elif script_path.endswith('.bat'):
            quote = quote_bat
        else:
            # fallbacks to POSIX shell compliant quote
            quote = shlex.quote

        replacements = {key: quote(s) for key, s in replacements.items()}
        for key, quoted in replacements.items():
            text = text.replace(key, quoted)
        return text

    def install_scripts(self, context, path):
        """
        Install scripts into the created environment from a directory.

        :param context: The information for the environment creation request
                        being processed.
        :param path:    Absolute pathname of a directory containing script.
                        Scripts in the 'common' subdirectory of this directory,
                        and those in the directory named for the platform
                        being run on, are installed in the created environment.
                        Placeholder variables are replaced with environment-
                        specific values.
        """
        binpath = context.bin_path
        plen = len(path)
        for root, dirs, files in os.walk(path):
            if root == path:  # at top-level, remove irrelevant dirs
                for d in dirs[:]:
                    if d not in ('common', os.name):
                        dirs.remove(d)
                continue  # ignore files in top level
            for f in files:
                if (os.name == 'nt' and f.startswith('python')
                        and f.endswith(('.exe', '.pdb'))):
                    continue
                srcfile = os.path.join(root, f)
                suffix = root[plen:].split(os.sep)[2:]
                if not suffix:
                    dstdir = binpath
                else:
                    dstdir = os.path.join(binpath, *suffix)
                if not os.path.exists(dstdir):
                    os.makedirs(dstdir)
                dstfile = os.path.join(dstdir, f)
                with open(srcfile, 'rb') as fh:
                    data = fh.read()
                if not srcfile.endswith(('.exe', '.pdb')):
                    context.script_path = srcfile
                    try:
                        data = data.decode('utf-8')
                        data = self.replace_variables(data, context)
                        if srcfile.endswith('.bat') and '\r\n' not in data:
                            # Nython: cmd.exe reads batch files with CRLF
                            # line ends
                            data = data.replace('\n', '\r\n')
                        data = data.encode('utf-8')
                    except UnicodeError as e:
                        data = None
                        logger.warning('unable to copy script %r, '
                                       'may be binary: %s', srcfile, e)
                if data is not None:
                    with open(dstfile, 'wb') as fh:
                        fh.write(data)
                    shutil.copymode(srcfile, dstfile)

    def upgrade_dependencies(self, context):
        logger.debug(
            f'Upgrading {CORE_VENV_DEPS} packages in {context.bin_path}'
        )
        self._call_new_python(context, '-m', 'pip', 'install', '--upgrade',
                              *CORE_VENV_DEPS)


def create(env_dir, system_site_packages=False, clear=False,
           symlinks=False, with_pip=False, prompt=None, upgrade_deps=False):
    """Create a virtual environment in a directory."""
    builder = EnvBuilder(system_site_packages=system_site_packages,
                         clear=clear, symlinks=symlinks, with_pip=with_pip,
                         prompt=prompt, upgrade_deps=upgrade_deps)
    builder.create(env_dir)


def main(args=None):
    import argparse

    parser = argparse.ArgumentParser(prog=__name__,
                                     description='Creates virtual Python '
                                                 'environments in one or '
                                                 'more target '
                                                 'directories.',
                                     epilog='Once an environment has been '
                                            'created, you may wish to '
                                            'activate it, e.g. by '
                                            'sourcing an activate script '
                                            'in its bin directory.')
    parser.add_argument('dirs', metavar='ENV_DIR', nargs='+',
                        help='A directory to create the environment in.')
    parser.add_argument('--system-site-packages', default=False,
                        action='store_true', dest='system_site',
                        help='Give the virtual environment access to the '
                             'system site-packages dir.')
    if os.name == 'nt':
        use_symlinks = False
    else:
        use_symlinks = True
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--symlinks', default=use_symlinks,
                       action='store_true', dest='symlinks',
                       help='Try to use symlinks rather than copies, '
                            'when symlinks are not the default for '
                            'the platform.')
    group.add_argument('--copies', default=not use_symlinks,
                       action='store_false', dest='symlinks',
                       help='Try to use copies rather than symlinks, '
                            'even when symlinks are the default for '
                            'the platform.')
    parser.add_argument('--clear', default=False, action='store_true',
                        dest='clear', help='Delete the contents of the '
                                           'environment directory if it '
                                           'already exists, before '
                                           'environment creation.')
    parser.add_argument('--upgrade', default=False, action='store_true',
                        dest='upgrade', help='Upgrade the environment '
                                             'directory to use this version '
                                             'of Python, assuming Python '
                                             'has been upgraded in-place.')
    parser.add_argument('--without-pip', dest='with_pip',
                        default=True, action='store_false',
                        help='Skips installing or upgrading pip in the '
                             'virtual environment (pip is bootstrapped '
                             'by default)')
    parser.add_argument('--prompt',
                        help='Provides an alternative prompt prefix for '
                             'this environment.')
    parser.add_argument('--upgrade-deps', default=False, action='store_true',
                        dest='upgrade_deps',
                        help=f'Upgrade core dependencies ({", ".join(CORE_VENV_DEPS)}) '
                             'to the latest version in PyPI')
    options = parser.parse_args(args)
    if options.upgrade and options.clear:
        raise ValueError('you cannot supply --upgrade and --clear together.')
    builder = EnvBuilder(system_site_packages=options.system_site,
                         clear=options.clear,
                         symlinks=options.symlinks,
                         upgrade=options.upgrade,
                         with_pip=options.with_pip,
                         prompt=options.prompt,
                         upgrade_deps=options.upgrade_deps)
    for d in options.dirs:
        builder.create(d)
