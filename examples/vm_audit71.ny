# vm_audit71.ny - the command line and what Python programs expect around
# it, both engines (round 77).
#
#   cli         nython -c / file / - / -m mod / -i (piped: values echoed, _
#               kept, SystemExit ends the prompt with its status), sys.argv
#               as Python sets it, --check, --version, unknown options (2),
#               exit()/sys.exit()/raise SystemExit statuses and messages;
#               every case on both engines (--vm passed to the child)
#   argparse    Python's parsing: chunked positionals, -abc / -n3 / -qn3,
#               --long=value, unique prefixes, ambiguity, negative numbers,
#               "--", nargs N/?/*/+/REMAINDER, append/extend/count,
#               BooleanOptionalAction, mutually exclusive groups, subcommands
#               with aliases and set_defaults, custom Action classes,
#               parse_known_args, parse_intermixed_args, fromfile_prefix_chars,
#               parents, exit_on_error=False, type errors; the usage and help
#               text byte for byte as Python's HelpFormatter lays it out
#               (wrapping, alignment, groups, formatter classes)
#   stdio       sys.stdin/stdout/stderr objects, print(*xs, sep=, end=,
#               file=, flush=), os.get_terminal_size (COLUMNS)
#   language    **kwargs keep the call order (PEP 468), locals() / globals()
#               / vars() / dir(), keyword-named arguments (fn=, namespace=),
#               namespace/struct/enum/interface usable as names, builtins
#               have __name__
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit71.ny
#     ./build/nython-cli --vm examples/vm_audit71.ny
import sys
import argparse

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    if repr(got) == repr(want):
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + repr(got) + " want " + repr(want))

os_setenv("COLUMNS", "80")
var EXE = sys.executable
var TMP = os_path_join(os_gettempdir(), "ny_audit71_" + str(os_getpid()))
os_makedirs(TMP, true)

def run(engine, args, input=none):
    var argv = [EXE] + engine + args
    var r = none
    if input != none:
        r = os_run(argv, input=input, timeout=60)
    else:
        r = os_run(argv, timeout=60)
    return [r["code"], r["stdout"], r["stderr"]]

# ── the command line, on each engine ─────────────────────────────────────────
def test_cli():
    write_file(os_path_join(TMP, "prog.ny"), "import sys\nprint(sys.argv)\n")
    os_makedirs(os_path_join(TMP, "pkg71"), true)
    write_file(os_path_join(TMP, "pkg71/__main__.ny"), "import sys\nprint('main of pkg71', sys.argv[1:])\n")
    write_file(os_path_join(TMP, "mod71.ny"), "print('mod71 ran', __name__)\n")
    write_file(os_path_join(TMP, "bad.ny"), "def f(:\n    pass\n")
    for engine in [[], ["--vm"]]:
        var tag = "vm " if len(engine) > 0 else "interp "
        check(tag + "-c argv", run(engine, ["-c", "import sys; print(sys.argv)", "a", "-x"]), [0, "['-c', 'a', '-x']\n", ""])
        var pf = os_path_join(TMP, "prog.ny")
        check(tag + "file argv", run(engine, [pf, "1", "--two"]), [0, repr([pf, "1", "--two"]) + "\n", ""])
        check(tag + "stdin program", run(engine, ["-", "q"], "import sys\nprint(6 * 7, sys.argv)\n"), [0, "42 ['-', 'q']\n", ""])
        var cwd_r = os_run([EXE] + engine + ["-m", "mod71"], cwd=TMP, timeout=60)
        check(tag + "-m module", [cwd_r["code"], cwd_r["stdout"]], [0, "mod71 ran __main__\n"])
        var pk = os_run([EXE] + engine + ["-m", "pkg71", "z"], cwd=TMP, timeout=60)
        check(tag + "-m package", [pk["code"], pk["stdout"]], [0, "main of pkg71 ['z']\n"])
        check(tag + "-m missing", run(engine, ["-m", "no_such_mod_71"])[0], 1)
        check(tag + "exit(3)", run(engine, ["-c", "exit(3)"]), [3, "", ""])
        check(tag + "exit(text)", run(engine, ["-c", "import sys; sys.exit('bye')"]), [1, "", "bye\n"])
        check(tag + "SystemExit caught", run(engine, ["-c", "try:\n    exit(5)\nexcept SystemExit as e:\n    print('caught', e.code)\n"]), [0, "caught 5\n", ""])
        check(tag + "finally runs on exit", run(engine, ["-c", "try:\n    exit(2)\nfinally:\n    print('cleanup')\n"]), [2, "cleanup\n", ""])
        check(tag + "uncaught error status", run(engine, ["-c", "raise ValueError('bad')"])[0], 1)
        check(tag + "--check ok", run(engine, ["--check", pf]), [0, pf + ": ok\n", ""])
        check(tag + "--check error", run(engine, ["--check", os_path_join(TMP, "bad.ny")])[0], 1)
        check(tag + "unknown option", run(engine, ["--bogus-71"])[0], 2)
        check(tag + "--version", string_strip(run(engine, ["--version"])[1]).startswith("Nython 0.2.1"), true)
        # the prompt on piped input (-i): values echoed, _ kept, errors as
        # Python's last traceback line, SystemExit ends it with its status
        var prompt = "x = 5\nx * 2\ndef f(a):\n    return a + 1\n\nf(x)\n'it'\n_\n1/0\nimport sys\nsys.exit(4)\nprint('not reached')\n"
        check(tag + "-i piped", run(engine, ["-i"], prompt), [4, "10\n6\n'it'\n'it'\n", "ZeroDivisionError: division by zero\n"])
        check(tag + "-i after -c", run(engine, ["-i", "-c", "y = [1, 2]"], "y + [3]\n"), [0, "[1, 2, 3]\n", ""])
        check(tag + "-q bundled", run(engine, ["-qi", "-c", "z = 9"], "z\n"), [0, "9\n", ""])

# ── argparse ─────────────────────────────────────────────────────────────────
def ap_run(p, argv):
    try:
        return repr(p.parse_args(argv))
    except SystemExit as e:
        return "exit " + str(e.code)

def test_argparse_parsing():
    var p = argparse.ArgumentParser(prog="tool", exit_on_error=false)
    p.add_argument("files", nargs="+")
    p.add_argument("-n", "--count", type=int, default=1, choices=[1, 2, 3])
    p.add_argument("-v", "--verbose", action="count", default=0)
    p.add_argument("-q", action="store_true")
    p.add_argument("--name", dest="who", default="anon")
    p.add_argument("--tag", action="append")
    p.add_argument("--opt", nargs="?", const="C", default="D")
    p.add_argument("--pair", nargs=2, metavar=("A", "B"))
    check("defaults", ap_run(p, ["a.txt"]), "Namespace(files=['a.txt'], count=1, verbose=0, q=false, who='anon', tag=none, opt='D', pair=none)")
    check("bundles and attached", ap_run(p, ["a", "b", "-n2", "-vvv", "-q", "--name=bob", "--tag", "x", "--tag", "y"]),
          "Namespace(files=['a', 'b'], count=2, verbose=3, q=true, who='bob', tag=['x', 'y'], opt='D', pair=none)")
    check("-qn3 chain", ap_run(p, ["f", "-qvn3"]), "Namespace(files=['f'], count=3, verbose=1, q=true, who='anon', tag=none, opt='D', pair=none)")
    check("prefixes", ap_run(p, ["--verb", "--coun", "3", "f"]), "Namespace(files=['f'], count=3, verbose=1, q=false, who='anon', tag=none, opt='D', pair=none)")
    check("nargs ? const", ap_run(p, ["f", "--opt"]), "Namespace(files=['f'], count=1, verbose=0, q=false, who='anon', tag=none, opt='C', pair=none)")
    check("nargs 2", ap_run(p, ["f", "--pair", "x", "y"]), "Namespace(files=['f'], count=1, verbose=0, q=false, who='anon', tag=none, opt='D', pair=['x', 'y'])")
    check("-- separator", ap_run(p, ["--", "-x", "-y"]), "Namespace(files=['-x', '-y'], count=1, verbose=0, q=false, who='anon', tag=none, opt='D', pair=none)")
    var r = p.parse_known_args(["f", "--zzz", "q"])
    check("parse_known_args tuple", [isinstance(r, "tuple"), r[0].files, r[1]], [true, ["f"], ["--zzz", "q"]])
    var errs = []
    for argv in [["f", "-n", "9"], ["f", "-n", "x"], ["f", "--pair", "x"], ["f", "--ver=1"], ["f", "-q=1"]]:
        try:
            p.parse_args(argv)
            errs.append("no error")
        except argparse.ArgumentError as e:
            errs.append(str(e))
    check("errors", errs, ["argument -n/--count: invalid choice: 9 (choose from 1, 2, 3)",
                           "argument -n/--count: invalid int value: 'x'",
                           "argument --pair: expected 2 arguments",
                           "argument -v/--verbose: ignored explicit argument '1'",
                           "argument -q: ignored explicit argument '1'"])
    var amb = argparse.ArgumentParser(prog="amb", exit_on_error=false)
    amb.add_argument("--alpha")
    amb.add_argument("--alps")
    try:
        amb.parse_args(["--al", "1"])
        check("ambiguous", "no error", "error")
    except argparse.ArgumentError as e:
        check("ambiguous", str(e), "ambiguous option: --al could match --alpha, --alps")

    var p2 = argparse.ArgumentParser(prog="c")
    p2.add_argument("nums", nargs="*", type=int)
    p2.add_argument("--neg", type=int)
    p2.add_argument("--rest", nargs=argparse.REMAINDER)
    check("negative values", ap_run(p2, ["--neg", "-5", "3", "-7"]), "Namespace(nums=[3, -7], neg=-5, rest=none)")
    check("remainder", ap_run(p2, ["1", "--rest", "a", "--neg", "b"]), "Namespace(nums=[1], neg=none, rest=['a', '--neg', 'b'])")

    class Upper(argparse.Action):
        def __call__(self, parser, namespace, values, option_string=none):
            setattr(namespace, self.dest, values.upper() + "!" + option_string)
    var p3 = argparse.ArgumentParser(prog="u")
    p3.add_argument("--up", action=Upper)
    p3.add_argument("--flag", action=argparse.BooleanOptionalAction, default=true)
    p3.add_argument("--ext", action="extend", nargs="+")
    check("custom action", ap_run(p3, ["--up", "abc", "--no-flag", "--ext", "a", "b", "--ext", "c"]),
          "Namespace(up='ABC!--up', flag=false, ext=['a', 'b', 'c'])")

    var g = argparse.ArgumentParser(prog="git", exit_on_error=false)
    g.add_argument("--debug", action="store_true")
    var sub = g.add_subparsers(dest="cmd", required=true)
    var c = sub.add_parser("commit", help="record changes")
    c.add_argument("-m", "--message", required=true)
    c.add_argument("-a", action="store_true")
    c.set_defaults(func="do_commit")
    var pu = sub.add_parser("push", aliases=["up"])
    pu.add_argument("remote", nargs="?", default="origin")
    check("subcommand", ap_run(g, ["--debug", "commit", "-am", "msg"]), "Namespace(debug=true, cmd='commit', message='msg', a=true, func='do_commit')")
    check("alias", ap_run(g, ["up", "gh"]), "Namespace(debug=false, cmd='up', remote='gh')")
    check("subcommand default", ap_run(g, ["push"]), "Namespace(debug=false, cmd='push', remote='origin')")

    var m = argparse.ArgumentParser(prog="x", exit_on_error=false)
    var grp = m.add_mutually_exclusive_group()
    grp.add_argument("--a", action="store_true")
    grp.add_argument("--b", action="store_true")
    try:
        m.parse_args(["--a", "--b"])
        check("exclusive", "no error", "error")
    except argparse.ArgumentError as e:
        check("exclusive", str(e), "argument --b: not allowed with argument --a")

    var mix = argparse.ArgumentParser(prog="mix")
    mix.add_argument("--foo")
    mix.add_argument("cmd")
    mix.add_argument("rest", nargs="*")
    check("positionals around an option", ap_run(mix, ["a", "--foo", "x", "b", "c"]), "Namespace(foo='x', cmd='a', rest=['b', 'c'])")
    check("intermixed", repr(mix.parse_intermixed_args(["a", "--foo", "x", "b"])), "Namespace(foo='x', cmd='a', rest=['b'])")

    var ff = argparse.ArgumentParser(prog="ff", fromfile_prefix_chars="@")
    ff.add_argument("--a")
    ff.add_argument("b")
    write_file(os_path_join(TMP, "args.txt"), "--a\nvalue\nbee\n")
    check("fromfile", ap_run(ff, ["@" + os_path_join(TMP, "args.txt")]), "Namespace(a='value', b='bee')")

    var parent = argparse.ArgumentParser(add_help=false)
    parent.add_argument("--shared", default="s")
    var child = argparse.ArgumentParser(prog="child", parents=[parent])
    child.add_argument("--own")
    check("parents", ap_run(child, ["--shared", "t"]), "Namespace(shared='t', own=none)")
    var ns = argparse.Namespace(a=1, b="x")
    check("Namespace", [repr(ns), "a" in ns, ns == argparse.Namespace(a=1, b="x"), vars(ns)], ["Namespace(a=1, b='x')", true, true, {"a": 1, "b": "x"}])

def test_argparse_help():
    var p = argparse.ArgumentParser(prog="tool", description="A tool that does a great many things with files, and whose description is long enough that it must be wrapped across several lines.", epilog="See the manual for more.")
    p.add_argument("files", nargs="+", help="input files to process, in the order they are given on the command line")
    p.add_argument("-n", "--count", type=int, default=1, choices=[1, 2, 3], help="how many (%(choices)s), default %(default)s")
    p.add_argument("-q", action="store_true", help="quiet")
    p.add_argument("--very-long-option-name-indeed", help="a long one")
    p.add_argument("--flag", action=argparse.BooleanOptionalAction, default=true, help="toggle")
    var g = p.add_argument_group("output", "where the results go")
    g.add_argument("-o", "--out", default="-", help="output file")
    var m = p.add_mutually_exclusive_group()
    m.add_argument("--json", action="store_true")
    m.add_argument("--xml", action="store_true")
    # what python3's argparse prints for the same parser at 80 columns
    var want = "".join([
        "usage: tool [-h] [-n {1,2,3}] [-q]\n",
        "            [--very-long-option-name-indeed VERY_LONG_OPTION_NAME_INDEED]\n",
        "            [--flag | --no-flag] [-o OUT] [--json | --xml]\n",
        "            files [files ...]\n",
        "\n",
        "A tool that does a great many things with files, and whose description is long\n",
        "enough that it must be wrapped across several lines.\n",
        "\n",
        "positional arguments:\n",
        "  files                 input files to process, in the order they are given on\n",
        "                        the command line\n",
        "\n",
        "options:\n",
        "  -h, --help            show this help message and exit\n",
        "  -n {1,2,3}, --count {1,2,3}\n",
        "                        how many (1, 2, 3), default 1\n",
        "  -q                    quiet\n",
        "  --very-long-option-name-indeed VERY_LONG_OPTION_NAME_INDEED\n",
        "                        a long one\n",
        "  --flag, --no-flag     toggle\n",
        "  --json\n",
        "  --xml\n",
        "\n",
        "output:\n",
        "  where the results go\n",
        "\n",
        "  -o OUT, --out OUT     output file\n",
        "\n",
        "See the manual for more.\n"
    ])
    check("help text", p.format_help(), want)

    var s = argparse.ArgumentParser(prog="git", description="vcs")
    s.add_argument("--debug", action="store_true")
    var sub = s.add_subparsers(dest="cmd", title="commands", description="the commands", help="what to do")
    sub.add_parser("commit", help="record changes")
    sub.add_parser("push", aliases=["up"], help="send changes")
    check("subcommand help", s.format_help(),
          "usage: git [-h] [--debug] {commit,push,up} ...\n\nvcs\n\noptions:\n  -h, --help        show this help message and exit\n  --debug\n\ncommands:\n  the commands\n\n  {commit,push,up}  what to do\n    commit          record changes\n    push (up)       send changes\n")

    var raw = argparse.ArgumentParser(prog="raw", formatter_class=argparse.RawDescriptionHelpFormatter, description="line one\n    indented two")
    check("raw description", raw.format_help(), "usage: raw [-h]\n\nline one\n    indented two\n\noptions:\n  -h, --help  show this help message and exit\n")
    var defs = argparse.ArgumentParser(prog="defs", formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    defs.add_argument("--x", help="the x", default=3)
    check("defaults formatter", defs.format_help(), "usage: defs [-h] [--x X]\n\noptions:\n  -h, --help  show this help message and exit\n  --x X       the x (default: 3)\n")

# ── stdio and print ──────────────────────────────────────────────────────────
def test_stdio():
    for engine in [[], ["--vm"]]:
        var tag = "vm " if len(engine) > 0 else "interp "
        check(tag + "print forms", run(engine, ["-c", "import sys\nxs = [1, 2, 3]\nprint(*xs)\nprint(*xs, sep='-', end='|\\n')\nprint('e', 1, file=sys.stderr)\nprint('f', flush=True)\nsys.stdout.write('w\\n')\nsys.stderr.write('E\\n')\n"]),
              [0, "1 2 3\n1-2-3|\nf\nw\n", "e 1\nE\n"])
        check(tag + "stdin object", run(engine, ["-c", "import sys\nprint(repr(sys.stdin.readline()))\nprint(repr(sys.stdin.read()))\n"], "first\nsecond\nthird"),
              [0, "'first\\n'\n'second\\nthird'\n", ""])
        check(tag + "print keyword check", run(engine, ["-c", "try:\n    print(1, colour=2)\nexcept TypeError as e:\n    print(e)\n"]), [0, "'colour' is an invalid keyword argument for print()\n", ""])
    check("stream attributes", [sys.stdout.fileno(), sys.stderr.fileno(), sys.stdin.fileno(), sys.stdout.writable(), sys.stdin.readable(), sys.__stdout__ is sys.stdout], [1, 2, 0, true, true, true])
    check("terminal size from COLUMNS", os_get_terminal_size()[0], 80)

# ── language pieces ──────────────────────────────────────────────────────────
def kw_order(**kw):
    return list(kw.keys())

class Thing:
    kind = "t"
    def __init__(self):
        self.a = 1
        self.b = "x"
    def method(self):
        return 1

def scope_probe(x, y=2):
    var z = 3
    return [sorted(list(locals().keys())), sorted(list(vars().keys()))]

def soft(namespace=1, struct=2, fn=3, enum=4, interface=5, package=6):
    return [namespace, struct, fn, enum, interface, package]

def test_language():
    check("kwargs order", kw_order(z=1, a=2, m=3, b=4), ["z", "a", "m", "b"])
    check("dict(**) order", list(dict(b=1, a=2).keys()), ["b", "a"])
    check("locals/vars()", scope_probe(1), [["x", "y", "z"], ["x", "y", "z"]])
    var t = Thing()
    check("vars(obj)", vars(t), {"a": 1, "b": "x"})
    check("dir(obj)", [n for n in dir(t) if not n.startswith("__")], ["a", "b", "kind", "method"])
    check("dir(class)", [n for n in dir(Thing) if not n.startswith("__")], ["kind", "method"])
    check("dir(list) has append", ["append" in dir([]), "upper" in dir(""), "keys" in dir({})], [true, true, true])
    check("globals()", ["Thing" in globals(), "scope_probe" in globals(), "print" in globals()], [true, true, false])
    try:
        vars(5)
        check("vars(5)", "no error", "TypeError")
    except TypeError as e:
        check("vars(5)", str(e), "vars() argument must have __dict__ attribute")
    check("keyword-named arguments", soft(namespace=10, struct=20, fn=30, enum=40, interface=50, package=60), [10, 20, 30, 40, 50, 60])
    var namespace = "ns"
    var struct = "st"
    check("soft keywords as names", [namespace, struct], ["ns", "st"])
    check("builtin __name__", [len.__name__, int.__name__, print.__name__], ["len", "int", "print"])

test_cli()
test_argparse_parsing()
test_argparse_help()
test_stdio()
test_language()
os_rmtree(TMP)
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT71 PASSED ===")
