# vm_audit125.ny - program text is never a path; raw descriptors are raw
# (round 86, main session).
#
# The parser reads an f-string's replacement field (and a Nython string's
# ${...}) with a lexer of its own over the field's text. That text went
# through the constructor that takes a *file name*, which asked the file
# system whether the string named one: f"{x}" in a directory holding a file
# called x read that file and ran it as the field's expression, and a field
# naming a directory (f"{lib}", f"{src}" beside lib/ and src/) hung the
# parser, the stream never reaching its end. On Windows f"{...}" hung
# wherever it was parsed, since Win32 path rules make "..." name the
# current directory. The same constructor read the text of exec'd
# programs' fields, the prelude, the mirror chunks, lang_eval's code and the
# editor's syntax check.
#
# Also here: os.read / os.write on the standard descriptors move bytes as
# they are on every platform (CPython puts them in binary mode at startup:
# on Windows "\r\n" arrived as "\n" and went out as "\r\r\n", and a Language
# Server's headers could not be read).
#
# The checks pass under python3 too (the Nython-only ones are marked):
#
#     ./build/nython-cli examples/vm_audit125.ny
#     ./build/nython-cli --vm examples/vm_audit125.ny
#     python3 examples/vm_audit125.ny

import os, sys, ast, tempfile, subprocess

NYTHON = sys.implementation.name == "nython"
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

home = os.getcwd()
T = tempfile.mkdtemp(prefix="ny125_")
# a file and a directory named like the fields below, and a file whose text
# would print if it were run
with open(os.path.join(T, "x"), "w") as f:
    f.write("print('FROM FILE x')\n")
with open(os.path.join(T, "total"), "w") as f:
    f.write("1 / 0\n")
os.mkdir(os.path.join(T, "lib"))
os.mkdir(os.path.join(T, "src"))
os.chdir(T)

def run_child(src):
    # a separate process, so a hang is a timeout and not this test's end
    try:
        r = subprocess.run([sys.executable] + (["--vm"] if NYTHON and "--vm" in getattr(sys, "orig_argv", []) else [])
                           + ["-c", src], capture_output=True, timeout=60, cwd=T)
        return [r.returncode, r.stdout.decode("utf-8", "replace").replace("\r\n", "\n"),
                r.stderr.decode("utf-8", "replace")[-300:] if r.returncode else ""]
    except subprocess.TimeoutExpired:
        return ["timeout"]

# ── f-string fields that name files and directories ─────────────────────────
ns = {"x": 5, "total": 7, "lib": "L", "src": "S"}
exec('r1 = f"{x} {total}"', ns)
check("f-string fields naming files in the working directory", ns["r1"], "5 7")
exec('r2 = f"{lib}/{src}"', ns)
check("f-string fields naming directories", ns["r2"], "L/S")
exec('r3 = f"{x!r:>4}|{lib=}"', ns)
check("... with a conversion, a spec and =", ns["r3"], "   5|lib='L'")
check("f'{...}' is Ellipsis", eval('f"{...}"'), "Ellipsis")
check("a program run where its fields name files",
      run_child('x = 5\nlib = "L"\nprint(f"{x} {lib}")\n'), [0, "5 L\n", ""])

# the ast module's view of the same fields (its own path through the parser)
tree = ast.parse('f"{x}{lib}"')
check("ast.parse of fields naming a file and a directory",
      [type(v).__name__ for v in tree.body[0].value.values],
      ["FormattedValue", "FormattedValue"])
check("... the names", [v.value.id for v in tree.body[0].value.values], ["x", "lib"])

if NYTHON:
    # Nython's own ${...} in a Nython-language string (exec'd from this .ny
    # file: Nython's language), its text read the same way
    exec(r'r4 = "v ${x} ${lib}"', ns)   # (raw: this file's own strings interpolate ${...})
    check("${...} naming a file and a directory (Nython only)", ns["r4"], "v 5 L")
    # the editor's syntax check on a buffer whose whole text names a file
    check("ny_check_syntax of text naming a file (Nython only)", ny_check_syntax("x"), [])
    check("ny_check_syntax of text naming a directory (Nython only)", ny_check_syntax("lib"), [])

# a path given as a program still runs as a file
with open(os.path.join(T, "prog.ny" if NYTHON else "prog.py"), "w") as f:
    f.write("print('ran ' + str(6 * 7))\n")
r = subprocess.run([sys.executable, "prog.ny" if NYTHON else "prog.py"], capture_output=True, timeout=60, cwd=T)
check("a program file still runs", [r.returncode, r.stdout.decode().strip()], [0, "ran 42"])

# ── raw descriptors move bytes as they are ──────────────────────────────────
r = subprocess.run([sys.executable, "-c", 'import os\nos.write(1, b"a\\r\\nb\\n\\r")\n'], capture_output=True, timeout=60)
check("os.write(1, ...) writes the bytes given", r.stdout, b"a\r\nb\n\r")
r = subprocess.run([sys.executable, "-c", 'import os\nos.write(1, b"a\\r\\nb\\rc\\n")\n'], capture_output=True, text=True, timeout=60)
check("... and text mode reads its line ends as \\n (universal newlines)", r.stdout, "a\nb\nc\n")
r = subprocess.run([sys.executable, "-c", 'import os\nd = b""\nwhile True:\n    c = os.read(0, 100)\n    if not c:\n        break\n    d += c\nos.write(1, repr(d).encode())\n'],
                   input=b"h1\r\nh2\n\r\n\r\nbody", capture_output=True, timeout=60)
check("os.read(0, ...) reads the bytes sent", r.stdout, b"b'h1\\r\\nh2\\n\\r\\n\\r\\nbody'")

os.chdir(home)
import shutil
shutil.rmtree(T, ignore_errors=True)

pass_n = 0
fail_n = 0
for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT125 PASSED ===")
